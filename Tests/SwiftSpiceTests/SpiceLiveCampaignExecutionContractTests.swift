import Darwin
import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live campaign execution contract")
struct SpiceLiveCampaignExecutionContractTests {
    @Test func contractBindsEveryExecutionInputAndManifestIdentity() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let metadata = try Self.metadata()
        let contract = try Self.contract(plan: plan, metadata: metadata)

        #expect(contract.baselineVersion == plan.baselineVersion)
        #expect(contract.candidateVersion == plan.candidateVersion)
        #expect(contract.baselineSourceCommit == metadata.baselineSourceCommit)
        #expect(contract.candidateSourceCommit == metadata.candidateSourceCommit)
        #expect(contract.baselineReleaseBinarySHA256 == Self.hash("1"))
        #expect(contract.candidateReleaseBinarySHA256 == Self.hash("2"))
        #expect(contract.runnerSourceCommit == Self.commit("c"))
        #expect(contract.runnerReleaseBinarySHA256 == Self.hash("3"))
        #expect(contract.remoteImageReference == Self.remoteImageReference)
        #expect(contract.remoteImageDigest == Self.hash("4"))
        #expect(contract.guestBuildManifestSHA256 == Self.hash("5"))
        #expect(contract.fixtureSourcesSHA256 == Self.hash("6"))
        #expect(contract.controlSourceSHA256 == Self.hash("7"))
        #expect(contract.pointerMode == .absolute)
        #expect(contract.stageProtocolVersion == .v1)
        #expect(contract.digest.utf8.count == 64)
        #expect(contract.digest.utf8.allSatisfy(Self.isLowerHex))

        let manifest = SpiceLiveCampaignManifest(
            plan: plan,
            metadata: metadata,
            executionContract: contract
        )
        #expect(SpiceLiveCampaignManifest.currentSchemaVersion == 2)
        #expect(manifest.schemaVersion == 2)
        #expect(manifest.executionContract == contract)
        #expect(manifest.executionContractDigest == contract.digest)

        let relativeContract = try Self.contract(
            plan: plan,
            metadata: metadata,
            pointerMode: .relative
        )
        let relativeManifest = SpiceLiveCampaignManifest(
            plan: plan,
            metadata: metadata,
            executionContract: relativeContract
        )
        #expect(!manifest.hasSameImmutableIdentity(as: relativeManifest))

