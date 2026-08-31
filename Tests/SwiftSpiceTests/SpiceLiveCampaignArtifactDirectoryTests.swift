import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live campaign artifact directory")
struct SpiceLiveCampaignArtifactDirectoryTests {
    @Test func successIndexIsPublishedLastAndBindsEveryDurableObject() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let directory = Self.directoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try SpiceLiveCampaignArtifactDirectory(
            directoryURL: directory,
            plan: plan,
            pointerMode: .absolute
        )
        let recorder = try Self.recorder(owner: owner, plan: plan)

        for runIndex in plan.runs.indices {
            try Self.completeRun(runIndex, recorder: recorder, plan: plan)
            try Self.recordRun(
                runIndex,
                owner: owner,
                plan: plan,
                fixture: fixture
            )
        }
        let finalized = try recorder.finalize()
        #expect(finalized.state == .finalized)
        #expect(finalized.generation == 261)
        #expect(!FileManager.default.fileExists(atPath: owner.indexURL.path))

        let index = try owner.publishSuccess()

        #expect(index.schemaVersion == 1)
        #expect(index.campaignID == plan.campaignID)
        #expect(index.planDigest == finalized.planDigest)
        let expectedContractDigest = try #require(finalized.executionContractDigest)
        #expect(index.executionContractDigest == expectedContractDigest)
        #expect(index.recordCount == 60)
        #expect(index.runCount == 20)
        #expect(index.runArtifacts.count == 20)
        #expect(Set(index.runArtifacts.map(\.relativePath)).count == 20)
        let indexBytes = try Data(contentsOf: owner.indexURL)
        let canonicalIndexBytes = try Self.canonicalData(index)
        #expect(indexBytes == canonicalIndexBytes)
        #expect(indexBytes.last != 0x0a)

