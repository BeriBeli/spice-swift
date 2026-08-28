import Foundation
import SpiceProtocol
import SpiceTransport
import SpiceWire

package actor ChannelConnection {
    package nonisolated let key: ChannelKey

    private let transport: any SpiceTransport
    private let serialBarrier: ChannelSerialBarrier
    private var framer: MessageFramer
    private var pendingBatch: FramedMessageBatch?
    private var pendingMessageIndex = 0
    private var ackController = AckController()
    private var unclaimedAcknowledgmentCount = 0
    private var nextClientSerial: UInt64 = 1
    private var nextImplicitServerSerial: UInt64 = 1
    private var isMigrating = false

    package init(
        key: ChannelKey,
        transport: any SpiceTransport,
        headerMode: HeaderMode,
        serialBarrier: ChannelSerialBarrier = ChannelSerialBarrier(),
        limits: WireLimits = .init()
    ) {
        self.key = key
        self.transport = transport
        self.serialBarrier = serialBarrier
        framer = MessageFramer(mode: headerMode, limits: limits)
    }

    package func receive() async throws(ChannelError) -> FramedMessage {
        let framed = try await receiveFramed()
        guard framed.type == SpiceChannelMigrationWire.serverMigrate else {
            guard framed.type != SpiceChannelMigrationWire.serverMigrateData else {
                throw .protocolViolation("unexpected channel migration data")
            }
            return framed
        }

        let flags: SpiceChannelMigrationFlags
        do {
            flags = try SpiceChannelMigrationCodec.decodeFlags(framed.body)
        } catch let error {
            throw .wire(error)
        }
        isMigrating = true
        if flags.contains(.needFlush) {
            try await send(
                messageType: SpiceChannelMigrationWire.clientFlushMark,
                body: Data()
            )
        }
        let migrationData: Data?
        if flags.contains(.needDataTransfer) {
            let dataMessage = try await receiveFramed()
            guard dataMessage.type == SpiceChannelMigrationWire.serverMigrateData else {
                throw .protocolViolation(
                    "channel migration expected MIGRATE_DATA after MIGRATE"
                )
            }
            migrationData = dataMessage.body
        } else {
            migrationData = nil
        }
        throw .migrationRequested(key: key, data: migrationData)
    }

    package func sendMigrationData(_ data: Data) async throws(ChannelError) {
        try await send(
            messageType: SpiceChannelMigrationWire.clientMigrateData,
            body: data
        )
    }

    package func resumeAfterMigrationCancellation() {
        isMigrating = false
    }

    private func receiveFramed() async throws(ChannelError) -> FramedMessage {
        while true {
            if let pendingBatch, pendingMessageIndex < pendingBatch.messages.count {
                let message = pendingBatch.framedMessage(at: pendingMessageIndex)
                pendingMessageIndex += 1
                if pendingMessageIndex == pendingBatch.messages.count {
                    self.pendingBatch = nil
                    pendingMessageIndex = 0
                }
                if message.acknowledgmentCount > 0 {
                    let (newCount, overflow) = unclaimedAcknowledgmentCount.addingReportingOverflow(
                        message.acknowledgmentCount
                    )
                    guard !overflow else {
                        throw .protocolViolation("physical message ACK count overflow")
                    }
                    unclaimedAcknowledgmentCount = newCount
                }
                return message
            }

            let framedBatch: FramedMessageBatch?
            do {
                framedBatch = try framer.nextBatch()
            } catch let error {
                throw .wire(error)
            }
            if let batch = framedBatch {
                let serial: UInt64
                if let explicitSerial = batch.serial {
                    serial = explicitSerial
                } else {
                    serial = nextImplicitServerSerial
                    let (next, overflow) = serial.addingReportingOverflow(1)
                    guard !overflow else {
                        throw .protocolViolation("server message serial overflow")
                    }
                    nextImplicitServerSerial = next
                }
                await serialBarrier.record(key: key, serial: serial)

                if batch.messages.isEmpty {
                    // An empty SPICE_MSG_LIST still represents one complete
                    // physical ACK unit. It has no logical protocol message to
                    // dispatch, so completion is immediate.
                    try await acknowledgePhysicalMessages(batch.acknowledgmentCount)
                    continue
                }
                pendingBatch = batch
                pendingMessageIndex = 0
                continue
            }

            let bytes: Data
            do {
                bytes = try await transport.read(minimum: 1, maximum: 64 * 1024)
            } catch let error {
                throw .transport(error)
            }
            guard !bytes.isEmpty else {
                throw .transport(.connectionClosed)
            }
            do {
                try framer.append(bytes)
            } catch let error {
                throw .wire(error)
            }
        }
    }

    /// Configures ACK accounting at the physical-message boundary. Resetting
    /// unclaimed state preserves the existing rule that the SET_ACK message
    /// establishing a window is not counted against that new window.
    package func configureAcknowledgments(generation: UInt32, window: UInt32) {
        ackController.configure(generation: generation, window: window)
        unclaimedAcknowledgmentCount = 0
    }

    /// Completes ACK accounting for the latest fully dispatched physical
    /// message. Intermediate logical submessages contribute zero here.
    package func acknowledgeLastDelivered() async throws(ChannelError) {
        let count = unclaimedAcknowledgmentCount
        unclaimedAcknowledgmentCount = 0
        try await acknowledgePhysicalMessages(count)
    }

    private func acknowledgePhysicalMessages(_ count: Int) async throws(ChannelError) {
        guard count >= 0 else {
            throw .protocolViolation("negative physical message ACK count")
        }
        for _ in 0..<count where ackController.didProcessMessage() {
            try await send(SpiceMsgcAck())
        }
    }

    package func send<Message: SpiceGeneratedMessage>(
        _ message: Message
    ) async throws(ChannelError) {
        guard let messageID = Message.messageID else {
            throw .protocolViolation("message \(String(describing: Message.self)) has no wire ID")
        }

        var bodyWriter = ByteWriter(capacity: Message.minimumWireSize)
        do {
            try message.encode(to: &bodyWriter)
        } catch let error {
            throw .wire(error)
        }
        try await send(messageType: messageID, body: bodyWriter.data)
    }

    package func send(messageType: UInt16, body: Data) async throws(ChannelError) {
        guard !isMigrating
                || messageType == SpiceChannelMigrationWire.clientFlushMark
                || messageType == SpiceChannelMigrationWire.clientMigrateData else {
            throw .invalidState
        }
        guard body.count <= Int(UInt32.max) else {
            throw .wire(.integerOverflow)
        }

        var writer = ByteWriter()
        switch framer.mode {
        case .full:
            writer.writeUInt64LE(nextClientSerial)
            let (next, overflow) = nextClientSerial.addingReportingOverflow(1)
            guard !overflow else {
                throw .protocolViolation("client message serial overflow")
            }
            nextClientSerial = next
            writer.writeUInt16LE(messageType)
            writer.writeUInt32LE(UInt32(body.count))
            writer.writeUInt32LE(0)
        case .mini:
            writer.writeUInt16LE(messageType)
            writer.writeUInt32LE(UInt32(body.count))
        }
        writer.writeBytes(body)

        do {
            try await transport.write(writer.data)
        } catch let error {
            throw .transport(error)
        }
    }

    package func close() async {
        await transport.close()
    }

    package func waitUntilReceived(
        _ requirements: [ChannelSerialBarrier.Requirement]
    ) async throws(ChannelError) {
        do {
            try await serialBarrier.wait(for: requirements)
        } catch is CancellationError {
            throw .transport(.cancelled)
        } catch {
            throw .protocolViolation(String(describing: error))
        }
    }
}

package struct ChannelKey: Sendable, Hashable {
    package let type: UInt8
    package let id: UInt8

    package init(type: UInt8, id: UInt8) {
        self.type = type
        self.id = id
    }
}
