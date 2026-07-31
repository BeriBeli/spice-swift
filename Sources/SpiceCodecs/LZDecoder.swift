import Foundation

package struct SpiceLZDecodeLimits: Sendable, Equatable {
    package var maximumDimension: Int
    package var maximumEncodedBytes: Int
    package var maximumDecodedBytes: Int
    package var maximumPaletteEntries: Int

    package init(
        maximumDimension: Int = 16_384,
        maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
        maximumDecodedBytes: Int = 256 * 1_024 * 1_024,
        maximumPaletteEntries: Int = 256
    ) {
        self.maximumDimension = maximumDimension
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumPaletteEntries = maximumPaletteEntries
    }
}

package struct SpiceLZDecoder: SpiceImageDecoder {
    private static let magic: UInt32 = 0x2020_5a4c
    private static let version: UInt32 = 0x0001_0001
    private static let maximumNearDistance = 8_191

    package nonisolated let format = SpiceImageFormat.lzRGB
    private let limits: SpiceLZDecodeLimits

    package init(limits: SpiceLZDecodeLimits = .init()) {
        self.limits = limits
    }

    @concurrent
    package func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        guard !payload.isEmpty else {
            throw .emptyPayload
        }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(
                actual: payload.count,
                maximum: limits.maximumEncodedBytes
            )
        }
        var reader = LZReader(data: payload)
        guard try reader.readUInt32BE() == Self.magic else {
            throw .invalidHeader("bad LZ magic")
        }
        guard try reader.readUInt32BE() == Self.version else {
            throw .invalidHeader("unsupported LZ version")
        }
        let type = Int(try reader.readUInt32BE())
        let imageType = try LZImageType(wireValue: type)
        let width = try integer(try reader.readUInt32BE(), field: "width")
        let height = try integer(try reader.readUInt32BE(), field: "height")
        let stride = try integer(try reader.readUInt32BE(), field: "stride")
        let topDownValue = try reader.readUInt32BE()
        guard topDownValue <= 1 else {
            throw .invalidHeader("invalid top-down flag")
        }
        guard width > 0, height > 0,
              width <= limits.maximumDimension, height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: width, height: height)
        }
        guard width == descriptor.width, height == descriptor.height else {
            throw .dimensionMismatch(
                expectedWidth: descriptor.width,
                expectedHeight: descriptor.height,
                actualWidth: width,
                actualHeight: height
            )
        }
        let (expectedStride, strideOverflow) = width.multipliedReportingOverflow(
            by: imageType.bytesPerSourcePixel
        )
        guard !strideOverflow, stride == expectedStride else {
            throw .invalidHeader("LZ stride does not match format")
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (outputByteCount, outputOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !outputOverflow else {
            throw .integerOverflow
        }
        guard outputByteCount <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(
                actual: outputByteCount,
                maximum: limits.maximumDecodedBytes
            )
        }

        var output = [UInt8](repeating: 0, count: outputByteCount)
        for plane in imageType.planes {
            try decodePlane(
                plane,
                reader: &reader,
                output: &output,
                pixelCount: pixelCount
            )
        }
        guard reader.isAtEnd else {
            throw .malformedPayload("trailing compressed bytes")
        }
        return SpiceDecodedImage(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            topDown: topDownValue == 1,
            alphaMode: imageType.hasAlpha ? .straight : .opaque,
            pixelsBGRA: Data(output)
        )
    }

    private func decodePlane(
        _ plane: LZPlane,
        reader: inout LZReader,
        output: inout [UInt8],
        pixelCount: Int
    ) throws(SpiceCodecError) {
        var outputPixels = 0
        while outputPixels < pixelCount {
            let control = Int(try reader.readByte())
            if control < 32 {
                let literalCount = control + 1
                guard literalCount <= pixelCount - outputPixels else {
                    throw .malformedPayload("literal exceeds output")
                }
                for _ in 0..<literalCount {
                    try decodeLiteral(
                        plane,
                        reader: &reader,
                        output: &output,
                        pixel: outputPixels
                    )
                    outputPixels += 1
                }
            } else {
                var length = (control >> 5) - 1
                if length == 6 {
                    var extensionByte: Int
                    repeat {
                        extensionByte = Int(try reader.readByte())
                        length += extensionByte
                    } while extensionByte == 255
                }
                let lowDistance = Int(try reader.readByte())
                var distance = (control & 31) << 8
                distance += lowDistance
                if lowDistance == 255, distance - lowDistance == 31 << 8 {
                    distance = Int(try reader.readByte()) << 8
                    distance += Int(try reader.readByte())
                    distance += Self.maximumNearDistance
                }
                length += plane.matchLengthBias
                distance += 1
                guard distance <= outputPixels else {
                    throw .malformedPayload("LZ reference precedes output")
                }
                guard length <= pixelCount - outputPixels else {
                    throw .malformedPayload("LZ reference exceeds output")
                }
                var reference = outputPixels - distance
                for _ in 0..<length {
                    let byteOffset = reference * 4
                    let destinationOffset = outputPixels * 4
                    if plane == .alpha {
                        output[destinationOffset + 3] = output[byteOffset + 3]
                    } else {
                        output[destinationOffset] = output[byteOffset]
                        output[destinationOffset + 1] = output[byteOffset + 1]
                        output[destinationOffset + 2] = output[byteOffset + 2]
                        output[destinationOffset + 3] = output[byteOffset + 3]
                    }
                    reference += 1
                    outputPixels += 1
                }
            }
        }
    }

    private func decodeLiteral(
        _ plane: LZPlane,
        reader: inout LZReader,
        output: inout [UInt8],
        pixel: Int
    ) throws(SpiceCodecError) {
        let offset = pixel * 4
        switch plane {
        case .rgb16:
            let redBits = try reader.readByte()
            let blueBits = try reader.readByte()
            var green = ((redBits << 6) | (blueBits >> 2)) & ~UInt8(0x07)
            green |= green >> 5
            output[offset] = (blueBits << 3) | ((blueBits >> 2) & 0x07)
            output[offset + 1] = green
            output[offset + 2] = ((redBits << 1) & ~UInt8(0x07)) | ((redBits >> 4) & 0x07)
            output[offset + 3] = 0
        case .color:
            output[offset] = try reader.readByte()
            output[offset + 1] = try reader.readByte()
            output[offset + 2] = try reader.readByte()
            output[offset + 3] = 0
        case .alpha:
            output[offset + 3] = try reader.readByte()
        }
    }

    private func integer(_ value: UInt32, field: String) throws(SpiceCodecError) -> Int {
        guard let result = Int(exactly: value) else {
            throw .invalidHeader("unrepresentable \(field)")
        }
        return result
    }
}

