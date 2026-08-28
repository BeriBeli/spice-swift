import Foundation
import SpiceIOSurface
import Synchronization

package enum SurfaceBackingKind: Sendable, Equatable {
    case data
    case unifiedIOSurface
}

package enum SurfaceBackingPolicy: @unchecked Sendable {
    case automatic
    case dataOnly
    case revisionedIOSurface(RevisionedIOSurfacePool)
}

package struct DataSurfaceBacking: Sendable {
    package var pixels: Data

    package init(pixels: consuming Data) {
        self.pixels = pixels
    }
}

package struct SurfaceMemoryBudgetMetrics: Sendable, Equatable {
    package let allocatedBytes: Int
    package let maximumBytes: Int
}

/// Shared canonical Surface-Data accounting for every Display channel in one session.
/// Each live Surface owns one lease, so destroy, resize, connection teardown,
/// and failed construction release their reservation automatically.
package final class SurfaceMemoryBudget: Sendable {
    private struct State {
        var allocatedBytes = 0
    }

    package let maximumBytes: Int
    private let state = Mutex(State())

    package init(maximumBytes: Int = 256 * 1_024 * 1_024) {
        self.maximumBytes = max(0, maximumBytes)
    }

    func checkout(bytes: Int) -> SurfaceMemoryLease? {
        guard bytes >= 0 else { return nil }
        let reserved = state.withLock { state -> Bool in
            let (total, overflow) = state.allocatedBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= maximumBytes else { return false }
            state.allocatedBytes = total
            return true
        }
        guard reserved else { return nil }
        return SurfaceMemoryLease(bytes: bytes, budget: self)
    }

    package func metrics() -> SurfaceMemoryBudgetMetrics {
        state.withLock {
            SurfaceMemoryBudgetMetrics(
                allocatedBytes: $0.allocatedBytes,
                maximumBytes: maximumBytes
            )
        }
    }

    fileprivate func release(bytes: Int) {
        state.withLock { state in
            precondition(state.allocatedBytes >= bytes)
            state.allocatedBytes -= bytes
        }
    }
}

package final class SurfaceMemoryLease: Sendable {
    private let bytes: Int
    private let budget: SurfaceMemoryBudget

    init(bytes: Int, budget: SurfaceMemoryBudget) {
        self.bytes = bytes
        self.budget = budget
    }

    deinit {
        budget.release(bytes: bytes)
    }
}

