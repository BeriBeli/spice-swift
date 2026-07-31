import Foundation
import SpiceIOSurface
import Testing
@testable import SpiceRenderer

@Suite("SurfaceStore")
struct SurfaceStoreTests {
    @Test func createsFillsCopiesAndDestroysSurface() async throws {
        let store = SurfaceStore()
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

    @Test func drawsTopDownAndBottomUpRawBitmaps() async throws {
        let topDownStore = SurfaceStore()
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

        let bottomUpStore = SurfaceStore()
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
        let argbStore = SurfaceStore()
        try await argbStore.create(id: 1, width: 1, height: 1, format: 96)
        try await argbStore.drawCopy(
            surfaceID: 1,
            destination: PixelRect(x: 0, y: 0, width: 1, height: 1),
            bitmap: source
        )
        #expect(try await argbStore.snapshot(surfaceID: 1).pixels == Data([1, 2, 3, 0x44]))

        let xrgbStore = SurfaceStore()
        try await xrgbStore.create(id: 2, width: 1, height: 1, format: 32)
        try await xrgbStore.drawCopy(
            surfaceID: 2,
            destination: PixelRect(x: 0, y: 0, width: 1, height: 1),
            bitmap: source
        )
        #expect(try await xrgbStore.snapshot(surfaceID: 2).pixels == Data([1, 2, 3, 0xff]))
    }

    @Test func rejectsUnboundedOrMalformedInputs() async throws {
        let store = SurfaceStore(limits: RenderLimits(
            maximumDimension: 64,
            maximumSurfaceBytes: 64
        ))
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

    @Test func publishesIOSurfaceAlongsideImmutablePixels() async throws {
        let store = SurfaceStore()
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

    @Test func fallsBackToDataWhenAllLeasesAreInUse() async throws {
        let pool = IOSurfaceFramePool(limits: .init(
            maximumFrames: 1,
            maximumBytes: 1_024 * 1_024
        ))
        let store = SurfaceStore(framePool: pool)
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

    private func pixel(_ snapshot: FrameSnapshot, x: Int, y: Int) -> [UInt8] {
        let offset = y * snapshot.bytesPerRow + x * 4
        return Array(snapshot.pixels[offset..<(offset + 4)])
    }
}
