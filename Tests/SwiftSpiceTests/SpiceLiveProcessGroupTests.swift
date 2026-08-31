import Darwin
import Foundation
import Testing
@testable import SpiceLiveInteractionSupport

@Suite(.serialized)
struct SpiceLiveProcessGroupTests {
    @Test
    func launchCreatesAnIndependentGroupAndFinishPublishesOneStableWait4Result() async throws {
        let fixture = try ProcessScriptFixture(
            """
            printf '%s\n' "$$" > "$1"
            while [ ! -f "$2" ]; do :; done
            index=0
            while [ "$index" -lt 100000 ]; do index=$((index + 1)); done
            exit 7
            """
        )
        defer { fixture.remove() }
        let process = try SpiceLiveProcessGroup.launch(
            executableURL: fixture.executableURL,
            arguments: [fixture.readyURL.path, fixture.releaseURL.path]
        )
        let watchdog = processGroupWatchdog(
            processIdentifier: process.processIdentifier,
            processGroupIdentifier: process.processGroupIdentifier
        )
        let identifiers = try await fixture.waitForIdentifiers(count: 1)

        #expect(process.processIdentifier == identifiers[0])
        #expect(process.processGroupIdentifier == process.processIdentifier)
        #expect(Darwin.getpgid(process.processIdentifier) == process.processIdentifier)
        try fixture.release()

        async let first = process.finish()
        async let second = process.finish()
        async let third = process.finish()
        let results = try await (first, second, third)
        let repeated = try await process.finish()

        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(results.0 == results.1)
        #expect(results.1 == results.2)
        #expect(results.2 == repeated)
        #expect(repeated.status == 7)
        let _: UInt64 = repeated.resourceUsage.userNanoseconds
        let _: UInt64 = repeated.resourceUsage.systemNanoseconds
        let _: UInt64 = repeated.resourceUsage.peakResidentBytes
        #expect(
            repeated.resourceUsage.userNanoseconds > 0
                || repeated.resourceUsage.systemNanoseconds > 0
        )
        #expect(repeated.resourceUsage.peakResidentBytes > 0)
        #expect(!processGroupExists(process.processGroupIdentifier))
    }

    @Test
    func finishAndCancelRaceSharesOneTerminalResultAndCleansTheGroup() async throws {
        let fixture = try ProcessScriptFixture(
            """
            trap '' TERM
            printf '%s\n' "$$" > "$1"
            while :; do :; done
            """
        )
        defer { fixture.remove() }
        let process = try SpiceLiveProcessGroup.launch(
            executableURL: fixture.executableURL,
            arguments: [fixture.readyURL.path]
        )
        let watchdog = processGroupWatchdog(
            processIdentifier: process.processIdentifier,
            processGroupIdentifier: process.processGroupIdentifier
        )
        _ = try await fixture.waitForIdentifiers(count: 1)

        async let finished = process.finish()
        async let cancelled = process.cancel()
        let terminal = try await (finished, cancelled)
        let repeatedFinish = try await process.finish()
        let repeatedCancel = try await process.cancel()

        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(terminal.0 == terminal.1)
        #expect(terminal.1 == repeatedFinish)
        #expect(repeatedFinish == repeatedCancel)
        #expect(terminal.0.status == 128 + SIGKILL)
        #expect(!processGroupExists(process.processGroupIdentifier))
    }

    @Test
    func responsiveChildReceivesTERMAndExitsWithinTheBound() async throws {
        let fixture = try ProcessScriptFixture(
            """
            trap 'exit 23' TERM
            printf '%s\n' "$$" > "$1"
            while :; do :; done
            """
        )
        defer { fixture.remove() }
        let process = try SpiceLiveProcessGroup.launch(
            executableURL: fixture.executableURL,
            arguments: [fixture.readyURL.path]
        )
        let watchdog = processGroupWatchdog(
            processIdentifier: process.processIdentifier,
            processGroupIdentifier: process.processGroupIdentifier
        )
        _ = try await fixture.waitForIdentifiers(count: 1)
        let started = ContinuousClock().now

        let terminal = try await process.cancel()

        let elapsed = started.duration(to: ContinuousClock().now)
        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(terminal.status == 23)
        #expect(elapsed < .seconds(3))
        #expect(!processGroupExists(process.processGroupIdentifier))
    }

    @Test
    func TERMThenKILLCleansAnIgnoringLeaderAndDescendant() async throws {
        let fixture = try ProcessScriptFixture(
            """
            trap '' TERM
            (
                trap '' TERM
                while :; do :; done
            ) &
            descendant=$!
            printf '%s %s\n' "$$" "$descendant" > "$1"
            while :; do :; done
            """
        )
        defer { fixture.remove() }
        let process = try SpiceLiveProcessGroup.launch(
            executableURL: fixture.executableURL,
            arguments: [fixture.readyURL.path]
        )
        let watchdog = processGroupWatchdog(
            processIdentifier: process.processIdentifier,
            processGroupIdentifier: process.processGroupIdentifier
        )
        let identifiers = try await fixture.waitForIdentifiers(count: 2)

        let terminal = try await process.cancel()

        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(terminal.status == 128 + SIGKILL)
        #expect(identifiers[0] == process.processIdentifier)
        #expect(!processGroupExists(process.processGroupIdentifier))
    }

    @Test
    func naturalLeaderExitStillCleansItsIgnoringDescendant() async throws {
        let fixture = try ProcessScriptFixture(
            """
            (
                trap '' TERM
                while :; do :; done
            ) &
            descendant=$!
            printf '%s %s\n' "$$" "$descendant" > "$1"
            exit 0
            """
        )
        defer { fixture.remove() }
        let process = try SpiceLiveProcessGroup.launch(
            executableURL: fixture.executableURL,
            arguments: [fixture.readyURL.path]
        )
        let watchdog = processGroupWatchdog(
            processIdentifier: process.processIdentifier,
            processGroupIdentifier: process.processGroupIdentifier
        )
        _ = try await fixture.waitForIdentifiers(count: 2)

        let terminal = try await process.finish()

        watchdog.cancel()
        #expect(!(await watchdog.value))
        #expect(terminal.status == 0)
        #expect(!processGroupExists(process.processGroupIdentifier))
    }

    @Test
    func externallyReapedChildFailsWithoutFabricatingResourceUsage() async throws {
        let fixture = try ProcessScriptFixture("exit 9")
        defer { fixture.remove() }
        let process = try SpiceLiveProcessGroup.launch(
            executableURL: fixture.executableURL,
            arguments: []
        )
        var rawStatus: Int32 = 0

        let reaped = Darwin.waitpid(process.processIdentifier, &rawStatus, 0)

        #expect(reaped == process.processIdentifier)
        do {
            _ = try await process.finish()
            Issue.record("externally reaped child unexpectedly produced a terminal result")
        } catch let error as SpiceLiveProcessGroup.ProcessError {
            #expect(error == .reapFailed(ECHILD))
        } catch {
            Issue.record("unexpected error type: \(error)")
        }
    }
}

