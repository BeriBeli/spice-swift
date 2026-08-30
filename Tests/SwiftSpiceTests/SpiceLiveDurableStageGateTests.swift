import Darwin
import Foundation
import Synchronization
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live durable child stage protocol")
struct SpiceLiveDurableStageGateTests {
    @Test func canonicalFramesAreV1BoundedAndExactlySingleLine() throws {
        let fixture = try Self.gateFixture()
        defer { Self.removeOutput(fixture.output) }
        let event = try Self.event(
            fixture: fixture,
            stage: .preArm,
            sequence: 1,
            previousGeneration: 3
        )

        let eventFrame = try SpiceLiveStageProtocolCodec.encodeEvent(event)
        #expect(eventFrame.count <= SpiceLiveStageProtocolCodec.maximumFrameBytes)
        #expect(eventFrame.count <= 4_096)
        #expect(eventFrame.last == 0x0a)
        #expect(!eventFrame.dropLast().contains(0x0a))
        let decodedEvent = try SpiceLiveStageProtocolCodec.decodeEvent(eventFrame)
        let reencodedEvent = try SpiceLiveStageProtocolCodec.encodeEvent(event)
        #expect(decodedEvent == event)
        #expect(reencodedEvent == eventFrame)

        let acknowledgement = try fixture.gate.accept(event)
        let durableBytes = try Data(contentsOf: fixture.output)
        let loadedManifest = try fixture.writer.load()
        let loaded = try #require(loadedManifest)
        let canonicalLoadedBytes = try Self.canonicalManifestData(loaded)
        #expect(loaded.generation == 4)
        #expect(loaded.stages.count == 4)
        #expect(durableBytes == canonicalLoadedBytes)
        #expect(acknowledgement.protocolVersion == .v1)
        #expect(acknowledgement.campaignID == event.campaignID)
        #expect(acknowledgement.runID == event.runID)
        #expect(acknowledgement.version == event.version)
        #expect(acknowledgement.clusterID == event.clusterID)
        #expect(acknowledgement.evidenceRunID == event.evidenceRunID)
        #expect(acknowledgement.actionClass == event.actionClass)
        #expect(acknowledgement.order == event.order)
        #expect(acknowledgement.token == event.token)
        #expect(acknowledgement.checksum == event.checksum)
        #expect(acknowledgement.stage == event.stage)
        #expect(acknowledgement.outcome == event.outcome)
        #expect(acknowledgement.eventSequence == event.eventSequence)
        #expect(
            acknowledgement.previousManifestGeneration
                == event.previousManifestGeneration
        )
        #expect(acknowledgement.durableManifestGeneration == loaded.generation)

