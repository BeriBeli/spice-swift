import Foundation
import SpiceRenderer
import Synchronization

package struct DisplaySurfaceKey: Sendable, Hashable {
    package let channelID: UInt8
    package let surfaceID: UInt32

    package init(channelID: UInt8, surfaceID: UInt32) {
        self.channelID = channelID
        self.surfaceID = surfaceID
    }
}

package enum DisplayFrameDemandEvent: Sendable {
    case demandChanged(surfaceID: UInt32, isDemanded: Bool)
    case frameConsumed(SurfaceRevision)
}

/// Thread-safe bridge between public desktop subscriptions and Display
/// channels. It contains demand and acknowledgements only; no frame lease is
/// retained at this layer.
package final class DisplayFrameDemandCoordinator: Sendable {
    package typealias Handler = @Sendable (DisplayFrameDemandEvent) -> Void
    package typealias DemandMutationHook = @Sendable (
        DisplaySurfaceKey,
        UInt64,
        Bool
    ) -> Void

    private struct HandlerRecord: Sendable {
        let channelID: UInt8
        let handler: Handler
    }

    private struct PendingDelivery: Sendable {
        let sequence: UInt64
        let handlerID: UInt64
        let event: DisplayFrameDemandEvent
    }

    private struct State: Sendable {
        var subscribersBySurface: [DisplaySurfaceKey: Set<UInt64>] = [:]
        var handlers: [UInt64: HandlerRecord] = [:]
        var nextHandlerID: UInt64 = 0
        var pendingDeliveries: [PendingDelivery] = []
        var pendingDeliveryIndex = 0
        var nextDeliverySequence: UInt64 = 0
    }

    private let state = Mutex(State())
    private let callbackLock = DisplayFrameDemandCallbackLock()
    private let beforeDemandMutation: DemandMutationHook?
    private let afterDemandMutation: DemandMutationHook?

    package init(
        beforeDemandMutation: DemandMutationHook? = nil,
        afterDemandMutation: DemandMutationHook? = nil
    ) {
        self.beforeDemandMutation = beforeDemandMutation
        self.afterDemandMutation = afterDemandMutation
    }

    package func setDemand(
        for key: DisplaySurfaceKey,
        subscriberID: UInt64,
        isDemanded: Bool
    ) {
        let dispatch = prepareDemandChange(
            for: key,
            subscriberID: subscriberID,
            isDemanded: isDemanded
        )
        afterDemandMutation?(key, subscriberID, isDemanded)
        dispatch.deliver()
    }

    /// Commits one demand mutation to the coordinator's total event order
    /// without invoking handlers. `SpiceDesktopSource` uses this while its own
    /// state lock is held, then drains only after unlocking so subscription
    /// state and coordinator demand cannot be observed in opposite orders.
    package func prepareDemandChange(
        for key: DisplaySurfaceKey,
        subscriberID: UInt64,
        isDemanded: Bool
    ) -> DisplayFrameDemandDispatch {
        beforeDemandMutation?(key, subscriberID, isDemanded)
        state.withLock { state in
            let wasDemanded = !(state.subscribersBySurface[key]?.isEmpty ?? true)
            if isDemanded {
                state.subscribersBySurface[key, default: []].insert(subscriberID)
            } else {
                state.subscribersBySurface[key]?.remove(subscriberID)
                if state.subscribersBySurface[key]?.isEmpty == true {
                    state.subscribersBySurface.removeValue(forKey: key)
                }
            }
            let nowDemanded = !(state.subscribersBySurface[key]?.isEmpty ?? true)
            guard wasDemanded != nowDemanded else { return }
            let handlerIDs = state.handlers.compactMap { identifier, record in
                record.channelID == key.channelID ? identifier : nil
            }
            Self.enqueue(
                .demandChanged(surfaceID: key.surfaceID, isDemanded: nowDemanded),
                for: handlerIDs,
                state: &state
            )
        }
        return DisplayFrameDemandDispatch(coordinator: self)
    }

    package func acknowledge(channelID: UInt8, revision: SurfaceRevision) {
        state.withLock { state in
            let handlerIDs = state.handlers.compactMap { identifier, record in
                record.channelID == channelID ? identifier : nil
            }
            Self.enqueue(
                .frameConsumed(revision),
                for: handlerIDs,
                state: &state
            )
        }
        drain()
    }

    package func register(
        channelID: UInt8,
        handler: @escaping Handler
    ) -> DisplayFrameDemandRegistration {
        let identifier = state.withLock { state -> UInt64 in
            let identifier = state.nextHandlerID
            state.nextHandlerID &+= 1
            state.handlers[identifier] = HandlerRecord(
                channelID: channelID,
                handler: handler
            )
            let demandedSurfaces = state.subscribersBySurface.keys.compactMap { key in
                key.channelID == channelID ? key.surfaceID : nil
            }.sorted()
            for surfaceID in demandedSurfaces {
                Self.enqueue(
                    .demandChanged(surfaceID: surfaceID, isDemanded: true),
                    for: [identifier],
                    state: &state
                )
            }
            return identifier
        }
        drain()
        return DisplayFrameDemandRegistration { [weak self] in
            self?.removeHandler(identifier)
        }
    }

    private func removeHandler(_ identifier: UInt64) {
        _ = state.withLock { state in
            state.handlers.removeValue(forKey: identifier)
        }
    }

    fileprivate func drain() {
        callbackLock.withLock {
            while let (handler, event) = nextDelivery() {
                handler(event)
            }
        }
    }

    private func nextDelivery() -> (Handler, DisplayFrameDemandEvent)? {
        state.withLock { state in
            while state.pendingDeliveryIndex < state.pendingDeliveries.count {
                let pending = state.pendingDeliveries[state.pendingDeliveryIndex]
                state.pendingDeliveryIndex += 1
                if state.pendingDeliveryIndex == state.pendingDeliveries.count {
                    state.pendingDeliveries.removeAll(keepingCapacity: true)
                    state.pendingDeliveryIndex = 0
                }
                if let record = state.handlers[pending.handlerID] {
                    return (record.handler, pending.event)
                }
            }
            return nil
        }
    }

    private static func enqueue(
        _ event: DisplayFrameDemandEvent,
        for handlerIDs: [UInt64],
        state: inout State
    ) {
        for handlerID in handlerIDs.sorted() {
            let sequence = state.nextDeliverySequence
            state.nextDeliverySequence &+= 1
            state.pendingDeliveries.append(PendingDelivery(
                sequence: sequence,
                handlerID: handlerID,
                event: event
            ))
        }
    }
}

