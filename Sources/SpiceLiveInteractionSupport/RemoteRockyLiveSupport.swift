import Darwin
import Foundation
import SwiftSpice
import Synchronization

package enum SpiceLiveInteractionSupportError: Error, Sendable, Equatable {
    case notExplicitlyEnabled
    case incompleteIsolatedConfiguration
    case invalidIsolatedConfiguration
    case invalidRunDirectory
    case invalidTicket
    case invalidTraceProtocol
    case childFailed
    case childTimedOut
    case operationTimedOut
}

package enum SpiceLiveInteractionStage: String, Sendable {
    case configuration
    case remoteStatus = "remote_status"
    case ticket
    case connection
    case foregroundWindow = "foreground_window"
    case initialPresentation = "initial_presentation"
    case arm
    case inputSend = "input_send"
    case guestEvidence = "guest_evidence"
    case exactPresentation = "exact_presentation"
    case localRecord = "local_record"
    case remoteCollector = "remote_collector"
}

package struct SpiceLiveFinalizedTrace: Sendable, Equatable {
    package let record: SpiceInteractionTraceRecord
    package let encodedJSONL: Data

    package init(record: SpiceInteractionTraceRecord, encodedJSONL: Data) {
        self.record = record
        self.encodedJSONL = encodedJSONL
    }
}

/// The non-UI portion of the live harness completion protocol. Tests can
/// exercise the exact-presentation and derived-invalid paths without creating
/// an AppKit window or contacting the Rocky fixture.
package struct SpiceLiveTraceOrchestrator: Sendable {
    private let capture: SpiceInteractionTraceCapture
    private let outputURL: URL

    package init(
        capture: SpiceInteractionTraceCapture,
        outputURL: URL
    ) {
        self.capture = capture
        self.outputURL = outputURL
    }

    package func completeAfterExactPresentation(
        timeout: Duration
    ) async throws -> SpiceLiveFinalizedTrace {
        _ = try await withSpiceLiveTimeout(timeout) {
            try await capture.waitForExactPresentation()
        }
        let record = try capture.finish()
        guard record.valid,
              record.schemaVersion == SpiceInteractionTraceRecord.currentSchemaVersion else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return try finalized(record)
    }

    /// Finishes with the assembler's own derived invalid reason. In
    /// particular, this must not replace a missing receive/selection/commit/
    /// presented reason with the executable's coarse failure stage.
    package func finishDerivedInvalid() throws -> SpiceLiveFinalizedTrace {
        try finalized(capture.finish())
    }

    private func finalized(
        _ record: SpiceInteractionTraceRecord
    ) throws -> SpiceLiveFinalizedTrace {
        let encoded = try Data(contentsOf: outputURL)
        guard encoded.split(separator: 0x0A).count == 1 else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return SpiceLiveFinalizedTrace(record: record, encodedJSONL: encoded)
    }
}

package struct SpiceLiveProcessResult: Sendable, Equatable {
    package let status: Int32
    package let standardOutput: String
    package let standardError: String

    package var outputLines: [String] {
        standardOutput.split(whereSeparator: \Character.isNewline).map(String.init)
    }
}

