import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Paired interaction artifact acceptance")
struct SpicePairedInteractionArtifactTests {
    private static let baselineVersion = "v0.2.7"
    private static let candidateVersion = "v0.3.3"

    @Test func acceptsExactlyTenCompletePairedClustersAndPreservesStages() throws {
        let fixture = try Self.makeFixture(pointerMode: .absolute)
        let report = try SpicePairedInteractionArtifactEvaluator.evaluate(
            records: fixture.records,
            resourceSamples: fixture.resources,
            specification: fixture.specification
        )

        #expect(report.recordCount == 60)
        #expect(report.runCount == 20)
        var expectedPairIDs: [String] = []
        var expectedTokens: [String] = []

        for actionClass in Self.actions {
            let summary = report.summary(for: actionClass)
            #expect(summary.pairs.count == 10)
            for (offset, pair) in summary.pairs.enumerated() {
                let clusterID = fixture.clusterIDs[offset]
                let expectedStep = try Self.step(
                    clusterID: clusterID,
                    actionClass: actionClass
                )
                expectedPairIDs.append(expectedStep.pairID)
                expectedTokens.append(expectedStep.token)
                #expect(pair.clusterID == clusterID)
                #expect(pair.baseline.record.version == Self.baselineVersion)
                #expect(pair.candidate.record.version == Self.candidateVersion)
                #expect(pair.baseline.record.pairId == expectedStep.pairID)
                #expect(pair.candidate.record.pairId == expectedStep.pairID)
                #expect(pair.baseline.record.token == expectedStep.token)
                #expect(pair.candidate.record.token == expectedStep.token)
                #expect(pair.baseline.record.markerChecksum == String(
                    format: "%08x",
                    expectedStep.checksum
                ))
                #expect(pair.candidate.record.markerChecksum == String(
                    format: "%08x",
                    expectedStep.checksum
                ))

                let stages = pair.candidate.stages
                #expect(stages.scheduledToHostInputNanoseconds == 100)
                #expect(stages.hostInputToSendStartedNanoseconds == 100)
                #expect(stages.sendStartedToCompletedNanoseconds == 100)
                #expect(stages.sendCompletedToDisplayNanoseconds == 100)
                #expect(stages.displayToSurfaceReadyNanoseconds == 100)
                #expect(stages.surfaceReadyToSelectedReadyNanoseconds == 100)
                #expect(stages.selectedReadyToSelectionNanoseconds == 100)
                #expect(stages.selectionToCommitNanoseconds == 100)
                #expect(stages.commitToPresentedNanoseconds
                    == pair.candidate.record.presentedNs! - pair.candidate.record.metalCommitNs!)
                #expect(stages.inputToPresentedNanoseconds
                    == pair.candidate.record.presentedNs! - pair.candidate.record.hostInputNs!)
                #expect(stages.guestMarkerDrawNanoseconds == 1_000)
            }
        }
        #expect(Set(expectedPairIDs).count == 30)
        #expect(Set(expectedTokens).count == 30)
    }

    @Test func computesTypeSevenQuantilesAndSignedPairedDeltas() throws {
        let fixture = try Self.makeFixture(pointerMode: .absolute)
        let report = try SpicePairedInteractionArtifactEvaluator.evaluate(
            records: fixture.records,
            resourceSamples: fixture.resources,
            specification: fixture.specification
        )

        let click = report.summary(for: .click)
        #expect(click.baselineInputToPresented.p50Nanoseconds == 55_000_000)
        Self.expectQuantile(click.baselineInputToPresented.p95Nanoseconds, 95_500_000)
        #expect(click.candidateInputToPresented.p50Nanoseconds == 60_000_000)
        Self.expectQuantile(click.candidateInputToPresented.p95Nanoseconds, 100_500_000)
        #expect(click.pairedInputToPresentedDelta.p50Nanoseconds == 5_000_000)
        #expect(click.pairedInputToPresentedDelta.p95Nanoseconds == 5_000_000)
        #expect(click.pairs.map(\.inputToPresentedDeltaNanoseconds)
            == Array(repeating: 5_000_000, count: 10))

        let key = report.summary(for: .key)
        #expect(key.baselineInputToPresented.p50Nanoseconds == 110_000_000)
        Self.expectQuantile(key.baselineInputToPresented.p95Nanoseconds, 191_000_000)
        #expect(key.candidateInputToPresented.p50Nanoseconds == 100_000_000)
        Self.expectQuantile(key.candidateInputToPresented.p95Nanoseconds, 181_000_000)
        #expect(key.pairedInputToPresentedDelta.p50Nanoseconds == -10_000_000)
        #expect(key.pairedInputToPresentedDelta.p95Nanoseconds == -10_000_000)

        let motion = report.summary(for: .motion)
        #expect(motion.baselineInputToPresented.p50Nanoseconds == 165_000_000)
        Self.expectQuantile(motion.baselineInputToPresented.p95Nanoseconds, 286_500_000)
        #expect(motion.candidateInputToPresented.p50Nanoseconds == 167_000_000)
        Self.expectQuantile(motion.candidateInputToPresented.p95Nanoseconds, 288_500_000)
        #expect(motion.pairedInputToPresentedDelta.p50Nanoseconds == 2_000_000)
        #expect(motion.pairedInputToPresentedDelta.p95Nanoseconds == 2_000_000)
    }

    @Test func acceptsDisplayReceiveBeforeSendContinuationCompletion() throws {
        var fixture = try Self.makeFixture(pointerMode: .absolute)
        let original = fixture.records[0]
        fixture.records[0] = try Self.replacing(
            original,
            key: "display_receive_ns",
            value: original.sendStartedNs! + 1
        )

        let report = try SpicePairedInteractionArtifactEvaluator.evaluate(
            records: fixture.records,
            resourceSamples: fixture.resources,
            specification: fixture.specification
        )
        let pair = try #require(report.summary(for: .click).pairs.first)
        #expect(pair.baseline.record.valid)
        #expect(pair.baseline.record.displayReceiveNs! < pair.baseline.record.sendCompletedNs!)
        #expect(pair.baseline.stages.sendCompletedToDisplayNanoseconds == 0)
    }

    @Test(arguments: ArtifactMutation.allCases)
    func rejectsStructurallyInvalidArtifacts(_ mutation: ArtifactMutation) throws {
        var fixture = try Self.makeFixture(pointerMode: .absolute)
        let expected = mutation.apply(to: &fixture)

        Self.expectArtifactError(expected) {
            try SpicePairedInteractionArtifactEvaluator.evaluate(
                records: fixture.records,
                resourceSamples: fixture.resources,
                specification: fixture.specification
            )
        }
    }

    @Test(arguments: IdentityMutation.allCases)
    func rejectsPairTokenOrChecksumMismatch(_ mutation: IdentityMutation) throws {
        var fixture = try Self.makeFixture(pointerMode: .absolute)
        try mutation.apply(to: &fixture.records[3])

        Self.expectArtifactError(.identityMismatch) {
            try SpicePairedInteractionArtifactEvaluator.evaluate(
                records: fixture.records,
                resourceSamples: fixture.resources,
                specification: fixture.specification
            )
        }
    }

    @Test(arguments: AcknowledgementMutation.allCases)
    func rejectsPointerModeAcknowledgementMismatch(
        _ mutation: AcknowledgementMutation
    ) throws {
        var fixture = try Self.makeFixture(pointerMode: mutation.pointerMode)
        try mutation.apply(to: &fixture.records)

        Self.expectArtifactError(.acknowledgementMismatch) {
            try SpicePairedInteractionArtifactEvaluator.evaluate(
                records: fixture.records,
                resourceSamples: fixture.resources,
                specification: fixture.specification
            )
        }
    }

    @Test func resourceGuardrailsCannotChangeLatencyPairingOrQuantiles() throws {
        let fixture = try Self.makeFixture(pointerMode: .absolute)
        let first = try SpicePairedInteractionArtifactEvaluator.evaluate(
            records: fixture.records,
            resourceSamples: fixture.resources,
            specification: fixture.specification
        )
        let changedResources = fixture.resources.map {
            SpicePairedInteractionResourceSample(
                runId: $0.runId,
                cpuPercent: $0.cpuPercent + 25,
                peakRSSBytes: $0.peakRSSBytes + 64 * 1_024 * 1_024
            )
        }
        let second = try SpicePairedInteractionArtifactEvaluator.evaluate(
            records: fixture.records,
            resourceSamples: changedResources,
            specification: fixture.specification
        )

        for actionClass in Self.actions {
            #expect(first.summary(for: actionClass) == second.summary(for: actionClass))
        }
        #expect(first.resourceGuardrails != second.resourceGuardrails)
    }

    @Test func rejectsMissingResourceGuardrailCoverage() throws {
        var fixture = try Self.makeFixture(pointerMode: .absolute)
        fixture.resources.removeLast()

        Self.expectArtifactError(.missingResourceSample) {
            try SpicePairedInteractionArtifactEvaluator.evaluate(
                records: fixture.records,
                resourceSamples: fixture.resources,
                specification: fixture.specification
            )
        }
    }

    @Test(arguments: ResourceValueMutation.allCases)
    func rejectsNonFiniteOrNegativeResourceSamples(
        _ mutation: ResourceValueMutation
    ) throws {
        var fixture = try Self.makeFixture(pointerMode: .absolute)
        let original = fixture.resources[0]
        fixture.resources[0] = SpicePairedInteractionResourceSample(
            runId: original.runId,
            cpuPercent: mutation.cpuPercent,
            peakRSSBytes: original.peakRSSBytes
        )

        Self.expectArtifactError(.invalidResourceSample) {
            try SpicePairedInteractionArtifactEvaluator.evaluate(
                records: fixture.records,
                resourceSamples: fixture.resources,
                specification: fixture.specification
            )
        }
    }

    @Test func rejectsTimestampUnderflowBeforeDerivingStages() throws {
        var fixture = try Self.makeFixture(pointerMode: .absolute)
        fixture.records[0] = Self.replacingPresentedWithUnderflow(fixture.records[0])
        #expect(!fixture.records[0].valid)

        Self.expectArtifactError(.invalidRecord) {
            try SpicePairedInteractionArtifactEvaluator.evaluate(
                records: fixture.records,
                resourceSamples: fixture.resources,
                specification: fixture.specification
            )
        }
    }

    @Test(arguments: SpecificationMutation.allCases)
    func rejectsNonCanonicalOrIncompleteSpecifications(
        _ mutation: SpecificationMutation
    ) throws {
        let clusterIDs = (1...10).map { String(format: "%016x", $0) }
        let mutatedClusters = mutation.clusterIDs(from: clusterIDs)
        let runSequence = mutation.runSequence(
            clusterIDs: mutatedClusters,
            baselineVersion: Self.baselineVersion,
            candidateVersion: Self.candidateVersion
        )

        do {
            _ = try SpicePairedInteractionArtifactSpecification(
                baselineVersion: Self.baselineVersion,
                candidateVersion: Self.candidateVersion,
                clusterIDs: mutatedClusters,
                pointerMode: .absolute,
                runSequence: runSequence
            )
            Issue.record("invalid paired specification unexpectedly passed")
        } catch let error as SpicePairedInteractionArtifactError {
            #expect(error == .invalidSpecification)
        } catch {
            Issue.record("unexpected specification error: \(error)")
        }
    }
}

