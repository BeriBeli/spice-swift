import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live remote fixture lease")
struct SpiceLiveRemoteFixtureLeaseTests {
    @Test func fixedCommandsBindExactRunAndAdvanceOnlyAfterDurableResults() throws {
        let seed = try Self.seed()
        defer { Self.remove(seed.output) }
        let lease = try Self.lease(seed)

        let stop = try lease.nextCommand()
        #expect(stop.arguments == Self.expectedArguments(
            seed: seed,
            script: "stop.sh"
        ))
        Self.expectStructuredSSH(stop)
        try lease.accept(
            result: Self.result(lines: ["podman: stopped owned container"]),
            for: stop
        )
        try Self.expectDurable(
            seed,
            generation: 1,
            stages: [.fixtureStop],
            evidenceRunID: nil
        )

        let start = try lease.nextCommand()
        #expect(start.arguments == Self.expectedArguments(
            seed: seed,
            script: "start.sh"
        ))
        Self.expectStructuredSSH(start)
        try lease.accept(result: Self.startResult(seed), for: start)
        try Self.expectDurable(
            seed,
            generation: 2,
            stages: [.fixtureStop, .fixtureStart],
            evidenceRunID: Self.evidenceID
        )

        let health = try lease.nextCommand()
        #expect(health.arguments == Self.expectedArguments(
            seed: seed,
            script: "status.sh"
        ))
        Self.expectStructuredSSH(health)
        try lease.accept(result: Self.healthResult(seed), for: health)
        try Self.expectDurable(
            seed,
            generation: 3,
            stages: [.fixtureStop, .fixtureStart, .fixtureHealth],
            evidenceRunID: Self.evidenceID
        )
        #expect(throws: (any Error).self) { _ = try lease.nextCommand() }
        #expect(seed.recorder.snapshot.state == .recording)
    }

    @Test(arguments: ReservedResultMutation.allCases)
    fileprivate func malformedOrMismatchedReservedResultPermanentlyFailsClosed(
        _ mutation: ReservedResultMutation
    ) throws {
        if mutation == .invalidStartEvidence {
            for startMutation in StartEvidenceMutation.allCases {
                try Self.expectInvalidStartEvidence(startMutation)
            }
            return
        }
        let seed = try Self.seed()
        defer { Self.remove(seed.output) }
        let lease = try Self.lease(seed)
        try Self.advanceThroughStart(lease, seed: seed)
        let health = try lease.nextCommand()
        let before = try Data(contentsOf: seed.output)
        var lines = Self.healthLines(seed)
        mutation.apply(to: &lines, seed: seed)

        #expect(throws: (any Error).self) {
            try lease.accept(result: Self.result(lines: lines), for: health)
        }
        try Self.expectTerminalAndStable(
            lease,
            seed: seed,
            failedCommand: health,
            bytesBeforeFailure: before,
            expectedGeneration: 3,
            expectedFailedStage: .fixtureHealth
        )
    }

    @Test func nonzeroOperationFailuresAreDurableTerminalWithoutRetry() throws {
        for failedOperation in LeaseOperation.allCases {
            let seed = try Self.seed()
            defer { Self.remove(seed.output) }
            let lease = try Self.lease(seed)
            let failureCommand: SpiceLiveRemoteFixtureLease.Command

            switch failedOperation {
            case .stop:
                failureCommand = try lease.nextCommand()
            case .start:
                try Self.acceptStop(lease, seed: seed)
                failureCommand = try lease.nextCommand()
            case .health:
                try Self.advanceThroughStart(lease, seed: seed)
                failureCommand = try lease.nextCommand()
            }
            let before = try Data(contentsOf: seed.output)
            #expect(throws: (any Error).self) {
                try lease.accept(
                    result: Self.result(status: 17, lines: ["podman: failed"]),
                    for: failureCommand
                )
            }
            try Self.expectTerminalAndStable(
                lease,
                seed: seed,
                failedCommand: failureCommand,
                bytesBeforeFailure: before,
                expectedGeneration: UInt64(failedOperation.rawValue + 1),
                expectedFailedStage: failedOperation.stage
            )
        }
    }

    @Test func foreignReplayAndOutOfOrderCommandsPermanentlyFailClosed() throws {
        for failure in CommandIdentityFailure.allCases {
            let seed = try Self.seed()
            let secondaryCampaignID: String
            switch failure {
            case .foreign:
                secondaryCampaignID = "b20000000000000f"
            case .replay, .outOfOrder:
                secondaryCampaignID = seed.run.campaignID
            }
            let secondarySeed = try Self.seed(campaignID: secondaryCampaignID)
            defer {
                Self.remove(seed.output)
                Self.remove(secondarySeed.output)
            }
            let lease = try Self.lease(seed)
            let secondaryLease = try Self.lease(secondarySeed)
            let command: SpiceLiveRemoteFixtureLease.Command

            switch failure {
            case .foreign:
                command = try secondaryLease.nextCommand()
            case .replay:
                let stop = try lease.nextCommand()
                try lease.accept(result: Self.result(), for: stop)
                command = stop
            case .outOfOrder:
                try Self.advanceThroughStart(secondaryLease, seed: secondarySeed)
                command = try secondaryLease.nextCommand()
                let current = try lease.nextCommand()
                #expect(command.arguments.dropLast() == current.arguments.dropLast())
                #expect(command.arguments.last == "\(seed.configuration.base)/remote/status.sh")
            }
            let before = try Data(contentsOf: seed.output)
            #expect(throws: (any Error).self) {
                try lease.accept(result: Self.result(), for: command)
            }
            try Self.expectTerminalAndStable(
                lease,
                seed: seed,
                failedCommand: command,
                bytesBeforeFailure: before,
                expectedGeneration: failure == .replay ? 2 : 1
            )
        }
    }
}

