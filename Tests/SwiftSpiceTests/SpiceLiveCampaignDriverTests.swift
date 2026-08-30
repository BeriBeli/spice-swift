import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live paired campaign driver")
struct SpiceLiveCampaignDriverTests {
    private static let campaignID = "a10000000000000f"

    @Test func planIsExactCounterbalancedFreshBootAndZeroRetry() throws {
        let plan = try Self.plan()
        let specification = try Self.pairedSpecification()
        #expect(plan.runs.count == 20)
        #expect(plan.runs.flatMap(\.steps).count == 60)
        #expect(plan.runs.map(\.sequence) == Array(1...20).map(UInt64.init))
        #expect(Set(plan.runs.map(\.runID)).count == 20)

        for (clusterIndex, clusterID) in specification.clusterIDs.enumerated() {
            let offset = clusterIndex * 2
            let pair = Array(plan.runs[offset...(offset + 1)])
            #expect(pair.map(\.clusterID) == [clusterID, clusterID])
            #expect(pair.allSatisfy { $0.freshBootRequired })
            #expect(pair.allSatisfy { $0.automaticRetryLimit == 0 })
            #expect(pair[0].steps == pair[1].steps)
            #expect(pair[0].steps.map(\.order) == [1, 2, 3])
            #expect(pair[0].steps.map(\.actionClass) == [.click, .key, .motion])
            #expect(pair.map(\.version) == (clusterIndex < 5
                ? [specification.baselineVersion, specification.candidateVersion]
                : [specification.candidateVersion, specification.baselineVersion]))
        }
    }

    @Test func successfulCampaignProducesExactlyThirteenStagesPerRun() throws {
        let plan = try Self.plan()
        var execution = SpiceLiveCampaignExecution(plan: plan)
        for expectedRun in plan.runs {
            #expect(try execution.beginNextRun() == expectedRun)
            for stage in Self.stageSequence {
                try execution.record(stage: stage, outcome: .succeeded)
            }
        }

        #expect(execution.campaignCompleted)
        #expect(!execution.campaignFailed)
        #expect(execution.entries.count == 260)
        #expect(execution.entries.allSatisfy { $0.attemptNumber == 1 })
        for runIndex in plan.runs.indices {
            let offset = runIndex * Self.stageSequence.count
            let entries = Array(execution.entries[offset..<(offset + 13)])
            #expect(entries.map(\.stage) == Self.stageSequence)
            #expect(entries.allSatisfy { $0.runID == plan.runs[runIndex].runID })
        }
    }

    @Test func everyStageFailureIsRecordedAndPermanentlyTerminal() throws {
        let plan = try Self.plan()
        for failedOffset in Self.stageSequence.indices {
            var execution = SpiceLiveCampaignExecution(plan: plan)
            _ = try execution.beginNextRun()
            for stage in Self.stageSequence[..<failedOffset] {
                try execution.record(stage: stage, outcome: .succeeded)
            }
            try execution.record(
                stage: Self.stageSequence[failedOffset],
                outcome: .failed
            )
            #expect(execution.campaignFailed)
            #expect(!execution.campaignCompleted)
            #expect(execution.entries.count == failedOffset + 1)
            #expect(execution.entries.last?.outcome == .failed)
            #expect(throws: (any Error).self) { _ = try execution.beginNextRun() }
            #expect(throws: (any Error).self) {
                try execution.record(
                    stage: Self.stageSequence[failedOffset],
                    outcome: .succeeded
                )
            }
        }
    }

    @Test func completeCanonicalArtifactInvokesStrictEvaluator() throws {
        let campaign = try Self.plan()
        let fixture = try SpicePairedInteractionArtifactTests.makeFixture(
            pointerMode: .absolute
        )
        var accumulator = SpiceLiveCampaignArtifactAccumulator(
            plan: campaign,
            pointerMode: .absolute
        )
        try Self.fill(&accumulator, campaign: campaign, fixture: fixture)
        let execution = try Self.completedExecution(for: campaign)
        let report = try accumulator.evaluate(execution: execution)

        #expect(report.recordCount == 60)
        #expect(report.runCount == 20)
        #expect(report.observations.count == 60)
        #expect(report.resourceGuardrails.observations.count == 20)
        for runIndex in campaign.runs.indices {
            let evidenceID = fixture.records[runIndex * 3].runId
            #expect(accumulator.evidenceRunID(
                forLogicalRunID: campaign.runs[runIndex].runID
            ) == evidenceID)
            #expect(evidenceID != campaign.runs[runIndex].runID)
        }
    }

    @Test func artifactRequiresMatchingCompletedSuccessfulExecution() throws {
        let campaign = try Self.plan()
        let fixture = try SpicePairedInteractionArtifactTests.makeFixture(
            pointerMode: .absolute
        )
        var accumulator = SpiceLiveCampaignArtifactAccumulator(
            plan: campaign,
            pointerMode: .absolute
        )
        try Self.fill(&accumulator, campaign: campaign, fixture: fixture)

        var incomplete = SpiceLiveCampaignExecution(plan: campaign)
        _ = try incomplete.beginNextRun()
        #expect(throws: (any Error).self) {
            _ = try accumulator.evaluate(execution: incomplete)
        }

        var failed = SpiceLiveCampaignExecution(plan: campaign)
        _ = try failed.beginNextRun()
        try failed.record(stage: .fixtureStop, outcome: .failed)
        #expect(throws: (any Error).self) {
            _ = try accumulator.evaluate(execution: failed)
        }

        let differentPlan = try SpiceLiveCampaignPlan(
            campaignID: "b10000000000000f",
            baselineVersion: fixture.specification.baselineVersion,
            candidateVersion: fixture.specification.candidateVersion,
            clusterIDs: fixture.specification.clusterIDs
        )
        let wrongExecution = try Self.completedExecution(for: differentPlan)
        #expect(throws: (any Error).self) {
            _ = try accumulator.evaluate(execution: wrongExecution)
        }
    }

    @Test func incompleteDuplicateReorderedOrExtraArtifactsFailClosed() throws {
        for failure in ArtifactFailure.allCases {
            let campaign = try Self.plan()
            let fixture = try SpicePairedInteractionArtifactTests.makeFixture(
                pointerMode: .absolute
            )
            #expect(throws: (any Error).self) {
                try Self.exerciseFailure(
                    failure,
                    campaign: campaign,
                    fixture: fixture
                )
            }
        }
    }
}

