import Foundation
import SpiceCore
import SpiceProtocol

package enum PlaybackEvent: Sendable, Equatable {
    case modeChanged(multimediaTime: UInt32, mode: SpiceAudioDataMode)
    case started(SpicePlaybackStart)
    case packet(SpicePlaybackPacket)
    case stopped
    case volumeChanged([UInt16])
    case muteChanged(Bool)
    case minimumLatencyChanged(milliseconds: UInt32)
    case ignored(UInt16)
}

package actor PlaybackChannel: SpiceManagedChannel {
    private var connection: ChannelConnection
    private let multimediaClock: any MultimediaClockScheduling
    private let maximumChannels: UInt32
    private let maximumFrequency: UInt32
    private var mode: SpiceAudioDataMode?
    private var configuration: SpicePlaybackStart?
    private var lastPacketTime: UInt32?

    package init(
        connection: ChannelConnection,
        multimediaClock: any MultimediaClockScheduling,
        maximumChannels: UInt32 = 8,
        maximumFrequency: UInt32 = 192_000
    ) {
        self.connection = connection
        self.multimediaClock = multimediaClock
        self.maximumChannels = max(1, maximumChannels)
        self.maximumFrequency = max(8_000, maximumFrequency)
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        while !Task.isCancelled {
            await emit(.playback(try await processNext()))
        }
    }

    package func processNext() async throws(ChannelError) -> PlaybackEvent {
        let framed = try await connection.receive()
        let message: SpiceServerMessage
        do {
            message = try SpiceServerMessageDecoder.decode(
                id: framed.type,
                body: framed.body,
                channel: .playback
            )
        } catch let error {
            throw .wire(error)
        }

        let event: PlaybackEvent
        switch message {
        case let .playback(command):
            event = try await handle(command)
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
            throw .protocolViolation("message received on wrong Playback Channel")
        }
        try await acknowledgeIfNeeded()
        return event
    }

    package func reportDelay(milliseconds: UInt32) async throws(ChannelError) {
        guard configuration != nil else {
            throw .protocolViolation("playback delay reported while stream is stopped")
        }
        guard let lastPacketTime else {
            throw .protocolViolation("playback delay reported before audio data")
        }
        await multimediaClock.synchronize(
            playbackTime: lastPacketTime,
            delayMilliseconds: milliseconds
        )
    }

    package func close() async {
        mode = nil
        configuration = nil
        lastPacketTime = nil
        await connection.close()
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Playback Channel")
        }
        let previous = connection
        connection = replacement
        return previous
    }

    private func handle(_ command: SpicePlaybackCommand) async throws(ChannelError) -> PlaybackEvent {
        switch command {
        case let .mode(update):
            guard update.mode == .raw else {
                throw .protocolViolation("unsupported Playback mode \(update.mode.rawValue)")
            }
            guard update.data.isEmpty else {
                throw .protocolViolation("RAW Playback mode must not contain codec data")
            }
            mode = update.mode
            return .modeChanged(multimediaTime: update.multimediaTime, mode: update.mode)
        case let .start(start):
            guard configuration == nil else {
                throw .protocolViolation("Playback START while stream is active")
            }
            guard mode == .raw else {
                throw .protocolViolation("Playback START before supported MODE")
            }
            guard start.channels > 0, start.channels <= maximumChannels else {
                throw .protocolViolation("invalid Playback channel count \(start.channels)")
            }
            guard start.format == .s16 else {
                throw .protocolViolation("unsupported Playback format \(start.format.rawValue)")
            }
            guard start.frequency >= 8_000, start.frequency <= maximumFrequency else {
                throw .protocolViolation("invalid Playback frequency \(start.frequency)")
            }
            configuration = start
            lastPacketTime = nil
            return .started(start)
        case let .data(packet):
            guard let configuration else {
                throw .protocolViolation("Playback DATA while stream is stopped")
            }
            let frameBytes = Int(configuration.channels) * MemoryLayout<Int16>.size
            guard packet.data.count.isMultiple(of: frameBytes) else {
                throw .protocolViolation(
                    "Playback DATA size \(packet.data.count) is not aligned to \(frameBytes)"
                )
            }
            lastPacketTime = packet.multimediaTime
            return .packet(packet)
        case .stop:
            guard configuration != nil else {
                throw .protocolViolation("Playback STOP while stream is stopped")
            }
            configuration = nil
            lastPacketTime = nil
            return .stopped
        case let .volume(volume):
            return .volumeChanged(volume)
        case let .mute(mute):
            return .muteChanged(mute)
        case let .latency(milliseconds):
            return .minimumLatencyChanged(milliseconds: milliseconds)
        }
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        try await connection.acknowledgeLastDelivered()
    }
}
