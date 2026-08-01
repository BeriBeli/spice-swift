import Foundation

package struct SpiceGLZDecodeLimits: Sendable, Equatable {
    package var maximumDimension: Int
    package var maximumEncodedBytes: Int
    package var maximumDecodedBytes: Int
    package var maximumDictionaryImages: Int
    package var maximumDictionaryBytes: Int
    package var maximumPendingDictionaryWaits: Int

    package init(
        maximumDimension: Int = 16_384,
        maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
        maximumDecodedBytes: Int = 256 * 1_024 * 1_024,
        maximumDictionaryImages: Int = 256 * 1_024,
        maximumDictionaryBytes: Int = 256 * 1_024 * 1_024,
        maximumPendingDictionaryWaits: Int = 64
    ) {
        self.maximumDimension = maximumDimension
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumDictionaryImages = maximumDictionaryImages
        self.maximumDictionaryBytes = maximumDictionaryBytes
        self.maximumPendingDictionaryWaits = maximumPendingDictionaryWaits
    }
}

package actor SpiceGLZDecoder: SpiceImageDecoder {
    private struct DictionaryImage: Sendable {
        let pixels: Data
        let pixelCount: Int
        let windowHeadDistance: UInt32
    }

    private struct DictionaryWaiter {
        let imageID: UInt64
        let continuation: CheckedContinuation<DictionaryImage, any Error>
    }

    package nonisolated let format = SpiceImageFormat.glzRGB

    private static let magic: UInt32 = 0x2020_5a4c
    private static let version: UInt32 = 0x0001_0001

    private let limits: SpiceGLZDecodeLimits
    private var dictionary: [UInt64: DictionaryImage] = [:]
    private var oldestImageID: UInt64 = 0
    private var tailGap: UInt64 = 0
    private var dictionaryByteCount = 0
    private var dictionaryWaiters: [UUID: DictionaryWaiter] = [:]
    private var pendingDictionaryWaitBytes = 0

    package init(limits: SpiceGLZDecodeLimits = .init()) {
        self.limits = limits
    }

    package func clear() {
        dictionary.removeAll(keepingCapacity: true)
        oldestImageID = 0
        tailGap = 0
        dictionaryByteCount = 0
        let waiters = dictionaryWaiters.values
        dictionaryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(throwing: SpiceCodecError.cancelled)
        }
    }

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

        var reader = GLZReader(data: payload)
        guard try reader.readUInt32BE() == Self.magic else {
            throw .invalidHeader("bad GLZ magic")
        }
        guard try reader.readUInt32BE() == Self.version else {
            throw .invalidHeader("unsupported GLZ version")
        }
        let typeAndOrientation = try reader.readByte()
        guard typeAndOrientation & 0xe0 == 0 else {
            throw .invalidHeader("invalid GLZ type flags")
        }
        let imageType = try GLZImageType(wireValue: Int(typeAndOrientation & 0x0f))
        let topDown = typeAndOrientation & 0x10 != 0
        let width = try integer(try reader.readUInt32BE(), field: "width")
        let height = try integer(try reader.readUInt32BE(), field: "height")
        let stride = try integer(try reader.readUInt32BE(), field: "stride")
        let imageID = try reader.readUInt64BE()
        let windowHeadDistance = try reader.readUInt32BE()

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
            by: imageType.sourceBytesPerPixel
        )
        guard !strideOverflow, stride == expectedStride else {
            throw .invalidHeader("GLZ stride does not match format")
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
        guard dictionary[imageID] == nil else {
            throw .malformedPayload("duplicate GLZ image id")
        }
        guard UInt64(windowHeadDistance) <= imageID else {
            throw .invalidHeader("GLZ window head precedes image zero")
        }

        var output = Data(count: outputByteCount)
        try await decodePlane(
            imageType.colorPlane,
            reader: &reader,
            output: &output,
            pixelCount: pixelCount,
            imageID: imageID
        )
        if imageType.hasAlpha {
            try await decodePlane(
                .alpha,
                reader: &reader,
                output: &output,
                pixelCount: pixelCount,
                imageID: imageID
            )
        }
        guard reader.isAtEnd else {
            throw .malformedPayload("trailing compressed bytes")
        }

        let pixels = output
        try commit(
            imageID: imageID,
            image: DictionaryImage(
                pixels: pixels,
                pixelCount: pixelCount,
                windowHeadDistance: windowHeadDistance
            )
        )
        return SpiceDecodedImage(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            topDown: topDown,
            alphaMode: imageType.hasAlpha ? .straight : .opaque,
            pixelsBGRA: pixels
        )
    }

    private func decodePlane(
        _ plane: GLZPlane,
        reader: inout GLZReader,
        output: inout Data,
        pixelCount: Int,
        imageID: UInt64
    ) async throws(SpiceCodecError) {
        var outputPixel = 0
        while outputPixel < pixelCount {
            let control = Int(try reader.readByte())
            if control < 32 {
                let literalCount = control + 1
                guard literalCount <= pixelCount - outputPixel else {
                    throw .malformedPayload("GLZ literal exceeds output")
                }
                try decodeLiterals(
                    plane,
                    reader: &reader,
                    output: &output,
                    startPixel: outputPixel,
                    count: literalCount
                )
                outputPixel += literalCount
                continue
            }

            var length = control >> 5
            if length == 7 {
                var extensionByte: Int
                repeat {
                    extensionByte = Int(try reader.readByte())
                    length += extensionByte
                } while extensionByte == 255
            }
            var pixelOffset = control & 0x0f
            let longPixelOffset = control & 0x10 != 0
            pixelOffset += Int(try reader.readByte()) << 4

            let referenceCode = Int(try reader.readByte())
            let imageDistanceByteCount = referenceCode >> 6
            var imageDistance = 0
            if !longPixelOffset {
                imageDistance = referenceCode & 0x3f
                for byteIndex in 0..<imageDistanceByteCount {
                    imageDistance += Int(try reader.readByte()) << (6 + 8 * byteIndex)
                }
            } else {
                pixelOffset += (referenceCode & 0x1f) << 12
                for byteIndex in 0..<imageDistanceByteCount {
                    imageDistance += Int(try reader.readByte()) << (8 * byteIndex)
                }
                if referenceCode & 0x20 != 0 {
                    pixelOffset += Int(try reader.readByte()) << 17
                }
            }

            length += plane.lengthBias
            if imageDistance == 0 {
                pixelOffset += 1
            }
            guard length <= pixelCount - outputPixel else {
                throw .malformedPayload("GLZ reference exceeds output")
            }

            if imageDistance == 0 {
                guard pixelOffset <= outputPixel else {
                    throw .malformedPayload("GLZ reference precedes current image")
                }
                copyPixelsWithinOutput(
                    plane,
                    output: &output,
                    sourcePixel: outputPixel - pixelOffset,
                    destinationPixel: outputPixel,
                    count: length
                )
                outputPixel += length
            } else {
                guard let distance = UInt64(exactly: imageDistance), distance <= imageID else {
                    throw .malformedPayload("invalid GLZ image distance")
                }
                let referenceID = imageID - distance
                let referenceImage = try await dictionaryImage(
                    id: referenceID,
                    retainedByteCount: output.count
                )
                guard pixelOffset <= referenceImage.pixelCount,
                      length <= referenceImage.pixelCount - pixelOffset
                else {
                    throw .malformedPayload("GLZ dictionary reference exceeds image")
                }
                copyPixels(
                    plane,
                    source: referenceImage.pixels,
                    sourcePixel: pixelOffset,
                    destination: &output,
                    destinationPixel: outputPixel,
                    count: length
                )
                outputPixel += length
            }
        }
    }

    private func dictionaryImage(
        id: UInt64,
        retainedByteCount: Int
    ) async throws(SpiceCodecError) -> DictionaryImage {
        if let image = dictionary[id] {
            return image
        }
        guard id >= oldestImageID else {
            throw .malformedPayload("GLZ dictionary image \(id) was evicted")
        }
        guard dictionaryWaiters.count < limits.maximumPendingDictionaryWaits else {
            throw .malformedPayload("GLZ dictionary wait limit exceeded")
        }
        guard retainedByteCount <= limits.maximumDictionaryBytes - pendingDictionaryWaitBytes
        else {
            throw .decodedImageTooLarge(
                actual: pendingDictionaryWaitBytes + retainedByteCount,
                maximum: limits.maximumDictionaryBytes
            )
        }
        let waiterID = UUID()
        pendingDictionaryWaitBytes += retainedByteCount
        defer { pendingDictionaryWaitBytes -= retainedByteCount }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<DictionaryImage, any Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if let image = dictionary[id] {
                        continuation.resume(returning: image)
                    } else {
                        dictionaryWaiters[waiterID] = DictionaryWaiter(
                            imageID: id,
                            continuation: continuation
                        )
                    }
                }
            } onCancel: {
                Task { await self.cancelDictionaryWaiter(id: waiterID) }
            }
        } catch is CancellationError {
            throw .cancelled
        } catch let error as SpiceCodecError {
            throw error
        } catch {
            throw .backendFailure(String(describing: error))
        }
    }

    private func cancelDictionaryWaiter(id: UUID) {
        dictionaryWaiters.removeValue(forKey: id)?.continuation.resume(
            throwing: CancellationError()
        )
    }

    private func decodeLiterals(
        _ plane: GLZPlane,
        reader: inout GLZReader,
        output: inout Data,
        startPixel: Int,
        count: Int
    ) throws(SpiceCodecError) {
        var decodingError: SpiceCodecError?
        output.withUnsafeMutableBytes { bytes in
            guard bytes.baseAddress != nil else { return }
            do {
                for pixel in startPixel..<(startPixel + count) {
                    let offset = pixel * 4
                    switch plane {
                    case .rgb16:
                        let redBits = try reader.readByte()
                        let blueBits = try reader.readByte()
                        var green = ((redBits << 6) | (blueBits >> 2)) & ~UInt8(0x07)
                        green |= green >> 5
                        bytes[offset] = (blueBits << 3) | ((blueBits >> 2) & 0x07)
                        bytes[offset + 1] = green
                        bytes[offset + 2] = ((redBits << 1) & ~UInt8(0x07))
                            | ((redBits >> 4) & 0x07)
                    case .color:
                        bytes[offset] = try reader.readByte()
                        bytes[offset + 1] = try reader.readByte()
                        bytes[offset + 2] = try reader.readByte()
                    case .alpha:
                        bytes[offset + 3] = try reader.readByte()
                    }
                }
            } catch let error as SpiceCodecError {
                decodingError = error
            } catch {
                preconditionFailure("GLZReader emitted an unexpected error type: \(error)")
            }
        }
        if let decodingError {
            throw decodingError
        }
    }

    private func copyPixelsWithinOutput(
        _ plane: GLZPlane,
        output: inout Data,
        sourcePixel: Int,
        destinationPixel: Int,
        count: Int
    ) {
        output.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            if plane != .alpha {
                let source = base.advanced(by: sourcePixel * 4)
                let destination = base.advanced(by: destinationPixel * 4)
                let distance = destinationPixel - sourcePixel
                let initialPixels = min(distance, count)
                memmove(destination, source, initialPixels * 4)

                // GLZ references may overlap their destination. Once the first
                // period is copied, double the initialized prefix instead of
                // copying the repeated pattern one pixel at a time.
                var copiedPixels = initialPixels
                while copiedPixels < count {
                    let chunkPixels = min(copiedPixels, count - copiedPixels)
                    memmove(
                        destination.advanced(by: copiedPixels * 4),
                        destination,
                        chunkPixels * 4
                    )
                    copiedPixels += chunkPixels
                }
                return
            }
            for index in 0..<count {
                let sourceOffset = (sourcePixel + index) * 4
                let destinationOffset = (destinationPixel + index) * 4
                bytes[destinationOffset + 3] = bytes[sourceOffset + 3]
            }
        }
    }

    private func copyPixels(
        _ plane: GLZPlane,
        source: Data,
        sourcePixel: Int,
        destination: inout Data,
        destinationPixel: Int,
        count: Int
    ) {
        source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress
                else {
                    return
                }
                if plane != .alpha {
                    memmove(
                        destinationBase.advanced(by: destinationPixel * 4),
                        sourceBase.advanced(by: sourcePixel * 4),
                        count * 4
                    )
                    return
                }
                for index in 0..<count {
                    let sourceOffset = (sourcePixel + index) * 4
                    let destinationOffset = (destinationPixel + index) * 4
                    destinationBytes[destinationOffset + 3] = sourceBase.load(
                        fromByteOffset: sourceOffset + 3,
                        as: UInt8.self
                    )
                }
            }
        }
    }

    private func commit(
        imageID: UInt64,
        image: DictionaryImage
    ) throws(SpiceCodecError) {
        guard dictionary[imageID] == nil else {
            throw .malformedPayload("duplicate GLZ image id")
        }
        var candidateTailGap = tailGap
        while candidateTailGap == imageID || dictionary[candidateTailGap] != nil {
            let (next, overflow) = candidateTailGap.addingReportingOverflow(1)
            guard !overflow else {
                throw .malformedPayload("GLZ image id overflow")
            }
            candidateTailGap = next
        }
        var candidateOldest = oldestImageID
        if candidateTailGap > 0,
           let newestContiguous = candidateTailGap - 1 == imageID
               ? image
               : dictionary[candidateTailGap - 1]
        {
            let head = candidateTailGap - 1 - UInt64(newestContiguous.windowHeadDistance)
            candidateOldest = max(candidateOldest, head)
        }

        var removedImageCount = 0
        var removedByteCount = 0
        var evictedID = oldestImageID
        while evictedID < candidateOldest {
            if let evicted = dictionary[evictedID] {
                removedImageCount += 1
                let (next, overflow) = removedByteCount.addingReportingOverflow(
                    evicted.pixels.count
                )
                guard !overflow else { throw .integerOverflow }
                removedByteCount = next
            }
            evictedID += 1
        }
        let candidateImageCount = dictionary.count + 1 - removedImageCount
        guard candidateImageCount <= limits.maximumDictionaryImages else {
            throw .decodedImageTooLarge(
                actual: candidateImageCount,
                maximum: limits.maximumDictionaryImages
            )
        }
        let (bytesWithImage, byteOverflow) = dictionaryByteCount.addingReportingOverflow(
            image.pixels.count
        )
        guard !byteOverflow, bytesWithImage >= removedByteCount else {
            throw .integerOverflow
        }
        let candidateByteCount = bytesWithImage - removedByteCount
        guard candidateByteCount <= limits.maximumDictionaryBytes else {
            throw .decodedImageTooLarge(
                actual: candidateByteCount,
                maximum: limits.maximumDictionaryBytes
            )
        }

        evictedID = oldestImageID
        while evictedID < candidateOldest {
            dictionary.removeValue(forKey: evictedID)
            evictedID += 1
        }
        dictionary[imageID] = image
        tailGap = candidateTailGap
        oldestImageID = candidateOldest
        dictionaryByteCount = candidateByteCount
        let ready = dictionaryWaiters.compactMap { id, waiter in
            waiter.imageID == imageID ? id : nil
        }
        for id in ready {
            dictionaryWaiters.removeValue(forKey: id)?.continuation.resume(
                returning: image
            )
        }
    }

    private func integer(_ value: UInt32, field: String) throws(SpiceCodecError) -> Int {
        guard let result = Int(exactly: value) else {
            throw .invalidHeader("unrepresentable \(field)")
        }
        return result
    }
}

private enum GLZImageType {
    case rgb16
    case rgb24
    case rgb32
    case rgba

    init(wireValue: Int) throws(SpiceCodecError) {
        switch wireValue {
        case 6: self = .rgb16
        case 7: self = .rgb24
        case 8: self = .rgb32
        case 9: self = .rgba
        default: throw .unsupportedFormat(wireValue)
        }
    }

    var sourceBytesPerPixel: Int {
        switch self {
        case .rgb16: 2
        case .rgb24: 3
        case .rgb32, .rgba: 4
        }
    }

    var colorPlane: GLZPlane {
        self == .rgb16 ? .rgb16 : .color
    }

    var hasAlpha: Bool { self == .rgba }
}

private enum GLZPlane {
    case rgb16
    case color
    case alpha

    var lengthBias: Int {
        switch self {
        case .rgb16: 1
        case .color: 0
        case .alpha: 2
        }
    }
}

private struct GLZReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset == data.count }

    mutating func readByte() throws(SpiceCodecError) -> UInt8 {
        guard offset < data.count else {
            throw .malformedPayload("truncated GLZ stream")
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

    mutating func readUInt64BE() throws(SpiceCodecError) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 {
            value = (value << 8) | UInt64(try readByte())
        }
        return value
    }
}
