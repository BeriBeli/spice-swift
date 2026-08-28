import CoreVideo
import Foundation
import IOSurface
import Metal
import SpiceCodecs
import SpiceIOSurface
import SpiceVideoToolbox
import Testing
@testable import SpiceRenderer

@Suite("SurfaceStore", .serialized)
struct SurfaceStoreTests {
    @Test func createsFillsCopiesAndDestroysSurface() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 7, width: 3, height: 2, format: 32)
        try await store.fill(
            surfaceID: 7,
            rectangle: PixelRect(x: 0, y: 0, width: 2, height: 1),
            colorARGB: 0x0011_2233
        )
        try await store.copyBits(
            surfaceID: 7,
            destination: PixelRect(x: 1, y: 1, width: 2, height: 1),
            sourceX: 0,
            sourceY: 0
        )

        let snapshot = try await store.snapshot(surfaceID: 7)
        #expect(snapshot.width == 3)
        #expect(snapshot.height == 2)
        #expect(pixel(snapshot, x: 0, y: 0) == [0x33, 0x22, 0x11, 0xff])
        #expect(pixel(snapshot, x: 1, y: 1) == [0x33, 0x22, 0x11, 0xff])
        #expect(pixel(snapshot, x: 2, y: 1) == [0x33, 0x22, 0x11, 0xff])

        try await store.destroy(id: 7)
        await #expect(throws: RenderError.unknownSurface(7)) {
            try await store.snapshot(surfaceID: 7)
        }
    }

    @Test(arguments: CopyVector.singleRectangleCases)
    func copyBitsMatchesCommandStartSnapshotInEveryDirection(
        vector: CopyVector
    ) async throws {
        let store = try await seededStore(width: 8, height: 8)
        let source = PixelRect(x: 2, y: 2, width: 3, height: 3)
        let destination = PixelRect(
            x: source.x + vector.deltaX,
            y: source.y + vector.deltaY,
            width: source.width,
            height: source.height
        )
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: PixelRect(x: 0, y: 0, width: 8, height: 8),
            clips: nil
        )
        let before = try await store.snapshot(surfaceID: 1)
        let descriptorBefore = try await store.descriptor(surfaceID: 1)
        let transactionCountBefore = await store.metrics().mutationTransactions
        let expected = copiedPixels(
            from: before,
            source: source,
            destination: destination,
            region: region
        )

        _ = try #require(await store.copyBits(
            surfaceID: 1,
            region: region,
            destination: destination,
            sourceX: source.x,
            sourceY: source.y
        ))

        let after = try await store.snapshot(surfaceID: 1)
        let descriptorAfter = try await store.descriptor(surfaceID: 1)
        #expect(after.pixels == expected)
        #expect(descriptorAfter.revision == descriptorBefore.revision + 1)
        #expect(
            descriptorAfter.mutationGeneration
                == descriptorBefore.mutationGeneration + 1
        )
        #expect(
            await store.metrics().mutationTransactions
                == transactionCountBefore + 1
        )
    }

    @Test(arguments: CopyVector.overlappingDirections)
    func clippedMultiSegmentCopyBitsMatchesCommandStartSnapshot(
        vector: CopyVector
    ) async throws {
        let store = try await seededStore(width: 8, height: 8)
        let source = PixelRect(x: 2, y: 2, width: 4, height: 4)
        let destination = PixelRect(
            x: source.x + vector.deltaX,
            y: source.y + vector.deltaY,
            width: source.width,
            height: source.height
        )
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: PixelRect(x: 0, y: 0, width: 8, height: 8),
            clips: [
                PixelRect(
                    x: destination.x + 2,
                    y: destination.y + 2,
                    width: 2,
                    height: 2
                ),
                PixelRect(x: destination.x, y: destination.y, width: 1, height: 1),
                PixelRect(
                    x: destination.x + 2,
                    y: destination.y,
                    width: 2,
                    height: 1
                ),
                PixelRect(
                    x: destination.x,
                    y: destination.y + 2,
                    width: 1,
                    height: 2
                ),
            ]
        )
        #expect(region.segmentCount == 4)
        let before = try await store.snapshot(surfaceID: 1)
        let descriptorBefore = try await store.descriptor(surfaceID: 1)
        let transactionCountBefore = await store.metrics().mutationTransactions
        let expected = copiedPixels(
            from: before,
            source: source,
            destination: destination,
            region: region
        )

        _ = try #require(await store.copyBits(
            surfaceID: 1,
            region: region,
            destination: destination,
            sourceX: source.x,
            sourceY: source.y
        ))

        let after = try await store.snapshot(surfaceID: 1)
        let descriptorAfter = try await store.descriptor(surfaceID: 1)
        #expect(after.pixels == expected)
        #expect(descriptorAfter.revision == descriptorBefore.revision + 1)
        #expect(
            descriptorAfter.mutationGeneration
                == descriptorBefore.mutationGeneration + 1
        )
        #expect(
            await store.metrics().mutationTransactions
                == transactionCountBefore + 1
        )
    }

    @Test(arguments: SurfaceCopyCommand.allCases)
    func successfulSurfaceCopiesUseNoTemporaryPixelStaging(
        command: SurfaceCopyCommand
    ) async throws {
        let store = try await seededStore(width: 6, height: 6, surfaceIDs: [1, 2])
        let destination = PixelRect(x: 2, y: 2, width: 3, height: 3)
        let source = PixelRect(x: 1, y: 1, width: 3, height: 3)
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: PixelRect(x: 0, y: 0, width: 6, height: 6),
            clips: [
                PixelRect(x: 2, y: 2, width: 2, height: 1),
                PixelRect(x: 4, y: 4, width: 1, height: 1),
            ]
        )
        let appliedRegion: PixelRegion
        if command.isRegionTransaction {
            appliedRegion = region
        } else {
            appliedRegion = try PixelRegion(
                destination: destination,
                surfaceBounds: PixelRect(x: 0, y: 0, width: 6, height: 6),
                clips: nil
            )
        }
        let destinationBefore = try await store.snapshot(surfaceID: 1)
        let sourceBefore = command.usesCrossSurface
            ? try await store.snapshot(surfaceID: 2)
            : destinationBefore
        let expected = copiedPixels(
            from: destinationBefore,
            sourceSnapshot: sourceBefore,
            source: source,
            destination: destination,
            region: appliedRegion
        )
        let descriptorBefore = try await store.descriptor(surfaceID: 1)
        let metricsBefore = await store.metrics()

        let revision: SurfaceRevision?
        switch command {
        case .regionCopyBits:
            revision = try await store.copyBits(
                surfaceID: 1,
                region: region,
                destination: destination,
                sourceX: source.x,
                sourceY: source.y
            )
        case .regionSameSurfaceDrawCopy:
            revision = try await store.drawCopy(
                surfaceID: 1,
                region: region,
                destination: destination,
                sourceSurfaceID: 1,
                source: source
            )
        case .regionCrossSurfaceDrawCopy:
            revision = try await store.drawCopy(
                surfaceID: 1,
                region: region,
                destination: destination,
                sourceSurfaceID: 2,
                source: source
            )
        case .rectangleCopyBits:
            revision = try await store.copyBits(
                surfaceID: 1,
                destination: destination,
                sourceX: source.x,
                sourceY: source.y
            )
        case .rectangleSameSurfaceDrawCopy:
            revision = try await store.drawCopy(
                surfaceID: 1,
                destination: destination,
                sourceSurfaceID: 1,
                source: source
            )
        case .rectangleCrossSurfaceDrawCopy:
            revision = try await store.drawCopy(
                surfaceID: 1,
                destination: destination,
                sourceSurfaceID: 2,
                source: source
            )
        }

        #expect(revision != nil)
        let descriptorAfter = try await store.descriptor(surfaceID: 1)
        let metricsAfter = await store.metrics()
        #expect(try await store.snapshot(surfaceID: 1).pixels == expected)
        #expect(descriptorAfter.revision == descriptorBefore.revision + 1)
        #expect(
            descriptorAfter.mutationGeneration
                == descriptorBefore.mutationGeneration + 1
        )
        #expect(metricsAfter.temporaryCopyBytes == metricsBefore.temporaryCopyBytes)
        if command.isRegionTransaction {
            #expect(
                metricsAfter.mutationTransactions
                    == metricsBefore.mutationTransactions + 1
            )
        } else {
            #expect(metricsAfter.mutationTransactions == metricsBefore.mutationTransactions)
        }
    }

    @Test(arguments: CopyKernelCase.cases)
    func copyKernelUsesExpectedBulkOrRowCallShape(testCase: CopyKernelCase) async throws {
        let store = try await seededStore(
            width: testCase.surfaceWidth,
            height: testCase.surfaceHeight,
            surfaceIDs: [1, 2]
        )
        let region = try PixelRegion(
            destination: testCase.destination,
            surfaceBounds: PixelRect(
                x: 0,
                y: 0,
                width: testCase.surfaceWidth,
                height: testCase.surfaceHeight
            ),
            clips: nil
        )
        let destinationBefore = try await store.snapshot(surfaceID: 1)
        let sourceBefore = testCase.crossSurface
            ? try await store.snapshot(surfaceID: 2)
            : destinationBefore
        let expected = copiedPixels(
            from: destinationBefore,
            sourceSnapshot: sourceBefore,
            source: testCase.source,
            destination: testCase.destination,
            region: region
        )
        let metricsBefore = await store.metrics()

        if testCase.crossSurface {
            _ = try #require(await store.drawCopy(
                surfaceID: 1,
                region: region,
                destination: testCase.destination,
                sourceSurfaceID: 2,
                source: testCase.source
            ))
        } else {
            _ = try #require(await store.copyBits(
                surfaceID: 1,
                region: region,
                destination: testCase.destination,
                sourceX: testCase.source.x,
                sourceY: testCase.source.y
            ))
        }

        let metricsAfter = await store.metrics()
        #expect(try await store.snapshot(surfaceID: 1).pixels == expected)
        #expect(
            metricsAfter.bulkCopyCalls
                == metricsBefore.bulkCopyCalls + testCase.expectedBulkCalls
        )
        #expect(
            metricsAfter.rowCopyCalls
                == metricsBefore.rowCopyCalls + testCase.expectedRowCalls
        )
        #expect(metricsAfter.temporaryCopyBytes == metricsBefore.temporaryCopyBytes)
        #expect(metricsAfter.mutationTransactions == metricsBefore.mutationTransactions + 1)
    }

    @Test(arguments: FillKernelCase.cases)
    func fillKernelPreservesSurfaceAlphaSemantics(testCase: FillKernelCase) async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 1, width: 4, height: 3, format: testCase.format)
        let region = try PixelRegion(
            destination: PixelRect(x: 0, y: 0, width: 4, height: 3),
            surfaceBounds: PixelRect(x: 0, y: 0, width: 4, height: 3),
            clips: [
                PixelRect(x: 0, y: 0, width: 2, height: 1),
                PixelRect(x: 3, y: 2, width: 1, height: 1),
            ]
        )
        #expect(region.segmentCount == 2)
        let metricsBefore = await store.metrics()

        _ = try #require(await store.fill(
            surfaceID: 1,
            region: region,
            colorARGB: 0x7f11_2233
        ))

        let snapshot = try await store.snapshot(surfaceID: 1)
        let metricsAfter = await store.metrics()
        let expectedColor: [UInt8] = [0x33, 0x22, 0x11, testCase.expectedAlpha]
        #expect(pixel(snapshot, x: 0, y: 0) == expectedColor)
        #expect(pixel(snapshot, x: 1, y: 0) == expectedColor)
        #expect(pixel(snapshot, x: 3, y: 2) == expectedColor)
        #expect(pixel(snapshot, x: 2, y: 0) == [0, 0, 0, 0])
        #expect(
            metricsAfter.fillKernelCalls
                == metricsBefore.fillKernelCalls + UInt64(region.segmentCount)
        )
        #expect(metricsAfter.mutationTransactions == metricsBefore.mutationTransactions + 1)
    }

    @Test func invalidLaterCopySegmentDoesNotPublishOrRecordKernelCalls() async throws {
        let store = try await seededStore(width: 5, height: 1)
        let destination = PixelRect(x: 0, y: 0, width: 5, height: 1)
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: destination,
            clips: [
                PixelRect(x: 0, y: 0, width: 1, height: 1),
                PixelRect(x: 4, y: 0, width: 1, height: 1),
            ]
        )
        let descriptorBefore = try await store.descriptor(surfaceID: 1)
        let pixelsBefore = try await store.snapshot(surfaceID: 1).pixels
        let metricsBefore = await store.metrics()

        await #expect(throws: RenderError.invalidRectangle) {
            try await store.copyBits(
                surfaceID: 1,
                region: region,
                destination: destination,
                sourceX: 1,
                sourceY: 0
            )
        }

        let metricsAfter = await store.metrics()
        #expect(try await store.descriptor(surfaceID: 1) == descriptorBefore)
        #expect(try await store.snapshot(surfaceID: 1).pixels == pixelsBefore)
        #expect(metricsAfter.mutationTransactions == metricsBefore.mutationTransactions)
        #expect(metricsAfter.damageOperations == metricsBefore.damageOperations)
        #expect(metricsAfter.damageBytes == metricsBefore.damageBytes)
        #expect(metricsAfter.temporaryCopyBytes == metricsBefore.temporaryCopyBytes)
        #expect(metricsAfter.bulkCopyCalls == metricsBefore.bulkCopyCalls)
        #expect(metricsAfter.rowCopyCalls == metricsBefore.rowCopyCalls)
    }

    @Test func drawsTopDownAndBottomUpRawBitmaps() async throws {
        let topDownStore = SurfaceStore(backingPolicy: .dataOnly)
        try await topDownStore.create(id: 1, width: 1, height: 2, format: 96)
        let pixels = Data([
            1, 2, 3, 4,
            5, 6, 7, 8,
        ])
        try await topDownStore.drawCopy(
            surfaceID: 1,
            destination: PixelRect(x: 0, y: 0, width: 1, height: 2),
            bitmap: RawBitmap(
                format: .argb8888,
                width: 1,
                height: 2,
                stride: 4,
                topDown: true,
                pixels: pixels
            )
        )
        let topDown = try await topDownStore.snapshot(surfaceID: 1)
        #expect(pixel(topDown, x: 0, y: 0) == [1, 2, 3, 4])
        #expect(pixel(topDown, x: 0, y: 1) == [5, 6, 7, 8])

        let bottomUpStore = SurfaceStore(backingPolicy: .dataOnly)
        try await bottomUpStore.create(id: 2, width: 1, height: 2, format: 32)
        try await bottomUpStore.drawCopy(
            surfaceID: 2,
            destination: PixelRect(x: 0, y: 0, width: 1, height: 2),
            bitmap: RawBitmap(
                format: .xRGB8888,
                width: 1,
                height: 2,
                stride: 4,
                topDown: false,
                pixels: pixels
            )
        )
        let bottomUp = try await bottomUpStore.snapshot(surfaceID: 2)
        #expect(pixel(bottomUp, x: 0, y: 0) == [5, 6, 7, 0xff])
        #expect(pixel(bottomUp, x: 0, y: 1) == [1, 2, 3, 0xff])
    }

    @Test func preservesAlphaOnlyForARGBSourceAndDestination() async throws {
        let source = RawBitmap(
            format: .argb8888,
            width: 1,
            height: 1,
            stride: 4,
            topDown: true,
            pixels: Data([1, 2, 3, 0x44])
        )
        let argbStore = SurfaceStore(backingPolicy: .dataOnly)
        try await argbStore.create(id: 1, width: 1, height: 1, format: 96)
        try await argbStore.drawCopy(
            surfaceID: 1,
            destination: PixelRect(x: 0, y: 0, width: 1, height: 1),
            bitmap: source
        )
        #expect(try await argbStore.snapshot(surfaceID: 1).pixels == Data([1, 2, 3, 0x44]))

        let xrgbStore = SurfaceStore(backingPolicy: .dataOnly)
        try await xrgbStore.create(id: 2, width: 1, height: 1, format: 32)
        try await xrgbStore.drawCopy(
            surfaceID: 2,
            destination: PixelRect(x: 0, y: 0, width: 1, height: 1),
            bitmap: source
        )
        #expect(try await xrgbStore.snapshot(surfaceID: 2).pixels == Data([1, 2, 3, 0xff]))
    }

    @Test func rawCopyFastPathsHandleVectorTailOffsetsStrideAndOrientation() async throws {
        let bitmapWidth = 21
        let bitmapHeight = 3
        let stride = bitmapWidth * 4 + 12
        var sourcePixels = Data(repeating: 0xee, count: stride * bitmapHeight)
        for row in 0..<bitmapHeight {
            for column in 0..<bitmapWidth {
                let offset = row * stride + column * 4
                sourcePixels[offset] = UInt8(column)
                sourcePixels[offset + 1] = UInt8(row)
                sourcePixels[offset + 2] = UInt8(column + row)
                sourcePixels[offset + 3] = UInt8(0x40 + row)
            }
        }

        let formats: [(RawBitmapFormat, UInt32)] = [
            (.argb8888, 96),
            (.argb8888, 32),
            (.xRGB8888, 96),
            (.xRGB8888, 32),
        ]
        for (index, formatPair) in formats.enumerated() {
            let store = SurfaceStore(
                framePool: IOSurfaceFramePool(limits: .init(maximumFrames: 0)),
                backingPolicy: .dataOnly
            )
            let surfaceID = UInt32(100 + index)
            try await store.create(id: surfaceID, width: 20, height: 5, format: formatPair.1)
            try await store.drawCopy(
                surfaceID: surfaceID,
                destination: PixelRect(x: 1, y: 1, width: 17, height: 3),
                bitmap: RawBitmap(
                    format: formatPair.0,
                    width: bitmapWidth,
                    height: bitmapHeight,
                    stride: stride,
                    topDown: false,
                    pixels: sourcePixels
                ),
                source: PixelRect(x: 2, y: 0, width: 17, height: 3)
            )
            let snapshot = try await store.snapshot(surfaceID: surfaceID)
            let preservesAlpha = formatPair.0 == .argb8888 && formatPair.1 == 96
            for destinationRow in 0..<3 {
                let sourceRow = bitmapHeight - 1 - destinationRow
                for destinationColumn in 0..<17 {
                    let sourceColumn = destinationColumn + 2
                    #expect(pixel(
                        snapshot,
                        x: destinationColumn + 1,
                        y: destinationRow + 1
                    ) == [
                        UInt8(sourceColumn),
                        UInt8(sourceRow),
                        UInt8(sourceColumn + sourceRow),
                        preservesAlpha ? UInt8(0x40 + sourceRow) : 0xff,
                    ])
                }
            }
        }
    }

    @Test func rejectsUnboundedOrMalformedInputs() async throws {
        let store = SurfaceStore(limits: RenderLimits(
            maximumDimension: 64,
            maximumSurfaceBytes: 64
        ), backingPolicy: .dataOnly)
        await #expect(throws: RenderError.surfaceTooLarge(bytes: 400, maximum: 64)) {
            try await store.create(id: 1, width: 10, height: 10, format: 32)
        }
        try await store.create(id: 2, width: 2, height: 2, format: 32)
        await #expect(throws: RenderError.invalidRectangle) {
            try await store.fill(
                surfaceID: 2,
                rectangle: PixelRect(x: 1, y: 1, width: 2, height: 2),
                colorARGB: 0
            )
        }
        await #expect(throws: RenderError.invalidBitmap) {
            try await store.drawCopy(
                surfaceID: 2,
                destination: PixelRect(x: 0, y: 0, width: 1, height: 1),
                bitmap: RawBitmap(
                    format: .xRGB8888,
                    width: 1,
                    height: 1,
                    stride: 4,
                    topDown: true,
                    pixels: Data([0, 0, 0])
                )
            )
        }
    }

    @Test func sharedSurfaceMemoryBudgetBoundsAllDisplayStores() async throws {
        let budget = SurfaceMemoryBudget(maximumBytes: 16)
        let first = SurfaceStore(memoryBudget: budget, backingPolicy: .dataOnly)
        let second = SurfaceStore(memoryBudget: budget, backingPolicy: .dataOnly)

        try await first.create(id: 1, width: 2, height: 1, format: 32)
        try await second.create(id: 1, width: 2, height: 1, format: 32)
        await #expect(throws: RenderError.surfaceBudgetExceeded(
            requestedBytes: 4,
            allocatedBytes: 16,
            maximum: 16
        )) {
            try await second.create(id: 2, width: 1, height: 1, format: 32)
        }

        try await first.destroy(id: 1)
        try await second.create(id: 2, width: 1, height: 1, format: 32)
        #expect(budget.metrics().allocatedBytes == 12)
    }

    @Test func dataFallbackPixelsRemainIndependentAfterFrameRelease() async throws {
        let budget = SurfaceMemoryBudget(maximumBytes: 4)
        let noIOSurfacePool = IOSurfaceFramePool(
            limits: .init(maximumFrames: 0, maximumBytes: 0)
        )
        let store = SurfaceStore(
            framePool: noIOSurfacePool,
            memoryBudget: budget,
            backingPolicy: .dataOnly
        )
        try await store.create(id: 30, width: 1, height: 1, format: 32)

        var frame: FrameSnapshot? = try await store.snapshot(surfaceID: 30)
        let retainedPixels = frame?.pixels
        frame = nil
        #expect(budget.metrics().allocatedBytes == 4)
        try await store.fill(
            surfaceID: 30,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        #expect(retainedPixels == Data([0, 0, 0, 0]))
        #expect(try await store.descriptor(surfaceID: 30).revision == 1)
        #expect(try await store.snapshot(surfaceID: 30).pixels == Data([0x33, 0x22, 0x11, 0xff]))
        #expect(await store.metrics().fullFrameCopyBytes == 8)

        try await store.destroy(id: 30)
        #expect(budget.metrics().allocatedBytes == 0)
        try await store.create(id: 32, width: 1, height: 1, format: 32)
        #expect(retainedPixels == Data([0, 0, 0, 0]))
    }

    @Test func emptyScaledDamageIsANoOpAndKeepsDataRevisionSynchronized() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 17, width: 2, height: 2, format: 32)
        let bitmap = RawBitmap(
            format: .xRGB8888,
            width: 1,
            height: 1,
            stride: 4,
            topDown: true,
            pixels: Data([1, 2, 3, 4])
        )
        let noOpRevision = try await store.drawScaledCopy(
            surfaceID: 17,
            destination: PixelRect(x: 0, y: 0, width: 2, height: 2),
            bitmap: bitmap,
            source: PixelRect(x: 0, y: 0, width: 1, height: 1),
            clippedDestinations: []
        )
        #expect(noOpRevision == nil)
        #expect(try await store.descriptor(surfaceID: 17).revision == 0)

        try await store.fill(
            surfaceID: 17,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        #expect(try await store.descriptor(surfaceID: 17).revision == 1)
    }

    @Test func publishesIOSurfaceAlongsideImmutablePixels() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 9, width: 2, height: 1, format: 32)
        try await store.fill(
            surfaceID: 9,
            rectangle: PixelRect(x: 0, y: 0, width: 2, height: 1),
            colorARGB: 0x0011_2233
        )

        let snapshot = try await store.snapshot(surfaceID: 9)
        let ioSurfaceFrame = try #require(snapshot.ioSurfaceFrame)
        #expect(ioSurfaceFrame.width == 2)
        #expect(ioSurfaceFrame.height == 1)
        #expect(ioSurfaceFrame.pixelFormat == 0x4247_5241)
        #expect(ioSurfaceFrame.copyPixels() == snapshot.pixels)
        #expect(snapshot.pixels == Data([
            0x33, 0x22, 0x11, 0xff,
            0x33, 0x22, 0x11, 0xff,
        ]))
    }

    @Test func boundsAndReusesIOSurfaceLeases() throws {
        let pool = IOSurfaceFramePool(limits: .init(
            maximumFrames: 1,
            maximumBytes: 1_024 * 1_024
        ))
        var first = pool.makeFrame(
            width: 2,
            height: 1,
            sourceBytesPerRow: 8,
            pixels: Data(repeating: 1, count: 8)
        )
        let firstID = try #require(first?.id)
        #expect(pool.metrics().inUseFrames == 1)
        #expect(pool.makeFrame(
            width: 2,
            height: 1,
            sourceBytesPerRow: 8,
            pixels: Data(repeating: 2, count: 8)
        ) == nil)

        first = nil
        #expect(pool.metrics().availableFrames == 1)
        let reused = try #require(pool.makeFrame(
            width: 2,
            height: 1,
            sourceBytesPerRow: 8,
            pixels: Data(repeating: 3, count: 8)
        ))
        #expect(reused.id == firstID)
        #expect(reused.copyPixels() == Data(repeating: 3, count: 8))
    }

    @Test func purgesOnlyAvailableLegacyIOSurfaceFrames() throws {
        let pool = IOSurfaceFramePool(limits: .init(
            maximumFrames: 2,
            maximumBytes: 1_024 * 1_024
        ))
        var available = pool.makeFrame(
            width: 2,
            height: 1,
            sourceBytesPerRow: 8,
            pixels: Data(repeating: 1, count: 8)
        )
        #expect(available != nil)
        let inUse = try #require(pool.makeFrame(
            width: 2,
            height: 1,
            sourceBytesPerRow: 8,
            pixels: Data(repeating: 2, count: 8)
        ))
        available = nil
        #expect(pool.metrics().availableFrames == 1)
        #expect(pool.metrics().inUseFrames == 1)

        pool.purgeAvailable()
        let metrics = pool.metrics()
        #expect(metrics.allocatedFrames == 1)
        #expect(metrics.availableFrames == 0)
        #expect(metrics.inUseFrames == 1)
        #expect(inUse.copyPixels() == Data(repeating: 2, count: 8))
    }

    @Test func fallsBackToDataWhenAllLeasesAreInUse() async throws {
        let pool = IOSurfaceFramePool(limits: .init(
            maximumFrames: 1,
            maximumBytes: 1_024 * 1_024
        ))
        let store = SurfaceStore(framePool: pool, backingPolicy: .dataOnly)
        try await store.create(id: 4, width: 1, height: 1, format: 32)
        try await store.fill(
            surfaceID: 4,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0001_0203
        )

        let leased = try await store.snapshot(surfaceID: 4)
        let fallback = try await store.snapshot(surfaceID: 4)
        #expect(leased.ioSurfaceFrame != nil)
        #expect(fallback.ioSurfaceFrame == nil)
        #expect(fallback.pixels == leased.pixels)
    }

    @Test func descriptorTracksLifecycleAndSuccessfulDrawRevisions() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 5, width: 2, height: 2, format: 32)

        let created = try await store.descriptor(surfaceID: 5)
        #expect(created.width == 2)
        #expect(created.height == 2)
        #expect(created.lifecycleGeneration == 1)
        #expect(created.revision == 0)
        #expect(await store.metrics().snapshots == 0)

        let fillRevision = try await store.fill(
            surfaceID: 5,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        let drawn = try await store.descriptor(surfaceID: 5)
        #expect(fillRevision == drawn.surfaceRevision)
        #expect(drawn.lifecycleGeneration == created.lifecycleGeneration)
        #expect(drawn.revision == 1)

        await #expect(throws: RenderError.invalidRectangle) {
            try await store.fill(
                surfaceID: 5,
                rectangle: PixelRect(x: 2, y: 2, width: 1, height: 1),
                colorARGB: 0
            )
        }
        #expect(try await store.descriptor(surfaceID: 5).revision == 1)

        let onePixel = PixelRect(x: 0, y: 0, width: 1, height: 1)
        let copiedRevision = try await store.copyBits(
            surfaceID: 5,
            destination: onePixel,
            sourceX: 0,
            sourceY: 0
        )
        #expect(copiedRevision.revision == 2)
        #expect(try await store.descriptor(surfaceID: 5).revision == 2)
        let bitmap = RawBitmap(
            format: .xRGB8888,
            width: 1,
            height: 1,
            stride: 4,
            topDown: true,
            pixels: Data([1, 2, 3, 4])
        )
        let bitmapRevision = try await store.drawCopy(
            surfaceID: 5,
            destination: onePixel,
            bitmap: bitmap
        )
        #expect(bitmapRevision.revision == 3)
        #expect(try await store.descriptor(surfaceID: 5).revision == 3)
        try await store.create(id: 15, width: 1, height: 1, format: 32)
        let surfaceRevision = try await store.drawCopy(
            surfaceID: 5,
            destination: onePixel,
            sourceSurfaceID: 15,
            source: onePixel
        )
        #expect(surfaceRevision.revision == 4)
        #expect(try await store.descriptor(surfaceID: 5).revision == 4)
        let scaledRevision = try #require(await store.drawScaledCopy(
            surfaceID: 5,
            destination: onePixel,
            bitmap: bitmap,
            source: onePixel,
            clippedDestinations: [onePixel]
        ))
        #expect(scaledRevision.revision == 5)
        #expect(try await store.descriptor(surfaceID: 5).revision == 5)

        try await store.destroy(id: 5)
        try await store.create(id: 5, width: 1, height: 1, format: 96)
        let recreated = try await store.descriptor(surfaceID: 5)
        #expect(recreated.lifecycleGeneration == 3)
        #expect(recreated.revision == 0)
    }

    @Test func revisionMatchedSnapshotRejectsStaleAndRecreatedSurfaces() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 6, width: 1, height: 1, format: 32)
        let created = try await store.descriptor(surfaceID: 6)
        let initial = try #require(await store.snapshot(matching: created.surfaceRevision))
        #expect(initial.surfaceRevision == created.surfaceRevision)

        try await store.fill(
            surfaceID: 6,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0001_0203
        )
        #expect(await store.snapshot(matching: created.surfaceRevision) == nil)
        let updated = try await store.descriptor(surfaceID: 6)
        #expect(await store.snapshot(matching: updated.surfaceRevision) != nil)
        let covering = try #require(await store.snapshot(atLeast: created.surfaceRevision))
        #expect(covering.surfaceRevision == updated.surfaceRevision)
        let future = SurfaceRevision(
            surfaceID: updated.surfaceID,
            lifecycleGeneration: updated.lifecycleGeneration,
            revision: updated.revision + 1
        )
        #expect(await store.snapshot(atLeast: future) == nil)

        try await store.destroy(id: 6)
        try await store.create(id: 6, width: 1, height: 1, format: 32)
        #expect(await store.snapshot(matching: updated.surfaceRevision) == nil)
        #expect(await store.snapshot(atLeast: updated.surfaceRevision) == nil)
    }

    @Test func cachesIOSurfaceCPUReadbackAndReportsAggregateMetrics() async throws {
        let pool = IOSurfaceFramePool(limits: .init(
            maximumFrames: 1,
            maximumBytes: 1_024 * 1_024
        ))
        let store = SurfaceStore(framePool: pool, backingPolicy: .dataOnly)
        try await store.create(id: 8, width: 2, height: 1, format: 32)
        try await store.fill(
            surfaceID: 8,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        let snapshot = try await store.snapshot(surfaceID: 8)

        var metrics = await store.metrics()
        #expect(metrics.damageOperations == 1)
        #expect(metrics.damageBytes == 4)
        #expect(metrics.snapshots == 1)
        #expect(metrics.fullFrameCopyBytes == 8)
        #expect(metrics.partialFrameCopyBytes == 0)
        #expect(metrics.cpuMaterializations == 0)
        #expect(metrics.inFlightLeases == 1)

        let first = snapshot.pixels
        let second = snapshot.pixels
        #expect(first == second)
        metrics = await store.metrics()
        #expect(metrics.cpuMaterializations == 1)
        #expect(metrics.cpuMaterializationBytes == 8)

        let fallback = try await store.snapshot(surfaceID: 8)
        #expect(fallback.ioSurfaceFrame == nil)
        metrics = await store.metrics()
        #expect(metrics.poolExhaustions == 1)
        #expect(metrics.cpuMaterializations == 1)
    }

    @Test func revisionedBackingUsesDamageHistoryAndKeepsOldLeaseImmutable() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        )
        else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 20, width: 4, height: 2, format: 32)
        try await store.fill(
            surfaceID: 20,
            rectangle: PixelRect(x: 0, y: 0, width: 4, height: 2),
            colorARGB: 0x0011_2233
        )
        var first: FrameSnapshot? = try await store.snapshot(surfaceID: 20)
        #expect(first?.ioSurfaceFrame != nil)

        try await store.fill(
            surfaceID: 20,
            rectangle: PixelRect(x: 1, y: 0, width: 1, height: 1),
            colorARGB: 0x00aa_bbcc
        )
        let second = try await store.snapshot(surfaceID: 20)
        #expect(second.ioSurfaceFrame != nil)

        #expect(pixel(try #require(first), x: 1, y: 0) == [0x33, 0x22, 0x11, 0xff])
        #expect(pixel(second, x: 1, y: 0) == [0xcc, 0xbb, 0xaa, 0xff])
        #expect(pixel(second, x: 3, y: 1) == [0x33, 0x22, 0x11, 0xff])

        // Once the first lease is released, its old slot can catch up from the
        // bounded revision damage history instead of blitting the full current
        // IOSurface into it.
        first = nil
        try await store.fill(
            surfaceID: 20,
            rectangle: PixelRect(x: 3, y: 1, width: 1, height: 1),
            colorARGB: 0x00dd_eeff
        )
        let third = try await store.snapshot(surfaceID: 20)
        #expect(pixel(second, x: 3, y: 1) == [0x33, 0x22, 0x11, 0xff])
        #expect(pixel(third, x: 1, y: 0) == [0xcc, 0xbb, 0xaa, 0xff])
        #expect(pixel(third, x: 3, y: 1) == [0xff, 0xee, 0xdd, 0xff])

        let metrics = await store.metrics()
        #expect(metrics.revisionedBackingEnabled)
        #expect(metrics.revisionedAllocatedFrames == 2)
        #expect(metrics.fullFrameCopyBytes == 64)
        #expect(metrics.partialFrameCopyBytes == 8)
        #expect(metrics.gpuCopyBytes == 0)
        #expect(metrics.gpuErrors == 0)
    }

    @Test func fullSurfaceRawCopyBecomesIOSurfaceCanonicalWithoutPublicationCopy() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 44, width: 2, height: 2, format: 32)
        let fullSurface = PixelRect(x: 0, y: 0, width: 2, height: 2)
        try await store.drawCopy(
            surfaceID: 44,
            destination: fullSurface,
            bitmap: RawBitmap(
                format: .xRGB8888,
                width: 2,
                height: 2,
                stride: 8,
                topDown: false,
                pixels: Data([
                    1, 2, 3, 4, 5, 6, 7, 8,
                    9, 10, 11, 12, 13, 14, 15, 16,
                ])
            )
        )

        let descriptorBefore = try await store.descriptor(surfaceID: 44)
        let metricsBefore = await store.metrics()
        #expect(metricsBefore.directIOSurfaceWriteBytes == 16)
        #expect(metricsBefore.fullFrameCopyBytes == 0)
        #expect(metricsBefore.partialFrameCopyBytes == 0)
        #expect(metricsBefore.cpuMaterializations == 0)

        try await store.fill(
            surfaceID: 44,
            rectangle: PixelRect(x: 1, y: 1, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        let descriptorAfter = try await store.descriptor(surfaceID: 44)
        let metricsAfterMutation = await store.metrics()
        #expect(descriptorAfter.revision == descriptorBefore.revision + 1)
        #expect(
            descriptorAfter.mutationGeneration
                == descriptorBefore.mutationGeneration + 1
        )
        #expect(
            metricsAfterMutation.cpuMaterializations
                == metricsBefore.cpuMaterializations
        )
        #expect(
            metricsAfterMutation.cpuMaterializationBytes
                == metricsBefore.cpuMaterializationBytes
        )
        #expect(metricsAfterMutation.fullFrameCopyBytes == metricsBefore.fullFrameCopyBytes)
        #expect(
            metricsAfterMutation.partialFrameCopyBytes
                == metricsBefore.partialFrameCopyBytes
        )

        let resumed = try await store.snapshot(surfaceID: 44)
        let ioSurfaceFrame = try #require(resumed.ioSurfaceFrame)
        #expect(ioSurfaceFrame.copyPixels() == Data([
            9, 10, 11, 0xff, 13, 14, 15, 0xff,
            1, 2, 3, 0xff, 0x33, 0x22, 0x11, 0xff,
        ]))
        let metricsAfterSnapshot = await store.metrics()
        #expect(metricsAfterSnapshot.fullFrameCopyBytes == metricsBefore.fullFrameCopyBytes)
        #expect(metricsAfterSnapshot.partialFrameCopyBytes == metricsBefore.partialFrameCopyBytes)
        #expect(metricsAfterSnapshot.cpuMaterializations == metricsBefore.cpuMaterializations)
        #expect(
            metricsAfterSnapshot.cpuMaterializationBytes
                == metricsBefore.cpuMaterializationBytes
        )
    }

    @Test func fullSurfaceRawCopyKeepsLeasedRevisionImmutable() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 45, width: 1, height: 1, format: 32)
        try await store.fill(
            surfaceID: 45,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        let oldSnapshot = try await store.snapshot(surfaceID: 45)

        try await store.drawCopy(
            surfaceID: 45,
            destination: PixelRect(x: 0, y: 0, width: 1, height: 1),
            bitmap: RawBitmap(
                format: .argb8888,
                width: 1,
                height: 1,
                stride: 4,
                topDown: true,
                pixels: Data([1, 2, 3, 4])
            )
        )
        let newSnapshot = try await store.snapshot(surfaceID: 45)
        #expect(pixel(oldSnapshot, x: 0, y: 0) == [0x33, 0x22, 0x11, 0xff])
        #expect(pixel(newSnapshot, x: 0, y: 0) == [1, 2, 3, 0xff])
        let metrics = await store.metrics()
        #expect(metrics.directIOSurfaceWriteBytes == 4)
        #expect(metrics.revisionedAllocatedFrames == 2)
    }

    @Test func canonicalCPUMutationKeepsLeasedRevisionImmutable() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        let fullSurface = PixelRect(x: 0, y: 0, width: 4, height: 2)
        try await store.create(id: 46, width: 4, height: 2, format: 32)
        try await store.drawCopy(
            surfaceID: 46,
            destination: fullSurface,
            bitmap: seededBitmap(width: 4, height: 2, seed: 17)
        )
        let oldSnapshot = try await store.snapshot(surfaceID: 46)
        let oldFrame = try #require(oldSnapshot.ioSurfaceFrame)
        let oldPixels = try #require(oldFrame.copyPixels())
        let oldRevision = oldSnapshot.surfaceRevision
        let descriptorBefore = try await store.descriptor(surfaceID: 46)
        let metricsBefore = await store.metrics()
        let destination = PixelRect(x: 2, y: 1, width: 1, height: 1)
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: fullSurface,
            clips: nil
        )

        _ = try #require(await store.fill(
            surfaceID: 46,
            region: region,
            colorARGB: 0x0011_2233
        ))

        let descriptorAfter = try await store.descriptor(surfaceID: 46)
        let metricsAfterMutation = await store.metrics()
        #expect(descriptorAfter.revision == descriptorBefore.revision + 1)
        #expect(
            descriptorAfter.mutationGeneration
                == descriptorBefore.mutationGeneration + 1
        )
        #expect(
            metricsAfterMutation.mutationTransactions
                == metricsBefore.mutationTransactions + 1
        )
        #expect(
            metricsAfterMutation.cpuMaterializations
                == metricsBefore.cpuMaterializations
        )
        #expect(
            metricsAfterMutation.cpuMaterializationBytes
                == metricsBefore.cpuMaterializationBytes
        )
        #expect(metricsAfterMutation.fullFrameCopyBytes == metricsBefore.fullFrameCopyBytes)
        #expect(
            metricsAfterMutation.partialFrameCopyBytes
                == metricsBefore.partialFrameCopyBytes
        )

        let newSnapshot = try await store.snapshot(surfaceID: 46)
        let newFrame = try #require(newSnapshot.ioSurfaceFrame)
        var expected = oldPixels
        replacePixel(
            in: &expected,
            bytesPerRow: oldSnapshot.bytesPerRow,
            x: destination.x,
            y: destination.y,
            with: [0x33, 0x22, 0x11, 0xff]
        )
        #expect(oldSnapshot.surfaceRevision == oldRevision)
        #expect(oldFrame.copyPixels() == oldPixels)
        #expect(newSnapshot.surfaceRevision == descriptorAfter.surfaceRevision)
        #expect(newFrame.copyPixels() == expected)
        #expect(pool.metrics().allocatedFrames == 2)
        let metricsAfterSnapshot = await store.metrics()
        #expect(metricsAfterSnapshot.cpuMaterializations == metricsBefore.cpuMaterializations)
        #expect(
            metricsAfterSnapshot.cpuMaterializationBytes
                == metricsBefore.cpuMaterializationBytes
        )
    }

    @Test(arguments: CanonicalCPUMutation.allCases)
    func canonicalIOSurfaceContinuesDirectlyAcrossCPUMutations(
        mutation: CanonicalCPUMutation
    ) async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        let fullSurface = PixelRect(x: 0, y: 0, width: 4, height: 3)
        let bitmap = seededBitmap(width: 4, height: 3, seed: 31)
        var expected = bitmap.pixels
        try await store.create(id: 47, width: 4, height: 3, format: 32)
        try await store.drawCopy(
            surfaceID: 47,
            destination: fullSurface,
            bitmap: bitmap
        )
        let crossSurfaceBitmap: RawBitmap?
        if case .crossSurfaceDrawCopy = mutation {
            let sourceBitmap = seededBitmap(width: 4, height: 3, seed: 109)
            try await store.create(id: 49, width: 4, height: 3, format: 32)
            try await store.drawCopy(
                surfaceID: 49,
                destination: fullSurface,
                bitmap: sourceBitmap
            )
            crossSurfaceBitmap = sourceBitmap
        } else {
            crossSurfaceBitmap = nil
        }
        let descriptorBefore = try await store.descriptor(surfaceID: 47)
        let metricsBefore = await store.metrics()

        switch mutation {
        case .fill:
            let destination = PixelRect(x: 1, y: 1, width: 1, height: 1)
            let region = try PixelRegion(
                destination: destination,
                surfaceBounds: fullSurface,
                clips: nil
            )
            _ = try #require(await store.fill(
                surfaceID: 47,
                region: region,
                colorARGB: 0x00aa_bbcc
            ))
            replacePixel(
                in: &expected,
                bytesPerRow: 16,
                x: 1,
                y: 1,
                with: [0xcc, 0xbb, 0xaa, 0xff]
            )
        case .sameSurfaceCopyBits:
            let destination = PixelRect(x: 1, y: 1, width: 2, height: 1)
            let source = PixelRect(x: 0, y: 0, width: 2, height: 1)
            let region = try PixelRegion(
                destination: destination,
                surfaceBounds: fullSurface,
                clips: nil
            )
            _ = try #require(await store.copyBits(
                surfaceID: 47,
                region: region,
                destination: destination,
                sourceX: source.x,
                sourceY: source.y
            ))
            copyPixels(
                in: &expected,
                bytesPerRow: 16,
                source: source,
                destination: destination
            )
        case .partialBitmapDrawCopy:
            let destination = PixelRect(x: 2, y: 1, width: 1, height: 2)
            let source = PixelRect(x: 0, y: 0, width: 1, height: 2)
            let region = try PixelRegion(
                destination: destination,
                surfaceBounds: fullSurface,
                clips: nil
            )
            let partial = RawBitmap(
                format: .xRGB8888,
                width: 1,
                height: 2,
                stride: 4,
                topDown: true,
                pixels: Data([
                    0x10, 0x20, 0x30, 0,
                    0x40, 0x50, 0x60, 0,
                ])
            )
            _ = try #require(await store.drawCopy(
                surfaceID: 47,
                region: region,
                destination: destination,
                bitmap: partial,
                source: source
            ))
            replacePixel(
                in: &expected,
                bytesPerRow: 16,
                x: 2,
                y: 1,
                with: [0x10, 0x20, 0x30, 0xff]
            )
            replacePixel(
                in: &expected,
                bytesPerRow: 16,
                x: 2,
                y: 2,
                with: [0x40, 0x50, 0x60, 0xff]
            )
        case .crossSurfaceDrawCopy:
            let sourceBitmap = try #require(crossSurfaceBitmap)
            let destination = PixelRect(x: 1, y: 1, width: 2, height: 1)
            let source = PixelRect(x: 0, y: 0, width: 2, height: 1)
            let region = try PixelRegion(
                destination: destination,
                surfaceBounds: fullSurface,
                clips: nil
            )
            _ = try #require(await store.drawCopy(
                surfaceID: 47,
                region: region,
                destination: destination,
                sourceSurfaceID: 49,
                source: source
            ))
            copyPixels(
                from: sourceBitmap.pixels,
                sourceBytesPerRow: sourceBitmap.stride,
                in: &expected,
                destinationBytesPerRow: 16,
                source: source,
                destination: destination
            )
        }

        let descriptorAfter = try await store.descriptor(surfaceID: 47)
        let metricsAfterMutation = await store.metrics()
        #expect(descriptorAfter.revision == descriptorBefore.revision + 1)
        #expect(
            descriptorAfter.mutationGeneration
                == descriptorBefore.mutationGeneration + 1
        )
        #expect(
            metricsAfterMutation.mutationTransactions
                == metricsBefore.mutationTransactions + 1
        )
        #expect(
            metricsAfterMutation.cpuMaterializations
                == metricsBefore.cpuMaterializations
        )
        #expect(
            metricsAfterMutation.cpuMaterializationBytes
                == metricsBefore.cpuMaterializationBytes
        )
        #expect(metricsAfterMutation.fullFrameCopyBytes == metricsBefore.fullFrameCopyBytes)
        #expect(
            metricsAfterMutation.partialFrameCopyBytes
                == metricsBefore.partialFrameCopyBytes
        )

        let snapshot = try await store.snapshot(surfaceID: 47)
        let frame = try #require(snapshot.ioSurfaceFrame)
        #expect(frame.copyPixels() == expected)
        if let crossSurfaceBitmap {
            let sourceSnapshot = try await store.snapshot(surfaceID: 49)
            let sourceFrame = try #require(sourceSnapshot.ioSurfaceFrame)
            #expect(sourceFrame.copyPixels() == crossSurfaceBitmap.pixels)
        }
        let metricsAfterSnapshot = await store.metrics()
        #expect(metricsAfterSnapshot.cpuMaterializations == metricsBefore.cpuMaterializations)
        #expect(
            metricsAfterSnapshot.cpuMaterializationBytes
                == metricsBefore.cpuMaterializationBytes
        )
        #expect(metricsAfterSnapshot.fullFrameCopyBytes == metricsBefore.fullFrameCopyBytes)
        #expect(metricsAfterSnapshot.partialFrameCopyBytes == metricsBefore.partialFrameCopyBytes)
    }

    @Test func canonicalMutationFallsBackAtomicallyWhenOnlySlotIsLeased() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 1, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        let fullSurface = PixelRect(x: 0, y: 0, width: 3, height: 2)
        let bitmap = seededBitmap(width: 3, height: 2, seed: 71)
        try await store.create(id: 48, width: 3, height: 2, format: 32)
        try await store.drawCopy(
            surfaceID: 48,
            destination: fullSurface,
            bitmap: bitmap
        )
        let oldSnapshot = try await store.snapshot(surfaceID: 48)
        let oldFrame = try #require(oldSnapshot.ioSurfaceFrame)
        let oldPixels = try #require(oldFrame.copyPixels())
        let descriptorBefore = try await store.descriptor(surfaceID: 48)
        let metricsBefore = await store.metrics()
        let destination = PixelRect(x: 1, y: 1, width: 1, height: 1)
        let region = try PixelRegion(
            destination: destination,
            surfaceBounds: fullSurface,
            clips: nil
        )

        _ = try #require(await store.fill(
            surfaceID: 48,
            region: region,
            colorARGB: 0x0011_2233
        ))

        let descriptorAfter = try await store.descriptor(surfaceID: 48)
        let metricsAfterMutation = await store.metrics()
        #expect(descriptorAfter.revision == descriptorBefore.revision + 1)
        #expect(
            descriptorAfter.mutationGeneration
                == descriptorBefore.mutationGeneration + 1
        )
        #expect(
            metricsAfterMutation.mutationTransactions
                == metricsBefore.mutationTransactions + 1
        )
        #expect(
            metricsAfterMutation.cpuMaterializations
                == metricsBefore.cpuMaterializations + 1
        )
        #expect(
            metricsAfterMutation.cpuMaterializationBytes
                == metricsBefore.cpuMaterializationBytes + UInt64(bitmap.pixels.count)
        )
        #expect(metricsAfterMutation.damageOperations == metricsBefore.damageOperations + 1)
        #expect(metricsAfterMutation.damageBytes == metricsBefore.damageBytes + 4)
        #expect(oldFrame.copyPixels() == oldPixels)

        let newSnapshot = try await store.snapshot(surfaceID: 48)
        #expect(newSnapshot.ioSurfaceFrame == nil)
        var expected = oldPixels
        replacePixel(
            in: &expected,
            bytesPerRow: oldSnapshot.bytesPerRow,
            x: destination.x,
            y: destination.y,
            with: [0x33, 0x22, 0x11, 0xff]
        )
        #expect(newSnapshot.pixels == expected)
        #expect(oldSnapshot.surfaceRevision == descriptorBefore.surfaceRevision)
        #expect(oldFrame.copyPixels() == oldPixels)
    }

    @Test func repeatedSmallDamageDoesNotRegressToFullGPUBlits() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let unified = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        let data = SurfaceStore(
            framePool: IOSurfaceFramePool(limits: .init(maximumFrames: 0)),
            backingPolicy: .dataOnly
        )
        for store in [unified, data] {
            try await store.create(id: 24, width: 64, height: 64, format: 32)
            try await store.fill(
                surfaceID: 24,
                rectangle: PixelRect(x: 0, y: 0, width: 64, height: 64),
                colorARGB: 0x0011_2233
            )
        }
        #expect(try await unified.snapshot(surfaceID: 24).pixels
            == data.snapshot(surfaceID: 24).pixels)

        for revision in 1...209 {
            let rectangle = PixelRect(
                x: revision % 32 * 2,
                y: revision / 32 % 32 * 2,
                width: 1,
                height: 1
            )
            for store in [unified, data] {
                try await store.fill(
                    surfaceID: 24,
                    rectangle: rectangle,
                    colorARGB: UInt32(revision)
                )
            }
            #expect(try await unified.snapshot(surfaceID: 24).pixels
                == data.snapshot(surfaceID: 24).pixels)
        }

        let metrics = await unified.metrics()
        #expect(metrics.gpuCopyBytes == 0)
        #expect(metrics.fullFrameCopyBytes == UInt64(64 * 64 * 4))
        #expect(metrics.partialFrameCopyBytes > 0)
        #expect(metrics.gpuErrors == 0)
    }

    @Test func CPUOnlyPublicationReusesUnleasedCanonicalSlot() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 25, width: 4, height: 2, format: 32)
        try await store.fill(
            surfaceID: 25,
            rectangle: PixelRect(x: 0, y: 0, width: 4, height: 2),
            colorARGB: 0x0011_2233
        )
        do {
            let first = try await store.snapshot(surfaceID: 25)
            #expect(first.ioSurfaceFrame != nil)
        }

        try await store.fill(
            surfaceID: 25,
            rectangle: PixelRect(x: 1, y: 0, width: 1, height: 1),
            colorARGB: 0x00aa_bbcc
        )
        let second = try await store.snapshot(surfaceID: 25)
        #expect(pixel(second, x: 1, y: 0) == [0xcc, 0xbb, 0xaa, 0xff])
        #expect(pixel(second, x: 3, y: 1) == [0x33, 0x22, 0x11, 0xff])

        let metrics = await store.metrics()
        #expect(metrics.revisionedAllocatedFrames == 1)
        #expect(metrics.fullFrameCopyBytes == 32)
        #expect(metrics.partialFrameCopyBytes == 4)
        #expect(metrics.gpuCopyBytes == 0)
    }

    @Test func revisionedSnapshotsShareOneReadbackForCurrentRevision() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 41, width: 16, height: 16, format: 32)
        try await store.fill(
            surfaceID: 41,
            rectangle: PixelRect(x: 0, y: 0, width: 16, height: 16),
            colorARGB: 0x0011_2233
        )

        var first: FrameSnapshot? = try await store.snapshot(surfaceID: 41)
        var second: FrameSnapshot? = try await store.snapshot(surfaceID: 41)
        #expect(first?.pixelStorage === second?.pixelStorage)
        #expect(pool.metrics().inFlightLeases == 1)
        var retainedPixels = first?.pixels
        _ = second?.pixels
        #expect(await store.metrics().cpuMaterializations == 1)

        first = nil
        second = nil
        var third: FrameSnapshot? = try await store.snapshot(surfaceID: 41)
        _ = third?.pixels
        #expect(await store.metrics().cpuMaterializations == 1)
        #expect(pool.metrics().inFlightLeases == 1)

        try await store.destroy(id: 41)
        third = nil
        #expect(retainedPixels?.count == 1_024)
        #expect(pool.metrics().allocatedFrames == 0)
        #expect(pool.metrics().inFlightLeases == 0)
        retainedPixels = nil
    }

    @Test func crossSurfaceCopyMaterializesGPUCanonicalSourceOnce() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let budget = SurfaceMemoryBudget(maximumBytes: 32)
        let store = SurfaceStore(
            framePool: IOSurfaceFramePool(
                limits: .init(maximumFrames: 0, maximumBytes: 0)
            ),
            memoryBudget: budget,
            backingPolicy: .revisionedIOSurface(pool)
        )
        try await store.create(id: 42, width: 2, height: 2, format: 32)
        try await store.create(id: 43, width: 2, height: 2, format: 32)

        let nativeFrame = try SpiceVideoToolboxFrame(
            pixelBuffer: makeNV12PixelBuffer(
                width: 2,
                height: 2,
                luma: 235,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ),
            expectedWidth: 2,
            expectedHeight: 2,
            maximumDecodedBytes: 16
        )
        try await store.drawNativeVideoFrame(
            surfaceID: 42,
            destination: PixelRect(x: 0, y: 0, width: 2, height: 2),
            frame: nativeFrame,
            source: PixelRect(x: 0, y: 0, width: 2, height: 2),
            topDown: true,
            clippedDestinations: [PixelRect(x: 0, y: 0, width: 2, height: 2)]
        )

        var leasedRevisions: [FrameSnapshot] = []
        for component: UInt32 in 1...3 {
            try await store.fill(
                surfaceID: 43,
                rectangle: PixelRect(x: 0, y: 0, width: 2, height: 2),
                colorARGB: component
            )
            leasedRevisions.append(try await store.snapshot(surfaceID: 43))
        }
        try await store.fill(
            surfaceID: 43,
            rectangle: PixelRect(x: 0, y: 0, width: 2, height: 2),
            colorARGB: 4
        )
        let dataFallback = try await store.snapshot(surfaceID: 43)
        #expect(dataFallback.ioSurfaceFrame == nil)
        try await store.drawCopy(
            surfaceID: 43,
            destination: PixelRect(x: 0, y: 0, width: 2, height: 2),
            sourceSurfaceID: 42,
            source: PixelRect(x: 0, y: 0, width: 2, height: 2)
        )
        #expect(await store.metrics().cpuMaterializations == 1)
        let copied = try await store.snapshot(surfaceID: 43)
        #expect(pixel(copied, x: 0, y: 0).allSatisfy { $0 >= 254 })
        #expect(pixel(dataFallback, x: 0, y: 0) == [4, 0, 0, 0xff])
        #expect(leasedRevisions.count == 3)
    }

    @Test func revisionedBackingFallsBackToDataWhenThreeSlotsAreLeased() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        )
        else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 21, width: 2, height: 1, format: 32)

        var leases: [FrameSnapshot] = []
        for value: UInt32 in 1...3 {
            try await store.fill(
                surfaceID: 21,
                rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
                colorARGB: value
            )
            leases.append(try await store.snapshot(surfaceID: 21))
        }
        #expect(leases.allSatisfy { $0.ioSurfaceFrame != nil })

        try await store.fill(
            surfaceID: 21,
            rectangle: PixelRect(x: 1, y: 0, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        let fallback = try await store.snapshot(surfaceID: 21)
        #expect(fallback.ioSurfaceFrame == nil)
        #expect(pixel(fallback, x: 1, y: 0) == [0x33, 0x22, 0x11, 0xff])
        #expect(pixel(leases[0], x: 0, y: 0) == [1, 0, 0, 0xff])
        #expect(await store.metrics().poolExhaustions == 1)

        leases.removeAll()
        let promoted = try await store.snapshot(surfaceID: 21)
        #expect(promoted.ioSurfaceFrame != nil)
        #expect(promoted.pixels == fallback.pixels)
    }

    @Test func revisionedWritableCandidateNeverAliasesCommittedSource() async throws {
        let namespace = RevisionedIOSurfaceNamespace()
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
                  limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
              ),
              let initial = pool.checkoutWritable(
                  namespace: namespace,
                  surfaceID: 31,
                  width: 2,
                  height: 2,
                  source: nil
              )
        else {
            return
        }
        #expect(await initial.synchronizeFromSource())
        let initialID = initial.withIOSurface { IOSurfaceGetID($0) }
        let revision = try #require(initial.finish(revision: 1))
        let candidate = try #require(pool.checkoutWritable(
            namespace: namespace,
            surfaceID: 31,
            width: 2,
            height: 2,
            source: revision
        ))
        let candidateID = candidate.withIOSurface { IOSurfaceGetID($0) }
        #expect(candidateID != initialID)
    }

    @Test func abortedWritableCandidateForcesFullResynchronization() async throws {
        let namespace = RevisionedIOSurfaceNamespace()
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let first = try #require(pool.checkoutWritable(
            namespace: namespace,
            surfaceID: 33,
            width: 2,
            height: 1,
            source: nil
        ))
        #expect(await first.synchronizeFromSource())
        let revision1 = try #require(first.finish(revision: 1))

        let second = try #require(pool.checkoutWritable(
            namespace: namespace,
            surfaceID: 33,
            width: 2,
            height: 1,
            source: revision1
        ))
        #expect(await second.synchronizeFromSource())
        let revision2 = try #require(second.finish(revision: 2))

        do {
            let aborted = try #require(pool.checkoutWritable(
                namespace: namespace,
                surfaceID: 33,
                width: 2,
                height: 1,
                source: revision2
            ))
            #expect(aborted.destinationRevision == 1)
            #expect(aborted.copyPackedPixels(
                Data([1, 2, 3, 4, 5, 6, 7, 8]),
                sourceBytesPerRow: 8,
                rectangles: [IOSurfaceCopyRectangle(x: 0, y: 0, width: 1, height: 1)]
            ) == 4)
        }

        let retried = try #require(pool.checkoutWritable(
            namespace: namespace,
            surfaceID: 33,
            width: 2,
            height: 1,
            source: revision2
        ))
        #expect(retried.destinationRevision == nil)
    }

    @Test func retiredLeasesRemainInsidePerSurfaceThreeSlotLimit() async throws {
        let namespace = RevisionedIOSurfaceNamespace()
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        )
        else {
            return
        }

        var current: RevisionedIOSurfaceRevision?
        var leases: [IOSurfaceFrame] = []
        for revision in 1...3 {
            let writable = try #require(pool.checkoutWritable(
                namespace: namespace,
                surfaceID: 32,
                width: 2,
                height: 2,
                source: current
            ))
            #expect(await writable.synchronizeFromSource())
            let committed: RevisionedIOSurfaceRevision = try #require(
                writable.finish(revision: UInt64(revision))
            )
            current = committed
            leases.append(try #require(committed.makeLease()))
        }
        pool.retire(namespace: namespace, surfaceID: 32)

        #expect(pool.checkoutWritable(
            namespace: namespace,
            surfaceID: 32,
            width: 2,
            height: 2,
            source: nil
        ) == nil)
        #expect(pool.metrics().allocatedFrames == 3)
        leases.removeAll()
        #expect(pool.metrics().allocatedFrames == 0)
    }

    @Test func revisionedPoolNamespacesEqualSurfaceIDsAcrossDisplays() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 1, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let firstNamespace = RevisionedIOSurfaceNamespace()
        let secondNamespace = RevisionedIOSurfaceNamespace()
        let first = try #require(pool.checkoutWritable(
            namespace: firstNamespace,
            surfaceID: 0,
            width: 2,
            height: 2,
            source: nil
        ))
        let second = try #require(pool.checkoutWritable(
            namespace: secondNamespace,
            surfaceID: 0,
            width: 2,
            height: 2,
            source: nil
        ))
        #expect(await first.synchronizeFromSource())
        #expect(await second.synchronizeFromSource())
        _ = try #require(first.finish(revision: 1))
        let secondRevision = try #require(second.finish(revision: 1))

        pool.retire(namespace: firstNamespace, surfaceID: 0)
        #expect(secondRevision.makeLease() != nil)
        #expect(pool.metrics().allocatedFrames == 1)
    }

    @Test func retiringAWriterCannotStrandItsSlot() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 1, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let namespace = RevisionedIOSurfaceNamespace()
        let writable = try #require(pool.checkoutWritable(
            namespace: namespace,
            surfaceID: 41,
            width: 2,
            height: 2,
            source: nil
        ))
        pool.retire(namespace: namespace, surfaceID: 41)
        #expect(writable.finish(revision: 1) == nil)
        #expect(pool.metrics().allocatedFrames == 0)
    }

    @Test func closingStoreRetiresCanonicalSlotsUntilLastLeaseReleases() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 42, width: 2, height: 2, format: 32)
        var snapshot: FrameSnapshot? = try await store.snapshot(surfaceID: 42)
        #expect(snapshot?.ioSurfaceFrame != nil)
        await store.close()
        #expect(pool.metrics().allocatedFrames == 1)
        snapshot = nil
        #expect(pool.metrics().allocatedFrames == 0)
    }

    @Test func closingStoreIsTerminalAndReleasesItsSurfaceBudget() async throws {
        let budget = SurfaceMemoryBudget(maximumBytes: 64)
        let store = SurfaceStore(memoryBudget: budget, backingPolicy: .dataOnly)
        try await store.create(id: 43, width: 2, height: 2, format: 32)
        #expect(budget.metrics().allocatedBytes == 16)

        await store.close()
        await store.close()
        #expect(budget.metrics().allocatedBytes == 0)

        await #expect(throws: RenderError.storeClosed) {
            try await store.create(id: 44, width: 2, height: 2, format: 32)
        }
        await #expect(throws: RenderError.storeClosed) {
            _ = try await store.descriptor(surfaceID: 43)
        }
        await #expect(throws: RenderError.storeClosed) {
            try await store.fill(
                surfaceID: 43,
                rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
                colorARGB: 0xff00_0000
            )
        }
    }

    @Test func legacyFrameLeaseDoesNotRetainItsDeadPool() throws {
        var pool: IOSurfaceFramePool? = IOSurfaceFramePool(limits: .init(
            maximumFrames: 1,
            maximumBytes: 1_024 * 1_024
        ))
        weak let weakPool = pool
        guard let frame = pool?.makeFrame(
            width: 1,
            height: 1,
            sourceBytesPerRow: 4,
            pixels: Data([1, 2, 3, 4])
        ) else {
            return
        }
        pool = nil
        #expect(weakPool == nil)
        #expect(frame.copyPixels() == Data([1, 2, 3, 4]))
    }

    @Test func damageJournalMergesAndEscalatesAtHalfCoverage() {
        var journal = SurfaceDamageJournal(width: 10, height: 10)
        for _ in 0..<1_000 {
            journal.append(PixelRect(x: 1, y: 1, width: 2, height: 2))
        }
        #expect(journal.copyRectangles == [PixelRect(x: 1, y: 1, width: 2, height: 2)])
        #expect(!journal.isFullFrame)

        journal.append(PixelRect(x: 0, y: 0, width: 10, height: 5))
        #expect(journal.isFullFrame)
        #expect(journal.copyRectangles == [PixelRect(x: 0, y: 0, width: 10, height: 10)])
    }

    @Test func damageJournalDoesNotInflateTouchingLShapes() {
        var journal = SurfaceDamageJournal(width: 100, height: 100)
        journal.append(PixelRect(x: 0, y: 0, width: 1, height: 50))
        journal.append(PixelRect(x: 0, y: 0, width: 100, height: 1))

        #expect(!journal.isFullFrame)
        #expect(journal.copyRectangles == [
            PixelRect(x: 0, y: 0, width: 1, height: 50),
            PixelRect(x: 0, y: 0, width: 100, height: 1),
        ])

        var exactHalf = SurfaceDamageJournal(width: 10, height: 10)
        exactHalf.append(PixelRect(x: 0, y: 0, width: 5, height: 5))
        exactHalf.append(PixelRect(x: 5, y: 5, width: 5, height: 5))
        #expect(exactHalf.isFullFrame)
    }

    @Test func damageJournalUsesExactCoverageAndKeepsSixtyFourSparseRectangles() {
        var overlap = SurfaceDamageJournal(width: 10, height: 10)
        overlap.append(PixelRect(x: 0, y: 0, width: 4, height: 10))
        overlap.append(PixelRect(x: 3, y: 0, width: 2, height: 5))
        #expect(!overlap.isFullFrame)
        overlap.append(PixelRect(x: 4, y: 5, width: 1, height: 5))
        #expect(overlap.isFullFrame)

        var oddArea = SurfaceDamageJournal(width: 5, height: 1)
        oddArea.append(PixelRect(x: 0, y: 0, width: 1, height: 1))
        oddArea.append(PixelRect(x: 2, y: 0, width: 1, height: 1))
        #expect(!oddArea.isFullFrame)
        oddArea.append(PixelRect(x: 4, y: 0, width: 1, height: 1))
        #expect(oddArea.isFullFrame)

        var sparse = SurfaceDamageJournal(width: 256, height: 256)
        for index in 0..<64 {
            sparse.append(PixelRect(
                x: index % 16 * 2,
                y: index / 16 * 2,
                width: 1,
                height: 1
            ))
        }
        #expect(!sparse.isFullFrame)
        #expect(sparse.copyRectangles.count == 64)
        sparse.append(PixelRect(x: 0, y: 8, width: 1, height: 1))
        #expect(sparse.isFullFrame)
    }

    @Test func sparseDiagonalDamageUploadsOnlyChangedPixels() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 27, width: 16, height: 16, format: 32)
        var initial: FrameSnapshot? = try await store.snapshot(surfaceID: 27)
        #expect(initial?.ioSurfaceFrame != nil)
        initial = nil

        for coordinate in 0..<12 {
            try await store.fill(
                surfaceID: 27,
                rectangle: PixelRect(x: coordinate, y: coordinate, width: 1, height: 1),
                colorARGB: UInt32(coordinate + 1)
            )
        }
        let updated = try await store.snapshot(surfaceID: 27)
        let metrics = await store.metrics()
        #expect(metrics.fullFrameCopyBytes == UInt64(16 * 16 * 4))
        #expect(metrics.partialFrameCopyBytes == UInt64(12 * 4))
        for coordinate in 0..<12 {
            #expect(pixel(updated, x: coordinate, y: coordinate)[0] == UInt8(coordinate + 1))
        }
    }

    @Test func nativeVideoCommitsTransactionallyWithoutBGRAAndCPUCanResume() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        )
        else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 22, width: 4, height: 4, format: 32)
        try await store.fill(
            surfaceID: 22,
            rectangle: PixelRect(x: 0, y: 0, width: 4, height: 4),
            colorARGB: 0x0011_2233
        )

        let nativeFrame = try SpiceVideoToolboxFrame(
            pixelBuffer: makeNV12PixelBuffer(
                width: 2,
                height: 2,
                luma: 235,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ),
            expectedWidth: 2,
            expectedHeight: 2,
            maximumDecodedBytes: 16
        )
        let beforeNoOp = try await store.descriptor(surfaceID: 22)
        let noOpRevision = try await store.drawNativeVideoFrame(
            surfaceID: 22,
            destination: PixelRect(x: 1, y: 1, width: 2, height: 2),
            frame: nativeFrame,
            source: PixelRect(x: 0, y: 0, width: 2, height: 2),
            topDown: true,
            clippedDestinations: []
        )
        #expect(noOpRevision == nil)
        #expect(try await store.descriptor(surfaceID: 22) == beforeNoOp)

        let nativeRevision = try #require(await store.drawNativeVideoFrame(
            surfaceID: 22,
            destination: PixelRect(x: 1, y: 1, width: 2, height: 2),
            frame: nativeFrame,
            source: PixelRect(x: 0, y: 0, width: 2, height: 2),
            topDown: true,
            clippedDestinations: [PixelRect(x: 1, y: 1, width: 2, height: 2)],
            isAdvancedVideo: true
        ))
        #expect(nativeRevision.revision == 2)
        let gpuSnapshot = try await store.snapshot(surfaceID: 22)
        #expect(gpuSnapshot.ioSurfaceFrame != nil)
        #expect(gpuSnapshot.isAdvancedVideoFrame)
        #expect(await store.metrics().cpuMaterializations == 0)
        #expect(pixel(gpuSnapshot, x: 0, y: 0) == [0x33, 0x22, 0x11, 0xff])
        let white = pixel(gpuSnapshot, x: 1, y: 1)
        #expect(white.allSatisfy { $0 >= 254 })

        // A later CPU command mutates a synchronized IOSurface candidate
        // without another CPU materialization, then preserves untouched video
        // pixels while applying its own damage.
        let materializationsBeforeCPUFill = await store.metrics().cpuMaterializations
        try await store.fill(
            surfaceID: 22,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x00aa_bbcc
        )
        #expect(
            await store.metrics().cpuMaterializations
                == materializationsBeforeCPUFill
        )
        let resumed = try await store.snapshot(surfaceID: 22)
        #expect(!resumed.isAdvancedVideoFrame)
        #expect(pixel(resumed, x: 0, y: 0) == [0xcc, 0xbb, 0xaa, 0xff])
        #expect(pixel(resumed, x: 1, y: 1).allSatisfy { $0 >= 254 })

        let beforeRejectedFrame = try await store.descriptor(surfaceID: 22)
        let unknownMatrixFrame = try SpiceVideoToolboxFrame(
            pixelBuffer: makeNV12PixelBuffer(
                width: 2,
                height: 2,
                luma: 128,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020
            ),
            expectedWidth: 2,
            expectedHeight: 2,
            maximumDecodedBytes: 16
        )
        await #expect(throws: SurfaceVideoCompositionError.compositor(.unsupportedColorMatrix)) {
            try await store.drawNativeVideoFrame(
                surfaceID: 22,
                destination: PixelRect(x: 1, y: 1, width: 2, height: 2),
                frame: unknownMatrixFrame,
                source: PixelRect(x: 0, y: 0, width: 2, height: 2),
                topDown: true,
                clippedDestinations: [PixelRect(x: 1, y: 1, width: 2, height: 2)]
            )
        }
        #expect(try await store.descriptor(surfaceID: 22) == beforeRejectedFrame)
        let finalMetrics = await store.metrics()
        #expect(finalMetrics.nativeVideoFrames == 1)
        #expect(finalMetrics.nativeVideoFallbacks == 1)
    }

    @Test func fullSurfaceNativeVideoSkipsRedundantSourceBlit() async throws {
        guard let pool = RevisionedIOSurfacePool.makeIfSupported(
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 1_024 * 1_024)
        ) else {
            return
        }
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 26, width: 2, height: 2, format: 32)
        try await store.fill(
            surfaceID: 26,
            rectangle: PixelRect(x: 0, y: 0, width: 2, height: 2),
            colorARGB: 0x0011_2233
        )
        let oldFrame = try await store.snapshot(surfaceID: 26)

        let nativeFrame = try SpiceVideoToolboxFrame(
            pixelBuffer: makeNV12PixelBuffer(
                width: 2,
                height: 2,
                luma: 235,
                matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
            ),
            expectedWidth: 2,
            expectedHeight: 2,
            maximumDecodedBytes: 16
        )
        let fullSurface = PixelRect(x: 0, y: 0, width: 2, height: 2)
        try await store.drawNativeVideoFrame(
            surfaceID: 26,
            destination: fullSurface,
            frame: nativeFrame,
            source: fullSurface,
            topDown: true,
            clippedDestinations: [fullSurface]
        )

        let metrics = await store.metrics()
        #expect(metrics.nativeVideoFrames == 1)
        #expect(metrics.gpuCopyBytes == 0)
        #expect(metrics.cpuMaterializations == 0)
        let newFrame = try await store.snapshot(surfaceID: 26)
        #expect(!newFrame.isAdvancedVideoFrame)
        #expect(pixel(oldFrame, x: 0, y: 0) == [0x33, 0x22, 0x11, 0xff])
        #expect(pixel(newFrame, x: 0, y: 0).allSatisfy { $0 >= 254 })
    }

    private func seededStore(
        width: Int,
        height: Int,
        surfaceIDs: [UInt32] = [1]
    ) async throws -> SurfaceStore {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        for surfaceID in surfaceIDs {
            try await store.create(
                id: surfaceID,
                width: UInt32(width),
                height: UInt32(height),
                format: 32
            )
            try await store.drawCopy(
                surfaceID: surfaceID,
                destination: PixelRect(x: 0, y: 0, width: width, height: height),
                bitmap: seededBitmap(
                    width: width,
                    height: height,
                    seed: UInt8(truncatingIfNeeded: surfaceID &* 53)
                )
            )
        }
        return store
    }

    private func seededBitmap(width: Int, height: Int, seed: UInt8) -> RawBitmap {
        var pixels = Data(capacity: width * height * 4)
        for index in 0..<(width * height) {
            let value = seed &+ UInt8(truncatingIfNeeded: index)
            pixels.append(value)
            pixels.append(value &* 3 &+ 1)
            pixels.append(value &* 5 &+ 2)
            pixels.append(0xff)
        }
        return RawBitmap(
            format: .xRGB8888,
            width: width,
            height: height,
            stride: width * 4,
            topDown: true,
            pixels: pixels
        )
    }

    private func copiedPixels(
        from snapshot: FrameSnapshot,
        sourceSnapshot: FrameSnapshot? = nil,
        source: PixelRect,
        destination: PixelRect,
        region: PixelRegion
    ) -> Data {
        let sourceSnapshot = sourceSnapshot ?? snapshot
        var expected = snapshot.pixels
        for rectangle in region {
            for destinationY in rectangle.y..<(rectangle.y + rectangle.height) {
                for destinationX in rectangle.x..<(rectangle.x + rectangle.width) {
                    let sourceX = source.x + destinationX - destination.x
                    let sourceY = source.y + destinationY - destination.y
                    let sourceOffset = sourceY * sourceSnapshot.bytesPerRow + sourceX * 4
                    let destinationOffset = destinationY * snapshot.bytesPerRow
                        + destinationX * 4
                    expected.replaceSubrange(
                        destinationOffset..<(destinationOffset + 4),
                        with: sourceSnapshot.pixels[sourceOffset..<(sourceOffset + 4)]
                    )
                }
            }
        }
        return expected
    }

    private func replacePixel(
        in pixels: inout Data,
        bytesPerRow: Int,
        x: Int,
        y: Int,
        with replacement: [UInt8]
    ) {
        let offset = y * bytesPerRow + x * 4
        pixels.replaceSubrange(offset..<(offset + 4), with: replacement)
    }

    private func copyPixels(
        in pixels: inout Data,
        bytesPerRow: Int,
        source: PixelRect,
        destination: PixelRect
    ) {
        let before = pixels
        copyPixels(
            from: before,
            sourceBytesPerRow: bytesPerRow,
            in: &pixels,
            destinationBytesPerRow: bytesPerRow,
            source: source,
            destination: destination
        )
    }

    private func copyPixels(
        from sourcePixels: Data,
        sourceBytesPerRow: Int,
        in destinationPixels: inout Data,
        destinationBytesPerRow: Int,
        source: PixelRect,
        destination: PixelRect
    ) {
        for row in 0..<destination.height {
            for column in 0..<destination.width {
                let sourceOffset = (source.y + row) * sourceBytesPerRow
                    + (source.x + column) * 4
                let destinationOffset = (destination.y + row) * destinationBytesPerRow
                    + (destination.x + column) * 4
                destinationPixels.replaceSubrange(
                    destinationOffset..<(destinationOffset + 4),
                    with: sourcePixels[sourceOffset..<(sourceOffset + 4)]
                )
            }
        }
    }

    private func pixel(_ snapshot: FrameSnapshot, x: Int, y: Int) -> [UInt8] {
        let offset = y * snapshot.bytesPerRow + x * 4
        return Array(snapshot.pixels[offset..<(offset + 4)])
    }

    private func makeNV12PixelBuffer(
        width: Int,
        height: Int,
        luma: UInt8,
        matrix: CFString
    ) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw TestError.pixelBuffer(status)
        }
        CVBufferSetAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            matrix,
            .shouldPropagate
        )
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else {
            throw TestError.pixelBufferLock
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            throw TestError.pixelBufferPlanes
        }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        lumaBase.initializeMemory(
            as: UInt8.self,
            repeating: luma,
            count: lumaStride * height
        )
        chromaBase.initializeMemory(
            as: UInt8.self,
            repeating: 128,
            count: chromaStride * (height / 2)
        )
        return pixelBuffer
    }
}

