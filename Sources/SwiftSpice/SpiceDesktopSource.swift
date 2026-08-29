import Foundation
import SpiceChannels
import SpiceRenderer
import Synchronization

public struct SpiceSurfaceIdentity: Sendable, Hashable {
    public let displayChannelID: UInt8
    public let surfaceID: UInt32
    public let generation: UInt64

    public init(displayChannelID: UInt8, surfaceID: UInt32, generation: UInt64) {
        self.displayChannelID = displayChannelID
        self.surfaceID = surfaceID
        self.generation = generation
    }
}

public struct SpicePixelRect: Sendable, Hashable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct SpiceFrameRevision: Sendable, Hashable {
    public let surface: SpiceSurfaceIdentity
    public let value: UInt64

    public init(surface: SpiceSurfaceIdentity, value: UInt64) {
        self.surface = surface
        self.value = value
    }
}

public enum SpiceDamageRegion: Sendable, Equatable {
    case full
    case rectangles([SpicePixelRect])
}

public struct SpiceFrameUpdate: Sendable {
    public let frame: SpiceFrame
    public let revision: SpiceFrameRevision
    public let damage: SpiceDamageRegion
    package let deliverySequence: UInt64

    public init(
        frame: SpiceFrame,
        revision: SpiceFrameRevision,
        damage: SpiceDamageRegion
    ) {
        self.frame = frame
        self.revision = revision
        self.damage = damage
        deliverySequence = 0
    }

    package init(
        frame: SpiceFrame,
        revision: SpiceFrameRevision,
        damage: SpiceDamageRegion,
        deliverySequence: UInt64
    ) {
        self.frame = frame
        self.revision = revision
        self.damage = damage
        self.deliverySequence = deliverySequence
    }
}

public struct SpiceDesktopSnapshot: Sendable {
    public let generation: UInt64
    public let frame: SpiceFrameUpdate?
    public let cursor: SpiceCursorState?
    public let pointerMode: SpicePointerMode
    package let deliverySequence: UInt64
    package var frameDeliverySequence: UInt64? { frame?.deliverySequence }

    public init(
        generation: UInt64,
        frame: SpiceFrameUpdate?,
        cursor: SpiceCursorState?,
        pointerMode: SpicePointerMode
    ) {
        self.generation = generation
        self.frame = frame
        self.cursor = cursor
        self.pointerMode = pointerMode
        deliverySequence = 0
    }

    package init(
        generation: UInt64,
        frame: SpiceFrameUpdate?,
        cursor: SpiceCursorState?,
        pointerMode: SpicePointerMode,
        deliverySequence: UInt64
    ) {
        self.generation = generation
        self.frame = frame.map {
            guard $0.deliverySequence == 0, deliverySequence != 0 else { return $0 }
            return SpiceFrameUpdate(
                frame: $0.frame,
                revision: $0.revision,
                damage: $0.damage,
                deliverySequence: deliverySequence
            )
        }
        self.cursor = cursor
        self.pointerMode = pointerMode
        self.deliverySequence = deliverySequence
    }
}

public enum SpiceSurfaceSelection: Sendable, Hashable {
    case primary
    case surface(displayChannelID: UInt8, surfaceID: UInt32)

    fileprivate var key: DisplaySurfaceKey {
        switch self {
        case .primary:
            DisplaySurfaceKey(channelID: 0, surfaceID: 0)
        case let .surface(displayChannelID, surfaceID):
            DisplaySurfaceKey(channelID: displayChannelID, surfaceID: surfaceID)
        }
    }
}

public enum SpiceDesktopDemand: Sendable, Hashable {
    case none
    case visible
}

private struct SpiceDesktopSubscriberState: Sendable {
    let selection: SpiceSurfaceSelection
    let streamSink: SpiceDesktopStreamSink
    var demand: SpiceDesktopDemand = .none
    var updateHandler: (@Sendable (SpiceDesktopSnapshot) -> Void)?
}