        let encoded = try Self.canonicalData(manifest)
        let decodedObject = try JSONSerialization.jsonObject(with: encoded)
        let object = try #require(decodedObject as? [String: Any])
        #expect(object["schema_version"] as? Int == 2)
        #expect(object["execution_contract_digest"] as? String == contract.digest)
        #expect(object["execution_contract"] is [String: Any])
        #expect(encoded.last != 0x0a)
    }

    @Test func contractRejectsPlanMetadataAndCanonicalBoundaryMismatches() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let metadata = try Self.metadata()

        let invalidContracts: [() throws -> SpiceLiveCampaignExecutionContract] = [
            { try Self.contract(plan: plan, metadata: metadata, baselineVersion: "v0.2.08") },
            { try Self.contract(plan: plan, metadata: metadata, baselineVersion: "v0.2.8") },
            { try Self.contract(plan: plan, metadata: metadata, candidateVersion: "0.3.3") },
            { try Self.contract(plan: plan, metadata: metadata, candidateVersion: "v0.3.3\n") },
            { try Self.contract(plan: plan, metadata: metadata, baselineSourceCommit: Self.commit("b")) },
            { try Self.contract(plan: plan, metadata: metadata, baselineSourceCommit: String(repeating: "a", count: 39)) },
            { try Self.contract(plan: plan, metadata: metadata, candidateSourceCommit: Self.commit("a")) },
            { try Self.contract(plan: plan, metadata: metadata, candidateSourceCommit: Self.commit("g")) },
            { try Self.contract(plan: plan, metadata: metadata, runnerSourceCommit: Self.commit("C")) },
            { try Self.contract(plan: plan, metadata: metadata, runnerSourceCommit: String(repeating: "c", count: 39)) },
            { try Self.contract(plan: plan, metadata: metadata, baselineReleaseBinarySHA256: Self.hash("A")) },
            { try Self.contract(plan: plan, metadata: metadata, candidateReleaseBinarySHA256: String(repeating: "2", count: 63)) },
            { try Self.contract(plan: plan, metadata: metadata, runnerReleaseBinarySHA256: Self.hash("g")) },
            { try Self.contract(plan: plan, metadata: metadata, remoteImageReference: "") },
            { try Self.contract(plan: plan, metadata: metadata, remoteImageReference: "registry.example/image latest") },
            { try Self.contract(plan: plan, metadata: metadata, remoteImageReference: "registry.example/image\nlatest") },
            { try Self.contract(plan: plan, metadata: metadata, remoteImageReference: "registry.example/image;touch-bad") },
            { try Self.contract(plan: plan, metadata: metadata, remoteImageReference: "registry.example/图像:v1") },
            { try Self.contract(plan: plan, metadata: metadata, remoteImageReference: String(repeating: "a", count: 513)) },
            { try Self.contract(plan: plan, metadata: metadata, remoteImageDigest: Self.hash("G")) },
            { try Self.contract(plan: plan, metadata: metadata, guestBuildManifestSHA256: "") },
            { try Self.contract(plan: plan, metadata: metadata, fixtureSourcesSHA256: Self.hash("F")) },
            { try Self.contract(plan: plan, metadata: metadata, controlSourceSHA256: Self.hash("0") + "0") },
        ]

        for invalidContract in invalidContracts {
            #expect(throws: (any Error).self) { _ = try invalidContract() }
        }
    }

    @Test func digestIsDeterministicLowerHexAndCommitsToEveryMutableField() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let metadata = try Self.metadata()
        let original = try Self.contract(plan: plan, metadata: metadata)
        let repeated = try Self.contract(plan: plan, metadata: metadata)
        #expect(original == repeated)
        #expect(original.digest == repeated.digest)

        let changedBaselinePlan = try Self.plan(
            fixture: fixture,
            baselineVersion: "v0.2.8"
        )
        let changedCandidatePlan = try Self.plan(
            fixture: fixture,
            candidateVersion: "v0.3.4"
        )
        let changedBaselineMetadata = try Self.metadata(
            baselineSourceCommit: Self.commit("d")
        )
        let changedCandidateMetadata = try Self.metadata(
            candidateSourceCommit: Self.commit("d")
        )
        let variants = try [
            Self.contract(plan: changedBaselinePlan, metadata: metadata),
            Self.contract(plan: changedCandidatePlan, metadata: metadata),
            Self.contract(plan: plan, metadata: changedBaselineMetadata),
            Self.contract(plan: plan, metadata: changedCandidateMetadata),
            Self.contract(plan: plan, metadata: metadata, baselineReleaseBinarySHA256: Self.hash("8")),
            Self.contract(plan: plan, metadata: metadata, candidateReleaseBinarySHA256: Self.hash("8")),
            Self.contract(plan: plan, metadata: metadata, runnerSourceCommit: Self.commit("d")),
            Self.contract(plan: plan, metadata: metadata, runnerReleaseBinarySHA256: Self.hash("8")),
            Self.contract(plan: plan, metadata: metadata, remoteImageReference: "registry.example/swiftspice/perf:v0.3.4-2"),
            Self.contract(plan: plan, metadata: metadata, remoteImageDigest: Self.hash("8")),
            Self.contract(plan: plan, metadata: metadata, guestBuildManifestSHA256: Self.hash("8")),
            Self.contract(plan: plan, metadata: metadata, fixtureSourcesSHA256: Self.hash("8")),
            Self.contract(plan: plan, metadata: metadata, controlSourceSHA256: Self.hash("8")),
            Self.contract(plan: plan, metadata: metadata, pointerMode: .relative),
        ]
        #expect(variants.allSatisfy { $0.digest != original.digest })
        #expect(Set(variants.map(\.digest)).count == variants.count)
    }

    @Test func canonicalFixtureContractHasExactKnownDigest() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let metadata = try Self.metadata()
        let contract = try Self.contract(plan: plan, metadata: metadata)

        #expect(contract.stageProtocolVersion == .v1)
        #expect(contract.digest == Self.canonicalContractDigest)
    }

    @Test func recorderRejectsContractMismatchBeforeCreatingOrReplacingOutput() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let metadata = try Self.metadata()
        let contract = try Self.contract(plan: plan, metadata: metadata)
        let changedPlan = try Self.plan(
            fixture: fixture,
            candidateVersion: "v0.3.4"
        )
        let changedMetadata = try Self.metadata(candidateSourceCommit: Self.commit("d"))
        let changedContract = try Self.contract(
            plan: changedPlan,
            metadata: changedMetadata
        )

        let rejectedOutput = try Self.outputURL()
        defer { Self.removeOutput(rejectedOutput) }
        let rejectedWriter = try SpiceLiveCampaignManifestWriter(outputURL: rejectedOutput)
        #expect(throws: (any Error).self) {
            _ = try SpiceLiveRealtimeStageRecorder(
                plan: plan,
                metadata: metadata,
                executionContract: changedContract,
                manifestWriter: rejectedWriter
            )
        }
        #expect(!FileManager.default.fileExists(atPath: rejectedOutput.path))
        let rejectedDirectoryEntries = try FileManager.default.contentsOfDirectory(
            atPath: rejectedOutput.deletingLastPathComponent().path
        )
        #expect(rejectedDirectoryEntries.isEmpty)

        let seeded = try Self.recorder(
            plan: plan,
            metadata: metadata,
            contract: contract
        )
        defer { Self.removeOutput(seeded.output) }
        let originalBytes = try Data(contentsOf: seeded.output)
        let originalState = try Self.outputState(seeded.output)
        #expect(throws: (any Error).self) {
            _ = try SpiceLiveRealtimeStageRecorder.resume(
                plan: plan,
                metadata: metadata,
                expectedExecutionContract: changedContract,
                manifestWriter: seeded.writer
            )
        }
        let bytesAfterContractMismatch = try Data(contentsOf: seeded.output)
        let stateAfterContractMismatch = try Self.outputState(seeded.output)
        #expect(bytesAfterContractMismatch == originalBytes)
        #expect(stateAfterContractMismatch == originalState)

        let mismatchedMetadata = try Self.metadata(
            candidateSourceCommit: Self.commit("d")
        )
        #expect(throws: (any Error).self) {
            _ = try SpiceLiveRealtimeStageRecorder.resume(
                plan: plan,
                metadata: mismatchedMetadata,
                expectedExecutionContract: contract,
                manifestWriter: seeded.writer
            )
        }
        let bytesAfterMetadataMismatch = try Data(contentsOf: seeded.output)
        let stateAfterMetadataMismatch = try Self.outputState(seeded.output)
        #expect(bytesAfterMetadataMismatch == originalBytes)
        #expect(stateAfterMetadataMismatch == originalState)
    }

    @Test func legacySchemaOneIsReadOnlyAndResumeNeverMutatesOrUpgradesIt() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let metadata = try Self.metadata()
        let contract = try Self.contract(plan: plan, metadata: metadata)
        let current = try Self.recorder(
            plan: plan,
            metadata: metadata,
            contract: contract
        )
        defer { Self.removeOutput(current.output) }
        let currentClassification = try current.writer.classification()
        #expect(currentClassification == .current(current.recorder.snapshot))

        let legacyOutput = try Self.outputURL()
        defer { Self.removeOutput(legacyOutput) }
        let schemaTwo = try Self.canonicalData(current.recorder.snapshot)
        let legacyBytes = try Self.schemaOneBytes(fromSchemaTwo: schemaTwo)
        try Self.writePrivate(legacyBytes, to: legacyOutput)
        let legacyWriter = try SpiceLiveCampaignManifestWriter(outputURL: legacyOutput)
        let beforeClassification = try Self.outputState(legacyOutput)
        let legacyClassification = try legacyWriter.classification()
        #expect(legacyClassification == .legacySchema1)
        let bytesAfterClassification = try Data(contentsOf: legacyOutput)
        #expect(bytesAfterClassification == legacyBytes)
        let afterClassification = try Self.outputState(legacyOutput)
        #expect(afterClassification == beforeClassification)

        #expect(throws: (any Error).self) {
            _ = try SpiceLiveRealtimeStageRecorder.resume(
                plan: plan,
                metadata: metadata,
                expectedExecutionContract: contract,
                manifestWriter: legacyWriter
            )
        }
        let bytesAfterResume = try Data(contentsOf: legacyOutput)
        let stateAfterResume = try Self.outputState(legacyOutput)
        #expect(bytesAfterResume == legacyBytes)
        #expect(stateAfterResume == beforeClassification)

        #expect(throws: (any Error).self) {
            _ = try SpiceLiveRealtimeStageRecorder(
                plan: plan,
                metadata: metadata,
                executionContract: contract,
                manifestWriter: legacyWriter
            )
        }
        let bytesAfterCreate = try Data(contentsOf: legacyOutput)
        let stateAfterCreate = try Self.outputState(legacyOutput)
        #expect(bytesAfterCreate == legacyBytes)
        #expect(stateAfterCreate == beforeClassification)
    }

    @Test func malformedMissingDuplicateAndConflictingIdentityRemainByteExact() throws {
        let fixture = try Self.fixture()
        let plan = try Self.plan(fixture: fixture)
        let metadata = try Self.metadata()
        let contract = try Self.contract(plan: plan, metadata: metadata)
        let seed = try Self.recorder(
            plan: plan,
            metadata: metadata,
            contract: contract
        )
        defer { Self.removeOutput(seed.output) }
        let canonical = try Self.canonicalData(seed.recorder.snapshot)
        var malformedInputs = try [
            Self.removing(key: "execution_contract", from: canonical),
            Self.removing(key: "execution_contract_digest", from: canonical),
            Self.replacing(
                key: "execution_contract_digest",
                with: Self.hash("0"),
                in: canonical
            ),
            Self.duplicatingTopLevel(key: "execution_contract", in: canonical),
            Self.duplicatingTopLevel(key: "execution_contract_digest", in: canonical),
            Self.duplicatingExecutionContractField(
                key: "baseline_version",
                in: canonical
            ),
            Self.duplicatingExecutionContractField(
                key: "stage_protocol_version",
                in: canonical
            ),
            Self.duplicatingSchemaVersion(in: canonical),
            Self.addingUnexpectedIdentity(in: canonical),
        ]
        for key in Self.executionContractRequiredKeys {
            malformedInputs.append(
                try Self.removingExecutionContractField(key: key, from: canonical)
            )
            malformedInputs.append(
                try Self.nullingExecutionContractField(key: key, in: canonical)
            )
        }
        #expect(malformedInputs.count == 39)

        for bytes in malformedInputs {
            let output = try Self.outputURL()
            defer { Self.removeOutput(output) }
            try Self.writePrivate(bytes, to: output)
            let writer = try SpiceLiveCampaignManifestWriter(outputURL: output)
            #expect(throws: (any Error).self) { _ = try writer.classification() }
            let bytesAfterClassification = try Data(contentsOf: output)
            #expect(bytesAfterClassification == bytes)
            #expect(throws: (any Error).self) {
                _ = try SpiceLiveRealtimeStageRecorder.resume(
                    plan: plan,
                    metadata: metadata,
                    expectedExecutionContract: contract,
                    manifestWriter: writer
                )
            }
            let preservedBytes = try Data(contentsOf: output)
            #expect(preservedBytes == bytes)
        }
    }
}

