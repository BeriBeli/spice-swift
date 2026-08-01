import Foundation
import SpiceRenderer

package struct DisplayFramePublisherMetrics: Sendable, Equatable {
    package var submissions: UInt64
    package var snapshotAttempts: UInt64
    package var emittedFrames: UInt64
    package var staleSnapshots: UInt64
    package var pendingEvictions: UInt64
    package var pendingSurfaces: Int

    package init(
        submissions: UInt64 = 0,
        snapshotAttempts: UInt64 = 0,
        emittedFrames: UInt64 = 0,
        staleSnapshots: UInt64 = 0,
        pendingEvictions: UInt64 = 0,
        pendingSurfaces: Int = 0
    ) {
        self.submissions = submissions
        self.snapshotAttempts = snapshotAttempts
        self.emittedFrames = emittedFrames
        self.staleSnapshots = staleSnapshots
        self.pendingEvictions = pendingEvictions
        self.pendingSurfaces = pendingSurfaces
    }

    package mutating func accumulate(_ other: Self) {
        submissions &+= other.submissions
        snapshotAttempts &+= other.snapshotAttempts
        emittedFrames &+= other.emittedFrames
        staleSnapshots &+= other.staleSnapshots
        pendingEvictions &+= other.pendingEvictions
        pendingSurfaces += other.pendingSurfaces
    }
}

package actor DisplayFramePublisher {
    package typealias Snapshot = @Sendable (SurfaceRevision) async -> FrameSnapshot?
    package typealias Emit = @Sendable (FrameSnapshot) async -> Void

    private struct Request: Sendable, Equatable {
        let surfaceRevision: SurfaceRevision
        let invalidationGeneration: UInt64
    }

    private let interval: Duration
    private let maximumPendingSurfaces: Int
    private let snapshot: Snapshot
    private let emit: Emit
    private let clock = ContinuousClock()
    private var pending: [UInt32: Request] = [:]
    private var order: [UInt32] = []
    private var invalidationGenerations: [UInt32: UInt64] = [:]
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var lastFlushStart: ContinuousClock.Instant?
    private var generation: UInt64 = 0
    private var submissions: UInt64 = 0
    private var snapshotAttempts: UInt64 = 0
    private var emittedFrames: UInt64 = 0
    private var staleSnapshots: UInt64 = 0
    private var pendingEvictions: UInt64 = 0

    package init(
        interval: Duration = .milliseconds(16),
        maximumPendingSurfaces: Int = 16,
        snapshot: @escaping Snapshot,
        emit: @escaping Emit
    ) {
        self.interval = interval
        self.maximumPendingSurfaces = max(1, maximumPendingSurfaces)
        self.snapshot = snapshot
        self.emit = emit
    }

    package func submit(_ surfaceRevision: SurfaceRevision) {
        submissions &+= 1
        let surfaceID = surfaceRevision.surfaceID
        let invalidationGeneration = invalidationGenerations[surfaceID] ?? 0
        if let existing = pending[surfaceID],
           existing.invalidationGeneration == invalidationGeneration,
           isNewer(existing.surfaceRevision, than: surfaceRevision)
        {
            return
        }

        if pending[surfaceID] == nil {
            if pending.count >= maximumPendingSurfaces, let oldest = order.first {
                pending.removeValue(forKey: oldest)
                order.removeFirst()
                pendingEvictions &+= 1
            }
            order.append(surfaceID)
        }
        pending[surfaceID] = Request(
            surfaceRevision: surfaceRevision,
            invalidationGeneration: invalidationGeneration
        )

        scheduleFlushIfNeeded()
    }

    private func scheduleFlushIfNeeded() {
        guard !pending.isEmpty, flushTask == nil, !isFlushing else { return }
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
            await self?.flush()
        }
    }

    package func remove(surfaceID: UInt32) {
        invalidationGenerations[surfaceID, default: 0] &+= 1
        pending.removeValue(forKey: surfaceID)
        order.removeAll { $0 == surfaceID }
    }

    package func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        guard !isFlushing else { return }
        await flush()
    }

    package func cancel() {
        generation &+= 1
        flushTask?.cancel()
        flushTask = nil
        isFlushing = false
        lastFlushStart = nil
        pending.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }

    package func metrics() -> DisplayFramePublisherMetrics {
        DisplayFramePublisherMetrics(
            submissions: submissions,
            snapshotAttempts: snapshotAttempts,
            emittedFrames: emittedFrames,
            staleSnapshots: staleSnapshots,
            pendingEvictions: pendingEvictions,
            pendingSurfaces: pending.count
        )
    }

    private func flush() async {
        guard !isFlushing else { return }
        let flushGeneration = generation
        isFlushing = true
        lastFlushStart = clock.now
        let requests = order.compactMap { pending[$0] }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        flushTask = nil

        for request in requests {
            snapshotAttempts &+= 1
            guard let frame = await snapshot(request.surfaceRevision) else {
                staleSnapshots &+= 1
                continue
            }
            guard generation == flushGeneration else { return }
            guard isCurrent(request), frame.surfaceRevision == request.surfaceRevision else {
                staleSnapshots &+= 1
                continue
            }
            if let replacement = pending[request.surfaceRevision.surfaceID] {
                guard replacement == request else {
                    staleSnapshots &+= 1
                    continue
                }
                pending.removeValue(forKey: request.surfaceRevision.surfaceID)
                order.removeAll { $0 == request.surfaceRevision.surfaceID }
            }
            await emit(frame)
            guard generation == flushGeneration else { return }
            emittedFrames &+= 1
        }
        guard generation == flushGeneration else { return }
        isFlushing = false
        scheduleFlushIfNeeded()
    }

    private func isCurrent(_ request: Request) -> Bool {
        (invalidationGenerations[request.surfaceRevision.surfaceID] ?? 0)
            == request.invalidationGeneration
    }

    private func isNewer(_ lhs: SurfaceRevision, than rhs: SurfaceRevision) -> Bool {
        if lhs.lifecycleGeneration != rhs.lifecycleGeneration {
            return lhs.lifecycleGeneration > rhs.lifecycleGeneration
        }
        return lhs.revision > rhs.revision
    }
}
