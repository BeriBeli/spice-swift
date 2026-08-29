import AppKit
import CryptoKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import SwiftSpice

@Suite("Remote Rocky live interaction")
struct RemoteRockyLiveInteractionTests {
    @Test func liveGateRequiresAnExplicitCompleteIsolatedEndpointIdentity() throws {
        do {
            _ = try RemoteRockyLiveConfiguration(environment: [:])
            Issue.record("live interaction gate enabled without explicit opt-in")
        } catch let error as RemoteRockyLiveError {
            #expect(error == .notExplicitlyEnabled)
        }

        do {
            _ = try RemoteRockyLiveConfiguration(environment: [
                "SWIFTSPICE_LIVE_INTERACTION": "1",
                "SWIFTSPICE_ROCKY_SSH_HOST": "rocky9",
                "SWIFTSPICE_PERF_BASE": "/home/test/swiftspice-aip00c",
            ])
            Issue.record("partial isolated identity unexpectedly enabled the live gate")
        } catch let error as RemoteRockyLiveError {
            #expect(error == .incompleteIsolatedConfiguration)
        }

        let validEnvironment = [
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
        let configuration = try RemoteRockyLiveConfiguration(environment: validEnvironment)
        #expect(configuration.container == "swiftspice-aip00c-qemu")
        #expect(configuration.spicePort == 6_135)
        #expect(configuration.controlPort == 6_136)
        #expect(configuration.endpointPort == 6_235)

        let forbiddenOverrides: [(String, String)] = [
            ("SWIFTSPICE_PERF_CONTAINER", "swiftspice-perf-ab-qemu"),
            ("SWIFTSPICE_PERF_BASE", "/home/test/swiftspice-remote-closure/perf-ab"),
            ("SWIFTSPICE_ROCKY_SSH_HOST", "-oProxyCommand=touch-pwned"),
        ]
        for (key, value) in forbiddenOverrides {
            var environment = validEnvironment
            environment[key] = value
            do {
                _ = try RemoteRockyLiveConfiguration(environment: environment)
                Issue.record("historical or unsafe endpoint identity was accepted: \(key)")
            } catch let error as RemoteRockyLiveError {
                #expect(error == .invalidIsolatedConfiguration)
            }
        }

        var historicalPorts = validEnvironment
        historicalPorts["SWIFTSPICE_PERF_SPICE_PORT"] = "5935"
        historicalPorts["SWIFTSPICE_PERF_CONTROL_PORT"] = "5936"
        do {
            _ = try RemoteRockyLiveConfiguration(environment: historicalPorts)
            Issue.record("historical endpoint port pair was accepted")
        } catch let error as RemoteRockyLiveError {
            #expect(error == .invalidIsolatedConfiguration)
        }
    }

    @Test(.enabled(if: RemoteRockyLiveConfiguration.isExplicitlyEnabled))
    @MainActor
    func exactGuestMarkerDeliveryReachesTheDrawablePresentedCallback() async throws {
        let configuration = try RemoteRockyLiveConfiguration(
            environment: ProcessInfo.processInfo.environment
        )
        let status = try await configuration.runRemoteScript("status.sh")
        let runDirectory = try #require(status.lines.first {
            $0.hasPrefix("run_evidence=")
        }?.dropFirst("run_evidence=".count)).description
        #expect(status.lines.contains("container=\(configuration.container)"))
        #expect(status.lines.contains("spice_listener=ready"))
        #expect(status.lines.contains("control_listener=ready"))

        // The password crosses only the SSH child's stdout pipe and this local
        // value. Neither failure descriptions nor test output includes it.
        let ticketOutput = try await configuration.runRemoteScript("ticket.sh")
        let ticket = ticketOutput.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ticket.range(of: "^[0-9a-f]{48}$", options: .regularExpression) != nil else {
            throw RemoteRockyLiveError.invalidTicket
        }

