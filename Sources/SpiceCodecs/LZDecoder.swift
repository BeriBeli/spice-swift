import CSpicePixelOps
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

package struct SpiceLZDecodeDiagnostics: Sendable, Equatable {
    package let decodedOutputAllocations: UInt64
    package let decodedOutputBytes: UInt64
    package let temporaryDecodedBackingAllocations: UInt64
    package let temporaryDecodedBackingBytes: UInt64
    package let referenceBulkCopyCalls: UInt64
    package let referenceBulkCopyBytes: UInt64
    package let paletteLookupExpansions: UInt64
    package let paletteLookupPixels: UInt64
}

package struct SpiceLZDecodeResult: Sendable, Equatable {
    package let image: SpiceDecodedImage
    package let diagnostics: SpiceLZDecodeDiagnostics
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
        try await decodeWithDiagnostics(
            descriptor: descriptor,
            payload: payload
        ).image
    }

    @concurrent
    package func decodeWithDiagnostics(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceLZDecodeResult {
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

        var metrics = MutableLZDecodeDiagnostics(outputByteCount: outputByteCount)
        var output = Data(count: outputByteCount)
        let decodeResult: Result<Void, SpiceCodecError> = output.withUnsafeMutableBytes {
            (outputBytes: UnsafeMutableRawBufferPointer) in
            do {
                for plane in imageType.planes {
                    try decodePlane(
                        plane,
                        reader: &reader,
                        output: outputBytes,
                        pixelCount: pixelCount,
                        metrics: &metrics
                    )
                }
                return .success(())
            } catch let error as SpiceCodecError {
                return .failure(error)
            } catch {
                preconditionFailure("LZ decoder emitted an unexpected error type: \(error)")
            }
        }
        try decodeResult.get()
        guard reader.isAtEnd else {
            throw .malformedPayload("trailing compressed bytes")
        }
        return SpiceLZDecodeResult(
            image: SpiceDecodedImage(
                width: width,
                height: height,
                bytesPerRow: width * 4,
                topDown: topDownValue == 1,
                alphaMode: imageType.hasAlpha ? .straight : .opaque,
                pixelsBGRA: output
            ),
            diagnostics: metrics.snapshot
        )
    }

    private func decodePlane(
        _ plane: LZPlane,
        reader: inout LZReader,
        output: UnsafeMutableRawBufferPointer,
        pixelCount: Int,
        metrics: inout MutableLZDecodeDiagnostics
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
                        output: output,
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
                copyReference(
                    plane: plane,
                    sourceUnit: outputPixels - distance,
                    destinationUnit: outputPixels,
                    unitCount: length,
                    output: output,
                    metrics: &metrics
                )
                outputPixels += length
            }
        }
    }

    private func decodeLiteral(
        _ plane: LZPlane,
        reader: inout LZReader,
        output: UnsafeMutableRawBufferPointer,
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

    private func copyReference(
        plane: LZPlane,
        sourceUnit: Int,
        destinationUnit: Int,
        unitCount: Int,
        output: UnsafeMutableRawBufferPointer,
        metrics: inout MutableLZDecodeDiagnostics
    ) {
        let distance = destinationUnit - sourceUnit
        precondition(distance > 0 && unitCount > 0)

        if plane == .alpha {
            spice_copy_bgra_alpha_overlap(
                output.baseAddress!.assumingMemoryBound(to: UInt8.self),
                sourceUnit,
                destinationUnit,
                unitCount
            )
            metrics.recordReferenceCopy(byteCount: unitCount)
            return
        }

        var copiedUnits = min(distance, unitCount)
        copyReferenceUnits(
            plane: plane,
            sourceUnit: sourceUnit,
            destinationUnit: destinationUnit,
            unitCount: copiedUnits,
            output: output,
            metrics: &metrics
        )
        while copiedUnits < unitCount {
            let nextUnits = min(copiedUnits, unitCount - copiedUnits)
            copyReferenceUnits(
                plane: plane,
                sourceUnit: destinationUnit,
                destinationUnit: destinationUnit + copiedUnits,
                unitCount: nextUnits,
                output: output,
                metrics: &metrics
            )
            copiedUnits += nextUnits
        }
    }

    private func copyReferenceUnits(
        plane: LZPlane,
        sourceUnit: Int,
        destinationUnit: Int,
        unitCount: Int,
        output: UnsafeMutableRawBufferPointer,
        metrics: inout MutableLZDecodeDiagnostics
    ) {
        switch plane {
        case .rgb16, .color:
            let byteCount = unitCount * 4
            let sourceOffset = sourceUnit * 4
            let destinationOffset = destinationUnit * 4
            output.baseAddress!.advanced(by: destinationOffset).copyMemory(
                from: output.baseAddress!.advanced(by: sourceOffset),
                byteCount: byteCount
            )
            metrics.recordReferenceCopy(byteCount: byteCount)
        case .alpha:
            preconditionFailure("alpha references use the strided C kernel")
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
        try await decodePaletteWithDiagnostics(
            descriptor: descriptor,
            payload: payload,
            palette: palette
        ).image
    }

    @concurrent
    package func decodePaletteWithDiagnostics(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data,
        palette: SpiceLZPalette
    ) async throws(SpiceCodecError) -> SpiceLZDecodeResult {
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
        guard outputByteCount <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(
                actual: outputByteCount,
                maximum: limits.maximumDecodedBytes
            )
        }

        let lookup = imageType.makeLookup(entriesARGB: palette.entriesARGB)
        var metrics = MutableLZDecodeDiagnostics(outputByteCount: outputByteCount)
        var output = Data(count: outputByteCount)
        let decodeResult: Result<Void, SpiceCodecError> = lookup.withUnsafeBytes {
            (lookupBytes: UnsafeRawBufferPointer) in
            output.withUnsafeMutableBytes { (outputBytes: UnsafeMutableRawBufferPointer) in
                do {
                    try decodePaletteBytes(
                        reader: &reader,
                        output: outputBytes,
                        outputByteCount: packedByteCount,
                        metrics: &metrics
                    )
                    guard reader.isAtEnd else {
                        throw SpiceCodecError.malformedPayload("trailing compressed bytes")
                    }
                    try expandPaletteBytes(
                        imageType: imageType,
                        width: width,
                        height: height,
                        stride: stride,
                        entryCount: palette.entriesARGB.count,
                        lookup: lookupBytes,
                        output: outputBytes,
                        metrics: &metrics
                    )
                    return .success(())
                } catch let error as SpiceCodecError {
                    return .failure(error)
                } catch {
                    preconditionFailure("LZ palette decoder emitted an unexpected error type: \(error)")
                }
            }
        }
        try decodeResult.get()
        return SpiceLZDecodeResult(
            image: SpiceDecodedImage(
                width: width,
                height: height,
                bytesPerRow: width * 4,
                topDown: topDownValue == 1,
                pixelsBGRA: output
            ),
            diagnostics: metrics.snapshot
        )
    }

    private func decodePaletteBytes(
        reader: inout LZReader,
        output: UnsafeMutableRawBufferPointer,
        outputByteCount: Int,
        metrics: inout MutableLZDecodeDiagnostics
    ) throws(SpiceCodecError) {
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
                copyPackedReference(
                    sourceOffset: outputOffset - distance,
                    destinationOffset: outputOffset,
                    byteCount: length,
                    output: output,
                    metrics: &metrics
                )
                outputOffset += length
            }
        }
    }

    private func copyPackedReference(
        sourceOffset: Int,
        destinationOffset: Int,
        byteCount: Int,
        output: UnsafeMutableRawBufferPointer,
        metrics: inout MutableLZDecodeDiagnostics
    ) {
        let distance = destinationOffset - sourceOffset
        precondition(distance > 0 && byteCount > 0)

        var copiedBytes = min(distance, byteCount)
        copyPackedBytes(
            sourceOffset: sourceOffset,
            destinationOffset: destinationOffset,
            byteCount: copiedBytes,
            output: output,
            metrics: &metrics
        )
        while copiedBytes < byteCount {
            let nextBytes = min(copiedBytes, byteCount - copiedBytes)
            copyPackedBytes(
                sourceOffset: destinationOffset,
                destinationOffset: destinationOffset + copiedBytes,
                byteCount: nextBytes,
                output: output,
                metrics: &metrics
            )
            copiedBytes += nextBytes
        }
    }

    private func copyPackedBytes(
        sourceOffset: Int,
        destinationOffset: Int,
        byteCount: Int,
        output: UnsafeMutableRawBufferPointer,
        metrics: inout MutableLZDecodeDiagnostics
    ) {
        output.baseAddress!.advanced(by: destinationOffset).copyMemory(
            from: output.baseAddress!.advanced(by: sourceOffset),
            byteCount: byteCount
        )
        metrics.recordReferenceCopy(byteCount: byteCount)
    }

    /// Packed units occupy the output prefix during LZ expansion. Walking
    /// pixels backwards is safe because every future packed source index is
    /// lower than the current destination byte offset. This preserves exact
    /// cross-row packed-byte references without a second decoded backing.
    private func expandPaletteBytes(
        imageType: LZPaletteType,
        width: Int,
        height: Int,
        stride: Int,
        entryCount: Int,
        lookup: UnsafeRawBufferPointer,
        output: UnsafeMutableRawBufferPointer,
        metrics: inout MutableLZDecodeDiagnostics
    ) throws(SpiceCodecError) {
        let pixelsPerByte = imageType.pixelsPerByte
        for row in (0..<height).reversed() {
            for packedColumn in (0..<stride).reversed() {
                let packedOffset = row * stride + packedColumn
                let packedByte = output[packedOffset]
                if imageType == .plt8, Int(packedByte) >= entryCount {
                    throw .malformedPayload("palette index out of range")
                }
                let firstColumn = packedColumn * pixelsPerByte
                let expandedPixels = min(pixelsPerByte, width - firstColumn)
                let destinationOffset = (row * width + firstColumn) * 4
                let lookupOffset = Int(packedByte) * pixelsPerByte * 4
                let expandedByteCount = expandedPixels * 4
                output.baseAddress!.advanced(by: destinationOffset).copyMemory(
                    from: lookup.baseAddress!.advanced(by: lookupOffset),
                    byteCount: expandedByteCount
                )
                metrics.recordPaletteExpansion(pixelCount: expandedPixels)
            }
        }
    }
}

