import AVFAudio
import Foundation
import Testing
@testable import SwiftSpice

@Suite("Bounded audio playback buffering")
struct PlaybackBufferControllerTests {
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
