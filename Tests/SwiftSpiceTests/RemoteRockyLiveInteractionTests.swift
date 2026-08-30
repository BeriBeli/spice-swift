import Darwin
import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Spice live interaction harness support")
struct RemoteRockyLiveInteractionTests {
    @Test func configurationRequiresExplicitOptInAndEveryIsolatedEndpointField() throws {
        expectConfigurationError([:], .notExplicitlyEnabled)

        for missingKey in validEnvironment.keys where missingKey != "SWIFTSPICE_LIVE_INTERACTION" {
            var environment = validEnvironment
            environment.removeValue(forKey: missingKey)
            expectConfigurationError(environment, .incompleteIsolatedConfiguration)
        }

        let configuration = try SpiceRemoteLiveConfiguration(environment: validEnvironment)
        #expect(configuration.sshHost == "rocky9")
        #expect(configuration.base == "/home/test/swiftspice-aip00c")
        #expect(configuration.container == "swiftspice-aip00c-qemu")
        #expect(configuration.image == "localhost/swiftspice-aip00c:local")
        #expect(configuration.spicePort == 6_135)
        #expect(configuration.controlPort == 6_136)
        #expect(configuration.endpointHost == "127.0.0.1")
        #expect(configuration.endpointPort == 6_235)
        #expect(configuration.version == "v0.3.3")
        #expect(configuration.clusterID == "0123456789abcdef")
    }

    @Test func configurationRequiresACanonicalExplicitLiveVersion() throws {
        let canonical = try SpiceRemoteLiveConfiguration(environment: validEnvironment)
        #expect(canonical.version == "v0.3.3")

        for invalidVersion in [
            "0.3.3",
            "v00.3.3",
            "v0.03.3",
            "v0.3.03",
            "v0.3",
            "v0.3.3-beta",
            "v0.3.3\n",
            "v0.3.3\r",
            "v0.3.3\r\n",
            "v0.3.3 ",
            "v0.3.3\t",
            "v0.3.3x",
        ] {
            var environment = validEnvironment
            environment["SWIFTSPICE_LIVE_VERSION"] = invalidVersion
            expectConfigurationError(environment, .invalidLiveVersion)
        }
    }

