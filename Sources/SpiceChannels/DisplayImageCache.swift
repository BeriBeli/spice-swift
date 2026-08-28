import Foundation
import SpiceCore
import SpiceProtocol
import SpiceRenderer

package enum DisplayImageCacheReservationMode: Sendable, Equatable {
    case cache
    case replace
}

package struct DisplayImageCacheMutation: ~Copyable, Sendable {
    fileprivate let token: UInt64
}

package enum DisplayImageCacheStageOutcome: Sendable, Equatable {
    case staged
    case invalidated
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
    package let pendingMutationCount: Int
    package let pendingReservationCount: Int
    package let queuedMutationCount: Int
    package let mutationRetainedBytes: Int
    package let pendingInvalidatedReservationCount: Int
    package let pendingWaiterCount: Int
    package let referenceCounts: [UInt64: UInt32]
}

package actor DisplayImageCache {
    private struct Entry: Sendable {
        let bitmap: RawBitmap
        let lossy: Bool
        let referenceCount: UInt32
    }

    private struct MutationRequest {
        let id: UInt64
        let lossy: Bool
        let mode: DisplayImageCacheReservationMode
        let retainedByteCount: Int
        var invalidated: Bool
        var stagedBitmap: RawBitmap?
        var continuation: CheckedContinuation<Result<UInt64, ChannelError>, Never>?
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
    private let maximumQueuedMutations: Int
    private var entries: [UInt64: Entry] = [:]
    private var committedBytes = 0
    private var nextMutationToken: UInt64 = 0
    private var mutations: [UInt64: MutationRequest] = [:]
    private var activeMutationTokensByImageID: [UInt64: UInt64] = [:]
    private var queuedMutationTokensByImageID: [UInt64: [UInt64]] = [:]
    private var queuedMutationCount = 0
    private var mutationRetainedBytes = 0
    private var reservedBytes = 0
    private var nextWaiterID: UInt64 = 0
    private var waiters: [UInt64: Waiter] = [:]
    private var retainedBytes = 0
    private var isClosed = false

    package init(
        maximumEntries: Int = 256,
        maximumBytes: Int = 256 * 1_024 * 1_024,
        maximumWaiters: Int = 64,
        maximumQueuedMutations: Int = 64
    ) {
        self.maximumEntries = max(1, maximumEntries)
        self.maximumBytes = max(1, maximumBytes)
        self.maximumWaiters = min(64, max(1, maximumWaiters))
        self.maximumQueuedMutations = min(64, max(1, maximumQueuedMutations))
    }

    /// Registers cache mutation ordering before source resolution or decode.
    /// Commands for one image ID acquire the active slot in FIFO order.
    package func begin(
        id: UInt64,
        lossy: Bool,
        mode: DisplayImageCacheReservationMode,
        retainedByteCount: Int = 0
    ) async throws(ChannelError) -> DisplayImageCacheMutation {
        guard !Task.isCancelled else {
            throw .transport(.cancelled)
        }
        guard !isClosed else {
            throw .transport(.connectionClosed)
        }
        guard retainedByteCount >= 0 else {
            throw .protocolViolation("negative image cache mutation retained byte count")
        }
        guard mode != .replace || !lossy else {
            throw .protocolViolation("CACHE_REPLACE_ME source must be lossless")
        }
        try validateTemporaryCapacity(adding: retainedByteCount)

        let isQueued = activeMutationTokensByImageID[id] != nil
        if isQueued {
            guard queuedMutationCount < maximumQueuedMutations else {
                throw .protocolViolation("image cache mutation queue limit exceeded")
            }
        } else {
            try validateActiveMutationSlot(for: id)
        }

        let token = nextMutationToken
        let (followingToken, overflow) = token.addingReportingOverflow(1)
        guard !overflow else {
            throw .protocolViolation("image cache mutation token overflow")
        }
        nextMutationToken = followingToken
        mutationRetainedBytes += retainedByteCount
        mutations[token] = MutationRequest(
            id: id,
            lossy: lossy,
            mode: mode,
            retainedByteCount: retainedByteCount,
            invalidated: false,
            stagedBitmap: nil,
            continuation: nil
        )

        guard isQueued else {
            activeMutationTokensByImageID[id] = token
            return DisplayImageCacheMutation(token: token)
        }

        queuedMutationTokensByImageID[id, default: []].append(token)
        queuedMutationCount += 1
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<Result<UInt64, ChannelError>, Never>) in
                guard !Task.isCancelled else {
                    cancelPendingMutation(token: token)
                    continuation.resume(returning: .failure(.transport(.cancelled)))
                    return
                }
                guard var request = mutations[token] else {
                    continuation.resume(returning: .failure(
                        isClosed
                            ? .transport(.connectionClosed)
                            : .protocolViolation("image cache cleared")
                    ))
                    return
                }
                if activeMutationTokensByImageID[request.id] == token {
                    continuation.resume(returning: .success(token))
                    return
                }
                request.continuation = continuation
                mutations[token] = request
            }
        } onCancel: {
            Task { await self.cancelPendingMutation(token: token) }
        }

        switch result {
        case .success:
            guard !Task.isCancelled else {
                _ = takeActiveMutation(token: token)
                throw .transport(.cancelled)
            }
            return DisplayImageCacheMutation(token: token)
        case let .failure(error):
            throw error
        }
    }

    /// Stages the decoded bitmap while retaining the active FIFO slot.
    @discardableResult
    package func stage(
        _ mutation: borrowing DisplayImageCacheMutation,
        bitmap: RawBitmap
    ) throws(ChannelError) -> DisplayImageCacheStageOutcome {
        guard var request = mutations[mutation.token],
              activeMutationTokensByImageID[request.id] == mutation.token
        else {
            throw isClosed ? .transport(.connectionClosed) : .invalidState
        }
        guard request.stagedBitmap == nil else {
            throw .invalidState
        }
        guard !request.invalidated else {
            return .invalidated
        }

        switch request.mode {
        case .cache:
            if let referenceCount = entries[request.id]?.referenceCount {
                guard referenceCount < UInt32.max else {
                    throw .protocolViolation("image cache reference count overflow")
                }
            }
        case .replace:
            guard let existing = entries[request.id], existing.lossy else {
                throw .protocolViolation(
                    "CACHE_REPLACE_ME requires a committed lossy cached image"
                )
            }
        }

        let bitmapByteCount = bitmap.pixels.count
        try validateTemporaryCapacity(adding: bitmapByteCount)
        try validateProjectedCapacity(
            addingID: request.id,
            bitmapByteCount: bitmapByteCount
        )
        reservedBytes += bitmapByteCount
        request.stagedBitmap = bitmap
        mutations[mutation.token] = request
        return .staged
    }

    /// Compatibility convenience for callers that already own a decoded bitmap.
    /// Display protocol execution uses `begin` before decode so invalidation ordering
    /// is established before any asynchronous source work starts.
    package func reserve(
        id: UInt64,
        bitmap: RawBitmap,
        lossy: Bool,
        mode: DisplayImageCacheReservationMode
    ) async throws(ChannelError) -> DisplayImageCacheMutation {
        let mutation = try await begin(id: id, lossy: lossy, mode: mode)
        do {
            _ = try stage(mutation, bitmap: bitmap)
            return consume mutation
        } catch {
            abort(consume mutation)
            throw error
        }
    }

    /// Finalizes a staged mutation after its Surface mutation has succeeded.
    /// Invalidation never makes this post-Surface operation throw.
    @discardableResult
    package func commit(
        _ mutation: consuming DisplayImageCacheMutation
    ) -> DisplayImageCacheCommitOutcome {
        guard let request = takeActiveMutation(token: mutation.token) else {
            return .discarded
        }
        guard !request.invalidated else {
            return .invalidated
        }
        guard let bitmap = request.stagedBitmap else {
            assertionFailure("uninvalidated image cache mutation committed before stage")
            return .discarded
        }

        let referenceCount: UInt32
        switch request.mode {
        case .cache:
            if let existing = entries[request.id] {
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
            guard let existing = entries[request.id], existing.lossy else {
                assertionFailure("validated replacement target changed without invalidation")
                return .discarded
            }
            referenceCount = existing.referenceCount
        }
        replaceEntry(
            id: request.id,
            with: Entry(
                bitmap: bitmap,
                lossy: request.lossy,
                referenceCount: referenceCount
            )
        )
        resumeReadyWaiters(for: request.id)
        return .committed
    }

    package func abort(_ mutation: consuming DisplayImageCacheMutation) {
        _ = takeActiveMutation(token: mutation.token)
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
        try validateTemporaryCapacity(adding: retainedByteCount)
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
                } else {
                    do {
                        try validateTemporaryCapacity(adding: retainedByteCount)
                        retainedBytes += retainedByteCount
                        waiters[waiterID] = Waiter(
                            id: waiterID,
                            imageID: id,
                            requirement: requirement,
                            retainedByteCount: retainedByteCount,
                            continuation: continuation
                        )
                    } catch {
                        guard let channelError = error as? ChannelError else {
                            assertionFailure("unexpected image cache waiter error: \(error)")
                            continuation.resume(returning: .failure(.invalidState))
                            return
                        }
                        continuation.resume(returning: .failure(channelError))
                    }
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
        if let active = activeMutationTokensByImageID[id] {
            mutations[active]?.invalidated = true
        }
        for token in queuedMutationTokensByImageID[id] ?? [] {
            mutations[token]?.invalidated = true
        }
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
        let tokens = Array(mutations.keys)
        for token in tokens {
            mutations[token]?.invalidated = true
        }
        removeAllState(
            waiterError: .protocolViolation("image cache invalidated"),
            closesCache: false,
            discardsMutations: false
        )
    }

    package func clear() {
        removeAllState(
            waiterError: .protocolViolation("image cache cleared"),
            closesCache: false,
            discardsMutations: true
        )
    }

    package func close() {
        guard !isClosed else { return }
        removeAllState(
            waiterError: .transport(.connectionClosed),
            closesCache: true,
            discardsMutations: true
        )
    }

    package func diagnosticsSnapshot() -> DisplayImageCacheDiagnostics {
        DisplayImageCacheDiagnostics(
            entryCount: entries.count,
            committedBytes: committedBytes,
            reservedBytes: reservedBytes,
            retainedBytes: retainedBytes,
            pendingMutationCount: mutations.count,
            pendingReservationCount: activeMutationTokensByImageID.count,
            queuedMutationCount: queuedMutationCount,
            mutationRetainedBytes: mutationRetainedBytes,
            pendingInvalidatedReservationCount: mutations.values.reduce(into: 0) {
                count, mutation in
                if mutation.invalidated { count += 1 }
            },
            pendingWaiterCount: waiters.count,
            referenceCounts: entries.mapValues(\.referenceCount)
        )
    }

    private func validateActiveMutationSlot(for id: UInt64) throws(ChannelError) {
        var projectedIDs = Set(entries.keys)
        projectedIDs.formUnion(activeMutationTokensByImageID.keys)
        projectedIDs.insert(id)
        guard projectedIDs.count <= maximumEntries else {
            throw .protocolViolation("image cache entry limit exceeded")
        }
    }

    private func validateTemporaryCapacity(adding byteCount: Int) throws(ChannelError) {
        var usedBytes = retainedBytes
        let (withMutations, mutationOverflow) = usedBytes.addingReportingOverflow(
            mutationRetainedBytes
        )
        guard !mutationOverflow else {
            throw .protocolViolation("image cache temporary byte count overflow")
        }
        usedBytes = withMutations
        let (withReservations, reservationOverflow) = usedBytes.addingReportingOverflow(
            reservedBytes
        )
        guard !reservationOverflow, withReservations <= maximumBytes,
              byteCount <= maximumBytes - withReservations
        else {
            throw .protocolViolation("image cache temporary byte limit exceeded")
        }
    }

    private func validateProjectedCapacity(
        addingID: UInt64,
        bitmapByteCount: Int
    ) throws(ChannelError) {
        var maximumBytesByID = entries.mapValues { $0.bitmap.pixels.count }
        for mutation in mutations.values {
            guard let bitmap = mutation.stagedBitmap else { continue }
            maximumBytesByID[mutation.id] = max(
                maximumBytesByID[mutation.id] ?? 0,
                bitmap.pixels.count
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

    private func takeActiveMutation(token: UInt64) -> MutationRequest? {
        guard let request = mutations[token],
              activeMutationTokensByImageID[request.id] == token
        else {
            return nil
        }
        mutations.removeValue(forKey: token)
        activeMutationTokensByImageID.removeValue(forKey: request.id)
        releaseMutationBytes(request)
        promoteNextMutation(for: request.id)
        return request
    }

    private func removeQueuedMutation(token: UInt64) -> MutationRequest? {
        guard let request = mutations[token],
              activeMutationTokensByImageID[request.id] != token,
              var queue = queuedMutationTokensByImageID[request.id],
              let index = queue.firstIndex(of: token)
        else {
            return nil
        }
        queue.remove(at: index)
        if queue.isEmpty {
            queuedMutationTokensByImageID.removeValue(forKey: request.id)
        } else {
            queuedMutationTokensByImageID[request.id] = queue
        }
        queuedMutationCount -= 1
        mutations.removeValue(forKey: token)
        releaseMutationBytes(request)
        return request
    }

    private func cancelPendingMutation(token: UInt64) {
        if let request = removeQueuedMutation(token: token) {
            request.continuation?.resume(returning: .failure(.transport(.cancelled)))
            return
        }
        _ = takeActiveMutation(token: token)
    }

    private func promoteNextMutation(for id: UInt64) {
        guard activeMutationTokensByImageID[id] == nil,
              var queue = queuedMutationTokensByImageID[id]
        else {
            return
        }
        while let token = queue.first {
            queue.removeFirst()
            queuedMutationCount -= 1
            guard var request = mutations[token] else { continue }
            if queue.isEmpty {
                queuedMutationTokensByImageID.removeValue(forKey: id)
            } else {
                queuedMutationTokensByImageID[id] = queue
            }
            activeMutationTokensByImageID[id] = token
            let continuation = request.continuation
            request.continuation = nil
            mutations[token] = request
            continuation?.resume(returning: .success(token))
            return
        }
        queuedMutationTokensByImageID.removeValue(forKey: id)
    }

    private func releaseMutationBytes(_ request: MutationRequest) {
        mutationRetainedBytes -= request.retainedByteCount
        if let bitmap = request.stagedBitmap {
            reservedBytes -= bitmap.pixels.count
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
        discardsMutations: Bool
    ) {
        entries.removeAll(keepingCapacity: true)
        committedBytes = 0
        let mutationContinuations: [CheckedContinuation<
            Result<UInt64, ChannelError>,
            Never
        >]
        if discardsMutations {
            mutationContinuations = mutations.values.compactMap(\.continuation)
            mutations.removeAll(keepingCapacity: true)
            activeMutationTokensByImageID.removeAll(keepingCapacity: true)
            queuedMutationTokensByImageID.removeAll(keepingCapacity: true)
            queuedMutationCount = 0
            mutationRetainedBytes = 0
            reservedBytes = 0
        } else {
            mutationContinuations = []
        }
        let pendingWaiters = Array(waiters.values)
        waiters.removeAll(keepingCapacity: false)
        retainedBytes = 0
        if closesCache {
            isClosed = true
        }
        for continuation in mutationContinuations {
            continuation.resume(returning: .failure(waiterError))
        }
        for waiter in pendingWaiters {
            waiter.continuation.resume(returning: .failure(waiterError))
        }
    }
}