private extension SpiceLiveCampaignDriverTests {
    enum ArtifactFailure: CaseIterable, Sendable {
        case missingRun
        case duplicateLogicalRun
        case duplicateEvidenceRun
        case reorderedRun
        case extraRecord
        case noncanonicalRecord
        case missingResource
        case duplicateResource
        case nonfiniteResource
    }

    static let stageSequence: [SpiceLiveAttemptStage] = [
        .fixtureStop,
        .fixtureStart,
        .fixtureHealth,
        .preArm, .arm, .postArm,
        .preArm, .arm, .postArm,
        .preArm, .arm, .postArm,
        .teardown,
    ]

    static func plan() throws -> SpiceLiveCampaignPlan {
        let specification = try pairedSpecification()
        try SpiceLiveCampaignPlan(
            campaignID: campaignID,
            baselineVersion: specification.baselineVersion,
            candidateVersion: specification.candidateVersion,
            clusterIDs: specification.clusterIDs
        )
    }

    static func pairedSpecification() throws -> SpicePairedInteractionArtifactSpecification {
        try SpicePairedInteractionArtifactTests.makeFixture(
            pointerMode: .absolute
        ).specification
    }

    static func fill(
        _ accumulator: inout SpiceLiveCampaignArtifactAccumulator,
        campaign: SpiceLiveCampaignPlan,
        fixture: SpicePairedInteractionArtifactTests.Fixture
    ) throws {
        for runIndex in campaign.runs.indices {
            try recordRun(
                runIndex,
                in: &accumulator,
                campaign: campaign,
                fixture: fixture
            )
        }
    }

    static func completedExecution(
        for plan: SpiceLiveCampaignPlan
    ) throws -> SpiceLiveCampaignExecution {
        var execution = SpiceLiveCampaignExecution(plan: plan)
        for _ in plan.runs {
            _ = try execution.beginNextRun()
            for stage in stageSequence {
                try execution.record(stage: stage, outcome: .succeeded)
            }
        }
        return execution
    }

