import Testing
@testable import SpiceRenderer

@Suite("PixelRegion canonical clipping")
struct PixelRegionTests {
    @Test func randomizedSmallRegionsMatchBitmapUnionOracle() throws {
        var generator = PixelRegionGenerator(seed: 0xa1_20_cafe_f00d_beef)

        for caseIndex in 0..<500 {
            let surfaceBounds = PixelRect(
                x: generator.next(in: -2...2),
                y: generator.next(in: -2...2),
                width: generator.next(in: 1...8),
                height: generator.next(in: 1...8)
            )
            let destination = PixelRect(
                x: generator.next(in: -6...10),
                y: generator.next(in: -6...10),
                width: generator.next(in: 0...10),
                height: generator.next(in: 0...10)
            )
            let clips: [PixelRect]?
            if caseIndex.isMultiple(of: 7) {
                clips = nil
            } else {
                var generated: [PixelRect] = []
                for clipIndex in 0..<generator.next(in: 0...12) {
                    if clipIndex.isMultiple(of: 4), !generated.isEmpty {
                        generated.append(generated[generator.next(in: 0...(generated.count - 1))])
                    } else {
                        generated.append(PixelRect(
                            x: generator.next(in: -8...12),
                            y: generator.next(in: -8...12),
                            width: generator.next(in: 0...10),
                            height: generator.next(in: 0...10)
                        ))
                    }
                }
                generator.shuffle(&generated)
                clips = generated
            }

            let region = try PixelRegion(
                destination: destination,
                surfaceBounds: surfaceBounds,
                clips: clips
            )
            let actualRectangles = Array(region)
            #expect(region.segmentCount == actualRectangles.count)
            expectCanonicalBands(region, caseIndex: caseIndex)

            var actualMask = Array(
                repeating: false,
                count: surfaceBounds.width * surfaceBounds.height
            )
            for rectangle in actualRectangles {
                #expect(rectangle.width > 0, "case \(caseIndex)")
                #expect(rectangle.height > 0, "case \(caseIndex)")
                for y in rectangle.y..<(rectangle.y + rectangle.height) {
                    for x in rectangle.x..<(rectangle.x + rectangle.width) {
                        #expect(contains(x: x, y: y, in: surfaceBounds), "case \(caseIndex)")
                        let maskIndex = (y - surfaceBounds.y) * surfaceBounds.width
                            + x - surfaceBounds.x
                        #expect(!actualMask[maskIndex], "overlapping output in case \(caseIndex)")
                        actualMask[maskIndex] = true
                    }
                }
            }

            var expectedMask: [Bool] = []
            expectedMask.reserveCapacity(surfaceBounds.width * surfaceBounds.height)
            for y in surfaceBounds.y..<(surfaceBounds.y + surfaceBounds.height) {
                for x in surfaceBounds.x..<(surfaceBounds.x + surfaceBounds.width) {
                    let insideClipUnion = clips.map { rectangles in
                        rectangles.contains { contains(x: x, y: y, in: $0) }
                    } ?? true
                    expectedMask.append(
                        contains(x: x, y: y, in: destination) && insideClipUnion
                    )
                }
            }
            #expect(actualMask == expectedMask, "bitmap differential case \(caseIndex)")
        }
    }

    @Test func noClipAndSingleRectangleUseInlineFastPath() throws {
        let surfaceBounds = PixelRect(x: 0, y: 0, width: 8, height: 6)
        let noClip = try PixelRegion(
            destination: PixelRect(x: -2, y: 1, width: 7, height: 8),
            surfaceBounds: surfaceBounds,
            clips: nil
        )
        #expect(noClip.singleRectangle == PixelRect(x: 0, y: 1, width: 5, height: 5))
        #expect(noClip.usesInlineRectangleStorage)
        #expect(noClip.bandCount == 1)
        #expect(noClip.segmentCount == 1)

        let singleClip = try PixelRegion(
            destination: PixelRect(x: 1, y: 1, width: 6, height: 4),
            surfaceBounds: surfaceBounds,
            clips: [PixelRect(x: 3, y: -4, width: 8, height: 7)]
        )
        #expect(singleClip.singleRectangle == PixelRect(x: 3, y: 1, width: 4, height: 2))
        #expect(singleClip.usesInlineRectangleStorage)
        #expect(Array(singleClip) == [PixelRect(x: 3, y: 1, width: 4, height: 2)])

        let emptyDestination = try PixelRegion(
            destination: PixelRect(x: Int.max, y: Int.min, width: 0, height: 4),
            surfaceBounds: surfaceBounds,
            clips: nil
        )
        #expect(emptyDestination.isEmpty)
        #expect(emptyDestination.segmentCount == 0)

        let emptyClip = try PixelRegion(
            destination: surfaceBounds,
            surfaceBounds: surfaceBounds,
            clips: [PixelRect(x: Int.max, y: Int.min, width: 0, height: 0)]
        )
        #expect(emptyClip.isEmpty)
        #expect(emptyClip.segmentCount == 0)
    }