private extension SpiceLiveCampaignExecutionContractTests {
    static let canonicalContractDigest =
        "dda67088a3dc4c61e906d344d0bec264bf85099f163d9b47aa83f2cd4fa1999d"
    static let remoteImageReference = "registry.example/swiftspice/perf:v0.3.4"
    static let executionContractRequiredKeys = [
        "baseline_version",
        "candidate_version",
        "baseline_source_commit",
        "candidate_source_commit",
        "baseline_release_binary_sha256",
        "candidate_release_binary_sha256",
        "runner_source_commit",
        "runner_release_binary_sha256",
        "remote_image_reference",
        "remote_image_digest",
        "guest_build_manifest_sha256",
        "fixture_sources_sha256",
        "control_source_sha256",
        "pointer_mode",
        "stage_protocol_version",
    ]

    static func fixture() throws -> SpicePairedInteractionArtifactTests.Fixture {
        try SpicePairedInteractionArtifactTests.makeFixture(pointerMode: .absolute)
    }

    static func plan(
        fixture: SpicePairedInteractionArtifactTests.Fixture,
        baselineVersion: String? = nil,
        candidateVersion: String? = nil
    ) throws -> SpiceLiveCampaignPlan {
        try SpiceLiveCampaignPlan(
            campaignID: "a20000000000000f",
            baselineVersion: baselineVersion
                ?? fixture.specification.baselineVersion,
            candidateVersion: candidateVersion
                ?? fixture.specification.candidateVersion,
            clusterIDs: fixture.specification.clusterIDs
        )
    }