private enum LZPaletteType: Equatable {
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

    func makeLookup(entriesARGB: [UInt32]) -> Data {
        let pixelStride = pixelsPerByte * 4
        var lookup = Data(count: 256 * pixelStride)
        lookup.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for packedValue in 0...255 {
                let packedByte = UInt8(packedValue)
                for pixelInByte in 0..<pixelsPerByte {
                    guard let index = paletteIndexForLookup(
                        packedByte: packedByte,
                        pixelInByte: pixelInByte,
                        entryCount: entriesARGB.count
                    ) else {
                        continue
                    }
                    let entry = entriesARGB[index]
                    let offset = packedValue * pixelStride + pixelInByte * 4
                    bytes[offset] = UInt8(truncatingIfNeeded: entry)
                    bytes[offset + 1] = UInt8(truncatingIfNeeded: entry >> 8)
                    bytes[offset + 2] = UInt8(truncatingIfNeeded: entry >> 16)
                    bytes[offset + 3] = 0
                }
            }
        }
        return lookup
    }

    private func paletteIndexForLookup(
        packedByte: UInt8,
        pixelInByte: Int,
        entryCount: Int
    ) -> Int? {
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
            return index < entryCount ? index : nil
        }
    }
}

private struct MutableLZDecodeDiagnostics {
    let outputByteCount: UInt64
    var referenceBulkCopyCalls: UInt64 = 0
    var referenceBulkCopyBytes: UInt64 = 0
    var paletteLookupExpansions: UInt64 = 0
    var paletteLookupPixels: UInt64 = 0