        let acknowledgementFrame = try SpiceLiveStageProtocolCodec
            .encodeAcknowledgement(acknowledgement)
        #expect(
            acknowledgementFrame.count
                <= SpiceLiveStageProtocolCodec.maximumFrameBytes
        )
        #expect(acknowledgementFrame.last == 0x0a)
        #expect(!acknowledgementFrame.dropLast().contains(0x0a))
        let acknowledgementJSONObject = try JSONSerialization.jsonObject(
            with: acknowledgementFrame
        )
        guard let acknowledgementObject = acknowledgementJSONObject
            as? [String: Any] else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        #expect(Set(acknowledgementObject.keys) == Set(Self.acknowledgementRequiredKeys))
        let decodedAcknowledgement = try SpiceLiveStageProtocolCodec
            .decodeAcknowledgement(acknowledgementFrame)
        #expect(decodedAcknowledgement == acknowledgement)
    }

    @Test func codecRejectsUnknownDuplicateMissingAndNoncanonicalFrames() throws {
        let fixture = try Self.gateFixture()
        defer { Self.removeOutput(fixture.output) }
        let event = try Self.event(
            fixture: fixture,
            stage: .preArm,
            sequence: 1,
            previousGeneration: 3
        )
        let canonical = try SpiceLiveStageProtocolCodec.encodeEvent(event)
        let decodedObject = try JSONSerialization.jsonObject(with: canonical)
        guard let object = decodedObject as? [String: Any] else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }

        var malformed: [Data] = []
        var unknown = object
        unknown["unknown"] = true
        malformed.append(try Self.canonicalFrame(unknown))
        malformed.append(try Self.duplicateField("campaign_id", in: canonical))
        for key in Self.eventRequiredKeys {
            var missing = object
            missing.removeValue(forKey: key)
            malformed.append(try Self.canonicalFrame(missing))

            var null = object
            null[key] = NSNull()
            malformed.append(try Self.canonicalFrame(null))
        }
        for (key, value) in [
            ("protocol_version", "v2"),
            ("campaign_id", "A10000000000000f"),
            ("run_id", "1000000000000000/child"),
            ("version", "v0.2.7\n"),
            ("cluster_id", "000000000000000G"),
            ("evidence_run_id", "20260831T000000Z.bad/ID"),
            ("token", "ABCDEF0123456789"),
            ("stage", "fixture_start"),
            ("outcome", "unknown"),
        ] {
            var mutated = object
            mutated[key] = value
            malformed.append(try Self.canonicalFrame(mutated))
        }
        malformed.append(Data(" \(String(decoding: canonical, as: UTF8.self))".utf8))
        malformed.append(Data(canonical.dropLast()))
        malformed.append(canonical + Data("\n".utf8))
        malformed.append(Data(repeating: 0x20, count: 4_097))

        for frame in malformed {
            #expect(throws: (any Error).self) {
                _ = try SpiceLiveStageProtocolCodec.decodeEvent(frame)
            }
        }

        let acknowledgement = try fixture.gate.accept(event)
        let acknowledgementFrame = try SpiceLiveStageProtocolCodec
            .encodeAcknowledgement(acknowledgement)
        let decodedAcknowledgementObject = try JSONSerialization.jsonObject(
            with: acknowledgementFrame
        )
        guard let acknowledgementObject = decodedAcknowledgementObject
            as? [String: Any] else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        var malformedAcknowledgements: [Data] = []
        var unknownAcknowledgement = acknowledgementObject
        unknownAcknowledgement["unknown"] = true
        malformedAcknowledgements.append(
            try Self.canonicalFrame(unknownAcknowledgement)
        )
        malformedAcknowledgements.append(
            try Self.duplicateField("event_sequence", in: acknowledgementFrame)
        )
        for key in Self.acknowledgementRequiredKeys {
            var missing = acknowledgementObject
            missing.removeValue(forKey: key)
            malformedAcknowledgements.append(try Self.canonicalFrame(missing))

            var null = acknowledgementObject
            null[key] = NSNull()
            malformedAcknowledgements.append(try Self.canonicalFrame(null))
        }
        malformedAcknowledgements.append(
            Data(" \(String(decoding: acknowledgementFrame, as: UTF8.self))".utf8)
        )
        malformedAcknowledgements.append(Data(acknowledgementFrame.dropLast()))
        malformedAcknowledgements.append(acknowledgementFrame + Data("\n".utf8))
        malformedAcknowledgements.append(Data(repeating: 0x20, count: 4_097))
        for frame in malformedAcknowledgements {
            #expect(throws: (any Error).self) {
                _ = try SpiceLiveStageProtocolCodec.decodeAcknowledgement(frame)
            }
        }
    }

    @Test func everyActionStageIsDurableBeforeItsAcknowledgementExists() throws {
        let fixture = try Self.gateFixture()
        defer { Self.removeOutput(fixture.output) }
        var eventSequence: UInt64 = 1
        var generation: UInt64 = 3

        for step in fixture.run.steps {
            for stage in Self.actionStages {
                let bytesBefore = try Data(contentsOf: fixture.output)
                let event = try Self.event(
                    fixture: fixture,
                    step: step,
                    stage: stage,
                    sequence: eventSequence,
                    previousGeneration: generation
                )
                let acknowledgement = try fixture.gate.accept(event)

                let bytesAfter = try Data(contentsOf: fixture.output)
                let loadedManifest = try fixture.writer.load()
                let persisted = try #require(loadedManifest)
                let canonicalPersisted = try Self.canonicalManifestData(persisted)
                #expect(bytesAfter != bytesBefore)
                #expect(bytesAfter == canonicalPersisted)
                #expect(persisted.generation == generation + 1)
                #expect(persisted.stages.last?.stage == stage)
                #expect(persisted.stages.last?.actionClass == step.actionClass)
                #expect(persisted.stages.last?.order == step.order)
                #expect(acknowledgement.durableManifestGeneration == persisted.generation)
                #expect(fixture.gate.pendingAcknowledgement == acknowledgement)

                try fixture.gate.acknowledgementDelivered(acknowledgement)
                #expect(fixture.gate.pendingAcknowledgement == nil)
                eventSequence += 1
                generation += 1
            }
        }

        #expect(eventSequence == 10)
        #expect(generation == 12)
        #expect(fixture.gate.isCompleted)
        #expect(!fixture.gate.isTerminal)
        let loadedManifest = try fixture.writer.load()
        let persisted = try #require(loadedManifest)
        #expect(persisted.generation == 12)
        #expect(Array(persisted.stages.suffix(9).map(\.stage)) == [
            .preArm, .arm, .postArm,
            .preArm, .arm, .postArm,
            .preArm, .arm, .postArm,
        ])
    }

    @Test func acknowledgementMustBeConfirmedBeforeTheNextEvent() throws {
        let fixture = try Self.gateFixture()
        defer { Self.removeOutput(fixture.output) }
        let first = try Self.event(
            fixture: fixture,
            stage: .preArm,
            sequence: 1,
            previousGeneration: 3
        )
        let acknowledgement = try fixture.gate.accept(first)
        let second = try Self.event(
            fixture: fixture,
            stage: .arm,
            sequence: 2,
            previousGeneration: 4
        )

        #expect(throws: (any Error).self) {
            _ = try fixture.gate.accept(second)
        }
        #expect(fixture.gate.isTerminal)
        #expect(fixture.gate.pendingAcknowledgement == acknowledgement)
        let loadedManifest = try fixture.writer.load()
        let persisted = try #require(loadedManifest)
        #expect(persisted.state == .failed)
        #expect(persisted.stages.last?.stage == .preArm)
        #expect(!persisted.stages.contains { $0.stage == .arm })
    }

    @Test func wrongIdentityReplayOrderAndStaleGenerationFailClosed() throws {
        let cases: [(Self.GateFixture) throws -> SpiceLiveChildStageEvent] = [
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .arm,
                    sequence: 1,
                    previousGeneration: 3
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 2,
                    previousGeneration: 3
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 2
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    campaignID: "b10000000000000f"
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    runID: "0000000000000000"
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    version: "v0.3.4"
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    clusterID: "0000000000000001"
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    evidenceRunID: SpiceLiveEvidenceRunID(
                        "20260831T000000Z.Z9y8X7"
                    )
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    actionClass: .key
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    order: 2
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    token: "0000000000000000"
                )
            },
            { fixture in
                try Self.event(
                    fixture: fixture,
                    stage: .preArm,
                    sequence: 1,
                    previousGeneration: 3,
                    checksum: 0
                )
            },
        ]

        for makeInvalidEvent in cases {
            let fixture = try Self.gateFixture()
            defer { Self.removeOutput(fixture.output) }
            let invalid = try makeInvalidEvent(fixture)
            #expect(throws: (any Error).self) {
                _ = try fixture.gate.accept(invalid)
            }
            #expect(fixture.gate.isTerminal)
            let loadedManifest = try fixture.writer.load()
            let persisted = try #require(loadedManifest)
            #expect(persisted.state == .failed)
            #expect(persisted.stages.count == 3)
        }

        let replayFixture = try Self.gateFixture()
        defer { Self.removeOutput(replayFixture.output) }
        let event = try Self.event(
            fixture: replayFixture,
            stage: .preArm,
            sequence: 1,
            previousGeneration: 3
        )
        let acknowledgement = try replayFixture.gate.accept(event)
        try replayFixture.gate.acknowledgementDelivered(acknowledgement)
        #expect(throws: (any Error).self) {
            _ = try replayFixture.gate.accept(event)
        }
        #expect(replayFixture.gate.isTerminal)
        let loadedReplayManifest = try replayFixture.writer.load()
        let replayPersisted = try #require(loadedReplayManifest)
        #expect(replayPersisted.state == .failed)
        #expect(replayPersisted.stages.filter { $0.stage == .preArm }.count == 1)
    }

    @Test func acknowledgementDeliveryRequiresTheExactPendingIdentity() throws {
        for mutatedKey in [
            "campaign_id",
            "token",
            "previous_manifest_generation",
            "durable_manifest_generation",
        ] {
            let fixture = try Self.gateFixture()
            defer { Self.removeOutput(fixture.output) }
            let event = try Self.event(
                fixture: fixture,
                stage: .preArm,
                sequence: 1,
                previousGeneration: 3
            )
            let pending = try fixture.gate.accept(event)
            let encoded = try SpiceLiveStageProtocolCodec
                .encodeAcknowledgement(pending)
            let decoded = try JSONSerialization.jsonObject(with: encoded)
            guard var object = decoded as? [String: Any] else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
            switch mutatedKey {
            case "campaign_id": object[mutatedKey] = "b10000000000000f"
            case "token": object[mutatedKey] = "0000000000000000"
            case "previous_manifest_generation": object[mutatedKey] = 2
            case "durable_manifest_generation": object[mutatedKey] = 5
            default: throw SpiceLiveCampaignManifestError.invalidManifest
            }
            let wrong = try SpiceLiveStageProtocolCodec.decodeAcknowledgement(
                Self.canonicalFrame(object)
            )

            #expect(throws: (any Error).self) {
                try fixture.gate.acknowledgementDelivered(wrong)
            }
            #expect(fixture.gate.isTerminal)
            #expect(throws: (any Error).self) {
                try fixture.gate.acknowledgementDelivered(pending)
            }
        }
    }

    @Test func childReportedFailureIsDurableAndCannotAdvance() throws {
        let fixture = try Self.gateFixture()
        defer { Self.removeOutput(fixture.output) }
        let failedEvent = try Self.event(
            fixture: fixture,
            stage: .preArm,
            outcome: .failed,
            sequence: 1,
            previousGeneration: 3
        )
        let acknowledgement = try fixture.gate.accept(failedEvent)
        let loadedManifest = try fixture.writer.load()
        let persisted = try #require(loadedManifest)
        #expect(persisted.generation == 4)
        #expect(persisted.state == .failed)
        #expect(persisted.stages.last?.outcome == .failed)
        #expect(acknowledgement.outcome == .failed)

        try fixture.gate.acknowledgementDelivered(acknowledgement)
        #expect(fixture.gate.isTerminal)
        let next = try Self.event(
            fixture: fixture,
            stage: .arm,
            sequence: 2,
            previousGeneration: 4
        )
        #expect(throws: (any Error).self) {
            _ = try fixture.gate.accept(next)
        }
    }

    @Test func persistenceFailureProducesNoAcknowledgementAndNoRetry() throws {
        let syncCalls = Mutex(0)
        let fixture = try Self.gateFixture(directorySync: { descriptor in
            let call = syncCalls.withLock { count in
                count += 1
                return count
            }
            if call == 5 {
                throw SpiceLiveCampaignManifestError.fileOperationFailed(
                    operation: "fsync_directory",
                    code: EIO
                )
            }
            guard Darwin.fsync(descriptor) == 0 else {
                throw SpiceLiveCampaignManifestError.fileOperationFailed(
                    operation: "fsync_directory",
                    code: errno
                )
            }
        })
        defer { Self.removeOutput(fixture.output) }
        #expect(syncCalls.withLock { $0 } == 4)
        let event = try Self.event(
            fixture: fixture,
            stage: .preArm,
            sequence: 1,
            previousGeneration: 3
        )

        #expect(throws: (any Error).self) {
            _ = try fixture.gate.accept(event)
        }
        #expect(syncCalls.withLock { $0 } == 5)
        #expect(fixture.gate.pendingAcknowledgement == nil)
        #expect(fixture.gate.isTerminal)
        let bytesAfterFailure = try Data(contentsOf: fixture.output)
        #expect(throws: (any Error).self) {
            _ = try fixture.gate.accept(event)
        }
        let bytesAfterRetry = try Data(contentsOf: fixture.output)
        #expect(bytesAfterRetry == bytesAfterFailure)
        #expect(syncCalls.withLock { $0 } == 5)
    }

    @Test func acknowledgementFailureEOFAndCancellationAreTerminalOnce() throws {
        for failure in Self.GateFailure.allCases {
            let fixture = try Self.gateFixture()
            defer { Self.removeOutput(fixture.output) }
            let event = try Self.event(
                fixture: fixture,
                stage: .preArm,
                sequence: 1,
                previousGeneration: 3
            )
            let acknowledgement = try fixture.gate.accept(event)
            try failure.apply(to: fixture.gate, acknowledgement: acknowledgement)

            #expect(fixture.gate.isTerminal)
            let firstTerminalBytes = try Data(contentsOf: fixture.output)
            let loadedTerminalManifest = try fixture.writer.load()
            let firstTerminalManifest = try #require(loadedTerminalManifest)
            #expect(firstTerminalManifest.state == .failed)
            #expect(firstTerminalManifest.stages.count == 4)
            #expect(throws: (any Error).self) {
                try failure.apply(
                    to: fixture.gate,
                    acknowledgement: acknowledgement
                )
            }
            let repeatedTerminalBytes = try Data(contentsOf: fixture.output)
            let repeatedTerminalManifest = try fixture.writer.load()
            #expect(repeatedTerminalBytes == firstTerminalBytes)
            #expect(repeatedTerminalManifest == firstTerminalManifest)
            #expect(throws: (any Error).self) {
                _ = try fixture.gate.accept(event)
            }
        }
    }
}