        let references = index.runArtifacts + [index.terminalManifest, index.report]
        for reference in references {
            try Self.expectReference(reference, in: directory)
        }
        for runIndex in plan.runs.indices {
            try Self.expectRunEnvelope(
                index.runArtifacts[runIndex],
                runIndex: runIndex,
                directory: directory,
                plan: plan,
                fixture: fixture
            )
        }
        let reportURL = directory.appending(path: index.report.relativePath)
        let report = try JSONDecoder().decode(
            SpiceLiveCampaignArtifactReportSnapshot.self,
            from: Data(contentsOf: reportURL)
        )
        let expectedReport = try SpicePairedInteractionArtifactEvaluator.evaluate(
            records: fixture.records,
            resourceSamples: fixture.resources,
            specification: fixture.specification
        )
        #expect(report.schemaVersion == 1)
        #expect(report.recordCount == 60)
        #expect(report.runCount == 20)
        Self.expectActionReport(
            report.click,
            equals: expectedReport.summary(for: .click)
        )
        Self.expectActionReport(
            report.key,
            equals: expectedReport.summary(for: .key)
        )
        Self.expectActionReport(
            report.motion,
            equals: expectedReport.summary(for: .motion)
        )
        Self.expectResourceReport(
            report.resources,
            equals: expectedReport.resourceGuardrails
        )

        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: directory.path
        )
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o700)
        try Self.expectPrivateRegularFile(owner.indexURL)
    }

    @Test(arguments: ArtifactInputFailure.allCases)
    func partialOrNoncanonicalRunPermanentlyFailsClosed(
        _ failure: ArtifactInputFailure
    ) throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let directory = Self.directoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try SpiceLiveCampaignArtifactDirectory(
            directoryURL: directory,
            plan: plan,
            pointerMode: .absolute
        )
        var lines = try Self.lines(forRun: 0, fixture: fixture)
        switch failure {
        case .missingRecord:
            lines.removeLast()
        case .noncanonicalRecord:
            lines[1].insert(0x20, at: 0)
        }

        #expect(throws: (any Error).self) {
            try owner.recordRun(
                logicalRunID: plan.runs[0].runID,
                evidenceRunID: Self.evidenceID(0),
                canonicalRecords: lines,
                resourceSample: fixture.resources[0],
                teardownResult: Self.teardownResult(fixture.resources[0])
            )
        }
        let directoryEntries = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        )
        #expect(!directoryEntries.contains(owner.indexURL.lastPathComponent))
        #expect(throws: (any Error).self) {
            try Self.recordRun(0, owner: owner, plan: plan, fixture: fixture)
        }
        #expect(throws: (any Error).self) { _ = try owner.publishSuccess() }
        #expect(!FileManager.default.fileExists(atPath: owner.indexURL.path))
    }

    @Test(arguments: RunIdentityFailure.allCases)
    func identityMismatchOrFailedTeardownPublishesNoSuccess(
        _ failure: RunIdentityFailure
    ) throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let directory = Self.directoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try SpiceLiveCampaignArtifactDirectory(
            directoryURL: directory,
            plan: plan,
            pointerMode: .absolute
        )
        var evidenceID = try Self.evidenceID(0)
        var sample = fixture.resources[0]
        var teardown = Self.teardownResult(sample)
        switch failure {
        case .wrongEvidence:
            evidenceID = try Self.evidenceID(1)
        case .wrongResource:
            sample = SpicePairedInteractionResourceSample(
                runId: fixture.resources[1].runId,
                cpuPercent: fixture.resources[0].cpuPercent,
                peakRSSBytes: fixture.resources[0].peakRSSBytes
            )
        case .failedTeardown:
            teardown = Self.teardownResult(sample, status: 1)
        }

        #expect(throws: (any Error).self) {
            try owner.recordRun(
                logicalRunID: plan.runs[0].runID,
                evidenceRunID: evidenceID,
                canonicalRecords: Self.lines(forRun: 0, fixture: fixture),
                resourceSample: sample,
                teardownResult: teardown
            )
        }
        #expect(throws: (any Error).self) { _ = try owner.publishSuccess() }
        #expect(!FileManager.default.fileExists(atPath: owner.indexURL.path))
    }

    @Test(arguments: ManifestFailure.allCases)
    func nonfinalizedTerminalManifestCannotPublishSuccess(
        _ failure: ManifestFailure
    ) throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let directory = Self.directoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try SpiceLiveCampaignArtifactDirectory(
            directoryURL: directory,
            plan: plan,
            pointerMode: .absolute
        )
        switch failure {
        case .recording:
            _ = try Self.recorder(owner: owner, plan: plan)
        case .failed:
            let recorder = try Self.recorder(owner: owner, plan: plan)
            try recorder.record(
                run: plan.runs[0],
                stage: .fixtureStop,
                outcome: .failed
            )
        case .interrupted:
            _ = try Self.recorder(owner: owner, plan: plan)
            _ = try SpiceLiveRealtimeStageRecorder.resume(
                plan: plan,
                metadata: Self.metadata(),
                expectedExecutionContract: Self.executionContract(
                    plan: plan,
                    metadata: Self.metadata()
                ),
                manifestWriter: owner.manifestWriter
            )
        }

        #expect(throws: (any Error).self) { _ = try owner.publishSuccess() }
        #expect(!FileManager.default.fileExists(atPath: owner.indexURL.path))
    }

    @Test func preplantedFilesCannotBeScannedIntoSuccess() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let directory = Self.directoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try SpiceLiveCampaignArtifactDirectory(
            directoryURL: directory,
            plan: plan,
            pointerMode: .absolute
        )
        let recorder = try Self.recorder(owner: owner, plan: plan)

        for runIndex in plan.runs.indices {
            try Self.completeRun(runIndex, recorder: recorder, plan: plan)
            let plantedURL = directory.appending(
                path: String(format: "run-%02d.records.jsonl", runIndex)
            )
            try Self.lines(forRun: runIndex, fixture: fixture)
                .reduce(into: Data(), { $0.append($1) })
                .write(to: plantedURL, options: [.atomic])
            #expect(chmod(plantedURL.path, S_IRUSR | S_IWUSR) == 0)
        }
        #expect(throws: (any Error).self) {
            try Self.recordRun(0, owner: owner, plan: plan, fixture: fixture)
        }
        _ = try recorder.finalize()

        #expect(throws: (any Error).self) { _ = try owner.publishSuccess() }
        #expect(!FileManager.default.fileExists(atPath: owner.indexURL.path))
    }

    @Test func interruptedOwnerCannotBeReopenedOrSynthesized() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let directory = Self.directoryURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let owner = try SpiceLiveCampaignArtifactDirectory(
                directoryURL: directory,
                plan: plan,
                pointerMode: .absolute
            )
            try Self.recordRun(
                0,
                owner: owner,
                plan: plan,
                fixture: fixture
            )
        }

        #expect(throws: (any Error).self) {
            _ = try SpiceLiveCampaignArtifactDirectory(
                directoryURL: directory,
                plan: plan,
                pointerMode: .absolute
            )
        }
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "success-index.json").path
        ))
    }
}