    init(outputByteCount: Int) {
        self.outputByteCount = UInt64(outputByteCount)
    }

    mutating func recordReferenceCopy(byteCount: Int) {
        Self.saturatingAdd(1, to: &referenceBulkCopyCalls)
        Self.saturatingAdd(UInt64(byteCount), to: &referenceBulkCopyBytes)
    }

    mutating func recordPaletteExpansion(pixelCount: Int) {
        Self.saturatingAdd(1, to: &paletteLookupExpansions)
        Self.saturatingAdd(UInt64(pixelCount), to: &paletteLookupPixels)
    }

    var snapshot: SpiceLZDecodeDiagnostics {
        SpiceLZDecodeDiagnostics(
            decodedOutputAllocations: 1,
            decodedOutputBytes: outputByteCount,
            temporaryDecodedBackingAllocations: 0,
            temporaryDecodedBackingBytes: 0,
            referenceBulkCopyCalls: referenceBulkCopyCalls,
            referenceBulkCopyBytes: referenceBulkCopyBytes,
            paletteLookupExpansions: paletteLookupExpansions,
            paletteLookupPixels: paletteLookupPixels
        )
    }

    private static func saturatingAdd(_ addition: UInt64, to value: inout UInt64) {
        let (sum, overflow) = value.addingReportingOverflow(addition)
        value = overflow ? UInt64.max : sum
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

private enum LZPlane: Equatable {
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
