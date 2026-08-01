import AVFAudio
import Foundation

public enum SpiceAudioPlaybackSinkError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case invalidConfiguration(String)
    case invalidPacket(String)
    case audioEngine(String)

    public var description: String {
        switch self {
        case .alreadyRunning:
            "audio playback sink is already running"
        case let .invalidConfiguration(reason):
            "invalid playback configuration: \(reason)"
        case let .invalidPacket(reason):
            "invalid playback packet: \(reason)"
        case let .audioEngine(reason):
            "audio engine failed: \(reason)"
        }
    }
}

public enum SpiceAudioPlaybackSinkEvent: Sendable, Equatable {
    case started(SpicePlaybackConfiguration)
    case stopped
    case muteChanged(Bool)
    case overflowResynchronized(droppedMilliseconds: UInt32)
    case oversizedPacketDropped(milliseconds: UInt32)
    case underrun
    case failed(SpiceAudioPlaybackSinkError)
}

public struct SpiceAudioPlaybackSinkStatistics: Sendable, Equatable {
    public let scheduledPackets: UInt64
    public let scheduledFrames: UInt64

    public init(scheduledPackets: UInt64, scheduledFrames: UInt64) {
        self.scheduledPackets = scheduledPackets
        self.scheduledFrames = scheduledFrames
    }
}

