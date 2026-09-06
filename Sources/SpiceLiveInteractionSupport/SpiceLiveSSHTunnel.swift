import Darwin
import Foundation

extension SpiceRemoteLiveConfiguration {
    /// Owns one foreground SSH tunnel for the operation's lifetime. The local
    /// callback runs only after SSH has established its requested forwarding.
    package func withSSHTunnel<Value: Sendable>(
        runner: SpiceLiveProcessRunner = .ssh,
        startupTimeout: Duration = .seconds(20),
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        guard endpointHost == "127.0.0.1", startupTimeout > .zero else {
            throw SpiceLiveInteractionSupportError.invalidIsolatedConfiguration
        }
        try Task.checkCancellation()
        let clock = ContinuousClock()
        let startupDeadline = clock.now.advanced(by: startupTimeout)
        // Inspect the same host/options before adding our one local forward.
        // ClearAllForwardings=yes would also remove the requested command-line -L.
        let inspection = try runner.launch(arguments: ["-G"] + sshTunnelOptions + [sshHost])
        let configuration = try await inspection.finish(within: startupTimeout)
        guard configuration.status == 0,
              !configuration.outputLines.contains(where: { line in
                  let key = line.split(whereSeparator: \.isWhitespace).first
                  return key == "localforward" || key == "remoteforward" || key == "dynamicforward"
              }) else {
            throw SpiceLiveInteractionSupportError.invalidIsolatedConfiguration
        }
        try Task.checkCancellation()
        guard clock.now < startupDeadline else {
            throw SpiceLiveInteractionSupportError.operationTimedOut
        }
        let (process, transport) = try launchSSHTunnel(runner: runner)
        let readyFrame = Data("SWIFTSPICE_TUNNEL_READY\n".utf8)

        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Result<Value, any Error>.self) { group in
                group.addTask {
                    _ = try await process.finish()
                    return .failure(SpiceLiveInteractionSupportError.childFailed)
                }
                group.addTask {
                    let remainingStartupTime = clock.now.duration(to: startupDeadline)
                    guard remainingStartupTime > .zero else {
                        throw SpiceLiveInteractionSupportError.operationTimedOut
                    }
                    let frame = try await withSpiceLiveTimeout(remainingStartupTime) {
                        try await withTaskCancellationHandler {
                            try await transport.receiveFrame(maximumBytes: readyFrame.count)
                        } onCancel: {
                            // Task cancellation alone cannot interrupt socket I/O.
                            // The scope below also joins this idempotent close.
                            Task { await transport.close() }
                        }
                    }
                    guard frame == readyFrame else {
                        throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                    }
                    try Task.checkCancellation()
                    return .success(try await operation())
                }

                let outcome: Result<Value, any Error>
                do {
                    outcome = try await group.next()
                        ?? .failure(SpiceLiveInteractionSupportError.childFailed)
                } catch {
                    outcome = .failure(error)
                }
                group.cancelAll()
                await transport.close()
                // Joining the same process owner preserves its one terminal
                // result and one reap even when cancellation races SSH exit.
                _ = try await process.cancel()
                return try outcome.get()
            }
        } onCancel: {
            Task {
                await transport.close()
                _ = try? await process.cancel()
            }
        }
    }

    private var sshTunnelOptions: [String] {
        [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ClearAllForwardings=no",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-o", "ForkAfterAuthentication=no",
            "-o", "PermitLocalCommand=yes",
            "-o", "LocalCommand=/usr/bin/printf 'SWIFTSPICE_TUNNEL_READY\\n'",
        ]
    }

    private func launchSSHTunnel(
        runner: SpiceLiveProcessRunner
    ) throws -> (SpiceLiveProcessGroup, SpiceLiveStageTransport) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
        guard fcntl(descriptors[0], F_SETFD, FD_CLOEXEC) == 0,
              fcntl(descriptors[1], F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw SpiceLiveInteractionSupportError.childFailed
        }
        defer { Darwin.close(descriptors[1]) }
        let socket = try SpiceLiveStageSocketTransport(takingDescriptor: descriptors[0])
        let nullDescriptor = Darwin.open("/dev/null", O_RDWR | O_CLOEXEC)
        guard nullDescriptor >= 0 else {
            throw SpiceLiveInteractionSupportError.childFailed
        }
        defer { Darwin.close(nullDescriptor) }

        let process = try SpiceLiveProcessGroup.launch(
            executableURL: runner.executableURL,
            arguments: runner.argumentPrefix + sshTunnelOptions + [
                "-L", "127.0.0.1:\(endpointPort):127.0.0.1:\(spicePort)",
                sshHost,
            ],
            standardInput: nullDescriptor,
            standardOutput: descriptors[1],
            standardError: nullDescriptor
        )
        return (process, socket.stageTransport)
    }
}
