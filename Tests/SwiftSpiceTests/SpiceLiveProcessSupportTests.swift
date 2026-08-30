import Darwin
import Foundation
import Testing
@testable import SpiceLiveInteractionSupport

@Suite("Live interaction child process support", .serialized)
struct SpiceLiveProcessSupportTests {
    @Test func processKeepsStdinStdoutAndStderrSeparated() async throws {
        let fixture = try Stage3ProcessScriptFixture(
            """
            input=$(/bin/cat)
            printf 'OUT:%s\n' "$input"
            printf 'ERR:%s\n' "$1" >&2
            """
        )
        defer { fixture.remove() }
        let child = try SpiceLiveProcessRunner(
            executableURL: fixture.executableURL,
            argumentPrefix: ["argument"]
        ).launch(
            arguments: [],
            standardInput: Data("canonical-input".utf8)
        )

        let result = try await child.finish(within: .seconds(5))

        #expect(result.status == 0)
        #expect(result.standardOutput == "OUT:canonical-input\n")
        #expect(result.standardError == "ERR:argument\n")
    }

    @Test func outputLimitsAcceptTheExactBoundAndFailClosedOneBytePast() async throws {
        let streamLimit = SpiceLiveChildProcess.maximumOutputBytesPerStream
        let exact = try Stage3ProcessScriptFixture(
            """
            /bin/dd if=/dev/zero bs=\(streamLimit) count=1 2>/dev/null
            exec 3>&2
            /bin/dd if=/dev/zero bs=\(streamLimit) count=1 2>/dev/null 1>&3
            exec 3>&-
            """
        )
        defer { exact.remove() }
        let exactChild = try SpiceLiveProcessRunner(
            executableURL: exact.executableURL
        ).launch(arguments: [])

        let exactResult = try await exactChild.finish(within: .seconds(5))

        #expect(exactResult.standardOutput.utf8.count == streamLimit)
        #expect(exactResult.standardError.utf8.count == streamLimit)
        #expect(
            exactResult.standardOutput.utf8.count + exactResult.standardError.utf8.count
                == SpiceLiveChildProcess.maximumCombinedOutputBytes
        )

