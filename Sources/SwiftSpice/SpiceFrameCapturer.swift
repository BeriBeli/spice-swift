import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import IOSurface
import UniformTypeIdentifiers

public struct SpiceFrameCaptureRequest: Sendable, Equatable {
    public var region: CGRect?
    public var maximumEdge: Int
    public var maximumPixels: Int
    public var includesCursor: Bool

    public init(
        region: CGRect? = nil,
        maximumEdge: Int = 1_280,
        maximumPixels: Int = 1_200_000,
        includesCursor: Bool = true
    ) {
        self.region = region
        self.maximumEdge = maximumEdge
        self.maximumPixels = maximumPixels
        self.includesCursor = includesCursor
    }
}

public struct SpiceCapturedFrame: Sendable, Equatable {
    public let png: Data
    public let width: Int
    public let height: Int
    public let crop: CGRect

    public init(png: consuming Data, width: Int, height: Int, crop: CGRect) {
        self.png = png
        self.width = width
        self.height = height
        self.crop = crop
    }
}

public enum SpiceFrameCaptureError: Error, Sendable, Equatable {
    case noFrame
    case invalidRegion
    case budgetExceeded
    case unsupportedCursor
    case encodeFailed
    case cancelled
}

public actor SpiceFrameCapturer {
    public static let maximumEdgeLimit = 2_048
    public static let maximumPixelLimit = 1_200_000
    public static let normalPNGByteLimit = 2 * 1_024 * 1_024
    public static let absolutePNGByteLimit = 6 * 1_024 * 1_024

    private let normalPNGByteLimit: Int
    private let encoder: @Sendable (CGImage) -> Data?

    public init() {
        normalPNGByteLimit = Self.normalPNGByteLimit
        encoder = Self.encodePNG
    }

    init(normalPNGByteLimit: Int) {
        self.normalPNGByteLimit = min(
            max(1, normalPNGByteLimit),
            Self.normalPNGByteLimit
        )
        encoder = Self.encodePNG
    }

    init(encoder: @escaping @Sendable (CGImage) -> Data?) {
        normalPNGByteLimit = Self.normalPNGByteLimit
        self.encoder = encoder
    }

    public func capturePNG(
        frame: SpiceFrame,
        cursor: SpiceCursorState?,
        request: SpiceFrameCaptureRequest
    ) async throws(SpiceFrameCaptureError) -> SpiceCapturedFrame {
        try checkCancellation()
        let plan = try CapturePlan(frame: frame, request: request)
        let rendered = try renderFrame(
            frame: frame,
            cursor: cursor,
            plan: plan,
            includesCursor: request.includesCursor
        )
        try checkCancellation()
        guard let png = encoder(rendered.image) else {
            throw SpiceFrameCaptureError.encodeFailed
        }
        guard png.count <= normalPNGByteLimit,
              png.count <= Self.absolutePNGByteLimit else {
            throw SpiceFrameCaptureError.budgetExceeded
        }
        withExtendedLifetime(rendered) {}
        try checkCancellation()
        return SpiceCapturedFrame(
            png: png,
            width: plan.outputWidth,
            height: plan.outputHeight,
            crop: plan.crop
        )
    }

    public func capturePNG(
        frame: SpiceFrame?,
        cursor: SpiceCursorState?,
        request: SpiceFrameCaptureRequest
    ) async throws(SpiceFrameCaptureError) -> SpiceCapturedFrame {
        guard let frame else { throw SpiceFrameCaptureError.noFrame }
        return try await capturePNG(frame: frame, cursor: cursor, request: request)
    }

    private func checkCancellation() throws(SpiceFrameCaptureError) {
        guard !Task.isCancelled else {
            throw SpiceFrameCaptureError.cancelled
        }
    }

    private func makeSourceImage(_ frame: SpiceFrame) throws(SpiceFrameCaptureError) -> SourceImage {
        let (minimumBytesPerRow, rowOverflow) = frame.width.multipliedReportingOverflow(by: 4)
        guard frame.width > 0,
              frame.height > 0,
              !rowOverflow,
              frame.bytesPerRow >= minimumBytesPerRow
        else {
            throw SpiceFrameCaptureError.invalidRegion
        }
        if let ioSurface = frame.ioSurface {
            guard ioSurface.width == frame.width,
                  ioSurface.height == frame.height,
                  ioSurface.bytesPerRow == frame.bytesPerRow,
                  ioSurface.pixelFormat == kCVPixelFormatType_32BGRA,
                  let source = IOSurfaceSource(frame: ioSurface)
            else {
                throw SpiceFrameCaptureError.encodeFailed
            }
            return SourceImage(image: source.image, owner: source)
        }

        let (byteCount, overflow) = frame.bytesPerRow.multipliedReportingOverflow(
            by: frame.height
        )
        guard !overflow else { throw SpiceFrameCaptureError.budgetExceeded }
        let pixels = frame.pixels
        guard pixels.count == byteCount,
              let provider = CGDataProvider(data: pixels as CFData),
              let image = makeBGRAImage(
                  width: frame.width,
                  height: frame.height,
                  bytesPerRow: frame.bytesPerRow,
                  provider: provider
              )
        else {
            throw SpiceFrameCaptureError.encodeFailed
        }
        return SourceImage(image: image, owner: pixels as NSData)
    }

    private func renderFrame(
        frame: SpiceFrame,
        cursor: SpiceCursorState?,
        plan: CapturePlan,
        includesCursor: Bool
    ) throws(SpiceFrameCaptureError) -> RenderedImage {
        let source = try makeSourceImage(frame)
        let rendered = try render(
            source: source.image,
            frame: frame,
            cursor: cursor,
            plan: plan,
            includesCursor: includesCursor
        )
        withExtendedLifetime(source) {}
        return rendered
    }

    private func render(
        source: CGImage,
        frame: SpiceFrame,
        cursor: SpiceCursorState?,
        plan: CapturePlan,
        includesCursor: Bool
    ) throws(SpiceFrameCaptureError) -> RenderedImage {
        let (rowBytes, rowOverflow) = plan.outputWidth.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(
            by: plan.outputHeight
        )
        guard !rowOverflow, !sizeOverflow else {
            throw SpiceFrameCaptureError.budgetExceeded
        }

        var output = Data(count: byteCount)
        let image: CGImage
        do {
            image = try output.withUnsafeMutableBytes { bytes -> CGImage in
                guard let baseAddress = bytes.baseAddress,
                      let context = CGContext(
                          data: baseAddress,
                          width: plan.outputWidth,
                          height: plan.outputHeight,
                          bitsPerComponent: 8,
                          bytesPerRow: rowBytes,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: bgraBitmapInfo.rawValue
                      )
                else {
                    throw SpiceFrameCaptureError.encodeFailed
                }

                context.interpolationQuality = .high
                context.translateBy(x: 0, y: CGFloat(plan.outputHeight))
                context.scaleBy(x: 1, y: -1)
                context.scaleBy(x: plan.scaleX, y: plan.scaleY)
                context.translateBy(x: -plan.crop.minX, y: -plan.crop.minY)
                context.saveGState()
                context.translateBy(x: 0, y: CGFloat(frame.height))
                context.scaleBy(x: 1, y: -1)
                context.draw(
                    source,
                    in: CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
                )
                context.restoreGState()
                if includesCursor {
                    try drawCursor(cursor, in: context)
                }
                guard let rendered = context.makeImage() else {
                    throw SpiceFrameCaptureError.encodeFailed
                }
                return rendered
            }
        } catch let error as SpiceFrameCaptureError {
            throw error
        } catch {
            throw SpiceFrameCaptureError.encodeFailed
        }
        return RenderedImage(image: image, storage: output)
    }

    private func drawCursor(
        _ state: SpiceCursorState?,
        in context: CGContext
    ) throws(SpiceFrameCaptureError) {
        guard let state, state.isVisible, let cursor = state.image else { return }
        guard cursor.format == .alpha else {
            throw SpiceFrameCaptureError.unsupportedCursor
        }
        let (rowBytes, rowOverflow) = cursor.width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = rowBytes.multipliedReportingOverflow(by: cursor.height)
        guard cursor.width > 0,
              cursor.height > 0,
              !rowOverflow,
              !sizeOverflow,
              cursor.data.count == byteCount,
              let provider = CGDataProvider(data: cursor.data as CFData),
              let image = makeBGRAImage(
                  width: cursor.width,
                  height: cursor.height,
                  bytesPerRow: rowBytes,
                  provider: provider
              )
        else {
            throw SpiceFrameCaptureError.unsupportedCursor
        }
        context.setBlendMode(.normal)
        context.interpolationQuality = .none
        let rectangle = CGRect(
            x: state.x - cursor.hotSpotX,
            y: state.y - cursor.hotSpotY,
            width: cursor.width,
            height: cursor.height
        )
        context.saveGState()
        context.translateBy(x: rectangle.minX, y: rectangle.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: rectangle.width, height: rectangle.height)
        )
        context.restoreGState()
    }

    private nonisolated static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

