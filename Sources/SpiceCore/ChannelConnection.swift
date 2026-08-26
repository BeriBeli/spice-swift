import Foundation
import SpiceProtocol
import SpiceTransport
import SpiceWire

package actor ChannelConnection {
    private struct InFlightDelivery {
        let effectiveSerial: UInt64
        let completesPhysicalMessage: Bool
        let isPhysicalMainMessage: Bool
        var acknowledgmentCount: Int
    }

    package nonisolated let key: ChannelKey

    private let transport: any SpiceTransport
    private let serialBarrier: ChannelSerialBarrier
    private var framer: MessageFramer
    private var pendingBatch: FramedMessageBatch?
    private var pendingMessageIndex = 0
    private var pendingEffectiveSerial: UInt64?
    private var inFlightDelivery: InFlightDelivery?
    private var ackController = AckController()
    private var nextClientSerial: UInt64 = 1
    private var nextImplicitServerSerial: UInt64 = 1
    private var isMigrating = false
    private var terminalError: ChannelError?

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
                let error = ChannelError.protocolViolation("unexpected channel migration data")
                await fail(error)
                throw error
            }
            return framed
        }

        let flags: SpiceChannelMigrationFlags
        do {
            flags = try SpiceChannelMigrationCodec.decodeFlags(framed.body)
        } catch let error {
            let channelError = ChannelError.wire(error)
            await fail(channelError)
            throw channelError
        }
        isMigrating = true
        do {
            if flags.contains(.needFlush) {
                try await send(
                    messageType: SpiceChannelMigrationWire.clientFlushMark,
                    body: Data()
                )
            }
            // MIGRATE is processed before a following MIGRATE_DATA physical
            // message is admitted. This also satisfies the outstanding
            // logical-delivery invariant.
            try await completeLastDelivered()
        } catch let error {
            await fail(error)
            throw error
        }
        let migrationData: Data?
        if flags.contains(.needDataTransfer) {
            let dataMessage = try await receiveFramed()
            guard dataMessage.type == SpiceChannelMigrationWire.serverMigrateData else {
                let error = ChannelError.protocolViolation(
                    "channel migration expected MIGRATE_DATA after MIGRATE"
                )
                await fail(error)
                throw error
            }
            migrationData = dataMessage.body
            do {
                try await completeLastDelivered()
            } catch let error {
                await fail(error)
                throw error
            }
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
        if let terminalError {
            throw terminalError
        }
        guard inFlightDelivery == nil else {
            let error = ChannelError.invalidState
            await fail(error)
            throw error
        }
        while true {
            if let pendingBatch, pendingMessageIndex < pendingBatch.messages.count {
                guard let effectiveSerial = pendingEffectiveSerial else {
                    let error = ChannelError.invalidState
                    await fail(error)
                    throw error
                }
                let index = pendingMessageIndex
                let message = pendingBatch.framedMessage(at: index)
                inFlightDelivery = InFlightDelivery(
                    effectiveSerial: effectiveSerial,
                    completesPhysicalMessage: message.acknowledgmentCount > 0,
                    isPhysicalMainMessage: pendingBatch.mainMessageIndex == index,
                    acknowledgmentCount: message.acknowledgmentCount
                )
                pendingMessageIndex += 1
                if pendingMessageIndex == pendingBatch.messages.count {
                    self.pendingBatch = nil
                    pendingMessageIndex = 0
                    pendingEffectiveSerial = nil
                }
                return message
            }

            let framedBatch: FramedMessageBatch?
            do {
                framedBatch = try framer.nextBatch()
            } catch let error {
                let channelError = ChannelError.wire(error)
                await fail(channelError)
                throw channelError
            }
            if let batch = framedBatch {
                let serial: UInt64
                if let explicitSerial = batch.serial {
                    serial = explicitSerial
                } else {
                    serial = nextImplicitServerSerial
                    let (next, overflow) = serial.addingReportingOverflow(1)
                    guard !overflow else {
                        let error = ChannelError.protocolViolation(
                            "server message serial overflow"
                        )
                        await fail(error)
                        throw error
                    }
                    nextImplicitServerSerial = next
                }
                if batch.messages.isEmpty {
                    // An empty SPICE_MSG_LIST still represents one complete
                    // physical ACK unit. It has no logical protocol message to
                    // dispatch, so completion is immediate.
                    do {
                        try await completePhysicalMessage(
                            effectiveSerial: serial,
                            acknowledgmentCount: batch.acknowledgmentCount
                        )
                    } catch let error {
                        await fail(error)
                        throw error
                    }
                    continue
                }
                pendingBatch = batch
                pendingMessageIndex = 0
                pendingEffectiveSerial = serial
                continue
            }

            let bytes: Data
            do {
                bytes = try await transport.read(minimum: 1, maximum: 64 * 1024)
            } catch let error {
                let channelError = ChannelError.transport(error)
                await fail(channelError)
                throw channelError
            }
            guard !bytes.isEmpty else {
                let error = ChannelError.transport(.connectionClosed)
                await fail(error)
                throw error
            }
            do {
                try framer.append(bytes)
            } catch let error {
                let channelError = ChannelError.wire(error)
                await fail(channelError)
                throw channelError
            }
        }
    }

    /// Configures ACK accounting at the physical-message boundary. A SET_ACK
    /// physical main message is not counted against the window it establishes.
    package func configureAcknowledgments(generation: UInt32, window: UInt32) {
        ackController.configure(generation: generation, window: window)
        // A SET_ACK carried as the physical main message establishes the new
        // window after that physical ACK boundary. A SET_ACK submessage, in
        // contrast, precedes the batch ACK and must not suppress it.
        if inFlightDelivery?.isPhysicalMainMessage == true {
            inFlightDelivery?.acknowledgmentCount = 0
        }
    }

    /// Completes the latest logical handler. Only the final logical message in
    /// a physical batch advances its effective serial and ACK state.
    package func completeLastDelivered() async throws(ChannelError) {
        guard terminalError == nil, let delivery = inFlightDelivery else {
            throw terminalError ?? .invalidState
        }
        if delivery.completesPhysicalMessage {
            do {
                try await completePhysicalMessage(
                    effectiveSerial: delivery.effectiveSerial,
                    acknowledgmentCount: delivery.acknowledgmentCount
                )
            } catch let error {
                await fail(error)
                throw error
            }
        }
        guard terminalError == nil else {
            throw terminalError ?? .invalidState
        }
        inFlightDelivery = nil
    }

    /// Compatibility spelling retained for AIP-10 callers.
    package func acknowledgeLastDelivered() async throws(ChannelError) {
        try await completeLastDelivered()
    }

    package func fail(_ error: ChannelError) async {
        if case .migrationRequested = error { return }
        guard terminalError == nil else { return }
        terminalError = error
        pendingBatch = nil
        pendingMessageIndex = 0
        pendingEffectiveSerial = nil
        inFlightDelivery = nil
        await serialBarrier.terminate(key: key)
    }

    private func completePhysicalMessage(
        effectiveSerial: UInt64,
        acknowledgmentCount: Int
    ) async throws(ChannelError) {
        try await acknowledgePhysicalMessages(acknowledgmentCount)
        guard terminalError == nil else {
            throw terminalError ?? .invalidState
        }
        await serialBarrier.record(key: key, serial: effectiveSerial)
        guard terminalError == nil else {
            throw terminalError ?? .invalidState
        }
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
            let channelError = ChannelError.transport(error)
            await fail(channelError)
            throw channelError
        }
    }

    package func close() async {
        await fail(.transport(.connectionClosed))
        await transport.close()
    }

    package func waitUntilProcessed(
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

    package func waitUntilReceived(
        _ requirements: [ChannelSerialBarrier.Requirement]
    ) async throws(ChannelError) {
        try await waitUntilProcessed(requirements)
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
