import Foundation
import SpiceProtocol
import SpiceTransport
import SpiceWire

package actor ChannelConnection {
    private struct InFlightDelivery {
        let effectiveSerial: UInt64
        let completesPhysicalMessage: Bool
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
    private var acknowledgmentSuppressedEffectiveSerial: UInt64?
    private var ackController = AckController()
    private var nextClientSerial: UInt64 = 1
    private var nextImplicitServerSerial: UInt64 = 1
    private var isMigrating = false
    private var isSuperseded = false
    private var preservesSerialBarrierAfterSupersede = false
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
        guard !isSuperseded else {
            throw .invalidState
        }
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
                let completesPhysicalMessage = message.acknowledgmentCount > 0
                inFlightDelivery = InFlightDelivery(
                    effectiveSerial: effectiveSerial,
                    completesPhysicalMessage: completesPhysicalMessage,
                    acknowledgmentCount:
                        acknowledgmentSuppressedEffectiveSerial == effectiveSerial
                            ? 0
                            : message.acknowledgmentCount
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
            guard !isSuperseded else {
                throw .invalidState
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

    /// Configures ACK accounting at the physical-message boundary. The entire
    /// physical message carrying SET_ACK is excluded from the new window,
    /// whether SET_ACK is the main message or any logical submessage.
    package func configureAcknowledgments(generation: UInt32, window: UInt32) {
        ackController.configure(generation: generation, window: window)
        if let delivery = inFlightDelivery {
            acknowledgmentSuppressedEffectiveSerial = delivery.effectiveSerial
        }
        if inFlightDelivery?.completesPhysicalMessage == true {
            inFlightDelivery?.acknowledgmentCount = 0
        }
    }

    /// Completes the latest logical handler. Only the final logical message in
    /// a physical batch advances its effective serial and ACK state.
    package func completeLastDelivered() async throws(ChannelError) {
        guard !isSuperseded, terminalError == nil, let delivery = inFlightDelivery else {
            throw terminalError ?? .invalidState
        }
        if delivery.completesPhysicalMessage {
            do {
                try await completePhysicalMessage(
                    effectiveSerial: delivery.effectiveSerial,
                    acknowledgmentCount: delivery.acknowledgmentCount
                )
                if acknowledgmentSuppressedEffectiveSerial == delivery.effectiveSerial {
                    acknowledgmentSuppressedEffectiveSerial = nil
                }
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
        if isSuperseded, preservesSerialBarrierAfterSupersede {
            return
        }
        guard terminalError == nil else { return }
        terminalError = error
        pendingBatch = nil
        pendingMessageIndex = 0
        pendingEffectiveSerial = nil
        inFlightDelivery = nil
        acknowledgmentSuppressedEffectiveSerial = nil
        await serialBarrier.terminate(key: key)
    }

    /// Retires this connection without terminating the key-scoped serial
    /// barrier. A replacement may share that barrier and ChannelKey.
    package func supersede(preservingSerialBarrier: Bool) {
        isSuperseded = true
        preservesSerialBarrierAfterSupersede = preservingSerialBarrier
        pendingBatch = nil
        pendingMessageIndex = 0
        pendingEffectiveSerial = nil
        inFlightDelivery = nil
        acknowledgmentSuppressedEffectiveSerial = nil
    }

    /// Makes a previously superseded connection current again during a
    /// migration rollback. A genuinely terminal connection is not revivable.
    package func activate() throws(ChannelError) {
        guard terminalError == nil else {
            throw terminalError ?? .invalidState
        }
        isSuperseded = false
        preservesSerialBarrierAfterSupersede = false
    }

    package nonisolated func sharesSerialBarrier(with other: ChannelConnection) -> Bool {
        serialBarrier === other.serialBarrier
    }

    private func completePhysicalMessage(
        effectiveSerial: UInt64,
        acknowledgmentCount: Int
    ) async throws(ChannelError) {
        try await acknowledgePhysicalMessages(acknowledgmentCount)
        guard !isSuperseded, terminalError == nil else {
            throw terminalError ?? .invalidState
        }
        await serialBarrier.record(key: key, serial: effectiveSerial)
        guard !isSuperseded, terminalError == nil else {
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

    package func send(
        messageType: UInt16,
        body: Data,
        allowSupersededSend: Bool = false
    ) async throws(ChannelError) {
        guard (!isSuperseded || allowSupersededSend),
              !isMigrating
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
        if !isSuperseded || !preservesSerialBarrierAfterSupersede {
            await fail(.transport(.connectionClosed))
        }
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