/// Injectable at the executable boundary without placing process or SSH
/// concerns in the SwiftSpice library target.
package struct SpiceLiveProcessRunner: Sendable {
    package let executableURL: URL
    package let argumentPrefix: [String]

    package init(executableURL: URL, argumentPrefix: [String] = []) {
        self.executableURL = executableURL
        self.argumentPrefix = argumentPrefix
    }

    package static let ssh = Self(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        argumentPrefix: ["-o", "BatchMode=yes"]
    )

    package func launch(
        arguments: [String],
        standardInput: Data? = nil
    ) throws -> SpiceLiveChildProcess {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = argumentPrefix + arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        var inputURL: URL?
        var inputHandle: FileHandle?
        if let standardInput {
            let url = FileManager.default.temporaryDirectory.appending(
                path: "swiftspice-live-stdin-\(UUID().uuidString)",
                directoryHint: .notDirectory
            )
            try standardInput.write(to: url, options: [.atomic])
            guard chmod(url.path, S_IRUSR | S_IWUSR) == 0 else {
                try? FileManager.default.removeItem(at: url)
                throw SpiceLiveInteractionSupportError.childFailed
            }
            inputURL = url
            inputHandle = try FileHandle(forReadingFrom: url)
            process.standardInput = inputHandle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer {
            try? inputHandle?.close()
            if let inputURL {
                try? FileManager.default.removeItem(at: inputURL)
            }
        }
        try process.run()
        return SpiceLiveChildProcess(
            process: process,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}

package final class SpiceLiveChildProcess: @unchecked Sendable {
    package static let terminationGrace = Duration.milliseconds(500)
    package static let killGrace = Duration.milliseconds(500)
    package static let pipeDrainGrace = Duration.milliseconds(500)

    private let process: Process
    private let standardOutput: Pipe
    private let standardError: Pipe

    fileprivate init(
        process: Process,
        standardOutput: Pipe,
        standardError: Pipe
    ) {
        self.process = process
        self.standardOutput = standardOutput
        self.standardError = standardError
    }

    package func readOutputLine(within timeout: Duration) async throws -> String {
        try await Task.detached {
            try Self.readLine(
                from: self.standardOutput.fileHandleForReading,
                within: timeout
            )
        }.value
    }

    package func finish(within timeout: Duration) async throws -> SpiceLiveProcessResult {
        let stdoutCollector = SpiceLivePipeCollector(
            handle: standardOutput.fileHandleForReading
        )
        let stderrCollector = SpiceLivePipeCollector(
            handle: standardError.fileHandleForReading
        )
        let stdoutReader = Task.detached { stdoutCollector.collect() }
        let stderrReader = Task.detached { stderrCollector.collect() }
        var collectorsStopped = false

        do {
            let exited = try await waitForExit(within: timeout)
            guard exited else {
                _ = await stopBoundedly()
                await stopCollectors(
                    stdoutCollector,
                    stderrCollector,
                    stdoutReader,
                    stderrReader
                )
                collectorsStopped = true
                throw SpiceLiveInteractionSupportError.childTimedOut
            }

            let drained = try await waitForCollectors(
                stdoutCollector,
                stderrCollector,
                within: Self.pipeDrainGrace
            )
            guard drained else {
                await stopCollectors(
                    stdoutCollector,
                    stderrCollector,
                    stdoutReader,
                    stderrReader
                )
                collectorsStopped = true
                throw SpiceLiveInteractionSupportError.childTimedOut
            }
            await stdoutReader.value
            await stderrReader.value
            stdoutCollector.close()
            stderrCollector.close()
            return SpiceLiveProcessResult(
                status: process.terminationStatus,
                standardOutput: String(decoding: stdoutCollector.data, as: UTF8.self),
                standardError: String(decoding: stderrCollector.data, as: UTF8.self)
            )
        } catch {
            if !collectorsStopped {
                _ = await stopBoundedly()
                await stopCollectors(
                    stdoutCollector,
                    stderrCollector,
                    stdoutReader,
                    stderrReader
                )
            }
            throw error
        }
    }

    @discardableResult
    package func terminateAndWait() async -> Bool {
        let exited = await stopBoundedly()
        standardOutput.fileHandleForReading.closeFile()
        standardError.fileHandleForReading.closeFile()
        return exited
    }

    private func waitForExit(within timeout: Duration) async throws -> Bool {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while process.isRunning, ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return !process.isRunning
    }

    private func stopBoundedly() async -> Bool {
        guard process.isRunning else { return true }
        process.terminate()
        if await waitForExitIgnoringCancellation(within: Self.terminationGrace) {
            return true
        }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        return await waitForExitIgnoringCancellation(within: Self.killGrace)
    }

    private func waitForExitIgnoringCancellation(within timeout: Duration) async -> Bool {
        let process = process
        return await Task.detached {
            let deadline = ContinuousClock().now.advanced(by: timeout)
            while process.isRunning, ContinuousClock().now < deadline {
                usleep(10_000)
            }
            return !process.isRunning
        }.value
    }

    private func waitForCollectors(
        _ stdout: SpiceLivePipeCollector,
        _ stderr: SpiceLivePipeCollector,
        within timeout: Duration
    ) async throws -> Bool {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !(stdout.isFinished && stderr.isFinished),
              ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return stdout.isFinished && stderr.isFinished
    }

    private func stopCollectors(
        _ stdout: SpiceLivePipeCollector,
        _ stderr: SpiceLivePipeCollector,
        _ stdoutTask: Task<Void, Never>,
        _ stderrTask: Task<Void, Never>
    ) async {
        // Both collectors use nonblocking reads and a 50 ms poll, so they
        // observe cancellation within one bounded poll cycle. Close only
        // afterwards to prevent an in-flight read from racing fd reuse.
        stdoutTask.cancel()
        stderrTask.cancel()
        await stdoutTask.value
        await stderrTask.value
        stdout.close()
        stderr.close()
    }

    private static func readLine(
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
            guard result >= 0 else {
                throw SpiceLiveInteractionSupportError.childFailed
            }
            guard result > 0 else { continue }
            var byte: UInt8 = 0
            guard Darwin.read(handle.fileDescriptor, &byte, 1) == 1 else {
                throw SpiceLiveInteractionSupportError.childFailed
            }
            if byte == 0x0A {
                if bytes.last == 0x0D { bytes.removeLast() }
                return String(decoding: bytes, as: UTF8.self)
            }
            guard bytes.count < 4_096 else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }
            bytes.append(byte)
        }
        throw SpiceLiveInteractionSupportError.childTimedOut
    }
}

private final class SpiceLivePipeCollector: @unchecked Sendable {
    private struct State: Sendable {
        var data = Data()
        var isFinished = false
    }

    private let handle: FileHandle
    private let state = Mutex(State())

    init(handle: FileHandle) {
        self.handle = handle
    }

    var data: Data {
        state.withLock(\.data)
    }

    var isFinished: Bool {
        state.withLock(\.isFinished)
    }

    func collect() {
        defer {
            state.withLock { $0.isFinished = true }
        }
        let descriptor = handle.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return
        }

        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while !Task.isCancelled {
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&pollDescriptor, 1, 50)
            if pollResult < 0, errno == EINTR { continue }
            if pollResult < 0 { return }
            if pollResult == 0 { continue }

            while !Task.isCancelled {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(buffer.prefix(count))
                    state.withLock { $0.data.append(chunk) }
                    continue
                }
                if count == 0 { return }
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                return
            }
        }
    }

    func close() {
        try? handle.close()
    }
}