private extension SpiceLiveRemoteFixtureLeaseTests {
    struct Seed {
        let plan: SpiceLiveCampaignPlan
        let run: SpiceLiveCampaignRun
        let contract: SpiceLiveCampaignExecutionContract
        let configuration: SpiceRemoteLiveConfiguration
        let recorder: SpiceLiveRealtimeStageRecorder
        let writer: SpiceLiveCampaignManifestWriter
        let output: URL
    }

    enum ReservedResultMutation: CaseIterable {
        case missingReservedField
        case duplicateReservedField
        case wrongRunIdentity
        case wrongContract
        case wrongContainer
        case wrongPorts
        case invalidStartEvidence
        case staleEvidence

        func apply(to lines: inout [String], seed: Seed) {
            switch self {
            case .missingReservedField:
                lines.removeAll { $0.hasPrefix("control_listener=") }
            case .duplicateReservedField:
                lines.append("container=\(seed.configuration.container)")
            case .wrongRunIdentity:
                Self.replace("logical_run_id", with: "ffffffffffffffff", in: &lines)
                Self.replace("version", with: "v9.9.9", in: &lines)
                Self.replace("cluster_id", with: "ffffffffffffffff", in: &lines)
            case .wrongContract:
                Self.replace(
                    "execution_contract_digest",
                    with: String(repeating: "f", count: 64),
                    in: &lines
                )
            case .wrongContainer:
                Self.replace("container", with: "foreign-container", in: &lines)
            case .wrongPorts:
                Self.replace("spice", with: "127.0.0.1:65530", in: &lines)
            case .invalidStartEvidence:
                preconditionFailure("handled before the health result is built")
            case .staleEvidence:
                Self.replace(
                    "run_evidence",
                    with: "\(seed.configuration.base)/logs/20260830T120000Z.Stale1",
                    in: &lines
                )
            }
        }

        fileprivate static func replace(
            _ key: String,
            with value: String,
            in lines: inout [String]
        ) {
            let index = lines.firstIndex { $0.hasPrefix("\(key)=") }!
            lines[index] = "\(key)=\(value)"
        }
    }

    enum StartEvidenceMutation: CaseIterable {
        case missing
        case duplicate
        case noncanonical
        case nested

        func apply(to lines: inout [String], seed: Seed) {
            switch self {
            case .missing:
                lines.removeAll { $0.hasPrefix("run_evidence=") }
            case .duplicate:
                lines.append(
                    "run_evidence=\(seed.configuration.base)/logs/"
                        + SpiceLiveRemoteFixtureLeaseTests.evidenceID.rawValue
                )
            case .noncanonical:
                ReservedResultMutation.replace(
                    "run_evidence",
                    with: "\(seed.configuration.base)/logs/20260830T120000Z.bad-01",
                    in: &lines
                )
            case .nested:
                ReservedResultMutation.replace(
                    "run_evidence",
                    with: "\(seed.configuration.base)/logs/nested/"
                        + SpiceLiveRemoteFixtureLeaseTests.evidenceID.rawValue,
                    in: &lines
                )
            }
        }
    }

    enum LeaseOperation: Int, CaseIterable {
        case stop
        case start
        case health

        var stage: SpiceLiveAttemptStage {
            switch self {
            case .stop: .fixtureStop
            case .start: .fixtureStart
            case .health: .fixtureHealth
            }
        }
    }

    enum CommandIdentityFailure: CaseIterable {
        case foreign
        case replay
        case outOfOrder
    }

    static let evidenceID = try! SpiceLiveEvidenceRunID("20260830T120000Z.A1b2C3")

