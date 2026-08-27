import AVFAudio
import AudioToolbox
import Foundation
import Synchronization

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
/// A source-node render callback consumes a preallocated SPICE-format PCM ring;
/// AVAudioEngine converts it to the current output-device format.
public actor SpiceAudioPlaybackSink {
    public nonisolated let events: AsyncStream<SpiceAudioPlaybackSinkEvent>

    private let eventContinuation: AsyncStream<SpiceAudioPlaybackSinkEvent>.Continuation
    private let maximumQueuedMilliseconds: UInt32
    private let delayReportInterval: Duration
    private let engine = AVAudioEngine()
    private var eventTask: Task<Void, Never>?
    private var delayTask: Task<Void, Never>?
    private var sourceNode: AVAudioSourceNode?
    private var renderBuffer: AudioPlaybackRenderBuffer?
    private var configuration: SpicePlaybackConfiguration?
    private var minimumLatencyMilliseconds: UInt32 = 0
    private var volume: [UInt16] = []
    private var isMuted = false
    private var scheduledPackets: UInt64 = 0
    private var scheduledFrames: UInt64 = 0
    private var streamEpoch: UInt64 = 0
    private var reportedUnderflows: UInt64 = 0

    public init(
        maximumQueuedMilliseconds: UInt32 = 500,
        delayReportIntervalMilliseconds: UInt32 = 50
    ) {
        precondition(delayReportIntervalMilliseconds > 0)
        self.maximumQueuedMilliseconds = maximumQueuedMilliseconds
        delayReportInterval = .milliseconds(delayReportIntervalMilliseconds)
        let pipe = AsyncStream.makeStream(
            of: SpiceAudioPlaybackSinkEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        events = pipe.stream
        eventContinuation = pipe.continuation
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
            reportNewUnderflows()
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
            renderBuffer?.setMinimumStartup(milliseconds: milliseconds)
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
        let ringCapacity = try Self.ringCapacity(
            configuration: configuration,
            maximumQueuedMilliseconds: maximumQueuedMilliseconds
        )

        stopStream(emit: self.configuration != nil)
        let renderBuffer = AudioPlaybackRenderBuffer(
            capacityBytes: ringCapacity.capacityBytes,
            capacitySlots: ringCapacity.capacitySlots,
            bytesPerFrame: configuration.channels * MemoryLayout<Int16>.size,
            sampleRate: configuration.sampleRate,
            minimumStartupMilliseconds: minimumLatencyMilliseconds
        )
        let sourceNode = AVAudioSourceNode(format: format) {
            _, _, frameCount, audioBufferList -> OSStatus in
            renderBuffer.render(frameCount: frameCount, into: audioBufferList)
            return noErr
        }
        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
            renderBuffer.close()
            throw .audioEngine(String(describing: error))
        }
        self.sourceNode = sourceNode
        self.renderBuffer = renderBuffer
        self.configuration = configuration
        scheduledPackets = 0
        scheduledFrames = 0
        reportedUnderflows = 0
        applyGain()
        eventContinuation.yield(.started(configuration))
    }

    private func enqueue(_ packet: SpicePlaybackPacket) throws(SpiceAudioPlaybackSinkError) {
        guard let configuration, let renderBuffer else {
            throw .invalidPacket("DATA received without an active stream")
        }
        let bytesPerFrame = configuration.channels * MemoryLayout<Int16>.size
        guard !packet.data.isEmpty, packet.data.count.isMultiple(of: bytesPerFrame) else {
            throw .invalidPacket("PCM data is not aligned to an interleaved frame")
        }
        let frameCount = UInt64(packet.data.count / bytesPerFrame)
        let result = renderBuffer.enqueue(packet)
        switch result {
        case let .droppedOversized(byteCount), let .droppedLeaseConflict(byteCount):
            eventContinuation.yield(.oversizedPacketDropped(
                milliseconds: Self.milliseconds(
                    frames: UInt64(byteCount / bytesPerFrame),
                    sampleRate: UInt64(configuration.sampleRate)
                )
            ))
        case .rejectedClosed:
            throw .invalidPacket("playback ring is closed")
        case let .enqueued(droppedPackets, droppedBytes):
            if droppedPackets > 0 || droppedBytes > 0 {
                eventContinuation.yield(.overflowResynchronized(
                    droppedMilliseconds: Self.milliseconds(
                        frames: UInt64(droppedBytes / bytesPerFrame),
                        sampleRate: UInt64(configuration.sampleRate)
                    )
                ))
            }
            scheduledPackets &+= 1
            scheduledFrames &+= frameCount
        }
        reportNewUnderflows()
    }

    package nonisolated static func isCurrentPlaybackCompletion(
        completedStreamEpoch: UInt64,
        currentStreamEpoch: UInt64
    ) -> Bool {
        completedStreamEpoch == currentStreamEpoch
    }

    private func stopStream(emit: Bool) {
        streamEpoch &+= 1
        renderBuffer?.close()
        engine.stop()
        if let sourceNode {
            engine.disconnectNodeOutput(sourceNode)
            engine.detach(sourceNode)
        }
        sourceNode = nil
        renderBuffer = nil
        configuration = nil
        if emit {
            eventContinuation.yield(.stopped)
        }
    }

    private func applyGain() {
        guard !isMuted else {
            engine.mainMixerNode.outputVolume = 0
            return
        }
        guard !volume.isEmpty else {
            engine.mainMixerNode.outputVolume = 1
            return
        }
        let sum = volume.reduce(UInt64(0)) { $0 + UInt64($1) }
        let average = Float(sum) / Float(volume.count) / Float(UInt16.max)
        engine.mainMixerNode.outputVolume = min(max(average, 0), 1)
    }

    private func currentDelayMilliseconds() -> UInt32 {
        guard let configuration, let renderBuffer else {
            return 0
        }
        let bytesPerFrame = configuration.channels * MemoryLayout<Int16>.size
        let queuedFrames = UInt64(renderBuffer.diagnostics().queuedBytes / bytesPerFrame)
        return Self.milliseconds(
            frames: queuedFrames,
            sampleRate: UInt64(configuration.sampleRate)
        )
    }

    private func reportNewUnderflows() {
        guard let renderBuffer else {
            return
        }
        let underflows = renderBuffer.diagnostics().underflows
        while reportedUnderflows < underflows {
            reportedUnderflows &+= 1
            eventContinuation.yield(.underrun)
        }
    }

    package func ringDiagnostics() -> AudioPacketRingDiagnostics? {
        renderBuffer?.diagnostics()
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
        guard frames > 0, sampleRate > 0 else {
            return 0
        }
        let (scaledFrames, scaleOverflow) = frames.multipliedReportingOverflow(by: 1_000)
        let (roundedFrames, roundingOverflow) = scaledFrames.addingReportingOverflow(
            sampleRate - 1
        )
        guard !scaleOverflow, !roundingOverflow else {
            return .max
        }
        let value = roundedFrames / sampleRate
        return UInt32(min(value, UInt64(UInt32.max)))
    }

    package nonisolated static func ringCapacity(
        configuration: SpicePlaybackConfiguration,
        maximumQueuedMilliseconds: UInt32
    ) throws(SpiceAudioPlaybackSinkError) -> AudioPacketRingCapacity {
        guard configuration.sampleRate > 0,
              configuration.channels > 0,
              maximumQueuedMilliseconds > 0 else {
            throw .invalidConfiguration("playback ring dimensions must be positive")
        }
        let (frameMilliseconds, frameOverflow) = UInt64(configuration.sampleRate)
            .multipliedReportingOverflow(by: UInt64(maximumQueuedMilliseconds))
        let (roundedFrameMilliseconds, roundingOverflow) = frameMilliseconds
            .addingReportingOverflow(999)
        guard !frameOverflow, !roundingOverflow else {
            throw .invalidConfiguration("playback ring frame capacity overflow")
        }
        let frames = roundedFrameMilliseconds / 1_000
        let (bytesPerFrame, bytesPerFrameOverflow) = configuration.channels
            .multipliedReportingOverflow(by: MemoryLayout<Int16>.size)
        guard !bytesPerFrameOverflow, bytesPerFrame > 0 else {
            throw .invalidConfiguration("playback ring frame size overflow")
        }
        let (bytes, byteOverflow) = frames.multipliedReportingOverflow(
            by: UInt64(bytesPerFrame)
        )
        guard !byteOverflow, let capacityBytes = Int(exactly: bytes), capacityBytes > 0 else {
            throw .invalidConfiguration("playback ring byte capacity overflow")
        }
        let capacitySlots: Int
        do {
            capacitySlots = try AudioPacketRingCapacity.slotCount(
                capacityBytes: capacityBytes,
                minimumPacketBytes: bytesPerFrame
            )
        } catch {
            throw .invalidConfiguration("playback ring slot capacity is invalid")
        }
        do {
            return try AudioPacketRingAllocationLimits.validate(
                capacityBytes: capacityBytes,
                capacitySlots: capacitySlots
            )
        } catch {
            throw .invalidConfiguration("playback ring allocation exceeds resource limits")
        }
    }

}

