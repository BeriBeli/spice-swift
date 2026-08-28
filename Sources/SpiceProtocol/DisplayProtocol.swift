import Foundation
import SpiceWire

package struct SpicePoint: Sendable, Equatable {
    package let x: Int32
    package let y: Int32
}

package struct SpiceRect: Sendable, Equatable {
    package let top: Int32
    package let left: Int32
    package let bottom: Int32
    package let right: Int32
}

package enum SpiceClip: Sendable, Equatable {
    case none
    case rectangles([SpiceRect])
}

package struct SpiceDisplayBase: Sendable, Equatable {
    package let surfaceID: UInt32
    package let box: SpiceRect
    package let clip: SpiceClip
}

package struct SpiceImageDescriptor: Sendable, Equatable {
    package let id: UInt64
    package let type: UInt8
    package let flags: UInt8
    package let width: UInt32
    package let height: UInt32
}

package enum SpiceCachedImageRequirement: Sendable, Equatable {
    case any
    case lossless
}

package struct SpiceRawBitmap: Sendable, Equatable {
    package let format: UInt8
    package let flags: UInt8
    package let width: UInt32
    package let height: UInt32
    package let stride: UInt32
    package let pixelSlice: WireSlice
    package var pixels: Data { pixelSlice.data }
}

package struct SpicePalette: Sendable, Equatable {
    package let uniqueID: UInt64
    package let entriesARGB: [UInt32]
}

package enum SpicePaletteReference: Sendable, Equatable {
    case inline(SpicePalette)
    case cached(UInt64)
}

package struct SpiceLZPaletteData: Sendable, Equatable {
    package let flags: UInt8
    package let palette: SpicePaletteReference
    package let dataSlice: WireSlice
    package var data: Data { dataSlice.data }
}

package struct SpiceZlibGLZData: Sendable, Equatable {
    package let glzDataSize: UInt32
    package let dataSlice: WireSlice
    package var data: Data { dataSlice.data }
}

package enum SpiceImage: Sendable, Equatable {
    case bitmap(descriptor: SpiceImageDescriptor, bitmap: SpiceRawBitmap)
    case quic(descriptor: SpiceImageDescriptor, data: WireSlice)
    case jpeg(descriptor: SpiceImageDescriptor, data: WireSlice)
    case lzRGB(descriptor: SpiceImageDescriptor, data: WireSlice)
    case glzRGB(descriptor: SpiceImageDescriptor, data: WireSlice)
    case zlibGLZ(descriptor: SpiceImageDescriptor, data: SpiceZlibGLZData)
    case lzPalette(descriptor: SpiceImageDescriptor, data: SpiceLZPaletteData)
    case surface(descriptor: SpiceImageDescriptor, surfaceID: UInt32)
    case cached(
        descriptor: SpiceImageDescriptor,
        requirement: SpiceCachedImageRequirement
    )
}

package enum SpiceBrush: Sendable, Equatable {
    case none
    case solid(UInt32)
    case pattern(image: SpiceImage, position: SpicePoint)
}

package struct SpiceMask: Sendable, Equatable {
    package let flags: UInt8
    package let position: SpicePoint
    package let bitmap: SpiceImage?
}

package struct SpiceDisplayCopyBits: Sendable, Equatable {
    package let base: SpiceDisplayBase
    package let sourcePosition: SpicePoint
}

package struct SpiceDisplayDrawFill: Sendable, Equatable {
    package let base: SpiceDisplayBase
    package let brush: SpiceBrush
    package let ropDescriptor: UInt16
    package let mask: SpiceMask
}

package struct SpiceDisplayDrawCopy: Sendable, Equatable {
    package let base: SpiceDisplayBase
    package let sourceImage: SpiceImage
    package let sourceArea: SpiceRect
    package let ropDescriptor: UInt16
    package let scaleMode: UInt8
    package let mask: SpiceMask
}

package enum SpiceVideoCodec: UInt8, Sendable, Equatable {
    case mjpeg = 1
    case vp8 = 2
    case h264 = 3
    case vp9 = 4
    case h265 = 5
}