/// Bounded journal used to patch a lagging IOSurface revision directly from
/// the packed CPU reference backing.
package struct SurfaceDamageJournal: Sendable, Equatable {
    private static let maximumRectangles = 64

    private let surfaceWidth: Int
    private let surfaceHeight: Int
    private var rectangles: [PixelRect] = []
    private var coversFullSurface: Bool

    package init(width: Int, height: Int, initiallyFull: Bool = false) {
        surfaceWidth = width
        surfaceHeight = height
        coversFullSurface = initiallyFull
    }

    package var isEmpty: Bool {
        !coversFullSurface && rectangles.isEmpty
    }

    package var copyRectangles: [PixelRect] {
        if isFullFrame {
            return [PixelRect(x: 0, y: 0, width: surfaceWidth, height: surfaceHeight)]
        }
        return rectangles
    }

    package var isFullFrame: Bool {
        coversFullSurface || coveredAreaReachesHalfSurface()
    }

    package mutating func append(_ rectangle: PixelRect) {
        guard !coversFullSurface else {
            return
        }

        var merged = rectangle
        var index = 0
        while index < rectangles.count {
            let existing = rectangles[index]
            if existing.contains(merged) {
                return
            }
            if merged.contains(existing) {
                rectangles.remove(at: index)
                index = 0
                continue
            }
            if let losslessUnion = existing.losslessUnion(with: merged) {
                merged = losslessUnion
                rectangles.remove(at: index)
                index = 0
                continue
            }
            index += 1
        }
        rectangles.append(merged)

        if rectangles.count > Self.maximumRectangles {
            markFull()
        }
    }

    package mutating func markFull() {
        coversFullSurface = true
        rectangles.removeAll(keepingCapacity: false)
    }

    package mutating func clear() {
        coversFullSurface = false
        rectangles.removeAll(keepingCapacity: true)
    }

    package mutating func merge(_ other: SurfaceDamageJournal) {
        if other.isFullFrame {
            markFull()
            return
        }
        for rectangle in other.copyRectangles {
            append(rectangle)
        }
    }

    private func coveredAreaReachesHalfSurface() -> Bool {
        guard !rectangles.isEmpty else {
            return false
        }
        let (surfaceArea, surfaceOverflow) = surfaceWidth.multipliedReportingOverflow(
            by: surfaceHeight
        )
        guard !surfaceOverflow else {
            return true
        }

        var areaUpperBound = 0
        for rectangle in rectangles {
            let (area, areaOverflow) = rectangle.width.multipliedReportingOverflow(
                by: rectangle.height
            )
            let (sum, sumOverflow) = areaUpperBound.addingReportingOverflow(area)
            guard !areaOverflow, !sumOverflow else { return true }
            areaUpperBound = sum
        }
        let (doubledUpperBound, upperBoundOverflow) = areaUpperBound
            .multipliedReportingOverflow(by: 2)
        guard upperBoundOverflow || doubledUpperBound >= surfaceArea else {
            return false
        }

        // Damage is queried once per publication but appended many times. Keep
        // append O(64) and compute exact union coverage only at that boundary;
        // this avoids promoting touching L-shaped damage through its much larger
        // bounding box.
        let xEdges = Set(rectangles.flatMap { [$0.x, $0.x + $0.width] }).sorted()
        var coveredArea = 0
        for edgeIndex in 0..<(xEdges.count - 1) {
            let left = xEdges[edgeIndex]
            let right = xEdges[edgeIndex + 1]
            let width = right - left
            guard width > 0 else { continue }
            let intervals = rectangles.compactMap { rectangle -> (Int, Int)? in
                guard rectangle.x < right, rectangle.x + rectangle.width > left else {
                    return nil
                }
                return (rectangle.y, rectangle.y + rectangle.height)
            }.sorted { lhs, rhs in
                lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 < rhs.0
            }
            guard var current = intervals.first else { continue }
            var coveredHeight = 0
            for interval in intervals.dropFirst() {
                if interval.0 <= current.1 {
                    current.1 = max(current.1, interval.1)
                } else {
                    coveredHeight += current.1 - current.0
                    current = interval
                }
            }
            coveredHeight += current.1 - current.0
            let (stripArea, stripOverflow) = width.multipliedReportingOverflow(by: coveredHeight)
            let (sum, sumOverflow) = coveredArea.addingReportingOverflow(stripArea)
            guard !stripOverflow, !sumOverflow else { return true }
            coveredArea = sum
        }
        let (doubled, doubledOverflow) = coveredArea.multipliedReportingOverflow(by: 2)
        return doubledOverflow || doubled >= surfaceArea
    }
}

/// Retains enough committed damage to advance a released ring slot without a
/// full IOSurface-to-IOSurface blit. A normal three-slot ring can lag by at
/// most three committed publications; a slower candidate outside this bounded
/// history safely degrades to a full upload from the CPU reference backing.
package struct SurfaceRevisionDamageHistory: Sendable, Equatable {
    private static let maximumCommittedRevisions = 3

    private struct Record: Sendable, Equatable {
        let revision: UInt64
        let damage: SurfaceDamageJournal
    }

    private let surfaceWidth: Int
    private let surfaceHeight: Int
    private var baseRevision: UInt64
    private var records: [Record] = []

    package init(width: Int, height: Int, baseRevision: UInt64 = 0) {
        surfaceWidth = width
        surfaceHeight = height
        self.baseRevision = baseRevision
    }

    package func catchUpJournal(
        from candidateRevision: UInt64?,
        pending: SurfaceDamageJournal
    ) -> SurfaceDamageJournal {
        var result = SurfaceDamageJournal(width: surfaceWidth, height: surfaceHeight)
        guard let candidateRevision, candidateRevision >= baseRevision else {
            result.markFull()
            return result
        }
        for record in records where record.revision > candidateRevision {
            result.merge(record.damage)
        }
        result.merge(pending)
        return result
    }

    package mutating func commit(
        _ damage: SurfaceDamageJournal,
        revision: UInt64
    ) {
        guard !damage.isEmpty else { return }
        records.append(Record(revision: revision, damage: damage))
        while records.count > Self.maximumCommittedRevisions {
            baseRevision = max(baseRevision, records.removeFirst().revision)
        }
    }

    package mutating func reset(at revision: UInt64) {
        baseRevision = revision
        records.removeAll(keepingCapacity: true)
    }
}

