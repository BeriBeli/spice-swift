import Foundation
import SpiceRenderer

package struct DisplayFramePublisherMetrics: Sendable, Equatable {
    package var submissions: UInt64
    package var snapshotAttempts: UInt64
    package var emittedFrames: UInt64
    package var emittedIOSurfaceFrames: UInt64
    package var emittedCPUOnlyFrames: UInt64
    package var staleSnapshots: UInt64
    package var pendingEvictions: UInt64
    package var pendingSurfaces: Int

    package init(
        submissions: UInt64 = 0,
        snapshotAttempts: UInt64 = 0,
        emittedFrames: UInt64 = 0,
        emittedIOSurfaceFrames: UInt64 = 0,
        emittedCPUOnlyFrames: UInt64 = 0,
        staleSnapshots: UInt64 = 0,
        pendingEvictions: UInt64 = 0,
        pendingSurfaces: Int = 0
    ) {
        self.submissions = submissions
        self.snapshotAttempts = snapshotAttempts
        self.emittedFrames = emittedFrames
        self.emittedIOSurfaceFrames = emittedIOSurfaceFrames
        self.emittedCPUOnlyFrames = emittedCPUOnlyFrames
        self.staleSnapshots = staleSnapshots
        self.pendingEvictions = pendingEvictions
        self.pendingSurfaces = pendingSurfaces
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
    private var lastEmittedRevisions: [UInt32: SurfaceRevision] = [:]
    private var flushTask: Task<Void, Never>?
    private var isFlushing = false
    private var isCancelled = false
    private var lastFlushStart: ContinuousClock.Instant?
    private var generation: UInt64 = 0
    private var submissions: UInt64 = 0
    private var snapshotAttempts: UInt64 = 0
    private var emittedFrames: UInt64 = 0
    private var emittedIOSurfaceFrames: UInt64 = 0
    private var emittedCPUOnlyFrames: UInt64 = 0
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
        guard !isCancelled else { return }
        let surfaceID = surfaceRevision.surfaceID
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
        guard !isCancelled,
              !pending.isEmpty,
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
            await self?.flush()
        }
    }

    package func remove(surfaceID: UInt32) {
        invalidationGenerations[surfaceID, default: 0] &+= 1
        lastEmittedRevisions.removeValue(forKey: surfaceID)
        pending.removeValue(forKey: surfaceID)
        order.removeAll { $0 == surfaceID }
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
        pending.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
        lastEmittedRevisions.removeAll(keepingCapacity: false)
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
            pendingSurfaces: pending.count
        )
    }

    private func flush() async {
        guard !isCancelled, !isFlushing else { return }
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
            guard isCurrent(request), frameCovers(frame, request: request) else {
                staleSnapshots &+= 1
                continue
            }
            let replacement = pending[request.surfaceRevision.surfaceID]
            if let replacement {
                let replacementLifecycle = replacement.surfaceRevision.lifecycleGeneration
                guard replacement.invalidationGeneration == request.invalidationGeneration,
                      replacementLifecycle == request.surfaceRevision.lifecycleGeneration
                else {
                    staleSnapshots &+= 1
                    continue
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
                continue
            }
            if replacement != nil {
                removePendingCovered(
                    by: frame,
                    invalidationGeneration: request.invalidationGeneration
                )
                // A different revision from this lifecycle that is not covered
                // remains pending; it does not invalidate the immutable snapshot.
            }
            await emit(frame)
            guard generation == flushGeneration else { return }
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
        }
        guard generation == flushGeneration else { return }
        isFlushing = false
        scheduleFlushIfNeeded()
    }

    private func isCurrent(_ request: Request) -> Bool {
        (invalidationGenerations[request.surfaceRevision.surfaceID] ?? 0)
            == request.invalidationGeneration
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
