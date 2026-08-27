import Foundation

/// A bounded canonical pixel set represented as ordered horizontal bands.
///
/// Bands are ordered by increasing y, never overlap, and contain sorted,
/// disjoint x intervals. Adjacent bands with identical intervals are merged.
package struct PixelRegion: Sendable, Equatable, Sequence {
    package static let defaultMaximumInputClips = 4_096
    package static let defaultMaximumSegments = 65_536

    package struct XInterval: Sendable, Equatable {
        package let lowerBound: Int
        package let upperBound: Int

        package init(lowerBound: Int, upperBound: Int) {
            self.lowerBound = lowerBound
            self.upperBound = upperBound
        }
    }

    package struct Band: Sendable, Equatable {
        package let yRange: Range<Int>
        package let intervals: [XInterval]

        package init(yRange: Range<Int>, intervals: [XInterval]) {
            self.yRange = yRange
            self.intervals = intervals
        }
    }

    private enum Storage: Sendable, Equatable {
        case empty
        case rectangle(PixelRect)
        case bands([Band])
    }

    private struct Edges {
        let left: Int
        let top: Int
        let right: Int
        let bottom: Int

        var isEmpty: Bool { left == right || top == bottom }
    }

    private struct SweepEvent {
        let y: Int
        let leftIndex: Int
        let rightIndex: Int
        let delta: Int
    }

    /// Range-add coverage tree over compressed half-open x segments.
    private struct CoverageTree {
        let coordinates: [Int]
        var fullCoverCounts: [Int]
        var subtreeHasCoverage: [Bool]

        init(coordinates: [Int]) throws(RenderError) {
            self.coordinates = coordinates
            let leafCount = coordinates.count - 1
            let (nodeCapacity, overflow) = leafCount.multipliedReportingOverflow(by: 4)
            guard !overflow, nodeCapacity > 0 else { throw .integerOverflow }
            fullCoverCounts = [Int](repeating: 0, count: nodeCapacity)
            subtreeHasCoverage = [Bool](repeating: false, count: nodeCapacity)
        }

        mutating func add(
            _ delta: Int,
            to range: Range<Int>
        ) throws(RenderError) {
            try add(
                delta,
                queryLower: range.lowerBound,
                queryUpper: range.upperBound,
                node: 1,
                nodeLower: 0,
                nodeUpper: coordinates.count - 1
            )
        }

        func intervals() -> [XInterval] {
            var result: [XInterval] = []
            appendIntervals(
                node: 1,
                nodeLower: 0,
                nodeUpper: coordinates.count - 1,
                to: &result
            )
            return result
        }

        private mutating func add(
            _ delta: Int,
            queryLower: Int,
            queryUpper: Int,
            node: Int,
            nodeLower: Int,
            nodeUpper: Int
        ) throws(RenderError) {
            if queryLower <= nodeLower, nodeUpper <= queryUpper {
                let (next, overflow) = fullCoverCounts[node].addingReportingOverflow(delta)
                guard !overflow, next >= 0 else { throw .integerOverflow }
                fullCoverCounts[node] = next
                refresh(node: node, lower: nodeLower, upper: nodeUpper)
                return
            }
            let middle = nodeLower + (nodeUpper - nodeLower) / 2
            if queryLower < middle {
                try add(
                    delta,
                    queryLower: queryLower,
                    queryUpper: queryUpper,
                    node: node * 2,
                    nodeLower: nodeLower,
                    nodeUpper: middle
                )
            }
            if queryUpper > middle {
                try add(
                    delta,
                    queryLower: queryLower,
                    queryUpper: queryUpper,
                    node: node * 2 + 1,
                    nodeLower: middle,
                    nodeUpper: nodeUpper
                )
            }
            refresh(node: node, lower: nodeLower, upper: nodeUpper)
        }

        private mutating func refresh(node: Int, lower: Int, upper: Int) {
            if fullCoverCounts[node] > 0 {
                subtreeHasCoverage[node] = true
            } else if upper - lower == 1 {
                subtreeHasCoverage[node] = false
            } else {
                subtreeHasCoverage[node] = subtreeHasCoverage[node * 2]
                    || subtreeHasCoverage[node * 2 + 1]
            }
        }

        private func appendIntervals(
            node: Int,
            nodeLower: Int,
            nodeUpper: Int,
            to result: inout [XInterval]
        ) {
            guard subtreeHasCoverage[node] else { return }
            if fullCoverCounts[node] > 0 || nodeUpper - nodeLower == 1 {
                append(
                    XInterval(
                        lowerBound: coordinates[nodeLower],
                        upperBound: coordinates[nodeUpper]
                    ),
                    to: &result
                )
                return
            }
            let middle = nodeLower + (nodeUpper - nodeLower) / 2
            appendIntervals(
                node: node * 2,
                nodeLower: nodeLower,
                nodeUpper: middle,
                to: &result
            )
            appendIntervals(
                node: node * 2 + 1,
                nodeLower: middle,
                nodeUpper: nodeUpper,
                to: &result
            )
        }

        private func append(_ interval: XInterval, to result: inout [XInterval]) {
            if let previous = result.last, previous.upperBound == interval.lowerBound {
                result[result.count - 1] = XInterval(
                    lowerBound: previous.lowerBound,
                    upperBound: interval.upperBound
                )
            } else {
                result.append(interval)
            }
        }
    }

    package struct Iterator: IteratorProtocol {
        fileprivate let region: PixelRegion
        fileprivate var emittedInlineRectangle = false
        fileprivate var bandIndex = 0
        fileprivate var intervalIndex = 0

        package mutating func next() -> PixelRect? {
            switch region.storage {
            case .empty:
                return nil
            case let .rectangle(rectangle):
                guard !emittedInlineRectangle else { return nil }
                emittedInlineRectangle = true
                return rectangle
            case let .bands(bands):
                guard bandIndex < bands.count else { return nil }
                let band = bands[bandIndex]
                let interval = band.intervals[intervalIndex]
                intervalIndex += 1
                if intervalIndex == band.intervals.count {
                    bandIndex += 1
                    intervalIndex = 0
                }
                return PixelRect(
                    x: interval.lowerBound,
                    y: band.yRange.lowerBound,
                    width: interval.upperBound - interval.lowerBound,
                    height: band.yRange.upperBound - band.yRange.lowerBound
                )
            }
        }
    }

    private let storage: Storage

    package init(
        destination: PixelRect,
        surfaceBounds: PixelRect,
        clips: [PixelRect]?,
        maximumInputClips: Int = Self.defaultMaximumInputClips,
        maximumSegments: Int = Self.defaultMaximumSegments
    ) throws(RenderError) {
        guard maximumInputClips >= 0 else {
            throw .regionClipLimitExceeded(actual: 0, maximum: maximumInputClips)
        }
        guard maximumSegments >= 0 else {
            throw .regionSegmentLimitExceeded(actual: 0, maximum: maximumSegments)
        }
        let destinationEdges = try Self.checkedEdges(destination)
        let surfaceEdges = try Self.checkedEdges(surfaceBounds)
        if let clips, clips.count > maximumInputClips {
            throw .regionClipLimitExceeded(
                actual: clips.count,
                maximum: maximumInputClips
            )
        }

        let boundedDestination = try Self.intersection(destinationEdges, surfaceEdges)
        guard let clips else {
            storage = try Self.fastStorage(
                boundedDestination,
                maximumSegments: maximumSegments
            )
            return
        }

        if clips.count == 1 {
            let clip = try Self.checkedEdges(clips[0])
            let result: Edges?
            if let boundedDestination {
                result = try Self.intersection(boundedDestination, clip)
            } else {
                result = nil
            }
            storage = try Self.fastStorage(result, maximumSegments: maximumSegments)
            return
        }

        var intersections: [Edges] = []
        intersections.reserveCapacity(clips.count)
        for clipRectangle in clips {
            let clip = try Self.checkedEdges(clipRectangle)
            guard let boundedDestination,
                  let clipped = try Self.intersection(boundedDestination, clip),
                  !clipped.isEmpty
            else {
                continue
            }
            intersections.append(clipped)
        }

        switch intersections.count {
        case 0:
            storage = .empty
        case 1:
            storage = try Self.fastStorage(
                intersections[0],
                maximumSegments: maximumSegments
            )
        default:
            storage = try Self.normalizedStorage(
                intersections,
                maximumSegments: maximumSegments
            )
        }
    }

    package var isEmpty: Bool {
        if case .empty = storage { return true }
        return false
    }

    package var singleRectangle: PixelRect? {
        guard case let .rectangle(rectangle) = storage else { return nil }
        return rectangle
    }

    package var usesInlineRectangleStorage: Bool { singleRectangle != nil }

    package var bandCount: Int {
        switch storage {
        case .empty: 0
        case .rectangle: 1
        case let .bands(bands): bands.count
        }
    }

    package var segmentCount: Int {
        switch storage {
        case .empty: 0
        case .rectangle: 1
        case let .bands(bands): bands.reduce(into: 0) { $0 += $1.intervals.count }
        }
    }

    /// Semantic band view. The empty and inline-rectangle fast paths allocate
    /// no arrays until this diagnostic view is requested.
    package var bands: [Band] {
        switch storage {
        case .empty:
            []
        case let .rectangle(rectangle):
            [Band(
                yRange: rectangle.y..<(rectangle.y + rectangle.height),
                intervals: [XInterval(
                    lowerBound: rectangle.x,
                    upperBound: rectangle.x + rectangle.width
                )]
            )]
        case let .bands(bands):
            bands
        }
    }

    package func makeIterator() -> Iterator {
        Iterator(region: self)
    }

    private static func checkedEdges(_ rectangle: PixelRect) throws(RenderError) -> Edges {
        guard rectangle.width >= 0, rectangle.height >= 0 else {
            throw .invalidRectangle
        }
        let (right, rightOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
        let (bottom, bottomOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
        guard !rightOverflow, !bottomOverflow else {
            throw .integerOverflow
        }
        return Edges(
            left: rectangle.x,
            top: rectangle.y,
            right: right,
            bottom: bottom
        )
    }

    private static func intersection(_ lhs: Edges, _ rhs: Edges) throws(RenderError) -> Edges? {
        let left = Swift.max(lhs.left, rhs.left)
        let top = Swift.max(lhs.top, rhs.top)
        let right = Swift.min(lhs.right, rhs.right)
        let bottom = Swift.min(lhs.bottom, rhs.bottom)
        guard right > left, bottom > top else { return nil }
        return Edges(left: left, top: top, right: right, bottom: bottom)
    }

    private static func fastStorage(
        _ edges: Edges?,
        maximumSegments: Int
    ) throws(RenderError) -> Storage {
        guard let edges, !edges.isEmpty else { return .empty }
        guard maximumSegments >= 1 else {
            throw .regionSegmentLimitExceeded(actual: 1, maximum: maximumSegments)
        }
        return .rectangle(try rectangle(edges))
    }

    private static func rectangle(_ edges: Edges) throws(RenderError) -> PixelRect {
        let (width, widthOverflow) = edges.right.subtractingReportingOverflow(edges.left)
        let (height, heightOverflow) = edges.bottom.subtractingReportingOverflow(edges.top)
        guard !widthOverflow, !heightOverflow, width > 0, height > 0 else {
            throw widthOverflow || heightOverflow ? .integerOverflow : .invalidRectangle
        }
        return PixelRect(x: edges.left, y: edges.top, width: width, height: height)
    }

    private static func normalizedStorage(
        _ rectangles: [Edges],
        maximumSegments: Int
    ) throws(RenderError) -> Storage {
        let (coordinateCapacity, coordinateCapacityOverflow) = rectangles.count
            .multipliedReportingOverflow(by: 2)
        guard !coordinateCapacityOverflow else { throw .integerOverflow }
        var xCoordinates: [Int] = []
        xCoordinates.reserveCapacity(coordinateCapacity)
        for rectangle in rectangles {
            xCoordinates.append(rectangle.left)
            xCoordinates.append(rectangle.right)
        }
        xCoordinates.sort()
        var uniqueX: [Int] = []
        uniqueX.reserveCapacity(xCoordinates.count)
        for coordinate in xCoordinates where uniqueX.last != coordinate {
            uniqueX.append(coordinate)
        }

        var xIndices: [Int: Int] = [:]
        xIndices.reserveCapacity(uniqueX.count)
        for (index, coordinate) in uniqueX.enumerated() {
            xIndices[coordinate] = index
        }

        var events: [SweepEvent] = []
        events.reserveCapacity(coordinateCapacity)
        for rectangle in rectangles {
            guard let leftIndex = xIndices[rectangle.left],
                  let rightIndex = xIndices[rectangle.right]
            else {
                preconditionFailure("compressed region coordinate is missing")
            }
            events.append(SweepEvent(
                y: rectangle.top,
                leftIndex: leftIndex,
                rightIndex: rightIndex,
                delta: 1
            ))
            events.append(SweepEvent(
                y: rectangle.bottom,
                leftIndex: leftIndex,
                rightIndex: rightIndex,
                delta: -1
            ))
        }
        events.sort { lhs, rhs in
            if lhs.y != rhs.y { return lhs.y < rhs.y }
            if lhs.leftIndex != rhs.leftIndex { return lhs.leftIndex < rhs.leftIndex }
            if lhs.rightIndex != rhs.rightIndex { return lhs.rightIndex < rhs.rightIndex }
            return lhs.delta < rhs.delta
        }

        var coverage = try CoverageTree(coordinates: uniqueX)
        var bands: [Band] = []
        bands.reserveCapacity(Swift.max(0, Swift.min(events.count, maximumSegments)))
        var segmentCount = 0
        var eventIndex = 0
        while eventIndex < events.count {
            let y = events[eventIndex].y
            var nextEventIndex = eventIndex
            while nextEventIndex < events.count, events[nextEventIndex].y == y {
                let event = events[nextEventIndex]
                try coverage.add(event.delta, to: event.leftIndex..<event.rightIndex)
                nextEventIndex += 1
            }
            guard nextEventIndex < events.count else { break }
            let nextY = events[nextEventIndex].y
            eventIndex = nextEventIndex
            guard nextY > y else { continue }

            let intervals = coverage.intervals()
            guard !intervals.isEmpty else { continue }

            if let last = bands.last,
               last.yRange.upperBound == y,
               last.intervals == intervals
            {
                bands[bands.count - 1] = Band(
                    yRange: last.yRange.lowerBound..<nextY,
                    intervals: intervals
                )
                continue
            }

            let (nextSegmentCount, overflow) = segmentCount.addingReportingOverflow(
                intervals.count
            )
            guard !overflow else { throw .integerOverflow }
            guard nextSegmentCount <= maximumSegments else {
                throw .regionSegmentLimitExceeded(
                    actual: nextSegmentCount,
                    maximum: maximumSegments
                )
            }
            segmentCount = nextSegmentCount
            bands.append(Band(yRange: y..<nextY, intervals: intervals))
        }

        guard !bands.isEmpty else { return .empty }
        if bands.count == 1, bands[0].intervals.count == 1 {
            let band = bands[0]
            let interval = band.intervals[0]
            return .rectangle(try rectangle(Edges(
                left: interval.lowerBound,
                top: band.yRange.lowerBound,
                right: interval.upperBound,
                bottom: band.yRange.upperBound
            )))
        }
        return .bands(bands)
    }
}
