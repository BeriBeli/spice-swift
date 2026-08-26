import Foundation
import SpiceCore
import SpiceProtocol
import SpiceWire

package enum RecordEvent: Sendable, Equatable {
    case started(SpiceRecordStart)
    case stopped
    case volumeChanged([UInt16])
    case muteChanged(Bool)
    case ignored(UInt16)
}

package actor RecordChannel: SpiceManagedChannel {
    private var connection: ChannelConnection
    private let maximumChannels: UInt32
    private let maximumFrequency: UInt32
    private let codec: SpiceRecordWireCodec
    private var configuration: SpiceRecordStart?
    private var streamMarked = false

    package init(
        connection: ChannelConnection,
        maximumChannels: UInt32 = 8,
        maximumFrequency: UInt32 = 192_000,
        wireLimits: SpiceRecordWireLimits = .init()
    ) {
        self.connection = connection
        self.maximumChannels = max(1, maximumChannels)
        self.maximumFrequency = max(8_000, maximumFrequency)
        codec = SpiceRecordWireCodec(limits: wireLimits)
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        while !Task.isCancelled {
            await emit(.record(try await processNext()))
        }
    }

    package func processNext() async throws(ChannelError) -> RecordEvent {
        let framed = try await connection.receive()
        let message: SpiceServerMessage
        do {
            message = try SpiceServerMessageDecoder.decode(
                id: framed.type,
                body: framed.body,
                channel: .record
            )
        } catch let error {
            throw .wire(error)
        }

        let event: RecordEvent
        switch message {
        case let .record(command):
            event = try handle(command)
        case let .setAck(setAck):
            await connection.configureAcknowledgments(
                generation: setAck.generation,
                window: setAck.window
            )
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
            return .ignored(framed.type)
        case let .ping(ping):
            try await connection.send(SpiceMsgcPong(id: ping.id, time: ping.time))
            event = .ignored(framed.type)
        case .disconnecting:
            throw .transport(.connectionClosed)
        case .unknown:
            event = .ignored(framed.type)
        default:
            throw .protocolViolation("message received on wrong Record Channel")
        }
        try await acknowledgeIfNeeded()
        return event
    }

    package func begin(timestamp: UInt32) async throws(ChannelError) {
        guard configuration != nil else {
            throw .protocolViolation("Record stream marked while stopped")
        }
        guard !streamMarked else {
            throw .protocolViolation("Record stream already marked")
        }
        let modeBody: Data
        do {
            modeBody = try codec.encodeMode(timestamp: timestamp)
        } catch let error {
            throw .wire(error)
        }
        try await connection.send(messageType: 102, body: modeBody)
        try await connection.send(
            messageType: 103,
            body: codec.encodeStartMark(timestamp: timestamp)
        )
        streamMarked = true
    }

    package func send(timestamp: UInt32, pcm: Data) async throws(ChannelError) {
        guard let configuration else {
            throw .protocolViolation("Record DATA while stream is stopped")
        }
        guard streamMarked else {
            throw .protocolViolation("Record DATA before MODE and START_MARK")
        }
        let frameBytes = Int(configuration.channels) * MemoryLayout<Int16>.size
        guard pcm.count.isMultiple(of: frameBytes) else {
            throw .protocolViolation(
                "Record DATA size \(pcm.count) is not aligned to \(frameBytes)"
            )
        }
        let body: Data
        do {
            body = try codec.encodeData(timestamp: timestamp, data: pcm)
        } catch let error {
            throw .wire(error)
        }
        try await connection.send(messageType: 101, body: body)
    }

    package func close() async {
        configuration = nil
        streamMarked = false
        await connection.close()
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Record Channel")
        }
        let previous = connection
        connection = replacement
        return previous
    }

    private func handle(_ command: SpiceRecordCommand) throws(ChannelError) -> RecordEvent {
        switch command {
        case let .start(start):
            guard configuration == nil else {
                throw .protocolViolation("Record START while stream is active")
            }
            guard start.channels > 0, start.channels <= maximumChannels else {
                throw .protocolViolation("invalid Record channel count \(start.channels)")
            }
            guard start.format == .s16 else {
                throw .protocolViolation("unsupported Record format \(start.format.rawValue)")
            }
            guard start.frequency >= 8_000, start.frequency <= maximumFrequency else {
                throw .protocolViolation("invalid Record frequency \(start.frequency)")
            }
            configuration = start
            streamMarked = false
            return .started(start)
        case .stop:
            guard configuration != nil else {
                throw .protocolViolation("Record STOP while stream is stopped")
            }
            configuration = nil
            streamMarked = false
            return .stopped
        case let .volume(volume):
            return .volumeChanged(volume)
        case let .mute(mute):
            return .muteChanged(mute)
        }
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        try await connection.acknowledgeLastDelivered()
    }
}