extension SpicePairedInteractionArtifactTests {
    static let actions: [SpiceInteractionActionClass] = [.click, .key, .motion]

    struct Fixture {
        let clusterIDs: [String]
        let specification: SpicePairedInteractionArtifactSpecification
        var records: [SpiceInteractionTraceRecord]
        var resources: [SpicePairedInteractionResourceSample]
    }

    enum ArtifactMutation: CaseIterable, Sendable, CustomTestStringConvertible {
        case duplicate
        case missing
        case reordered
        case actionSwap
        case versionAlias
        case thirdVersion
        case runReuse
        case extra
        case invalidColdStart

        var testDescription: String { String(describing: self) }

        func apply(to fixture: inout Fixture) -> SpicePairedInteractionArtifactError {
            switch self {
            case .duplicate:
                fixture.records.append(fixture.records[0])
                return .duplicateObservation
            case .missing:
                fixture.records.removeLast()
                return .missingObservation
            case .reordered:
                fixture.records.swapAt(0, 1)
                return .reorderedObservation
            case .actionSwap:
                fixture.records[0] = try! replacing(
                    fixture.records[0],
                    key: "action_class",
                    value: SpiceInteractionActionClass.key.rawValue
                )
                return .identityMismatch
            case .versionAlias:
                replaceVersion(in: &fixture.records, indices: 3..<6, with: "v0.3.03")
                return .unexpectedVersion
            case .thirdVersion:
                replaceVersion(in: &fixture.records, indices: 3..<6, with: "v9.9.9")
                return .unexpectedVersion
            case .runReuse:
                let reused = fixture.records[0].runId
                for index in 3..<6 {
                    fixture.records[index] = try! replacing(
                        fixture.records[index],
                        key: "run_id",
                        value: reused
                    )
                }
                return .reusedRunID
            case .extra:
                var extra = try! replacing(
                    fixture.records[0],
                    key: "pair_id",
                    value: "live-ffffffffffffffff-1-click"
                )
                extra = try! replacing(extra, key: "run_id", value: "run-extra")
                fixture.records.append(extra)
                return .unexpectedObservation
            case .invalidColdStart:
                fixture.records.append(invalidColdStartRecord())
                return .invalidRecord
            }
        }