package struct SpiceRemoteLiveConfiguration: Sendable, Equatable {
    package let sshHost: String
    package let base: String
    package let container: String
    package let image: String
    package let spicePort: UInt16
    package let controlPort: UInt16
    package let endpointHost: String
    package let endpointPort: UInt16

    package init(environment: [String: String]) throws {
        guard environment["SWIFTSPICE_LIVE_INTERACTION"] == "1" else {
            throw SpiceLiveInteractionSupportError.notExplicitlyEnabled
        }
        let required = [
            "SWIFTSPICE_ROCKY_SSH_HOST",
            "SWIFTSPICE_PERF_BASE",
            "SWIFTSPICE_PERF_CONTAINER",
            "SWIFTSPICE_PERF_IMAGE",
            "SWIFTSPICE_PERF_SPICE_PORT",
            "SWIFTSPICE_PERF_CONTROL_PORT",
            "SWIFTSPICE_LIVE_ENDPOINT_HOST",
            "SWIFTSPICE_LIVE_ENDPOINT_PORT",
        ]
        guard required.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
            throw SpiceLiveInteractionSupportError.incompleteIsolatedConfiguration
        }

        let sshHost = environment["SWIFTSPICE_ROCKY_SSH_HOST"]!
        let base = environment["SWIFTSPICE_PERF_BASE"]!
        let container = environment["SWIFTSPICE_PERF_CONTAINER"]!
        let image = environment["SWIFTSPICE_PERF_IMAGE"]!
        let endpointHost = environment["SWIFTSPICE_LIVE_ENDPOINT_HOST"]!
        guard !sshHost.hasPrefix("-"),
              Self.matches(sshHost, "^[A-Za-z0-9_.@:-]+$"),
              Self.validAbsolutePath(base),
              Self.matches(container, "^[a-z0-9][a-z0-9_.-]{0,127}$"),
              Self.matches(
                  image,
                  "^[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$"
              ),
              Self.matches(endpointHost, "^[A-Za-z0-9_.:-]+$"),
              let spicePort = UInt16(environment["SWIFTSPICE_PERF_SPICE_PORT"]!),
              let controlPort = UInt16(environment["SWIFTSPICE_PERF_CONTROL_PORT"]!),
              let endpointPort = UInt16(environment["SWIFTSPICE_LIVE_ENDPOINT_PORT"]!),
              spicePort >= 1_024,
              controlPort >= 1_024,
              endpointPort >= 1_024,
              spicePort != controlPort,
              endpointPort != spicePort,
              endpointPort != 5_935,
              endpointPort != 15_935,
              container != "swiftspice-perf-ab-qemu",
              !(spicePort == 5_935 && controlPort == 5_936),
              !base.hasSuffix("/swiftspice-remote-closure/perf-ab")
        else {
            throw SpiceLiveInteractionSupportError.invalidIsolatedConfiguration
        }
        self.sshHost = sshHost
        self.base = base
        self.container = container
        self.image = image
        self.spicePort = spicePort
        self.controlPort = controlPort
        self.endpointHost = endpointHost
        self.endpointPort = endpointPort
    }

    package func runRemoteScript(
        _ script: String,
        runner: SpiceLiveProcessRunner = .ssh
    ) async throws -> SpiceLiveProcessResult {
        guard Self.matches(script, "^[a-z0-9][a-z0-9.-]*\\.sh$") else {
            throw SpiceLiveInteractionSupportError.invalidIsolatedConfiguration
        }
        let child = try runner.launch(arguments: remoteArguments + ["\(base)/remote/\(script)"])
        return try await child.finish(within: .seconds(20))
    }

    package func launchControlTrace(
        actionClass: String,
        token: String,
        runner: SpiceLiveProcessRunner = .ssh
    ) throws -> SpiceLiveChildProcess {
        guard ["click", "key", "motion"].contains(actionClass),
              Self.matches(token, "^[0-9a-f]{16}$") else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return try runner.launch(arguments: remoteArguments + [
            "\(base)/remote/control.sh", "trace", actionClass, token,
        ])
    }

    package func appendRecord(
        _ record: Data,
        runDirectory: String,
        runner: SpiceLiveProcessRunner = .ssh
    ) async throws {
        guard Self.validAbsolutePath(runDirectory),
              runDirectory.hasPrefix("\(base)/logs/") else {
            throw SpiceLiveInteractionSupportError.invalidRunDirectory
        }
        let child = try runner.launch(
            arguments: remoteArguments + [
                "\(base)/remote/collect-input-events.sh", runDirectory,
            ],
            standardInput: record
        )
        let result = try await child.finish(within: .seconds(20))
        guard result.status == 0,
              result.outputLines.contains(where: {
                  $0.hasPrefix("PERF_INPUT_EVENT_COLLECTED ")
              }) else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
    }

    package func runDirectory(from status: SpiceLiveProcessResult) throws -> String {
        guard status.status == 0,
              let value = status.outputLines.first(where: {
                  $0.hasPrefix("run_evidence=")
              }).map({ String($0.dropFirst("run_evidence=".count)) }),
              Self.validAbsolutePath(value),
              value.hasPrefix("\(base)/logs/") else {
            throw SpiceLiveInteractionSupportError.invalidRunDirectory
        }
        return value
    }

    package func ticket(from result: SpiceLiveProcessResult) throws -> String {
        let value = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0,
              Self.matches(value, "^[0-9a-f]{48}$") else {
            throw SpiceLiveInteractionSupportError.invalidTicket
        }
        return value
    }

    private var remoteArguments: [String] {
        [
            sshHost,
            "env",
            "SWIFTSPICE_PERF_BASE=\(base)",
            "SWIFTSPICE_PERF_CONTAINER=\(container)",
            "SWIFTSPICE_PERF_IMAGE=\(image)",
            "SWIFTSPICE_PERF_SPICE_PORT=\(spicePort)",
            "SWIFTSPICE_PERF_CONTROL_PORT=\(controlPort)",
        ]
    }

    private static func validAbsolutePath(_ value: String) -> Bool {
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

package struct SpiceRemoteGuestTrace: Sendable, Equatable {
    package let receivedNanoseconds: UInt64
    package let drawnNanoseconds: UInt64
    package let markerRevision: UInt64

    package init(lines: [String], actionClass: String, token: String) throws {
        guard lines.count == 3,
              lines[0] == "PERF_ARMED action_class=\(actionClass) token=\(token)",
              let received = Self.parse(lines[1], event: "guest_received"),
              let drawn = Self.parse(lines[2], event: "marker_drawn"),
              received.actionClass == actionClass,
              drawn.actionClass == actionClass,
              received.token == token,
              drawn.token == token,
              received.revision == drawn.revision,
              received.nanoseconds <= drawn.nanoseconds else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
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
              let revision = UInt64(fields[5].dropFirst("marker_revision=".count)) else {
            return nil
        }
        return (
            String(fields[2].dropFirst("action_class=".count)),
            String(fields[3].dropFirst("token=".count)),
            nanoseconds,
            revision
        )
    }
}

package func withSpiceLiveTimeout<Value: Sendable>(
    _ timeout: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw SpiceLiveInteractionSupportError.operationTimedOut
        }
        guard let value = try await group.next() else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
        group.cancelAll()
        return value
    }
}