        let session = SpiceSession()
        do {
            _ = try await session.connect(
                endpoint: SpiceEndpoint(
                    host: configuration.endpointHost,
                    port: configuration.endpointPort
                ),
                credentials: SpiceCredentials(password: ticket)
            )
            try await runExactInteraction(
                session: session,
                configuration: configuration,
                runDirectory: runDirectory
            )
            await session.disconnect()
        } catch {
            await session.disconnect()
            throw error
        }
    }

    @MainActor
    private func runExactInteraction(
        session: SpiceSession,
        configuration: RemoteRockyLiveConfiguration,
        runDirectory: String
    ) async throws {
        let desktop = SpiceDesktopView(desktop: session.desktop) { input in
            Task {
                try? await session.send(input)
            }
        }
        let hostingView = NSHostingView(rootView: desktop)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.close()
        }

        try await waitForFirstDesktopFrame(session.desktop)
        let baseline = await session.diagnosticsSnapshot()
        let token = String(format: "%016llx", UInt64.random(in: 1...UInt64.max))
        let checksum = markerChecksum(token: token)
        let trace = try configuration.launchRemoteControlTrace(
            actionClass: "click",
            token: token
        )
        defer { trace.terminateIfRunning() }
        let armed = try await trace.readLine(within: .seconds(15))
        guard armed == "PERF_ARMED action_class=click token=\(token)" else {
            throw RemoteRockyLiveError.invalidTraceProtocol
        }

        let outputDirectory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-live-interaction-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let output = outputDirectory.appending(path: "input-events.jsonl")
        let capture = try SpiceInteractionTraceCapture(
            session: session,
            writer: SpiceInteractionTraceJSONLWriter(outputURL: output),
            pairId: "live-\(token)",
            version: "v0.3.1",
            runId: URL(fileURLWithPath: runDirectory).lastPathComponent,
            order: 1,
            actionClass: .click,
            token: token,
            checksum: checksum
        )
        let scheduled = SpiceInteractionHostClock.nowNanoseconds()
        let hostInput = SpiceInteractionHostClock.nowNanoseconds()
        let sendStarted = SpiceInteractionHostClock.nowNanoseconds()
        try capture.recordHostInput(
            scheduledNs: scheduled,
            hostInputNs: hostInput,
            sendStartedNs: sendStarted
        )
        try await session.send(.mousePress(.left))
        try capture.recordSendCompleted(at: SpiceInteractionHostClock.nowNanoseconds())
        try await session.send(.mouseRelease(.left))

        let traceResult = try await trace.finish(within: .seconds(15))
        guard traceResult.status == 0 else {
            throw RemoteRockyLiveError.traceFailed
        }
        let guest = try RemoteRockyGuestTrace(
            lines: [armed] + traceResult.lines,
            actionClass: "click",
            token: token
        )
        try capture.recordGuestEvidence(
            receivedNs: guest.receivedNanoseconds,
            drawnNs: guest.drawnNanoseconds,
            markerRevision: guest.markerRevision
        )

        let exactIdentity = try await withRemoteRockyLiveTimeout(.seconds(15)) {
            try await capture.waitForExactPresentation()
        }
        let record = try capture.finish()
        #expect(record.valid)
        #expect(record.schemaVersion == SpiceInteractionTraceRecord.currentSchemaVersion)
        #expect(record.token == token)
        #expect(record.markerChecksum == String(format: "%08x", checksum))
        #expect(record.desktopGeneration == exactIdentity.desktopGeneration)
        #expect(record.displayChannelID == exactIdentity.displayChannelID)
        #expect(record.surfaceID == exactIdentity.surfaceID)
        #expect(record.surfaceGeneration == exactIdentity.surfaceGeneration)
        #expect(record.frameRevision == exactIdentity.frameRevision)
        #expect(record.deliverySequence == exactIdentity.deliverySequence)
        #expect(record.guestReceivedNs == guest.receivedNanoseconds)
        #expect(record.guestMarkerDrawnNs == guest.drawnNanoseconds)
        #expect(record.markerRevision == guest.markerRevision)
        #expect(record.selectedRevisionReadyNs != nil)
        #expect(record.selectionNs != nil)
        #expect(record.metalCommitNs != nil)
        #expect(record.presentedNs != nil)
        if let ready = record.selectedRevisionReadyNs, let selection = record.selectionNs {
            #expect(selection >= ready)
        }

        let encoded = try Data(contentsOf: output)
        #expect(encoded.split(separator: 0x0A).count == 1)
        try await configuration.appendCollectedRecord(encoded, to: runDirectory)

        let final = await session.diagnosticsSnapshot()
        #expect(final.gpuErrors == baseline.gpuErrors)
        #expect(final.poolExhaustions == baseline.poolExhaustions)
        #expect(final.publisherStaleSnapshots == baseline.publisherStaleSnapshots)
        #expect(final.metalPresentationErrors == baseline.metalPresentationErrors)
        #expect(final.metalCommandBuffersCommitted > baseline.metalCommandBuffersCommitted)
        #expect(SpiceMetalPresenter.maximumInFlightCommands == 2)
    }

    private func waitForFirstDesktopFrame(_ desktop: SpiceDesktopSource) async throws {
        let subscription = desktop.subscribe()
        subscription.setDemand(.visible)
        defer {
            subscription.setDemand(.none)
            subscription.cancel()
        }
        _ = try await withRemoteRockyLiveTimeout(.seconds(20)) {
            for await snapshot in subscription.updates where snapshot.frame != nil {
                return snapshot
            }
            throw RemoteRockyLiveError.desktopClosed
        }
    }

    private func markerChecksum(token: String) -> UInt32 {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

private struct RemoteRockyLiveConfiguration: Sendable {
    static var isExplicitlyEnabled: Bool {
        ProcessInfo.processInfo.environment["SWIFTSPICE_LIVE_INTERACTION"] == "1"
    }

    let sshHost: String
    let base: String
    let container: String
    let image: String
    let spicePort: UInt16
    let controlPort: UInt16
    let endpointHost: String
    let endpointPort: UInt16

    init(environment: [String: String]) throws {
        guard environment["SWIFTSPICE_LIVE_INTERACTION"] == "1" else {
            throw RemoteRockyLiveError.notExplicitlyEnabled
        }
        let required = [
            "SWIFTSPICE_ROCKY_SSH_HOST",
            "SWIFTSPICE_PERF_BASE",
            "SWIFTSPICE_PERF_CONTAINER",
            "SWIFTSPICE_PERF_IMAGE",
            "SWIFTSPICE_PERF_SPICE_PORT",
            "SWIFTSPICE_PERF_CONTROL_PORT",
        ]
        guard required.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
            throw RemoteRockyLiveError.incompleteIsolatedConfiguration
        }
        sshHost = environment["SWIFTSPICE_ROCKY_SSH_HOST"]!
        base = environment["SWIFTSPICE_PERF_BASE"]!
        container = environment["SWIFTSPICE_PERF_CONTAINER"]!
        image = environment["SWIFTSPICE_PERF_IMAGE"]!
        guard !sshHost.hasPrefix("-"),
              Self.matches(sshHost, "^[A-Za-z0-9_.@:-]+$"),
              Self.validBase(base),
              Self.matches(container, "^[a-z0-9][a-z0-9_.-]{0,127}$"),
              Self.matches(
                  image,
                  "^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$"
              ),
              let spicePort = UInt16(environment["SWIFTSPICE_PERF_SPICE_PORT"]!),
              let controlPort = UInt16(environment["SWIFTSPICE_PERF_CONTROL_PORT"]!),
              spicePort >= 1_024,
              controlPort >= 1_024,
              spicePort != controlPort,
              container != "swiftspice-perf-ab-qemu",
              !(spicePort == 5_935 && controlPort == 5_936),
              !base.hasSuffix("/swiftspice-remote-closure/perf-ab")
        else {
            throw RemoteRockyLiveError.invalidIsolatedConfiguration
        }
        self.spicePort = spicePort
        self.controlPort = controlPort
        endpointHost = environment["SWIFTSPICE_LIVE_ENDPOINT_HOST"] ?? "127.0.0.1"
        guard Self.matches(endpointHost, "^[A-Za-z0-9_.:-]+$") else {
            throw RemoteRockyLiveError.invalidIsolatedConfiguration
        }
        if let localPort = environment["SWIFTSPICE_LIVE_ENDPOINT_PORT"] {
            guard let endpointPort = UInt16(localPort), endpointPort >= 1_024 else {
                throw RemoteRockyLiveError.invalidIsolatedConfiguration
            }
            self.endpointPort = endpointPort
        } else {
            endpointPort = spicePort
        }
    }

    func runRemoteScript(_ script: String) async throws -> RemoteRockyChildResult {
        let child = try launchSSH(arguments: remoteEnvironment + [
            "\(base)/remote/\(script)",
        ])
        return try await child.finish(within: .seconds(20))
    }

    func launchRemoteControlTrace(
        actionClass: String,
        token: String
    ) throws -> RemoteRockyLiveChild {
        try launchSSH(arguments: remoteEnvironment + [
            "\(base)/remote/control.sh", "trace", actionClass, token,
        ])
    }

    func appendCollectedRecord(_ record: Data, to runDirectory: String) async throws {
        guard Self.validBase(runDirectory) else {
            throw RemoteRockyLiveError.invalidRunDirectory
        }
        let child = try launchSSH(
            arguments: remoteEnvironment + [
                "\(base)/remote/collect-input-events.sh", runDirectory,
            ],
            standardInput: record
        )
        let result = try await child.finish(within: .seconds(20))
        guard result.status == 0,
              result.lines.contains(where: { $0.hasPrefix("PERF_INPUT_EVENT_COLLECTED ") })
        else {
            throw RemoteRockyLiveError.collectorFailed
        }
    }

    private var remoteEnvironment: [String] {
        [
            "env",
            "SWIFTSPICE_PERF_BASE=\(base)",
            "SWIFTSPICE_PERF_CONTAINER=\(container)",
            "SWIFTSPICE_PERF_IMAGE=\(image)",
            "SWIFTSPICE_PERF_SPICE_PORT=\(spicePort)",
            "SWIFTSPICE_PERF_CONTROL_PORT=\(controlPort)",
        ]
    }

    private func launchSSH(
        arguments: [String],
        standardInput: Data? = nil
    ) throws -> RemoteRockyLiveChild {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-o", "BatchMode=yes", sshHost] + arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        if let standardInput {
            let input = Pipe()
            process.standardInput = input
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: standardInput)
            try input.fileHandleForWriting.close()
            return RemoteRockyLiveChild(
                process: process,
                standardOutput: standardOutput,
                standardError: standardError
            )
        }
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return RemoteRockyLiveChild(
            process: process,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }

    private static func validBase(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value != "/"
            && !value.hasSuffix("/")
            && !value.contains("//")
            && !value.split(separator: "/").contains(".")
            && !value.split(separator: "/").contains("..")
            && matches(value, "^/[A-Za-z0-9_./-]+$")
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }
}

