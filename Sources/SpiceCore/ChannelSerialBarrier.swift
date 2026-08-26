import Foundation

package actor ChannelSerialBarrier {
    package enum WaitError: Error, Sendable, Equatable {
        case channelTerminated(ChannelKey)
    }

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
    private var terminatedKeys: Set<ChannelKey> = []
    private var waiters: [UUID: Waiter] = [:]

    package init() {}

    package func record(key: ChannelKey, serial: UInt64) {
        guard !terminatedKeys.contains(key) else { return }
        latestSerials[key] = max(latestSerials[key] ?? 0, serial)
        let ready = waiters.compactMap { id, waiter in
            isSatisfied(waiter.requirements) ? id : nil
        }
        for id in ready {
            waiters.removeValue(forKey: id)?.continuation.resume()
        }
    }

    package func terminate(key: ChannelKey) {
        guard terminatedKeys.insert(key).inserted else { return }
        let failed = waiters.compactMap { id, waiter in
            firstUnsatisfiedTerminatedKey(in: waiter.requirements) == key ? id : nil
        }
        for id in failed {
            waiters.removeValue(forKey: id)?.continuation.resume(
                throwing: WaitError.channelTerminated(key)
            )
        }
    }

    package func wait(for requirements: [Requirement]) async throws {
        guard !isSatisfied(requirements) else { return }
        if let key = firstUnsatisfiedTerminatedKey(in: requirements) {
            throw WaitError.channelTerminated(key)
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if isSatisfied(requirements) {
                    continuation.resume()
                } else if let key = firstUnsatisfiedTerminatedKey(in: requirements) {
                    continuation.resume(throwing: WaitError.channelTerminated(key))
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

    private func firstUnsatisfiedTerminatedKey(
        in requirements: [Requirement]
    ) -> ChannelKey? {
        requirements.first { requirement in
            terminatedKeys.contains(requirement.key)
                && (latestSerials[requirement.key] ?? 0) < requirement.serial
        }?.key
    }
}