package struct UnifiedIOSurfaceBacking: @unchecked Sendable {
    package let pool: RevisionedIOSurfacePool
    package let namespace: RevisionedIOSurfaceNamespace
    package var current: RevisionedIOSurfaceRevision?
    package var damageJournal: SurfaceDamageJournal
    package var damageHistory: SurfaceRevisionDamageHistory

    package init(
        pool: RevisionedIOSurfacePool,
        namespace: RevisionedIOSurfaceNamespace,
        width: Int,
        height: Int
    ) {
        self.pool = pool
        self.namespace = namespace
        current = nil
        damageJournal = SurfaceDamageJournal(
            width: width,
            height: height,
            initiallyFull: true
        )
        damageHistory = SurfaceRevisionDamageHistory(width: width, height: height)
    }
}

/// Tracks byte-exact Data and immutable IOSurface representations. Either may
/// be canonical: eligible CPU kernels continue directly from an IOSurface
/// revision while leaving `dataRevision` stale, and Data-canonical mutations
/// retain bounded damage for the next IOSurface publication.
/// This dual representation keeps native video and CPU drawing on one revision
/// chain without exposing CoreVideo or mutable IOSurface handles publicly.
package struct SurfaceStorage: @unchecked Sendable {
    package var dataBacking: DataSurfaceBacking
    package var unifiedBacking: UnifiedIOSurfaceBacking?
    package var dataRevision: UInt64
    /// Damage not yet attached to a desktop publication. Unlike the
    /// IOSurface catch-up journal this exists for every backing kind and is
    /// cleared only by `SurfaceStore.publicationSnapshot`.
    package var publicationDamageJournal: SurfaceDamageJournal

    package init(
        pixels: consuming Data,
        width: Int,
        height: Int,
        revisionedPool: RevisionedIOSurfacePool?,
        revisionedNamespace: RevisionedIOSurfaceNamespace
    ) {
        dataBacking = DataSurfaceBacking(pixels: pixels)
        unifiedBacking = revisionedPool.map {
            UnifiedIOSurfaceBacking(
                pool: $0,
                namespace: revisionedNamespace,
                width: width,
                height: height
            )
        }
        dataRevision = 0
        publicationDamageJournal = SurfaceDamageJournal(
            width: width,
            height: height,
            initiallyFull: true
        )
    }

    package var kind: SurfaceBackingKind {
        unifiedBacking == nil ? .data : .unifiedIOSurface
    }

    package var pixels: Data {
        _read {
            yield dataBacking.pixels
        }
        _modify {
            yield &dataBacking.pixels
        }
    }

    package mutating func recordDamage(_ rectangle: PixelRect, revision: UInt64) {
        dataRevision = revision
        unifiedBacking?.damageJournal.append(rectangle)
        publicationDamageJournal.append(rectangle)
    }

    package mutating func recordFullDamage(revision: UInt64) {
        dataRevision = revision
        unifiedBacking?.damageJournal.markFull()
        publicationDamageJournal.markFull()
    }

    /// Direct IOSurface mutations already contain the complete next revision,
    /// so only the publication journal needs their destination damage.
    package mutating func recordPublicationDamage(_ rectangle: PixelRect) {
        publicationDamageJournal.append(rectangle)
    }

    package mutating func disableUnifiedBacking(surfaceID: UInt32) {
        if let unifiedBacking {
            unifiedBacking.pool.retire(
                namespace: unifiedBacking.namespace,
                surfaceID: surfaceID
            )
        }
        unifiedBacking = nil
    }
}

private extension PixelRect {
    func contains(_ other: PixelRect) -> Bool {
        x <= other.x
            && y <= other.y
            && x + width >= other.x + other.width
            && y + height >= other.y + other.height
    }

    /// Returns a union only when it is itself a rectangle with no added area.
    /// Edge/corner contact with different spans stays separate so the upload
    /// journal never expands an L shape to its bounding box.
    func losslessUnion(with other: PixelRect) -> PixelRect? {
        if y == other.y, height == other.height,
           x <= other.x + other.width, other.x <= x + width
        {
            let left = min(x, other.x)
            let right = max(x + width, other.x + other.width)
            return PixelRect(x: left, y: y, width: right - left, height: height)
        }
        if x == other.x, width == other.width,
           y <= other.y + other.height, other.y <= y + height
        {
            let top = min(y, other.y)
            let bottom = max(y + height, other.y + other.height)
            return PixelRect(x: x, y: top, width: width, height: bottom - top)
        }
        return nil
    }
}
