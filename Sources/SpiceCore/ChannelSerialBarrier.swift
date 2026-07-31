import Foundation

package actor ChannelSerialBarrier {
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

    private var latestSerials: [ChannelKey: UInt64] = [:]
    private var waiters: [UUID: Waiter] = [:]

    package init() {}

    package func record(key: ChannelKey, serial: UInt64) {
        latestSerials[key] = max(latestSerials[key] ?? 0, serial)
        let ready = waiters.compactMap { id, waiter in
            isSatisfied(waiter.requirements) ? id : nil
        }
        for id in ready {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    package func wait(for requirements: [Requirement]) async throws {
        guard !isSatisfied(requirements) else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isSatisfied(requirements) {
                    continuation.resume()
                } else {
                    waiters[id] = Waiter(
                        requirements: requirements,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func cancel(id: UUID) {
        waiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    private func isSatisfied(_ requirements: [Requirement]) -> Bool {
        requirements.allSatisfy { requirement in
            (latestSerials[requirement.key] ?? 0) >= requirement.serial
        }
    }
}