extension SpiceLZDecoder: SpicePaletteImageDecoder {
    @concurrent
    package func decodePalette(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data,
        palette: SpiceLZPalette
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        guard !payload.isEmpty else {
            throw .emptyPayload
        }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(
                actual: payload.count,
                maximum: limits.maximumEncodedBytes
            )
        }
        guard !palette.entriesARGB.isEmpty,
              palette.entriesARGB.count <= limits.maximumPaletteEntries
        else {
            throw .unsupportedFormat(palette.entriesARGB.count)
        }

        var reader = LZReader(data: payload)
        guard try reader.readUInt32BE() == Self.magic else {
            throw .invalidHeader("bad LZ magic")
        }
        guard try reader.readUInt32BE() == Self.version else {
            throw .invalidHeader("unsupported LZ version")
        }
        let imageType = try LZPaletteType(wireValue: Int(try reader.readUInt32BE()))
        let width = try integer(try reader.readUInt32BE(), field: "width")
        let height = try integer(try reader.readUInt32BE(), field: "height")
        let stride = try integer(try reader.readUInt32BE(), field: "stride")
        let topDownValue = try reader.readUInt32BE()
        guard topDownValue <= 1 else {
            throw .invalidHeader("invalid top-down flag")
        }
        guard width > 0, height > 0,
              width <= limits.maximumDimension, height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: width, height: height)
        }
        guard width == descriptor.width, height == descriptor.height else {
            throw .dimensionMismatch(
                expectedWidth: descriptor.width,
                expectedHeight: descriptor.height,
                actualWidth: width,
                actualHeight: height
            )
        }
        let expectedStride = (width + imageType.pixelsPerByte - 1) / imageType.pixelsPerByte
        guard stride == expectedStride else {
            throw .invalidHeader("LZ palette stride does not match format")
        }
        guard imageType.acceptsPaletteEntryCount(palette.entriesARGB.count) else {
            throw .malformedPayload("palette has too few entries")
        }

        let (packedByteCount, packedOverflow) = stride.multipliedReportingOverflow(by: height)
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (outputByteCount, outputOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !packedOverflow, !pixelOverflow, !outputOverflow else {
            throw .integerOverflow
        }
        let (workingByteCount, workingOverflow) = outputByteCount.addingReportingOverflow(
            packedByteCount
        )
        guard !workingOverflow, workingByteCount <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(
                actual: workingOverflow ? Int.max : workingByteCount,
                maximum: limits.maximumDecodedBytes
            )
        }

        let packed = try decodePaletteBytes(
            reader: &reader,
            outputByteCount: packedByteCount
        )
        guard reader.isAtEnd else {
            throw .malformedPayload("trailing compressed bytes")
        }
        var output = [UInt8](repeating: 0, count: outputByteCount)
        for row in 0..<height {
            for column in 0..<width {
                let packedByte = packed[row * stride + column / imageType.pixelsPerByte]
                let index = try imageType.paletteIndex(
                    packedByte: packedByte,
                    pixelInByte: column % imageType.pixelsPerByte,
                    entryCount: palette.entriesARGB.count
                )
                let entry = palette.entriesARGB[index]
                let offset = (row * width + column) * 4
                output[offset] = UInt8(truncatingIfNeeded: entry)
                output[offset + 1] = UInt8(truncatingIfNeeded: entry >> 8)
                output[offset + 2] = UInt8(truncatingIfNeeded: entry >> 16)
                output[offset + 3] = 0
            }
        }
        return SpiceDecodedImage(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            topDown: topDownValue == 1,
            pixelsBGRA: Data(output)
        )
    }

    private func decodePaletteBytes(
        reader: inout LZReader,
        outputByteCount: Int
    ) throws(SpiceCodecError) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: outputByteCount)
        var outputOffset = 0
        while outputOffset < outputByteCount {
            let control = Int(try reader.readByte())
            if control < 32 {
                let literalCount = control + 1
                guard literalCount <= outputByteCount - outputOffset else {
                    throw .malformedPayload("literal exceeds output")
                }
                for _ in 0..<literalCount {
                    output[outputOffset] = try reader.readByte()
                    outputOffset += 1
                }
            } else {
                var length = (control >> 5) - 1
                if length == 6 {
                    var extensionByte: Int
                    repeat {
                        extensionByte = Int(try reader.readByte())
                        length += extensionByte
                    } while extensionByte == 255
                }
                let lowDistance = Int(try reader.readByte())
                var distance = (control & 31) << 8
                distance += lowDistance
                if lowDistance == 255, distance - lowDistance == 31 << 8 {
                    distance = Int(try reader.readByte()) << 8
                    distance += Int(try reader.readByte())
                    distance += Self.maximumNearDistance
                }
                length += 3
                distance += 1
                guard distance <= outputOffset else {
                    throw .malformedPayload("LZ reference precedes output")
                }
                guard length <= outputByteCount - outputOffset else {
                    throw .malformedPayload("LZ reference exceeds output")
                }
                var reference = outputOffset - distance
                for _ in 0..<length {
                    output[outputOffset] = output[reference]
                    outputOffset += 1
                    reference += 1
                }
            }
        }
        return output
    }
}

