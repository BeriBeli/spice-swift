import Foundation
import SwiftSpice

package struct SpiceLiveCampaignRun: Sendable, Equatable {
    package let campaignID: String
    package let runID: String
    package let version: String
    package let clusterID: String
    package let sequence: UInt64
    package let steps: [SpiceLiveInteractionClusterPlan.Step]
    package let freshBootRequired: Bool
    package let automaticRetryLimit: Int

    fileprivate init(
        campaignID: String,
        runID: String,
        version: String,
        clusterID: String,
        sequence: UInt64,
        steps: [SpiceLiveInteractionClusterPlan.Step],
        freshBootRequired: Bool,
        automaticRetryLimit: Int
    ) {
        self.campaignID = campaignID
        self.runID = runID
        self.version = version
        self.clusterID = clusterID
        self.sequence = sequence
        self.steps = steps
        self.freshBootRequired = freshBootRequired
        self.automaticRetryLimit = automaticRetryLimit
    }
}

package struct SpiceLiveCampaignPlan: Sendable, Equatable {
    package let campaignID: String
    package let baselineVersion: String
    package let candidateVersion: String
    package let clusterIDs: [String]
    package let runs: [SpiceLiveCampaignRun]

    package init(
        campaignID: String,
        baselineVersion: String,
        candidateVersion: String,
        clusterIDs: [String]
    ) throws {
        guard SpiceLiveValidation.isCanonicalLowerHex(campaignID, count: 16),
              SpiceLiveValidation.isCanonicalVersion(baselineVersion),
              SpiceLiveValidation.isCanonicalVersion(candidateVersion),
              baselineVersion != candidateVersion,
              clusterIDs.count == 10,
              Set(clusterIDs).count == clusterIDs.count,
              clusterIDs.allSatisfy({
                  SpiceLiveValidation.isCanonicalLowerHex($0, count: 16)
              }) else {
            throw SpiceLiveInteractionSupportError.invalidCampaignPlan
        }

        var runs: [SpiceLiveCampaignRun] = []
        runs.reserveCapacity(clusterIDs.count * 2)
        var sequence: UInt64 = 1
        var planTokens = Set<String>()
        var planPairIDs = Set<String>()
        for (clusterIndex, clusterID) in clusterIDs.enumerated() {
            let cluster = try SpiceLiveInteractionClusterPlan(clusterID: clusterID)
            for step in cluster.steps {
                guard planTokens.insert(step.token).inserted,
                      planPairIDs.insert(step.pairID).inserted else {
                    throw SpiceLiveInteractionSupportError.invalidCampaignPlan
                }
            }
            let versions = clusterIndex < clusterIDs.count / 2
                ? [baselineVersion, candidateVersion]
                : [candidateVersion, baselineVersion]
            for version in versions {
                let runID = SpiceLiveValidation.digestHex(
                    "swiftspice-live-run-v1:\(campaignID):\(sequence):\(clusterID):\(version)",
                    byteCount: 8
                )
                runs.append(
                    SpiceLiveCampaignRun(
                        campaignID: campaignID,
                        runID: runID,
                        version: version,
                        clusterID: clusterID,
                        sequence: sequence,
                        steps: cluster.steps,
                        freshBootRequired: true,
                        automaticRetryLimit: 0
                    )
                )
                sequence += 1
            }
        }
        guard runs.count == 20,
              Set(runs.map(\.runID)).count == runs.count else {
            throw SpiceLiveInteractionSupportError.invalidCampaignPlan
        }
        self.campaignID = campaignID
        self.baselineVersion = baselineVersion
        self.candidateVersion = candidateVersion
        self.clusterIDs = clusterIDs
        self.runs = runs
    }
}

package enum SpiceLiveAttemptStage: String, Codable, Sendable, Equatable {
    case fixtureStop = "fixture_stop"
    case fixtureStart = "fixture_start"
    case fixtureHealth = "fixture_health"
    case preArm = "pre_arm"
    case arm
    case postArm = "post_arm"
    case teardown
}

package enum SpiceLiveAttemptOutcome: String, Codable, Sendable, Equatable {
    case succeeded
    case failed
}