private struct SpiceDesktopSourceState: Sendable {
    var generation: UInt64 = 0
    var pointerMode: SpicePointerMode = .absolute
    var cursor: SpiceCursorState?
    var isSynthetic = false
    var frames: [DisplaySurfaceKey: SpiceFrameUpdate] = [:]
    var subscribers: [UInt64: SpiceDesktopSubscriberState] = [:]
    var surfacesAwaitingFreshPublication: Set<DisplaySurfaceKey> = []
    var nextSubscriberID: UInt64 = 0
    var deliverySequence: UInt64 = 0
    var deliveredSnapshots: UInt64 = 0
    var streamCoalesces: UInt64 = 0
    var handlerDeliveries: UInt64 = 0
}

package struct SpiceDesktopSourceMetrics: Sendable, Equatable {
    package let deliveredSnapshots: UInt64
    package let streamCoalesces: UInt64
    package let handlerDeliveries: UInt64
    package let subscriptions: Int
    package let visibleSubscriptions: Int
}

private enum SpiceDesktopDelivery: Sendable {
    case stream(SpiceDesktopStreamSink, SpiceDesktopSnapshot)
    case handler(
        @Sendable (SpiceDesktopSnapshot) -> Void,
        SpiceDesktopSnapshot
    )
}

private final class SpiceDesktopStreamSink: Sendable {
    private struct State: Sendable {
        let continuation: AsyncStream<SpiceDesktopSnapshot>.Continuation
        var latestOffered: SpiceDesktopSnapshot?
        var isFinished = false
    }

    private let state: Mutex<State>

    init(_ continuation: AsyncStream<SpiceDesktopSnapshot>.Continuation) {
        state = Mutex(State(continuation: continuation))
    }

    /// Serializes `AsyncStream` offers so a late callback cannot replace a
    /// newer buffered snapshot. If the buffer is occupied, the dropped and
    /// incoming snapshots are folded into one authoritative latest update.
    func offer(_ snapshot: SpiceDesktopSnapshot) -> Bool {
        state.withLock { state in
            guard !state.isFinished else { return false }
            var offered = snapshot
            if let latest = state.latestOffered,
               snapshot.generation < latest.generation
                || (
                    snapshot.generation == latest.generation
                        && snapshot.deliverySequence <= latest.deliverySequence
                )
            {
                offered = SpiceDesktopSource.merging(latest, snapshot)
            }
            let result = state.continuation.yield(offered)
            guard case let .dropped(previous) = result else {
                state.latestOffered = offered
                return false
            }
            offered = SpiceDesktopSource.merging(previous, offered)
            _ = state.continuation.yield(offered)
            state.latestOffered = offered
            return true
        }
    }

    func discardLatest() {
        state.withLock { $0.latestOffered = nil }
    }

    func finish() {
        let continuation = state.withLock { state -> AsyncStream<
            SpiceDesktopSnapshot
        >.Continuation? in
            guard !state.isFinished else { return nil }
            state.isFinished = true
            state.latestOffered = nil
            return state.continuation
        }
        continuation?.finish()
    }
}

private final class WeakSpiceDesktopSource: @unchecked Sendable {
    weak var value: SpiceDesktopSource?

    init(_ value: SpiceDesktopSource) {
        self.value = value
    }
}

/// Latest-only desktop state independent of SwiftUI Observation. Display
/// channels consult its demand coordinator before constructing IOSurface
/// snapshots, while cursor and pointer-mode changes remain lightweight.
public final class SpiceDesktopSource: Sendable {
    private let state = Mutex(SpiceDesktopSourceState())
    package let frameDemandCoordinator: DisplayFrameDemandCoordinator
    package let presentationDiagnostics: SpicePresentationDiagnostics

    package init(
        presentationDiagnostics: SpicePresentationDiagnostics = .init(),
        frameDemandCoordinator: DisplayFrameDemandCoordinator = .init()
    ) {
        self.presentationDiagnostics = presentationDiagnostics
        self.frameDemandCoordinator = frameDemandCoordinator
    }