    @Test func pathologicalMaximumClipInputNormalizesToOneSegment() throws {
        let bounds = PixelRect(x: 0, y: 0, width: 32, height: 32)
        var clips: [PixelRect] = []
        clips.reserveCapacity(4_096)
        for index in 0..<4_095 {
            clips.append(PixelRect(
                x: (index * 17) % 48 - 8,
                y: (index * 29) % 48 - 8,
                width: index.isMultiple(of: 5) ? 0 : 16,
                height: index.isMultiple(of: 7) ? 0 : 16
            ))
        }
        clips.insert(bounds, at: 2_047)

        let region = try PixelRegion(
            destination: bounds,
            surfaceBounds: bounds,
            clips: clips
        )
        #expect(region.singleRectangle == bounds)
        #expect(region.segmentCount == 1)

        clips.append(bounds)
        #expect(
            throws: RenderError.regionClipLimitExceeded(actual: 4_097, maximum: 4_096)
        ) {
            try PixelRegion(destination: bounds, surfaceBounds: bounds, clips: clips)
        }
    }

    @Test func normalizedSegmentLimitIsCheckedBeforeReturningARegion() throws {
        let bounds = PixelRect(x: 0, y: 0, width: 513, height: 512)
        let clips = segmentExplosionClips()

        #expect(
            throws: RenderError.regionSegmentLimitExceeded(actual: 65_789, maximum: 65_536)
        ) {
            try PixelRegion(destination: bounds, surfaceBounds: bounds, clips: clips)
        }

        let admitted = try PixelRegion(
            destination: bounds,
            surfaceBounds: bounds,
            clips: clips,
            maximumSegments: 70_000
        )
        #expect(admitted.segmentCount == 66_048)
        expectCanonicalBands(admitted, caseIndex: -1)
    }

    @Test func checkedHalfOpenCoordinatesRejectOverflowAndNegativeSizes() {
        let bounds = PixelRect(x: 0, y: 0, width: 8, height: 8)
        #expect(throws: RenderError.integerOverflow) {
            try PixelRegion(
                destination: PixelRect(x: Int.max, y: 0, width: 1, height: 1),
                surfaceBounds: bounds,
                clips: nil
            )
        }
        #expect(throws: RenderError.integerOverflow) {
            try PixelRegion(
                destination: bounds,
                surfaceBounds: bounds,
                clips: [PixelRect(x: 0, y: Int.max, width: 1, height: 1)]
            )
        }
        #expect(throws: RenderError.integerOverflow) {
            try PixelRegion(
                destination: bounds,
                surfaceBounds: PixelRect(x: Int.max, y: 0, width: 1, height: 1),
                clips: nil
            )
        }
        #expect(throws: RenderError.invalidRectangle) {
            try PixelRegion(
                destination: PixelRect(x: 0, y: 0, width: -1, height: 1),
                surfaceBounds: bounds,
                clips: nil
            )
        }
        #expect(throws: RenderError.invalidRectangle) {
            try PixelRegion(
                destination: bounds,
                surfaceBounds: bounds,
                clips: [PixelRect(x: 0, y: 0, width: 1, height: -1)]
            )
        }
    }

    private func segmentExplosionClips() -> [PixelRect] {
        let vertical = (0..<257).map { index in
            PixelRect(x: index * 2, y: 0, width: 1, height: 512)
        }
        let horizontal = (0..<256).map { index in
            PixelRect(x: 0, y: index * 2 + 1, width: 513, height: 1)
        }
        return vertical + horizontal
    }

    private func expectCanonicalBands(_ region: PixelRegion, caseIndex: Int) {
        var previousYUpperBound: Int?
        var previousIntervals: [PixelRegion.XInterval]?
        var countedSegments = 0
        for band in region.bands {
            #expect(!band.yRange.isEmpty, "case \(caseIndex)")
            if let previousYUpperBound {
                #expect(previousYUpperBound <= band.yRange.lowerBound, "case \(caseIndex)")
                if previousYUpperBound == band.yRange.lowerBound {
                    #expect(previousIntervals != band.intervals, "unmerged bands in case \(caseIndex)")
                }
            }
            var previousXUpperBound: Int?
            for interval in band.intervals {
                #expect(interval.lowerBound < interval.upperBound, "case \(caseIndex)")
                if let previousXUpperBound {
                    #expect(previousXUpperBound < interval.lowerBound, "case \(caseIndex)")
                }
                previousXUpperBound = interval.upperBound
                countedSegments += 1
            }
            #expect(!band.intervals.isEmpty, "case \(caseIndex)")
            previousYUpperBound = band.yRange.upperBound
            previousIntervals = band.intervals
        }
        #expect(countedSegments == region.segmentCount, "case \(caseIndex)")
        #expect(region.bandCount == region.bands.count, "case \(caseIndex)")
        #expect(region.isEmpty == region.bands.isEmpty, "case \(caseIndex)")
    }

    private func contains(x: Int, y: Int, in rectangle: PixelRect) -> Bool {
        rectangle.width > 0 && rectangle.height > 0
            && x >= rectangle.x && x < rectangle.x + rectangle.width
            && y >= rectangle.y && y < rectangle.y + rectangle.height
    }
}

private struct PixelRegionGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next(in range: ClosedRange<Int>) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let width = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(state % width)
    }

    mutating func shuffle<Element>(_ values: inout [Element]) {
        guard values.count > 1 else { return }
        for index in values.indices.dropLast().reversed() {
            let other = next(in: 0...index)
            values.swapAt(index, other)
        }
    }
}