extension SpiceLiveCampaignArtifactDirectoryTests {
    struct RunEnvelopeProbe: Decodable {
        let schemaVersion: Int
        let logicalRunID: String
        let evidenceRunID: String
        let resourceSample: ResourceSampleProbe
        let teardownResult: TeardownResultProbe
        let records: ReferenceProbe

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case logicalRunID = "logical_run_id"
            case evidenceRunID = "evidence_run_id"
            case resourceSample = "resource_sample"
            case teardownResult = "teardown_result"
            case records
        }
    }

    struct ResourceSampleProbe: Decodable {
        let runID: String
        let cpuPercent: Double
        let peakRSSBytes: UInt64

        enum CodingKeys: String, CodingKey {
            case runID = "run_id"
            case cpuPercent = "cpu_percent"
            case peakRSSBytes = "peak_rss_bytes"
        }
    }

    struct TeardownResultProbe: Decodable {
        let status: Int32
        let userNanoseconds: UInt64
        let systemNanoseconds: UInt64
        let peakResidentBytes: UInt64

        enum CodingKeys: String, CodingKey {
            case status
            case userNanoseconds = "user_nanoseconds"
            case systemNanoseconds = "system_nanoseconds"
            case peakResidentBytes = "peak_resident_bytes"
        }
    }

    struct ReferenceProbe: Decodable {
        let relativePath: String
        let sha256: String
        let byteCount: UInt64

        enum CodingKeys: String, CodingKey {
            case relativePath = "relative_path"
            case sha256
            case byteCount = "byte_count"
        }
    }

    enum ArtifactInputFailure: CaseIterable, Sendable, CustomTestStringConvertible {
        case missingRecord
        case noncanonicalRecord

        var testDescription: String { String(describing: self) }
    }

    enum RunIdentityFailure: CaseIterable, Sendable, CustomTestStringConvertible {
        case wrongEvidence
        case wrongResource
        case failedTeardown

        var testDescription: String { String(describing: self) }
    }

    enum ManifestFailure: CaseIterable, Sendable, CustomTestStringConvertible {
        case recording
        case failed
        case interrupted

        var testDescription: String { String(describing: self) }
    }

    static let stages: [SpiceLiveAttemptStage] = [
        .fixtureStop,
        .fixtureStart,
        .fixtureHealth,
        .preArm, .arm, .postArm,
        .preArm, .arm, .postArm,
        .preArm, .arm, .postArm,
        .teardown,
    ]

    static func fixture() throws -> SpicePairedInteractionArtifactTests.Fixture {
        var fixture = try SpicePairedInteractionArtifactTests.makeFixture(
            pointerMode: .absolute
        )
        for runIndex in fixture.resources.indices {
            let evidenceID = try evidenceID(runIndex).rawValue
            for recordIndex in (runIndex * 3)..<(runIndex * 3 + 3) {
                fixture.records[recordIndex] = try
                    SpicePairedInteractionArtifactTests.replacing(
                        fixture.records[recordIndex],
                        key: "run_id",
                        value: evidenceID
                    )
            }
            let sample = fixture.resources[runIndex]
            fixture.resources[runIndex] = SpicePairedInteractionResourceSample(
                runId: evidenceID,
                cpuPercent: sample.cpuPercent,
                peakRSSBytes: sample.peakRSSBytes
            )
        }
        return fixture
    }

    static func plan(
        fixture: SpicePairedInteractionArtifactTests.Fixture
    ) throws -> SpiceLiveCampaignPlan {
        try SpiceLiveCampaignPlan(
            campaignID: "a10000000000000f",
            baselineVersion: fixture.specification.baselineVersion,
            candidateVersion: fixture.specification.candidateVersion,
            clusterIDs: fixture.specification.clusterIDs
        )
    }

    static func recorder(
        owner: SpiceLiveCampaignArtifactDirectory,
        plan: SpiceLiveCampaignPlan
    ) throws -> SpiceLiveRealtimeStageRecorder {
        let metadata = try metadata()
        return try SpiceLiveRealtimeStageRecorder(
            plan: plan,
            metadata: metadata,
            executionContract: executionContract(plan: plan, metadata: metadata),
            manifestWriter: owner.manifestWriter
        )
    }

    static func metadata() throws -> SpiceLiveCampaignManifestMetadata {
        try SpiceLiveCampaignManifestMetadata(
            baselineSourceCommit: String(repeating: "a", count: 40),
            candidateSourceCommit: String(repeating: "b", count: 40),
            toolchain: "Swift 6.3 / Xcode 27 beta",
            hardware: "Apple Silicon test host",
            thermalState: .nominal,
            workload: "aip-00-paired-click-key-motion-v1",
            startedAtUTC: "2026-08-31T10:00:00Z"
        )
    }

    static func executionContract(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata
    ) throws -> SpiceLiveCampaignExecutionContract {
        try SpiceLiveCampaignExecutionContract(
            plan: plan,
            metadata: metadata,
            baselineVersion: plan.baselineVersion,
            candidateVersion: plan.candidateVersion,
            baselineSourceCommit: metadata.baselineSourceCommit,
            candidateSourceCommit: metadata.candidateSourceCommit,
            baselineReleaseBinarySHA256: String(repeating: "1", count: 64),
            candidateReleaseBinarySHA256: String(repeating: "2", count: 64),
            runnerSourceCommit: String(repeating: "c", count: 40),
            runnerReleaseBinarySHA256: String(repeating: "3", count: 64),
            remoteImageReference: "registry.example/swiftspice/perf:v0.3.4",
            remoteImageDigest: String(repeating: "4", count: 64),
            guestBuildManifestSHA256: String(repeating: "5", count: 64),
            fixtureSourcesSHA256: String(repeating: "6", count: 64),
            controlSourceSHA256: String(repeating: "7", count: 64),
            pointerMode: .absolute,
            stageProtocolVersion: .v1
        )
    }

    static func completeRun(
        _ runIndex: Int,
        recorder: SpiceLiveRealtimeStageRecorder,
        plan: SpiceLiveCampaignPlan
    ) throws {
        let run = plan.runs[runIndex]
        for stage in stages {
            try recorder.record(
                run: run,
                stage: stage,
                outcome: .succeeded,
                evidenceRunID: stage == .fixtureStart ? evidenceID(runIndex) : nil
            )
        }
    }

    static func recordRun(
        _ runIndex: Int,
        owner: SpiceLiveCampaignArtifactDirectory,
        plan: SpiceLiveCampaignPlan,
        fixture: SpicePairedInteractionArtifactTests.Fixture
    ) throws {
        try owner.recordRun(
            logicalRunID: plan.runs[runIndex].runID,
            evidenceRunID: evidenceID(runIndex),
            canonicalRecords: lines(forRun: runIndex, fixture: fixture),
            resourceSample: fixture.resources[runIndex],
            teardownResult: teardownResult(fixture.resources[runIndex])
        )
    }

    static func lines(
        forRun runIndex: Int,
        fixture: SpicePairedInteractionArtifactTests.Fixture
    ) throws -> [Data] {
        try fixture.records[(runIndex * 3)..<(runIndex * 3 + 3)].map { record in
            var data = try canonicalData(record)
            data.append(0x0a)
            return data
        }
    }

    static func teardownResult(
        _ sample: SpicePairedInteractionResourceSample,
        status: Int32 = 0
    ) -> SpiceLiveProcessGroup.TerminalResult {
        SpiceLiveProcessGroup.TerminalResult(
            status: status,
            resourceUsage: SpiceLiveProcessGroup.ResourceUsage(
                userNanoseconds: 10_000,
                systemNanoseconds: 5_000,
                peakResidentBytes: sample.peakRSSBytes
            )
        )
    }

    static func evidenceID(_ runIndex: Int) throws -> SpiceLiveEvidenceRunID {
        try SpiceLiveEvidenceRunID(String(
            format: "20260831T120000Z.%06d",
            runIndex
        ))
    }

    static func directoryURL() -> URL {
        FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-aip00h2c3-\(UUID().uuidString)"
        )
    }

    static func canonicalData<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func expectReference(
        _ reference: SpiceLiveCampaignArtifactReference,
        in directory: URL
    ) throws {
        let url = directory.appending(path: reference.relativePath)
        let data = try Data(contentsOf: url)
        #expect(reference.byteCount == UInt64(data.count))
        #expect(reference.sha256 == SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined())
        try expectPrivateRegularFile(url)
    }

    static func expectRunEnvelope(
        _ reference: SpiceLiveCampaignArtifactReference,
        runIndex: Int,
        directory: URL,
        plan: SpiceLiveCampaignPlan,
        fixture: SpicePairedInteractionArtifactTests.Fixture
    ) throws {
        #expect(reference.relativePath == String(format: "run-%02d.json", runIndex))
        let envelopeURL = directory.appending(path: reference.relativePath)
        let envelope = try JSONDecoder().decode(
            RunEnvelopeProbe.self,
            from: Data(contentsOf: envelopeURL)
        )
        let expectedEvidenceID = try evidenceID(runIndex).rawValue
        let sample = fixture.resources[runIndex]
        #expect(envelope.schemaVersion == 1)
        #expect(envelope.logicalRunID == plan.runs[runIndex].runID)
        #expect(envelope.evidenceRunID == expectedEvidenceID)
        #expect(envelope.resourceSample.runID == expectedEvidenceID)
        #expect(envelope.resourceSample.cpuPercent == sample.cpuPercent)
        #expect(envelope.resourceSample.peakRSSBytes == sample.peakRSSBytes)
        #expect(envelope.teardownResult.status == 0)
        #expect(envelope.teardownResult.userNanoseconds == 10_000)
        #expect(envelope.teardownResult.systemNanoseconds == 5_000)
        #expect(envelope.teardownResult.peakResidentBytes == sample.peakRSSBytes)

        let expectedRecordsPath = String(
            format: "run-%02d.records.jsonl",
            runIndex
        )
        #expect(envelope.records.relativePath == expectedRecordsPath)
        let recordsURL = directory.appending(path: envelope.records.relativePath)
        let recordsBytes = try Data(contentsOf: recordsURL)
        let expectedBytes = try lines(forRun: runIndex, fixture: fixture)
            .reduce(into: Data(), { $0.append($1) })
        #expect(recordsBytes == expectedBytes)
        #expect(envelope.records.byteCount == UInt64(recordsBytes.count))
        #expect(envelope.records.sha256 == digest(recordsBytes))
        try expectPrivateRegularFile(recordsURL)
    }

    static func expectActionReport(
        _ actual: SpiceLiveCampaignArtifactActionReport,
        equals expected: SpicePairedInteractionActionSummary
    ) {
        #expect(actual.pairCount == expected.pairs.count)
        expectQuantiles(
            actual.baselineInputToPresented,
            equals: expected.baselineInputToPresented
        )
        expectQuantiles(
            actual.candidateInputToPresented,
            equals: expected.candidateInputToPresented
        )
        expectQuantiles(
            actual.pairedInputToPresentedDelta,
            equals: expected.pairedInputToPresentedDelta
        )
    }

    static func expectResourceReport(
        _ actual: SpiceLiveCampaignArtifactResourceReport,
        equals expected: SpicePairedInteractionResourceGuardrails
    ) {
        #expect(actual.pairCount == expected.pairs.count)
        expectQuantiles(actual.baselineCPUPercent, equals: expected.baselineCPUPercent)
        expectQuantiles(actual.candidateCPUPercent, equals: expected.candidateCPUPercent)
        expectQuantiles(
            actual.pairedCPUPercentDelta,
            equals: expected.pairedCPUPercentDelta
        )
        expectQuantiles(
            actual.baselinePeakRSSBytes,
            equals: expected.baselinePeakRSSBytes
        )
        expectQuantiles(
            actual.candidatePeakRSSBytes,
            equals: expected.candidatePeakRSSBytes
        )
        expectQuantiles(
            actual.pairedPeakRSSBytesDelta,
            equals: expected.pairedPeakRSSBytesDelta
        )
    }

    static func expectQuantiles(
        _ actual: SpiceLiveCampaignArtifactQuantiles,
        equals expected: SpiceLiveQuantiles
    ) {
        #expect(actual.p50 == expected.p50Nanoseconds)
        #expect(actual.p95 == expected.p95Nanoseconds)
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func expectPrivateRegularFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
    }
}