struct CopyVector: Sendable, CustomTestStringConvertible {
    let name: String
    let deltaX: Int
    let deltaY: Int

    var testDescription: String { name }

    static let overlappingDirections: [Self] = [
        Self(name: "N", deltaX: 0, deltaY: -1),
        Self(name: "NE", deltaX: 1, deltaY: -1),
        Self(name: "E", deltaX: 1, deltaY: 0),
        Self(name: "SE", deltaX: 1, deltaY: 1),
        Self(name: "S", deltaX: 0, deltaY: 1),
        Self(name: "SW", deltaX: -1, deltaY: 1),
        Self(name: "W", deltaX: -1, deltaY: 0),
        Self(name: "NW", deltaX: -1, deltaY: -1),
    ]

    static let singleRectangleCases: [Self] = overlappingDirections + [
        Self(name: "zero displacement", deltaX: 0, deltaY: 0),
        Self(name: "horizontal overlap boundary", deltaX: 3, deltaY: 0),
        Self(name: "vertical overlap boundary", deltaX: 0, deltaY: 3),
    ]
}

enum SurfaceCopyCommand: CaseIterable, Sendable {
    case regionCopyBits
    case regionSameSurfaceDrawCopy
    case regionCrossSurfaceDrawCopy
    case rectangleCopyBits
    case rectangleSameSurfaceDrawCopy
    case rectangleCrossSurfaceDrawCopy