    @Test func configurationRequiresACanonicalExplicitClusterIdentity() {
        var missing = validEnvironment
        missing.removeValue(forKey: "SWIFTSPICE_LIVE_CLUSTER_ID")
        expectConfigurationError(missing, .incompleteIsolatedConfiguration)

        for invalidClusterID in [
            "0123456789abcde",
            "0123456789abcdef0",
            "0123456789abcdeF",
            "0123456789abcdeg",
            "0123456789abcdef\n",
            "cluster-000000001",
        ] {
            var environment = validEnvironment
            environment["SWIFTSPICE_LIVE_CLUSTER_ID"] = invalidClusterID
            expectConfigurationError(environment, .invalidIsolatedConfiguration)
            #expect(throws: SpiceLiveInteractionSupportError.invalidIsolatedConfiguration) {
                _ = try SpiceLiveInteractionClusterPlan(clusterID: invalidClusterID)
            }
        }
    }

    @Test func clusterPlanFixesCanonicalActionsInputsAndPairedIdentities() throws {
        let currentVersion = try SpiceRemoteLiveConfiguration(environment: validEnvironment)
        var adjacentEnvironment = validEnvironment
        adjacentEnvironment["SWIFTSPICE_LIVE_VERSION"] = "v0.3.4"
        let adjacentVersion = try SpiceRemoteLiveConfiguration(
            environment: adjacentEnvironment
        )
        #expect(currentVersion.version != adjacentVersion.version)
        #expect(currentVersion.clusterID == adjacentVersion.clusterID)

        let firstCluster = try completedClusterSteps(currentVersion.clusterID)
        let pairedVersionCluster = try completedClusterSteps(adjacentVersion.clusterID)
        let differentCluster = try completedClusterSteps("fedcba9876543210")

        #expect(firstCluster.map(\.order) == [1, 2, 3])
        #expect(firstCluster.map(\.actionClass) == [.click, .key, .motion])
        #expect(firstCluster.map(\.remoteActionClass) == ["click", "key", "motion"])
        #expect(firstCluster.map {
            $0.requiresMotionAcknowledgement(for: .relative)
        } == [false, false, true])
        #expect(firstCluster.map {
            $0.requiresMotionAcknowledgement(for: .absolute)
        } == [false, false, false])
        #expect(Set(firstCluster.map(\.token)).count == 3)
        #expect(Set(firstCluster.map(\.pairID)).count == 3)
        #expect(firstCluster.allSatisfy { step in
            step.token.utf8.count == 16 && step.token.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
        })

        // Cluster identity, action, and order—not version—define the paired
        // capture intent. Adjacent version runs therefore use the exact same
        // pair IDs and tokens, while a different cluster cannot collide.
        #expect(firstCluster.map(\.pairID) == pairedVersionCluster.map(\.pairID))
        #expect(firstCluster.map(\.token) == pairedVersionCluster.map(\.token))
        #expect(Set(firstCluster.map(\.pairID)).isDisjoint(
            with: Set(differentCluster.map(\.pairID))
        ))
        #expect(Set(firstCluster.map(\.token)).isDisjoint(
            with: Set(differentCluster.map(\.token))
        ))

        #expect(firstCluster[0].inputs(for: .relative) == [
            .mousePress(.left), .mouseRelease(.left),
        ])
        #expect(firstCluster[1].inputs(for: .relative) == [
            .keyDown(scanCode: 0x1e), .keyUp(scanCode: 0x1e),
        ])
        #expect(firstCluster[2].inputs(for: .relative) == [
            .mouseMotion(dx: 1, dy: 1),
        ])
        let absoluteInputs = firstCluster[2].inputs(for: .absolute)
        #expect(absoluteInputs.count == 1)
        let absoluteMotion = try #require(absoluteInputs.first)
        guard case let .mousePosition(x, y, displayID) = absoluteMotion else {
            Issue.record("absolute motion step did not use one deterministic position")
            return
        }
        #expect(displayID == 0)
        #expect(x > 0)
        #expect(y > 0)
    }

    @Test func clusterPlanAdvancesOnlyAfterExactPresentationAndAppend() throws {
        var plan = try SpiceLiveInteractionClusterPlan(
            clusterID: "0123456789abcdef"
        )
        let click = try plan.beginNextStep()
        try plan.recordExactPresentation(order: click.order)
        try plan.recordAppendCompleted(order: click.order)
        let key = try plan.beginNextStep()
        #expect(key.order == 2)
        try plan.recordExactPresentation(order: key.order)
        try plan.recordAppendCompleted(order: key.order)
        let motion = try plan.beginNextStep()
        #expect(motion.order == 3)
        #expect(motion.requiresMotionAcknowledgement(for: .relative))
        #expect(!motion.requiresMotionAcknowledgement(for: .absolute))
        try plan.recordExactPresentation(order: motion.order)
        try plan.recordAppendCompleted(order: motion.order)
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try plan.beginNextStep()
        }

        var armBeforePresentation = try SpiceLiveInteractionClusterPlan(
            clusterID: "0123456789abcdef"
        )
        _ = try armBeforePresentation.beginNextStep()
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try armBeforePresentation.beginNextStep()
        }
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            try armBeforePresentation.recordExactPresentation(order: 1)
        }

        var armBeforeAppend = try SpiceLiveInteractionClusterPlan(
            clusterID: "0123456789abcdef"
        )
        let unappended = try armBeforeAppend.beginNextStep()
        try armBeforeAppend.recordExactPresentation(order: unappended.order)
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try armBeforeAppend.beginNextStep()
        }

        var appendBeforePresentation = try SpiceLiveInteractionClusterPlan(
            clusterID: "0123456789abcdef"
        )
        _ = try appendBeforePresentation.beginNextStep()
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            try appendBeforePresentation.recordAppendCompleted(order: 1)
        }
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try appendBeforePresentation.beginNextStep()
        }

        var failed = try SpiceLiveInteractionClusterPlan(
            clusterID: "0123456789abcdef"
        )
        let failedClick = try failed.beginNextStep()
        try failed.recordExactPresentation(order: failedClick.order)
        // A remote/local append failure after presentation is terminal. It
        // cannot arm key while the click record is absent from the artifact.
        failed.failCurrentStep()
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try failed.beginNextStep()
        }
    }

    @Test func motionAcknowledgementRequiresTheCurrentCleanEpochAndSendBoundary() async throws {
        let monitor = SpiceLiveMotionAcknowledgementMonitor()

        // An ACK already present when the clean epoch begins belongs to prior
        // traffic and cannot satisfy this motion probe.
        await monitor.recordAcknowledgement(at: 10)
        let cleanEpoch = try await monitor.beginCleanEpoch()
        await #expect(throws: SpiceLiveInteractionSupportError.operationTimedOut) {
            _ = try await withSpiceLiveTimeout(.milliseconds(20)) {
                try await monitor.waitForAcknowledgement(
                    after: cleanEpoch,
                    notBefore: 0
                )
            }
        }

        // An ACK from this epoch but before the send-start boundary is
        // likewise ineligible and is never clamped or rewritten to that bound.
        let boundedEpoch = try await monitor.beginCleanEpoch()
        await monitor.recordAcknowledgement(at: 15)
        await #expect(throws: SpiceLiveInteractionSupportError.operationTimedOut) {
            _ = try await withSpiceLiveTimeout(.milliseconds(20)) {
                try await monitor.waitForAcknowledgement(
                    after: boundedEpoch,
                    notBefore: 20
                )
            }
        }

        // Both timed-out waits were fully removed. A fresh epoch can buffer and
        // return exactly one later qualifying ACK without leaking a waiter.
        let acceptedEpoch = try await monitor.beginCleanEpoch()
        await monitor.recordAcknowledgement(at: 25)
        let accepted = try await monitor.waitForAcknowledgement(
            after: acceptedEpoch,
            notBefore: 20
        )
        #expect(accepted == 25)
    }

    @Test func configurationRejectsHistoricalDefaultsAndSSHOptionInjection() {
        let forbiddenOverrides: [(String, String)] = [
            ("SWIFTSPICE_PERF_CONTAINER", "swiftspice-perf-ab-qemu"),
            ("SWIFTSPICE_PERF_BASE", "/home/test/swiftspice-remote-closure/perf-ab"),
            ("SWIFTSPICE_ROCKY_SSH_HOST", "-oProxyCommand=touch-pwned"),
        ]
        for (key, value) in forbiddenOverrides {
            var environment = validEnvironment
            environment[key] = value
            expectConfigurationError(environment, .invalidIsolatedConfiguration)
        }

        var historicalPorts = validEnvironment
        historicalPorts["SWIFTSPICE_PERF_SPICE_PORT"] = "5935"
        historicalPorts["SWIFTSPICE_PERF_CONTROL_PORT"] = "5936"
        expectConfigurationError(historicalPorts, .invalidIsolatedConfiguration)

        for endpointPort in ["5935", "15935", "6135"] {
            var environment = validEnvironment
            environment["SWIFTSPICE_LIVE_ENDPOINT_PORT"] = endpointPort
            expectConfigurationError(environment, .invalidIsolatedConfiguration)
        }
    }

    @Test func ticketParsesOnlyStandardOutputAndCommandsNeverContainTheSecret() async throws {
        let fixture = try SpiceLiveScriptFixture(
            """
            printf '%s\n' '\(validTicket)'
            printf '%s\n' 'Warning: experimental post-quantum key exchange' >&2
            for argument in "$@"; do
                printf 'ARG=%s\n' "$argument" >&2
            done
            """
        )
        defer { fixture.remove() }
        let runner = SpiceLiveProcessRunner(executableURL: fixture.executableURL)
        let configuration = try SpiceRemoteLiveConfiguration(environment: validEnvironment)

        let result = try await configuration.runRemoteScript("ticket.sh", runner: runner)

        #expect(result.standardOutput == "\(validTicket)\n")
        #expect(result.standardError.contains("post-quantum"))
        #expect(!result.standardError.contains(validTicket))
        #expect(result.standardError.contains("swiftspice-aip00c-qemu"))
        #expect(!result.standardError.contains("swiftspice-perf-ab-qemu"))
        #expect(try configuration.ticket(from: result) == validTicket)

        let warningContaminatedOutput = SpiceLiveProcessResult(
            status: 0,
            standardOutput: "Warning: post-quantum\n\(validTicket)\n",
            standardError: ""
        )
        #expect(throws: SpiceLiveInteractionSupportError.invalidTicket) {
            _ = try configuration.ticket(from: warningContaminatedOutput)
        }
        #expect(throws: SpiceLiveInteractionSupportError.invalidTicket) {
            _ = try configuration.ticket(from: SpiceLiveProcessResult(
                status: 0,
                standardOutput: "\(validTicket)0\n",
                standardError: ""
            ))
        }
    }

    @Test func controlTraceStreamsArmedThenOneExactGuestRevision() async throws {
        let token = "0000000000000031"
        let fixture = try SpiceLiveScriptFixture(
            """
            printf '%s\n' 'PERF_ARMED action_class=click token=\(token)'
            printf '%s\n' 'PERF_TRACE event=guest_received action_class=click token=\(token) guest_ns=100 marker_revision=7'
            printf '%s\n' 'PERF_TRACE event=marker_drawn action_class=click token=\(token) guest_ns=101 marker_revision=7'
            printf '%s\n' 'OpenSSH diagnostic kept off the protocol stream' >&2
            for argument in "$@"; do
                printf 'ARG=%s\n' "$argument" >&2
            done
            """
        )
        defer { fixture.remove() }
        let configuration = try SpiceRemoteLiveConfiguration(environment: validEnvironment)
        let child = try configuration.launchControlTrace(
            actionClass: "click",
            token: token,
            runner: SpiceLiveProcessRunner(executableURL: fixture.executableURL)
        )

        let armed = try await child.readOutputLine(within: .seconds(1))
        #expect(armed == "PERF_ARMED action_class=click token=\(token)")
        let result = try await child.finish(within: .seconds(1))
        #expect(result.status == 0)
        #expect(result.outputLines.count == 2)
        #expect(result.standardError.contains("OpenSSH diagnostic"))
        #expect(result.standardError.contains("control.sh"))
        #expect(result.standardError.contains("swiftspice-aip00c-qemu"))
        #expect(!result.standardError.contains("swiftspice-perf-ab-qemu"))
        #expect(!result.standardError.contains(validTicket))

        let trace = try SpiceRemoteGuestTrace(
            lines: [armed] + result.outputLines,
            actionClass: "click",
            token: token
        )
        #expect(trace.receivedNanoseconds == 100)
        #expect(trace.drawnNanoseconds == 101)
        #expect(trace.markerRevision == 7)
    }

    @Test(arguments: [
        [
            "PERF_ARMED action_class=click token=0000000000000031",
            "PERF_TRACE event=guest_received action_class=click token=0000000000000031 guest_ns=100 marker_revision=7",
            "PERF_TRACE event=marker_drawn action_class=click token=0000000000000031 guest_ns=101 marker_revision=8",
        ],
        [
            "PERF_ARMED action_class=click token=0000000000000031",
            "PERF_TRACE event=marker_drawn action_class=click token=0000000000000031 guest_ns=101 marker_revision=7",
            "PERF_TRACE event=guest_received action_class=click token=0000000000000031 guest_ns=100 marker_revision=7",
        ],
        [
            "PERF_ARMED action_class=click token=0000000000000031",
            "PERF_TRACE event=guest_received action_class=click token=0000000000000031 guest_ns=not-a-clock marker_revision=7",
            "PERF_TRACE event=marker_drawn action_class=click token=0000000000000031 guest_ns=101 marker_revision=7",
        ],
    ])
    func guestTraceRejectsRevisionMismatchOutOfOrderOrMalformedEvidence(
        lines: [String]
    ) {
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try SpiceRemoteGuestTrace(
                lines: lines,
                actionClass: "click",
                token: "0000000000000031"
            )
        }
    }

    @Test func childAndOverallTimeoutsAreBoundedAndFailClosed() async throws {
        let fixture = try SpiceLiveScriptFixture(
            """
            while :; do
                :
            done
            """
        )
        defer { fixture.remove() }
        let child = try SpiceLiveProcessRunner(
            executableURL: fixture.executableURL
        ).launch(arguments: [])

        await #expect(throws: SpiceLiveInteractionSupportError.childTimedOut) {
            _ = try await child.finish(within: .milliseconds(20))
        }
        await #expect(throws: SpiceLiveInteractionSupportError.operationTimedOut) {
            _ = try await withSpiceLiveTimeout(.milliseconds(20)) {
                try await Task.sleep(for: .seconds(1))
                return true
            }
        }
    }

    @Test func finishEscalatesPastIgnoredTERMAndDoesNotWaitForAnInheritedPipeWriter() async throws {
        let fixture = try SpiceLiveScriptFixture(
            """
            trap '' TERM
            (
                trap '' TERM
                while :; do
                    :
                done
            ) &
            descendant=$!
            printf 'READY parent=%s descendant=%s\n' "$$" "$descendant"
            while :; do
                :
            done
            """
        )
        defer { fixture.remove() }
        let child = try SpiceLiveProcessRunner(
            executableURL: fixture.executableURL
        ).launch(arguments: [])
        let identifiers = try processIdentifiers(
            from: await child.readOutputLine(within: .seconds(1))
        )
        let operationTimeout = Duration.milliseconds(20)
        let outerLimit = operationTimeout
            + SpiceLiveChildProcess.terminationGrace
            + SpiceLiveChildProcess.killGrace
            + SpiceLiveChildProcess.pipeDrainGrace
            + .milliseconds(500)
        let watchdog = terminationWatchdog(
            processIdentifiers: identifiers,
            after: outerLimit
        )
        let started = ContinuousClock().now

        do {
            _ = try await child.finish(within: operationTimeout)
            Issue.record("TERM-ignoring child unexpectedly completed successfully")
        } catch let error as SpiceLiveInteractionSupportError {
            #expect(error == .childTimedOut)
        }

        let elapsed = started.duration(to: ContinuousClock().now)
        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(elapsed < outerLimit)
        expectNoSurvivingProcesses(identifiers)
    }

    @Test func terminateAndWaitEscalatesPastIgnoredTERMWithinItsOuterLimit() async throws {
        let fixture = try SpiceLiveScriptFixture(
            """
            trap '' TERM
            (
                trap '' TERM
                while :; do
                    :
                done
            ) &
            descendant=$!
            printf 'READY parent=%s descendant=%s\n' "$$" "$descendant"
            while :; do
                :
            done
            """
        )
        defer { fixture.remove() }
        let child = try SpiceLiveProcessRunner(
            executableURL: fixture.executableURL
        ).launch(arguments: [])
        let identifiers = try processIdentifiers(
            from: await child.readOutputLine(within: .seconds(1))
        )
        let outerLimit = SpiceLiveChildProcess.terminationGrace
            + SpiceLiveChildProcess.killGrace
            + .milliseconds(500)
        let watchdog = terminationWatchdog(
            processIdentifiers: identifiers,
            after: outerLimit
        )
        let started = ContinuousClock().now

        let exited = await child.terminateAndWait()

        let elapsed = started.duration(to: ContinuousClock().now)
        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(exited)
        #expect(elapsed < outerLimit)
        expectNoSurvivingProcesses(identifiers)
    }

    @Test func naturalLeaderExitWithInheritedWriterUsesBoundedDrainTimeoutAndReapsTree() async throws {
        let fixture = try SpiceLiveScriptFixture(
            """
            (
                trap '' TERM
                while :; do
                    :
                done
            ) &
            descendant=$!
            printf 'READY parent=%s descendant=%s\n' "$$" "$descendant"
            exit 0
            """
        )
        defer { fixture.remove() }
        let child = try SpiceLiveProcessRunner(
            executableURL: fixture.executableURL
        ).launch(arguments: [])
        let identifiers = try processIdentifiers(
            from: await child.readOutputLine(within: .seconds(1))
        )
        let outerLimit = SpiceLiveChildProcess.pipeDrainGrace
            + SpiceLiveChildProcess.terminationGrace
            + SpiceLiveChildProcess.killGrace
            + .milliseconds(500)
        let watchdog = terminationWatchdog(
            processIdentifiers: identifiers,
            after: outerLimit
        )
        let started = ContinuousClock().now

        do {
            _ = try await child.finish(within: .seconds(2))
            Issue.record("inherited writer unexpectedly allowed a successful pipe drain")
        } catch let error as SpiceLiveInteractionSupportError {
            #expect(error == .childTimedOut)
        }

        let elapsed = started.duration(to: ContinuousClock().now)
        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(elapsed >= SpiceLiveChildProcess.pipeDrainGrace)
        #expect(elapsed < outerLimit)
        expectNoSurvivingProcesses(identifiers)
    }

    @Test func successfulLeaderExitStillReapsResidualDescendantAfterCleanPipeEOF() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-live-residual-descendant-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let descendantReady = directory.appending(path: "descendant-ready")
        let fixture = try SpiceLiveScriptFixture(
            """
            (
                trap '' TERM
                exec >/dev/null 2>&1
                : > "$1"
                while :; do
                    :
                done
            ) &
            descendant=$!
            while [ ! -f "$1" ]; do
                :
            done
            printf 'READY parent=%s descendant=%s\n' "$$" "$descendant"
            exit 0
            """
        )
        defer { fixture.remove() }
        let child = try SpiceLiveProcessRunner(
            executableURL: fixture.executableURL
        ).launch(arguments: [descendantReady.path])
        let identifiers = try processIdentifiers(
            from: await child.readOutputLine(within: .seconds(1))
        )
        let outerLimit = SpiceLiveChildProcess.pipeDrainGrace
            + SpiceLiveChildProcess.terminationGrace
            + SpiceLiveChildProcess.killGrace
            + .milliseconds(500)
        let watchdog = terminationWatchdog(
            processIdentifiers: identifiers,
            after: outerLimit
        )
        var result: SpiceLiveProcessResult?

        do {
            result = try await child.finish(within: .seconds(2))
        } catch {
            Issue.record("clean EOF success path unexpectedly failed")
        }

        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(result?.status == 0)
        #expect(result?.standardOutput.isEmpty == true)
        #expect(result?.standardError.isEmpty == true)
        expectNoSurvivingProcesses(identifiers)
    }

    @Test func outputLimitsAcceptExactBoundsAndFailClosedOneBytePast() async throws {
        let streamLimit = SpiceLiveChildProcess.maximumOutputBytesPerStream
        let exactFixture = try SpiceLiveScriptFixture(
            """
            /bin/dd if=/dev/zero bs=\(streamLimit) count=1 2>/dev/null
            exec 3>&2
            /bin/dd if=/dev/zero bs=\(streamLimit) count=1 2>/dev/null 1>&3
            exec 3>&-
            """
        )
        defer { exactFixture.remove() }
        let exactChild = try SpiceLiveProcessRunner(
            executableURL: exactFixture.executableURL
        ).launch(arguments: [])

        let exactResult = try await exactChild.finish(within: .seconds(2))

        #expect(exactResult.standardOutput.utf8.count == streamLimit)
        #expect(exactResult.standardError.utf8.count == streamLimit)
        #expect(
            exactResult.standardOutput.utf8.count + exactResult.standardError.utf8.count
                == SpiceLiveChildProcess.maximumCombinedOutputBytes
        )

        for stream in ["stdout", "stderr"] {
            let sensitiveOutput = "ticket=0123456789abcdef0123456789abcdef0123456789abcdef"
            let overflowBytes = streamLimit - sensitiveOutput.utf8.count + 1
            let directory = FileManager.default.temporaryDirectory.appending(
                path: "swiftspice-live-\(stream)-limit-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let pidFile = directory.appending(path: "pid")
            let outputCommands: String
            if stream == "stdout" {
                outputCommands = """
                printf '%s' '\(sensitiveOutput)'
                /bin/dd if=/dev/zero bs=\(overflowBytes) count=1 2>/dev/null
                """
            } else {
                outputCommands = """
                exec 3>&2
                printf '%s' '\(sensitiveOutput)' >&3
                /bin/dd if=/dev/zero bs=\(overflowBytes) count=1 2>/dev/null 1>&3
                exec 3>&-
                """
            }
            let overflowFixture = try SpiceLiveScriptFixture(
                """
                printf '%s\n' "$$" > "$1"
                trap '' TERM
                \(outputCommands)
                while :; do
                    :
                done
                """
            )
            defer { overflowFixture.remove() }
            let overflowChild = try SpiceLiveProcessRunner(
                executableURL: overflowFixture.executableURL
            ).launch(arguments: [pidFile.path])
            var observedError: SpiceLiveInteractionSupportError?

            do {
                _ = try await overflowChild.finish(within: .seconds(2))
                Issue.record("one-past-limit \(stream) unexpectedly returned a result")
            } catch let error as SpiceLiveInteractionSupportError {
                observedError = error
            }

            #expect(observedError == .outputLimitExceeded)
            #expect(!String(reflecting: observedError).contains(sensitiveOutput))
            let rawProcessIdentifier = try String(
                contentsOf: pidFile,
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let processIdentifier = try #require(pid_t(rawProcessIdentifier))
            expectNoSurvivingProcesses([processIdentifier])
        }
    }

    @Test func timeoutFinalizationPreservesTheDerivedFirstMissingStage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-live-derived-stage-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "input-events.jsonl")
        let capture = try SpiceInteractionTraceCapture(
            presentationDiagnostics: SpicePresentationDiagnostics(),
            writer: SpiceInteractionTraceJSONLWriter(outputURL: output),
            pairId: "timeout-pair",
            version: "v0.3.1",
            runId: "isolated-run",
            order: 1,
            actionClass: .click,
            token: "0000000000000031",
            checksum: 0x9f9f_5111
        )
        try capture.recordHostInput(scheduledNs: 10, hostInputNs: 20, sendStartedNs: 30)
        try capture.recordSendCompleted(at: 40)
        try capture.recordGuestEvidence(receivedNs: 50, drawnNs: 60, markerRevision: 7)
        let orchestrator = SpiceLiveTraceOrchestrator(capture: capture, outputURL: output)

        await #expect(throws: SpiceLiveInteractionSupportError.operationTimedOut) {
            _ = try await orchestrator.completeAfterExactPresentation(
                timeout: .milliseconds(20)
            )
        }
        let finalized = try orchestrator.finishDerivedInvalid()
        let record = finalized.record

        #expect(!record.valid)
        // No exact marker frame was ever observed, so schema validation must
        // retain its earliest evidence gap rather than forcing a coarse
        // timeout or missing-presented label.
        #expect(record.invalidReason == "missing_marker_checksum")
        #expect(record.presentedNs == nil)
        let lines = finalized.encodedJSONL.split(separator: 0x0A)
        #expect(lines.count == 1)
        let decoded = try JSONDecoder().decode(SpiceInteractionTraceRecord.self, from: Data(lines[0]))
        #expect(decoded == record)
    }

    private func completedClusterSteps(
        _ clusterID: String
    ) throws -> [SpiceLiveInteractionClusterPlan.Step] {
        var plan = try SpiceLiveInteractionClusterPlan(clusterID: clusterID)
        var steps: [SpiceLiveInteractionClusterPlan.Step] = []
        for expectedOrder: UInt64 in 1...3 {
            let step = try plan.beginNextStep()
            #expect(step.order == expectedOrder)
            steps.append(step)
            try plan.recordExactPresentation(order: step.order)
            try plan.recordAppendCompleted(order: step.order)
        }
        return steps
    }

    private var validEnvironment: [String: String] {
        [
            "SWIFTSPICE_LIVE_INTERACTION": "1",
            "SWIFTSPICE_ROCKY_SSH_HOST": "rocky9",
            "SWIFTSPICE_PERF_BASE": "/home/test/swiftspice-aip00c",
            "SWIFTSPICE_PERF_CONTAINER": "swiftspice-aip00c-qemu",
            "SWIFTSPICE_PERF_IMAGE": "localhost/swiftspice-aip00c:local",
            "SWIFTSPICE_PERF_SPICE_PORT": "6135",
            "SWIFTSPICE_PERF_CONTROL_PORT": "6136",
            "SWIFTSPICE_LIVE_ENDPOINT_HOST": "127.0.0.1",
            "SWIFTSPICE_LIVE_ENDPOINT_PORT": "6235",
            "SWIFTSPICE_LIVE_VERSION": "v0.3.3",
            "SWIFTSPICE_LIVE_CLUSTER_ID": "0123456789abcdef",
        ]
    }

    private var validTicket: String {
        String(repeating: "a", count: 48)
    }

    private func expectConfigurationError(
        _ environment: [String: String],
        _ expected: SpiceLiveInteractionSupportError
    ) {
        do {
            _ = try SpiceRemoteLiveConfiguration(environment: environment)
            Issue.record("configuration unexpectedly passed validation")
        } catch let error as SpiceLiveInteractionSupportError {
            #expect(error == expected)
        } catch {
            Issue.record("configuration threw an unexpected error type")
        }
    }
}