    public func subscribe(
        surface: SpiceSurfaceSelection = .primary
    ) -> SpiceDesktopSubscription {
        let identifier = state.withLock { state -> UInt64 in
            let identifier = state.nextSubscriberID
            state.nextSubscriberID &+= 1
            return identifier
        }
        let pipe = AsyncStream.makeStream(
            of: SpiceDesktopSnapshot.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let weakSource = WeakSpiceDesktopSource(self)
        pipe.continuation.onTermination = { @Sendable _ in
            weakSource.value?.cancelSubscription(identifier)
        }
        state.withLock { state in
            let streamSink = SpiceDesktopStreamSink(pipe.continuation)
            state.subscribers[identifier] = SpiceDesktopSubscriberState(
                selection: surface,
                streamSink: streamSink
            )
        }
        return SpiceDesktopSubscription(
            identifier: identifier,
            updates: pipe.stream,
            source: self
        )
    }

    package func beginSession(pointerMode: SpicePointerMode) {
        let deliveries = state.withLock { state -> [SpiceDesktopDelivery] in
            state.generation &+= 1
            state.deliverySequence &+= 1
            state.isSynthetic = false
            state.pointerMode = pointerMode
            state.cursor = nil
            state.frames.removeAll(keepingCapacity: true)
            state.surfacesAwaitingFreshPublication.removeAll(keepingCapacity: true)
            return deliveriesForAllVisibleSubscribers(state: state, forceFull: true)
        }
        deliver(deliveries)
    }

    package func endSession() {
        let deliveries = state.withLock { state -> [SpiceDesktopDelivery] in
            state.generation &+= 1
            state.deliverySequence &+= 1
            state.isSynthetic = false
            state.cursor = nil
            state.frames.removeAll(keepingCapacity: true)
            state.surfacesAwaitingFreshPublication.removeAll(keepingCapacity: true)
            return deliveriesForAllVisibleSubscribers(state: state, forceFull: true)
        }
        deliver(deliveries)
    }

    /// Advances the public desktop generation at a seamless migration
    /// boundary without discarding the canonical frame retained by the reused
    /// DisplayChannel/SurfaceStore. The generation change makes any delivery
    /// already captured by the old receive task stale, while the full retained
    /// update keeps a static guest desktop visible when the target sends no new
    /// display damage after handoff.
    package func beginSeamlessMigration(pointerMode: SpicePointerMode) {
        let deliveries = state.withLock { state -> [SpiceDesktopDelivery] in
            state.generation &+= 1
            state.deliverySequence &+= 1
            state.isSynthetic = false
            state.pointerMode = pointerMode
            state.cursor = nil
            return deliveriesForAllVisibleSubscribers(state: state, forceFull: true)
        }
        deliver(deliveries)
    }

    package func receiveFrame(_ published: PublishedDisplayFrame, displayChannelID: UInt8) {
        let snapshot = published.snapshot
        let key = DisplaySurfaceKey(
            channelID: displayChannelID,
            surfaceID: snapshot.surfaceID
        )
        let identity = SpiceSurfaceIdentity(
            displayChannelID: displayChannelID,
            surfaceID: snapshot.surfaceID,
            generation: snapshot.lifecycleGeneration
        )
        let damage = Self.damageRegion(snapshot.publicationDamage)
        let deliveredUpdate = SpiceFrameUpdate(
            frame: SpiceFrame(snapshot),
            revision: SpiceFrameRevision(surface: identity, value: snapshot.revision),
            damage: damage
        )
        let result = state.withLock { state -> (
            deliveries: [SpiceDesktopDelivery],
            autoAcknowledge: Bool,
            traceSnapshot: SpiceDesktopSnapshot?,
            retiredGeneration: UInt64?
        ) in
            state.deliverySequence &+= 1
            let sequencedUpdate = SpiceFrameUpdate(
                frame: deliveredUpdate.frame,
                revision: deliveredUpdate.revision,
                damage: deliveredUpdate.damage,
                deliverySequence: state.deliverySequence
            )
            let retainedUpdate = SpiceFrameUpdate(
                frame: sequencedUpdate.frame,
                revision: sequencedUpdate.revision,
                damage: .rectangles([]),
                deliverySequence: sequencedUpdate.deliverySequence
            )
            let previousGeneration = state.frames[key]?.revision.surface.generation
            let retiredGeneration = previousGeneration.flatMap {
                $0 == identity.generation ? nil : $0
            }
            state.frames[key] = retainedUpdate
            state.surfacesAwaitingFreshPublication.remove(key)
            let desktopSnapshot = SpiceDesktopSnapshot(
                generation: state.generation,
                frame: sequencedUpdate,
                cursor: state.cursor,
                pointerMode: state.pointerMode,
                deliverySequence: state.deliverySequence
            )
            let deliveries = state.subscribers.values.compactMap {
                subscriber -> SpiceDesktopDelivery? in
                guard subscriber.demand == .visible, subscriber.selection.key == key else {
                    return nil
                }
                return delivery(
                    for: subscriber,
                    snapshot: desktopSnapshot
                )
            }
            return (
                deliveries,
                shouldAutoAcknowledge(key: key, state: state),
                deliveries.isEmpty ? nil : desktopSnapshot,
                retiredGeneration
            )
        }
        // A Surface may be recreated without a desktop-generation change or a
        // separately delivered destroy event. Retire the overwritten lifecycle
        // before the replacement can be observed or delivered, so an old
        // drawable callback cannot complete the replacement's trace.
        if let retiredGeneration = result.retiredGeneration {
            presentationDiagnostics.retireInteractionSurfaceLifecycle(
                displayChannelID: displayChannelID,
                surfaceID: snapshot.surfaceID,
                generation: retiredGeneration
            )
        }
        if let traceSnapshot = result.traceSnapshot {
            presentationDiagnostics.recordInteractionFrameReceived(
                traceSnapshot,
                sourceTiming: published.sourceTiming
            )
        }
        deliver(result.deliveries)
        if result.autoAcknowledge {
            frameDemandCoordinator.acknowledge(
                channelID: displayChannelID,
                revision: snapshot.surfaceRevision
            )
        }
    }

    package func receiveFrame(_ snapshot: FrameSnapshot, displayChannelID: UInt8) {
        receiveFrame(
            PublishedDisplayFrame(snapshot: snapshot, sourceTiming: nil),
            displayChannelID: displayChannelID
        )
    }

    package func surfaceDestroyed(displayChannelID: UInt8, surfaceID: UInt32) {
        let key = DisplaySurfaceKey(channelID: displayChannelID, surfaceID: surfaceID)
        let result = state.withLock { state -> (
            deliveries: [SpiceDesktopDelivery],
            retiredGeneration: UInt64?
        ) in
            state.deliverySequence &+= 1
            let retiredGeneration = state.frames.removeValue(forKey: key)?
                .revision.surface.generation
            state.surfacesAwaitingFreshPublication.remove(key)
            let deliveries = state.subscribers.values.compactMap {
                subscriber -> SpiceDesktopDelivery? in
                guard subscriber.demand == .visible, subscriber.selection.key == key else {
                    return nil
                }
                return delivery(
                    for: subscriber,
                    snapshot: authoritativeSnapshot(
                        for: subscriber.selection,
                        state: state,
                        forceFull: true
                    )
                )
            }
            return (deliveries, retiredGeneration)
        }
        if let retiredGeneration = result.retiredGeneration {
            presentationDiagnostics.retireInteractionSurfaceLifecycle(
                displayChannelID: displayChannelID,
                surfaceID: surfaceID,
                generation: retiredGeneration
            )
        }
        deliver(result.deliveries)
    }

    package func updateCursor(_ cursor: SpiceCursorState?) {
        let deliveries = state.withLock { state -> [SpiceDesktopDelivery] in
            state.deliverySequence &+= 1
            state.cursor = cursor
            return deliveriesForAllVisibleSubscribers(state: state, forceFull: false)
        }
        deliver(deliveries)
    }

    package func updatePointerMode(_ pointerMode: SpicePointerMode) {
        let deliveries = state.withLock { state -> [SpiceDesktopDelivery] in
            state.deliverySequence &+= 1
            state.pointerMode = pointerMode
            return deliveriesForAllVisibleSubscribers(state: state, forceFull: false)
        }
        deliver(deliveries)
    }

    package func beginSyntheticDesktop(pointerMode: SpicePointerMode = .absolute) {
        beginSession(pointerMode: pointerMode)
        state.withLock { $0.isSynthetic = true }
    }

    package func publishSyntheticFrame(
        _ frame: SpiceFrame,
        revision: UInt64,
        damage: SpiceDamageRegion = .full
    ) {
        let deliveries = state.withLock { state -> [SpiceDesktopDelivery] in
            if state.generation == 0 {
                state.generation = 1
                state.isSynthetic = true
            }
            state.deliverySequence &+= 1
            let key = DisplaySurfaceKey(channelID: 0, surfaceID: frame.surfaceID)
            state.surfacesAwaitingFreshPublication.remove(key)
            let identity = SpiceSurfaceIdentity(
                displayChannelID: 0,
                surfaceID: frame.surfaceID,
                generation: state.generation
            )
            let delivered = SpiceFrameUpdate(
                frame: frame,
                revision: SpiceFrameRevision(surface: identity, value: revision),
                damage: damage,
                deliverySequence: state.deliverySequence
            )
            state.frames[key] = SpiceFrameUpdate(
                frame: frame,
                revision: delivered.revision,
                damage: .rectangles([]),
                deliverySequence: delivered.deliverySequence
            )
            return state.subscribers.values.compactMap {
                subscriber -> SpiceDesktopDelivery? in
                guard subscriber.demand == .visible, subscriber.selection.key == key else {
                    return nil
                }
                return delivery(
                    for: subscriber,
                    snapshot: SpiceDesktopSnapshot(
                        generation: state.generation,
                        frame: delivered,
                        cursor: state.cursor,
                        pointerMode: state.pointerMode,
                        deliverySequence: state.deliverySequence
                    )
                )
            }
        }
        deliver(deliveries)
    }

    package func metrics() -> SpiceDesktopSourceMetrics {
        state.withLock { state in
            SpiceDesktopSourceMetrics(
                deliveredSnapshots: state.deliveredSnapshots,
                streamCoalesces: state.streamCoalesces,
                handlerDeliveries: state.handlerDeliveries,
                subscriptions: state.subscribers.count,
                visibleSubscriptions: state.subscribers.values.count {
                    $0.demand == .visible
                }
            )
        }
    }

    fileprivate func setDemand(_ demand: SpiceDesktopDemand, subscriberID: UInt64) {
        let result = state.withLock { state -> (
            key: DisplaySurfaceKey,
            changed: Bool,
            demandDispatch: DisplayFrameDemandDispatch?,
            delivery: SpiceDesktopDelivery?,
            autoAcknowledge: SpiceFrameRevision?
        )? in
            guard var subscriber = state.subscribers[subscriberID] else { return nil }
            let changed = subscriber.demand != demand
            let key = subscriber.selection.key
            let hadOtherVisibleSubscriber = state.subscribers.contains { identifier, candidate in
                identifier != subscriberID
                    && candidate.demand == .visible
                    && candidate.selection.key == key
            }
            subscriber.demand = demand
            state.subscribers[subscriberID] = subscriber
            let hasVisibleSubscriber = state.subscribers.values.contains {
                $0.demand == .visible && $0.selection.key == key
            }
            let shouldDeliverRetained = changed
                && demand == .visible
                && (
                    state.isSynthetic
                        || hadOtherVisibleSubscriber
                        || (
                            state.frames[key] == nil
                                && !state.surfacesAwaitingFreshPublication.contains(key)
                        )
                )
            let snapshot = shouldDeliverRetained
                ? authoritativeSnapshot(
                    for: subscriber.selection,
                    state: state,
                    forceFull: true
                )
                : nil
            let autoAcknowledge = demand == .none
                && shouldAutoAcknowledge(key: key, state: state)
                ? state.frames[key]?.revision
                : nil
            if demand == .none, !hasVisibleSubscriber, !state.isSynthetic {
                if state.frames[key] != nil {
                    state.surfacesAwaitingFreshPublication.insert(key)
                }
                state.frames.removeValue(forKey: key)
            }
            let demandDispatch = changed
                ? frameDemandCoordinator.prepareDemandChange(
                    for: key,
                    subscriberID: subscriberID,
                    isDemanded: demand == .visible
                )
                : nil
            return (
                key,
                changed,
                demandDispatch,
                snapshot.map { delivery(for: subscriber, snapshot: $0) },
                autoAcknowledge
            )
        }
        guard let result else { return }
        result.demandDispatch?.deliver()
        if let delivery = result.delivery {
            deliver([delivery])
        }
        if let revision = result.autoAcknowledge {
            acknowledge(revision)
        }
    }

    fileprivate func cancelSubscription(_ identifier: UInt64) {
        let result = state.withLock { state -> (
            subscriber: SpiceDesktopSubscriberState?,
            demandDispatch: DisplayFrameDemandDispatch?,
            autoAcknowledge: SpiceFrameRevision?
        ) in
            let subscriber = state.subscribers.removeValue(forKey: identifier)
            let key = subscriber?.selection.key
            let revision = key.flatMap { key -> SpiceFrameRevision? in
                guard shouldAutoAcknowledge(key: key, state: state) else { return nil }
                return state.frames[key]?.revision
            }
            if let key,
               !state.subscribers.values.contains(where: {
                   $0.demand == .visible && $0.selection.key == key
               }),
               !state.isSynthetic
            {
                if state.frames[key] != nil {
                    state.surfacesAwaitingFreshPublication.insert(key)
                }
                state.frames.removeValue(forKey: key)
            }
            let demandDispatch: DisplayFrameDemandDispatch?
            if let subscriber, subscriber.demand == .visible {
                demandDispatch = frameDemandCoordinator.prepareDemandChange(
                    for: subscriber.selection.key,
                    subscriberID: identifier,
                    isDemanded: false
                )
            } else {
                demandDispatch = nil
            }
            return (subscriber, demandDispatch, revision)
        }
        guard let subscriber = result.subscriber else { return }
        result.demandDispatch?.deliver()
        subscriber.streamSink.finish()
        if let revision = result.autoAcknowledge {
            acknowledge(revision)
        }
    }

    fileprivate func setUpdateHandler(
        _ handler: (@Sendable (SpiceDesktopSnapshot) -> Void)?,
        subscriberID: UInt64
    ) {
        let result = state.withLock { state -> (
            initial: SpiceDesktopSnapshot?,
            autoAcknowledge: SpiceFrameRevision?
        )? in
            guard var subscriber = state.subscribers[subscriberID] else { return nil }
            subscriber.updateHandler = handler
            if handler != nil {
                subscriber.streamSink.discardLatest()
            }
            state.subscribers[subscriberID] = subscriber
            let initial = handler != nil
                && subscriber.demand == .visible
                && state.isSynthetic
                ? authoritativeSnapshot(
                    for: subscriber.selection,
                    state: state,
                    forceFull: true
                )
                : nil
            let key = subscriber.selection.key
            let autoAcknowledge = handler == nil
                && shouldAutoAcknowledge(key: key, state: state)
                ? state.frames[key]?.revision
                : nil
            return (initial, autoAcknowledge)
        }
        guard let result else { return }
        if let handler, let initial = result.initial {
            handler(initial)
        }
        if let revision = result.autoAcknowledge {
            acknowledge(revision)
        }
    }

    fileprivate func acknowledgeFrame(
        _ revision: SpiceFrameRevision,
        subscriberID: UInt64
    ) {
        let shouldAcknowledge = state.withLock { state in
            guard let subscriber = state.subscribers[subscriberID],
                  subscriber.demand == .visible,
                  subscriber.selection.key.channelID == revision.surface.displayChannelID,
                  subscriber.selection.key.surfaceID == revision.surface.surfaceID
            else {
                return false
            }
            return true
        }
        guard shouldAcknowledge else { return }
        frameDemandCoordinator.acknowledge(
            channelID: revision.surface.displayChannelID,
            revision: SurfaceRevision(
                surfaceID: revision.surface.surfaceID,
                lifecycleGeneration: revision.surface.generation,
                revision: revision.value
            )
        )
    }

    private func acknowledge(_ revision: SpiceFrameRevision) {
        frameDemandCoordinator.acknowledge(
            channelID: revision.surface.displayChannelID,
            revision: SurfaceRevision(
                surfaceID: revision.surface.surfaceID,
                lifecycleGeneration: revision.surface.generation,
                revision: revision.value
            )
        )
    }

    fileprivate func requestLatest(subscriberID: UInt64) {
        let next = state.withLock { state -> SpiceDesktopDelivery? in
            guard let subscriber = state.subscribers[subscriberID],
                  subscriber.demand == .visible
            else {
                return nil
            }
            state.deliverySequence &+= 1
            return delivery(
                for: subscriber,
                snapshot: authoritativeSnapshot(
                    for: subscriber.selection,
                    state: state,
                    forceFull: true
                )
            )
        }
        if let next { deliver([next]) }
    }

    private func deliveriesForAllVisibleSubscribers(
        state: SpiceDesktopSourceState,
        forceFull: Bool
    ) -> [SpiceDesktopDelivery] {
        state.subscribers.values.compactMap {
            subscriber -> SpiceDesktopDelivery? in
            guard subscriber.demand == .visible else { return nil }
            return delivery(
                for: subscriber,
                snapshot: authoritativeSnapshot(
                    for: subscriber.selection,
                    state: state,
                    forceFull: forceFull
                )
            )
        }
    }

    private func shouldAutoAcknowledge(
        key: DisplaySurfaceKey,
        state: SpiceDesktopSourceState
    ) -> Bool {
        let visible = state.subscribers.values.filter {
            $0.demand == .visible && $0.selection.key == key
        }
        return !visible.isEmpty && visible.allSatisfy { $0.updateHandler == nil }
    }

    private func authoritativeSnapshot(
        for selection: SpiceSurfaceSelection,
        state: SpiceDesktopSourceState,
        forceFull: Bool
    ) -> SpiceDesktopSnapshot {
        let frame = state.frames[selection.key].map { update in
            guard forceFull else { return update }
            return SpiceFrameUpdate(
                frame: update.frame,
                revision: update.revision,
                damage: .full,
                deliverySequence: update.deliverySequence
            )
        }
        return SpiceDesktopSnapshot(
            generation: state.generation,
            frame: frame,
            cursor: state.cursor,
            pointerMode: state.pointerMode,
            deliverySequence: state.deliverySequence
        )
    }

    private func delivery(
        for subscriber: SpiceDesktopSubscriberState,
        snapshot: SpiceDesktopSnapshot
    ) -> SpiceDesktopDelivery {
        if let updateHandler = subscriber.updateHandler {
            return .handler(updateHandler, snapshot)
        }
        return .stream(subscriber.streamSink, snapshot)
    }

    private func deliver(_ deliveries: [SpiceDesktopDelivery]) {
        for next in deliveries {
            switch next {
            case let .handler(handler, snapshot):
                state.withLock { state in
                    state.deliveredSnapshots &+= 1
                    state.handlerDeliveries &+= 1
                }
                handler(snapshot)
            case let .stream(streamSink, snapshot):
                state.withLock { $0.deliveredSnapshots &+= 1 }
                if streamSink.offer(snapshot) {
                    state.withLock { $0.streamCoalesces &+= 1 }
                }
            }
        }
    }

    private static func damageRegion(_ journal: SurfaceDamageJournal) -> SpiceDamageRegion {
        if journal.isFullFrame {
            return .full
        }
        return .rectangles(journal.copyRectangles.map {
            SpicePixelRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        })
    }

    package static func merging(
        _ previous: SpiceDesktopSnapshot,
        _ incoming: SpiceDesktopSnapshot
    ) -> SpiceDesktopSnapshot {
        let incomingIsNewest: Bool
        if incoming.generation != previous.generation {
            incomingIsNewest = incoming.generation > previous.generation
        } else if incoming.deliverySequence != previous.deliverySequence {
            incomingIsNewest = incoming.deliverySequence > previous.deliverySequence
        } else {
            // Package clients can construct sequence-zero snapshots. Preserve
            // conventional `(previous, incoming)` behavior for that tie.
            incomingIsNewest = true
        }
        let newest = incomingIsNewest ? incoming : previous
        let older = incomingIsNewest ? previous : incoming

        guard older.generation == newest.generation,
              let newestFrame = newest.frame
        else {
            return newest.frame.map { newestFrame in
                SpiceDesktopSnapshot(
                    generation: newest.generation,
                    frame: SpiceFrameUpdate(
                        frame: newestFrame.frame,
                        revision: newestFrame.revision,
                        damage: .full,
                        deliverySequence: newestFrame.deliverySequence
                    ),
                    cursor: newest.cursor,
                    pointerMode: newest.pointerMode,
                    deliverySequence: newest.deliverySequence
                )
            } ?? newest
        }
        guard let olderFrame = older.frame,
              olderFrame.revision.surface == newestFrame.revision.surface
        else {
            return SpiceDesktopSnapshot(
                generation: newest.generation,
                frame: SpiceFrameUpdate(
                    frame: newestFrame.frame,
                    revision: newestFrame.revision,
                    damage: .full,
                    deliverySequence: newestFrame.deliverySequence
                ),
                cursor: newest.cursor,
                pointerMode: newest.pointerMode,
                deliverySequence: newest.deliverySequence
            )
        }
        let damage = mergeDamage(
            olderFrame.damage,
            newestFrame.damage,
            width: newestFrame.frame.width,
            height: newestFrame.frame.height
        )
        return SpiceDesktopSnapshot(
            generation: newest.generation,
            frame: SpiceFrameUpdate(
                frame: newestFrame.frame,
                revision: newestFrame.revision,
                damage: damage,
                deliverySequence: newestFrame.deliverySequence
            ),
            cursor: newest.cursor,
            pointerMode: newest.pointerMode,
            deliverySequence: newest.deliverySequence
        )
    }

    private static func mergeDamage(
        _ lhs: SpiceDamageRegion,
        _ rhs: SpiceDamageRegion,
        width: Int,
        height: Int
    ) -> SpiceDamageRegion {
        guard case let .rectangles(left) = lhs,
              case let .rectangles(right) = rhs
        else {
            return .full
        }
        var journal = SurfaceDamageJournal(width: width, height: height)
        for rectangle in left + right {
            journal.append(PixelRect(
                x: rectangle.x,
                y: rectangle.y,
                width: rectangle.width,
                height: rectangle.height
            ))
        }
        return damageRegion(journal)
    }
}

public final class SpiceDesktopSubscription: Sendable {
    public let updates: AsyncStream<SpiceDesktopSnapshot>