package struct DisplayFrameDemandDispatch: Sendable {
    private let coordinator: DisplayFrameDemandCoordinator

    fileprivate init(coordinator: DisplayFrameDemandCoordinator) {
        self.coordinator = coordinator
    }

    package func deliver() {
        coordinator.drain()
    }
}

private final class DisplayFrameDemandCallbackLock: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    func withLock(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        operation()
    }
}

package final class DisplayFrameDemandRegistration: Sendable {
    private let cancellation: Mutex<(@Sendable () -> Void)?>

    fileprivate init(cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = Mutex(cancellation)
    }

    package func cancel() {
        let action = cancellation.withLock { action in
            defer { action = nil }
            return action
        }
        action?()
    }

    deinit {
        cancel()
    }
}

package struct DisplayFrameSourceTiming: Sendable, Equatable {
    package let messageReceivedAt: ContinuousClock.Instant
    package let surfaceReadyAt: ContinuousClock.Instant

    package init(
        messageReceivedAt: ContinuousClock.Instant,
        surfaceReadyAt: ContinuousClock.Instant
    ) {
        self.messageReceivedAt = messageReceivedAt
        self.surfaceReadyAt = surfaceReadyAt
    }
}

package struct DisplayFramePublisherMetrics: Sendable, Equatable {
    package var submissions: UInt64
    package var snapshotAttempts: UInt64
    package var emittedFrames: UInt64
    package var emittedIOSurfaceFrames: UInt64
    package var emittedCPUOnlyFrames: UInt64
    package var staleSnapshots: UInt64
    package var pendingEvictions: UInt64
    package var pendingSurfaces: Int
    package var flushes: UInt64
    package var flushesWithoutEmission: UInt64
    package var demandSuppressedSubmissions: UInt64
    package var pendingRevisionCoalesces: UInt64
    package var preparedFrameCoalesces: UInt64
    package var demandedSurfaces: Int
    package var preparedFrames: Int
    package var batchStartGap = SpiceTimingHistogram()
    package var framedReceiveBatchStartGap = SpiceTimingHistogram()
    package var messageReceiveToSurfaceReady = SpiceTimingHistogram()
    package var surfaceReadyToSubmit = SpiceTimingHistogram()
    package var flushStartGap = SpiceTimingHistogram()
    package var flushSchedulingDelay = SpiceTimingHistogram()
    package var snapshotDuration = SpiceTimingHistogram()
    package var emitDuration = SpiceTimingHistogram()

    package init(
        submissions: UInt64 = 0,
        snapshotAttempts: UInt64 = 0,
        emittedFrames: UInt64 = 0,
        emittedIOSurfaceFrames: UInt64 = 0,
        emittedCPUOnlyFrames: UInt64 = 0,
        staleSnapshots: UInt64 = 0,
        pendingEvictions: UInt64 = 0,
        pendingSurfaces: Int = 0,
        flushes: UInt64 = 0,
        flushesWithoutEmission: UInt64 = 0,
        demandSuppressedSubmissions: UInt64 = 0,
        pendingRevisionCoalesces: UInt64 = 0,
        preparedFrameCoalesces: UInt64 = 0,
        demandedSurfaces: Int = 0,
        preparedFrames: Int = 0,
        batchStartGap: SpiceTimingHistogram = .init(),
        framedReceiveBatchStartGap: SpiceTimingHistogram = .init(),
        messageReceiveToSurfaceReady: SpiceTimingHistogram = .init(),
        surfaceReadyToSubmit: SpiceTimingHistogram = .init(),
        flushStartGap: SpiceTimingHistogram = .init(),
        flushSchedulingDelay: SpiceTimingHistogram = .init(),
        snapshotDuration: SpiceTimingHistogram = .init(),
        emitDuration: SpiceTimingHistogram = .init()
    ) {
        self.submissions = submissions
        self.snapshotAttempts = snapshotAttempts
        self.emittedFrames = emittedFrames
        self.emittedIOSurfaceFrames = emittedIOSurfaceFrames
        self.emittedCPUOnlyFrames = emittedCPUOnlyFrames
        self.staleSnapshots = staleSnapshots
        self.pendingEvictions = pendingEvictions
        self.pendingSurfaces = pendingSurfaces
        self.flushes = flushes
        self.flushesWithoutEmission = flushesWithoutEmission
        self.demandSuppressedSubmissions = demandSuppressedSubmissions
        self.pendingRevisionCoalesces = pendingRevisionCoalesces
        self.preparedFrameCoalesces = preparedFrameCoalesces
        self.demandedSurfaces = demandedSurfaces
        self.preparedFrames = preparedFrames
        self.batchStartGap = batchStartGap
        self.framedReceiveBatchStartGap = framedReceiveBatchStartGap
        self.messageReceiveToSurfaceReady = messageReceiveToSurfaceReady
        self.surfaceReadyToSubmit = surfaceReadyToSubmit
        self.flushStartGap = flushStartGap
        self.flushSchedulingDelay = flushSchedulingDelay
        self.snapshotDuration = snapshotDuration
        self.emitDuration = emitDuration
    }

    package mutating func accumulate(_ other: Self) {
        submissions &+= other.submissions
        snapshotAttempts &+= other.snapshotAttempts
        emittedFrames &+= other.emittedFrames
        emittedIOSurfaceFrames &+= other.emittedIOSurfaceFrames
        emittedCPUOnlyFrames &+= other.emittedCPUOnlyFrames
        staleSnapshots &+= other.staleSnapshots
        pendingEvictions &+= other.pendingEvictions
        pendingSurfaces += other.pendingSurfaces
        flushes &+= other.flushes
        flushesWithoutEmission &+= other.flushesWithoutEmission
        demandSuppressedSubmissions &+= other.demandSuppressedSubmissions
        pendingRevisionCoalesces &+= other.pendingRevisionCoalesces
        preparedFrameCoalesces &+= other.preparedFrameCoalesces
        demandedSurfaces += other.demandedSurfaces
        preparedFrames += other.preparedFrames
        batchStartGap.accumulate(other.batchStartGap)
        framedReceiveBatchStartGap.accumulate(other.framedReceiveBatchStartGap)
        messageReceiveToSurfaceReady.accumulate(other.messageReceiveToSurfaceReady)
        surfaceReadyToSubmit.accumulate(other.surfaceReadyToSubmit)
        flushStartGap.accumulate(other.flushStartGap)
        flushSchedulingDelay.accumulate(other.flushSchedulingDelay)
        snapshotDuration.accumulate(other.snapshotDuration)
        emitDuration.accumulate(other.emitDuration)
    }
}

