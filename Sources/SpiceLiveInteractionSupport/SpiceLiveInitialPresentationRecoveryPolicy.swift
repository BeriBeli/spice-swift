/// A one-shot, pre-arm recovery decision for a visible initial Metal commit
/// whose drawable has not reached the display compositor within the caller's
/// fixed grace interval. The policy is pure: it neither requests frames nor
/// changes presentation readiness, pacing, input, or trace state.
package struct SpiceLiveInitialPresentationRecoveryPolicy: Sendable {
    package enum Action: Sendable, Equatable {
        case none
        case requestAuthoritativeLatest
    }

    package struct Observation: Sendable, Equatable {
        package let windowVisible: Bool
        package let subscriptionVisible: Bool
        package let committedDelta: UInt64
        package let presentedDelta: UInt64
        package let elapsedSinceFirstCommit: Duration

        package init(
            windowVisible: Bool,
            subscriptionVisible: Bool,
            committedDelta: UInt64,
            presentedDelta: UInt64,
            elapsedSinceFirstCommit: Duration
        ) {
            self.windowVisible = windowVisible
            self.subscriptionVisible = subscriptionVisible
            self.committedDelta = committedDelta
            self.presentedDelta = presentedDelta
            self.elapsedSinceFirstCommit = elapsedSinceFirstCommit
        }
    }

    private enum Phase: Sendable, Equatable {
        case observing
        case requested
        case presented
    }

    private let graceInterval: Duration
    private var phase: Phase = .observing

    package init(graceInterval: Duration) {
        self.graceInterval = graceInterval
    }

    package mutating func observe(_ observation: Observation) -> Action {
        guard phase == .observing else { return .none }
        if observation.presentedDelta > 0 {
            phase = .presented
            return .none
        }
        guard observation.windowVisible,
              observation.subscriptionVisible,
              observation.committedDelta > 0,
              observation.elapsedSinceFirstCommit >= graceInterval else {
            return .none
        }
        phase = .requested
        return .requestAuthoritativeLatest
    }
}