        for stream in ["stdout", "stderr"] {
            try await Stage3ProcessFixture.withTemporaryDirectory { directory in
                let pidFile = directory.appending(path: "pid")
                let secret = "ticket=0123456789abcdef0123456789abcdef0123456789abcdef"
                let extraCount = streamLimit - secret.utf8.count + 1
                let output: String
                if stream == "stdout" {
                    output = """
                    printf '%s' '\(secret)'
                    /bin/dd if=/dev/zero bs=\(extraCount) count=1 2>/dev/null
                    """
                } else {
                    output = """
                    exec 3>&2
                    printf '%s' '\(secret)' >&3
                    /bin/dd if=/dev/zero bs=\(extraCount) count=1 2>/dev/null 1>&3
                    exec 3>&-
                    """
                }
                let overflowing = try Stage3ProcessScriptFixture(
                    """
                    printf '%s\n' "$$" > "$1"
                    trap '' TERM
                    \(output)
                    while :; do :; done
                    """
                )
                defer { overflowing.remove() }
                let child = try SpiceLiveProcessRunner(
                    executableURL: overflowing.executableURL
                ).launch(arguments: [pidFile.path])
                var observed: SpiceLiveInteractionSupportError?

                do {
                    _ = try await child.finish(within: .seconds(2))
                    Issue.record("one-past \(stream) output unexpectedly succeeded")
                } catch let error as SpiceLiveInteractionSupportError {
                    observed = error
                }

                #expect(observed == .outputLimitExceeded)
                #expect(!String(reflecting: observed).contains(secret))
                let identifier = try Stage3ProcessFixture.processIdentifier(at: pidFile)
                Stage3ProcessFixture.expectNoSurvivors([identifier])
            }
        }
    }

    @Test func timeoutKillsTheWholeGroupAndCannotHangOnInheritedPipes() async throws {
        let fixture = try Stage3ProcessScriptFixture(
            """
            trap '' TERM
            (
                trap '' TERM
                while :; do :; done
            ) &
            descendant=$!
            printf 'READY parent=%s descendant=%s\n' "$$" "$descendant"
            while :; do :; done
            """
        )
        defer { fixture.remove() }
        let child = try SpiceLiveProcessRunner(
            executableURL: fixture.executableURL
        ).launch(arguments: [])
        let identifiers = try Stage3ProcessFixture.processIdentifiers(
            from: await child.readOutputLine(within: .seconds(1))
        )
        let operationTimeout = Duration.milliseconds(20)
        let outerLimit = operationTimeout
            + SpiceLiveChildProcess.terminationGrace
            + SpiceLiveChildProcess.killGrace
            + SpiceLiveChildProcess.pipeDrainGrace
            + .milliseconds(500)
        let watchdog = Stage3ProcessFixture.watchdog(
            identifiers: identifiers,
            after: outerLimit
        )
        let started = ContinuousClock().now

        await #expect(throws: SpiceLiveInteractionSupportError.childTimedOut) {
            _ = try await child.finish(within: operationTimeout)
        }

        let elapsed = started.duration(to: ContinuousClock().now)
        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(elapsed < outerLimit)
        Stage3ProcessFixture.expectNoSurvivors(identifiers)
    }

    @Test func naturalLeaderExitWithInheritedWriterHasABoundedDrainTimeout() async throws {
        let fixture = try Stage3ProcessScriptFixture(
            """
            (
                trap '' TERM
                while :; do :; done
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
        let identifiers = try Stage3ProcessFixture.processIdentifiers(
            from: await child.readOutputLine(within: .seconds(1))
        )
        let outerLimit = SpiceLiveChildProcess.pipeDrainGrace
            + SpiceLiveChildProcess.terminationGrace
            + SpiceLiveChildProcess.killGrace
            + .milliseconds(500)
        let watchdog = Stage3ProcessFixture.watchdog(
            identifiers: identifiers,
            after: outerLimit
        )
        let started = ContinuousClock().now

        await #expect(throws: SpiceLiveInteractionSupportError.childTimedOut) {
            _ = try await child.finish(within: .seconds(2))
        }

        let elapsed = started.duration(to: ContinuousClock().now)
        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(elapsed >= SpiceLiveChildProcess.pipeDrainGrace)
        #expect(elapsed < outerLimit)
        Stage3ProcessFixture.expectNoSurvivors(identifiers)
    }
}

private struct Stage3ProcessScriptFixture {
    let directory: URL
    let executableURL: URL

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-stage3-process-\(UUID().uuidString)",
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

private enum Stage3ProcessFixture {
    static func processIdentifiers(from line: String) throws -> [pid_t] {
        let fields = line.split(separator: " ")
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

    static func processIdentifier(at file: URL) throws -> pid_t {
        let raw = try String(contentsOf: file, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(raw))
    }

    static func watchdog(
        identifiers: [pid_t],
        after delay: Duration
    ) -> Task<Bool, Never> {
        Task.detached {
            do {
                try await Task.sleep(for: delay)
            } catch {
                return false
            }
            var terminated = false
            for identifier in identifiers where Darwin.kill(identifier, 0) == 0 {
                _ = Darwin.kill(identifier, SIGKILL)
                terminated = true
            }
            return terminated
        }
    }

    static func expectNoSurvivors(_ identifiers: [pid_t]) {
        let survivors = identifiers.filter { Darwin.kill($0, 0) == 0 }
        #expect(survivors.isEmpty)
        if !survivors.isEmpty {
            for identifier in survivors {
                _ = Darwin.kill(identifier, SIGKILL)
            }
        }
    }

    static func withTemporaryDirectory<Result: Sendable>(
        _ operation: (URL) async throws -> Result
    ) async throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-stage3-process-output-\(UUID().uuidString)",
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
