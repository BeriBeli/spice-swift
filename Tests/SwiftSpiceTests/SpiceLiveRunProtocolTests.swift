import Darwin
import Foundation
import Testing
@testable import SpiceLiveInteractionSupport
@testable import SwiftSpice

@Suite("Live interaction run protocol")
struct SpiceLiveRunProtocolTests {
    @Test func statusRequiresExactReadyEndpointAndCanonicalRemoteEvidence() throws {
        let configuration = try Stage3LiveRunFixture.configuration()
        let runDirectory = Stage3LiveRunFixture.remoteRunDirectory
        let valid = SpiceLiveProcessResult(
            status: 0,
            standardOutput: Stage3LiveRunFixture.statusOutput(
                runDirectory: runDirectory
            ),
            standardError: "diagnostic-only\n"
        )

        let status = try SpiceRemoteRunStatus(
            result: valid,
            configuration: configuration
        )

        #expect(status.container == configuration.container)
        #expect(status.spiceReady)
        #expect(status.controlReady)
        #expect(status.runDirectory == runDirectory)
        #expect(status.evidenceRunID == "20260830T120000Z.a1B2c3")
        #expect(status.evidenceRunID != configuration.runID)

        var invalidProtocolOutputs = [String]()
        invalidProtocolOutputs.append(Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory,
            state: "stopped"
        ))
        invalidProtocolOutputs.append(Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory,
            container: "wrong-container"
        ))
        invalidProtocolOutputs.append(Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory,
            spice: "127.0.0.1:15999"
        ))
        invalidProtocolOutputs.append(Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory,
            control: "127.0.0.1:15999"
        ))
        invalidProtocolOutputs.append(Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory
        ) + "spice=127.0.0.1:15945\n")
        invalidProtocolOutputs.append(Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory
        ) + "spice_listener=ready\n")
        invalidProtocolOutputs.append(Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory
        ) + "control_listener=not-ready\n")
        invalidProtocolOutputs.append(Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory
        ) + "run_evidence=\(runDirectory)\n")
        let validLines = Stage3LiveRunFixture.statusOutput(
            runDirectory: runDirectory
        ).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        invalidProtocolOutputs.append(validLines.dropFirst().joined(separator: "\n"))
        invalidProtocolOutputs.append(
            ([validLines[1], validLines[0]] + validLines.dropFirst(2)).joined(separator: "\n")
        )
        invalidProtocolOutputs.append(
            (Array(validLines.prefix(2)) + Array(validLines.dropFirst(3))).joined(separator: "\n")
        )
        invalidProtocolOutputs.append(
            (Array(validLines.prefix(3)) + Array(validLines.dropFirst(4))).joined(separator: "\n")
        )
        invalidProtocolOutputs.append(
            (Array(validLines.prefix(6)) + Array(validLines.dropFirst(7))).joined(separator: "\n")
        )
        invalidProtocolOutputs.append(
            (Array(validLines.prefix(7)) + Array(validLines.dropFirst(8))).joined(separator: "\n")
        )
        for output in invalidProtocolOutputs {
            #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
                _ = try SpiceRemoteRunStatus(
                    result: SpiceLiveProcessResult(
                        status: 0,
                        standardOutput: output,
                        standardError: "listener missing or malformed"
                    ),
                    configuration: configuration
                )
            }
        }

        let invalidRunDirectories = [
            "\(configuration.base)/logs-extra/20260830T120000Z.a1B2c3",
            "\(configuration.base)/logs/../20260830T120000Z.a1B2c3",
            "\(configuration.base)/logs/20260830T120000Z.a1B2c3/child",
            "\(configuration.base)/logs/20260830t120000z.a1B2c3",
            "\(configuration.base)/logs/20260830T120000Z.link/../a1B2c3",
        ]
        for invalidRunDirectory in invalidRunDirectories {
            let output = Stage3LiveRunFixture.statusOutput(
                runDirectory: invalidRunDirectory
            )
            #expect(throws: SpiceLiveInteractionSupportError.invalidRunDirectory) {
                _ = try SpiceRemoteRunStatus(
                    result: SpiceLiveProcessResult(
                        status: 0,
                        standardOutput: output,
                        standardError: ""
                    ),
                    configuration: configuration
                )
            }
        }
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try SpiceRemoteRunStatus(
                result: SpiceLiveProcessResult(
                    status: 1,
                    standardOutput: valid.standardOutput,
                    standardError: "failed"
                ),
                configuration: configuration
            )
        }
    }

    @Test func ticketIsOneExactLowercaseFortyEightHexValue() throws {
        let configuration = try Stage3LiveRunFixture.configuration()
        let ticket = String(repeating: "a1", count: 24)
        #expect(try configuration.ticket(from: SpiceLiveProcessResult(
            status: 0,
            standardOutput: "\(ticket)\n",
            standardError: "ssh warning kept separate"
        )) == ticket)

        for output in [
            String(repeating: "a", count: 47),
            String(repeating: "a", count: 49),
            String(repeating: "A", count: 48),
            " \(ticket)\n",
            "\(ticket) \n",
            "\(ticket)\n\n",
            "warning\n\(ticket)\n",
            "\(ticket)\r\n",
        ] {
            #expect(throws: SpiceLiveInteractionSupportError.invalidTicket) {
                _ = try configuration.ticket(from: SpiceLiveProcessResult(
                    status: 0,
                    standardOutput: output,
                    standardError: ""
                ))
            }
        }
        #expect(throws: SpiceLiveInteractionSupportError.invalidTicket) {
            _ = try configuration.ticket(from: SpiceLiveProcessResult(
                status: 1,
                standardOutput: "\(ticket)\n",
                standardError: "failed"
            ))
        }
    }

    @Test func guestTraceRequiresArmedReceivedDrawnForOneExactRevision() throws {
        let token = "471a5b01a43d3ed0"
        let lines = Stage3LiveRunFixture.traceLines(
            actionClass: "click",
            token: token,
            revision: 7
        )
        let trace = try SpiceRemoteGuestTrace(
            lines: lines,
            actionClass: "click",
            token: token
        )
        #expect(trace.receivedNanoseconds == 100)
        #expect(trace.drawnNanoseconds == 101)
        #expect(trace.markerRevision == 7)

        var invalid = [[String]]()
        invalid.append(Array(lines.dropLast()))
        invalid.append(lines + [lines[2]])
        invalid.append([lines[0], lines[2], lines[1]])
        invalid.append([lines[0], lines[1], lines[1]])
        invalid.append([
            lines[0],
            lines[1],
            lines[2].replacingOccurrences(of: "marker_revision=7", with: "marker_revision=8"),
        ])
        invalid.append([
            lines[0],
            lines[1].replacingOccurrences(of: "token=\(token)", with: "token=0000000000000000"),
            lines[2],
        ])
        invalid.append([
            lines[0],
            lines[1].replacingOccurrences(of: "action_class=click", with: "action_class=key"),
            lines[2],
        ])
        invalid.append([
            lines[0],
            "PERF_TRACE_ERROR reason=trace_timeout",
            lines[2],
        ])
        invalid.append([
            lines[0],
            lines[1].replacingOccurrences(of: "guest_ns=100", with: "guest_ns=102"),
            lines[2],
        ])
        for candidate in invalid {
            #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
                _ = try SpiceRemoteGuestTrace(
                    lines: candidate,
                    actionClass: "click",
                    token: token
                )
            }
        }
    }

    @Test func collectorUsesCanonicalSingleSchemaTwoLineAndStructuredCommand() async throws {
        try await Stage3LiveRunFixture.withTemporaryDirectory { directory in
            let plan = try Stage3LiveRunFixture.plan()
            let configuration = try Stage3LiveRunFixture.configuration(run: plan.runs[0])
            let runDirectory = Stage3LiveRunFixture.remoteRunDirectory
            let command = try configuration.collectorCommand(
                runDirectory: runDirectory
            )
            #expect(command.executable == "/usr/bin/ssh")
            #expect(command.arguments.last == runDirectory)
            #expect(command.arguments.dropLast().last == configuration.paths.controlScript
                .replacingOccurrences(of: "control.sh", with: "collect-input-events.sh"))
            #expect(!command.arguments.contains("bash"))
            #expect(!command.arguments.contains("-c"))
            #expect(!command.arguments.contains(where: {
                $0.contains(";") || $0.contains("$(") || $0.contains("`")
            }))

            let capturedInput = directory.appending(path: "collector-input.jsonl")
            let fixture = try Stage3RunScriptFixture(
                """
                input="$1"
                shift
                /bin/cat > "$input"
                printf '%s\n' 'PERF_INPUT_EVENT_COLLECTED valid=true reason=none'
                """
            )
            defer { fixture.remove() }
            let runner = SpiceLiveProcessRunner(
                executableURL: fixture.executableURL,
                argumentPrefix: [capturedInput.path]
            )
            let status = try SpiceRemoteRunStatus(
                result: SpiceLiveProcessResult(
                    status: 0,
                    standardOutput: Stage3LiveRunFixture.statusOutput(
                        runDirectory: runDirectory
                    ),
                    standardError: ""
                ),
                configuration: configuration
            )
            let line = Stage3LiveRunFixture.canonicalRecordLine(
                runID: status.evidenceRunID
            )
            try await configuration.appendRecord(
                line,
                runDirectory: runDirectory,
                runner: runner
            )
            #expect(try Data(contentsOf: capturedInput) == line)
            let decoded = try JSONDecoder().decode(
                SpiceInteractionTraceRecord.self,
                from: line.dropLast()
            )
            #expect(decoded.schemaVersion == 2)
            #expect(decoded.valid)
            #expect(decoded.runId == status.evidenceRunID)
            #expect(decoded.runId != configuration.runID)

            let sentinel = directory.appending(path: "must-not-launch")
            let rejectingFixture = try Stage3RunScriptFixture(
                """
                : > "$1"
                exit 0
                """
            )
            defer { rejectingFixture.remove() }
            let rejectingRunner = SpiceLiveProcessRunner(
                executableURL: rejectingFixture.executableURL,
                argumentPrefix: [sentinel.path]
            )
            let malformedInputs = [
                Data(line.dropLast()),
                Data((" " + String(decoding: line, as: UTF8.self)).utf8),
                line + line,
                Data(
                    repeating: 0x61,
                    count: SpiceRemoteLiveConfiguration.maximumCollectorRecordBytes + 1
                ),
                Data(String(decoding: line, as: UTF8.self).replacingOccurrences(
                    of: "\"schema_version\":2",
                    with: "\"schema_version\":1"
                ).utf8),
                Stage3LiveRunFixture.canonicalRecordLine(runID: configuration.runID),
            ]
            for malformed in malformedInputs {
                await #expect(throws: (any Error).self) {
                    try await configuration.appendRecord(
                        malformed,
                        runDirectory: runDirectory,
                        runner: rejectingRunner
                    )
                }
            }
            #expect(!FileManager.default.fileExists(atPath: sentinel.path))
        }
    }

    @Test func readinessPermitIsRequiredBeforeTheFirstActionOnly() throws {
        let baseline: UInt64 = 11
        let blockedStates = [
            SpiceLiveReadinessState(
                windowVisible: false,
                windowOccluded: false,
                hostingVisible: true,
                visibleSubscriptions: 1,
                metalPresentedFrames: 12
            ),
            SpiceLiveReadinessState(
                windowVisible: true,
                windowOccluded: true,
                hostingVisible: true,
                visibleSubscriptions: 1,
                metalPresentedFrames: 12
            ),
            SpiceLiveReadinessState(
                windowVisible: true,
                windowOccluded: false,
                hostingVisible: false,
                visibleSubscriptions: 1,
                metalPresentedFrames: 12
            ),
            SpiceLiveReadinessState(
                windowVisible: true,
                windowOccluded: false,
                hostingVisible: true,
                visibleSubscriptions: 0,
                metalPresentedFrames: 12
            ),
            SpiceLiveReadinessState(
                windowVisible: true,
                windowOccluded: false,
                hostingVisible: true,
                visibleSubscriptions: 1,
                metalPresentedFrames: baseline
            ),
        ]
        for state in blockedStates {
            #expect(state.permit(since: baseline) == nil)
        }
        let ready = SpiceLiveReadinessState(
            windowVisible: true,
            windowOccluded: false,
            hostingVisible: true,
            visibleSubscriptions: 1,
            metalPresentedFrames: baseline + 1
        )
        let permit = try #require(ready.permit(since: baseline))
        let steps = try SpiceLiveInteractionClusterPlan(
            clusterID: Stage3LiveRunFixture.clusterIDs[0]
        ).steps

        var blocked = try SpiceLiveSingleRunExecution(steps: steps)
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try blocked.beginNextStep(readiness: nil)
        }
        #expect(blocked.failed)

        var execution = try SpiceLiveSingleRunExecution(steps: steps)
        let click = try execution.beginNextStep(readiness: permit)
        #expect(click.actionClass == .click)
        try execution.recordExactPresentation(order: click.order)
        try execution.recordLocalAppend(order: click.order)
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try execution.beginNextStep(readiness: nil)
        }

        var success = try SpiceLiveSingleRunExecution(steps: steps)
        for expectedAction in [
            SpiceInteractionActionClass.click, .key, .motion,
        ] {
            let step = try success.beginNextStep(
                readiness: expectedAction == .click ? permit : nil
            )
            #expect(step.actionClass == expectedAction)
            try success.recordExactPresentation(order: step.order)
            try success.recordLocalAppend(order: step.order)
            try success.recordRemoteAppend(order: step.order)
        }
        #expect(success.completed)
        #expect(!success.failed)
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try SpiceLiveSingleRunExecution(steps: Array(steps.dropLast()))
        }
    }

    @Test func singleRunAppendFailuresAreTerminalAndCaptureRetryIsExact() throws {
        let steps = try SpiceLiveInteractionClusterPlan(
            clusterID: Stage3LiveRunFixture.clusterIDs[0]
        ).steps
        let readiness = try #require(SpiceLiveReadinessState(
            windowVisible: true,
            windowOccluded: false,
            hostingVisible: true,
            visibleSubscriptions: 1,
            metalPresentedFrames: 2
        ).permit(since: 1))

        var remoteBeforeLocal = try SpiceLiveSingleRunExecution(steps: steps)
        let remoteBeforeLocalStep = try remoteBeforeLocal.beginNextStep(
            readiness: readiness
        )
        try remoteBeforeLocal.recordExactPresentation(order: remoteBeforeLocalStep.order)
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            try remoteBeforeLocal.recordRemoteAppend(order: remoteBeforeLocalStep.order)
        }
        #expect(remoteBeforeLocal.failed)

        var localFailure = try SpiceLiveSingleRunExecution(steps: steps)
        _ = try localFailure.beginNextStep(readiness: readiness)
        localFailure.fail()
        #expect(localFailure.failed)
        #expect(throws: SpiceLiveInteractionSupportError.invalidTraceProtocol) {
            _ = try localFailure.beginNextStep(readiness: nil)
        }

        try Stage3LiveRunFixture.withTemporaryDirectory { directory in
            let capture = try SpiceInteractionTraceCapture(
                presentationDiagnostics: SpicePresentationDiagnostics(),
                pairId: "cached-pair",
                version: "v0.2.7",
                runId: "cached-run",
                order: 1,
                actionClass: .click,
                token: "471a5b01a43d3ed0",
                checksum: 0x8808_062b
            )
            let missingOutput = directory.appending(path: "missing/input-events.jsonl")
            #expect(throws: (any Error).self) {
                try capture.append(
                    to: SpiceInteractionTraceJSONLWriter(outputURL: missingOutput)
                )
            }
            let output = directory.appending(path: "input-events.jsonl")
            let retried = try capture.append(
                to: SpiceInteractionTraceJSONLWriter(outputURL: output),
                invalidReason: "must_not_replace_derived_reason"
            )
            #expect(retried.invalidReason == "missing_host_input")
            #expect(try Stage3LiveRunFixture.decodeRecords(at: output) == [retried])
            #expect(throws: SpiceInteractionTraceCollectionError.captureAlreadyFinished) {
                try capture.append(
                    to: SpiceInteractionTraceJSONLWriter(outputURL: output)
                )
            }
        }
    }

    @Test func localOutputResolvesCanonicalPrivatePathAndRejectsInvalidRun() throws {
        try Stage3LiveRunFixture.withTemporaryDirectory { directory in
            let realBase = directory.appending(path: "real", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: realBase,
                withIntermediateDirectories: false
            )
            let linkBase = directory.appending(path: "link", directoryHint: .isDirectory)
            try FileManager.default.createSymbolicLink(
                at: linkBase,
                withDestinationURL: realBase
            )
            let runID = "0123456789abcdef"
            let output = try SpiceLiveLocalOutput.create(
                baseDirectory: linkBase,
                runID: runID
            )
            let canonicalBase = realBase.resolvingSymlinksInPath()
            #expect(output.path.hasPrefix("\(canonicalBase.path)/swiftspice-live-\(runID)-"))
            #expect(output.lastPathComponent == "input-events.jsonl")
            #expect(!output.path.contains("/link/"))
            let parent = output.deletingLastPathComponent()
            let permissions = try #require(
                FileManager.default.attributesOfItem(atPath: parent.path)[.posixPermissions]
                    as? NSNumber
            )
            #expect(permissions.intValue & 0o777 == 0o700)

            for invalidRunID in ["", "0123456789abcde", "ABCDEF0123456789", "../escape"] {
                #expect(throws: SpiceLiveInteractionSupportError.invalidConfiguration) {
                    _ = try SpiceLiveLocalOutput.create(
                        baseDirectory: realBase,
                        runID: invalidRunID
                    )
                }
            }
        }
    }

    @Test func directSessionDispatchNeverClaimsAppKitReceipt() {
        let metadata = SpiceLiveInputDispatchMetadata.directSessionAPI
        #expect(metadata.kind == .directSessionAPI)
        #expect(!metadata.reportsAppKitReceipt)
    }
}