package struct SpiceLiveAttemptLedgerEntry: Codable, Sendable, Equatable {
    package let campaignID: String
    package let runID: String
    package let version: String
    package let clusterID: String
    package let runSequence: UInt64
    package let actionClass: SpiceInteractionActionClass
    package let order: UInt64
    package let checksum: UInt32
    package let token: String
    package let attemptNumber: UInt64
    package let stage: SpiceLiveAttemptStage
    package let outcome: SpiceLiveAttemptOutcome

    fileprivate init(
        campaignID: String,
        runID: String,
        version: String,
        clusterID: String,
        runSequence: UInt64,
        actionClass: SpiceInteractionActionClass,
        order: UInt64,
        checksum: UInt32,
        token: String,
        attemptNumber: UInt64,
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome
    ) {
        self.campaignID = campaignID
        self.runID = runID
        self.version = version
        self.clusterID = clusterID
        self.runSequence = runSequence
        self.actionClass = actionClass
        self.order = order
        self.checksum = checksum
        self.token = token
        self.attemptNumber = attemptNumber
        self.stage = stage
        self.outcome = outcome
    }

    enum CodingKeys: String, CodingKey {
        case campaignID = "campaign_id"
        case runID = "run_id"
        case version
        case clusterID = "cluster_id"
        case runSequence = "run_sequence"
        case actionClass = "action_class"
        case order
        case checksum
        case token
        case attemptNumber = "attempt_number"
        case stage
        case outcome
    }
}

package struct SpiceLiveCampaignExecution: Sendable {
    private enum Phase: Sendable {
        case ready(runIndex: Int)
        case active(
            runIndex: Int,
            stepIndex: Int,
            expectedStage: SpiceLiveAttemptStage
        )
        case completed
        case failed
    }

    private let plan: SpiceLiveCampaignPlan
    private var phase: Phase = .ready(runIndex: 0)
    package private(set) var entries: [SpiceLiveAttemptLedgerEntry] = []

    package var campaignFailed: Bool {
        if case .failed = phase { true } else { false }
    }

    package var campaignCompleted: Bool {
        if case .completed = phase { true } else { false }
    }

    package init(plan: SpiceLiveCampaignPlan) {
        self.plan = plan
        entries.reserveCapacity(plan.runs.count * 13)
    }

    package mutating func beginNextRun() throws -> SpiceLiveCampaignRun {
        guard case let .ready(runIndex) = phase,
              plan.runs.indices.contains(runIndex) else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidExecutionTransition
        }
        phase = .active(
            runIndex: runIndex,
            stepIndex: 0,
            expectedStage: .fixtureStop
        )
        return plan.runs[runIndex]
    }

    package mutating func record(
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome
    ) throws {
        guard case let .active(runIndex, stepIndex, expectedStage) = phase,
              stage == expectedStage else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidExecutionTransition
        }
        let run = plan.runs[runIndex]
        let step = run.steps[stepIndex]
        guard entries.count < plan.runs.count * 13 else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidExecutionTransition
        }
        entries.append(
            SpiceLiveAttemptLedgerEntry(
                campaignID: run.campaignID,
                runID: run.runID,
                version: run.version,
                clusterID: run.clusterID,
                runSequence: run.sequence,
                actionClass: step.actionClass,
                order: step.order,
                checksum: step.checksum,
                token: step.token,
                attemptNumber: 1,
                stage: stage,
                outcome: outcome
            )
        )
        guard outcome == .succeeded else {
            phase = .failed
            return
        }

        switch stage {
        case .fixtureStop:
            phase = .active(
                runIndex: runIndex,
                stepIndex: stepIndex,
                expectedStage: .fixtureStart
            )
        case .fixtureStart:
            phase = .active(
                runIndex: runIndex,
                stepIndex: stepIndex,
                expectedStage: .fixtureHealth
            )
        case .fixtureHealth:
            phase = .active(
                runIndex: runIndex,
                stepIndex: stepIndex,
                expectedStage: .preArm
            )
        case .preArm:
            phase = .active(runIndex: runIndex, stepIndex: stepIndex, expectedStage: .arm)
        case .arm:
            phase = .active(runIndex: runIndex, stepIndex: stepIndex, expectedStage: .postArm)
        case .postArm:
            let nextStep = stepIndex + 1
            phase = run.steps.indices.contains(nextStep)
                ? .active(runIndex: runIndex, stepIndex: nextStep, expectedStage: .preArm)
                : .active(runIndex: runIndex, stepIndex: stepIndex, expectedStage: .teardown)
        case .teardown:
            let nextRun = runIndex + 1
            phase = plan.runs.indices.contains(nextRun)
                ? .ready(runIndex: nextRun)
                : .completed
        }
    }
}
