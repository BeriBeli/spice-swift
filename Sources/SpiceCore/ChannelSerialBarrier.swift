import Foundation
import Synchronization

package final class ChannelSerialBarrier: Sendable {
    package struct Requirement: Sendable, Equatable {
        package let key: ChannelKey
        package let serial: UInt64

        package init(key: ChannelKey, serial: UInt64) {
            self.key = key
            self.serial = serial
        }
    }

    private struct Waiter {
        let requirements: [Requirement]
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var latestSerials: [ChannelKey: UInt64] = [:]
        var waiters: [UUID: Waiter] = [:]
    }

    /// Carries cancellation across the window before a continuation is
    /// registered. Its lifetime is exactly one wait, so no global tombstone is
    /// needed after a record-versus-cancel race resolves.
    private final class CancellationState: Sendable {
        private let isCancelled = Mutex(false)

        func markCancelled() {
            isCancelled.withLock { $0 = true }
        }

        var value: Bool {
            isCancelled.withLock { $0 }
        }
    }

    private enum Resolution {
        case none
        case success(CheckedContinuation<Void, any Error>)
        case cancelled(CheckedContinuation<Void, any Error>)

        func resume() {
            switch self {
            case .none:
                break
            case let .success(continuation):
                continuation.resume()
            case let .cancelled(continuation):
                continuation.resume(throwing: CancellationError())
            }
        }
    }

    private let state = Mutex(State())

    package init() {}

    package func record(key: ChannelKey, serial: UInt64) {
        let continuations = state.withLock {
            state -> [CheckedContinuation<Void, any Error>] in
            state.latestSerials[key] = max(state.latestSerials[key] ?? 0, serial)
            let ready = state.waiters.compactMap { id, waiter in
                Self.isSatisfied(
                    waiter.requirements,
                    latestSerials: state.latestSerials
                )
                    ? id
                    : nil
            }
            return ready.compactMap { id in
                guard let waiter = state.waiters.removeValue(forKey: id) else {
                    return nil
                }
                return waiter.continuation
            }
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    package func wait(for requirements: [Requirement]) async throws {
        let id = UUID()
        let cancellation = CancellationState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let resolution = state.withLock { state -> Resolution in
                    if cancellation.value || Task.isCancelled {
                        return .cancelled(continuation)
                    }
                    if Self.isSatisfied(
                        requirements,
                        latestSerials: state.latestSerials
                    ) {
                        return .success(continuation)
                    }
                    state.waiters[id] = Waiter(
                        requirements: requirements,
                        continuation: continuation
                    )
                    return .none
                }
                resolution.resume()
            }
        } onCancel: {
            cancellation.markCancelled()
            self.cancel(id: id)
        }
    }

    private func cancel(id: UUID) {
        let resolution = state.withLock { state -> Resolution in
            if let waiter = state.waiters.removeValue(forKey: id) {
                return .cancelled(waiter.continuation)
            }
            return .none
        }
        resolution.resume()
    }

    private static func isSatisfied(
        _ requirements: [Requirement],
        latestSerials: [ChannelKey: UInt64]
    ) -> Bool {
        requirements.allSatisfy { requirement in
            (latestSerials[requirement.key] ?? 0) >= requirement.serial
        }
    }
}
