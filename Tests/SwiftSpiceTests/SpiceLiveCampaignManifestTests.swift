import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live campaign real-time manifest")
struct SpiceLiveCampaignManifestTests {
    @Test func manifestBindsSchemaPlanAndMeasurementMetadata() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let result = try Self.recorder(plan: plan)
        defer { Self.removeOutput(result.output) }
        let manifest = result.recorder.snapshot

        #expect(manifest.schemaVersion == SpiceLiveCampaignManifest.currentSchemaVersion)
        #expect(manifest.generation == 0)
        #expect(manifest.state == .recording)
        #expect(manifest.campaignID == plan.campaignID)
        #expect(manifest.baselineVersion == plan.baselineVersion)
        #expect(manifest.candidateVersion == plan.candidateVersion)
        #expect(manifest.runs.count == 20)
        #expect(manifest.runs.map(\.logicalRunID) == plan.runs.map(\.runID))
        #expect(manifest.runs.allSatisfy { $0.evidenceRunID == nil })
        #expect(manifest.stages.isEmpty)
        #expect(manifest.metadata.baselineSourceCommit == String(repeating: "a", count: 40))
        #expect(manifest.metadata.candidateSourceCommit == String(repeating: "b", count: 40))
        #expect(manifest.metadata.toolchain == "Swift 6.3 / Xcode 27 beta")
        #expect(manifest.metadata.hardware == "Apple Silicon test host")
        #expect(manifest.metadata.thermalState == .nominal)
        #expect(manifest.metadata.workload == "aip-00-paired-click-key-motion-v1")
        #expect(manifest.metadata.startedAtUTC == "2026-08-30T10:00:00Z")
        #expect(manifest.planDigest.utf8.count == 64)
        #expect(manifest.planDigest.utf8.allSatisfy(Self.isLowerHex))
        #expect(try Data(contentsOf: result.output) == Self.canonicalData(manifest))
        #expect(try result.writer.load() == manifest)