package struct SpiceDisplayStreamCreate: Sendable, Equatable {
    package let surfaceID: UInt32
    package let streamID: UInt32
    package let topDown: Bool
    package let codec: SpiceVideoCodec
    package let stamp: UInt64
    package let streamWidth: UInt32
    package let streamHeight: UInt32
    package let sourceWidth: UInt32
    package let sourceHeight: UInt32
    package let destination: SpiceRect
    package let clip: SpiceClip
}

package struct SpiceDisplayStreamData: Sendable, Equatable {
    package let streamID: UInt32
    package let multimediaTime: UInt32
    package let dataSlice: WireSlice
    package var data: Data { dataSlice.data }
}

package struct SpiceDisplayStreamDataSized: Sendable, Equatable {
    package let streamID: UInt32
    package let multimediaTime: UInt32
    package let width: UInt32
    package let height: UInt32
    package let destination: SpiceRect
    package let dataSlice: WireSlice
    package var data: Data { dataSlice.data }
}

package struct SpiceDisplayStreamClip: Sendable, Equatable {
    package let streamID: UInt32
    package let clip: SpiceClip
}

package enum SpiceDisplayCommand: Sendable, Equatable {
    case copyBits(SpiceDisplayCopyBits)
    case drawFill(SpiceDisplayDrawFill)
    case drawCopy(SpiceDisplayDrawCopy)
}

package struct SpiceDisplayWireLimits: Sendable, Equatable {
    package var maximumClipRectangles: Int
    package var maximumBitmapBytes: Int
    package var maximumStreamDimension: Int
    package var maximumStreamDataBytes: Int

    package init(
        maximumClipRectangles: Int = 4_096,
        maximumBitmapBytes: Int = 64 * 1_024 * 1_024,
        maximumStreamDimension: Int = 16_384,
        maximumStreamDataBytes: Int = 64 * 1_024 * 1_024
    ) {
        self.maximumClipRectangles = maximumClipRectangles
        self.maximumBitmapBytes = maximumBitmapBytes
        self.maximumStreamDimension = maximumStreamDimension
        self.maximumStreamDataBytes = maximumStreamDataBytes
    }
}