        private func replaceVersion(
            in records: inout [SpiceInteractionTraceRecord],
            indices: Range<Int>,
            with version: String
        ) {
            for index in indices {
                records[index] = try! replacing(
                    records[index],
                    key: "version",
                    value: version
                )
            }
        }
    }

    enum IdentityMutation: CaseIterable, Sendable, CustomTestStringConvertible {
        case pairID
        case token
        case checksum

        var testDescription: String { String(describing: self) }

        func apply(to record: inout SpiceInteractionTraceRecord) throws {
            switch self {
            case .pairID:
                record = try replacing(record, key: "pair_id", value: "wrong-pair")
            case .token:
                record = try replacing(
                    record,
                    key: "token",
                    value: "ffffffffffffffff"
                )
            case .checksum:
                record = try replacing(
                    record,
                    key: "marker_checksum",
                    value: "00000000"
                )
            }
        }
    }

    enum AcknowledgementMutation:
        CaseIterable, Equatable, Sendable, CustomTestStringConvertible
    {
        case absoluteMotionHasACK
        case relativeMotionMissingACK
        case clickHasACK

        var testDescription: String { String(describing: self) }

        var pointerMode: SpicePointerMode {
            self == .relativeMotionMissingACK ? .relative : .absolute
        }

        func apply(to records: inout [SpiceInteractionTraceRecord]) throws {
            let action: SpiceInteractionActionClass = self == .clickHasACK ? .click : .motion
            let index = records.firstIndex { $0.actionClass == action }!
            switch self {
            case .relativeMotionMissingACK:
                records[index] = try replacing(
                    records[index],
                    key: "motion_ack_ns",
                    value: nil
                )
            case .absoluteMotionHasACK, .clickHasACK:
                records[index] = try replacing(
                    records[index],
                    key: "motion_ack_ns",
                    value: records[index].sendStartedNs! + 1
                )
            }
        }
    }