        for invalidMetadata in Self.invalidMetadata() {
            #expect(throws: (any Error).self) { _ = try invalidMetadata() }
        }
    }

    @Test func eachRealStageImmediatelyPersistsOneCanonicalGeneration() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let result = try Self.recorder(plan: plan)
        defer { Self.removeOutput(result.output) }
        let recorder = result.recorder
        let run = plan.runs[0]

        for (offset, stage) in Self.stages.enumerated() {
            try recorder.record(
                run: run,
                stage: stage,
                outcome: .succeeded,
                evidenceRunID: stage == .fixtureStart ? Self.evidenceID(0) : nil
            )
            let bytes = try Data(contentsOf: result.output)
            let persisted = try #require(result.writer.load())
            #expect(bytes == Self.canonicalData(persisted))
            #expect(bytes.last != 0x0a)
            #expect(persisted == recorder.snapshot)
            #expect(persisted.generation == UInt64(offset + 1))
            #expect(persisted.stages.count == offset + 1)
            #expect(persisted.stages.map(\.stage) == Array(Self.stages.prefix(offset + 1)))
        }
        #expect(recorder.snapshot.runs[0].logicalRunID == run.runID)
        #expect(recorder.snapshot.runs[0].evidenceRunID == Self.evidenceID(0))
    }

    @Test func everyStageFailureIncludingTeardownPersistsAndIsTerminal() throws {
        for failureOffset in Self.stages.indices {
            let fixture = try Self.fixture()
            let plan = try Self.plan(fixture: fixture)
            let result = try Self.recorder(plan: plan)
            defer { Self.removeOutput(result.output) }
            let recorder = result.recorder
            let run = plan.runs[0]

            for stage in Self.stages[..<failureOffset] {
                try recorder.record(
                    run: run,
                    stage: stage,
                    outcome: .succeeded,
                    evidenceRunID: stage == .fixtureStart ? Self.evidenceID(0) : nil
                )
            }
            let failedStage = Self.stages[failureOffset]
            try recorder.record(
                run: run,
                stage: failedStage,
                outcome: .failed,
                evidenceRunID: nil
            )

            let persisted = try #require(result.writer.load())
            #expect(persisted.state == .failed)
            #expect(persisted.generation == UInt64(failureOffset + 1))
            #expect(persisted.stages.count == failureOffset + 1)
            #expect(persisted.stages.last?.outcome == .failed)
            #expect(throws: (any Error).self) {
                try recorder.record(run: run, stage: failedStage, outcome: .succeeded)
            }
            #expect(throws: (any Error).self) { _ = try recorder.finalize() }
        }
    }

    @Test func interruptionRecoversOnlyTheDurablePrefixAndRemainsTerminal() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let seed = try Self.recorder(plan: plan)
        defer { Self.removeOutput(seed.output) }
        let run = plan.runs[0]
        try seed.recorder.record(run: run, stage: .fixtureStop, outcome: .succeeded)
        let durablePrefix = try #require(seed.writer.load())
        #expect(durablePrefix.stages.count == 1)

        let recovered = try SpiceLiveRealtimeStageRecorder.resume(
            plan: plan,
            metadata: Self.metadata(),
            manifestWriter: seed.writer
        )
        let interrupted = try #require(seed.writer.load())
        #expect(recovered.snapshot == interrupted)
        #expect(interrupted.state == .interrupted)
        #expect(interrupted.generation == durablePrefix.generation + 1)
        #expect(interrupted.stages == durablePrefix.stages)
        #expect(throws: (any Error).self) {
            try recovered.record(
                run: run,
                stage: .fixtureStart,
                outcome: .succeeded,
                evidenceRunID: Self.evidenceID(0)
            )
        }
        #expect(recovered.snapshot.stages == durablePrefix.stages)
        #expect(throws: (any Error).self) { _ = try recovered.finalize() }
    }

    @Test func onlyExactTwoHundredSixtyStageSuccessFinalizes() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)

        let incomplete = try Self.recorder(plan: plan)
        defer { Self.removeOutput(incomplete.output) }
        #expect(throws: (any Error).self) { _ = try incomplete.recorder.finalize() }

        let complete = try Self.recorder(plan: plan)
        defer { Self.removeOutput(complete.output) }
        for runIndex in plan.runs.indices {
            try Self.completeRun(runIndex, recorder: complete.recorder, plan: plan)
        }
        #expect(complete.recorder.snapshot.stages.count == 260)
        #expect(complete.recorder.snapshot.generation == 260)
        let finalized = try complete.recorder.finalize()
        #expect(finalized.state == .finalized)
        #expect(finalized.generation == 261)
        #expect(finalized.stages.count == 260)
        #expect(Set(finalized.runs.compactMap(\.evidenceRunID)).count == 20)
        #expect(try complete.writer.load() == finalized)
    }

    @Test func missingDuplicateReorderedExtraAndMismatchFailClosed() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)

        let reordered = try Self.recorder(plan: plan)
        defer { Self.removeOutput(reordered.output) }
        #expect(throws: (any Error).self) {
            try reordered.recorder.record(
                run: plan.runs[0],
                stage: .fixtureStart,
                outcome: .succeeded,
                evidenceRunID: Self.evidenceID(0)
            )
        }
        #expect(reordered.recorder.snapshot.state == .failed)

        let duplicate = try Self.recorder(plan: plan)
        defer { Self.removeOutput(duplicate.output) }
        try duplicate.recorder.record(
            run: plan.runs[0],
            stage: .fixtureStop,
            outcome: .succeeded
        )
        #expect(throws: (any Error).self) {
            try duplicate.recorder.record(
                run: plan.runs[0],
                stage: .fixtureStop,
                outcome: .succeeded
            )
        }
        #expect(duplicate.recorder.snapshot.state == .failed)

        let duplicateEvidence = try Self.recorder(plan: plan)
        defer { Self.removeOutput(duplicateEvidence.output) }
        try Self.completeRun(0, recorder: duplicateEvidence.recorder, plan: plan)
        try duplicateEvidence.recorder.record(
            run: plan.runs[1],
            stage: .fixtureStop,
            outcome: .succeeded
        )
        #expect(throws: (any Error).self) {
            try duplicateEvidence.recorder.record(
                run: plan.runs[1],
                stage: .fixtureStart,
                outcome: .succeeded,
                evidenceRunID: Self.evidenceID(0)
            )
        }
        #expect(duplicateEvidence.recorder.snapshot.state == .failed)

        let mismatch = try Self.recorder(plan: plan)
        defer { Self.removeOutput(mismatch.output) }
        let otherPlan = try SpiceLiveCampaignPlan(
            campaignID: "b10000000000000f",
            baselineVersion: plan.baselineVersion,
            candidateVersion: plan.candidateVersion,
            clusterIDs: plan.clusterIDs
        )
        #expect(throws: (any Error).self) {
            _ = try SpiceLiveRealtimeStageRecorder.resume(
                plan: otherPlan,
                metadata: Self.metadata(),
                manifestWriter: mismatch.writer
            )
        }

        let extra = try Self.recorder(plan: plan)
        defer { Self.removeOutput(extra.output) }
        for runIndex in plan.runs.indices {
            try Self.completeRun(runIndex, recorder: extra.recorder, plan: plan)
        }
        #expect(throws: (any Error).self) {
            try extra.recorder.record(
                run: plan.runs.last!,
                stage: .fixtureStop,
                outcome: .succeeded
            )
        }
        #expect(extra.recorder.snapshot.state == .failed)
        #expect(throws: (any Error).self) { _ = try extra.recorder.finalize() }
    }

    @Test func writerIsPrivateBoundedAtomicAndRejectsUnsafeState() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let seed = try Self.recorder(plan: plan)
        defer { Self.removeOutput(seed.output) }
        let parent = seed.output.deletingLastPathComponent()

        let attributes = try FileManager.default.attributesOfItem(atPath: seed.output.path)
        #expect(attributes[.type] as? FileAttributeType == .typeRegular)
        #expect((attributes[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)
        let initialBytes = try Data(contentsOf: seed.output)
        #expect(initialBytes.count == Self.canonicalData(seed.recorder.snapshot).count)

        let boundedOutput = try Self.outputURL()
        defer { Self.removeOutput(boundedOutput) }
        let boundedWriter = try SpiceLiveCampaignManifestWriter(
            outputURL: boundedOutput,
            maximumBytes: initialBytes.count
        )
        let boundedRecorder = try SpiceLiveRealtimeStageRecorder(
            plan: plan,
            metadata: Self.metadata(),
            manifestWriter: boundedWriter
        )
        let beforeFailedReplacement = try Data(contentsOf: boundedOutput)
        #expect(throws: (any Error).self) {
            try boundedRecorder.record(
                run: plan.runs[0],
                stage: .fixtureStop,
                outcome: .succeeded
            )
        }
        #expect(try Data(contentsOf: boundedOutput) == beforeFailedReplacement)
        #expect(boundedRecorder.snapshot.stages.isEmpty)

        let target = parent.appending(path: "sentinel")
        let symlink = parent.appending(path: "manifest-link.json")
        try Data("sentinel".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: target
        )
        #expect(throws: (any Error).self) {
            _ = try SpiceLiveCampaignManifestWriter(outputURL: symlink)
        }
        #expect(try Data(contentsOf: target) == Data("sentinel".utf8))

        let directoryOutput = parent.appending(path: "directory-output")
        try FileManager.default.createDirectory(at: directoryOutput, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            _ = try SpiceLiveCampaignManifestWriter(outputURL: directoryOutput)
        }

        let noncanonical = parent.appending(path: "noncanonical.json")
        let noncanonicalBytes = Data(" {\"schema_version\":1}".utf8)
        try noncanonicalBytes.write(to: noncanonical)
        #expect(throws: (any Error).self) {
            let writer = try SpiceLiveCampaignManifestWriter(outputURL: noncanonical)
            _ = try writer.load()
        }
        #expect(try Data(contentsOf: noncanonical) == noncanonicalBytes)

        let oversized = parent.appending(path: "oversized.json")
        let oversizedBytes = Data(repeating: 0x61, count: 1_025)
        try oversizedBytes.write(to: oversized)
        #expect(throws: (any Error).self) {
            let writer = try SpiceLiveCampaignManifestWriter(
                outputURL: oversized,
                maximumBytes: 1_024
            )
            _ = try writer.load()
        }
        #expect(try Data(contentsOf: oversized) == oversizedBytes)
    }
}

