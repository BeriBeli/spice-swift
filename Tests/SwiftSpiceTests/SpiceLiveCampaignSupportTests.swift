import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live interaction campaign support")
struct SpiceLiveCampaignSupportTests {
    @Test func campaignPlanIsExactCounterbalancedAndDeterministic() throws {
        let clusters = Stage3LiveCampaignFixture.clusterIDs
        let plan = try Stage3LiveCampaignFixture.plan()
        let repeated = try Stage3LiveCampaignFixture.plan()

        #expect(plan.campaignID == Stage3LiveCampaignFixture.campaignID)
        #expect(plan.baselineVersion == "v0.2.7")
        #expect(plan.candidateVersion == "v0.3.3")
        #expect(plan.clusterIDs == clusters)
        #expect(plan.runs == repeated.runs)
        #expect(plan.runs.count == 20)
        #expect(plan.runs.flatMap(\.steps).count == 60)
        #expect(Set(plan.runs.map(\.runID)).count == 20)
        #expect(plan.runs.map(\.sequence) == Array(1...20).map(UInt64.init))

        var baselineFirstCount = 0
        var candidateFirstCount = 0
        var allTokens = Set<String>()
        var allPairIDs = Set<String>()
        for (clusterIndex, clusterID) in clusters.enumerated() {
            let pair = Array(plan.runs[(clusterIndex * 2)...(clusterIndex * 2 + 1)])
            #expect(pair.map(\.clusterID) == [clusterID, clusterID])
            #expect(pair.allSatisfy { $0.campaignID == plan.campaignID })
            #expect(pair.allSatisfy { $0.freshBootRequired })
            #expect(pair.allSatisfy { $0.automaticRetryLimit == 0 })
            #expect(pair[0].steps == pair[1].steps)
            #expect(pair[0].steps.map(\.order) == [1, 2, 3])
            #expect(pair[0].steps.map(\.actionClass) == [.click, .key, .motion])
            if clusterIndex < 5 {
                baselineFirstCount += 1
                #expect(pair.map(\.version) == ["v0.2.7", "v0.3.3"])
            } else {
                candidateFirstCount += 1
                #expect(pair.map(\.version) == ["v0.3.3", "v0.2.7"])
            }
            for step in pair[0].steps {
                #expect(allTokens.insert(step.token).inserted)
                #expect(allPairIDs.insert(step.pairID).inserted)
            }
        }
        #expect(baselineFirstCount == 5)
        #expect(candidateFirstCount == 5)
        #expect(allTokens.count == 30)
        #expect(allPairIDs.count == 30)

        let first = plan.runs[0].steps
        #expect(first[0].token == "471a5b01a43d3ed0")
        #expect(first[0].checksum == 0x8808_062b)
        #expect(first[0].pairID == "live-0000000000000000-1-click")
        #expect(first[1].token == "fe9d28fae6078b17")
        #expect(first[1].checksum == 0xe4c8_93ee)
        #expect(first[1].pairID == "live-0000000000000000-2-key")
        #expect(first[2].token == "51e34c49956dbf89")
        #expect(first[2].checksum == 0x1367_c5aa)
        #expect(first[2].pairID == "live-0000000000000000-3-motion")

        let differentCampaign = try SpiceLiveCampaignPlan(
            campaignID: "bbbbbbbbbbbbbbbb",
            baselineVersion: "v0.2.7",
            candidateVersion: "v0.3.3",
            clusterIDs: clusters
        )
        #expect(differentCampaign.runs.map(\.runID) != plan.runs.map(\.runID))
        #expect(differentCampaign.runs.flatMap(\.steps) == plan.runs.flatMap(\.steps))
    }

