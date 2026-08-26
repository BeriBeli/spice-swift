import Foundation
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceRenderer

@Suite("Session image cache")
struct DisplayImageCacheTests {
    @Test func pendingResolveCompletesOnlyAfterReservationCommit() async throws {
        let cache = DisplayImageCache(maximumEntries: 2, maximumBytes: 16)
        let bitmap = cacheBitmap([1, 2, 3, 4])
        let reservation = try await cache.reserve(
            id: 1,
            bitmap: bitmap,
            lossy: false,
            mode: .cache
        )
        let resolve = Task {
            try await cache.resolve(id: 1, requirement: .any)
        }
        await expectCacheDiagnostics(cache) {
            $0.pendingReservationCount == 1
                && $0.reservedBytes == 4
                && $0.pendingWaiterCount == 1
        }

        #expect(await cache.commit(reservation) == .committed)

        #expect(try await resolve.value == bitmap)
        let diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 1)
        #expect(diagnostics.committedBytes == 4)
        #expect(diagnostics.reservedBytes == 0)
        #expect(diagnostics.retainedBytes == 0)
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.pendingWaiterCount == 0)
        #expect(diagnostics.referenceCounts == [1: 1])
    }

    @Test func cancellingPendingResolveRemovesWaiterAndRetainedBytes() async throws {
        let cache = DisplayImageCache(maximumEntries: 2, maximumBytes: 8)
        let reservation = try await cache.reserve(
            id: 2,
            bitmap: cacheBitmap([1, 2, 3, 4]),
            lossy: false,
            mode: .cache
        )
        let resolve = Task {
            try await cache.resolve(
                id: 2,
                requirement: .any,
                retainedByteCount: 3
            )
        }
        await expectCacheDiagnostics(cache) {
            $0.pendingWaiterCount == 1 && $0.retainedBytes == 3
        }

        resolve.cancel()
        await #expect(throws: ChannelError.transport(.cancelled)) {
            try await resolve.value
        }
        let diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.pendingWaiterCount == 0)
        #expect(diagnostics.retainedBytes == 0)
        #expect(diagnostics.pendingReservationCount == 1)
        await cache.abort(reservation)
    }

    @Test func clearAndCloseWakePendingResolvesWithoutPublishingReservations() async throws {
        let clearCache = DisplayImageCache(maximumEntries: 2, maximumBytes: 16)
        let clearReservation = try await clearCache.reserve(
            id: 3,
            bitmap: cacheBitmap([1, 2, 3, 4]),
            lossy: false,
            mode: .cache
        )
        let clearedResolve = Task {
            try await clearCache.resolve(id: 3, requirement: .any)
        }
        await expectCacheDiagnostics(clearCache) { $0.pendingWaiterCount == 1 }
        await clearCache.clear()
        await #expect(throws: ChannelError.protocolViolation("image cache cleared")) {
            try await clearedResolve.value
        }
        let cleared = await clearCache.diagnosticsSnapshot()
        #expect(cleared.entryCount == 0)
        #expect(cleared.pendingReservationCount == 0)
        #expect(cleared.pendingWaiterCount == 0)
        #expect(cleared.retainedBytes == 0)
        #expect(await clearCache.commit(clearReservation) == .discarded)

        let reusable = try await clearCache.reserve(
            id: 4,
            bitmap: cacheBitmap([5, 6, 7, 8]),
            lossy: false,
            mode: .cache
        )
        await clearCache.commit(reusable)
        #expect(try await clearCache.resolve(id: 4, requirement: .any).pixels == Data([5, 6, 7, 8]))

        let closeCache = DisplayImageCache(maximumEntries: 1, maximumBytes: 8)
        let closeReservation = try await closeCache.reserve(
            id: 5,
            bitmap: cacheBitmap([9, 10, 11, 12]),
            lossy: false,
            mode: .cache
        )
        let closedResolve = Task {
            try await closeCache.resolve(id: 5, requirement: .any)
        }
        await expectCacheDiagnostics(closeCache) { $0.pendingWaiterCount == 1 }
        await closeCache.close()
        await #expect(throws: ChannelError.transport(.connectionClosed)) {
            try await closedResolve.value
        }
        await #expect(throws: ChannelError.transport(.connectionClosed)) {
            _ = try await closeCache.resolve(id: 5, requirement: .any)
        }
        #expect(await closeCache.commit(closeReservation) == .discarded)
    }

    @Test func closedCacheCannotBeReopenedByClearOrInvalidateAll() async throws {
        let clearedAfterClose = DisplayImageCache(maximumEntries: 1, maximumBytes: 8)
        await clearedAfterClose.close()
        await clearedAfterClose.clear()
        await expectCacheRemainsClosed(
            clearedAfterClose,
            id: 50,
            bitmap: cacheBitmap([1, 2, 3, 4])
        )

        let invalidatedAfterClose = DisplayImageCache(maximumEntries: 1, maximumBytes: 8)
        await invalidatedAfterClose.close()
        await invalidatedAfterClose.invalidateAll()
        await expectCacheRemainsClosed(
            invalidatedAfterClose,
            id: 51,
            bitmap: cacheBitmap([5, 6, 7, 8])
        )
    }

    @Test func limitsPendingResolvesToSixtyFourWaiters() async throws {
        let cache = DisplayImageCache(
            maximumEntries: 1,
            maximumBytes: 1_024,
            maximumWaiters: 64
        )
        let reservation = try await cache.reserve(
            id: 6,
            bitmap: cacheBitmap([1, 2, 3, 4]),
            lossy: false,
            mode: .cache
        )
        let waiters = (0..<64).map { _ in
            Task { () -> Result<RawBitmap, ChannelError> in
                do {
                    return .success(try await cache.resolve(id: 6, requirement: .any))
                } catch let error as ChannelError {
                    return .failure(error)
                } catch {
                    return .failure(.invalidState)
                }
            }
        }
        await expectCacheDiagnostics(cache) { $0.pendingWaiterCount == 64 }

        await #expect(throws: ChannelError.self) {
            _ = try await cache.resolve(id: 6, requirement: .any)
        }
        #expect(await cache.diagnosticsSnapshot().pendingWaiterCount == 64)

        for waiter in waiters { waiter.cancel() }
        for waiter in waiters { _ = await waiter.value }
        #expect(await cache.diagnosticsSnapshot().pendingWaiterCount == 0)
        await cache.abort(reservation)
    }

    @Test func pendingRetainedBytesNeverExceedCacheByteBudget() async throws {
        let cache = DisplayImageCache(maximumEntries: 2, maximumBytes: 8)
        let first = Task {
            try await cache.resolve(
                id: 7,
                requirement: .any,
                retainedByteCount: 8
            )
        }
        await expectCacheDiagnostics(cache) {
            $0.pendingWaiterCount == 1 && $0.retainedBytes == 8
        }

        await #expect(throws: ChannelError.self) {
            _ = try await cache.resolve(
                id: 8,
                requirement: .any,
                retainedByteCount: 1
            )
        }
        let diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.retainedBytes == 8)
        #expect(diagnostics.retainedBytes <= 8)
        #expect(diagnostics.pendingWaiterCount == 1)

        first.cancel()
        await #expect(throws: ChannelError.transport(.cancelled)) {
            try await first.value
        }
        #expect(await cache.diagnosticsSnapshot().retainedBytes == 0)
    }

    @Test func reservationsKeepCapacityRefcountsAndAbortAtomic() async throws {
        let cache = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let original = cacheBitmap([1, 2, 3, 4])
        let pending = try await cache.reserve(
            id: 9,
            bitmap: original,
            lossy: false,
            mode: .cache
        )

        await #expect(throws: ChannelError.self) {
            _ = try await cache.reserve(
                id: 10,
                bitmap: original,
                lossy: false,
                mode: .cache
            )
        }
        var diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.pendingReservationCount == 1)
        #expect(diagnostics.committedBytes == 0)
        #expect(diagnostics.reservedBytes == 4)

        await cache.abort(pending)
        diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.committedBytes == 0)
        #expect(diagnostics.reservedBytes == 0)

        let inserted = try await cache.reserve(
            id: 9,
            bitmap: original,
            lossy: false,
            mode: .cache
        )
        await cache.commit(inserted)
        let duplicate = try await cache.reserve(
            id: 9,
            bitmap: original,
            lossy: false,
            mode: .cache
        )
        await cache.commit(duplicate)
        diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 1)
        #expect(diagnostics.committedBytes == 4)
        #expect(diagnostics.referenceCounts == [9: 2])

        await cache.invalidate(id: 9)
        #expect(try await cache.resolve(id: 9, requirement: .any) == original)
        #expect(await cache.diagnosticsSnapshot().referenceCounts == [9: 1])

        await cache.invalidate(id: 9)
        diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.committedBytes == 0)
        #expect(diagnostics.referenceCounts.isEmpty)
    }

    @Test func invalidationLinearizesBeforePendingReservationCommit() async throws {
        let targeted = DisplayImageCache(maximumEntries: 2, maximumBytes: 8)
        let targetedReservation = try await targeted.reserve(
            id: 20,
            bitmap: cacheBitmap([1, 2, 3, 4]),
            lossy: false,
            mode: .cache
        )
        #expect(await targeted.diagnosticsSnapshot().reservedBytes == 4)

        await targeted.invalidate(id: 20)
        #expect(await targeted.commit(targetedReservation) == .invalidated)
        var diagnostics = await targeted.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.committedBytes == 0)
        #expect(diagnostics.reservedBytes == 0)
        #expect(diagnostics.pendingReservationCount == 0)

        let invalidatedAll = DisplayImageCache(maximumEntries: 2, maximumBytes: 8)
        let globalReservation = try await invalidatedAll.reserve(
            id: 21,
            bitmap: cacheBitmap([5, 6, 7, 8]),
            lossy: false,
            mode: .cache
        )
        #expect(await invalidatedAll.diagnosticsSnapshot().reservedBytes == 4)

        await invalidatedAll.invalidateAll()
        #expect(await invalidatedAll.commit(globalReservation) == .invalidated)
        diagnostics = await invalidatedAll.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.committedBytes == 0)
        #expect(diagnostics.reservedBytes == 0)
        #expect(diagnostics.pendingReservationCount == 0)
    }

    @Test func nonexistentTargetedInvalidationsDoNotRetainTombstones() async {
        let cache = DisplayImageCache(maximumEntries: 2, maximumBytes: 8)

        for id in UInt64(10_000)..<UInt64(20_000) {
            await cache.invalidate(id: id)
        }

        let diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.pendingInvalidatedReservationCount == 0)
        #expect(diagnostics.committedBytes == 0)
        #expect(diagnostics.reservedBytes == 0)
    }

    @Test func invalidationTracksOnlyBoundedPendingReservations() async throws {
        let targeted = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let targetedReservation = try await targeted.reserve(
            id: 40,
            bitmap: cacheBitmap([1, 2, 3, 4]),
            lossy: false,
            mode: .cache
        )
        await targeted.invalidate(id: 40)
        var diagnostics = await targeted.diagnosticsSnapshot()
        #expect(diagnostics.pendingReservationCount == 1)
        #expect(diagnostics.pendingInvalidatedReservationCount == 1)
        #expect(diagnostics.reservedBytes == 4)

        #expect(await targeted.commit(targetedReservation) == .invalidated)
        diagnostics = await targeted.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.pendingInvalidatedReservationCount == 0)
        #expect(diagnostics.reservedBytes == 0)

        let global = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let globalReservation = try await global.reserve(
            id: 41,
            bitmap: cacheBitmap([5, 6, 7, 8]),
            lossy: false,
            mode: .cache
        )
        await global.invalidateAll()
        diagnostics = await global.diagnosticsSnapshot()
        #expect(diagnostics.pendingReservationCount == 1)
        #expect(diagnostics.pendingInvalidatedReservationCount == 1)
        #expect(diagnostics.reservedBytes == 4)

        #expect(await global.commit(globalReservation) == .invalidated)
        diagnostics = await global.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 0)
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.pendingInvalidatedReservationCount == 0)
        #expect(diagnostics.reservedBytes == 0)
    }

    @Test func invalidatedReservationTrackingIsReleasedByAbortClearAndClose() async throws {
        let aborted = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let abortedReservation = try await aborted.reserve(
            id: 50,
            bitmap: cacheBitmap([1, 2, 3, 4]),
            lossy: false,
            mode: .cache
        )
        await aborted.invalidate(id: 50)
        #expect(await aborted.diagnosticsSnapshot().pendingInvalidatedReservationCount == 1)
        await aborted.abort(abortedReservation)
        #expect(await aborted.diagnosticsSnapshot().pendingInvalidatedReservationCount == 0)

        let cleared = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let clearedReservation = try await cleared.reserve(
            id: 51,
            bitmap: cacheBitmap([5, 6, 7, 8]),
            lossy: false,
            mode: .cache
        )
        await cleared.invalidate(id: 51)
        #expect(await cleared.diagnosticsSnapshot().pendingInvalidatedReservationCount == 1)
        await cleared.clear()
        var diagnostics = await cleared.diagnosticsSnapshot()
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.pendingInvalidatedReservationCount == 0)
        #expect(diagnostics.reservedBytes == 0)
        #expect(await cleared.commit(clearedReservation) == .discarded)

        let closed = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let closedReservation = try await closed.reserve(
            id: 52,
            bitmap: cacheBitmap([9, 10, 11, 12]),
            lossy: false,
            mode: .cache
        )
        await closed.invalidateAll()
        #expect(await closed.diagnosticsSnapshot().pendingInvalidatedReservationCount == 1)
        await closed.close()
        diagnostics = await closed.diagnosticsSnapshot()
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.pendingInvalidatedReservationCount == 0)
        #expect(diagnostics.reservedBytes == 0)
        #expect(await closed.commit(closedReservation) == .discarded)
    }

    @Test func pendingReservationsAreExclusivePerIDAndBoundedByActualBytes() async throws {
        let cache = DisplayImageCache(maximumEntries: 3, maximumBytes: 8)
        let first = try await cache.reserve(
            id: 30,
            bitmap: cacheBitmap([1, 2, 3, 4]),
            lossy: false,
            mode: .cache
        )
        let afterFirst = await cache.diagnosticsSnapshot()
        #expect(afterFirst.pendingReservationCount == 1)
        #expect(afterFirst.reservedBytes == 4)

        await #expect(throws: ChannelError.self) {
            _ = try await cache.reserve(
                id: 30,
                bitmap: cacheBitmap([5, 6, 7, 8]),
                lossy: false,
                mode: .cache
            )
        }
        #expect(await cache.diagnosticsSnapshot() == afterFirst)

        let second = try await cache.reserve(
            id: 31,
            bitmap: cacheBitmap([9, 10, 11, 12]),
            lossy: false,
            mode: .cache
        )
        let atBudget = await cache.diagnosticsSnapshot()
        #expect(atBudget.pendingReservationCount == 2)
        #expect(atBudget.reservedBytes == 8)
        await #expect(throws: ChannelError.self) {
            _ = try await cache.reserve(
                id: 32,
                bitmap: cacheBitmap([13, 14, 15, 16]),
                lossy: false,
                mode: .cache
            )
        }
        #expect(await cache.diagnosticsSnapshot() == atBudget)

        await cache.abort(first)
        #expect(await cache.diagnosticsSnapshot().reservedBytes == 4)
        #expect(await cache.commit(second) == .committed)
        var diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.reservedBytes == 0)
        #expect(diagnostics.committedBytes == 4)

        let returnedBudget = try await cache.reserve(
            id: 32,
            bitmap: cacheBitmap([17, 18, 19, 20]),
            lossy: false,
            mode: .cache
        )
        #expect(await cache.diagnosticsSnapshot().reservedBytes == 4)
        await cache.abort(returnedBudget)
        diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.reservedBytes == 0)
        #expect(diagnostics.committedBytes == 4)
    }

    @Test func replaceAcceptsOnlyLosslessSourceForCommittedLossyEntry() async throws {
        let cache = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let lossy = cacheBitmap([1, 2, 3, 4])
        let lossless = cacheBitmap([5, 6, 7, 8])
        let inserted = try await cache.reserve(
            id: 10,
            bitmap: lossy,
            lossy: true,
            mode: .cache
        )
        #expect(await cache.commit(inserted) == .committed)

        let replacement = try await cache.reserve(
            id: 10,
            bitmap: lossless,
            lossy: false,
            mode: .replace
        )
        #expect(await cache.commit(replacement) == .committed)

        #expect(try await cache.resolve(id: 10, requirement: .lossless) == lossless)
        let diagnostics = await cache.diagnosticsSnapshot()
        #expect(diagnostics.entryCount == 1)
        #expect(diagnostics.committedBytes == 4)
        #expect(diagnostics.pendingReservationCount == 0)
        #expect(diagnostics.referenceCounts == [10: 1])
    }

    @Test func rejectedReplacementsLeaveCacheStateUnchanged() async throws {
        let missing = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let missingState = await missing.diagnosticsSnapshot()
        await #expect(throws: ChannelError.self) {
            _ = try await missing.reserve(
                id: 11,
                bitmap: cacheBitmap([1, 2, 3, 4]),
                lossy: false,
                mode: .replace
            )
        }
        #expect(await missing.diagnosticsSnapshot() == missingState)

        let losslessEntry = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let originalLossless = cacheBitmap([5, 6, 7, 8])
        let losslessReservation = try await losslessEntry.reserve(
            id: 12,
            bitmap: originalLossless,
            lossy: false,
            mode: .cache
        )
        await losslessEntry.commit(losslessReservation)
        let losslessState = await losslessEntry.diagnosticsSnapshot()
        await #expect(throws: ChannelError.self) {
            _ = try await losslessEntry.reserve(
                id: 12,
                bitmap: cacheBitmap([9, 10, 11, 12]),
                lossy: false,
                mode: .replace
            )
        }
        #expect(await losslessEntry.diagnosticsSnapshot() == losslessState)
        #expect(try await losslessEntry.resolve(id: 12, requirement: .lossless) == originalLossless)

        let lossySource = DisplayImageCache(maximumEntries: 1, maximumBytes: 4)
        let originalLossy = cacheBitmap([13, 14, 15, 16])
        let lossyReservation = try await lossySource.reserve(
            id: 13,
            bitmap: originalLossy,
            lossy: true,
            mode: .cache
        )
        await lossySource.commit(lossyReservation)
        let lossyState = await lossySource.diagnosticsSnapshot()
        await #expect(throws: ChannelError.self) {
            _ = try await lossySource.reserve(
                id: 13,
                bitmap: cacheBitmap([17, 18, 19, 20]),
                lossy: true,
                mode: .replace
            )
        }
        #expect(await lossySource.diagnosticsSnapshot() == lossyState)
        #expect(try await lossySource.resolve(id: 13, requirement: .any) == originalLossy)
    }
}