private enum Stage3LiveRunFixture {
    static let campaignID = "aaaaaaaaaaaaaaaa"
    static let clusterIDs = (0..<10).map { String(format: "%016x", $0) }
    static let remoteRunDirectory = "/var/tmp/swiftspice-aip00e/logs/20260830T120000Z.a1B2c3"

    static func plan() throws -> SpiceLiveCampaignPlan {
        try SpiceLiveCampaignPlan(
            campaignID: campaignID,
            baselineVersion: "v0.2.7",
            candidateVersion: "v0.3.3",
            clusterIDs: clusterIDs
        )
    }

    static func configuration(
        run: SpiceLiveCampaignRun? = nil
    ) throws -> SpiceRemoteLiveConfiguration {
        let selectedRun: SpiceLiveCampaignRun
        if let run {
            selectedRun = run
        } else {
            selectedRun = try plan().runs[0]
        }
        return try SpiceRemoteLiveConfiguration(environment: [
            "SWIFTSPICE_LIVE_INTERACTION": "1",
            "SWIFTSPICE_ROCKY_SSH_HOST": "rocky9",
            "SWIFTSPICE_PERF_BASE": "/var/tmp/swiftspice-aip00e",
            "SWIFTSPICE_PERF_CONTAINER": "swiftspice-v027-campaign",
            "SWIFTSPICE_PERF_IMAGE": "localhost/swiftspice-v027:measured",
            "SWIFTSPICE_PERF_SPICE_PORT": "15945",
            "SWIFTSPICE_PERF_CONTROL_PORT": "15946",
            "SWIFTSPICE_LIVE_ENDPOINT_HOST": "127.0.0.1",
            "SWIFTSPICE_LIVE_ENDPOINT_PORT": "25945",
            "SWIFTSPICE_LIVE_CAMPAIGN_ID": selectedRun.campaignID,
            "SWIFTSPICE_LIVE_RUN_ID": selectedRun.runID,
            "SWIFTSPICE_LIVE_VERSION": selectedRun.version,
            "SWIFTSPICE_LIVE_CLUSTER_ID": selectedRun.clusterID,
        ])
    }