    enum ResourceValueMutation: CaseIterable, Sendable, CustomTestStringConvertible {
        case negative
        case notANumber

        var testDescription: String { String(describing: self) }

        var cpuPercent: Double {
            switch self {
            case .negative: -0.5
            case .notANumber: .nan
            }
        }
    }

    enum SpecificationMutation:
        CaseIterable, Equatable, Sendable, CustomTestStringConvertible
    {
        case nonCanonicalCluster
        case duplicateCluster
        case incompleteRunSequence

        var testDescription: String { String(describing: self) }

        func clusterIDs(from canonical: [String]) -> [String] {
            var result = canonical
            switch self {
            case .nonCanonicalCluster:
                result[0] = "ABCDEF0123456789"
            case .duplicateCluster:
                result[9] = result[0]
            case .incompleteRunSequence:
                break
            }
            return result
        }

        func runSequence(
            clusterIDs: [String],
            baselineVersion: String,
            candidateVersion: String
        ) -> [SpicePairedInteractionRunKey] {
            var result = clusterIDs.flatMap { clusterID in
                [baselineVersion, candidateVersion].map {
                    SpicePairedInteractionRunKey(clusterID: clusterID, version: $0)
                }
            }
            if self == .incompleteRunSequence {
                result.removeLast()
            }
            return result
        }
    }