    @Test func campaignPlanRejectsAliasesMissingAndNoncanonicalIdentity() {
        let validClusters = Stage3LiveCampaignFixture.clusterIDs
        let invalidCampaignIDs = [
            "", "aaaaaaaaaaaaaaa", "aaaaaaaaaaaaaaaaa", "AAAAAAAAAAAAAAAA",
            "aaaaaaaaaaaaaaa;",
        ]
        for campaignID in invalidCampaignIDs {
            #expect(throws: SpiceLiveInteractionSupportError.invalidCampaignPlan) {
                _ = try Stage3LiveCampaignFixture.plan(campaignID: campaignID)
            }
        }

        let invalidVersions = [
            "0.2.7", "v00.2.7", "v0.02.7", "v0.2.07", "v0.2",
            "v0.2.7-beta", "v0.2.7\n", "v0.2.7 ", "v0.2.7.0",
        ]
        for version in invalidVersions {
            #expect(throws: SpiceLiveInteractionSupportError.invalidCampaignPlan) {
                _ = try SpiceLiveCampaignPlan(
                    campaignID: Stage3LiveCampaignFixture.campaignID,
                    baselineVersion: version,
                    candidateVersion: "v0.3.3",
                    clusterIDs: validClusters
                )
            }
        }
        #expect(throws: SpiceLiveInteractionSupportError.invalidCampaignPlan) {
            _ = try SpiceLiveCampaignPlan(
                campaignID: Stage3LiveCampaignFixture.campaignID,
                baselineVersion: "v0.2.7",
                candidateVersion: "v0.2.7",
                clusterIDs: validClusters
            )
        }

        var duplicateClusters = validClusters
        duplicateClusters[9] = duplicateClusters[0]
        var uppercaseClusters = validClusters
        uppercaseClusters[0] = "ABCDEF0000000000"
        for clusters in [
            Array(validClusters.dropLast()),
            validClusters + ["000000000000000a"],
            duplicateClusters,
            uppercaseClusters,
        ] {
            #expect(throws: SpiceLiveInteractionSupportError.invalidCampaignPlan) {
                _ = try SpiceLiveCampaignPlan(
                    campaignID: Stage3LiveCampaignFixture.campaignID,
                    baselineVersion: "v0.2.7",
                    candidateVersion: "v0.3.3",
                    clusterIDs: clusters
                )
            }
        }
    }

    @Test func executionProducesExactBoundedCanonicalLedger() throws {
        let plan = try Stage3LiveCampaignFixture.plan()
        var execution = SpiceLiveCampaignExecution(plan: plan)
        for expectedRun in plan.runs {
            let run = try execution.beginNextRun()
            #expect(run == expectedRun)
            try execution.record(stage: .fixtureStop, outcome: .succeeded)
            try execution.record(stage: .fixtureStart, outcome: .succeeded)
            try execution.record(stage: .fixtureHealth, outcome: .succeeded)
            for _ in run.steps {
                try execution.record(stage: .preArm, outcome: .succeeded)
                try execution.record(stage: .arm, outcome: .succeeded)
                try execution.record(stage: .postArm, outcome: .succeeded)
            }
            try execution.record(stage: .teardown, outcome: .succeeded)
        }

        #expect(execution.campaignCompleted)
        #expect(!execution.campaignFailed)
        #expect(execution.entries.count == 260)
        #expect(execution.entries.allSatisfy { $0.attemptNumber == 1 })
        for (runIndex, run) in plan.runs.enumerated() {
            let entries = Array(execution.entries[(runIndex * 13)...(runIndex * 13 + 12)])
            #expect(entries.map(\.stage) == [
                .fixtureStop, .fixtureStart, .fixtureHealth,
                .preArm, .arm, .postArm,
                .preArm, .arm, .postArm,
                .preArm, .arm, .postArm,
                .teardown,
            ])
            #expect(entries.map(\.order) == [
                1, 1, 1,
                1, 1, 1,
                2, 2, 2,
                3, 3, 3, 3,
            ])
            #expect(entries.map(\.actionClass) == [
                .click, .click, .click,
                .click, .click, .click,
                .key, .key, .key,
                .motion, .motion, .motion, .motion,
            ])
            #expect(entries.allSatisfy { entry in
                entry.campaignID == run.campaignID
                    && entry.runID == run.runID
                    && entry.version == run.version
                    && entry.clusterID == run.clusterID
                    && entry.runSequence == run.sequence
                    && entry.outcome == .succeeded
            })
        }

        let encoded = try JSONEncoder().encode(execution.entries[0])
        let object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(object.keys) == [
            "campaign_id", "run_id", "version", "cluster_id", "run_sequence",
            "action_class", "order", "checksum", "token", "attempt_number",
            "stage", "outcome",
        ])
        #expect(object["attempt_number"] as? Int == 1)
        #expect(object["stage"] as? String == "fixture_stop")
        #expect(object["outcome"] as? String == "succeeded")
        #expect(encoded.count < 512)
        #expect(throws: SpiceLiveInteractionSupportError.invalidExecutionTransition) {
            _ = try execution.beginNextRun()
        }
    }

    @Test func everyFailureStageIsLedgeredAndPermanentlyTerminal() throws {
        let plan = try Stage3LiveCampaignFixture.plan()
        for failedStage in [
            SpiceLiveAttemptStage.fixtureStop, .fixtureStart, .fixtureHealth,
            .preArm, .arm, .postArm, .teardown,
        ] {
            var execution = SpiceLiveCampaignExecution(plan: plan)
            let run = try execution.beginNextRun()
            try Stage3LiveCampaignFixture.advance(
                execution: &execution,
                toFailureAt: failedStage
            )
            let failure = try #require(execution.entries.last)
            #expect(execution.campaignFailed)
            #expect(!execution.campaignCompleted)
            #expect(failure.stage == failedStage)
            #expect(failure.outcome == .failed)
            #expect(failure.attemptNumber == 1)
            #expect(failure.runID == run.runID)
            if failedStage == .teardown {
                #expect(failure.actionClass == .motion)
                #expect(failure.order == 3)
            }
            #expect(throws: SpiceLiveInteractionSupportError.invalidExecutionTransition) {
                _ = try execution.beginNextRun()
            }
            #expect(throws: SpiceLiveInteractionSupportError.invalidExecutionTransition) {
                try execution.record(stage: failedStage, outcome: .succeeded)
            }
        }

        var wrongOrder = SpiceLiveCampaignExecution(plan: plan)
        _ = try wrongOrder.beginNextRun()
        #expect(throws: SpiceLiveInteractionSupportError.invalidExecutionTransition) {
            try wrongOrder.record(stage: .preArm, outcome: .succeeded)
        }
        #expect(wrongOrder.campaignFailed)
        #expect(wrongOrder.entries.isEmpty)

        let explicitNewPlan = try Stage3LiveCampaignFixture.plan(
            campaignID: "bbbbbbbbbbbbbbbb"
        )
        var explicitNewExecution = SpiceLiveCampaignExecution(plan: explicitNewPlan)
        #expect(try explicitNewExecution.beginNextRun() == explicitNewPlan.runs[0])
    }

    @Test func remoteConfigurationRequiresEveryExplicitCanonicalField() throws {
        let plan = try Stage3LiveCampaignFixture.plan()
        let run = plan.runs[0]
        let environment = Stage3LiveCampaignFixture.environment(for: run)
        let configuration = try SpiceRemoteLiveConfiguration(environment: environment)
        #expect(configuration.sshHost == "rocky9")
        #expect(configuration.base == "/var/tmp/swiftspice-aip00e")
        #expect(configuration.container == "swiftspice-v027-campaign")
        #expect(configuration.image == "localhost/swiftspice-v027:measured")
        #expect(configuration.spicePort == 15_945)
        #expect(configuration.controlPort == 15_946)
        #expect(configuration.endpointHost == "127.0.0.1")
        #expect(configuration.endpointPort == 25_945)
        #expect(configuration.campaignID == run.campaignID)
        #expect(configuration.runID == run.runID)
        #expect(configuration.version == run.version)
        #expect(configuration.clusterID == run.clusterID)

        var disabled = environment
        disabled["SWIFTSPICE_LIVE_INTERACTION"] = "0"
        #expect(throws: SpiceLiveInteractionSupportError.notExplicitlyEnabled) {
            _ = try SpiceRemoteLiveConfiguration(environment: disabled)
        }
        for key in environment.keys where key != "SWIFTSPICE_LIVE_INTERACTION" {
            var incomplete = environment
            incomplete.removeValue(forKey: key)
            #expect(throws: SpiceLiveInteractionSupportError.incompleteConfiguration) {
                _ = try SpiceRemoteLiveConfiguration(environment: incomplete)
            }
        }

        let invalidValues: [(String, String)] = [
            ("SWIFTSPICE_ROCKY_SSH_HOST", "-oProxyCommand=id"),
            ("SWIFTSPICE_ROCKY_SSH_HOST", "rocky9;id"),
            ("SWIFTSPICE_PERF_BASE", "/var/tmp/live path"),
            ("SWIFTSPICE_PERF_BASE", "/var/tmp/live;id"),
            ("SWIFTSPICE_PERF_BASE", "/var/tmp/live/../escape"),
            ("SWIFTSPICE_PERF_CONTAINER", "swiftspice-perf-ab-qemu"),
            ("SWIFTSPICE_PERF_CONTAINER", "campaign$(id)"),
            ("SWIFTSPICE_PERF_IMAGE", "localhost/image:tag|id"),
            ("SWIFTSPICE_PERF_SPICE_PORT", "15945;id"),
            ("SWIFTSPICE_PERF_CONTROL_PORT", "$(id)"),
            ("SWIFTSPICE_LIVE_ENDPOINT_HOST", "127.0.0.1;id"),
            ("SWIFTSPICE_LIVE_ENDPOINT_PORT", "15945\n"),
            ("SWIFTSPICE_LIVE_CAMPAIGN_ID", "AAAAAAAAAAAAAAAA"),
            ("SWIFTSPICE_LIVE_RUN_ID", "0000000000000000`"),
            ("SWIFTSPICE_LIVE_VERSION", "v0.2.7\r\n"),
            ("SWIFTSPICE_LIVE_CLUSTER_ID", "0000000000000000&"),
        ]
        for (key, value) in invalidValues {
            var invalid = environment
            invalid[key] = value
            #expect(throws: SpiceLiveInteractionSupportError.invalidConfiguration) {
                _ = try SpiceRemoteLiveConfiguration(environment: invalid)
            }
        }

        var historicalPorts = environment
        historicalPorts["SWIFTSPICE_PERF_SPICE_PORT"] = "5935"
        historicalPorts["SWIFTSPICE_PERF_CONTROL_PORT"] = "5936"
        #expect(throws: SpiceLiveInteractionSupportError.invalidConfiguration) {
            _ = try SpiceRemoteLiveConfiguration(environment: historicalPorts)
        }
        var historicalBase = environment
        historicalBase["SWIFTSPICE_PERF_BASE"] = "/tmp/swiftspice-remote-closure/perf-ab"
        #expect(throws: SpiceLiveInteractionSupportError.invalidConfiguration) {
            _ = try SpiceRemoteLiveConfiguration(environment: historicalBase)
        }
    }

    @Test func freshBootCommandsUseOnlyStructuredArgumentsAndExactRunIdentity() throws {
        let plan = try Stage3LiveCampaignFixture.plan()
        let run = plan.runs[0]
        let configuration = try SpiceRemoteLiveConfiguration(
            environment: Stage3LiveCampaignFixture.environment(for: run)
        )
        let commands = try configuration.freshBootCommands(for: run)
        #expect(commands.count == 3)
        #expect(commands == [
            SpiceRemoteFixtureOperation.stop.command(configuration: configuration),
            SpiceRemoteFixtureOperation.start.command(configuration: configuration),
            SpiceRemoteFixtureOperation.health.command(configuration: configuration),
        ])
        #expect(commands.map(\.executable) == Array(repeating: "/usr/bin/ssh", count: 3))
        #expect(commands.map { $0.arguments.last } == [
            configuration.paths.stopScript,
            configuration.paths.startScript,
            configuration.paths.healthScript,
        ])
        #expect(commands.allSatisfy { command in
            command.arguments.prefix(4) == ["-o", "BatchMode=yes", "rocky9", "/usr/bin/env"]
        })
        #expect(commands.allSatisfy { command in
            !command.arguments.contains("bash")
                && !command.arguments.contains("-c")
                && !command.arguments.contains(where: { $0.localizedCaseInsensitiveContains("reset") })
        })
        let expectedAssignments = [
            "SWIFTSPICE_PERF_BASE=/var/tmp/swiftspice-aip00e",
            "SWIFTSPICE_PERF_CONTAINER=swiftspice-v027-campaign",
            "SWIFTSPICE_PERF_IMAGE=localhost/swiftspice-v027:measured",
            "SWIFTSPICE_PERF_SPICE_PORT=15945",
            "SWIFTSPICE_PERF_CONTROL_PORT=15946",
            "SWIFTSPICE_LIVE_CAMPAIGN_ID=\(run.campaignID)",
            "SWIFTSPICE_LIVE_RUN_ID=\(run.runID)",
            "SWIFTSPICE_LIVE_VERSION=\(run.version)",
            "SWIFTSPICE_LIVE_CLUSTER_ID=\(run.clusterID)",
        ]
        #expect(commands.allSatisfy { command in
            expectedAssignments.allSatisfy(command.arguments.contains)
        })
        let expectedPaths = try SpiceRemoteFixturePaths(
            base: "/var/tmp/swiftspice-aip00e"
        )
        #expect(configuration.paths == expectedPaths)
        #expect(configuration.paths.logsDirectory == "/var/tmp/swiftspice-aip00e/logs")

        let mismatchedRuns = [plan.runs[1], plan.runs[2]]
        for mismatch in mismatchedRuns {
            #expect(throws: SpiceLiveInteractionSupportError.invalidConfiguration) {
                _ = try configuration.freshBootCommands(for: mismatch)
            }
        }
        #expect(throws: SpiceLiveInteractionSupportError.invalidConfiguration) {
            _ = try SpiceRemoteFixturePaths(base: "/var/tmp/live/../escape")
        }
    }

    @Test func pointerModeSnapshotControlsOnlyMotionAcknowledgement() throws {
        let steps = try SpiceLiveInteractionClusterPlan(
            clusterID: "0000000000000000"
        ).steps
        let click = steps[0]
        let key = steps[1]
        let motion = steps[2]
        for mode in [SpicePointerMode.relative, .absolute] {
            #expect(!click.requiresMotionAcknowledgement(for: mode))
            #expect(!key.requiresMotionAcknowledgement(for: mode))
        }
        #expect(motion.requiresMotionAcknowledgement(for: .relative))
        #expect(!motion.requiresMotionAcknowledgement(for: .absolute))
        #expect(click.inputs(for: .relative) == [
            .mousePress(.left), .mouseRelease(.left),
        ])
        #expect(key.inputs(for: .absolute) == [
            .keyDown(scanCode: 0x1e), .keyUp(scanCode: 0x1e),
        ])
        #expect(motion.inputs(for: .relative) == [.mouseMotion(dx: 1, dy: 1)])
        let x = 160 + (UInt32(motion.token.prefix(2), radix: 16) ?? 0) % 64
        let y = 120 + (UInt32(motion.token.dropFirst(2).prefix(2), radix: 16) ?? 0) % 64
        #expect(motion.inputs(for: .absolute) == [
            .mousePosition(x: x, y: y, displayID: 0),
        ])

        let session = SpiceSession()
        #expect(session.currentPointerMode == .absolute)
        session.desktop.updatePointerMode(.relative)
        #expect(session.currentPointerMode == .relative)
    }
}