private struct SpiceLiveScriptFixture {
    let directory: URL
    let executableURL: URL

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-live-script-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        executableURL = directory.appending(path: "fixture.sh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(
            to: executableURL,
            options: .atomic
        )
        guard chmod(executableURL.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
            remove()
            throw SpiceLiveInteractionSupportError.childFailed
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func processIdentifiers(from readyLine: String) throws -> [pid_t] {
    let fields = readyLine.split(separator: " ")
    guard fields.first == "READY" else {
        throw SpiceLiveInteractionSupportError.invalidTraceProtocol
    }
    let identifiers = fields.dropFirst().compactMap { field -> pid_t? in
        guard let separator = field.firstIndex(of: "=") else { return nil }
        return pid_t(field[field.index(after: separator)...])
    }
    guard identifiers.count == fields.count - 1,
          identifiers.allSatisfy({ $0 > 1 }) else {
        throw SpiceLiveInteractionSupportError.invalidTraceProtocol
    }
    return identifiers
}

private func terminationWatchdog(
    processIdentifiers: [pid_t],
    after delay: Duration
) -> Task<Bool, Never> {
    Task.detached {
        do {
            try await Task.sleep(for: delay)
        } catch {
            return false
        }
        var terminatedProcess = false
        for identifier in processIdentifiers where Darwin.kill(identifier, 0) == 0 {
            _ = Darwin.kill(identifier, SIGKILL)
            terminatedProcess = true
        }
        return terminatedProcess
    }
}

private func forceTerminate(_ processIdentifiers: [pid_t]) {
    for identifier in processIdentifiers where Darwin.kill(identifier, 0) == 0 {
        _ = Darwin.kill(identifier, SIGKILL)
    }
}

private func expectNoSurvivingProcesses(_ processIdentifiers: [pid_t]) {
    let survivors = processIdentifiers.filter { Darwin.kill($0, 0) == 0 }
    #expect(survivors.isEmpty)
    // Emergency cleanup happens only after recording the orphan regression;
    // it cannot turn a surviving descendant into a passing assertion.
    if !survivors.isEmpty {
        forceTerminate(survivors)
    }
}