    static func makeFixture(pointerMode: SpicePointerMode) throws -> Fixture {
        let clusterIDs = (1...10).map { String(format: "%016x", $0) }
        var runSequence: [SpicePairedInteractionRunKey] = []
        for (offset, clusterID) in clusterIDs.enumerated() {
            let versions = offset < 5
                ? [baselineVersion, candidateVersion]
                : [candidateVersion, baselineVersion]
            runSequence.append(contentsOf: versions.map {
                SpicePairedInteractionRunKey(clusterID: clusterID, version: $0)
            })
        }
        let specification = try SpicePairedInteractionArtifactSpecification(
            baselineVersion: baselineVersion,
            candidateVersion: candidateVersion,
            clusterIDs: clusterIDs,
            pointerMode: pointerMode,
            runSequence: runSequence
        )

        var records: [SpiceInteractionTraceRecord] = []
        var resources: [SpicePairedInteractionResourceSample] = []
        for (runOffset, runKey) in runSequence.enumerated() {
            let clusterOffset = clusterIDs.firstIndex(of: runKey.clusterID)!
            let steps = try completedSteps(clusterID: runKey.clusterID)
            let runID = "run-\(runKey.clusterID)-\(runKey.version)"
            for step in steps {
                records.append(makeRecord(
                    step: step,
                    clusterOffset: clusterOffset,
                    runOffset: runOffset,
                    runID: runID,
                    version: runKey.version,
                    pointerMode: pointerMode
                ))
            }
            resources.append(SpicePairedInteractionResourceSample(
                runId: runID,
                cpuPercent: 10 + Double(runOffset),
                peakRSSBytes: UInt64(128 + runOffset) * 1_024 * 1_024
            ))
        }
        return Fixture(
            clusterIDs: clusterIDs,
            specification: specification,
            records: records,
            resources: resources
        )
    }

    static func completedSteps(
        clusterID: String
    ) throws -> [SpiceLiveInteractionClusterPlan.Step] {
        var plan = try SpiceLiveInteractionClusterPlan(clusterID: clusterID)
        var result: [SpiceLiveInteractionClusterPlan.Step] = []
        for expectedOrder in UInt64(1)...3 {
            let step = try plan.beginNextStep()
            #expect(step.order == expectedOrder)
            result.append(step)
            try plan.recordExactPresentation(order: step.order)
            try plan.recordAppendCompleted(order: step.order)
        }
        return result
    }

