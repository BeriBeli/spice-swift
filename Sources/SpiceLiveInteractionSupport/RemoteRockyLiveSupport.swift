import Darwin
import Foundation
import SwiftSpice
import Synchronization

package enum SpiceLiveInteractionSupportError: Error, Sendable, Equatable {
    case notExplicitlyEnabled
    case incompleteIsolatedConfiguration
    case invalidIsolatedConfiguration
    case invalidLiveVersion
    case invalidRunDirectory
    case invalidTicket
    case invalidTraceProtocol
    case childFailed
    case childTimedOut
    case outputLimitExceeded
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
        let standardOutput = Pipe()
        let standardError = Pipe()

        var inputURL: URL?
        var inputDescriptor: Int32 = -1
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
            inputDescriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        } else {
            inputDescriptor = Darwin.open("/dev/null", O_RDONLY | O_CLOEXEC)
        }
        defer {
            if inputDescriptor >= 0 { Darwin.close(inputDescriptor) }
            if let inputURL {
                try? FileManager.default.removeItem(at: inputURL)
            }
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
        }
        guard inputDescriptor >= 0 else {
            throw SpiceLiveInteractionSupportError.childFailed
        }

        let process = try SpiceLiveSpawnedProcess.spawn(
            executablePath: executableURL.path,
            arguments: argumentPrefix + arguments,
            standardInput: inputDescriptor,
            standardOutput: standardOutput.fileHandleForWriting.fileDescriptor,
            standardError: standardError.fileHandleForWriting.fileDescriptor,
            descriptorsClosedInChild: [
                standardOutput.fileHandleForReading.fileDescriptor,
                standardError.fileHandleForReading.fileDescriptor,
            ]
        )
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
    package static let maximumOutputBytesPerStream = 256 * 1_024
    package static let maximumCombinedOutputBytes = 512 * 1_024

    private let process: SpiceLiveSpawnedProcess
    private let standardOutput: Pipe
    private let standardError: Pipe

    fileprivate init(
        process: SpiceLiveSpawnedProcess,
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
        let outputBudget = SpiceLiveOutputBudget(
            maximumBytes: Self.maximumCombinedOutputBytes
        )
        let stdoutCollector = SpiceLivePipeCollector(
            handle: standardOutput.fileHandleForReading,
            maximumBytes: Self.maximumOutputBytesPerStream,
            budget: outputBudget
        )
        let stderrCollector = SpiceLivePipeCollector(
            handle: standardError.fileHandleForReading,
            maximumBytes: Self.maximumOutputBytesPerStream,
            budget: outputBudget
        )
        let stdoutReader = Task.detached { stdoutCollector.collect() }
        let stderrReader = Task.detached { stderrCollector.collect() }
        var collectorsStopped = false

        do {
            let exited = try await waitForExit(
                stdoutCollector,
                stderrCollector,
                within: timeout
            )
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
            guard !(stdoutCollector.exceededLimit || stderrCollector.exceededLimit) else {
                throw SpiceLiveInteractionSupportError.outputLimitExceeded
            }
            await stdoutReader.value
            await stderrReader.value
            stdoutCollector.close()
            stderrCollector.close()
            guard await stopResidualGroupBoundedly() else {
                throw SpiceLiveInteractionSupportError.childFailed
            }
            guard let status = process.reap() else {
                throw SpiceLiveInteractionSupportError.childFailed
            }
            return SpiceLiveProcessResult(
                status: status,
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

    private func waitForExit(
        _ stdout: SpiceLivePipeCollector,
        _ stderr: SpiceLivePipeCollector,
        within timeout: Duration
    ) async throws -> Bool {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !process.hasExited, ContinuousClock().now < deadline {
            if stdout.exceededLimit || stderr.exceededLimit {
                throw SpiceLiveInteractionSupportError.outputLimitExceeded
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if stdout.exceededLimit || stderr.exceededLimit {
            throw SpiceLiveInteractionSupportError.outputLimitExceeded
        }
        return process.hasExited
    }

    private func stopBoundedly() async -> Bool {
        let process = process
        return await Task.detached {
            if process.isReaped { return !process.groupExists }
            // The leader remains unreaped while signals are sent, so its PID
            // cannot be reused and the atomically-created PGID still names
            // only this launch's process tree.
            process.signalGroup(SIGTERM)
            let termDeadline = ContinuousClock().now.advanced(
                by: Self.terminationGrace
            )
            while ContinuousClock().now < termDeadline {
                usleep(10_000)
            }
            process.signalGroup(SIGKILL)
            let killDeadline = ContinuousClock().now.advanced(by: Self.killGrace)
            while ContinuousClock().now < killDeadline {
                if process.hasExited {
                    _ = process.reap()
                    if !process.groupExists { return true }
                }
                usleep(10_000)
            }
            _ = process.reap()
            return !process.groupExists
        }.value
    }

    private func stopResidualGroupBoundedly() async -> Bool {
        guard process.hasResidualGroupMembers else { return true }
        return await stopBoundedly()
    }

    private func waitForCollectors(
        _ stdout: SpiceLivePipeCollector,
        _ stderr: SpiceLivePipeCollector,
        within timeout: Duration
    ) async throws -> Bool {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while !(stdout.isFinished && stderr.isFinished),
              ContinuousClock().now < deadline {
            if stdout.exceededLimit || stderr.exceededLimit {
                throw SpiceLiveInteractionSupportError.outputLimitExceeded
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if stdout.exceededLimit || stderr.exceededLimit {
            throw SpiceLiveInteractionSupportError.outputLimitExceeded
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
        var exceededLimit = false
    }

    private let handle: FileHandle
    private let maximumBytes: Int
    private let budget: SpiceLiveOutputBudget
    private let state = Mutex(State())

    init(
        handle: FileHandle,
        maximumBytes: Int,
        budget: SpiceLiveOutputBudget
    ) {
        self.handle = handle
        self.maximumBytes = maximumBytes
        self.budget = budget
    }

    var data: Data {
        state.withLock(\.data)
    }

    var isFinished: Bool {
        state.withLock(\.isFinished)
    }

    var exceededLimit: Bool {
        state.withLock(\.exceededLimit)
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
                    let accepted = state.withLock { state -> Bool in
                        guard state.data.count <= maximumBytes - chunk.count,
                              budget.reserve(chunk.count) else {
                            state.exceededLimit = true
                            return false
                        }
                        state.data.append(chunk)
                        return true
                    }
                    if !accepted { return }
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

private final class SpiceLiveOutputBudget: Sendable {
    private let maximumBytes: Int
    private let usedBytes = Mutex(0)

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func reserve(_ count: Int) -> Bool {
        usedBytes.withLock { usedBytes in
            guard usedBytes <= maximumBytes - count else { return false }
            usedBytes += count
            return true
        }
    }
}

private final class SpiceLiveSpawnedProcess: @unchecked Sendable {
    private struct State: Sendable {
        var terminationStatus: Int32?
        var reaped = false
    }

    private let processIdentifier: pid_t
    private let processGroup: pid_t
    private let state = Mutex(State())

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        processGroup = processIdentifier
    }

    static func spawn(
        executablePath: String,
        arguments: [String],
        standardInput: Int32,
        standardOutput: Int32,
        standardError: Int32,
        descriptorsClosedInChild: [Int32]
    ) throws -> SpiceLiveSpawnedProcess {
        let allArguments = [executablePath] + arguments
        guard !allArguments.contains(where: { $0.utf8.contains(0) }) else {
            throw SpiceLiveInteractionSupportError.childFailed
        }

        var actions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, standardInput, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, standardOutput, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, standardError, STDERR_FILENO) == 0
        else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
        for descriptor in descriptorsClosedInChild {
            guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else {
                throw SpiceLiveInteractionSupportError.childFailed
            }
        }
        for descriptor in [standardInput, standardOutput, standardError]
        where descriptor > STDERR_FILENO {
            guard posix_spawn_file_actions_addclose(&actions, descriptor) == 0 else {
                throw SpiceLiveInteractionSupportError.childFailed
            }
        }

        var attributes: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
        ) == 0,
            posix_spawnattr_setpgroup(&attributes, 0) == 0
        else {
            throw SpiceLiveInteractionSupportError.childFailed
        }

        let duplicatedArguments = allArguments.map { argument in
            argument.withCString { strdup($0) }
        }
        guard duplicatedArguments.allSatisfy({ $0 != nil }) else {
            for argument in duplicatedArguments { free(argument) }
            throw SpiceLiveInteractionSupportError.childFailed
        }
        defer {
            for argument in duplicatedArguments { free(argument) }
        }
        var mutableArguments = duplicatedArguments + [nil]
        var pid: pid_t = 0
        let result = mutableArguments.withUnsafeMutableBufferPointer { arguments in
            posix_spawn(
                &pid,
                executablePath,
                &actions,
                &attributes,
                arguments.baseAddress,
                environ
            )
        }
        guard result == 0, pid > 0 else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
        return SpiceLiveSpawnedProcess(processIdentifier: pid)
    }

    var hasExited: Bool {
        state.withLock { state in
            if state.reaped { return true }
            var information = siginfo_t()
            guard waitid(
                P_PID,
                id_t(processIdentifier),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            ) == 0 else {
                return errno == ECHILD
            }
            return information.si_pid == processIdentifier
        }
    }

    var isReaped: Bool {
        state.withLock(\.reaped)
    }

    var hasResidualGroupMembers: Bool {
        state.withLock { state in
            guard !state.reaped else { return groupExists }
            // The dead leader remains a zombie here, anchoring both PID and
            // PGID. With no other member, no process can later fork into this
            // group, so the fast path can reap without a grace-period wait.
            var identifiers = [pid_t](repeating: 0, count: 16)
            let count = proc_listpgrppids(
                processGroup,
                &identifiers,
                Int32(identifiers.count * MemoryLayout<pid_t>.stride)
            )
            guard count >= 0 else { return true }
            return identifiers.prefix(Int(count)).contains {
                $0 > 0 && $0 != processIdentifier
            }
        }
    }

    func reap() -> Int32? {
        state.withLock { state in
            if state.reaped { return state.terminationStatus }
            var rawStatus: Int32 = 0
            let result = waitpid(processIdentifier, &rawStatus, WNOHANG)
            guard result == processIdentifier else { return nil }
            let signal = rawStatus & 0x7f
            let status = signal == 0
                ? (rawStatus >> 8) & 0xff
                : 128 + signal
            state.terminationStatus = status
            state.reaped = true
            return status
        }
    }

    func signalGroup(_ signal: Int32) {
        state.withLock { state in
            guard !state.reaped else { return }
            _ = Darwin.kill(-processGroup, signal)
        }
    }

    var groupExists: Bool {
        if Darwin.kill(-processGroup, 0) == 0 { return true }
        return errno == EPERM
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
    package let version: String

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
            "SWIFTSPICE_LIVE_VERSION",
        ]
        guard required.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
            throw SpiceLiveInteractionSupportError.incompleteIsolatedConfiguration
        }

        let sshHost = environment["SWIFTSPICE_ROCKY_SSH_HOST"]!
        let base = environment["SWIFTSPICE_PERF_BASE"]!
        let container = environment["SWIFTSPICE_PERF_CONTAINER"]!
        let image = environment["SWIFTSPICE_PERF_IMAGE"]!
        let endpointHost = environment["SWIFTSPICE_LIVE_ENDPOINT_HOST"]!
        let version = environment["SWIFTSPICE_LIVE_VERSION"]!
        guard Self.matches(
            version,
            "^v(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$"
        ) else {
            throw SpiceLiveInteractionSupportError.invalidLiveVersion
        }
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
        self.version = version
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