package struct SpiceDisplayWireDecoder: Sendable {
    private struct ImageAtOffset {
        let image: SpiceImage
        let range: Range<Int>
    }

    private let limits: SpiceDisplayWireLimits

    package init(limits: SpiceDisplayWireLimits = .init()) {
        self.limits = limits
    }

    package func decode(id: UInt16, body: Data) throws(WireError) -> SpiceDisplayCommand {
        try decode(id: id, body: OwnedBytes(body).wholeSlice)
    }

    package func decode(id: UInt16, body: WireSlice) throws(WireError) -> SpiceDisplayCommand {
        switch id {
        case 104:
            return .copyBits(try decodeCopyBits(body))
        case 302:
            return .drawFill(try decodeDrawFill(body))
        case 304:
            return .drawCopy(try decodeDrawCopy(body))
        default:
            throw .unsupportedFeature("Display message \(id)")
        }
    }

    package func decodeCopyBitsMessage(_ body: Data) throws(WireError) -> SpiceDisplayCopyBits {
        try decodeCopyBitsMessage(OwnedBytes(body).wholeSlice)
    }

    package func decodeCopyBitsMessage(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayCopyBits {
        try decodeCopyBits(body)
    }

    package func decodeDrawFillMessage(_ body: Data) throws(WireError) -> SpiceDisplayDrawFill {
        try decodeDrawFillMessage(OwnedBytes(body).wholeSlice)
    }

    package func decodeDrawFillMessage(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayDrawFill {
        try decodeDrawFill(body)
    }

    package func decodeDrawCopyMessage(_ body: Data) throws(WireError) -> SpiceDisplayDrawCopy {
        try decodeDrawCopyMessage(OwnedBytes(body).wholeSlice)
    }

    package func decodeDrawCopyMessage(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayDrawCopy {
        try decodeDrawCopy(body)
    }

    package func decodeStreamCreateMessage(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayStreamCreate {
        try decodeStreamCreate(body)
    }

    package func decodeStreamDataMessage(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayStreamData {
        try decodeStreamData(body)
    }

    package func decodeStreamDataSizedMessage(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayStreamDataSized {
        try decodeStreamDataSized(body)
    }

    package func decodeStreamClipMessage(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayStreamClip {
        try decodeStreamClip(body)
    }

    package func decodeStreamDestroyMessage(
        _ body: WireSlice
    ) throws(WireError) -> UInt32 {
        try decodeStreamDestroy(body)
    }

    package func decodeStreamDestroyAllMessage(
        _ body: WireSlice
    ) throws(WireError) {
        try decodeStreamDestroyAll(body)
    }

    package func decodeStreamCreateMessage(
        _ body: Data
    ) throws(WireError) -> SpiceDisplayStreamCreate {
        try decodeStreamCreate(OwnedBytes(body).wholeSlice)
    }

    private func decodeStreamCreate(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayStreamCreate {
        var reader = try ByteReader(body)
        let surfaceID = try reader.readUInt32LE()
        let streamID = try decodeStreamID(from: &reader)
        let flags = try reader.readUInt8()
        guard flags & ~UInt8(0x01) == 0 else {
            throw .invalidEnum(type: "SpiceStreamFlags", value: UInt64(flags))
        }
        let codecValue = try reader.readUInt8()
        guard let codec = SpiceVideoCodec(rawValue: codecValue) else {
            throw .invalidEnum(type: "SpiceVideoCodec", value: UInt64(codecValue))
        }
        let stamp = try reader.readUInt64LE()
        let streamWidth = try reader.readUInt32LE()
        let streamHeight = try reader.readUInt32LE()
        let sourceWidth = try reader.readUInt32LE()
        let sourceHeight = try reader.readUInt32LE()
        try validateStreamDimensions(width: streamWidth, height: streamHeight)
        try validateStreamDimensions(width: sourceWidth, height: sourceHeight)
        guard sourceWidth <= streamWidth, sourceHeight <= streamHeight else {
            throw .invalidSize(Int(max(sourceWidth, sourceHeight)))
        }
        let destination = try decodeRect(from: &reader)
        try validateStreamRect(destination)
        let clip = try decodeClip(from: &reader)
        try reader.requireFullyConsumed()
        return SpiceDisplayStreamCreate(
            surfaceID: surfaceID,
            streamID: streamID,
            topDown: flags & 0x01 != 0,
            codec: codec,
            stamp: stamp,
            streamWidth: streamWidth,
            streamHeight: streamHeight,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            destination: destination,
            clip: clip
        )
    }

    package func decodeStreamDataMessage(
        _ body: Data
    ) throws(WireError) -> SpiceDisplayStreamData {
        try decodeStreamData(OwnedBytes(body).wholeSlice)
    }

    private func decodeStreamData(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayStreamData {
        var reader = try ByteReader(body)
        let streamID = try decodeStreamID(from: &reader)
        let multimediaTime = try reader.readUInt32LE()
        let data = try decodeStreamData(from: &reader)
        try reader.requireFullyConsumed()
        return SpiceDisplayStreamData(
            streamID: streamID,
            multimediaTime: multimediaTime,
            dataSlice: data
        )
    }

    package func decodeStreamDataSizedMessage(
        _ body: Data
    ) throws(WireError) -> SpiceDisplayStreamDataSized {
        try decodeStreamDataSized(OwnedBytes(body).wholeSlice)
    }

    private func decodeStreamDataSized(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayStreamDataSized {
        var reader = try ByteReader(body)
        let streamID = try decodeStreamID(from: &reader)
        let multimediaTime = try reader.readUInt32LE()
        let width = try reader.readUInt32LE()
        let height = try reader.readUInt32LE()
        try validateStreamDimensions(width: width, height: height)
        let destination = try decodeRect(from: &reader)
        try validateStreamRect(destination)
        let data = try decodeStreamData(from: &reader)
        try reader.requireFullyConsumed()
        return SpiceDisplayStreamDataSized(
            streamID: streamID,
            multimediaTime: multimediaTime,
            width: width,
            height: height,
            destination: destination,
            dataSlice: data
        )
    }

    package func decodeStreamClipMessage(
        _ body: Data
    ) throws(WireError) -> SpiceDisplayStreamClip {
        try decodeStreamClip(OwnedBytes(body).wholeSlice)
    }

    private func decodeStreamClip(
        _ body: WireSlice
    ) throws(WireError) -> SpiceDisplayStreamClip {
        var reader = try ByteReader(body)
        let streamID = try decodeStreamID(from: &reader)
        let clip = try decodeClip(from: &reader)
        try reader.requireFullyConsumed()
        return SpiceDisplayStreamClip(streamID: streamID, clip: clip)
    }

    package func decodeStreamDestroyMessage(_ body: Data) throws(WireError) -> UInt32 {
        try decodeStreamDestroy(OwnedBytes(body).wholeSlice)
    }

    private func decodeStreamDestroy(_ body: WireSlice) throws(WireError) -> UInt32 {
        var reader = try ByteReader(body)
        let streamID = try decodeStreamID(from: &reader)
        try reader.requireFullyConsumed()
        return streamID
    }

    package func decodeStreamDestroyAllMessage(_ body: Data) throws(WireError) {
        try decodeStreamDestroyAll(OwnedBytes(body).wholeSlice)
    }

    private func decodeStreamDestroyAll(_ body: WireSlice) throws(WireError) {
        let reader = try ByteReader(body)
        try reader.requireFullyConsumed()
    }

    private func decodeCopyBits(_ body: WireSlice) throws(WireError) -> SpiceDisplayCopyBits {
        var reader = try ByteReader(body)
        let base = try decodeBase(from: &reader)
        let source = try decodePoint(from: &reader)
        try reader.requireFullyConsumed()
        return SpiceDisplayCopyBits(base: base, sourcePosition: source)
    }

    private func decodeDrawFill(_ body: WireSlice) throws(WireError) -> SpiceDisplayDrawFill {
        var reader = try ByteReader(body)
        let base = try decodeBase(from: &reader)
        let brushType = try reader.readUInt8()
        let solidColor: UInt32?
        let patternOffset: UInt32?
        let patternPosition: SpicePoint?
        switch brushType {
        case 0:
            solidColor = nil
            patternOffset = nil
            patternPosition = nil
        case 1:
            solidColor = try reader.readUInt32LE()
            patternOffset = nil
            patternPosition = nil
        case 2:
            solidColor = nil
            patternOffset = try reader.readUInt32LE()
            patternPosition = try decodePoint(from: &reader)
        default:
            throw .invalidEnum(type: "SpiceBrushType", value: UInt64(brushType))
        }
        let ropDescriptor = try reader.readUInt16LE()
        let maskHeader = try decodeMaskHeader(from: &reader)
        let fixedEnd = reader.offset

        var ranges: [Range<Int>] = []
        let brush: SpiceBrush
        if let solidColor {
            brush = .solid(solidColor)
        } else if let patternOffset, let patternPosition {
            let parsed = try decodeImage(at: patternOffset, body: body, minimumOffset: fixedEnd)
            ranges.append(parsed.range)
            brush = .pattern(image: parsed.image, position: patternPosition)
        } else {
            brush = .none
        }
        let mask = try finishMask(maskHeader, body: body, minimumOffset: fixedEnd, ranges: &ranges)
        try validateReferencedPayload(body: body, fixedEnd: fixedEnd, ranges: ranges)
        return SpiceDisplayDrawFill(
            base: base,
            brush: brush,
            ropDescriptor: ropDescriptor,
            mask: mask
        )
    }

    private func decodeDrawCopy(_ body: WireSlice) throws(WireError) -> SpiceDisplayDrawCopy {
        var reader = try ByteReader(body)
        let base = try decodeBase(from: &reader)
        let sourceOffset = try reader.readUInt32LE()
        let sourceArea = try decodeRect(from: &reader)
        let ropDescriptor = try reader.readUInt16LE()
        let scaleMode = try reader.readUInt8()
        let maskHeader = try decodeMaskHeader(from: &reader)
        let fixedEnd = reader.offset

        let source = try decodeImage(at: sourceOffset, body: body, minimumOffset: fixedEnd)
        var ranges = [source.range]
        let mask = try finishMask(maskHeader, body: body, minimumOffset: fixedEnd, ranges: &ranges)
        try validateReferencedPayload(body: body, fixedEnd: fixedEnd, ranges: ranges)
        return SpiceDisplayDrawCopy(
            base: base,
            sourceImage: source.image,
            sourceArea: sourceArea,
            ropDescriptor: ropDescriptor,
            scaleMode: scaleMode,
            mask: mask
        )
    }

    private func decodeBase(from reader: inout ByteReader) throws(WireError) -> SpiceDisplayBase {
        let surfaceID = try reader.readUInt32LE()
        let box = try decodeRect(from: &reader)
        let clip = try decodeClip(from: &reader)
        return SpiceDisplayBase(surfaceID: surfaceID, box: box, clip: clip)
    }

    private func decodeClip(from reader: inout ByteReader) throws(WireError) -> SpiceClip {
        let clipType = try reader.readUInt8()
        let clip: SpiceClip
        switch clipType {
        case 0:
            clip = .none
        case 1:
            let countValue = try reader.readUInt32LE()
            guard let count = Int(exactly: countValue), count <= limits.maximumClipRectangles,
                  count <= reader.remainingCount / 16
            else {
                throw .invalidSize(Int(countValue))
            }
            var rectangles: [SpiceRect] = []
            rectangles.reserveCapacity(count)
            for _ in 0..<count {
                rectangles.append(try decodeRect(from: &reader))
            }
            clip = .rectangles(rectangles)
        default:
            throw .invalidEnum(type: "SpiceClipType", value: UInt64(clipType))
        }
        return clip
    }

    private func decodeStreamID(from reader: inout ByteReader) throws(WireError) -> UInt32 {
        let streamID = try reader.readUInt32LE()
        guard streamID < 64 else {
            throw .invalidSize(Int(streamID))
        }
        return streamID
    }

    private func decodeStreamData(
        from reader: inout ByteReader
    ) throws(WireError) -> WireSlice {
        let dataSizeValue = try reader.readUInt32LE()
        guard let dataSize = Int(exactly: dataSizeValue),
              dataSize <= limits.maximumStreamDataBytes,
              dataSize <= reader.remainingCount
        else {
            throw .invalidSize(Int(dataSizeValue))
        }
        return try reader.readSlice(count: dataSize)
    }

    private func validateStreamDimensions(width: UInt32, height: UInt32) throws(WireError) {
        guard let maximum = UInt32(exactly: limits.maximumStreamDimension),
              width > 0, height > 0,
              width <= maximum,
              height <= maximum
        else {
            throw .invalidSize(Int(max(width, height)))
        }
    }

    private func validateStreamRect(_ rectangle: SpiceRect) throws(WireError) {
        guard rectangle.right > rectangle.left, rectangle.bottom > rectangle.top else {
            throw .invalidSize(0)
        }
    }

    private func decodeRect(from reader: inout ByteReader) throws(WireError) -> SpiceRect {
        SpiceRect(
            top: try reader.readInt32LE(),
            left: try reader.readInt32LE(),
            bottom: try reader.readInt32LE(),
            right: try reader.readInt32LE()
        )
    }

    private func decodePoint(from reader: inout ByteReader) throws(WireError) -> SpicePoint {
        SpicePoint(x: try reader.readInt32LE(), y: try reader.readInt32LE())
    }

    private func decodeMaskHeader(
        from reader: inout ByteReader
    ) throws(WireError) -> (UInt8, SpicePoint, UInt32) {
        let flags = try reader.readUInt8()
        let position = try decodePoint(from: &reader)
        let bitmapOffset = try reader.readUInt32LE()
        return (flags, position, bitmapOffset)
    }

    private func finishMask(
        _ header: (UInt8, SpicePoint, UInt32),
        body: WireSlice,
        minimumOffset: Int,
        ranges: inout [Range<Int>]
    ) throws(WireError) -> SpiceMask {
        let bitmap: SpiceImage?
        if header.2 == 0 {
            bitmap = nil
        } else {
            let parsed = try decodeImage(at: header.2, body: body, minimumOffset: minimumOffset)
            ranges.append(parsed.range)
            bitmap = parsed.image
        }
        return SpiceMask(flags: header.0, position: header.1, bitmap: bitmap)
    }

    private func decodeImage(
        at offsetValue: UInt32,
        body: WireSlice,
        minimumOffset: Int
    ) throws(WireError) -> ImageAtOffset {
        let offset = Int(offsetValue)
        guard offset >= minimumOffset else {
            throw .invalidOffset(UInt64(offsetValue))
        }
        _ = try SpiceAddressResolver(messageSize: body.count).resolve(
            UInt64(offsetValue),
            minimumSize: 18
        )
        var reader = try ByteReader(body, offset: offset)
        let descriptor = SpiceImageDescriptor(
            id: try reader.readUInt64LE(),
            type: try reader.readUInt8(),
            flags: try reader.readUInt8(),
            width: try reader.readUInt32LE(),
            height: try reader.readUInt32LE()
        )
        guard descriptor.flags & ~UInt8(0x07) == 0 else {
            throw .invalidEnum(type: "SpiceImageFlags", value: UInt64(descriptor.flags))
        }
        let image: SpiceImage
        switch descriptor.type {
        case 0:
            let format = try reader.readUInt8()
            let flags = try reader.readUInt8()
            let width = try reader.readUInt32LE()
            let height = try reader.readUInt32LE()
            let stride = try reader.readUInt32LE()
            if flags & 0x02 != 0 {
                _ = try reader.readUInt64LE()
            } else {
                let paletteOffset = try reader.readUInt32LE()
                guard paletteOffset == 0 else {
                    throw .unsupportedFeature("RAW true-color palette")
                }
            }
            guard width == descriptor.width, height == descriptor.height else {
                throw .invalidSize(Int(width))
            }
            let (byteCount64, overflow) = UInt64(stride).multipliedReportingOverflow(
                by: UInt64(height)
            )
            guard !overflow, byteCount64 <= UInt64(limits.maximumBitmapBytes),
                  let byteCount = Int(exactly: byteCount64)
            else {
                throw .messageTooLarge(
                    actual: byteCount64 > UInt64(Int.max) ? Int.max : Int(byteCount64),
                    maximum: limits.maximumBitmapBytes
                )
            }
            let pixels = try reader.readSlice(count: byteCount)
            image = .bitmap(
                descriptor: descriptor,
                bitmap: SpiceRawBitmap(
                    format: format,
                    flags: flags,
                    width: width,
                    height: height,
                    stride: stride,
                    pixelSlice: pixels
                )
            )
        case 1:
            let dataSizeValue = try reader.readUInt32LE()
            guard let dataSize = Int(exactly: dataSizeValue),
                  dataSize <= limits.maximumBitmapBytes
            else {
                throw .messageTooLarge(
                    actual: Int(dataSizeValue),
                    maximum: limits.maximumBitmapBytes
                )
            }
            image = .quic(
                descriptor: descriptor,
                data: try reader.readSlice(count: dataSize)
            )
        case 103:
            image = .cached(descriptor: descriptor, requirement: .any)
        case 104:
            image = .surface(
                descriptor: descriptor,
                surfaceID: try reader.readUInt32LE()
            )
        case 105:
            let dataSizeValue = try reader.readUInt32LE()
            guard let dataSize = Int(exactly: dataSizeValue),
                  dataSize <= limits.maximumBitmapBytes
            else {
                throw .messageTooLarge(
                    actual: Int(dataSizeValue),
                    maximum: limits.maximumBitmapBytes
                )
            }
            image = .jpeg(
                descriptor: descriptor,
                data: try reader.readSlice(count: dataSize)
            )
        case 106:
            image = .cached(descriptor: descriptor, requirement: .lossless)
        case 107:
            let glzDataSize = try reader.readUInt32LE()
            guard limits.maximumBitmapBytes > 0,
                  glzDataSize > 0,
                  UInt64(glzDataSize) <= UInt64(limits.maximumBitmapBytes)
            else {
                throw .messageTooLarge(
                    actual: Int(glzDataSize),
                    maximum: limits.maximumBitmapBytes
                )
            }
            let dataSizeValue = try reader.readUInt32LE()
            guard let dataSize = Int(exactly: dataSizeValue),
                  dataSize <= limits.maximumBitmapBytes
            else {
                throw .messageTooLarge(
                    actual: Int(dataSizeValue),
                    maximum: limits.maximumBitmapBytes
                )
            }
            image = .zlibGLZ(
                descriptor: descriptor,
                data: SpiceZlibGLZData(
                    glzDataSize: glzDataSize,
                    dataSlice: try reader.readSlice(count: dataSize)
                )
            )
        case 100:
            let flags = try reader.readUInt8()
            guard flags & ~UInt8(0x07) == 0 else {
                throw .invalidEnum(type: "SpiceBitmapFlags", value: UInt64(flags))
            }
            let dataSizeValue = try reader.readUInt32LE()
            guard let dataSize = Int(exactly: dataSizeValue),
                  dataSize <= limits.maximumBitmapBytes
            else {
                throw .messageTooLarge(
                    actual: Int(dataSizeValue),
                    maximum: limits.maximumBitmapBytes
                )
            }
            let palette: SpicePaletteReference
            if flags & 0x02 != 0 {
                palette = .cached(try reader.readUInt64LE())
                image = .lzPalette(
                    descriptor: descriptor,
                    data: SpiceLZPaletteData(
                        flags: flags,
                        palette: palette,
                        dataSlice: try reader.readSlice(count: dataSize)
                    )
                )
            } else {
                let paletteOffset = try reader.readUInt32LE()
                let compressed = try reader.readSlice(count: dataSize)
                guard Int(paletteOffset) == reader.offset else {
                    throw .invalidOffset(UInt64(paletteOffset))
                }
                var paletteReader = try ByteReader(body, offset: Int(paletteOffset))
                let uniqueID = try paletteReader.readUInt64LE()
                let countValue = try paletteReader.readUInt16LE()
                let count = Int(countValue)
                guard count > 0, count <= 256,
                      count <= paletteReader.remainingCount / 4
                else {
                    throw .invalidSize(count)
                }
                var entries: [UInt32] = []
                entries.reserveCapacity(count)
                for _ in 0..<count {
                    entries.append(try paletteReader.readUInt32LE())
                }
                reader = paletteReader
                palette = .inline(SpicePalette(
                    uniqueID: uniqueID,
                    entriesARGB: entries
                ))
                image = .lzPalette(
                    descriptor: descriptor,
                    data: SpiceLZPaletteData(
                        flags: flags,
                        palette: palette,
                        dataSlice: compressed
                    )
                )
            }
        case 101:
            let dataSizeValue = try reader.readUInt32LE()
            guard let dataSize = Int(exactly: dataSizeValue),
                  dataSize <= limits.maximumBitmapBytes
            else {
                throw .messageTooLarge(
                    actual: Int(dataSizeValue),
                    maximum: limits.maximumBitmapBytes
                )
            }
            image = .lzRGB(
                descriptor: descriptor,
                data: try reader.readSlice(count: dataSize)
            )
        case 102:
            let dataSizeValue = try reader.readUInt32LE()
            guard let dataSize = Int(exactly: dataSizeValue),
                  dataSize <= limits.maximumBitmapBytes
            else {
                throw .messageTooLarge(
                    actual: Int(dataSizeValue),
                    maximum: limits.maximumBitmapBytes
                )
            }
            image = .glzRGB(
                descriptor: descriptor,
                data: try reader.readSlice(count: dataSize)
            )
        default:
            throw .unsupportedFeature("Spice image type \(descriptor.type)")
        }
        return ImageAtOffset(image: image, range: offset..<reader.offset)
    }

    private func validateReferencedPayload(
        body: WireSlice,
        fixedEnd: Int,
        ranges: [Range<Int>]
    ) throws(WireError) {
        guard !ranges.isEmpty else {
            guard fixedEnd == body.count else {
                throw .trailingBytes(body.count - fixedEnd)
            }
            return
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var expectedStart = fixedEnd
        for range in sorted {
            guard range.lowerBound >= expectedStart else {
                throw .invalidOffset(UInt64(range.lowerBound))
            }
            guard range.lowerBound - expectedStart <= 3 else {
                throw .invalidOffset(UInt64(range.lowerBound))
            }
            expectedStart = range.upperBound
        }
        guard expectedStart == body.count else {
            throw .trailingBytes(body.count - expectedStart)
        }
    }
}