    static func statusOutput(
        runDirectory: String,
        state: String = "running",
        container: String = "swiftspice-v027-campaign",
        spice: String = "127.0.0.1:15945",
        control: String = "127.0.0.1:15946"
    ) -> String {
        """
        state=\(state)
        container=\(container)
        spice=\(spice)
        control=\(control)
        resolution=1280x720
        run_evidence=\(runDirectory)
        spice_listener=ready
        control_listener=ready
        LISTEN diagnostic may follow required lines

        """
    }

    static func traceLines(
        actionClass: String,
        token: String,
        revision: UInt64
    ) -> [String] {
        [
            "PERF_ARMED action_class=\(actionClass) token=\(token)",
            "PERF_TRACE event=guest_received action_class=\(actionClass) token=\(token) guest_ns=100 marker_revision=\(revision)",
            "PERF_TRACE event=marker_drawn action_class=\(actionClass) token=\(token) guest_ns=101 marker_revision=\(revision)",
        ]
    }

    static func canonicalRecordLine(runID: String) -> Data {
        let record = SpiceInteractionTraceRecord(
            pairId: "live-0000000000000000-1-click",
            version: "v0.2.7",
            runId: runID,
            order: 1,
            actionClass: .click,
            token: "471a5b01a43d3ed0",
            scheduledNs: 1,
            hostInputNs: 2,
            sendStartedNs: 3,
            sendCompletedNs: 4,
            guestReceivedNs: 5,
            guestMarkerDrawnNs: 6,
            displayReceiveNs: 7,
            surfaceReadyNs: 8,
            selectedRevisionReadyNs: 9,
            selectionNs: 10,
            metalCommitNs: 11,
            presentedNs: 12,
            displayChannelID: 0,
            surfaceID: 1,
            surfaceGeneration: 2,
            desktopGeneration: 3,
            frameRevision: 4,
            deliverySequence: 5,
            markerRevision: 6,
            markerChecksum: "8808062b"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var line = try! encoder.encode(record)
        line.append(0x0A)
        return line
    }

    static func decodeRecords(at output: URL) throws -> [SpiceInteractionTraceRecord] {
        try Data(contentsOf: output).split(separator: 0x0A).map {
            try JSONDecoder().decode(SpiceInteractionTraceRecord.self, from: $0)
        }
    }

    static func withTemporaryDirectory<Result>(
        _ operation: (URL) throws -> Result
    ) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-stage3c3-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try operation(directory)
    }

    static func withTemporaryDirectory<Result: Sendable>(
        _ operation: (URL) async throws -> Result
    ) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-stage3c3-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await operation(directory)
    }
}

private struct Stage3RunScriptFixture {
    let directory: URL
    let executableURL: URL

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-stage3c3-script-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        executableURL = directory.appending(path: "fixture.sh")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
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
