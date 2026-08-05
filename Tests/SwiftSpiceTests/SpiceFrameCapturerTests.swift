import CoreGraphics
import CoreVideo
import ImageIO
import IOSurface
import Metal
import Testing
@testable import SpiceIOSurface
@testable import SpiceRenderer
@testable import SwiftSpice

private let runsFourKHostCapture = ProcessInfo.processInfo.environment[
    "SPICE_CAPTURE_4K_HOST_TEST"
] == "1"

@Suite("Bounded frame capture")
struct SpiceFrameCapturerTests {
    @Test func cpuCaptureHonorsCropScaleAndPNGContract() async throws {
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 4,
            height: 2,
            bytesPerRow: 16,
            pixels: Data(repeating: 0x7f, count: 32)
        )
        let captured = try await SpiceFrameCapturer().capturePNG(
            frame: frame,
            cursor: nil,
            request: SpiceFrameCaptureRequest(
                region: CGRect(x: 1, y: 0, width: 2, height: 2),
                maximumEdge: 1,
                maximumPixels: 1,
                includesCursor: false
            )
        )

        #expect(captured.width == 1)
        #expect(captured.height == 1)
        #expect(captured.crop == CGRect(x: 1, y: 0, width: 2, height: 2))
        let image = try #require(decode(captured.png))
        #expect(image.width == 1)
        #expect(image.height == 1)
    }

    @Test func cropCoordinatesUseTopLeftFrameOrigin() async throws {
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixels: Data([
                0x00, 0x00, 0xff, 0xff, 0x00, 0xff, 0x00, 0xff,
                0xff, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff,
            ])
        )
        let captured = try await SpiceFrameCapturer().capturePNG(
            frame: frame,
            cursor: nil,
            request: SpiceFrameCaptureRequest(
                region: CGRect(x: 0, y: 0, width: 1, height: 1),
                maximumEdge: 1,
                maximumPixels: 1,
                includesCursor: false
            )
        )

        let decoded = try decodeBGRA(captured.png)
        #expect(
            decoded == Data([0x00, 0x00, 0xff, 0xff]),
            "top-left pixel was \(decoded as NSData)"
        )
    }

    @Test func invalidRegionsAndBudgetsFailClosed() async throws {
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixels: Data(repeating: 0, count: 16)
        )
        let capturer = SpiceFrameCapturer()
        await #expect(throws: SpiceFrameCaptureError.invalidRegion) {
            try await capturer.capturePNG(
                frame: frame,
                cursor: nil,
                request: SpiceFrameCaptureRequest(
                    region: CGRect(x: -1, y: 0, width: 2, height: 2),
                    maximumEdge: 2,
                    maximumPixels: 4,
                    includesCursor: false
                )
            )
        }
        await #expect(throws: SpiceFrameCaptureError.budgetExceeded) {
            try await capturer.capturePNG(
                frame: frame,
                cursor: nil,
                request: SpiceFrameCaptureRequest(maximumEdge: 0)
            )
        }
        await #expect(throws: SpiceFrameCaptureError.budgetExceeded) {
            try await capturer.capturePNG(
                frame: frame,
                cursor: nil,
                request: SpiceFrameCaptureRequest(
                    maximumEdge: SpiceFrameCapturer.maximumEdgeLimit + 1
                )
            )
        }
        await #expect(throws: SpiceFrameCaptureError.budgetExceeded) {
            try await capturer.capturePNG(
                frame: frame,
                cursor: nil,
                request: SpiceFrameCaptureRequest(
                    maximumPixels: SpiceFrameCapturer.maximumPixelLimit + 1
                )
            )
        }
        await #expect(throws: SpiceFrameCaptureError.noFrame) {
            try await capturer.capturePNG(
                frame: nil,
                cursor: nil,
                request: SpiceFrameCaptureRequest()
            )
        }
    }

    @Test func cancellationStopsBeforeReadingFramePixels() async throws {
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixels: Data(repeating: 0, count: 16)
        )
        let task = Task {
            try await SpiceFrameCapturer().capturePNG(
                frame: frame,
                cursor: nil,
                request: SpiceFrameCaptureRequest()
            )
        }
        task.cancel()
        await #expect(throws: SpiceFrameCaptureError.cancelled) {
            try await task.value
        }
    }

    @Test func unsupportedCursorDoesNotSilentlyDisappear() async throws {
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixels: Data(repeating: 0, count: 16)
        )
        let cursor = SpiceCursorState(
            x: 0,
            y: 0,
            isVisible: true,
            image: SpiceCursorImage(
                id: 1,
                format: .color24,
                width: 1,
                height: 1,
                hotSpotX: 0,
                hotSpotY: 0,
                data: Data([0, 0, 0])
            )
        )
        await #expect(throws: SpiceFrameCaptureError.unsupportedCursor) {
            try await SpiceFrameCapturer().capturePNG(
                frame: frame,
                cursor: cursor,
                request: SpiceFrameCaptureRequest(includesCursor: true)
            )
        }
    }

    @Test func cursorHotspotAndBoundsAreClippedAndCanBeExcluded() async throws {
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 4,
            height: 4,
            bytesPerRow: 16,
            pixels: Data(repeating: 0, count: 64)
        )
        let image = SpiceCursorImage(
            id: 2,
            format: .alpha,
            width: 2,
            height: 2,
            hotSpotX: 1,
            hotSpotY: 1,
            data: Data(repeating: 0xff, count: 16)
        )
        let capturer = SpiceFrameCapturer()
        let withoutCursor = try await capturer.capturePNG(
            frame: frame,
            cursor: SpiceCursorState(x: 0, y: 0, isVisible: true, image: image),
            request: SpiceFrameCaptureRequest(includesCursor: false)
        )
        let partiallyVisible = try await capturer.capturePNG(
            frame: frame,
            cursor: SpiceCursorState(x: 0, y: 0, isVisible: true, image: image),
            request: SpiceFrameCaptureRequest(includesCursor: true)
        )
        let outside = try await capturer.capturePNG(
            frame: frame,
            cursor: SpiceCursorState(x: -10, y: -10, isVisible: true, image: image),
            request: SpiceFrameCaptureRequest(includesCursor: true)
        )

        #expect(partiallyVisible.png != withoutCursor.png)
        #expect(outside.png == withoutCursor.png)
    }

    @Test func cpuAndIOSurfaceCapturesMatchForCropScaleAndCursor() async throws {
        let width = 64
        let height = 64
        let rowBytes = width * 4
        let pixels = Data((0..<(width * height)).flatMap { _ in
            [UInt8(0x30), 0x20, 0x10, 0xff]
        })
        let cpuFrame = SpiceFrame(
            surfaceID: 1,
            width: width,
            height: height,
            bytesPerRow: rowBytes,
            pixels: pixels
        )
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        var seed: UInt32 = 0
        #expect(IOSurfaceLock(surface, [], &seed) == 0)
        IOSurfaceGetBaseAddress(surface).copyMemory(from: [UInt8](pixels), byteCount: pixels.count)
        IOSurfaceUnlock(surface, [], &seed)
        let ioSurface = IOSurfaceFrame(
            surface: surface,
            width: width,
            height: height,
            bytesPerRow: IOSurfaceGetBytesPerRow(surface),
            pixelFormat: kCVPixelFormatType_32BGRA,
            release: {}
        )
        let ioFrame = SpiceFrame(FrameSnapshot(
            surfaceID: 2,
            width: width,
            height: height,
            bytesPerRow: IOSurfaceGetBytesPerRow(surface),
            pixels: nil,
            ioSurfaceFrame: ioSurface
        ))
        let cursor = SpiceCursorState(
            x: 32,
            y: 32,
            isVisible: true,
            image: SpiceCursorImage(
                id: 9,
                format: .alpha,
                width: 1,
                height: 1,
                hotSpotX: 0,
                hotSpotY: 0,
                data: Data([0, 0, 0xff, 0xff])
            )
        )
        let request = SpiceFrameCaptureRequest(
            maximumEdge: 64,
            maximumPixels: 64 * 64,
            includesCursor: true
        )
        let capturer = SpiceFrameCapturer()
        let cpu = try await capturer.capturePNG(
            frame: cpuFrame,
            cursor: cursor,
            request: request
        )
        let io = try await capturer.capturePNG(
            frame: ioFrame,
            cursor: cursor,
            request: request
        )
        let withoutCursor = try await capturer.capturePNG(
            frame: cpuFrame,
            cursor: cursor,
            request: SpiceFrameCaptureRequest(
                maximumEdge: 64,
                maximumPixels: 64 * 64,
                includesCursor: false
            )
        )

        #expect(cpu.png == io.png)
        #expect(cpu.png != withoutCursor.png)
        #expect(cpu.width == io.width)
        #expect(cpu.height == io.height)
    }

    @Test func encodedByteLimitFailsAsBudgetInsteadOfReturningLargePNG() async throws {
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixels: Data(repeating: 0x7f, count: 16)
        )
        await #expect(throws: SpiceFrameCaptureError.budgetExceeded) {
            try await SpiceFrameCapturer(normalPNGByteLimit: 1).capturePNG(
                frame: frame,
                cursor: nil,
                request: SpiceFrameCaptureRequest(includesCursor: false)
            )
        }
    }

    @Test func encoderFailureIsReportedWithoutReturningPartialData() async throws {
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixels: Data(repeating: 0x7f, count: 16)
        )
        await #expect(throws: SpiceFrameCaptureError.encodeFailed) {
            try await SpiceFrameCapturer(encoder: { _ in nil }).capturePNG(
                frame: frame,
                cursor: nil,
                request: SpiceFrameCaptureRequest(includesCursor: false)
            )
        }
    }

    @Test(.enabled(if: runsFourKHostCapture))
    func fourKIOSurfaceCaptureAvoidsFullFrameMaterialization() async throws {
        let cpu1080 = SpiceFrame(
            surfaceID: 98,
            width: 1_920,
            height: 1_080,
            bytesPerRow: 1_920 * 4,
            pixels: Data(repeating: 0x44, count: 1_920 * 1_080 * 4)
        )
        let cpu1080Capture = try await SpiceFrameCapturer().capturePNG(
            frame: cpu1080,
            cursor: nil,
            request: SpiceFrameCaptureRequest(includesCursor: false)
        )
        #expect(cpu1080Capture.width == 1_280)
        #expect(cpu1080Capture.height == 720)

        let device = try #require(MTLCreateSystemDefaultDevice())
        let pool = try #require(RevisionedIOSurfacePool(
            device: device,
            limits: .init(maximumFramesPerSurface: 3, maximumBytes: 128 * 1_024 * 1_024)
        ))
        let store = SurfaceStore(backingPolicy: .revisionedIOSurface(pool))
        try await store.create(id: 99, width: 3_840, height: 2_160, format: 32)
        try await store.fill(
            surfaceID: 99,
            rectangle: PixelRect(x: 0, y: 0, width: 3_840, height: 2_160),
            colorARGB: 0x0011_2233
        )
        var frame: SpiceFrame? = SpiceFrame(try await store.snapshot(surfaceID: 99))
        #expect(frame?.ioSurface != nil)
        #expect(pool.metrics().inFlightLeases == 1)
        let before = await store.metrics().cpuMaterializations

        let captured = try await SpiceFrameCapturer().capturePNG(
            frame: try #require(frame),
            cursor: nil,
            request: SpiceFrameCaptureRequest(
                maximumEdge: 1_280,
                maximumPixels: 1_200_000,
                includesCursor: false
            )
        )

        #expect(captured.width == 1_280)
        #expect(captured.height == 720)
        #expect(captured.png.count <= SpiceFrameCapturer.normalPNGByteLimit)
        #expect(await store.metrics().cpuMaterializations == before)
        frame = nil
        try await store.destroy(id: 99)
        #expect(pool.metrics().inFlightLeases == 0)
    }

    private func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private func decodeBGRA(_ data: Data) throws -> Data {
        let image = try #require(decode(data))
        let rowBytes = image.width * 4
        var pixels = Data(count: rowBytes * image.height)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(
                data: bytes.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: rowBytes,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                )).rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
}