private enum Stage3LiveCampaignFixture {
    static let campaignID = "aaaaaaaaaaaaaaaa"
    static let clusterIDs = (0..<10).map { String(format: "%016x", $0) }

    static func plan(campaignID: String = campaignID) throws -> SpiceLiveCampaignPlan {
        try SpiceLiveCampaignPlan(
            campaignID: campaignID,
            baselineVersion: "v0.2.7",
            candidateVersion: "v0.3.3",
            clusterIDs: clusterIDs
        )
    }

    static func environment(for run: SpiceLiveCampaignRun) -> [String: String] {
        [
            "SWIFTSPICE_LIVE_INTERACTION": "1",
            "SWIFTSPICE_ROCKY_SSH_HOST": "rocky9",
            "SWIFTSPICE_PERF_BASE": "/var/tmp/swiftspice-aip00e",
            "SWIFTSPICE_PERF_CONTAINER": "swiftspice-v027-campaign",
            "SWIFTSPICE_PERF_IMAGE": "localhost/swiftspice-v027:measured",
            "SWIFTSPICE_PERF_SPICE_PORT": "15945",
            "SWIFTSPICE_PERF_CONTROL_PORT": "15946",
            "SWIFTSPICE_LIVE_ENDPOINT_HOST": "127.0.0.1",
            "SWIFTSPICE_LIVE_ENDPOINT_PORT": "25945",
            "SWIFTSPICE_LIVE_CAMPAIGN_ID": run.campaignID,
            "SWIFTSPICE_LIVE_RUN_ID": run.runID,
            "SWIFTSPICE_LIVE_VERSION": run.version,
            "SWIFTSPICE_LIVE_CLUSTER_ID": run.clusterID,
        ]
    }

