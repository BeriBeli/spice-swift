import Foundation
import SpiceIOSurface

package enum SurfacePixelFormat: UInt32, Sendable, Equatable {
    case xRGB8888 = 32
    case argb8888 = 96
}

package enum RawBitmapFormat: UInt8, Sendable, Equatable {
    case xRGB8888 = 8
    case argb8888 = 9
}

package struct PixelRect: Sendable, Equatable {
    package let x: Int
    package let y: Int
    package let width: Int
    package let height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package struct RawBitmap: Sendable, Equatable {
    package let format: RawBitmapFormat
    package let width: Int
    package let height: Int
    package let stride: Int
    package let topDown: Bool
    package let pixels: Data

    package init(
        format: RawBitmapFormat,
        width: Int,
        height: Int,
        stride: Int,
        topDown: Bool,
        pixels: consuming Data
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.stride = stride
        self.topDown = topDown
        self.pixels = pixels
    }
}

package struct FrameSnapshot: Sendable, Equatable {
    package let surfaceID: UInt32
    package let width: Int
    package let height: Int
    package let bytesPerRow: Int
    package let pixels: Data
    package let ioSurfaceFrame: IOSurfaceFrame?

    package static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.surfaceID == rhs.surfaceID
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.bytesPerRow == rhs.bytesPerRow
            && lhs.pixels == rhs.pixels
    }
}

package struct RenderLimits: Sendable, Equatable {
    package var maximumDimension: Int
    package var maximumSurfaceBytes: Int

    package init(
        maximumDimension: Int = 16_384,
        maximumSurfaceBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumDimension = maximumDimension
        self.maximumSurfaceBytes = maximumSurfaceBytes
    }
}

package enum RenderError: Error, Sendable, Equatable {
    case duplicateSurface(UInt32)
    case unknownSurface(UInt32)
    case unsupportedSurfaceFormat(UInt32)
    case invalidDimensions(width: Int, height: Int)
    case surfaceTooLarge(bytes: Int, maximum: Int)
    case invalidRectangle
    case invalidBitmap
    case integerOverflow
}

