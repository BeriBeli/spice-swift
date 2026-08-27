import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import SwiftSpice

@Suite("Bounded audio playback buffering")
struct PlaybackBufferControllerTests {
    @Test func overflowCannotConsumeReplacementUsingTheOldPrimedGate() {
        let buffer = AudioPlaybackRenderBuffer(
            capacityBytes: 8,
            capacitySlots: 4,
            bytesPerFrame: 2,
            sampleRate: 1_000,
            minimumStartupMilliseconds: 4
        )
        #expect(buffer.enqueue(SpicePlaybackPacket(
            multimediaTime: 1,
            data: Data([1, 2, 3, 4, 5, 6, 7, 8])
        )) == .enqueued(droppedPackets: 0, droppedBytes: 0))

        var primingFrame = [UInt8](repeating: 0xff, count: 2)
        #expect(primingFrame.withUnsafeMutableBytes {
            (bytes: UnsafeMutableRawBufferPointer) in buffer.renderPCM(into: bytes)
        } == 2)
        #expect(primingFrame == [1, 2])

        let overflowBarrier = PlaybackRaceBarrier()
        let overflowResult = PlaybackLockedValue<AudioPacketRingEnqueueResult?>(nil)
        let overflowFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            overflowResult.store(buffer.enqueue(
                SpicePlaybackPacket(
                    multimediaTime: 2,
                    data: Data([9, 10, 11, 12, 13, 14])
                ),
                overflowReplacementPublished: overflowBarrier.block
            ))
            overflowFinished.signal()
        }
        #expect(overflowBarrier.waitUntilEntered())
        #expect(buffer.diagnostics().queuedBytes == 6)

        let renderGateReached = DispatchSemaphore(value: 0)
        let renderFinished = DispatchSemaphore(value: 0)
        let renderResult = PlaybackLockedValue<PlaybackRenderResult?>(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            var bytes = [UInt8](repeating: 0xff, count: 2)
            let copied = bytes.withUnsafeMutableBytes {
                (destination: UnsafeMutableRawBufferPointer) in
                buffer.renderPCM(
                    into: destination,
                    gateAcquisitionWillBegin: { renderGateReached.signal() }
                )
            }
            renderResult.store(PlaybackRenderResult(copied: copied, bytes: bytes))
            renderFinished.signal()
        }
        #expect(renderGateReached.wait(timeout: .now() + 10) == .success)
        #expect(renderFinished.wait(timeout: .now()) == .timedOut)
        #expect(buffer.diagnostics().queuedBytes == 6)

        overflowBarrier.release()
        #expect(overflowFinished.wait(timeout: .now() + 10) == .success)
        #expect(renderFinished.wait(timeout: .now() + 10) == .success)
        #expect(overflowResult.load() == .enqueued(droppedPackets: 1, droppedBytes: 6))
        #expect(renderResult.load() == PlaybackRenderResult(copied: 0, bytes: [0, 0]))
        #expect(buffer.diagnostics().queuedBytes == 6)

        #expect(buffer.enqueue(SpicePlaybackPacket(
            multimediaTime: 3,
            data: Data([15, 16])
        )) == .enqueued(droppedPackets: 0, droppedBytes: 0))
        var restartedFrames = [UInt8](repeating: 0xff, count: 8)
        #expect(restartedFrames.withUnsafeMutableBytes {
            (bytes: UnsafeMutableRawBufferPointer) in buffer.renderPCM(into: bytes)
        } == 8)
        #expect(restartedFrames == [9, 10, 11, 12, 13, 14, 15, 16])
        let diagnostics = buffer.diagnostics()
        #expect(diagnostics.overruns == 1)
        #expect(diagnostics.droppedPackets == 1)
        #expect(diagnostics.droppedBytes == 6)
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.retainedSlots == 0)
        buffer.close()
    }

    @Test func producerPayloadCopyDoesNotHoldTheRealtimeRenderGate() {
        let buffer = AudioPlaybackRenderBuffer(
            capacityBytes: 8,
            capacitySlots: 4,
            bytesPerFrame: 2,
            sampleRate: 1_000,
            minimumStartupMilliseconds: 4
        )
        #expect(buffer.enqueue(SpicePlaybackPacket(
            multimediaTime: 1,
            data: Data([1, 2, 3, 4, 5, 6, 7, 8])
        )) == .enqueued(droppedPackets: 0, droppedBytes: 0))

        let copyBarrier = PlaybackRaceBarrier()
        let overflowPublished = DispatchSemaphore(value: 0)
        let producerFinished = DispatchSemaphore(value: 0)
        let producerResult = PlaybackLockedValue<AudioPacketRingEnqueueResult?>(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = buffer.enqueue(
                SpicePlaybackPacket(
                    multimediaTime: 2,
                    data: Data([9, 10, 11, 12, 13, 14])
                ),
                payloadCopyWillBegin: copyBarrier.block,
                overflowReplacementPublished: { overflowPublished.signal() }
            )
            producerResult.store(result)
            producerFinished.signal()
        }
        #expect(copyBarrier.waitUntilEntered())

        let renderFinished = DispatchSemaphore(value: 0)
        let renderResult = PlaybackLockedValue<PlaybackRenderResult?>(nil)
        DispatchQueue.global(qos: .userInitiated).async {
            var bytes = [UInt8](repeating: 0xff, count: 2)
            let copied = bytes.withUnsafeMutableBytes {
                (destination: UnsafeMutableRawBufferPointer) in
                buffer.renderPCM(into: destination)
            }
            renderResult.store(PlaybackRenderResult(copied: copied, bytes: bytes))
            renderFinished.signal()
        }
        #expect(renderFinished.wait(timeout: .now() + 10) == .success)
        #expect(renderResult.load() == PlaybackRenderResult(copied: 0, bytes: [0, 0]))
        #expect(producerFinished.wait(timeout: .now()) == .timedOut)

        copyBarrier.release()
        #expect(overflowPublished.wait(timeout: .now() + 10) == .success)
        #expect(producerFinished.wait(timeout: .now() + 10) == .success)
        #expect(producerResult.load() == .enqueued(droppedPackets: 1, droppedBytes: 8))

        var gatedFrame = [UInt8](repeating: 0xff, count: 2)
        let gatedCount = gatedFrame.withUnsafeMutableBytes {
            (destination: UnsafeMutableRawBufferPointer) in
            buffer.renderPCM(into: destination)
        }
        #expect(gatedCount == 0)
        #expect(gatedFrame == [0, 0])

        #expect(buffer.enqueue(SpicePlaybackPacket(
            multimediaTime: 3,
            data: Data([15, 16])
        )) == .enqueued(droppedPackets: 0, droppedBytes: 0))
        var restartedFrames = [UInt8](repeating: 0xff, count: 8)
        let restartedCount = restartedFrames.withUnsafeMutableBytes {
            (destination: UnsafeMutableRawBufferPointer) in
            buffer.renderPCM(into: destination)
        }
        #expect(restartedCount == 8)
        #expect(restartedFrames == [9, 10, 11, 12, 13, 14, 15, 16])
        let diagnostics = buffer.diagnostics()
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.retainedSlots == 0)
        #expect(diagnostics.linearMovementBytes == 0)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        buffer.close()
    }

    @Test func audioRingAllocationLimitsAcceptExactBoundsAndRejectOnePastThem() throws {
        let maximumBytes = AudioPacketRingAllocationLimits.maximumPayloadBytes
        let maximumSlots = AudioPacketRingAllocationLimits.maximumSlotCount
        #expect(try AudioPacketRingAllocationLimits.validate(
            capacityBytes: maximumBytes,
            capacitySlots: maximumSlots
        ) == AudioPacketRingCapacity(
            capacityBytes: maximumBytes,
            capacitySlots: maximumSlots
        ))
        #expect(throws: AudioPacketRingAllocationLimitError.payloadCapacityExceeded(
            actual: maximumBytes + 1,
            maximum: maximumBytes
        )) {
            try AudioPacketRingAllocationLimits.validate(
                capacityBytes: maximumBytes + 1,
                capacitySlots: maximumSlots
            )
        }
        #expect(throws: AudioPacketRingAllocationLimitError.slotCapacityExceeded(
            actual: maximumSlots + 1,
            maximum: maximumSlots
        )) {
            try AudioPacketRingAllocationLimits.validate(
                capacityBytes: maximumBytes,
                capacitySlots: maximumSlots + 1
            )
        }
    }

    @Test func playbackAndCaptureCapacityRejectHugeInputsBeforeRingAllocation() throws {
        let captureDefault = try SpiceAudioCaptureSource.ringCapacity(
            configuration: SpiceRecordConfiguration(
                channels: 2,
                format: .signed16LittleEndian,
                sampleRate: 48_000
            ),
            maximumQueuedMilliseconds: 500
        )
        let expectedCaptureDefault = AudioPacketRingCapacity(
            capacityBytes: 96_000,
            capacitySlots: 24_000
        )
        #expect(captureDefault == expectedCaptureDefault)

        let playbackConfiguration = SpicePlaybackConfiguration(
            channels: 8,
            format: .signed16LittleEndian,
            sampleRate: 192_000
        )
        let captureConfiguration = SpiceRecordConfiguration(
            channels: 8,
            format: .signed16LittleEndian,
            sampleRate: 192_000
        )
        let playbackUpper = try SpiceAudioPlaybackSink.ringCapacity(
            configuration: playbackConfiguration,
            maximumQueuedMilliseconds: 1_000
        )
        let captureUpper = try SpiceAudioCaptureSource.ringCapacity(
            configuration: captureConfiguration,
            maximumQueuedMilliseconds: 1_000
        )
        #expect(playbackUpper == AudioPacketRingCapacity(
            capacityBytes: 3_072_000,
            capacitySlots: 192_000
        ))
        let expectedCaptureUpper = AudioPacketRingCapacity(
            capacityBytes: 3_072_000,
            capacitySlots: 192_000
        )
        #expect(captureUpper == expectedCaptureUpper)

        #expect(throws: SpiceAudioPlaybackSinkError.invalidConfiguration(
            "playback ring allocation exceeds resource limits"
        )) {
            try SpiceAudioPlaybackSink.ringCapacity(
                configuration: playbackConfiguration,
                maximumQueuedMilliseconds: .max
            )
        }
        #expect(throws: SpiceAudioCaptureSourceError.invalidConfiguration(
            "capture ring allocation exceeds resource limits"
        )) {
            try SpiceAudioCaptureSource.ringCapacity(
                configuration: captureConfiguration,
                maximumQueuedMilliseconds: .max
            )
        }

        let overflowPlayback = SpicePlaybackConfiguration(
            channels: .max,
            format: .signed16LittleEndian,
            sampleRate: .max
        )
        let overflowCapture = SpiceRecordConfiguration(
            channels: .max,
            format: .signed16LittleEndian,
            sampleRate: .max
        )
        #expect(throws: SpiceAudioPlaybackSinkError.invalidConfiguration(
            "playback ring frame capacity overflow"
        )) {
            try SpiceAudioPlaybackSink.ringCapacity(
                configuration: overflowPlayback,
                maximumQueuedMilliseconds: .max
            )
        }
        #expect(throws: SpiceAudioCaptureSourceError.invalidConfiguration(
            "capture ring frame capacity overflow"
        )) {
            try SpiceAudioCaptureSource.ringCapacity(
                configuration: overflowCapture,
                maximumQueuedMilliseconds: .max
            )
        }
    }

    @Test func captureCapacityReservesOneSlotPerOutputFrameWithinBothResourceLimits() throws {
        let lowRateOutput = SpiceRecordConfiguration(
            channels: 1,
            format: .signed16LittleEndian,
            sampleRate: 8_000
        )
        let reviewerCase = try SpiceAudioCaptureSource.ringCapacity(
            configuration: lowRateOutput,
            maximumQueuedMilliseconds: 10_000
        )
        let expectedReviewerCase = AudioPacketRingCapacity(
            capacityBytes: 160_000,
            capacitySlots: 80_000
        )
        #expect(reviewerCase == expectedReviewerCase)

        let exactCapacity = try SpiceAudioCaptureSource.ringCapacity(
            configuration: lowRateOutput,
            maximumQueuedMilliseconds: 32_768
        )
        let expectedExactCapacity = AudioPacketRingCapacity(
            capacityBytes: 524_288,
            capacitySlots: AudioPacketRingAllocationLimits.maximumSlotCount
        )
        #expect(exactCapacity == expectedExactCapacity)
        #expect(throws: SpiceAudioCaptureSourceError.invalidConfiguration(
            "capture ring allocation exceeds resource limits"
        )) {
            try SpiceAudioCaptureSource.ringCapacity(
                configuration: lowRateOutput,
                maximumQueuedMilliseconds: 32_769
            )
        }
    }

    @Test func productionRingCapacityAllowsEveryOneFramePacketInTheByteBudget() throws {
        let configuration = SpicePlaybackConfiguration(
            channels: 2,
            format: .signed16LittleEndian,
            sampleRate: 48_000
        )
        let capacity = try SpiceAudioPlaybackSink.ringCapacity(
            configuration: configuration,
            maximumQueuedMilliseconds: 500
        )

        #expect(capacity.capacityBytes == 96_000)
        #expect(capacity.capacitySlots == 24_000)
        let derivedSlotCount = try AudioPacketRingCapacity.slotCount(
            capacityBytes: capacity.capacityBytes,
            minimumPacketBytes: 4
        )
        #expect(capacity.capacitySlots == derivedSlotCount)

        let ring = PreallocatedAudioPacketRing(
            capacityBytes: capacity.capacityBytes,
            capacitySlots: capacity.capacitySlots
        )
        let oneStereoFrame: [UInt8] = [1, 2, 3, 4]
        let allEnqueued = oneStereoFrame.withUnsafeBytes {
            (bytes: UnsafeRawBufferPointer) in
            for packetIndex in 0 ..< capacity.capacitySlots {
                guard ring.enqueue(
                    timestamp: UInt32(packetIndex),
                    bytes: bytes
                ) == .enqueued(droppedPackets: 0, droppedBytes: 0) else {
                    return false
                }
            }
            return true
        }

        #expect(allEnqueued)
        let diagnostics = ring.diagnostics()
        #expect(diagnostics.queuedBytes == capacity.capacityBytes)
        #expect(diagnostics.queuedSlots == capacity.capacitySlots)
        #expect(diagnostics.enqueuedPackets == 24_000)
        #expect(diagnostics.overruns == 0)
        #expect(diagnostics.droppedPackets == 0)
        ring.close()
        #expect(ring.diagnostics().retainedSlots == 0)
    }

    @Test func lateCompletionFromPreviousPlaybackStreamIsRejected() {
        #expect(SpiceAudioPlaybackSink.isCurrentPlaybackCompletion(
            completedStreamEpoch: 7,
            currentStreamEpoch: 7
        ))
        #expect(!SpiceAudioPlaybackSink.isCurrentPlaybackCompletion(
            completedStreamEpoch: 6,
            currentStreamEpoch: 7
        ))
    }

    @Test func waitsForMinimumLatencyBeforeStarting() {
        var controller = PlaybackBufferController(
            sampleRate: 1_000,
            maximumQueuedMilliseconds: 500,
            minimumStartupMilliseconds: 100
        )

        #expect(controller.enqueue(frames: 40) == .schedule(
            generation: 0,
            flushScheduledAudio: false,
            startPlayback: false,
            droppedFrames: 0
        ))
        #expect(controller.enqueue(frames: 60) == .schedule(
            generation: 0,
            flushScheduledAudio: false,
            startPlayback: true,
            droppedFrames: 0
        ))
        #expect(controller.queuedFrames == 100)
        #expect(controller.delayMilliseconds() == 100)
    }

    @Test func overflowFlushesOldAudioAndInvalidatesItsCallbacks() {
        var controller = PlaybackBufferController(
            sampleRate: 1_000,
            maximumQueuedMilliseconds: 100
        )
        _ = controller.enqueue(frames: 80)

        #expect(controller.enqueue(frames: 30) == .schedule(
            generation: 1,
            flushScheduledAudio: true,
            startPlayback: true,
            droppedFrames: 80
        ))
        #expect(controller.completed(frames: 80, generation: 0) == .init(
            accepted: false,
            becameEmpty: false
        ))
        #expect(controller.queuedFrames == 30)
    }

    @Test func loweringMinimumLatencyStartsAlreadyBufferedAudio() {
        var controller = PlaybackBufferController(
            sampleRate: 1_000,
            maximumQueuedMilliseconds: 500,
            minimumStartupMilliseconds: 200
        )
        _ = controller.enqueue(frames: 100)

        let shouldStart = controller.setMinimumStartup(milliseconds: 100)
        #expect(shouldStart)
        #expect(controller.isPlaying)
    }

    @Test func packetLargerThanEntireBudgetIsDroppedWithoutMutation() {
        var controller = PlaybackBufferController(
            sampleRate: 48_000,
            maximumQueuedMilliseconds: 10
        )

        #expect(controller.enqueue(frames: 481) == .dropOversized(frames: 481))
        #expect(controller.queuedFrames == 0)
        #expect(controller.generation == 0)
    }

    @Test func emptyQueueResetsTimelineAndRecoversOnNextPacket() {
        var controller = PlaybackBufferController(
            sampleRate: 1_000,
            maximumQueuedMilliseconds: 100
        )
        _ = controller.enqueue(frames: 25)
        #expect(controller.completed(frames: 25, generation: 0) == .init(
            accepted: true,
            becameEmpty: true
        ))
        controller.resetEmptyTimeline()

        #expect(controller.enqueue(frames: 10) == .schedule(
            generation: 1,
            flushScheduledAudio: false,
            startPlayback: true,
            droppedFrames: 0
        ))
    }

    @Test func delayUsesRenderedPositionAndRoundsUpPartialMilliseconds() {
        var controller = PlaybackBufferController(
            sampleRate: 48_000,
            maximumQueuedMilliseconds: 500
        )
        _ = controller.enqueue(frames: 4_801)

        #expect(controller.delayMilliseconds() == 101)
        #expect(controller.delayMilliseconds(renderedFrames: 2_401) == 50)
        #expect(controller.delayMilliseconds(renderedFrames: 4_801) == 0)
    }

    @Test func createsInterleavedS16BufferWithoutChangingWireBytes() throws {
        let configuration = SpicePlaybackConfiguration(
            channels: 2,
            format: .signed16LittleEndian,
            sampleRate: 48_000
        )
        let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        let buffer = try SpiceAudioPlaybackSink.makePCMBuffer(
            bytes,
            configuration: configuration
        )

        #expect(buffer.format.commonFormat == .pcmFormatInt16)
        #expect(buffer.format.isInterleaved)
        #expect(buffer.format.channelCount == 2)
        #expect(buffer.frameLength == 2)
        let audioBuffer = buffer.audioBufferList.pointee.mBuffers
        let copied = Data(bytes: audioBuffer.mData!, count: bytes.count)
        #expect(copied == bytes)
    }

    @Test func rejectsMisalignedPCMBuffer() {
        let configuration = SpicePlaybackConfiguration(
            channels: 2,
            format: .signed16LittleEndian,
            sampleRate: 48_000
        )
        #expect(throws: SpiceAudioPlaybackSinkError.invalidPacket(
            "PCM data is not aligned to an interleaved frame"
        )) {
            try SpiceAudioPlaybackSink.makePCMBuffer(
                Data([0, 1, 2]),
                configuration: configuration
            )
        }
    }
}

private struct PlaybackRenderResult: Sendable, Equatable {
    let copied: Int
    let bytes: [UInt8]
}

private final class PlaybackRaceBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func block() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 10) == .success
    }

    func release() {
        released.signal()
    }
}

private final class PlaybackLockedValue<Value: Sendable>: @unchecked Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    func store(_ value: Value) {
        storage.withLock { $0 = value }
    }

    func load() -> Value {
        storage.withLock { $0 }
    }
}