private enum LZPaletteType {
    case plt1LE
    case plt1BE
    case plt4LE
    case plt4BE
    case plt8

    init(wireValue: Int) throws(SpiceCodecError) {
        switch wireValue {
        case 1: self = .plt1LE
        case 2: self = .plt1BE
        case 3: self = .plt4LE
        case 4: self = .plt4BE
        case 5: self = .plt8
        default: throw .unsupportedFormat(wireValue)
        }
    }

    var pixelsPerByte: Int {
        switch self {
        case .plt1LE, .plt1BE: 8
        case .plt4LE, .plt4BE: 2
        case .plt8: 1
        }
    }

    func acceptsPaletteEntryCount(_ count: Int) -> Bool {
        switch self {
        case .plt1LE, .plt1BE: count >= 2
        case .plt4LE, .plt4BE, .plt8: count > 0
        }
    }

    func paletteIndex(
        packedByte: UInt8,
        pixelInByte: Int,
        entryCount: Int
    ) throws(SpiceCodecError) -> Int {
        switch self {
        case .plt1LE:
            return Int((packedByte >> pixelInByte) & 1)
        case .plt1BE:
            return Int((packedByte >> (7 - pixelInByte)) & 1)
        case .plt4LE:
            let shift = pixelInByte == 0 ? 0 : 4
            return Int((packedByte >> shift) & 0x0f) % entryCount
        case .plt4BE:
            let shift = pixelInByte == 0 ? 4 : 0
            return Int((packedByte >> shift) & 0x0f) % entryCount
        case .plt8:
            let index = Int(packedByte)
            guard index < entryCount else {
                throw .malformedPayload("palette index out of range")
            }
            return index
        }
    }
}

private enum LZImageType {
    case rgb16
    case rgb24
    case rgb32
    case rgba
    case xxxa
    case a8

    init(wireValue: Int) throws(SpiceCodecError) {
        switch wireValue {
        case 6: self = .rgb16
        case 7: self = .rgb24
        case 8: self = .rgb32
        case 9: self = .rgba
        case 10: self = .xxxa
        case 11: self = .a8
        default: throw .unsupportedFormat(wireValue)
        }
    }

    var bytesPerSourcePixel: Int {
        switch self {
        case .rgb16: 2
        case .rgb24: 3
        case .rgb32, .rgba, .xxxa: 4
        case .a8: 1
        }
    }

    var planes: [LZPlane] {
        switch self {
        case .rgb16: [.rgb16]
        case .rgb24, .rgb32: [.color]
        case .rgba: [.color, .alpha]
        case .xxxa, .a8: [.alpha]
        }
    }

    var hasAlpha: Bool {
        switch self {
        case .rgba, .xxxa, .a8: true
        case .rgb16, .rgb24, .rgb32: false
        }
    }
}

private enum LZPlane {
    case rgb16
    case color
    case alpha

    var matchLengthBias: Int {
        switch self {
        case .color: 1
        case .rgb16: 2
        case .alpha: 3
        }
    }
}

private struct LZReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws(SpiceCodecError) -> UInt8 {
        guard offset < data.count else {
            throw .malformedPayload("truncated LZ stream")
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt32BE() throws(SpiceCodecError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(try readByte())
        }
        return value
    }
}