    static func seed(
        campaignID: String = "a20000000000000f"
    ) throws -> Seed {
        let fixture = try SpicePairedInteractionArtifactTests.makeFixture(
            pointerMode: .absolute
        )
        let plan = try SpiceLiveCampaignPlan(
            campaignID: campaignID,
            baselineVersion: fixture.specification.baselineVersion,
            candidateVersion: fixture.specification.candidateVersion,
            clusterIDs: fixture.specification.clusterIDs
        )
        let run = plan.runs[0]
        let metadata = try SpiceLiveCampaignManifestMetadata(
            baselineSourceCommit: String(repeating: "a", count: 40),
            candidateSourceCommit: String(repeating: "b", count: 40),
            toolchain: "Swift 6.3",
            hardware: "Apple Silicon test host",
            thermalState: .nominal,
            workload: "aip-00-paired-click-key-motion-v1",
            startedAtUTC: "2026-08-30T10:00:00Z"
        )
        let contract = try SpiceLiveCampaignExecutionContract(
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
        let configuration = try SpiceRemoteLiveConfiguration(environment: [
            "SWIFTSPICE_LIVE_INTERACTION": "1",
            "SWIFTSPICE_ROCKY_SSH_HOST": "rocky9",
            "SWIFTSPICE_PERF_BASE": "/home/beribeli/swiftspice-aip00h/perf-ab",
            "SWIFTSPICE_PERF_CONTAINER": "swiftspice-aip00h-qemu",
            "SWIFTSPICE_PERF_IMAGE": contract.remoteImageReference,
            "SWIFTSPICE_PERF_SPICE_PORT": "5945",
            "SWIFTSPICE_PERF_CONTROL_PORT": "5946",
            "SWIFTSPICE_LIVE_ENDPOINT_HOST": "127.0.0.1",
            "SWIFTSPICE_LIVE_ENDPOINT_PORT": "15945",
            "SWIFTSPICE_LIVE_VERSION": run.version,
            "SWIFTSPICE_LIVE_CLUSTER_ID": run.clusterID,
        ])
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-h2d1-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let output = directory.appending(path: "campaign-manifest.json")
        let writer = try SpiceLiveCampaignManifestWriter(outputURL: output)
        let recorder = try SpiceLiveRealtimeStageRecorder(
            plan: plan,
            metadata: metadata,
            executionContract: contract,
            manifestWriter: writer
        )
        return Seed(
            plan: plan,
            run: run,
            contract: contract,
            configuration: configuration,
            recorder: recorder,
            writer: writer,
            output: output
        )
    }

    static func lease(_ seed: Seed) throws -> SpiceLiveRemoteFixtureLease {
        try SpiceLiveRemoteFixtureLease(
            configuration: seed.configuration,
            run: seed.run,
            executionContractDigest: seed.contract.digest,
            recorder: seed.recorder
        )
    }

    static func expectedArguments(seed: Seed, script: String) -> [String] {
        [
            "-o", "BatchMode=yes", seed.configuration.sshHost, "/usr/bin/env",
            "SWIFTSPICE_PERF_BASE=\(seed.configuration.base)",
            "SWIFTSPICE_PERF_CONTAINER=\(seed.configuration.container)",
            "SWIFTSPICE_PERF_IMAGE=\(seed.configuration.image)",
            "SWIFTSPICE_PERF_SPICE_PORT=\(seed.configuration.spicePort)",
            "SWIFTSPICE_PERF_CONTROL_PORT=\(seed.configuration.controlPort)",
            "SWIFTSPICE_LIVE_CAMPAIGN_ID=\(seed.run.campaignID)",
            "SWIFTSPICE_LIVE_LOGICAL_RUN_ID=\(seed.run.runID)",
            "SWIFTSPICE_LIVE_VERSION=\(seed.run.version)",
            "SWIFTSPICE_LIVE_CLUSTER_ID=\(seed.run.clusterID)",
            "SWIFTSPICE_LIVE_RUN_SEQUENCE=\(seed.run.sequence)",
            "SWIFTSPICE_LIVE_EXECUTION_CONTRACT_DIGEST=\(seed.contract.digest)",
            "\(seed.configuration.base)/remote/\(script)",
        ]
    }

    static func expectStructuredSSH(
        _ command: SpiceLiveRemoteFixtureLease.Command
    ) {
        #expect(command.executableURL.path == "/usr/bin/ssh")
        #expect(!command.arguments.contains("sh"))
        #expect(!command.arguments.contains("bash"))
        #expect(!command.arguments.contains("-c"))
        #expect(command.arguments.allSatisfy { argument in
            !argument.contains(";")
                && !argument.contains("|")
                && !argument.contains("&")
                && !argument.contains("$")
                && !argument.contains("`")
                && !argument.contains("\n")
        })
    }

    static func result(
        status: Int32 = 0,
        lines: [String] = []
    ) -> SpiceLiveProcessResult {
        SpiceLiveProcessResult(
            status: status,
            standardOutput: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n",
            standardError: ""
        )
    }

    static func startResult(_ seed: Seed) -> SpiceLiveProcessResult {
        result(lines: startLines(seed))
    }

    static func startLines(_ seed: Seed) -> [String] {
        [
            "podman: created owned container",
            "run_evidence=\(seed.configuration.base)/logs/\(evidenceID.rawValue)",
        ]
    }

    static func healthResult(_ seed: Seed) -> SpiceLiveProcessResult {
        result(lines: healthLines(seed))
    }

    static func healthLines(_ seed: Seed) -> [String] {
        [
            "podman: diagnostic line retained",
            "campaign_id=\(seed.run.campaignID)",
            "logical_run_id=\(seed.run.runID)",
            "version=\(seed.run.version)",
            "cluster_id=\(seed.run.clusterID)",
            "run_sequence=\(seed.run.sequence)",
            "execution_contract_digest=\(seed.contract.digest)",
            "state=running",
            "container=\(seed.configuration.container)",
            "spice=127.0.0.1:\(seed.configuration.spicePort)",
            "control=127.0.0.1:\(seed.configuration.controlPort)",
            "run_evidence=\(seed.configuration.base)/logs/\(evidenceID.rawValue)",
            "spice_listener=ready",
            "control_listener=ready",
            "podman: another diagnostic line retained",
        ]
    }

    static func acceptStop(
        _ lease: SpiceLiveRemoteFixtureLease,
        seed: Seed
    ) throws {
        let stop = try lease.nextCommand()
        #expect(stop.arguments.last == "\(seed.configuration.base)/remote/stop.sh")
        try lease.accept(result: result(), for: stop)
    }

    static func advanceThroughStart(
        _ lease: SpiceLiveRemoteFixtureLease,
        seed: Seed
    ) throws {
        try acceptStop(lease, seed: seed)
        let start = try lease.nextCommand()
        #expect(start.arguments.last == "\(seed.configuration.base)/remote/start.sh")
        try lease.accept(result: startResult(seed), for: start)
    }

    static func expectInvalidStartEvidence(
        _ mutation: StartEvidenceMutation
    ) throws {
        let seed = try seed()
        defer { remove(seed.output) }
        let lease = try lease(seed)
        try acceptStop(lease, seed: seed)
        let start = try lease.nextCommand()
        let before = try Data(contentsOf: seed.output)
        var lines = startLines(seed)
        mutation.apply(to: &lines, seed: seed)

        #expect(throws: (any Error).self) {
            try lease.accept(result: result(lines: lines), for: start)
        }
        try expectTerminalAndStable(
            lease,
            seed: seed,
            failedCommand: start,
            bytesBeforeFailure: before,
            expectedGeneration: 2,
            expectedFailedStage: .fixtureStart
        )
    }

    static func expectDurable(
        _ seed: Seed,
        generation: UInt64,
        stages: [SpiceLiveAttemptStage],
        evidenceRunID: SpiceLiveEvidenceRunID?
    ) throws {
        let loaded = try seed.writer.load()
        let persisted = try #require(loaded)
        #expect(persisted == seed.recorder.snapshot)
        #expect(persisted.generation == generation)
        #expect(persisted.state == .recording)
        #expect(persisted.stages.map(\.stage) == stages)
        #expect(persisted.stages.allSatisfy { $0.outcome == .succeeded })
        #expect(persisted.runs[0].evidenceRunID == evidenceRunID)
    }

    static func expectTerminalAndStable(
        _ lease: SpiceLiveRemoteFixtureLease,
        seed: Seed,
        failedCommand: SpiceLiveRemoteFixtureLease.Command,
        bytesBeforeFailure: Data,
        expectedGeneration: UInt64,
        expectedFailedStage: SpiceLiveAttemptStage? = nil
    ) throws {
        let failedBytes = try Data(contentsOf: seed.output)
        #expect(failedBytes != bytesBeforeFailure)
        let loaded = try seed.writer.load()
        let failed = try #require(loaded)
        #expect(failed == seed.recorder.snapshot)
        #expect(failed.state == .failed)
        #expect(failed.generation == expectedGeneration)
        if let expectedFailedStage {
            #expect(failed.stages.last?.stage == expectedFailedStage)
            #expect(failed.stages.last?.outcome == .failed)
        }
        #expect(throws: (any Error).self) { _ = try lease.nextCommand() }
        #expect(throws: (any Error).self) {
            try lease.accept(result: result(), for: failedCommand)
        }
        let bytesAfterRepeatedCalls = try Data(contentsOf: seed.output)
        #expect(bytesAfterRepeatedCalls == failedBytes)
        let reloaded = try seed.writer.load()
        let repeated = try #require(reloaded)
        #expect(repeated == failed)
    }

    static func remove(_ output: URL) {
        try? FileManager.default.removeItem(at: output.deletingLastPathComponent())
    }
}