    static func step(
        clusterID: String,
        actionClass: SpiceInteractionActionClass
    ) throws -> SpiceLiveInteractionClusterPlan.Step {
        try #require(completedSteps(clusterID: clusterID).first {
            $0.actionClass == actionClass
        })
    }

    static func makeRecord(
        step: SpiceLiveInteractionClusterPlan.Step,
        clusterOffset: Int,
        runOffset: Int,
        runID: String,
        version: String,
        pointerMode: SpicePointerMode
    ) -> SpiceInteractionTraceRecord {
        let inputDuration = durationNanoseconds(
            actionClass: step.actionClass,
            clusterOffset: clusterOffset,
            isCandidate: version == candidateVersion
        )
        let hostInput = UInt64(1_000_000_000 + runOffset * 1_000_000)
        let scheduled = hostInput - 100
        let sendStarted = hostInput + 100
        let sendCompleted = hostInput + 200
        let displayReceive = hostInput + 300
        let surfaceReady = hostInput + 400
        let selectedReady = hostInput + 500
        let selection = hostInput + 600
        let commit = hostInput + 700
        let presented = hostInput + inputDuration
        let motionACK = step.requiresMotionAcknowledgement(for: pointerMode)
            ? sendStarted + 50
            : nil
        return SpiceInteractionTraceRecord(
            pairId: step.pairID,
            version: version,
            runId: runID,
            order: step.order,
            actionClass: step.actionClass,
            token: step.token,
            scheduledNs: scheduled,
            hostInputNs: hostInput,
            sendStartedNs: sendStarted,
            sendCompletedNs: sendCompleted,
            motionAckNs: motionACK,
            guestReceivedNs: 1_000,
            guestMarkerDrawnNs: 2_000,
            displayReceiveNs: displayReceive,
            surfaceReadyNs: surfaceReady,
            selectedRevisionReadyNs: selectedReady,
            selectionNs: selection,
            metalCommitNs: commit,
            presentedNs: presented,
            displayChannelID: 0,
            surfaceID: UInt32(clusterOffset + 1),
            surfaceGeneration: 1,
            desktopGeneration: 1,
            frameRevision: UInt64(runOffset * 10) + step.order,
            deliverySequence: UInt64(runOffset * 10) + step.order,
            markerRevision: UInt64(runOffset * 10) + step.order,
            markerChecksum: String(format: "%08x", step.checksum)
        )
    }

    static func durationNanoseconds(
        actionClass: SpiceInteractionActionClass,
        clusterOffset: Int,
        isCandidate: Bool
    ) -> UInt64 {
        let index = UInt64(clusterOffset + 1)
        switch actionClass {
        case .click:
            return index * 10_000_000 + (isCandidate ? 5_000_000 : 0)
        case .key:
            return index * 20_000_000 - (isCandidate ? 10_000_000 : 0)
        case .motion:
            return index * 30_000_000 + (isCandidate ? 2_000_000 : 0)
        }
    }

    static func replacing(
        _ record: SpiceInteractionTraceRecord,
        key: String,
        value: Any?
    ) throws -> SpiceInteractionTraceRecord {
        let encoded = try JSONEncoder().encode(record)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        if let value {
            object[key] = value
        } else {
            object.removeValue(forKey: key)
        }
        return try JSONDecoder().decode(
            SpiceInteractionTraceRecord.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
    }

    static func replacingPresentedWithUnderflow(
        _ record: SpiceInteractionTraceRecord
    ) -> SpiceInteractionTraceRecord {
        SpiceInteractionTraceRecord(
            pairId: record.pairId,
            version: record.version,
            runId: record.runId,
            order: record.order,
            actionClass: record.actionClass,
            token: record.token,
            scheduledNs: record.scheduledNs,
            hostInputNs: record.hostInputNs,
            sendStartedNs: record.sendStartedNs,
            sendCompletedNs: record.sendCompletedNs,
            motionAckNs: record.motionAckNs,
            guestReceivedNs: record.guestReceivedNs,
            guestMarkerDrawnNs: record.guestMarkerDrawnNs,
            displayReceiveNs: record.displayReceiveNs,
            surfaceReadyNs: record.surfaceReadyNs,
            selectedRevisionReadyNs: record.selectedRevisionReadyNs,
            selectionNs: record.selectionNs,
            metalCommitNs: record.metalCommitNs,
            presentedNs: record.metalCommitNs! - 1,
            displayChannelID: record.displayChannelID,
            surfaceID: record.surfaceID,
            surfaceGeneration: record.surfaceGeneration,
            desktopGeneration: record.desktopGeneration,
            frameRevision: record.frameRevision,
            deliverySequence: record.deliverySequence,
            markerRevision: record.markerRevision,
            markerChecksum: record.markerChecksum
        )
    }

    static func invalidColdStartRecord() -> SpiceInteractionTraceRecord {
        SpiceInteractionTraceRecord(
            pairId: "cold-start",
            version: candidateVersion,
            runId: "run-cold-start-invalid",
            order: 1,
            actionClass: .click,
            token: "0000000000000000",
            invalidReason: "cold_start_missing_presented"
        )
    }

    static func expectArtifactError(
        _ expected: SpicePairedInteractionArtifactError,
        _ operation: () throws -> SpicePairedInteractionArtifactReport
    ) {
        do {
            _ = try operation()
            Issue.record("artifact unexpectedly passed acceptance")
        } catch let error as SpicePairedInteractionArtifactError {
            #expect(error == expected)
        } catch {
            Issue.record("unexpected artifact error: \(error)")
        }
    }

    static func expectQuantile(_ actual: Double, _ expected: Double) {
        #expect(abs(actual - expected) < 0.001)
    }
}
