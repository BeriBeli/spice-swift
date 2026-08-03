import Foundation
import SpiceProtocol
import SpiceTransport
import SpiceWire

package struct ChannelConnectionMetrics: Sendable, Equatable {
    package var framerNextTiming: RenderPhaseMetrics
    package var framerAppendTiming: RenderPhaseMetrics

    package init(
        framerNextTiming: RenderPhaseMetrics = RenderPhaseMetrics(),
        framerAppendTiming: RenderPhaseMetrics = RenderPhaseMetrics()
    ) {
        self.framerNextTiming = framerNextTiming
        self.framerAppendTiming = framerAppendTiming
    }

    package mutating func accumulate(_ other: Self) {
        framerNextTiming = framerNextTiming.accumulating(other.framerNextTiming)
        framerAppendTiming = framerAppendTiming.accumulating(other.framerAppendTiming)
    }

    package func subtracting(_ earlier: Self) -> Self {
        Self(
            framerNextTiming: framerNextTiming.subtracting(earlier.framerNextTiming),
            framerAppendTiming: framerAppendTiming.subtracting(
                earlier.framerAppendTiming
            )
        )
    }
}

package actor ChannelConnection {
    package nonisolated let key: ChannelKey

    private let transport: any SpiceTransport
    private let serialBarrier: ChannelSerialBarrier
    private var framer: MessageFramer
    private var nextClientSerial: UInt64 = 1
    private var nextImplicitServerSerial: UInt64 = 1
    private var isMigrating = false
    private let diagnosticsEnabled: Bool
    private var framerNextTiming: RenderPhaseRecorder
    private var framerAppendTiming: RenderPhaseRecorder

    package init(
        key: ChannelKey,
        transport: any SpiceTransport,
        headerMode: HeaderMode,
        serialBarrier: ChannelSerialBarrier = ChannelSerialBarrier(),
        limits: WireLimits = .init(),
        diagnosticsMode: RenderDiagnosticsMode = .disabled,
        diagnosticsClock: @escaping RenderPhaseRecorder.Clock =
            RenderPhaseRecorder.systemClock
    ) {
        self.key = key
        self.transport = transport
        self.serialBarrier = serialBarrier
        diagnosticsEnabled = diagnosticsMode.normalizedCommandPeriod != nil
        framer = MessageFramer(mode: headerMode, limits: limits)
        framerNextTiming = RenderPhaseRecorder(
            mode: diagnosticsMode,
            clock: diagnosticsClock
        )
        framerAppendTiming = RenderPhaseRecorder(
            mode: diagnosticsMode,
            clock: diagnosticsClock
        )
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
            let framedMessage: FramedMessage?
            do {
                if diagnosticsEnabled {
                    var timingSample = framerNextTiming.beginCommand()
                    defer { framerNextTiming.finishCommand(&timingSample) }
                    framedMessage = try framer.nextMessage()
                } else {
                    framedMessage = try framer.nextMessage()
                }
            } catch let error {
                throw .wire(error)
            }
            if let message = framedMessage {
                let serial: UInt64
                if let explicitSerial = message.serial {
                    serial = explicitSerial
                } else {
                    serial = nextImplicitServerSerial
                    let (next, overflow) = serial.addingReportingOverflow(1)
                    guard !overflow else {
                        throw .protocolViolation("server message serial overflow")
                    }
                    nextImplicitServerSerial = next
                }
                serialBarrier.record(key: key, serial: serial)
                return message
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
                if diagnosticsEnabled {
                    var timingSample = framerAppendTiming.beginCommand()
                    defer { framerAppendTiming.finishCommand(&timingSample) }
                    try framer.append(bytes)
                } else {
                    try framer.append(bytes)
                }
            } catch let error {
                throw .wire(error)
            }
        }
    }

    package func metrics() -> ChannelConnectionMetrics {
        ChannelConnectionMetrics(
            framerNextTiming: framerNextTiming.metrics,
            framerAppendTiming: framerAppendTiming.metrics
        )
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
