import Synchronization

package struct SpiceAgentEventEnvelope: Sendable, Equatable {
    package let event: SpiceAgentEvent
    package let disconnectRevision: UInt64?
    package let connectionGeneration: UInt64

    package init(
        event: SpiceAgentEvent,
        disconnectRevision: UInt64? = nil,
        connectionGeneration: UInt64 = 0
    ) {
        self.event = event
        self.disconnectRevision = disconnectRevision
        self.connectionGeneration = connectionGeneration
    }
}

/// Single-consumer Agent mailbox whose lifecycle boundaries outrank payloads.
/// A disconnect atomically discards queued messages from the old connection;
/// the following connect is retained behind that boundary.
package final class SpiceAgentEventMailbox: Sendable {
    package enum SendResult: Sendable, Equatable {
        case enqueued
        case full
        case terminated
    }

    private struct State: Sendable {
        var pending: [SpiceAgentEventEnvelope] = []
        var waiters: [UInt64: CheckedContinuation<SpiceAgentEventEnvelope?, Never>] = [:]
        var waiterOrder: [UInt64] = []
        var nextWaiterToken: UInt64 = 0
        var consumerDetached = false
        var finished = false
    }

    private enum Delivery {
        case none
        case event(
            CheckedContinuation<SpiceAgentEventEnvelope?, Never>,
            SpiceAgentEventEnvelope
        )
        case finished(CheckedContinuation<SpiceAgentEventEnvelope?, Never>)

        func resume() {
            switch self {
            case .none:
                break
            case let .event(continuation, event):
                continuation.resume(returning: event)
            case let .finished(continuation):
                continuation.resume(returning: nil)
            }
        }
    }

    private let capacity: Int
    private let state = Mutex(State())

    package init(capacity: Int = 64) {
        precondition(capacity >= 2)
        self.capacity = capacity
    }

    package func send(
        _ event: SpiceAgentEvent,
        connectionGeneration: UInt64 = 0
    ) -> SendResult {
        let envelope = SpiceAgentEventEnvelope(
            event: event,
            connectionGeneration: connectionGeneration
        )
        let result = state.withLock { state -> (SendResult, Delivery) in
            guard !state.finished else { return (.terminated, .none) }
            if let continuation = Self.removeFirstWaiter(from: &state) {
                state.consumerDetached = false
                return (.enqueued, .event(continuation, envelope))
            }
            guard state.pending.count < capacity else {
                return (state.consumerDetached ? .terminated : .full, .none)
            }
            state.pending.append(envelope)
            return (.enqueued, .none)
        }
        result.1.resume()
        return result.0
    }

    package func sendLifecycle(
        _ event: SpiceAgentEvent,
        disconnectRevision: UInt64? = nil,
        connectionGeneration: UInt64 = 0
    ) {
        let envelope = SpiceAgentEventEnvelope(
            event: event,
            disconnectRevision: disconnectRevision,
            connectionGeneration: connectionGeneration
        )
        let delivery = state.withLock { state -> Delivery in
            guard !state.finished else { return .none }
            if let continuation = Self.removeFirstWaiter(from: &state) {
                return .event(continuation, envelope)
            }
            switch event {
            case .disconnected:
                state.pending.removeAll(keepingCapacity: true)
            case .connected:
                if let boundary = state.pending.lastIndex(where: {
                    if case .disconnected = $0.event { return true }
                    return false
                }) {
                    state.pending = Array(state.pending[boundary...])
                } else {
                    state.pending.removeAll(keepingCapacity: true)
                }
            case .message:
                preconditionFailure("payload events must use send(_:)")
            }
            state.pending.append(envelope)
            return .none
        }
        delivery.resume()
    }

    package func next() async -> SpiceAgentEventEnvelope? {
        let waiterToken = state.withLock { state in
            let token = state.nextWaiterToken
            state.nextWaiterToken &+= 1
            return token
        }
        return await withTaskCancellationHandler {
            if Task.isCancelled {
                detachConsumer(waiterToken: waiterToken)
                return nil
            }
            return await withCheckedContinuation { continuation in
                let delivery = state.withLock { state -> Delivery in
                    // Cancellation can run before this continuation is
                    // registered. Check it while holding the same lock used by
                    // detachConsumer, before reactivating or dequeuing payload.
                    guard !state.finished, !Task.isCancelled else {
                        state.consumerDetached = state.waiters.isEmpty
                        return .finished(continuation)
                    }
                    state.consumerDetached = false
                    if !state.pending.isEmpty {
                        return .event(continuation, state.pending.removeFirst())
                    }
                    state.waiters[waiterToken] = continuation
                    state.waiterOrder.append(waiterToken)
                    return .none
                }
                delivery.resume()
            }
        } onCancel: { [weak self] in
            self?.detachConsumer(waiterToken: waiterToken)
        }
    }

    private func detachConsumer(waiterToken: UInt64) {
        let continuation = state.withLock { state in
            let continuation = state.waiters.removeValue(forKey: waiterToken)
            state.waiterOrder.removeAll { $0 == waiterToken }
            if state.waiters.isEmpty {
                // A cancelled iterator is detached, not a permanent stream
                // termination. Keep the bounded backlog for a future iterator,
                // but report overflow as terminated so an absent consumer can
                // never fail the session.
                state.consumerDetached = true
            }
            return continuation
        }
        continuation?.resume(returning: nil)
    }

    package func finish() {
        let continuations = state.withLock { state in
            guard !state.finished else {
                return [CheckedContinuation<SpiceAgentEventEnvelope?, Never>]()
            }
            state.finished = true
            state.pending.removeAll(keepingCapacity: false)
            let continuations = state.waiterOrder.compactMap { state.waiters[$0] }
            state.waiters.removeAll(keepingCapacity: false)
            state.waiterOrder.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: nil)
        }
    }

    private static func removeFirstWaiter(
        from state: inout State
    ) -> CheckedContinuation<SpiceAgentEventEnvelope?, Never>? {
        while let token = state.waiterOrder.first {
            state.waiterOrder.removeFirst()
            if let continuation = state.waiters.removeValue(forKey: token) {
                return continuation
            }
        }
        return nil
    }
}