private extension SpiceLiveDurableStageGateTests {
    struct GateFixture {
        let plan: SpiceLiveCampaignPlan
        let run: SpiceLiveCampaignRun
        let evidenceRunID: SpiceLiveEvidenceRunID
        let writer: SpiceLiveCampaignManifestWriter
        let recorder: SpiceLiveRealtimeStageRecorder
        let gate: SpiceLiveDurableStageGate
        let output: URL
    }

    enum GateFailure: CaseIterable {
        case acknowledgementDelivery
        case endOfFile
        case cancellation

        func apply(
            to gate: SpiceLiveDurableStageGate,
            acknowledgement: SpiceLiveStageAcknowledgement
        ) throws {
            switch self {
            case .acknowledgementDelivery:
                try gate.acknowledgementDeliveryFailed(acknowledgement)
            case .endOfFile:
                try gate.childReachedEOF()
            case .cancellation:
                try gate.cancel()
            }
        }
    }

    static let actionStages: [SpiceLiveAttemptStage] = [
        .preArm, .arm, .postArm,
    ]

    static let eventRequiredKeys = [
        "protocol_version",
        "campaign_id",
        "run_id",
        "version",
        "cluster_id",
        "evidence_run_id",
        "action_class",
        "order",
        "token",
        "checksum",
        "stage",
        "outcome",
        "event_sequence",
        "previous_manifest_generation",
    ]

