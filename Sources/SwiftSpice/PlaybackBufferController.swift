import Foundation

package struct PlaybackBufferController: Sendable {
    package enum EnqueueDecision: Sendable, Equatable {
        case schedule(
            generation: UInt64,
            flushScheduledAudio: Bool,
            startPlayback: Bool,
            droppedFrames: UInt64
        )
        case dropOversized(frames: UInt64)
    }

    package struct Completion: Sendable, Equatable {
        package let accepted: Bool
        package let becameEmpty: Bool
    }

    package let sampleRate: UInt64
    package let maximumFrames: UInt64
    private(set) package var queuedFrames: UInt64 = 0
    private(set) package var scheduledFrames: UInt64 = 0
    private(set) package var generation: UInt64 = 0
    private(set) package var isPlaying = false
    private var minimumStartupFrames: UInt64 = 0

    package init(
        sampleRate: Int,
        maximumQueuedMilliseconds: UInt32,
        minimumStartupMilliseconds: UInt32 = 0
    ) {
        precondition(sampleRate > 0)
        self.sampleRate = UInt64(sampleRate)
        maximumFrames = max(
            1,
            Self.frames(
                milliseconds: maximumQueuedMilliseconds,
                sampleRate: UInt64(sampleRate)
            )
        )
        setMinimumStartup(milliseconds: minimumStartupMilliseconds)
    }

    @discardableResult
    package mutating func setMinimumStartup(milliseconds: UInt32) -> Bool {
        minimumStartupFrames = min(
            maximumFrames,
            Self.frames(milliseconds: milliseconds, sampleRate: sampleRate)
        )
        let shouldStart = !isPlaying && queuedFrames > 0 && queuedFrames >= minimumStartupFrames
        if shouldStart {
            isPlaying = true
        }
        return shouldStart
    }

    package mutating func enqueue(frames: UInt64) -> EnqueueDecision {
        guard frames <= maximumFrames else {
            return .dropOversized(frames: frames)
        }

        let wouldOverflow = frames > maximumFrames - queuedFrames
        let droppedFrames: UInt64
        if wouldOverflow {
            droppedFrames = queuedFrames
            generation &+= 1
            queuedFrames = 0
            scheduledFrames = 0
            isPlaying = false
        } else {
            droppedFrames = 0
        }

        queuedFrames += frames
        scheduledFrames += frames
        let shouldStart = !isPlaying && queuedFrames >= minimumStartupFrames
        if shouldStart {
            isPlaying = true
        }
        return .schedule(
            generation: generation,
            flushScheduledAudio: wouldOverflow,
            startPlayback: shouldStart,
            droppedFrames: droppedFrames
        )
    }

    package mutating func completed(
        frames: UInt64,
        generation completedGeneration: UInt64
    ) -> Completion {
        guard completedGeneration == generation else {
            return Completion(accepted: false, becameEmpty: false)
        }
        queuedFrames = frames >= queuedFrames ? 0 : queuedFrames - frames
        let becameEmpty = queuedFrames == 0
        if becameEmpty {
            isPlaying = false
        }
        return Completion(accepted: true, becameEmpty: becameEmpty)
    }

    /// Resets AVAudioPlayerNode's sample timeline after an underrun.
    package mutating func resetEmptyTimeline() {
        guard queuedFrames == 0 else {
            return
        }
        generation &+= 1
        scheduledFrames = 0
        isPlaying = false
    }

    package mutating func stop() {
        generation &+= 1
        queuedFrames = 0
        scheduledFrames = 0
        isPlaying = false
    }

    package func delayMilliseconds(renderedFrames: UInt64? = nil) -> UInt32 {
        let remainingFrames: UInt64
        if let renderedFrames {
            remainingFrames = renderedFrames >= scheduledFrames
                ? 0
                : scheduledFrames - renderedFrames
        } else {
            remainingFrames = queuedFrames
        }
        guard remainingFrames > 0 else {
            return 0
        }
        let milliseconds = (remainingFrames * 1_000 + sampleRate - 1) / sampleRate
        return UInt32(min(milliseconds, UInt64(UInt32.max)))
    }

    private static func frames(milliseconds: UInt32, sampleRate: UInt64) -> UInt64 {
        (UInt64(milliseconds) * sampleRate + 999) / 1_000
    }
}