private extension SpiceLiveCampaignManifestTests {
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
        try SpicePairedInteractionArtifactTests.makeFixture(pointerMode: .absolute)
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

    static func metadata(
        baselineSourceCommit: String = String(repeating: "a", count: 40),
        candidateSourceCommit: String = String(repeating: "b", count: 40),
        toolchain: String = "Swift 6.3 / Xcode 27 beta",
        hardware: String = "Apple Silicon test host",
        thermalState: SpiceLiveCampaignThermalState = .nominal,
        workload: String = "aip-00-paired-click-key-motion-v1",
        startedAtUTC: String = "2026-08-30T10:00:00Z"
    ) throws -> SpiceLiveCampaignManifestMetadata {
        try SpiceLiveCampaignManifestMetadata(
            baselineSourceCommit: baselineSourceCommit,
            candidateSourceCommit: candidateSourceCommit,
            toolchain: toolchain,
            hardware: hardware,
            thermalState: thermalState,
            workload: workload,
            startedAtUTC: startedAtUTC
        )
    }

    static func invalidMetadata() -> [() throws -> SpiceLiveCampaignManifestMetadata] {
        [
            { try metadata(baselineSourceCommit: "") },
            { try metadata(candidateSourceCommit: "") },
            { try metadata(toolchain: "") },
            { try metadata(hardware: "") },
            { try metadata(workload: "") },
            { try metadata(startedAtUTC: "") },
        ]
    }

    static func evidenceID(_ runIndex: Int) throws -> SpiceLiveEvidenceRunID {
        try SpiceLiveEvidenceRunID(String(
            format: "20260830T120000Z.%06d",
            runIndex
        ))
    }

    static func outputURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-aip00h-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appending(path: "campaign-manifest.json")
    }

    static func removeOutput(_ output: URL) {
        try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
    }

    static func recorder(
        plan: SpiceLiveCampaignPlan
    ) throws -> (
        recorder: SpiceLiveRealtimeStageRecorder,
        writer: SpiceLiveCampaignManifestWriter,
        output: URL
    ) {
        let output = try outputURL()
        let writer = try SpiceLiveCampaignManifestWriter(outputURL: output)
        return (
            try SpiceLiveRealtimeStageRecorder(
                plan: plan,
                metadata: metadata(),
                manifestWriter: writer
            ),
            writer,
            output
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

    static func canonicalData(_ manifest: SpiceLiveCampaignManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    static func isLowerHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }
}
