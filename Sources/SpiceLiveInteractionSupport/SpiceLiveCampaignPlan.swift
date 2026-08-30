import CryptoKit
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
        steps: [SpiceLiveInteractionClusterPlan.Step]
    ) {
        self.campaignID = campaignID
        self.runID = runID
        self.version = version
        self.clusterID = clusterID
        self.sequence = sequence
        self.steps = steps
        freshBootRequired = true
        automaticRetryLimit = 0
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
        guard CampaignValidation.isCanonicalLowerHex(campaignID, count: 16),
              CampaignValidation.isCanonicalVersion(baselineVersion),
              CampaignValidation.isCanonicalVersion(candidateVersion),
              baselineVersion != candidateVersion,
              clusterIDs.count == 10,
              Set(clusterIDs).count == clusterIDs.count,
              clusterIDs.allSatisfy({
                  CampaignValidation.isCanonicalLowerHex($0, count: 16)
              }) else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }

        var generatedRuns: [SpiceLiveCampaignRun] = []
        generatedRuns.reserveCapacity(20)
        var planTokens = Set<String>()
        var planPairIDs = Set<String>()

        for (clusterIndex, clusterID) in clusterIDs.enumerated() {
            let steps = try CampaignValidation.completedSteps(clusterID: clusterID)
            for step in steps {
                guard planTokens.insert(step.token).inserted,
                      planPairIDs.insert(step.pairID).inserted else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
            }
            let versions = clusterIndex < clusterIDs.count / 2
                ? [baselineVersion, candidateVersion]
                : [candidateVersion, baselineVersion]
            for version in versions {
                let sequence = UInt64(generatedRuns.count + 1)
                let runID = CampaignValidation.digestHex(
                    "swiftspice-live-run-v1:\(campaignID):\(sequence):\(clusterID):\(version)",
                    byteCount: 8
                )
                generatedRuns.append(SpiceLiveCampaignRun(
                    campaignID: campaignID,
                    runID: runID,
                    version: version,
                    clusterID: clusterID,
                    sequence: sequence,
                    steps: steps
                ))
            }
        }
        guard generatedRuns.count == 20,
              Set(generatedRuns.map(\.runID)).count == generatedRuns.count else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }

        self.campaignID = campaignID
        self.baselineVersion = baselineVersion
        self.candidateVersion = candidateVersion
        self.clusterIDs = clusterIDs
        runs = generatedRuns
    }

    package func specification(
        pointerMode: SpicePointerMode
    ) throws -> SpicePairedInteractionArtifactSpecification {
        try SpicePairedInteractionArtifactSpecification(
            baselineVersion: baselineVersion,
            candidateVersion: candidateVersion,
            clusterIDs: clusterIDs,
            pointerMode: pointerMode,
            runSequence: runs.map {
                SpicePairedInteractionRunKey(
                    clusterID: $0.clusterID,
                    version: $0.version
                )
            }
        )
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
        run: SpiceLiveCampaignRun,
        step: SpiceLiveInteractionClusterPlan.Step,
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome
    ) {
        campaignID = run.campaignID
        runID = run.runID
        version = run.version
        clusterID = run.clusterID
        runSequence = run.sequence
        actionClass = step.actionClass
        order = step.order
        checksum = step.checksum
        token = step.token
        attemptNumber = 1
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

    package let plan: SpiceLiveCampaignPlan
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
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
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
              stage == expectedStage,
              entries.count < plan.runs.count * 13 else {
            phase = .failed
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let run = plan.runs[runIndex]
        let step = run.steps[stepIndex]
        entries.append(SpiceLiveAttemptLedgerEntry(
            run: run,
            step: step,
            stage: stage,
            outcome: outcome
        ))
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
            phase = .active(
                runIndex: runIndex,
                stepIndex: stepIndex,
                expectedStage: .arm
            )
        case .arm:
            phase = .active(
                runIndex: runIndex,
                stepIndex: stepIndex,
                expectedStage: .postArm
            )
        case .postArm:
            let nextStep = stepIndex + 1
            phase = run.steps.indices.contains(nextStep)
                ? .active(
                    runIndex: runIndex,
                    stepIndex: nextStep,
                    expectedStage: .preArm
                )
                : .active(
                    runIndex: runIndex,
                    stepIndex: stepIndex,
                    expectedStage: .teardown
                )
        case .teardown:
            let nextRun = runIndex + 1
            phase = plan.runs.indices.contains(nextRun)
                ? .ready(runIndex: nextRun)
                : .completed
        }
    }
}

private enum CampaignValidation {
    static func isCanonicalLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    static func isCanonicalVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.first == 118 else { return false }
        let components = bytes.dropFirst().split(
            separator: 46,
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                return false
            }
            return component.count == 1 || component.first != 48
        }
    }

    static func digestHex(_ material: String, byteCount: Int) -> String {
        SHA256.hash(data: Data(material.utf8)).prefix(byteCount).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func completedSteps(
        clusterID: String
    ) throws -> [SpiceLiveInteractionClusterPlan.Step] {
        var plan = try SpiceLiveInteractionClusterPlan(clusterID: clusterID)
        var steps: [SpiceLiveInteractionClusterPlan.Step] = []
        steps.reserveCapacity(3)
        for _ in 0..<3 {
            let step = try plan.beginNextStep()
            steps.append(step)
            try plan.recordExactPresentation(order: step.order)
            try plan.recordAppendCompleted(order: step.order)
        }
        return steps
    }
}