/// Keeps render-thread state outside the actor. All storage and diagnostics are
/// preallocated; the AVAudioSourceNode callback only takes a bounded lock and
/// copies into Core Audio-owned buffers.
package final class AudioPlaybackRenderBuffer: @unchecked Sendable {
    package typealias GateObserver = @Sendable () -> Void

    private struct GateState: Sendable {
        var minimumStartupBytes: Int
        var isPrimed = false
        var publicationPending = false
    }

    private let ring: PreallocatedAudioPacketRing
    private let bytesPerFrame: Int
    private let sampleRate: Int
    private let gate: Mutex<GateState>
    private let producer = Mutex(())

    package init(
        capacityBytes: Int,
        capacitySlots: Int,
        bytesPerFrame: Int,
        sampleRate: Int,
        minimumStartupMilliseconds: UInt32
    ) {
        ring = PreallocatedAudioPacketRing(
            capacityBytes: capacityBytes,
            capacitySlots: capacitySlots
        )
        self.bytesPerFrame = bytesPerFrame
        self.sampleRate = sampleRate
        gate = Mutex(GateState(minimumStartupBytes: Self.startupBytes(
            milliseconds: minimumStartupMilliseconds,
            sampleRate: sampleRate,
            bytesPerFrame: bytesPerFrame,
            capacityBytes: capacityBytes
        )))
    }

    /// Producers are serialized, but payload copy happens without holding the
    /// render gate. `publicationPending` makes the ring publication invisible
    /// to render until overflow replacement and startup reset are committed in
    /// one short gate section. No path holds the ring mutex while acquiring the
    /// gate; render and close retain their gate-before-ring order.
    package func enqueue(
        _ packet: SpicePlaybackPacket,
        payloadCopyWillBegin payloadObserver: GateObserver? = nil,
        overflowReplacementPublished observer: GateObserver? = nil
    ) -> AudioPacketRingEnqueueResult {
        producer.withLock { _ in
            var publicationCleared = false
            gate.withLock { state in
                state.publicationPending = true
            }
            defer {
                if !publicationCleared {
                    gate.withLock { state in
                        state.publicationPending = false
                    }
                }
            }
            payloadObserver?()
            let result = packet.data.withUnsafeBytes { bytes in
                ring.enqueue(timestamp: packet.multimediaTime, bytes: bytes)
            }
            gate.withLock { state in
                if case let .enqueued(droppedPackets, droppedBytes) = result,
                   droppedPackets > 0 || droppedBytes > 0 {
                    observer?()
                    state.isPrimed = false
                }
                state.publicationPending = false
            }
            publicationCleared = true
            return result
        }
    }

    package func setMinimumStartup(milliseconds: UInt32) {
        let capacityBytes = ring.diagnostics().capacityBytes
        gate.withLock { state in
            state.minimumStartupBytes = Self.startupBytes(
                milliseconds: milliseconds,
                sampleRate: sampleRate,
                bytesPerFrame: bytesPerFrame,
                capacityBytes: capacityBytes
            )
        }
    }

    package func render(
        frameCount: AVAudioFrameCount,
        into audioBufferList: UnsafeMutablePointer<AudioBufferList>
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        let requestedBytes = Int(frameCount) * bytesPerFrame
        guard requestedBytes > 0 else {
            return
        }
        for index in buffers.indices {
            guard let pointer = buffers[index].mData else {
                continue
            }
            let availableBytes = Int(buffers[index].mDataByteSize)
            let byteCount = min(requestedBytes, availableBytes)
            let destination = UnsafeMutableRawBufferPointer(start: pointer, count: byteCount)
            guard index == buffers.startIndex, byteCount == requestedBytes else {
                destination.initializeMemory(as: UInt8.self, repeating: 0)
                continue
            }
            _ = renderPCM(into: destination)
        }
    }

    /// Package seam shared by the AVAudio callback and deterministic race
    /// tests. The observer fires immediately before attempting the gate lock.
    /// No allocation occurs on the production path.
    package func renderPCM(
        into destination: UnsafeMutableRawBufferPointer,
        gateAcquisitionWillBegin observer: GateObserver? = nil
    ) -> Int {
        guard destination.count > 0 else {
            return 0
        }
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        observer?()
        return gate.withLock { state in
            guard !state.publicationPending else { return 0 }
            let queuedBytes = ring.diagnostics().queuedBytes
            if !state.isPrimed {
                guard queuedBytes > 0, queuedBytes >= state.minimumStartupBytes else {
                    return 0
                }
                state.isPrimed = true
            }
            let copied = ring.read(into: destination)
            if copied < destination.count {
                state.isPrimed = false
            }
            return copied
        }
    }

    package func close() {
        gate.withLock { state in
            ring.close()
            state.isPrimed = false
            state.publicationPending = false
        }
    }

    package func diagnostics() -> AudioPacketRingDiagnostics {
        ring.diagnostics()
    }

    private static func startupBytes(
        milliseconds: UInt32,
        sampleRate: Int,
        bytesPerFrame: Int,
        capacityBytes: Int
    ) -> Int {
        guard sampleRate > 0, bytesPerFrame > 0, capacityBytes > 0 else {
            return capacityBytes
        }
        let (frameMilliseconds, frameOverflow) = UInt64(milliseconds)
            .multipliedReportingOverflow(by: UInt64(sampleRate))
        let (roundedFrameMilliseconds, roundingOverflow) = frameMilliseconds
            .addingReportingOverflow(999)
        guard !frameOverflow, !roundingOverflow else {
            return capacityBytes
        }
        let frames = roundedFrameMilliseconds / 1_000
        let (bytes, byteOverflow) = frames.multipliedReportingOverflow(
            by: UInt64(bytesPerFrame)
        )
        guard !byteOverflow else {
            return capacityBytes
        }
        return min(capacityBytes, Int(clamping: bytes))
    }
}
