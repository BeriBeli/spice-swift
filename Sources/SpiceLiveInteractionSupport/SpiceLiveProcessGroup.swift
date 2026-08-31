import Darwin
import Dispatch
import Foundation
import Synchronization

package final class SpiceLiveProcessGroup: Sendable {
    package enum ProcessError: Error, Sendable, Equatable {
        case invalidArgument
        case spawnFailed(Int32)
        case teardownFailed(Int32)
        case reapFailed(Int32)
        case invalidResourceUsage
    }

    package struct ResourceUsage: Sendable, Equatable {
        package let userNanoseconds: UInt64
        package let systemNanoseconds: UInt64
        package let peakResidentBytes: UInt64
    }

    package struct TerminalResult: Sendable, Equatable {
        package let status: Int32
        package let resourceUsage: ResourceUsage
    }

    private struct Storage: Sendable {
        var cancellationRequested = false
        var workerStarted = false
        var terminal: Result<TerminalResult, ProcessError>?
        var waiters: [CheckedContinuation<Result<TerminalResult, ProcessError>, Never>] = []
    }

    private static let terminationGrace = Duration.milliseconds(500)
    private static let killGrace = Duration.milliseconds(500)

    package let processIdentifier: pid_t
    package let processGroupIdentifier: pid_t

    private let storage = Mutex(Storage())
    private let lifecycleQueue = DispatchQueue(
        label: "SwiftSpice.LiveProcessGroup",
        qos: .userInitiated
    )

    private init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
        processGroupIdentifier = processIdentifier
    }

    package static func launch(
        executableURL: URL,
        arguments: [String]
    ) throws -> SpiceLiveProcessGroup {
        let executablePath = executableURL.path
        let allArguments = [executablePath] + arguments
        guard !allArguments.contains(where: { $0.utf8.contains(0) }) else {
            throw ProcessError.invalidArgument
        }

        var attributes: posix_spawnattr_t? = nil
        let initialization = posix_spawnattr_init(&attributes)
        guard initialization == 0 else {
            throw ProcessError.spawnFailed(initialization)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        var signalMask = sigset_t()
        guard sigemptyset(&signalMask) == 0 else {
            throw ProcessError.spawnFailed(errno)
        }
        let mask = posix_spawnattr_setsigmask(&attributes, &signalMask)
        guard mask == 0 else {
            throw ProcessError.spawnFailed(mask)
        }
        let flags = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK)
        )
        guard flags == 0 else {
            throw ProcessError.spawnFailed(flags)
        }
        let group = posix_spawnattr_setpgroup(&attributes, 0)
        guard group == 0 else {
            throw ProcessError.spawnFailed(group)
        }

        let duplicatedArguments = allArguments.map { argument in
            argument.withCString { strdup($0) }
        }
        guard duplicatedArguments.allSatisfy({ $0 != nil }) else {
            for argument in duplicatedArguments { free(argument) }
            throw ProcessError.spawnFailed(ENOMEM)
        }
        defer {
            for argument in duplicatedArguments { free(argument) }
        }

        var mutableArguments = duplicatedArguments + [nil]
        var processIdentifier: pid_t = 0
        let spawnResult = mutableArguments.withUnsafeMutableBufferPointer { arguments in
            posix_spawn(
                &processIdentifier,
                executablePath,
                nil,
                &attributes,
                arguments.baseAddress,
                environ
            )
        }
        guard spawnResult == 0, processIdentifier > 1 else {
            throw ProcessError.spawnFailed(spawnResult == 0 ? EINVAL : spawnResult)
        }
        return SpiceLiveProcessGroup(processIdentifier: processIdentifier)
    }

    package func finish() async throws -> TerminalResult {
        try await terminalResult(requestCancellation: false)
    }

    package func cancel() async throws -> TerminalResult {
        try await terminalResult(requestCancellation: true)
    }

    private func terminalResult(
        requestCancellation: Bool
    ) async throws -> TerminalResult {
        let result = await withCheckedContinuation { continuation in
            var immediate: Result<TerminalResult, ProcessError>?
            let shouldStart = storage.withLock { storage -> Bool in
                if let terminal = storage.terminal {
                    immediate = terminal
                    return false
                }
                if requestCancellation {
                    storage.cancellationRequested = true
                }
                storage.waiters.append(continuation)
                guard !storage.workerStarted else { return false }
                storage.workerStarted = true
                return true
            }
            if let immediate {
                continuation.resume(returning: immediate)
            } else if shouldStart {
                lifecycleQueue.async { [self] in
                    publish(runLifecycleResult())
                }
            }
        }
        return try result.get()
    }

    private func runLifecycleResult() -> Result<TerminalResult, ProcessError> {
        do {
            return .success(try runLifecycle())
        } catch {
            return .failure(error)
        }
    }

    private func publish(_ result: Result<TerminalResult, ProcessError>) {
        let waiters = storage.withLock { storage in
            storage.terminal = result
            defer { storage.waiters.removeAll(keepingCapacity: false) }
            return storage.waiters
        }
        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }

    private func runLifecycle() throws(ProcessError) -> TerminalResult {
        var terminationDeadline: ContinuousClock.Instant?
        var killDeadline: ContinuousClock.Instant?
        var deferredFailure: ProcessError?

        while true {
            // A successful non-reaping wait validates that this owner still
            // anchors the PID/PGID. ECHILD fails before any group signal.
            let leaderExited = try observeLeaderExit()
            let cancellationRequested = storage.withLock(\.cancellationRequested)
            if cancellationRequested, terminationDeadline == nil {
                deferredFailure = signalGroup(SIGTERM) ?? deferredFailure
                terminationDeadline = ContinuousClock().now.advanced(
                    by: Self.terminationGrace
                )
            }

            var hasResidualMembers = false
            if leaderExited {
                switch groupHasResidualMembers() {
                case let .success(hasResidual):
                    hasResidualMembers = hasResidual
                case let .failure(error):
                    deferredFailure = deferredFailure ?? error
                    hasResidualMembers = true
                }
            }

            if leaderExited, !hasResidualMembers {
                let result = try reap()
                if let deferredFailure { throw deferredFailure }
                return result
            }

            if leaderExited, hasResidualMembers, terminationDeadline == nil {
                deferredFailure = signalGroup(SIGTERM) ?? deferredFailure
                terminationDeadline = ContinuousClock().now.advanced(
                    by: Self.terminationGrace
                )
            }

            if let terminationDeadline,
               killDeadline == nil,
               ContinuousClock().now >= terminationDeadline {
                deferredFailure = signalGroup(SIGKILL) ?? deferredFailure
                killDeadline = ContinuousClock().now.advanced(by: Self.killGrace)
            }

            if let killDeadline,
               ContinuousClock().now >= killDeadline {
                let failure = deferredFailure ?? .teardownFailed(ETIMEDOUT)
                deferredFailure = failure
                // Never publish a teardown failure while this direct child is
                // still reappable. Continue until WNOWAIT observes its exit;
                // then wait4 below owns the one final reap before failure.
                if leaderExited {
                    _ = try reap()
                    throw failure
                }
            }
            usleep(10_000)
        }
    }

    private func observeLeaderExit() throws(ProcessError) -> Bool {
        while true {
            var information = siginfo_t()
            if waitid(
                P_PID,
                id_t(processIdentifier),
                &information,
                WEXITED | WNOHANG | WNOWAIT
            ) == 0 {
                return information.si_pid == processIdentifier
            }
            if errno == EINTR { continue }
            throw ProcessError.reapFailed(errno)
        }
    }

    private func groupHasResidualMembers() -> Result<Bool, ProcessError> {
        var identifiers = [pid_t](repeating: 0, count: 16)
        let count = proc_listpgrppids(
            processGroupIdentifier,
            &identifiers,
            Int32(identifiers.count * MemoryLayout<pid_t>.stride)
        )
        guard count >= 0 else {
            return .failure(.teardownFailed(errno))
        }
        return .success(identifiers.prefix(Int(count)).contains {
            $0 > 0 && $0 != processIdentifier
        })
    }

    private func signalGroup(_ signal: Int32) -> ProcessError? {
        guard Darwin.kill(-processGroupIdentifier, signal) != 0 else { return nil }
        guard errno != ESRCH else { return nil }
        return .teardownFailed(errno)
    }

    private func reap() throws(ProcessError) -> TerminalResult {
        var rawStatus: Int32 = 0
        var rawUsage = rusage()
        while true {
            let result = wait4(processIdentifier, &rawStatus, 0, &rawUsage)
            if result == processIdentifier { break }
            if result < 0, errno == EINTR { continue }
            throw ProcessError.reapFailed(result < 0 ? errno : ECHILD)
        }

        guard let userNanoseconds = Self.nanoseconds(rawUsage.ru_utime),
              let systemNanoseconds = Self.nanoseconds(rawUsage.ru_stime),
              let peakResidentBytes = UInt64(exactly: rawUsage.ru_maxrss)
        else {
            throw ProcessError.invalidResourceUsage
        }
        let signal = rawStatus & 0x7f
        let status = signal == 0
            ? (rawStatus >> 8) & 0xff
            : 128 + signal
        return TerminalResult(
            status: status,
            resourceUsage: ResourceUsage(
                userNanoseconds: userNanoseconds,
                systemNanoseconds: systemNanoseconds,
                peakResidentBytes: peakResidentBytes
            )
        )
    }

    private static func nanoseconds(_ time: timeval) -> UInt64? {
        guard let seconds = UInt64(exactly: time.tv_sec),
              let microseconds = UInt64(exactly: time.tv_usec),
              microseconds < 1_000_000
        else {
            return nil
        }
        let secondsResult = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        let microsecondsResult = microseconds.multipliedReportingOverflow(by: 1_000)
        guard !secondsResult.overflow, !microsecondsResult.overflow else {
            return nil
        }
        let secondNanoseconds = secondsResult.partialValue
        let microsecondNanoseconds = microsecondsResult.partialValue
        let total = secondNanoseconds.addingReportingOverflow(microsecondNanoseconds)
        return total.overflow ? nil : total.partialValue
    }
}
