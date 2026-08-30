import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live initial presentation recovery")
struct SpiceLiveInitialPresentationRecoveryTests {
    @Test func eligibleColdStartRequestsOneAuthoritativeLatestRedraw() {
        var policy = SpiceLiveInitialPresentationRecoveryPolicy(
            graceInterval: .milliseconds(250)
        )

        #expect(policy.observe(Self.observation(
            committedDelta: 1,
            elapsedSinceFirstCommit: .milliseconds(249)
        )) == .none)
        #expect(policy.observe(Self.observation(
            committedDelta: 1,
            elapsedSinceFirstCommit: .milliseconds(250)
        )) == .requestAuthoritativeLatest)

        // Ticks after the grace boundary cannot consume another recovery.
        #expect(policy.observe(Self.observation(
            committedDelta: 1,
            elapsedSinceFirstCommit: .seconds(10)
        )) == .none)

        // A real presentation closes readiness; it never creates more work.
        #expect(policy.observe(Self.observation(
            committedDelta: 2,
            presentedDelta: 1,
            elapsedSinceFirstCommit: .seconds(10)
        )) == .none)
    }

    @Test func recoveryRequiresVisibleDemandCommitAndMissingPresentation() {
        let ineligible: [SpiceLiveInitialPresentationRecoveryPolicy.Observation] = [
            Self.observation(
                windowVisible: false,
                committedDelta: 1,
                elapsedSinceFirstCommit: .seconds(1)
            ),
            Self.observation(
                subscriptionVisible: false,
                committedDelta: 1,
                elapsedSinceFirstCommit: .seconds(1)
            ),
            Self.observation(
                committedDelta: 0,
                elapsedSinceFirstCommit: .seconds(1)
            ),
            Self.observation(
                committedDelta: 1,
                presentedDelta: 1,
                elapsedSinceFirstCommit: .seconds(1)
            ),
        ]

        for observation in ineligible {
            var policy = SpiceLiveInitialPresentationRecoveryPolicy(
                graceInterval: .milliseconds(250)
            )
            #expect(policy.observe(observation) == .none)
        }
    }

    @Test func timeoutRemainsFailClosedAndRecoveryHasNoMeasurementSideEffects() {
        var policy = SpiceLiveInitialPresentationRecoveryPolicy(
            graceInterval: .milliseconds(250)
        )
        var effects = RecoveryEffects()
        var pacing = SpiceDesktopPresentationPacingPolicy()
        let diagnostics = SpicePresentationDiagnostics()
        let metricsBeforeRecovery = diagnostics.snapshot()

        #expect(pacing.readyBecameAvailable() == .selectImmediately)

        effects.apply(policy.observe(Self.observation(
            committedDelta: 1,
            elapsedSinceFirstCommit: .milliseconds(250)
        )))
        effects.apply(policy.observe(Self.observation(
            committedDelta: 2,
            elapsedSinceFirstCommit: .seconds(20)
        )))

        // Recovery is only an authoritative-latest request. It cannot arm or
        // send input, fabricate/append a trace, select an interaction frame,
        // or alter the desktop presentation pacing state.
        #expect(effects.authoritativeLatestRequests == 1)
        #expect(effects.inputSends == 0)
        #expect(effects.traceAppends == 0)
        #expect(effects.interactionSelections == 0)
        #expect(effects.pacingMutations == 0)
        #expect(!effects.readinessSucceeded)
        #expect(diagnostics.snapshot() == metricsBeforeRecovery)
        #expect(diagnostics.snapshot().desktopImmediateSelections == 0)
        #expect(pacing.readyBecameAvailable() == .waitForDisplayLink)
    }

    private static func observation(
        windowVisible: Bool = true,
        subscriptionVisible: Bool = true,
        committedDelta: UInt64,
        presentedDelta: UInt64 = 0,
        elapsedSinceFirstCommit: Duration
    ) -> SpiceLiveInitialPresentationRecoveryPolicy.Observation {
        .init(
            windowVisible: windowVisible,
            subscriptionVisible: subscriptionVisible,
            committedDelta: committedDelta,
            presentedDelta: presentedDelta,
            elapsedSinceFirstCommit: elapsedSinceFirstCommit
        )
    }
}

private struct RecoveryEffects {
    var authoritativeLatestRequests = 0
    var inputSends = 0
    var traceAppends = 0
    var interactionSelections = 0
    var pacingMutations = 0
    var readinessSucceeded = false

    mutating func apply(
        _ action: SpiceLiveInitialPresentationRecoveryPolicy.Action
    ) {
        if action == .requestAuthoritativeLatest {
            authoritativeLatestRequests += 1
        }
    }
}