/// A bounded macOS audio sink for SPICE RAW signed 16-bit little-endian PCM.
///
/// The player node receives the SPICE source format and AVAudioEngine converts
/// it to the current output-device format through the main mixer.
public actor SpiceAudioPlaybackSink {
    public nonisolated let events: AsyncStream<SpiceAudioPlaybackSinkEvent>

    private let eventContinuation: AsyncStream<SpiceAudioPlaybackSinkEvent>.Continuation
    private let maximumQueuedMilliseconds: UInt32
    private let delayReportInterval: Duration
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var eventTask: Task<Void, Never>?
    private var delayTask: Task<Void, Never>?
    private var controller: PlaybackBufferController?
    private var configuration: SpicePlaybackConfiguration?
    private var minimumLatencyMilliseconds: UInt32 = 0
    private var volume: [UInt16] = []
    private var isMuted = false
    private var scheduledPackets: UInt64 = 0
    private var scheduledFrames: UInt64 = 0

    public init(
        maximumQueuedMilliseconds: UInt32 = 500,
        delayReportIntervalMilliseconds: UInt32 = 50
    ) {
        precondition(maximumQueuedMilliseconds > 0)
        precondition(delayReportIntervalMilliseconds > 0)
        self.maximumQueuedMilliseconds = maximumQueuedMilliseconds
        delayReportInterval = .milliseconds(delayReportIntervalMilliseconds)
        let pipe = AsyncStream.makeStream(
            of: SpiceAudioPlaybackSinkEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        events = pipe.stream
        eventContinuation = pipe.continuation
        engine.attach(player)
    }

    deinit {
        eventTask?.cancel()
        delayTask?.cancel()
        eventContinuation.finish()
    }

    public func start(session: SpiceSession) throws(SpiceAudioPlaybackSinkError) {
        guard eventTask == nil else {
            throw .alreadyRunning
        }
        eventTask = Task { [weak self] in
            await self?.consumePlaybackEvents(from: session)
        }
        delayTask = Task { [weak self] in
            await self?.reportDelays(to: session)
        }
    }

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        delayTask?.cancel()
        delayTask = nil
        stopStream(emit: configuration != nil)
    }

    public func statistics() -> SpiceAudioPlaybackSinkStatistics {
        SpiceAudioPlaybackSinkStatistics(
            scheduledPackets: scheduledPackets,
            scheduledFrames: scheduledFrames
        )
    }

    private func consumePlaybackEvents(from session: SpiceSession) async {
        for await event in session.playbackEvents {
            guard !Task.isCancelled else {
                break
            }
            do {
                try handle(event)
            } catch let error {
                eventContinuation.yield(.failed(error))
                stopStream(emit: configuration != nil)
            }
        }
    }

    private func reportDelays(to session: SpiceSession) async {
        while !Task.isCancelled {
            do {
                try await ContinuousClock().sleep(for: delayReportInterval)
            } catch {
                break
            }
            guard configuration != nil else {
                continue
            }
            let delay = currentDelayMilliseconds()
            try? await session.reportPlaybackDelay(milliseconds: delay)
        }
    }

    private func handle(_ event: SpicePlaybackEvent) throws(SpiceAudioPlaybackSinkError) {
        switch event {
        case .modeChanged:
            break
        case let .started(configuration):
            try startStream(configuration)
        case let .packet(packet):
            try enqueue(packet)
        case .stopped:
            stopStream(emit: true)
        case let .volumeChanged(volume):
            self.volume = volume
            applyGain()
        case let .muteChanged(muted):
            isMuted = muted
            applyGain()
            eventContinuation.yield(.muteChanged(muted))
        case let .minimumLatencyChanged(milliseconds):
            minimumLatencyMilliseconds = milliseconds
            if var controller {
                let shouldStart = controller.setMinimumStartup(milliseconds: milliseconds)
                self.controller = controller
                if shouldStart {
                    player.play()
                }
            }
        }
    }

    private func startStream(
        _ configuration: SpicePlaybackConfiguration
    ) throws(SpiceAudioPlaybackSinkError) {
        guard configuration.format == .signed16LittleEndian else {
            throw .invalidConfiguration("unsupported sample format")
        }
        guard (1 ... 8).contains(configuration.channels),
              (8_000 ... 192_000).contains(configuration.sampleRate) else {
            throw .invalidConfiguration("channels or sample rate out of range")
        }
        guard let format = Self.audioFormat(for: configuration) else {
            throw .invalidConfiguration("AVAudioFormat rejected the source format")
        }

        stopStream(emit: self.configuration != nil)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw .audioEngine(String(describing: error))
        }
        controller = PlaybackBufferController(
            sampleRate: configuration.sampleRate,
            maximumQueuedMilliseconds: maximumQueuedMilliseconds,
            minimumStartupMilliseconds: minimumLatencyMilliseconds
        )
        self.configuration = configuration
        scheduledPackets = 0
        scheduledFrames = 0
        applyGain()
        eventContinuation.yield(.started(configuration))
    }

    private func enqueue(_ packet: SpicePlaybackPacket) throws(SpiceAudioPlaybackSinkError) {
        guard let configuration, var controller else {
            throw .invalidPacket("DATA received without an active stream")
        }
        let bytesPerFrame = configuration.channels * MemoryLayout<Int16>.size
        guard !packet.data.isEmpty, packet.data.count.isMultiple(of: bytesPerFrame) else {
            throw .invalidPacket("PCM data is not aligned to an interleaved frame")
        }
        let frameCount = UInt64(packet.data.count / bytesPerFrame)
        let decision = controller.enqueue(frames: frameCount)
        self.controller = controller

        switch decision {
        case let .dropOversized(frames):
            eventContinuation.yield(.oversizedPacketDropped(
                milliseconds: Self.milliseconds(frames: frames, sampleRate: controller.sampleRate)
            ))
        case let .schedule(generation, flush, startPlayback, droppedFrames):
            if flush {
                player.stop()
                eventContinuation.yield(.overflowResynchronized(
                    droppedMilliseconds: Self.milliseconds(
                        frames: droppedFrames,
                        sampleRate: controller.sampleRate
                    )
                ))
            }
            let buffer = try Self.makePCMBuffer(packet.data, configuration: configuration)
            player.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task {
                    await self?.bufferPlayed(frames: frameCount, generation: generation)
                }
            }
            scheduledPackets &+= 1
            scheduledFrames &+= frameCount
            if startPlayback {
                player.play()
            }
        }
    }

    private func bufferPlayed(frames: UInt64, generation: UInt64) {
        guard var controller else {
            return
        }
        let completion = controller.completed(frames: frames, generation: generation)
        guard completion.accepted else {
            return
        }
        if completion.becameEmpty {
            player.stop()
            controller.resetEmptyTimeline()
            eventContinuation.yield(.underrun)
        }
        self.controller = controller
    }

    private func stopStream(emit: Bool) {
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        controller?.stop()
        controller = nil
        configuration = nil
        if emit {
            eventContinuation.yield(.stopped)
        }
    }

    private func applyGain() {
        guard !isMuted else {
            player.volume = 0
            return
        }
        guard !volume.isEmpty else {
            player.volume = 1
            return
        }
        let sum = volume.reduce(UInt64(0)) { $0 + UInt64($1) }
        let average = Float(sum) / Float(volume.count) / Float(UInt16.max)
        player.volume = min(max(average, 0), 1)
    }

    private func currentDelayMilliseconds() -> UInt32 {
        guard let controller else {
            return 0
        }
        guard player.isPlaying,
              let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime),
              playerTime.sampleTime >= 0 else {
            return controller.delayMilliseconds()
        }
        return controller.delayMilliseconds(renderedFrames: UInt64(playerTime.sampleTime))
    }

    package static func audioFormat(
        for configuration: SpicePlaybackConfiguration
    ) -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(configuration.sampleRate),
            channels: AVAudioChannelCount(configuration.channels),
            interleaved: true
        )
    }

    package static func makePCMBuffer(
        _ data: Data,
        configuration: SpicePlaybackConfiguration
    ) throws(SpiceAudioPlaybackSinkError) -> AVAudioPCMBuffer {
        guard let format = audioFormat(for: configuration) else {
            throw .invalidConfiguration("AVAudioFormat rejected the source format")
        }
        let bytesPerFrame = configuration.channels * MemoryLayout<Int16>.size
        guard !data.isEmpty, data.count.isMultiple(of: bytesPerFrame) else {
            throw .invalidPacket("PCM data is not aligned to an interleaved frame")
        }
        let frameCount = data.count / bytesPerFrame
        guard frameCount <= Int(AVAudioFrameCount.max),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ) else {
            throw .invalidPacket("PCM packet is too large for AVAudioPCMBuffer")
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        let audioBuffer = buffer.mutableAudioBufferList.pointee.mBuffers
        guard let destination = audioBuffer.mData,
              Int(audioBuffer.mDataByteSize) >= data.count else {
            throw .invalidPacket("AVAudioPCMBuffer has insufficient storage")
        }
        data.copyBytes(to: destination.assumingMemoryBound(to: UInt8.self), count: data.count)
        return buffer
    }

    private static func milliseconds(frames: UInt64, sampleRate: UInt64) -> UInt32 {
        guard frames > 0 else {
            return 0
        }
        let value = (frames * 1_000 + sampleRate - 1) / sampleRate
        return UInt32(min(value, UInt64(UInt32.max)))
    }
}