private final class RemoteRockyLiveChild: @unchecked Sendable {
    let process: Process
    private let standardOutput: Pipe
    private let standardError: Pipe

    init(process: Process, standardOutput: Pipe, standardError: Pipe) {
        self.process = process
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    func readLine(within timeout: Duration) async throws -> String {
        try await Task.detached {
            try readRemoteRockyLiveLine(
                from: self.standardOutput.fileHandleForReading,
                within: timeout
            )
        }.value
    }

    func finish(within timeout: Duration) async throws -> RemoteRockyChildResult {
        try await Task.detached {
            let stdoutReader = Task.detached {
                self.standardOutput.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrReader = Task.detached {
                self.standardError.fileHandleForReading.readDataToEndOfFile()
            }
            let deadline = ContinuousClock().now.advanced(by: timeout)
            while self.process.isRunning, ContinuousClock().now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !self.process.isRunning else {
                self.process.terminate()
                self.process.waitUntilExit()
                throw RemoteRockyLiveError.childTimedOut
            }
            self.process.waitUntilExit()
            let stdout = await stdoutReader.value
            let stderr = await stderrReader.value
            return RemoteRockyChildResult(
                status: self.process.terminationStatus,
                text: String(decoding: stdout, as: UTF8.self),
                standardError: String(decoding: stderr, as: UTF8.self)
            )
        }.value
    }

    func terminateIfRunning() {
        if process.isRunning {
            process.terminate()
        }
    }
}

private struct RemoteRockyChildResult: Sendable {
    let status: Int32
    let text: String
    let standardError: String

    var lines: [String] {
        text.split(whereSeparator: \Character.isNewline).map(String.init)
    }
}

private struct RemoteRockyGuestTrace {
    let receivedNanoseconds: UInt64
    let drawnNanoseconds: UInt64
    let markerRevision: UInt64

    init(lines: [String], actionClass: String, token: String) throws {
        guard lines.first == "PERF_ARMED action_class=\(actionClass) token=\(token)",
              lines.count == 3,
              let received = Self.parse(lines[1], event: "guest_received"),
              let drawn = Self.parse(lines[2], event: "marker_drawn"),
              received.actionClass == actionClass,
              drawn.actionClass == actionClass,
              received.token == token,
              drawn.token == token,
              received.revision == drawn.revision,
              received.nanoseconds <= drawn.nanoseconds
        else {
            throw RemoteRockyLiveError.invalidTraceProtocol
        }
        receivedNanoseconds = received.nanoseconds
        drawnNanoseconds = drawn.nanoseconds
        markerRevision = received.revision
    }

    private static func parse(
        _ line: String,
        event: String
    ) -> (actionClass: String, token: String, nanoseconds: UInt64, revision: UInt64)? {
        let fields = line.split(separator: " ")
        guard fields.count == 6,
              fields[0] == "PERF_TRACE",
              fields[1] == "event=\(event)",
              fields[2].hasPrefix("action_class="),
              fields[3].hasPrefix("token="),
              fields[4].hasPrefix("guest_ns="),
              fields[5].hasPrefix("marker_revision="),
              let nanoseconds = UInt64(fields[4].dropFirst("guest_ns=".count)),
              let revision = UInt64(fields[5].dropFirst("marker_revision=".count))
        else { return nil }
        return (
            String(fields[2].dropFirst("action_class=".count)),
            String(fields[3].dropFirst("token=".count)),
            nanoseconds,
            revision
        )
    }
}

private func readRemoteRockyLiveLine(
    from handle: FileHandle,
    within timeout: Duration
) throws -> String {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    var bytes = Data()
    while ContinuousClock().now < deadline {
        var descriptor = pollfd(
            fd: handle.fileDescriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let result = Darwin.poll(&descriptor, 1, 50)
        if result < 0, errno == EINTR { continue }
        guard result >= 0 else { throw RemoteRockyLiveError.childFailed }
        guard result > 0 else { continue }
        var byte: UInt8 = 0
        guard Darwin.read(handle.fileDescriptor, &byte, 1) == 1 else {
            throw RemoteRockyLiveError.childFailed
        }
        if byte == 0x0A {
            if bytes.last == 0x0D { bytes.removeLast() }
            return String(decoding: bytes, as: UTF8.self)
        }
        bytes.append(byte)
    }
    throw RemoteRockyLiveError.childTimedOut
}

private func withRemoteRockyLiveTimeout<Value: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw RemoteRockyLiveError.exactPresentationTimedOut
        }
        guard let value = try await group.next() else {
            throw RemoteRockyLiveError.childFailed
        }
        group.cancelAll()
        return value
    }
}

private enum RemoteRockyLiveError: Error, Equatable {
    case notExplicitlyEnabled
    case incompleteIsolatedConfiguration
    case invalidIsolatedConfiguration
    case invalidRunDirectory
    case invalidTicket
    case invalidTraceProtocol
    case traceFailed
    case collectorFailed
    case desktopClosed
    case exactPresentationTimedOut
    case childTimedOut
    case childFailed
}