private struct ProcessScriptFixture {
    enum FixtureError: Error {
        case setupFailed
        case readinessTimedOut
        case malformedReadiness
    }

    let directory: URL
    let executableURL: URL
    let readyURL: URL
    let releaseURL: URL

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-process-group-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        executableURL = directory.appending(path: "fixture.sh")
        readyURL = directory.appending(path: "ready")
        releaseURL = directory.appending(path: "release")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try Data("#!/bin/sh\nset -eu\n\(body)\n".utf8).write(
                to: executableURL,
                options: .atomic
            )
            guard chmod(executableURL.path, S_IRUSR | S_IWUSR | S_IXUSR) == 0 else {
                throw FixtureError.setupFailed
            }
        } catch {
            remove()
            throw error
        }
    }

    func waitForIdentifiers(count: Int) async throws -> [pid_t] {
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while ContinuousClock().now < deadline {
            try Task.checkCancellation()
            if let data = try? Data(contentsOf: readyURL), !data.isEmpty {
                let fields = String(decoding: data, as: UTF8.self)
                    .split(whereSeparator: \Character.isWhitespace)
                guard fields.count == count else {
                    throw FixtureError.malformedReadiness
                }
                let identifiers = fields.compactMap { pid_t($0) }
                guard identifiers.count == count,
                      identifiers.allSatisfy({ $0 > 1 }) else {
                    throw FixtureError.malformedReadiness
                }
                return identifiers
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw FixtureError.readinessTimedOut
    }

    func release() throws {
        try Data().write(to: releaseURL, options: .atomic)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func processGroupExists(_ processGroup: pid_t) -> Bool {
    if Darwin.kill(-processGroup, 0) == 0 { return true }
    return errno == EPERM
}

private func processGroupWatchdog(
    processIdentifier: pid_t,
    processGroupIdentifier: pid_t
) -> Task<Bool, Never> {
    Task.detached {
        do {
            try await Task.sleep(for: .seconds(4))
        } catch {
            return false
        }
        guard processIdentifier > 1 else { return false }
        if processGroupIdentifier == processIdentifier,
           Darwin.getpgid(processIdentifier) == processIdentifier {
            return Darwin.kill(-processGroupIdentifier, SIGKILL) == 0
        }
        return Darwin.kill(processIdentifier, SIGKILL) == 0
    }
}