    static func advance(
        execution: inout SpiceLiveCampaignExecution,
        toFailureAt failedStage: SpiceLiveAttemptStage
    ) throws {
        switch failedStage {
        case .fixtureStop:
            try execution.record(stage: .fixtureStop, outcome: .failed)
        case .fixtureStart:
            try execution.record(stage: .fixtureStop, outcome: .succeeded)
            try execution.record(stage: .fixtureStart, outcome: .failed)
        case .fixtureHealth:
            try execution.record(stage: .fixtureStop, outcome: .succeeded)
            try execution.record(stage: .fixtureStart, outcome: .succeeded)
            try execution.record(stage: .fixtureHealth, outcome: .failed)
        case .preArm:
            try completeFixtureLifecycle(execution: &execution)
            try execution.record(stage: .preArm, outcome: .failed)
        case .arm:
            try completeFixtureLifecycle(execution: &execution)
            try execution.record(stage: .preArm, outcome: .succeeded)
            try execution.record(stage: .arm, outcome: .failed)
        case .postArm:
            try completeFixtureLifecycle(execution: &execution)
            try execution.record(stage: .preArm, outcome: .succeeded)
            try execution.record(stage: .arm, outcome: .succeeded)
            try execution.record(stage: .postArm, outcome: .failed)
        case .teardown:
            try completeFixtureLifecycle(execution: &execution)
            for _ in 0..<3 {
                try execution.record(stage: .preArm, outcome: .succeeded)
                try execution.record(stage: .arm, outcome: .succeeded)
                try execution.record(stage: .postArm, outcome: .succeeded)
            }
            try execution.record(stage: .teardown, outcome: .failed)
        }
    }

    private static func completeFixtureLifecycle(
        execution: inout SpiceLiveCampaignExecution
    ) throws {
        try execution.record(stage: .fixtureStop, outcome: .succeeded)
        try execution.record(stage: .fixtureStart, outcome: .succeeded)
        try execution.record(stage: .fixtureHealth, outcome: .succeeded)
    }
}