    private let identifier: UInt64
    private let source: SpiceDesktopSource
    private let isCancelled = Mutex(false)

    fileprivate init(
        identifier: UInt64,
        updates: AsyncStream<SpiceDesktopSnapshot>,
        source: SpiceDesktopSource
    ) {
        self.identifier = identifier
        self.updates = updates
        self.source = source
    }

    public func setDemand(_ demand: SpiceDesktopDemand) {
        guard !isCancelled.withLock({ $0 }) else { return }
        source.setDemand(demand, subscriberID: identifier)
    }

    public func cancel() {
        let shouldCancel = isCancelled.withLock { cancelled in
            guard !cancelled else { return false }
            cancelled = true
            return true
        }
        guard shouldCancel else { return }
        source.cancelSubscription(identifier)
    }

    package func setUpdateHandler(
        _ handler: (@Sendable (SpiceDesktopSnapshot) -> Void)?
    ) {
        guard !isCancelled.withLock({ $0 }) else { return }
        source.setUpdateHandler(handler, subscriberID: identifier)
    }

    package func acknowledgeFrame(_ revision: SpiceFrameRevision) {
        guard !isCancelled.withLock({ $0 }) else { return }
        source.acknowledgeFrame(revision, subscriberID: identifier)
    }

    package func requestLatest() {
        guard !isCancelled.withLock({ $0 }) else { return }
        source.requestLatest(subscriberID: identifier)
    }

    deinit {
        cancel()
    }
}
