import Foundation
import SpiceCore
import SpiceProtocol
import SpiceRenderer

package enum DisplayImageCacheReservationMode: Sendable, Equatable {
    case cache
    case replace
}

package struct DisplayImageCacheReservation: ~Copyable, Sendable {
    fileprivate let token: UInt64
}

package enum DisplayImageCacheCommitOutcome: Sendable, Equatable {
    case committed
    case invalidated
    case discarded
}

package struct DisplayImageCacheDiagnostics: Sendable, Equatable {
    package let entryCount: Int
    package let committedBytes: Int
    package let reservedBytes: Int
    package let retainedBytes: Int
    package let pendingReservationCount: Int
    package let pendingWaiterCount: Int
    package let referenceCounts: [UInt64: UInt32]
}

package actor DisplayImageCache {
    private struct Entry: Sendable {
        let bitmap: RawBitmap
        let lossy: Bool
        let referenceCount: UInt32
    }

    private struct PendingReservation: Sendable {
        let id: UInt64
        let bitmap: RawBitmap
        let lossy: Bool
        let mode: DisplayImageCacheReservationMode
        let globalInvalidationGeneration: UInt64
        let imageInvalidationGeneration: UInt64
    }

    private struct Waiter {
        let id: UInt64
        let imageID: UInt64
        let requirement: SpiceCachedImageRequirement
        let retainedByteCount: Int
        let continuation: CheckedContinuation<Result<RawBitmap, ChannelError>, Never>
    }

    private let maximumEntries: Int
    private let maximumBytes: Int
    private let maximumWaiters: Int
    private var entries: [UInt64: Entry] = [:]
    private var committedBytes = 0
    private var nextReservationToken: UInt64 = 0
    private var reservations: [UInt64: PendingReservation] = [:]
    private var reservationTokensByImageID: [UInt64: UInt64] = [:]
    private var reservedBytes = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: Waiter] = [:]
    private var retainedBytes = 0
    private var globalInvalidationGeneration: UInt64 = 0
    private var imageInvalidationGenerations: [UInt64: UInt64] = [:]
    private var isClosed = false

    package init(
        maximumEntries: Int = 256,
        maximumBytes: Int = 256 * 1_024 * 1_024,
        maximumWaiters: Int = 64
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
        self.maximumWaiters = min(64, max(1, maximumWaiters))
    }

    package func reserve(
        id: UInt64,
        bitmap: RawBitmap,
        lossy: Bool,
        mode: DisplayImageCacheReservationMode
    ) throws(ChannelError) -> DisplayImageCacheReservation {
        guard !isClosed else {
            throw .transport(.connectionClosed)
        }
        guard mode != .replace || !lossy else {
            throw .protocolViolation("CACHE_REPLACE_ME source must be lossless")
        }
        guard reservationTokensByImageID[id] == nil else {
            throw .protocolViolation("image cache reservation already pending for image \(id)")
        }
        switch mode {
        case .cache:
            if let committedReferences = entries[id]?.referenceCount {
                guard committedReferences < UInt32.max else {
                    throw .protocolViolation("image cache reference count overflow")
                }
            }
        case .replace:
            guard let existing = entries[id], existing.lossy else {
                throw .protocolViolation(
                    "CACHE_REPLACE_ME requires a committed lossy cached image"
                )
            }
        }
        let bitmapByteCount = bitmap.pixels.count
        guard bitmapByteCount <= maximumBytes - reservedBytes else {
            throw .protocolViolation("image cache pending reservation byte limit exceeded")
        }
        try validateProjectedCapacity(addingID: id, bitmapByteCount: bitmapByteCount)

        let token = nextReservationToken
        let (followingToken, overflow) = token.addingReportingOverflow(1)
        guard !overflow else {
            throw .protocolViolation("image cache reservation token overflow")
        }
        let (nextReservedBytes, reservedByteOverflow) = reservedBytes.addingReportingOverflow(
            bitmapByteCount
        )
        guard !reservedByteOverflow else {
            throw .protocolViolation("image cache pending reservation byte count overflow")
        }
        nextReservationToken = followingToken
        reservedBytes = nextReservedBytes
        reservationTokensByImageID[id] = token
        reservations[token] = PendingReservation(
            id: id,
            bitmap: bitmap,
            lossy: lossy,
            mode: mode,
            globalInvalidationGeneration: globalInvalidationGeneration,
            imageInvalidationGeneration: imageInvalidationGenerations[id, default: 0]
        )
        return DisplayImageCacheReservation(token: token)
    }

    /// Finalizes a reservation after its Surface mutation has succeeded.
    ///
    /// Invalidation linearizes when its generation advances. A reservation
    /// admitted before that point can still finish its Surface mutation, but
    /// returns `.invalidated` and cannot republish the invalidated cache ID.
    /// Clear and close return `.discarded`. None of these teardown races make
    /// commit throw after the Surface has already changed.
    @discardableResult
    package func commit(
        _ reservation: consuming DisplayImageCacheReservation
    ) -> DisplayImageCacheCommitOutcome {
        guard let pending = takeReservation(token: reservation.token) else {
            return .discarded
        }
        guard pending.globalInvalidationGeneration == globalInvalidationGeneration,
              pending.imageInvalidationGeneration
                == imageInvalidationGenerations[pending.id, default: 0]
        else {
            return .invalidated
        }

        let referenceCount: UInt32
        switch pending.mode {
        case .cache:
            if let existing = entries[pending.id] {
                let (incremented, overflow) = existing.referenceCount.addingReportingOverflow(1)
                guard !overflow else {
                    assertionFailure("validated image cache reference count overflow")
                    return .discarded
                }
                referenceCount = incremented
            } else {
                referenceCount = 1
            }
        case .replace:
            guard let existing = entries[pending.id], existing.lossy else {
                assertionFailure("validated replacement target changed without invalidation")
                return .discarded
            }
            referenceCount = existing.referenceCount
        }
        replaceEntry(
            id: pending.id,
            with: Entry(
                bitmap: pending.bitmap,
                lossy: pending.lossy,
                referenceCount: referenceCount
            )
        )
        resumeReadyWaiters(for: pending.id)
        return .committed
    }

    package func abort(_ reservation: consuming DisplayImageCacheReservation) {
        _ = takeReservation(token: reservation.token)
    }

    private func takeReservation(token: UInt64) -> PendingReservation? {
        guard let pending = reservations.removeValue(forKey: token) else { return nil }
        if reservationTokensByImageID[pending.id] == token {
            reservationTokensByImageID.removeValue(forKey: pending.id)
        }
        reservedBytes -= pending.bitmap.pixels.count
        return pending
    }

    package func resolve(
        id: UInt64,
        requirement: SpiceCachedImageRequirement,
        retainedByteCount: Int = 0
    ) async throws(ChannelError) -> RawBitmap {
        guard !Task.isCancelled else {
            throw .transport(.cancelled)
        }
        guard !isClosed else {
            throw .transport(.connectionClosed)
        }
        guard retainedByteCount >= 0 else {
            throw .protocolViolation("negative image cache retained byte count")
        }
        if let bitmap = resolvedBitmap(id: id, requirement: requirement) {
            return bitmap
        }
        guard waiters.count < maximumWaiters else {
            throw .protocolViolation("image cache waiter limit exceeded")
        }
        guard retainedByteCount <= maximumBytes - retainedBytes else {
            throw .protocolViolation("image cache retained byte limit exceeded")
        }
        let waiterID = nextWaiterID
        let (followingWaiterID, overflow) = waiterID.addingReportingOverflow(1)
        guard !overflow else {
            throw .protocolViolation("image cache waiter ID overflow")
        }
        nextWaiterID = followingWaiterID

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<RawBitmap, ChannelError>, Never>) in
                if Task.isCancelled {
                    continuation.resume(returning: .failure(.transport(.cancelled)))
                } else if isClosed {
                    continuation.resume(returning: .failure(.transport(.connectionClosed)))
                } else if let bitmap = resolvedBitmap(id: id, requirement: requirement) {
                    continuation.resume(returning: .success(bitmap))
                } else if retainedByteCount > maximumBytes - retainedBytes {
                    continuation.resume(returning: .failure(
                        .protocolViolation("image cache retained byte limit exceeded")
                    ))
                } else {
                    retainedBytes += retainedByteCount
                    waiters[waiterID] = Waiter(
                        id: waiterID,
                        imageID: id,
                        requirement: requirement,
                        retainedByteCount: retainedByteCount,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: waiterID) }
        }
        return try result.get()
    }

    package func invalidate(id: UInt64) {
        invalidateOne(id: id)
    }

    package func invalidate(ids: [UInt64]) {
        for id in ids {
            invalidateOne(id: id)
        }
    }

    private func invalidateOne(id: UInt64) {
        imageInvalidationGenerations[id, default: 0] &+= 1
        if let entry = entries[id] {
            if entry.referenceCount > 1 {
                entries[id] = Entry(
                    bitmap: entry.bitmap,
                    lossy: entry.lossy,
                    referenceCount: entry.referenceCount - 1
                )
            } else {
                entries.removeValue(forKey: id)
                committedBytes -= entry.bitmap.pixels.count
            }
        }
        failWaiters(
            where: { $0.imageID == id },
            error: .protocolViolation("cached image \(id) invalidated")
        )
    }

    package func invalidateAll() {
        globalInvalidationGeneration &+= 1
        removeAllState(
            waiterError: .protocolViolation("image cache invalidated"),
            closesCache: false,
            discardsReservations: false
        )
    }

    package func clear() {
        removeAllState(
            waiterError: .protocolViolation("image cache cleared"),
            closesCache: false,
            discardsReservations: true
        )
    }

    package func close() {
        guard !isClosed else { return }
        removeAllState(
            waiterError: .transport(.connectionClosed),
            closesCache: true,
            discardsReservations: true
        )
    }

    package func diagnosticsSnapshot() -> DisplayImageCacheDiagnostics {
        DisplayImageCacheDiagnostics(
            entryCount: entries.count,
            committedBytes: committedBytes,
            reservedBytes: reservedBytes,
            retainedBytes: retainedBytes,
            pendingReservationCount: reservations.count,
            pendingWaiterCount: waiters.count,
            referenceCounts: entries.mapValues(\.referenceCount)
        )
    }

    private func validateProjectedCapacity(
        addingID: UInt64,
        bitmapByteCount: Int
    ) throws(ChannelError) {
        var maximumBytesByID = entries.mapValues { $0.bitmap.pixels.count }
        for reservation in reservations.values {
            maximumBytesByID[reservation.id] = max(
                maximumBytesByID[reservation.id] ?? 0,
                reservation.bitmap.pixels.count
            )
        }
        maximumBytesByID[addingID] = max(maximumBytesByID[addingID] ?? 0, bitmapByteCount)
        guard maximumBytesByID.count <= maximumEntries else {
            throw .protocolViolation("image cache entry limit exceeded")
        }
        var projectedBytes = 0
        for byteCount in maximumBytesByID.values {
            let (next, overflow) = projectedBytes.addingReportingOverflow(byteCount)
            guard !overflow else {
                throw .protocolViolation("image cache byte count overflow")
            }
            projectedBytes = next
        }
        guard projectedBytes <= maximumBytes else {
            throw .protocolViolation("image cache byte limit exceeded")
        }
    }

    private func resolvedBitmap(
        id: UInt64,
        requirement: SpiceCachedImageRequirement
    ) -> RawBitmap? {
        guard let entry = entries[id] else { return nil }
        guard requirement == .any || !entry.lossy else { return nil }
        return entry.bitmap
    }

    private func replaceEntry(id: UInt64, with entry: Entry) {
        if let previous = entries.updateValue(entry, forKey: id) {
            committedBytes -= previous.bitmap.pixels.count
        }
        committedBytes += entry.bitmap.pixels.count
        assert(committedBytes <= maximumBytes)
        assert(entries.count <= maximumEntries)
    }

    private func resumeReadyWaiters(for imageID: UInt64) {
        guard let entry = entries[imageID] else { return }
        let readyIDs: [UInt64] = waiters.compactMap { id, waiter in
            guard waiter.imageID == imageID,
                  waiter.requirement == .any || !entry.lossy
            else {
                return nil
            }
            return id
        }
        for id in readyIDs {
            takeWaiter(id: id)?.continuation.resume(returning: .success(entry.bitmap))
        }
    }

    private func cancelWaiter(id: UInt64) {
        takeWaiter(id: id)?.continuation.resume(
            returning: .failure(.transport(.cancelled))
        )
    }

    private func takeWaiter(id: UInt64) -> Waiter? {
        guard let waiter = waiters.removeValue(forKey: id) else { return nil }
        retainedBytes -= waiter.retainedByteCount
        return waiter
    }

    private func failWaiters(
        where predicate: (Waiter) -> Bool,
        error: ChannelError
    ) {
        let matchingIDs: [UInt64] = waiters.compactMap { id, waiter in
            predicate(waiter) ? id : nil
        }
        for id in matchingIDs {
            takeWaiter(id: id)?.continuation.resume(returning: .failure(error))
        }
    }

    private func removeAllState(
        waiterError: ChannelError,
        closesCache: Bool,
        discardsReservations: Bool
    ) {
        entries.removeAll(keepingCapacity: true)
        committedBytes = 0
        if discardsReservations {
            reservations.removeAll(keepingCapacity: true)
            reservationTokensByImageID.removeAll(keepingCapacity: true)
            reservedBytes = 0
        }
        let pendingWaiters = waiters.values
        waiters.removeAll(keepingCapacity: false)
        retainedBytes = 0
        if closesCache {
            isClosed = true
        }
        for waiter in pendingWaiters {
            waiter.continuation.resume(returning: .failure(waiterError))
        }
    }
}