package actor DisplayFramePublisher {
    package typealias Snapshot = @Sendable (SurfaceRevision) async -> FrameSnapshot?
    package typealias Emit = @Sendable (FrameSnapshot) async -> Void

    private struct Request: Sendable, Equatable {
        let surfaceRevision: SurfaceRevision
        let invalidationGeneration: UInt64
    }

    private struct SnapshotPreparation: Sendable {
        let requestIndex: Int
        var frame: FrameSnapshot?
        let duration: Duration
    }

    private struct SnapshotRunResult: Sendable {
        let completedAllRequests: Bool
        let admittedRequestCount: Int
    }

    private let interval: Duration
    private let maximumPendingSurfaces: Int
    private let maximumConcurrentSnapshots: Int
    private let requiresExplicitDemand: Bool
    private let waitsForConsumption: Bool
    private let snapshot: Snapshot
    private let emit: Emit
    private let clock = ContinuousClock()
    private var pending: [UInt32: Request] = [:]
    private var order: [UInt32] = []
    private var invalidationGenerations: [UInt32: UInt64] = [:]
    private var lastEmittedRevisions: [UInt32: SurfaceRevision] = [:]
    private var latestSubmittedRevisions: [UInt32: SurfaceRevision] = [:]
    private var demandedSurfaces: Set<UInt32> = []
    private var preparedRevisions: [UInt32: SurfaceRevision] = [:]
    private var forceFullDamage: Set<UInt32> = []
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var isCancelled = false
    private var lastFlushStart: ContinuousClock.Instant?
    private var lastBatchStart: ContinuousClock.Instant?
    private var lastFramedReceiveBatchStart: ContinuousClock.Instant?
    private var generation: UInt64 = 0
    private var submissions: UInt64 = 0
    private var snapshotAttempts: UInt64 = 0
    private var emittedFrames: UInt64 = 0
    private var emittedIOSurfaceFrames: UInt64 = 0
    private var emittedCPUOnlyFrames: UInt64 = 0
    private var staleSnapshots: UInt64 = 0
    private var pendingEvictions: UInt64 = 0
    private var flushes: UInt64 = 0
    private var flushesWithoutEmission: UInt64 = 0
    private var demandSuppressedSubmissions: UInt64 = 0
    private var pendingRevisionCoalesces: UInt64 = 0
    private var preparedFrameCoalesces: UInt64 = 0
    private var batchStartGap = SpiceTimingHistogram()
    private var framedReceiveBatchStartGap = SpiceTimingHistogram()
    private var messageReceiveToSurfaceReady = SpiceTimingHistogram()
    private var surfaceReadyToSubmit = SpiceTimingHistogram()
    private var flushStartGap = SpiceTimingHistogram()
    private var flushSchedulingDelay = SpiceTimingHistogram()
    private var snapshotDuration = SpiceTimingHistogram()
    private var emitDuration = SpiceTimingHistogram()

    package init(
        interval: Duration = .milliseconds(16),
        maximumPendingSurfaces: Int = 16,
        maximumConcurrentSnapshots: Int = 3,
        requiresExplicitDemand: Bool = false,
        waitsForConsumption: Bool = false,
        snapshot: @escaping Snapshot,
        emit: @escaping Emit
    ) {
        self.interval = interval
        self.maximumPendingSurfaces = max(1, maximumPendingSurfaces)
        self.maximumConcurrentSnapshots = max(1, maximumConcurrentSnapshots)
        self.requiresExplicitDemand = requiresExplicitDemand
        self.waitsForConsumption = waitsForConsumption
        self.snapshot = snapshot
        self.emit = emit
    }

    package func submit(
        _ surfaceRevision: SurfaceRevision,
        sourceTiming: DisplayFrameSourceTiming? = nil
    ) {
        let submittedAt = clock.now
        submissions &+= 1
        if let sourceTiming {
            messageReceiveToSurfaceReady.record(
                sourceTiming.messageReceivedAt.duration(to: sourceTiming.surfaceReadyAt)
            )
            surfaceReadyToSubmit.record(
                sourceTiming.surfaceReadyAt.duration(to: submittedAt)
            )
        }
        guard !isCancelled else { return }
        let surfaceID = surfaceRevision.surfaceID
        if let latest = latestSubmittedRevisions[surfaceID],
           isNewer(latest, than: surfaceRevision)
        {
            return
        }
        latestSubmittedRevisions[surfaceID] = surfaceRevision
        if !requiresExplicitDemand {
            demandedSurfaces.insert(surfaceID)
        } else if !demandedSurfaces.contains(surfaceID) {
            demandSuppressedSubmissions &+= 1
        }
        if let lastEmitted = lastEmittedRevisions[surfaceID],
           !isNewer(surfaceRevision, than: lastEmitted)
        {
            return
        }
        let invalidationGeneration = invalidationGenerations[surfaceID] ?? 0
        if let existing = pending[surfaceID],
           existing.invalidationGeneration == invalidationGeneration,
           isNewer(existing.surfaceRevision, than: surfaceRevision)
        {
            return
        }

        if pending.isEmpty {
            let now = submittedAt
            if let lastBatchStart {
                batchStartGap.record(lastBatchStart.duration(to: now))
            }
            lastBatchStart = now
            if let framedReceiveBatchStartedAt = sourceTiming?.messageReceivedAt {
                if let lastFramedReceiveBatchStart {
                    framedReceiveBatchStartGap.record(
                        lastFramedReceiveBatchStart.duration(to: framedReceiveBatchStartedAt)
                    )
                }
                lastFramedReceiveBatchStart = framedReceiveBatchStartedAt
            }
        }

        if pending[surfaceID] == nil {
            if pending.count >= maximumPendingSurfaces, let oldest = order.first {
                pending.removeValue(forKey: oldest)
                order.removeFirst()
                pendingEvictions &+= 1
            }
            order.append(surfaceID)
        } else {
            pendingRevisionCoalesces &+= 1
        }
        if preparedRevisions[surfaceID] != nil {
            preparedFrameCoalesces &+= 1
        }
        pending[surfaceID] = Request(
            surfaceRevision: surfaceRevision,
            invalidationGeneration: invalidationGeneration
        )

        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !isCancelled,
              pending.keys.contains(where: canPrepare),
              flushTask == nil,
              !isFlushing
        else {
            return
        }
        let now = clock.now
        let deadline = lastFlushStart?.advanced(by: interval) ?? now.advanced(by: interval)
        let delay = now < deadline ? now.duration(to: deadline) : .zero
        flushTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            await self?.flush(scheduledFor: deadline)
        }
    }

    package func remove(surfaceID: UInt32) {
        invalidationGenerations[surfaceID, default: 0] &+= 1
        lastEmittedRevisions.removeValue(forKey: surfaceID)
        latestSubmittedRevisions.removeValue(forKey: surfaceID)
        pending.removeValue(forKey: surfaceID)
        order.removeAll { $0 == surfaceID }
        // Desktop demand belongs to the selected surface identity, not to one
        // server-side create/destroy lifetime. Keep explicit demand across a
        // same-ID recreation; otherwise a visible subscriber would never
        // receive the recreated surface until it toggled visibility.
        if !requiresExplicitDemand {
            demandedSurfaces.remove(surfaceID)
        }
        preparedRevisions.removeValue(forKey: surfaceID)
        forceFullDamage.remove(surfaceID)
    }

    package func setDemand(surfaceID: UInt32, isDemanded: Bool) {
        guard !isCancelled else { return }
        if isDemanded {
            demandedSurfaces.insert(surfaceID)
            scheduleFlushIfNeeded()
        } else {
            demandedSurfaces.remove(surfaceID)
            if preparedRevisions.removeValue(forKey: surfaceID) != nil {
                forceFullDamage.insert(surfaceID)
            }
            // Preserve a full redraw request even when the canonical surface
            // does not mutate while hidden. Resume must publish one fresh
            // authoritative lease instead of replaying a retained UI frame.
            if let latest = latestSubmittedRevisions[surfaceID] {
                let request = Request(
                    surfaceRevision: latest,
                    invalidationGeneration: invalidationGenerations[surfaceID] ?? 0
                )
                if pending[surfaceID] == nil {
                    if pending.count >= maximumPendingSurfaces, let oldest = order.first {
                        pending.removeValue(forKey: oldest)
                        order.removeFirst()
                        pendingEvictions &+= 1
                    }
                    order.append(surfaceID)
                }
                pending[surfaceID] = request
                forceFullDamage.insert(surfaceID)
            }
        }
    }

    package func acknowledge(_ revision: SurfaceRevision) {
        guard waitsForConsumption,
              let prepared = preparedRevisions[revision.surfaceID],
              prepared.lifecycleGeneration == revision.lifecycleGeneration,
              revision.revision >= prepared.revision
        else {
            return
        }
        preparedRevisions.removeValue(forKey: revision.surfaceID)
        scheduleFlushIfNeeded()
    }

    package func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        guard !isCancelled, !isFlushing else { return }
        await flush()
    }

    package func cancel() {
        isCancelled = true
        generation &+= 1
        flushTask?.cancel()
        flushTask = nil
        isFlushing = false
        lastFlushStart = nil
        lastBatchStart = nil
        lastFramedReceiveBatchStart = nil
        pending.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        lastEmittedRevisions.removeAll(keepingCapacity: false)
        latestSubmittedRevisions.removeAll(keepingCapacity: false)
        demandedSurfaces.removeAll(keepingCapacity: false)
        preparedRevisions.removeAll(keepingCapacity: false)
        forceFullDamage.removeAll(keepingCapacity: false)
    }

    package func metrics() -> DisplayFramePublisherMetrics {
        DisplayFramePublisherMetrics(
            submissions: submissions,
            snapshotAttempts: snapshotAttempts,
            emittedFrames: emittedFrames,
            emittedIOSurfaceFrames: emittedIOSurfaceFrames,
            emittedCPUOnlyFrames: emittedCPUOnlyFrames,
            staleSnapshots: staleSnapshots,
            pendingEvictions: pendingEvictions,
            pendingSurfaces: pending.count,
            flushes: flushes,
            flushesWithoutEmission: flushesWithoutEmission,
            demandSuppressedSubmissions: demandSuppressedSubmissions,
            pendingRevisionCoalesces: pendingRevisionCoalesces,
            preparedFrameCoalesces: preparedFrameCoalesces,
            demandedSurfaces: demandedSurfaces.count,
            preparedFrames: preparedRevisions.count,
            batchStartGap: batchStartGap,
            framedReceiveBatchStartGap: framedReceiveBatchStartGap,
            messageReceiveToSurfaceReady: messageReceiveToSurfaceReady,
            surfaceReadyToSubmit: surfaceReadyToSubmit,
            flushStartGap: flushStartGap,
            flushSchedulingDelay: flushSchedulingDelay,
            snapshotDuration: snapshotDuration,
            emitDuration: emitDuration
        )
    }

    private func flush(scheduledFor deadline: ContinuousClock.Instant? = nil) async {
        guard !isCancelled, !isFlushing else { return }
        let flushGeneration = generation
        isFlushing = true
        let flushStartedAt = clock.now
        if let lastFlushStart {
            flushStartGap.record(lastFlushStart.duration(to: flushStartedAt))
        }
        if let deadline, deadline < flushStartedAt {
            flushSchedulingDelay.record(deadline.duration(to: flushStartedAt))
        } else if deadline != nil {
            flushSchedulingDelay.record(.zero)
        }
        lastFlushStart = flushStartedAt
        flushes &+= 1
        let emittedAtFlushStart = emittedFrames
        let eligibleSurfaceIDs = order.filter(canPrepare)
        let requests = eligibleSurfaceIDs.compactMap { pending[$0] }
        for surfaceID in eligibleSurfaceIDs {
            pending.removeValue(forKey: surfaceID)
        }
        let eligibleSet = Set(eligibleSurfaceIDs)
        order.removeAll { eligibleSet.contains($0) }
        flushTask = nil

        let snapshotRun = await prepareSnapshots(
            requests,
            flushGeneration: flushGeneration
        )
        guard snapshotRun.completedAllRequests,
              generation == flushGeneration,
              !isCancelled,
              !Task.isCancelled
        else {
            if generation == flushGeneration, !isCancelled {
                restoreQueuedRequestsAfterAbortedFlush(
                    requests,
                    admittedRequestCount: snapshotRun.admittedRequestCount
                )
                isFlushing = false
                scheduleFlushIfNeeded()
            }
            return
        }
        guard generation == flushGeneration else { return }
        if emittedFrames == emittedAtFlushStart {
            flushesWithoutEmission &+= 1
        }
        isFlushing = false
        scheduleFlushIfNeeded()
    }

    private func prepareSnapshots(
        _ requests: [Request],
        flushGeneration: UInt64
    ) async -> SnapshotRunResult {
        guard !requests.isEmpty else {
            return SnapshotRunResult(
                completedAllRequests: true,
                admittedRequestCount: 0
            )
        }
        let snapshot = self.snapshot
        let clock = self.clock
        let snapshotWindow = Swift.min(
            maximumConcurrentSnapshots,
            requests.count
        )
        return await withTaskGroup(
            of: SnapshotPreparation.self,
            returning: SnapshotRunResult.self
        ) { group in
            var nextAdmissionIndex = 0
            var nextEmissionIndex = 0
            var admissionOpen = true
            var buffered: [Int: SnapshotPreparation] = [:]
            buffered.reserveCapacity(snapshotWindow)

            while nextAdmissionIndex < snapshotWindow {
                let requestIndex = nextAdmissionIndex
                let request = requests[requestIndex]
                nextAdmissionIndex += 1
                snapshotAttempts &+= 1
                group.addTask {
                    let startedAt = clock.now
                    let frame = await snapshot(request.surfaceRevision)
                    return SnapshotPreparation(
                        requestIndex: requestIndex,
                        frame: frame,
                        duration: startedAt.duration(to: clock.now)
                    )
                }
            }

            while var preparation = await group.next() {
                snapshotDuration.record(preparation.duration)
                if admissionOpen,
                   (generation != flushGeneration || isCancelled || Task.isCancelled)
                {
                    admissionOpen = false
                    buffered.removeAll(keepingCapacity: false)
                    group.cancelAll()
                }

                guard admissionOpen else {
                    // The late result and its immutable frame leave this
                    // iteration immediately. Continue draining every started
                    // child so no snapshot lease escapes the structured group.
                    continue
                }

                let completedRequestIndex = preparation.requestIndex
                buffered[completedRequestIndex] = preparation
                // The buffer is now the sole publisher-owned reference to the
                // immutable frame; do not let this result local retain a lease
                // across the refill below.
                preparation.frame = nil
                while admissionOpen {
                    let shouldContinue: Bool
                    do {
                        guard let ordered = buffered.removeValue(
                            forKey: nextEmissionIndex
                        ) else {
                            break
                        }
                        shouldContinue = await processSnapshotPreparation(
                            consume ordered,
                            request: requests[nextEmissionIndex],
                            flushGeneration: flushGeneration
                        )
                    }
                    // The ordered preparation's lexical scope has ended, so
                    // its lease is gone before a replacement child starts.
                    nextEmissionIndex += 1
                    if !shouldContinue {
                        admissionOpen = false
                        buffered.removeAll(keepingCapacity: false)
                        group.cancelAll()
                    }
                    if admissionOpen,
                       nextAdmissionIndex < requests.count,
                       nextAdmissionIndex - nextEmissionIndex
                           < snapshotWindow
                    {
                        let requestIndex = nextAdmissionIndex
                        let request = requests[requestIndex]
                        nextAdmissionIndex += 1
                        snapshotAttempts &+= 1
                        group.addTask {
                            let startedAt = clock.now
                            let frame = await snapshot(request.surfaceRevision)
                            return SnapshotPreparation(
                                requestIndex: requestIndex,
                                frame: frame,
                                duration: startedAt.duration(to: clock.now)
                            )
                        }
                    }
                }
            }

            return SnapshotRunResult(
                completedAllRequests: admissionOpen
                    && nextAdmissionIndex == requests.count
                    && nextEmissionIndex == requests.count
                    && buffered.isEmpty,
                admittedRequestCount: nextAdmissionIndex
            )
        }
    }

    /// Validates and publishes exactly one ordered preparation. Keeping the
    /// frame inside this helper ensures its immutable IOSurface lease is
    /// released before the TaskGroup driver refills the admission window.
    private func processSnapshotPreparation(
        _ preparation: consuming SnapshotPreparation,
        request: Request,
        flushGeneration: UInt64
    ) async -> Bool {
        guard generation == flushGeneration,
              !isCancelled,
              !Task.isCancelled
        else {
            return false
        }
        guard let frame = preparation.frame else {
            staleSnapshots &+= 1
            return true
        }
        guard isCurrent(request),
              canPrepare(request.surfaceRevision.surfaceID),
              frameCovers(frame, request: request)
        else {
            staleSnapshots &+= 1
            forceFullDamage.insert(request.surfaceRevision.surfaceID)
            return true
        }
        let replacement = pending[request.surfaceRevision.surfaceID]
        if let replacement {
            let replacementLifecycle = replacement.surfaceRevision.lifecycleGeneration
            guard replacement.invalidationGeneration == request.invalidationGeneration,
                  replacementLifecycle == request.surfaceRevision.lifecycleGeneration
            else {
                staleSnapshots &+= 1
                return true
            }
        }
        guard frameMatchesSubmittedRevision(
            frame,
            request: request,
            replacement: replacement
        ) else {
            // The surface advanced beyond every revision this publisher
            // observed. Wait for its commit event instead of publishing a
            // possible intermediate state from a multi-rectangle command.
            forceFullDamage.insert(request.surfaceRevision.surfaceID)
            return true
        }
        if replacement != nil {
            removePendingCovered(
                by: frame,
                invalidationGeneration: request.invalidationGeneration
            )
            // A different revision from this lifecycle that is not covered
            // remains pending; it does not invalidate the immutable snapshot.
        }
        var publishedFrame = frame
        if forceFullDamage.remove(frame.surfaceID) != nil {
            var fullDamage = SurfaceDamageJournal(
                width: frame.width,
                height: frame.height
            )
            fullDamage.markFull()
            publishedFrame = frame.withPublicationDamage(fullDamage)
        }
        if waitsForConsumption {
            preparedRevisions[frame.surfaceID] = frame.surfaceRevision
        }
        let emitStartedAt = clock.now
        await emit(publishedFrame)
        emitDuration.record(emitStartedAt.duration(to: clock.now))
        guard generation == flushGeneration,
              !isCancelled,
              !Task.isCancelled
        else {
            return false
        }
        if isCurrent(request) {
            lastEmittedRevisions[frame.surfaceID] = frame.surfaceRevision
            removePendingCovered(
                by: frame,
                invalidationGeneration: request.invalidationGeneration
            )
        }
        emittedFrames &+= 1
        if frame.ioSurfaceFrame == nil {
            emittedCPUOnlyFrames &+= 1
        } else {
            emittedIOSurfaceFrames &+= 1
        }
        return true
    }

    private func restoreQueuedRequestsAfterAbortedFlush(
        _ requests: [Request],
        admittedRequestCount: Int
    ) {
        var restoredSurfaceIDs: [UInt32] = []
        restoredSurfaceIDs.reserveCapacity(requests.count)
        for (requestIndex, request) in requests.enumerated() {
            guard requestIndex >= admittedRequestCount else {
                continue
            }
            let surfaceID = request.surfaceRevision.surfaceID
            guard pending[surfaceID] == nil,
                  pending.count < maximumPendingSurfaces,
                  isCurrent(request),
                  lastEmittedRevisions[surfaceID].map({
                      isNewer(request.surfaceRevision, than: $0)
                  }) ?? true
            else {
                continue
            }
            pending[surfaceID] = request
            restoredSurfaceIDs.append(surfaceID)
        }
        guard !restoredSurfaceIDs.isEmpty else { return }
        let restored = Set(restoredSurfaceIDs)
        order.removeAll { restored.contains($0) }
        order.insert(contentsOf: restoredSurfaceIDs, at: 0)
    }

    private func isCurrent(_ request: Request) -> Bool {
        (invalidationGenerations[request.surfaceRevision.surfaceID] ?? 0)
            == request.invalidationGeneration
    }

    private func canPrepare(_ surfaceID: UInt32) -> Bool {
        demandedSurfaces.contains(surfaceID)
            && (!waitsForConsumption || preparedRevisions[surfaceID] == nil)
    }

    private func frameCovers(_ frame: FrameSnapshot, request: Request) -> Bool {
        frame.surfaceID == request.surfaceRevision.surfaceID
            && frame.lifecycleGeneration == request.surfaceRevision.lifecycleGeneration
            && frame.revision >= request.surfaceRevision.revision
    }

    private func frameMatchesSubmittedRevision(
        _ frame: FrameSnapshot,
        request: Request,
        replacement: Request?
    ) -> Bool {
        if frame.surfaceRevision == request.surfaceRevision {
            return true
        }
        return frame.surfaceRevision == replacement?.surfaceRevision
    }

    private func removePendingCovered(
        by frame: FrameSnapshot,
        invalidationGeneration: UInt64
    ) {
        guard let replacement = pending[frame.surfaceID],
              replacement.invalidationGeneration == invalidationGeneration,
              replacement.surfaceRevision.lifecycleGeneration == frame.lifecycleGeneration,
              frame.revision >= replacement.surfaceRevision.revision
        else {
            return
        }
        pending.removeValue(forKey: frame.surfaceID)
        order.removeAll { $0 == frame.surfaceID }
    }

    private func isNewer(_ lhs: SurfaceRevision, than rhs: SurfaceRevision) -> Bool {
        if lhs.lifecycleGeneration != rhs.lifecycleGeneration {
            return lhs.lifecycleGeneration > rhs.lifecycleGeneration
        }
        return lhs.revision > rhs.revision
    }
}
