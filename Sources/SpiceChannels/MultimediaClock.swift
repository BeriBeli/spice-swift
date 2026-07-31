import Foundation

package enum MultimediaFrameTiming: Sendable, Equatable {
    case early(milliseconds: UInt32)
    case due
    case late(milliseconds: UInt32)
}

package enum MultimediaTimestamp {
    /// SPICE multimedia timestamps are wrapping UInt32 millisecond counters.
    /// Interpreting the wrapping subtraction as Int32 is valid as long as the
    /// two observations are less than 2^31 milliseconds apart.
    package static func timing(current: UInt32, target: UInt32) -> MultimediaFrameTiming {
        let delta = Int32(bitPattern: target &- current)
        if delta > 0 {
            return .early(milliseconds: UInt32(delta))
        }
        if delta < 0 {
            return .late(milliseconds: UInt32(delta.magnitude))
        }
        return .due
    }
}

package protocol MultimediaClockScheduling: Sendable {
    func reset(to multimediaTime: UInt32) async
    func synchronize(playbackTime: UInt32, delayMilliseconds: UInt32) async
    func timing(for multimediaTime: UInt32) async -> MultimediaFrameTiming
    func wait(until multimediaTime: UInt32) async throws -> MultimediaFrameTiming
}

/// Session-wide SPICE multimedia clock anchored to a monotonic local clock.
/// Actor reentrancy lets a Main Channel reset change the result of an active
/// wait; the target is re-evaluated after every sleep.
package actor MultimediaClock: MultimediaClockScheduling {
    private let clock = ContinuousClock()
    private var anchorInstant: ContinuousClock.Instant
    private var anchorTime: UInt32

    package init(initialTime: UInt32 = 0) {
        anchorInstant = clock.now
        anchorTime = initialTime
    }

    package func reset(to multimediaTime: UInt32) {
        anchorInstant = clock.now
        anchorTime = multimediaTime
    }

    package func synchronize(playbackTime: UInt32, delayMilliseconds: UInt32) {
        reset(to: playbackTime &- delayMilliseconds)
    }

    package func timing(for multimediaTime: UInt32) -> MultimediaFrameTiming {
        MultimediaTimestamp.timing(current: currentTime(), target: multimediaTime)
    }

    package func wait(until multimediaTime: UInt32) async throws -> MultimediaFrameTiming {
        while true {
            let frameTiming = timing(for: multimediaTime)
            switch frameTiming {
            case let .early(milliseconds):
                try await clock.sleep(for: .milliseconds(Int64(milliseconds)))
            case .due, .late:
                return frameTiming
            }
        }
    }

    private func currentTime() -> UInt32 {
        let elapsed = anchorInstant.duration(to: clock.now).components
        let seconds = UInt64(max(0, elapsed.seconds))
        let (wholeMilliseconds, overflow) = seconds.multipliedReportingOverflow(by: 1_000)
        guard !overflow else {
            return anchorTime &+ UInt32(truncatingIfNeeded: UInt64.max)
        }
        let fractionalMilliseconds = UInt64(max(0, elapsed.attoseconds)) / 1_000_000_000_000_000
        return anchorTime &+ UInt32(truncatingIfNeeded: wholeMilliseconds + fractionalMilliseconds)
    }
}