    static let acknowledgementRequiredKeys = eventRequiredKeys + [
        "durable_manifest_generation",
    ]

    static func gateFixture(
        directorySync: (@Sendable (Int32) throws -> Void)? = nil
    ) throws -> GateFixture {
        let plan = try campaignPlan()
        let metadata = try campaignMetadata()
        let output = try outputURL()
        let writer: SpiceLiveCampaignManifestWriter
        if let directorySync {
            writer = try SpiceLiveCampaignManifestWriter(
                outputURL: output,
                directorySync: directorySync
            )
        } else {
            writer = try SpiceLiveCampaignManifestWriter(outputURL: output)
        }
        let recorder = try SpiceLiveRealtimeStageRecorder(
            plan: plan,
            metadata: metadata,
            executionContract: campaignExecutionContract(
                plan: plan,
                metadata: metadata
            ),
            manifestWriter: writer
        )
        let run = plan.runs[0]
        let evidenceRunID = try SpiceLiveEvidenceRunID(
            "20260831T000000Z.A1b2C3"
        )
        try recorder.record(
            run: run,
            stage: .fixtureStop,
            outcome: .succeeded
        )
        try recorder.record(
            run: run,
            stage: .fixtureStart,
            outcome: .succeeded,
            evidenceRunID: evidenceRunID
        )
        try recorder.record(
            run: run,
            stage: .fixtureHealth,
            outcome: .succeeded
        )
        let gate = try SpiceLiveDurableStageGate(
            plan: plan,
            recorder: recorder
        )
        return GateFixture(
            plan: plan,
            run: run,
            evidenceRunID: evidenceRunID,
            writer: writer,
            recorder: recorder,
            gate: gate,
            output: output
        )
    }

