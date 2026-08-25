import Synchronization

/// FIFO handoff for low-frequency session control events. Frame, surface,
/// cursor and pointer-mode state use `SpiceDesktopSource` instead.
package final class SpiceSessionEventMailbox: Sendable {
    private struct State: Sendable {
        var pending: [SpiceSessionEvent] = []
        var waiters: [UInt64: CheckedContinuation<SpiceSessionEvent?, Never>] = [:]
        var waiterOrder: [UInt64] = []
        var cancelledWaiters: Set<UInt64> = []
        var nextWaiterToken: UInt64 = 0
        var finished = false
    }

    private enum Delivery {
        case none
        case event(CheckedContinuation<SpiceSessionEvent?, Never>, SpiceSessionEvent)
        case finished(CheckedContinuation<SpiceSessionEvent?, Never>)

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

    private let state = Mutex(State())

    package init() {}

    package func send(_ event: SpiceSessionEvent) {
        let delivery = state.withLock { state -> Delivery in
            guard !state.finished else { return .none }
            if let continuation = Self.removeFirstWaiter(from: &state) {
                return .event(continuation, event)
            }
            state.pending.append(event)
            return .none
        }
        delivery.resume()
    }

    package func next() async -> SpiceSessionEvent? {
        let waiterToken = state.withLock { state in
            let token = state.nextWaiterToken
            state.nextWaiterToken &+= 1
            return token
        }
        return await withTaskCancellationHandler {
            if Task.isCancelled { return nil }
            return await withCheckedContinuation { continuation in
                let delivery = state.withLock { state -> Delivery in
                    if !state.pending.isEmpty {
                        return .event(continuation, state.pending.removeFirst())
                    }
                    if state.finished
                        || state.cancelledWaiters.remove(waiterToken) != nil
                        || Task.isCancelled
                    {
                        return .finished(continuation)
                    }
                    state.waiters[waiterToken] = continuation
                    state.waiterOrder.append(waiterToken)
                    return .none
                }
                delivery.resume()
            }
        } onCancel: { [weak self] in
            self?.cancel(waiterToken: waiterToken)
        }
    }

    package func finish() {
        let continuations = state.withLock { state in
            guard !state.finished else {
                return [CheckedContinuation<SpiceSessionEvent?, Never>]()
            }
            state.finished = true
            state.pending.removeAll(keepingCapacity: false)
            let continuations = state.waiterOrder.compactMap { state.waiters[$0] }
            state.waiters.removeAll(keepingCapacity: false)
            state.waiterOrder.removeAll(keepingCapacity: false)
            state.cancelledWaiters.removeAll(keepingCapacity: false)
            return continuations
        }
        for continuation in continuations {
            continuation.resume(returning: nil)
        }
    }

    private func cancel(waiterToken: UInt64) {
        let continuation = state.withLock { state -> CheckedContinuation<
            SpiceSessionEvent?, Never
        >? in
            if let continuation = state.waiters.removeValue(forKey: waiterToken) {
                state.waiterOrder.removeAll { $0 == waiterToken }
                return continuation
            }
            if !state.finished {
                state.cancelledWaiters.insert(waiterToken)
            }
            return nil
        }
        continuation?.resume(returning: nil)
    }

    private static func removeFirstWaiter(
        from state: inout State
    ) -> CheckedContinuation<SpiceSessionEvent?, Never>? {
        while let token = state.waiterOrder.first {
            state.waiterOrder.removeFirst()
            if let continuation = state.waiters.removeValue(forKey: token) {
                return continuation
            }
        }
        return nil
    }
}
