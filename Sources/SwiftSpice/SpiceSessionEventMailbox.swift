import Synchronization

/// A bounded, frame-coalescing handoff for the public session event stream.
///
/// Frame traffic is lossy by design: only the newest pending frame for a
/// surface within one control-event segment is retained, and at most
/// `maximumPendingFrames` frame entries are queued. Control events are never
/// evicted by frame pressure. A control event also closes the current
/// coalescing segment so a later frame cannot move ahead of that control state.
package final class SpiceSessionEventMailbox: Sendable {
    private struct FrameIdentity: Sendable, Hashable {
        let displayChannelID: UInt8?
        let surfaceID: UInt32
    }

    private enum Pending: Sendable {
        case control(SpiceSessionEvent)
        case frame(UInt64)
    }

    private struct PendingFrame: Sendable {
        let identity: FrameIdentity
        var event: SpiceSessionEvent
    }

    private struct State: Sendable {
        var pending: [Pending] = []
        var frames: [UInt64: PendingFrame] = [:]
        var latestFrameTokenByIdentity: [FrameIdentity: UInt64] = [:]
        var waiters: [UInt64: CheckedContinuation<SpiceSessionEvent?, Never>] = [:]
        var waiterOrder: [UInt64] = []
        var cancelledWaiters: Set<UInt64> = []
        var nextFrameToken: UInt64 = 0
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

    private let maximumPendingFrames: Int
    private let state = Mutex(State())

    package init(maximumPendingFrames: Int = 64) {
        precondition(maximumPendingFrames > 0)
        self.maximumPendingFrames = maximumPendingFrames
    }

    package func send(_ event: SpiceSessionEvent, displayChannelID: UInt8? = nil) {
        let delivery = state.withLock { state -> Delivery in
            guard !state.finished else { return .none }
            if let continuation = Self.removeFirstWaiter(from: &state) {
                return .event(continuation, event)
            }

            switch event {
            case let .frame(frame):
                enqueueFrame(
                    event,
                    identity: FrameIdentity(
                        displayChannelID: displayChannelID,
                        surfaceID: frame.surfaceID
                    ),
                    state: &state
                )
            case let .surfaceDestroyed(surfaceID):
                removePendingFrames(
                    identity: FrameIdentity(
                        displayChannelID: displayChannelID,
                        surfaceID: surfaceID
                    ),
                    state: &state
                )
                state.latestFrameTokenByIdentity.removeAll(keepingCapacity: true)
                state.pending.append(.control(event))
            default:
                state.latestFrameTokenByIdentity.removeAll(keepingCapacity: true)
                state.pending.append(.control(event))
            }
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
            if Task.isCancelled {
                return nil
            }
            return await withCheckedContinuation { continuation in
                let delivery = state.withLock { state -> Delivery in
                    if let event = Self.removeFirstEvent(from: &state) {
                        return .event(continuation, event)
                    }
                    if state.finished || state.cancelledWaiters.remove(waiterToken) != nil
                        || Task.isCancelled {
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
            state.frames.removeAll(keepingCapacity: false)
            state.latestFrameTokenByIdentity.removeAll(keepingCapacity: false)
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

    private func enqueueFrame(
        _ event: SpiceSessionEvent,
        identity: FrameIdentity,
        state: inout State
    ) {
        if let token = state.latestFrameTokenByIdentity[identity],
           state.frames[token] != nil {
            state.frames[token]?.event = event
            return
        }

        while state.frames.count >= maximumPendingFrames {
            guard let index = state.pending.firstIndex(where: {
                if case .frame = $0 { true } else { false }
            }) else {
                break
            }
            guard case let .frame(token) = state.pending.remove(at: index),
                  let removed = state.frames.removeValue(forKey: token) else {
                continue
            }
            if state.latestFrameTokenByIdentity[removed.identity] == token {
                state.latestFrameTokenByIdentity.removeValue(forKey: removed.identity)
            }
        }

        let token = state.nextFrameToken
        state.nextFrameToken &+= 1
        state.frames[token] = PendingFrame(identity: identity, event: event)
        state.latestFrameTokenByIdentity[identity] = token
        state.pending.append(.frame(token))
    }

    private func removePendingFrames(identity: FrameIdentity, state: inout State) {
        let tokens = Set(state.frames.compactMap { token, frame in
            let matchesChannel = identity.displayChannelID == nil
                || frame.identity.displayChannelID == identity.displayChannelID
            return matchesChannel && frame.identity.surfaceID == identity.surfaceID
                ? token
                : nil
        })
        guard !tokens.isEmpty else { return }
        state.pending.removeAll { pending in
            guard case let .frame(token) = pending else { return false }
            return tokens.contains(token)
        }
        for token in tokens {
            state.frames.removeValue(forKey: token)
        }
        if identity.displayChannelID == nil {
            state.latestFrameTokenByIdentity = state.latestFrameTokenByIdentity.filter {
                $0.key.surfaceID != identity.surfaceID
            }
        } else {
            state.latestFrameTokenByIdentity.removeValue(forKey: identity)
        }
    }

    private func cancel(waiterToken: UInt64) {
        let continuation: CheckedContinuation<SpiceSessionEvent?, Never>? = state.withLock { state in
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

    private static func removeFirstEvent(from state: inout State) -> SpiceSessionEvent? {
        while let pending = state.pending.first {
            state.pending.removeFirst()
            switch pending {
            case let .control(event):
                return event
            case let .frame(token):
                guard let frame = state.frames.removeValue(forKey: token) else {
                    continue
                }
                if state.latestFrameTokenByIdentity[frame.identity] == token {
                    state.latestFrameTokenByIdentity.removeValue(forKey: frame.identity)
                }
                return frame.event
            }
        }
        return nil
    }
}