    static func metadata(
        baselineSourceCommit: String = commit("a"),
        candidateSourceCommit: String = commit("b")
    ) throws -> SpiceLiveCampaignManifestMetadata {
        try SpiceLiveCampaignManifestMetadata(
            baselineSourceCommit: baselineSourceCommit,
            candidateSourceCommit: candidateSourceCommit,
            toolchain: "Swift 6.3 / Xcode 27 beta",
            hardware: "Apple Silicon test host",
            thermalState: .nominal,
            workload: "aip-00-paired-click-key-motion-v1",
            startedAtUTC: "2026-08-30T10:00:00Z"
        )
    }

    static func contract(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata,
        baselineVersion: String? = nil,
        candidateVersion: String? = nil,
        baselineSourceCommit: String? = nil,
        candidateSourceCommit: String? = nil,
        baselineReleaseBinarySHA256: String = hash("1"),
        candidateReleaseBinarySHA256: String = hash("2"),
        runnerSourceCommit: String = commit("c"),
        runnerReleaseBinarySHA256: String = hash("3"),
        remoteImageReference: String = remoteImageReference,
        remoteImageDigest: String = hash("4"),
        guestBuildManifestSHA256: String = hash("5"),
        fixtureSourcesSHA256: String = hash("6"),
        controlSourceSHA256: String = hash("7"),
        pointerMode: SpicePointerMode = .absolute
    ) throws -> SpiceLiveCampaignExecutionContract {
        try SpiceLiveCampaignExecutionContract(
            plan: plan,
            metadata: metadata,
            baselineVersion: baselineVersion ?? plan.baselineVersion,
            candidateVersion: candidateVersion ?? plan.candidateVersion,
            baselineSourceCommit: baselineSourceCommit ?? metadata.baselineSourceCommit,
            candidateSourceCommit: candidateSourceCommit ?? metadata.candidateSourceCommit,
            baselineReleaseBinarySHA256: baselineReleaseBinarySHA256,
            candidateReleaseBinarySHA256: candidateReleaseBinarySHA256,
            runnerSourceCommit: runnerSourceCommit,
            runnerReleaseBinarySHA256: runnerReleaseBinarySHA256,
            remoteImageReference: remoteImageReference,
            remoteImageDigest: remoteImageDigest,
            guestBuildManifestSHA256: guestBuildManifestSHA256,
            fixtureSourcesSHA256: fixtureSourcesSHA256,
            controlSourceSHA256: controlSourceSHA256,
            pointerMode: pointerMode,
            stageProtocolVersion: .v1
        )
    }