package actor SurfaceStore {
    private struct Surface: Sendable {
        let id: UInt32
        let width: Int
        let height: Int
        let format: SurfacePixelFormat
        var pixels: Data

        var bytesPerRow: Int { width * 4 }
    }

    private let limits: RenderLimits
    private let framePool: IOSurfaceFramePool
    private var surfaces: [UInt32: Surface] = [:]

    package init(
        limits: RenderLimits = .init(),
        framePool: IOSurfaceFramePool = .init()
    ) {
        self.limits = limits
        self.framePool = framePool
    }

    package func create(
        id: UInt32,
        width: UInt32,
        height: UInt32,
        format rawFormat: UInt32
    ) throws(RenderError) {
        guard surfaces[id] == nil else {
            throw .duplicateSurface(id)
        }
        guard let width = Int(exactly: width), let height = Int(exactly: height),
              width > 0, height > 0,
              width <= limits.maximumDimension, height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: Int(width), height: Int(height))
        }
        guard let format = SurfacePixelFormat(rawValue: rawFormat) else {
            throw .unsupportedSurfaceFormat(rawFormat)
        }
        let byteCount = try checkedByteCount(width: width, height: height)
        surfaces[id] = Surface(
            id: id,
            width: width,
            height: height,
            format: format,
            pixels: Data(repeating: 0, count: byteCount)
        )
    }

    package func destroy(id: UInt32) throws(RenderError) {
        guard surfaces.removeValue(forKey: id) != nil else {
            throw .unknownSurface(id)
        }
    }

    package func fill(
        surfaceID: UInt32,
        rectangle: PixelRect,
        colorARGB: UInt32
    ) throws(RenderError) {
        var surface = try surface(id: surfaceID)
        try validate(rectangle, in: surface)
        let blue = UInt8(truncatingIfNeeded: colorARGB)
        let green = UInt8(truncatingIfNeeded: colorARGB >> 8)
        let red = UInt8(truncatingIfNeeded: colorARGB >> 16)
        let alpha = surface.format == .argb8888
            ? UInt8(truncatingIfNeeded: colorARGB >> 24)
            : 255
        for y in rectangle.y..<(rectangle.y + rectangle.height) {
            for x in rectangle.x..<(rectangle.x + rectangle.width) {
                let offset = y * surface.bytesPerRow + x * 4
                surface.pixels[offset] = blue
                surface.pixels[offset + 1] = green
                surface.pixels[offset + 2] = red
                surface.pixels[offset + 3] = alpha
            }
        }
        surfaces[surfaceID] = surface
    }

    package func copyBits(
        surfaceID: UInt32,
        destination: PixelRect,
        sourceX: Int,
        sourceY: Int
    ) throws(RenderError) {
        var surface = try surface(id: surfaceID)
        try validate(destination, in: surface)
        let source = PixelRect(
            x: sourceX,
            y: sourceY,
            width: destination.width,
            height: destination.height
        )
        try validate(source, in: surface)

        let rowBytes = destination.width * 4
        var copied = Data(capacity: rowBytes * destination.height)
        for row in 0..<source.height {
            let start = (source.y + row) * surface.bytesPerRow + source.x * 4
            copied.append(surface.pixels[start..<(start + rowBytes)])
        }
        for row in 0..<destination.height {
            let sourceStart = row * rowBytes
            let destinationStart = (destination.y + row) * surface.bytesPerRow + destination.x * 4
            surface.pixels.replaceSubrange(
                destinationStart..<(destinationStart + rowBytes),
                with: copied[sourceStart..<(sourceStart + rowBytes)]
            )
        }
        surfaces[surfaceID] = surface
    }

    package func drawCopy(
        surfaceID: UInt32,
        destination: PixelRect,
        bitmap: RawBitmap,
        source sourceRectangle: PixelRect? = nil
    ) throws(RenderError) {
        var surface = try surface(id: surfaceID)
        try validate(destination, in: surface)
        let source = sourceRectangle ?? PixelRect(
            x: 0,
            y: 0,
            width: bitmap.width,
            height: bitmap.height
        )
        guard source.width == destination.width, source.height == destination.height,
              bitmap.width > 0, bitmap.height > 0,
              source.x >= 0, source.y >= 0, source.width > 0, source.height > 0
        else {
            throw .invalidBitmap
        }
        let (sourceRight, sourceRightOverflow) = source.x.addingReportingOverflow(source.width)
        let (sourceBottom, sourceBottomOverflow) = source.y.addingReportingOverflow(source.height)
        guard !sourceRightOverflow, !sourceBottomOverflow,
              sourceRight <= bitmap.width, sourceBottom <= bitmap.height
        else {
            throw .invalidBitmap
        }
        let (minimumStride, strideOverflow) = bitmap.width.multipliedReportingOverflow(by: 4)
        guard !strideOverflow, bitmap.stride >= minimumStride else {
            throw .invalidBitmap
        }
        let (requiredBytes, sizeOverflow) = bitmap.stride.multipliedReportingOverflow(
            by: bitmap.height
        )
        guard !sizeOverflow, requiredBytes == bitmap.pixels.count else {
            throw .invalidBitmap
        }

        for destinationRow in 0..<source.height {
            let logicalSourceRow = source.y + destinationRow
            let sourceRow = bitmap.topDown
                ? logicalSourceRow
                : bitmap.height - 1 - logicalSourceRow
            let sourceStart = sourceRow * bitmap.stride
            let destinationStart = (destination.y + destinationRow) * surface.bytesPerRow
                + destination.x * 4
            for column in 0..<source.width {
                let sourceOffset = sourceStart + (source.x + column) * 4
                let destinationOffset = destinationStart + column * 4
                surface.pixels[destinationOffset] = bitmap.pixels[sourceOffset]
                surface.pixels[destinationOffset + 1] = bitmap.pixels[sourceOffset + 1]
                surface.pixels[destinationOffset + 2] = bitmap.pixels[sourceOffset + 2]
                surface.pixels[destinationOffset + 3] =
                    surface.format == .argb8888 && bitmap.format == .argb8888
                    ? bitmap.pixels[sourceOffset + 3]
                    : 255
            }
        }
        surfaces[surfaceID] = surface
    }

    package func drawCopy(
        surfaceID: UInt32,
        destination: PixelRect,
        sourceSurfaceID: UInt32,
        source sourceRectangle: PixelRect
    ) throws(RenderError) {
        var destinationSurface = try surface(id: surfaceID)
        let sourceSurface = try surface(id: sourceSurfaceID)
        try validate(destination, in: destinationSurface)
        try validate(sourceRectangle, in: sourceSurface)
        guard destination.width == sourceRectangle.width,
              destination.height == sourceRectangle.height
        else {
            throw .invalidRectangle
        }
        let rowBytes = destination.width * 4
        var copied = Data(capacity: rowBytes * destination.height)
        for row in 0..<sourceRectangle.height {
            let start = (sourceRectangle.y + row) * sourceSurface.bytesPerRow
                + sourceRectangle.x * 4
            copied.append(sourceSurface.pixels[start..<(start + rowBytes)])
        }
        for row in 0..<destination.height {
            let sourceStart = row * rowBytes
            let destinationStart = (destination.y + row) * destinationSurface.bytesPerRow
                + destination.x * 4
            destinationSurface.pixels.replaceSubrange(
                destinationStart..<(destinationStart + rowBytes),
                with: copied[sourceStart..<(sourceStart + rowBytes)]
            )
        }
        surfaces[surfaceID] = destinationSurface
    }

    package func drawScaledCopy(
        surfaceID: UInt32,
        destination: PixelRect,
        bitmap: RawBitmap,
        source: PixelRect,
        clippedDestinations: [PixelRect]
    ) throws(RenderError) {
        var surface = try surface(id: surfaceID)
        try validate(destination, in: surface)
        guard source.x >= 0, source.y >= 0,
              source.width > 0, source.height > 0,
              bitmap.width > 0, bitmap.height > 0
        else {
            throw .invalidBitmap
        }
        let (sourceRight, sourceRightOverflow) = source.x.addingReportingOverflow(source.width)
        let (sourceBottom, sourceBottomOverflow) = source.y.addingReportingOverflow(source.height)
        guard !sourceRightOverflow, !sourceBottomOverflow,
              sourceRight <= bitmap.width, sourceBottom <= bitmap.height
        else {
            throw .invalidBitmap
        }
        let (minimumStride, strideOverflow) = bitmap.width.multipliedReportingOverflow(by: 4)
        let (requiredBytes, sizeOverflow) = bitmap.stride.multipliedReportingOverflow(
            by: bitmap.height
        )
        guard !strideOverflow, !sizeOverflow,
              bitmap.stride >= minimumStride,
              requiredBytes == bitmap.pixels.count
        else {
            throw .invalidBitmap
        }
        let (_, horizontalScaleOverflow) = (destination.width - 1)
            .multipliedReportingOverflow(by: source.width)
        let (_, verticalScaleOverflow) = (destination.height - 1)
            .multipliedReportingOverflow(by: source.height)
        guard !horizontalScaleOverflow, !verticalScaleOverflow else {
            throw .integerOverflow
        }
        for clipped in clippedDestinations {
            try validate(clipped, in: surface)
            guard clipped.x >= destination.x, clipped.y >= destination.y,
                  clipped.x + clipped.width <= destination.x + destination.width,
                  clipped.y + clipped.height <= destination.y + destination.height
            else {
                throw .invalidRectangle
            }
        }

        for clipped in clippedDestinations {
            for destinationY in clipped.y..<(clipped.y + clipped.height) {
                let sourceY = source.y
                    + (destinationY - destination.y) * source.height / destination.height
                let sourceRow = bitmap.topDown
                    ? sourceY
                    : bitmap.height - 1 - sourceY
                for destinationX in clipped.x..<(clipped.x + clipped.width) {
                    let sourceX = source.x
                        + (destinationX - destination.x) * source.width / destination.width
                    let sourceOffset = sourceRow * bitmap.stride + sourceX * 4
                    let destinationOffset = destinationY * surface.bytesPerRow + destinationX * 4
                    surface.pixels[destinationOffset] = bitmap.pixels[sourceOffset]
                    surface.pixels[destinationOffset + 1] = bitmap.pixels[sourceOffset + 1]
                    surface.pixels[destinationOffset + 2] = bitmap.pixels[sourceOffset + 2]
                    surface.pixels[destinationOffset + 3] =
                        surface.format == .argb8888 && bitmap.format == .argb8888
                        ? bitmap.pixels[sourceOffset + 3]
                        : 255
                }
            }
        }
        surfaces[surfaceID] = surface
    }

    package func snapshot(surfaceID: UInt32) throws(RenderError) -> FrameSnapshot {
        let surface = try surface(id: surfaceID)
        let ioSurfaceFrame = framePool.makeFrame(
            width: surface.width,
            height: surface.height,
            sourceBytesPerRow: surface.bytesPerRow,
            pixels: surface.pixels
        )
        return FrameSnapshot(
            surfaceID: surface.id,
            width: surface.width,
            height: surface.height,
            bytesPerRow: surface.bytesPerRow,
            pixels: surface.pixels,
            ioSurfaceFrame: ioSurfaceFrame
        )
    }

    private func surface(id: UInt32) throws(RenderError) -> Surface {
        guard let surface = surfaces[id] else {
            throw .unknownSurface(id)
        }
        return surface
    }

    private func validate(_ rectangle: PixelRect, in surface: Surface) throws(RenderError) {
        guard rectangle.x >= 0, rectangle.y >= 0,
              rectangle.width > 0, rectangle.height > 0
        else {
            throw .invalidRectangle
        }
        let (right, rightOverflow) = rectangle.x.addingReportingOverflow(rectangle.width)
        let (bottom, bottomOverflow) = rectangle.y.addingReportingOverflow(rectangle.height)
        guard !rightOverflow, !bottomOverflow,
              right <= surface.width, bottom <= surface.height
        else {
            throw .invalidRectangle
        }
    }

    private func checkedByteCount(width: Int, height: Int) throws(RenderError) -> Int {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else {
            throw .integerOverflow
        }
        guard bytes <= limits.maximumSurfaceBytes else {
            throw .surfaceTooLarge(bytes: bytes, maximum: limits.maximumSurfaceBytes)
        }
        return bytes
    }
}