private let bgraBitmapInfo = CGBitmapInfo.byteOrder32Little.union(
    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
)

private func makeBGRAImage(
    width: Int,
    height: Int,
    bytesPerRow: Int,
    provider: CGDataProvider
) -> CGImage? {
    CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bgraBitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )
}

private struct SourceImage {
    let image: CGImage
    let owner: AnyObject
}

private struct RenderedImage {
    let image: CGImage
    let storage: Data
}

private final class IOSurfaceSource: @unchecked Sendable {
    let image: CGImage
    private let surface: IOSurfaceRef
    private var seed: UInt32 = 0
    private var isLocked = false

    init?(frame: SpiceIOSurfaceFrame) {
        var retainedSurface: IOSurfaceRef?
        frame.backing.withIOSurface { retainedSurface = $0 }
        guard let surface = retainedSurface else { return nil }
        self.surface = surface
        guard IOSurfaceLock(surface, .readOnly, &seed) == 0 else { return nil }
        isLocked = true
        let (byteCount, overflow) = frame.bytesPerRow.multipliedReportingOverflow(
            by: frame.height
        )
        guard !overflow else {
            IOSurfaceUnlock(surface, .readOnly, &seed)
            isLocked = false
            return nil
        }
        guard let provider = CGDataProvider(
            dataInfo: nil,
            data: IOSurfaceGetBaseAddress(surface),
            size: byteCount,
            releaseData: { _, _, _ in }
        ), let image = makeBGRAImage(
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            provider: provider
        ) else {
            IOSurfaceUnlock(surface, .readOnly, &seed)
            isLocked = false
            return nil
        }
        self.image = image
    }

