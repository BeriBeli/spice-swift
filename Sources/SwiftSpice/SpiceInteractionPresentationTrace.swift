import Foundation
import QuartzCore

package struct SpiceInteractionFrameIdentity: Sendable, Hashable, Codable {
    package let desktopGeneration: UInt64
    package let displayChannelID: UInt8
    package let surfaceID: UInt32
    package let surfaceGeneration: UInt64
    package let frameRevision: UInt64
    package let deliverySequence: UInt64

    package init(
        desktopGeneration: UInt64,
        displayChannelID: UInt8,
        surfaceID: UInt32,
        surfaceGeneration: UInt64,
        frameRevision: UInt64,
        deliverySequence: UInt64
    ) {
        self.desktopGeneration = desktopGeneration
        self.displayChannelID = displayChannelID
        self.surfaceID = surfaceID
        self.surfaceGeneration = surfaceGeneration
        self.frameRevision = frameRevision
        self.deliverySequence = deliverySequence
    }
}

package struct SpiceInteractionPresentationContext: Sendable, Equatable {
    package let identity: SpiceInteractionFrameIdentity
    package let readyNanoseconds: UInt64
    package let selectionNanoseconds: UInt64

    package init(
        identity: SpiceInteractionFrameIdentity,
        readyNanoseconds: UInt64,
        selectionNanoseconds: UInt64
    ) {
        self.identity = identity
        self.readyNanoseconds = readyNanoseconds
        self.selectionNanoseconds = selectionNanoseconds
    }
}

/// A measurement-only sink for exact desktop presentation evidence.
///
/// Implementations must return promptly and must not throw. SwiftSpice invokes
/// these methods after taking a single observer reference; it never retains an
/// observer-owned callback in the Metal or AppKit presentation state.
package protocol SpiceInteractionPresentationObserver: AnyObject, Sendable {
    func observeSelected(_ context: SpiceInteractionPresentationContext)
    func observeCommitted(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    )
    func observePresented(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    )
    func observePresentationDropped(identity: SpiceInteractionFrameIdentity)
}

package enum SpiceInteractionHostClock {
    private static let anchor: (instant: ContinuousClock.Instant, nanoseconds: UInt64) = {
        let nanoseconds = monotonicNanoseconds()
        return (ContinuousClock().now, nanoseconds)
    }()

    private static func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_MONOTONIC, &time) == 0)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    package static func nowNanoseconds() -> UInt64 {
        nanoseconds(for: ContinuousClock().now) ?? anchor.nanoseconds
    }

    package static func nanoseconds(for instant: ContinuousClock.Instant) -> UInt64? {
        let components = anchor.instant.duration(to: instant).components
        let (secondsNanoseconds, secondsOverflow) = components.seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflow else { return nil }
        let fractionalNanoseconds = components.attoseconds / 1_000_000_000
        let (delta, deltaOverflow) = secondsNanoseconds
            .addingReportingOverflow(fractionalNanoseconds)
        guard !deltaOverflow else { return nil }
        if delta >= 0 {
            let (value, overflow) = anchor.nanoseconds.addingReportingOverflow(UInt64(delta))
            return overflow ? nil : value
        }
        guard delta != Int64.min else { return nil }
        let magnitude = UInt64(-delta)
        guard magnitude <= anchor.nanoseconds else { return nil }
        return anchor.nanoseconds - magnitude
    }

    /// Converts an actual drawable presentation timestamp using clock samples
    /// captured by the same callback. A process-lifetime Core Animation offset
    /// can drift after sleep, so it is deliberately not retained.
    package static func nanoseconds(
        forCoreAnimationTime mediaTime: TimeInterval,
        mediaTimeNow: TimeInterval,
        continuousNanosecondsNow: UInt64
    ) -> UInt64? {
        guard mediaTime.isFinite,
              mediaTimeNow.isFinite,
              // CAMetalDrawable uses zero when the drawable was not presented.
              mediaTime > 0,
              mediaTimeNow >= mediaTime
        else {
            return nil
        }
        let elapsedNanosecondsValue = (
            (mediaTimeNow - mediaTime) * 1_000_000_000
        ).rounded()
        guard elapsedNanosecondsValue.isFinite,
              elapsedNanosecondsValue >= 0,
              let elapsedNanoseconds = UInt64(exactly: elapsedNanosecondsValue),
              elapsedNanoseconds <= continuousNanosecondsNow
        else {
            return nil
        }
        return continuousNanosecondsNow - elapsedNanoseconds
    }
}

extension SpiceDesktopSnapshot {
    package var interactionFrameIdentity: SpiceInteractionFrameIdentity? {
        guard let revision = frame?.revision,
              let frameDeliverySequence
        else {
            return nil
        }
        return SpiceInteractionFrameIdentity(
            desktopGeneration: generation,
            displayChannelID: revision.surface.displayChannelID,
            surfaceID: revision.surface.surfaceID,
            surfaceGeneration: revision.surface.generation,
            frameRevision: revision.value,
            deliverySequence: frameDeliverySequence
        )
    }
}