    static func recorder(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata,
        contract: SpiceLiveCampaignExecutionContract
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
                metadata: metadata,
                executionContract: contract,
                manifestWriter: writer
            ),
            writer,
            output
        )
    }

    static func outputURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-aip00h2a-\(UUID().uuidString)"
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

    static func schemaOneBytes(fromSchemaTwo data: Data) throws -> Data {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        var object = try #require(decodedObject as? [String: Any])
        object["schema_version"] = 1
        object.removeValue(forKey: "execution_contract")
        object.removeValue(forKey: "execution_contract_digest")
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func removing(key: String, from data: Data) throws -> Data {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        var object = try #require(decodedObject as? [String: Any])
        object.removeValue(forKey: key)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func replacing(key: String, with value: String, in data: Data) throws -> Data {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        var object = try #require(decodedObject as? [String: Any])
        object[key] = value
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func removingExecutionContractField(
        key: String,
        from data: Data
    ) throws -> Data {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        var object = try #require(decodedObject as? [String: Any])
        var contract = try #require(object["execution_contract"] as? [String: Any])
        contract.removeValue(forKey: key)
        object["execution_contract"] = contract
        return try canonicalJSONObjectData(object)
    }

    static func nullingExecutionContractField(
        key: String,
        in data: Data
    ) throws -> Data {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        var object = try #require(decodedObject as? [String: Any])
        var contract = try #require(object["execution_contract"] as? [String: Any])
        contract[key] = NSNull()
        object["execution_contract"] = contract
        return try canonicalJSONObjectData(object)
    }

    static func duplicatingTopLevel(key: String, in data: Data) throws -> Data {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        let object = try #require(decodedObject as? [String: Any])
        let value = try #require(object[key])
        return try duplicating(
            key: key,
            value: value,
            in: data
        )
    }

    static func duplicatingExecutionContractField(
        key: String,
        in data: Data
    ) throws -> Data {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        let object = try #require(decodedObject as? [String: Any])
        let contract = try #require(object["execution_contract"] as? [String: Any])
        let value = try #require(contract[key])
        let canonicalContract = try canonicalJSONObjectData(contract)
        let duplicatedContract = try duplicating(
            key: key,
            value: value,
            in: canonicalContract
        )
        let source = try #require(String(data: data, encoding: .utf8))
        let contractSource = try #require(
            String(data: canonicalContract, encoding: .utf8)
        )
        let duplicateSource = try #require(
            String(data: duplicatedContract, encoding: .utf8)
        )
        guard let range = source.range(of: contractSource) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var duplicate = source
        duplicate.replaceSubrange(range, with: duplicateSource)
        return Data(duplicate.utf8)
    }

    static func duplicating(key: String, value: Any, in data: Data) throws -> Data {
        let source = try #require(String(data: data, encoding: .utf8))
        let wrapped = try canonicalJSONObjectData(["value": value])
        let wrappedSource = try #require(String(data: wrapped, encoding: .utf8))
        let prefix = "{\"value\":"
        guard wrappedSource.hasPrefix(prefix), wrappedSource.last == "}" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let valueStart = wrappedSource.index(
            wrappedSource.startIndex,
            offsetBy: prefix.count
        )
        let valueSource = wrappedSource[valueStart..<wrappedSource.index(before: wrappedSource.endIndex)]
        let field = "\"\(key)\":\(valueSource)"
        guard let range = source.range(of: field) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var duplicate = source
        duplicate.replaceSubrange(range, with: "\(field),\(field)")
        return Data(duplicate.utf8)
    }

    static func canonicalJSONObjectData(_ object: Any) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    static func duplicatingSchemaVersion(in data: Data) throws -> Data {
        let source = try #require(String(data: data, encoding: .utf8))
        let duplicate = source.replacingOccurrences(
            of: "\"schema_version\":2",
            with: "\"schema_version\":2,\"schema_version\":2"
        )
        #expect(duplicate != source)
        return Data(duplicate.utf8)
    }

    static func addingUnexpectedIdentity(in data: Data) throws -> Data {
        let decodedObject = try JSONSerialization.jsonObject(with: data)
        var object = try #require(decodedObject as? [String: Any])
        object["execution_contract_alias"] = object["execution_contract"]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func writePrivate(_ data: Data, to output: URL) throws {
        try data.write(to: output)
        guard chmod(output.path, S_IRUSR | S_IWUSR) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func outputState(_ output: URL) throws -> OutputState {
        let entries = try FileManager.default.contentsOfDirectory(
            atPath: output.deletingLastPathComponent().path
        ).sorted()
        var status = stat()
        guard lstat(output.path, &status) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return OutputState(
            entries: entries,
            device: status.st_dev,
            inode: status.st_ino,
            mode: status.st_mode,
            size: status.st_size,
            modifiedSeconds: status.st_mtimespec.tv_sec,
            modifiedNanoseconds: status.st_mtimespec.tv_nsec
        )
    }

    static func canonicalData(_ manifest: SpiceLiveCampaignManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    static func commit(_ character: Character) -> String {
        String(repeating: character, count: 40)
    }

    static func hash(_ character: Character) -> String {
        String(repeating: character, count: 64)
    }

    static func isLowerHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
    }

    struct OutputState: Equatable {
        let entries: [String]
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
    }
}