    static func event(
        fixture: GateFixture,
        step: SpiceLiveInteractionClusterPlan.Step? = nil,
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome = .succeeded,
        sequence: UInt64,
        previousGeneration: UInt64,
        campaignID: String? = nil,
        runID: String? = nil,
        version: String? = nil,
        clusterID: String? = nil,
        evidenceRunID: SpiceLiveEvidenceRunID? = nil,
        actionClass: SpiceInteractionActionClass? = nil,
        order: UInt64? = nil,
        token: String? = nil,
        checksum: UInt32? = nil
    ) throws -> SpiceLiveChildStageEvent {
        let selectedStep = step ?? fixture.run.steps[0]
        return try SpiceLiveChildStageEvent(
            protocolVersion: .v1,
            campaignID: campaignID ?? fixture.run.campaignID,
            runID: runID ?? fixture.run.runID,
            version: version ?? fixture.run.version,
            clusterID: clusterID ?? fixture.run.clusterID,
            evidenceRunID: evidenceRunID ?? fixture.evidenceRunID,
            actionClass: actionClass ?? selectedStep.actionClass,
            order: order ?? selectedStep.order,
            token: token ?? selectedStep.token,
            checksum: checksum ?? selectedStep.checksum,
            stage: stage,
            outcome: outcome,
            eventSequence: sequence,
            previousManifestGeneration: previousGeneration
        )
    }