    static func exerciseFailure(
        _ failure: ArtifactFailure,
        campaign: SpiceLiveCampaignPlan,
        fixture: SpicePairedInteractionArtifactTests.Fixture
    ) throws {
        var accumulator = SpiceLiveCampaignArtifactAccumulator(
            plan: campaign,
            pointerMode: .absolute
        )
        let execution = try completedExecution(for: campaign)
        switch failure {
        case .missingRun:
            for runIndex in campaign.runs.indices.dropLast() {
                try recordRun(
                    runIndex,
                    in: &accumulator,
                    campaign: campaign,
                    fixture: fixture
                )
            }
            _ = try accumulator.evaluate(execution: execution)
        case .duplicateLogicalRun:
            try recordRun(0, in: &accumulator, campaign: campaign, fixture: fixture)
            try recordRun(0, in: &accumulator, campaign: campaign, fixture: fixture)
        case .duplicateEvidenceRun:
            try recordRun(0, in: &accumulator, campaign: campaign, fixture: fixture)
            let secondRecords = Array(fixture.records[3..<6])
            try accumulator.recordRun(
                logicalRunID: campaign.runs[1].runID,
                evidenceRunID: fixture.records[0].runId,
                canonicalRecords: try secondRecords.map(canonicalLine)
            )
        case .reorderedRun:
            try recordRun(1, in: &accumulator, campaign: campaign, fixture: fixture)
        case .extraRecord:
            var records = Array(fixture.records[0..<3])
            records.append(records[0])
            try accumulator.recordRun(
                logicalRunID: campaign.runs[0].runID,
                evidenceRunID: records[0].runId,
                canonicalRecords: try records.map(canonicalLine)
            )
        case .noncanonicalRecord:
            var lines = try fixture.records[0..<3].map(canonicalLine)
            lines[0].insert(0x20, at: 0)
            try accumulator.recordRun(
                logicalRunID: campaign.runs[0].runID,
                evidenceRunID: fixture.records[0].runId,
                canonicalRecords: lines
            )
        case .missingResource:
            for runIndex in campaign.runs.indices {
                let offset = runIndex * 3
                let records = Array(fixture.records[offset..<(offset + 3)])
                try accumulator.recordRun(
                    logicalRunID: campaign.runs[runIndex].runID,
                    evidenceRunID: records[0].runId,
                    canonicalRecords: try records.map(canonicalLine)
                )
            }
            _ = try accumulator.evaluate(execution: execution)
        case .duplicateResource:
            try accumulator.recordResourceSample(
                logicalRunID: campaign.runs[0].runID,
                sample: fixture.resources[0]
            )
            try accumulator.recordResourceSample(
                logicalRunID: campaign.runs[0].runID,
                sample: fixture.resources[0]
            )
        case .nonfiniteResource:
            try accumulator.recordResourceSample(
                logicalRunID: campaign.runs[0].runID,
                sample: SpicePairedInteractionResourceSample(
                    runId: fixture.resources[0].runId,
                    cpuPercent: .nan,
                    peakRSSBytes: fixture.resources[0].peakRSSBytes
                )
            )
        }
    }

    static func recordRun(
        _ runIndex: Int,
        in accumulator: inout SpiceLiveCampaignArtifactAccumulator,
        campaign: SpiceLiveCampaignPlan,
        fixture: SpicePairedInteractionArtifactTests.Fixture
    ) throws {
        let offset = runIndex * 3
        let records = Array(fixture.records[offset..<(offset + 3)])
        try accumulator.recordRun(
            logicalRunID: campaign.runs[runIndex].runID,
            evidenceRunID: records[0].runId,
            canonicalRecords: try records.map(canonicalLine)
        )
        try accumulator.recordResourceSample(
            logicalRunID: campaign.runs[runIndex].runID,
            sample: fixture.resources[runIndex]
        )
    }

    static func canonicalLine(_ record: SpiceInteractionTraceRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try encoder.encode(record)
        line.append(0x0a)
        return line
    }
}