    deinit {
        if isLocked {
            IOSurfaceUnlock(surface, .readOnly, &seed)
        }
    }
}

private struct CapturePlan {
    let crop: CGRect
    let outputWidth: Int
    let outputHeight: Int
    let scaleX: CGFloat
    let scaleY: CGFloat

    init(frame: SpiceFrame, request: SpiceFrameCaptureRequest) throws(SpiceFrameCaptureError) {
        guard frame.width > 0,
              frame.height > 0,
              request.maximumEdge > 0,
              request.maximumEdge <= SpiceFrameCapturer.maximumEdgeLimit,
              request.maximumPixels > 0,
              request.maximumPixels <= SpiceFrameCapturer.maximumPixelLimit
        else {
            throw SpiceFrameCaptureError.budgetExceeded
        }
        let frameRect = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let crop = request.region ?? frameRect
        guard crop.origin.x.isFinite,
              crop.origin.y.isFinite,
              crop.width.isFinite,
              crop.height.isFinite,
              crop.width > 0,
              crop.height > 0,
              crop.minX.rounded() == crop.minX,
              crop.minY.rounded() == crop.minY,
              crop.maxX.rounded() == crop.maxX,
              crop.maxY.rounded() == crop.maxY,
              frameRect.contains(crop)
        else {
            throw SpiceFrameCaptureError.invalidRegion
        }
        let maximumEdgeScale = CGFloat(request.maximumEdge) / max(crop.width, crop.height)
        let maximumPixelScale = sqrt(CGFloat(request.maximumPixels) / (crop.width * crop.height))
        let scale = min(1, maximumEdgeScale, maximumPixelScale)
        guard scale.isFinite, scale > 0 else {
            throw SpiceFrameCaptureError.budgetExceeded
        }
        let outputWidth = max(1, Int((crop.width * scale).rounded(.down)))
        let outputHeight = max(1, Int((crop.height * scale).rounded(.down)))
        let (pixels, overflow) = outputWidth.multipliedReportingOverflow(by: outputHeight)
        guard !overflow,
              outputWidth <= request.maximumEdge,
              outputHeight <= request.maximumEdge,
              pixels <= request.maximumPixels
        else {
            throw SpiceFrameCaptureError.budgetExceeded
        }
        self.crop = crop
        self.outputWidth = outputWidth
        self.outputHeight = outputHeight
        scaleX = CGFloat(outputWidth) / crop.width
        scaleY = CGFloat(outputHeight) / crop.height
    }
}