    static func campaignPlan() throws -> SpiceLiveCampaignPlan {
        try SpiceLiveCampaignPlan(
            campaignID: "a10000000000000f",
            baselineVersion: "v0.2.7",
            candidateVersion: "v0.3.4",
            clusterIDs: (0..<10).map { String(format: "%016x", $0) }
        )
    }

    static func campaignMetadata() throws -> SpiceLiveCampaignManifestMetadata {
        try SpiceLiveCampaignManifestMetadata(
            baselineSourceCommit: String(repeating: "a", count: 40),
            candidateSourceCommit: String(repeating: "b", count: 40),
            toolchain: "Swift 6.3 / Xcode 27 beta",
            hardware: "Apple Silicon test host",
            thermalState: .nominal,
            workload: "aip-00-paired-click-key-motion-v1",
            startedAtUTC: "2026-08-31T00:00:00Z"
        )
    }

    static func campaignExecutionContract(
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

    static func outputURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-aip00h2b-stage-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory.appending(path: "campaign-manifest.json")
    }

    static func removeOutput(_ output: URL) {
        try? FileManager.default.removeItem(
            at: output.deletingLastPathComponent()
        )
    }

    static func canonicalManifestData(
        _ manifest: SpiceLiveCampaignManifest
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }

    static func canonicalFrame(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }

    static func duplicateField(_ key: String, in frame: Data) throws -> Data {
        let body = String(decoding: frame.dropLast(), as: UTF8.self)
        let prefix = "\"\(key)\":"
        guard let keyRange = body.range(of: prefix) else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        let valueStart = keyRange.upperBound
        let suffix = body[valueStart...]
        let valueEnd = suffix.firstIndex(of: ",") ?? suffix.firstIndex(of: "}")
        guard let valueEnd else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        let value = body[valueStart..<valueEnd]
        guard body.last == "}" else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        let duplicated = body.dropLast() + ",\"\(key)\":\(value)}\n"
        return Data(duplicated.utf8)
    }
}