    var isRegionTransaction: Bool {
        switch self {
        case .regionCopyBits, .regionSameSurfaceDrawCopy, .regionCrossSurfaceDrawCopy:
            true
        case .rectangleCopyBits,
             .rectangleSameSurfaceDrawCopy,
             .rectangleCrossSurfaceDrawCopy:
            false
        }
    }

    var usesCrossSurface: Bool {
        switch self {
        case .regionCrossSurfaceDrawCopy, .rectangleCrossSurfaceDrawCopy:
            true
        default:
            false
        }
    }
}

struct CopyKernelCase: Sendable, CustomTestStringConvertible {
    let name: String
    let surfaceWidth: Int
    let surfaceHeight: Int
    let destination: PixelRect
    let source: PixelRect
    let crossSurface: Bool
    let expectedBulkCalls: UInt64
    let expectedRowCalls: UInt64

    var testDescription: String { name }

    static let cases: [Self] = [
        Self(
            name: "tightly packed full cross-Surface copy",
            surfaceWidth: 4,
            surfaceHeight: 3,
            destination: PixelRect(x: 0, y: 0, width: 4, height: 3),
            source: PixelRect(x: 0, y: 0, width: 4, height: 3),
            crossSurface: true,
            expectedBulkCalls: 1,
            expectedRowCalls: 0
        ),
        Self(
            name: "non-contiguous cross-Surface subrectangle",
            surfaceWidth: 6,
            surfaceHeight: 5,
            destination: PixelRect(x: 1, y: 1, width: 3, height: 3),
            source: PixelRect(x: 2, y: 0, width: 3, height: 3),
            crossSurface: true,
            expectedBulkCalls: 0,
            expectedRowCalls: 3
        ),
        Self(
            name: "overlapping same-Surface subrectangle",
            surfaceWidth: 6,
            surfaceHeight: 5,
            destination: PixelRect(x: 2, y: 1, width: 3, height: 3),
            source: PixelRect(x: 1, y: 1, width: 3, height: 3),
            crossSurface: false,
            expectedBulkCalls: 0,
            expectedRowCalls: 3
        ),
        Self(
            name: "single-row horizontal same-Surface overlap",
            surfaceWidth: 6,
            surfaceHeight: 3,
            destination: PixelRect(x: 2, y: 1, width: 3, height: 1),
            source: PixelRect(x: 1, y: 1, width: 3, height: 1),
            crossSurface: false,
            expectedBulkCalls: 0,
            expectedRowCalls: 1
        ),
        Self(
            name: "full-width vertical same-Surface overlap",
            surfaceWidth: 6,
            surfaceHeight: 5,
            destination: PixelRect(x: 0, y: 1, width: 6, height: 3),
            source: PixelRect(x: 0, y: 0, width: 6, height: 3),
            crossSurface: false,
            expectedBulkCalls: 0,
            expectedRowCalls: 3
        ),
    ]
}

struct FillKernelCase: Sendable, CustomTestStringConvertible {
    let name: String
    let format: UInt32
    let expectedAlpha: UInt8

    var testDescription: String { name }

    static let cases: [Self] = [
        Self(name: "ARGB8888 preserves alpha", format: 96, expectedAlpha: 0x7f),
        Self(name: "xRGB8888 forces opaque alpha", format: 32, expectedAlpha: 0xff),
    ]
}

enum CanonicalCPUMutation: CaseIterable, Sendable {
    case fill
    case sameSurfaceCopyBits
    case partialBitmapDrawCopy
    case crossSurfaceDrawCopy
}

private enum TestError: Error {
    case pixelBuffer(CVReturn)
    case pixelBufferLock
    case pixelBufferPlanes
}