private func cacheBitmap(_ pixels: [UInt8]) -> RawBitmap {
    RawBitmap(
        format: .xRGB8888,
        width: 1,
        height: 1,
        stride: 4,
        topDown: true,
        pixels: Data(pixels)
    )
}

private func expectCacheDiagnostics(
    _ cache: DisplayImageCache,
    where predicate: (DisplayImageCacheDiagnostics) -> Bool
) async {
    for _ in 0..<1_000 {
        if predicate(await cache.diagnosticsSnapshot()) { return }
        await Task.yield()
    }
    Issue.record("cache diagnostics did not reach expected state")
}

private func expectCacheRemainsClosed(
    _ cache: DisplayImageCache,
    id: UInt64,
    bitmap: RawBitmap
) async {
    do {
        let reservation = try await cache.reserve(
            id: id,
            bitmap: bitmap,
            lossy: false,
            mode: .cache
        )
        Issue.record("closed cache accepted a reservation")
        await cache.abort(reservation)
    } catch let error {
        #expect(error == .transport(.connectionClosed))
    }

    let resolve = Task { () -> Result<RawBitmap, ChannelError> in
        do {
            return .success(try await cache.resolve(id: id, requirement: .any))
        } catch let error as ChannelError {
            return .failure(error)
        } catch {
            return .failure(.invalidState)
        }
    }
    for _ in 0..<1_000 {
        if await cache.diagnosticsSnapshot().pendingWaiterCount > 0 { break }
        await Task.yield()
    }
    let unexpectedlyPending = await cache.diagnosticsSnapshot().pendingWaiterCount > 0
    #expect(!unexpectedlyPending)
    if unexpectedlyPending {
        await cache.close()
    }
    #expect(await resolve.value == .failure(.transport(.connectionClosed)))
}
