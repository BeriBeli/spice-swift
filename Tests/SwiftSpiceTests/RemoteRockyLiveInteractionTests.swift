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
        defer { forceTerminate(identifiers) }
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
        #expect(Darwin.kill(try #require(identifiers.first), 0) != 0)
    }

    @Test func terminateAndWaitEscalatesPastIgnoredTERMWithinItsOuterLimit() async throws {
        let fixture = try SpiceLiveScriptFixture(
            """
            trap '' TERM
            printf 'READY parent=%s\n' "$$"
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
        defer { forceTerminate(identifiers) }
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
        #expect(Darwin.kill(try #require(identifiers.first), 0) != 0)
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
