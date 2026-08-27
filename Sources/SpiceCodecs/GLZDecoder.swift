import CSpicePixelOps
import Foundation

package struct SpiceGLZDecodeLimits: Sendable, Equatable {
    package var maximumDimension: Int
    package var maximumEncodedBytes: Int
    package var maximumDecodedBytes: Int
    package var maximumDictionaryImages: Int
    package var maximumDictionaryBytes: Int
    package var maximumPendingDictionaryWaits: Int
    package var maximumProgramOperations: Int

    package init(
        maximumDimension: Int = 16_384,
        maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
        maximumDecodedBytes: Int = 256 * 1_024 * 1_024,
        maximumDictionaryImages: Int = 256 * 1_024,
        maximumDictionaryBytes: Int = 256 * 1_024 * 1_024,
        maximumPendingDictionaryWaits: Int = 64,
        maximumProgramOperations: Int = 1_048_576
    ) {
        self.maximumDimension = maximumDimension
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
        self.maximumDictionaryImages = maximumDictionaryImages
        self.maximumDictionaryBytes = maximumDictionaryBytes
        self.maximumPendingDictionaryWaits = maximumPendingDictionaryWaits
        self.maximumProgramOperations = maximumProgramOperations
    }
}

package struct SpiceGLZDecoderDiagnostics: Sendable, Equatable {
    package let generation: UInt64
    package let dictionaryImages: Int
    package let dictionaryBytes: Int
    package let reservedImages: Int
    package let pendingDictionaryWaits: Int
    package let pendingDictionaryWaitBytes: Int
}

package actor SpiceGLZDecoder: SpiceImageDecoder {
    private struct DictionaryImage: Sendable {
        let pixels: Data
        let pixelCount: Int
        let windowHeadDistance: UInt32
    }

    private struct DictionaryWaiter {
        let imageID: UInt64
        let retainedByteCount: Int
        let continuation: CheckedContinuation<DictionaryImage, any Error>
    }

    package nonisolated let format = SpiceImageFormat.glzRGB
    private static let magic: UInt32 = 0x2020_5a4c
    private static let version: UInt32 = 0x0001_0001

    private let limits: SpiceGLZDecodeLimits
    private let executor: SpiceCodecTaskExecutor
    private var dictionary: [UInt64: DictionaryImage] = [:]
    private var reservations: [UInt64: UUID] = [:]
    private var generationToken = UUID()
    private var generation: UInt64 = 0
    private var oldestImageID: UInt64 = 0
    private var tailGap: UInt64 = 0
    private var dictionaryByteCount = 0
    private var dictionaryWaiters: [UUID: DictionaryWaiter] = [:]
    private var pendingDictionaryWaitBytes = 0

    package init(
        executor: SpiceCodecTaskExecutor = SpiceCodecTaskExecutor(),
        limits: SpiceGLZDecodeLimits = .init()
    ) {
        self.executor = executor
        self.limits = limits
    }

    package func clear() {
        dictionary.removeAll(keepingCapacity: true)
        reservations.removeAll(keepingCapacity: true)
        generationToken = UUID()
        generation = generation == .max ? .max : generation + 1
        oldestImageID = 0
        tailGap = 0
        dictionaryByteCount = 0
        pendingDictionaryWaitBytes = 0
        let waiters = dictionaryWaiters.values
        dictionaryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(throwing: SpiceCodecError.cancelled)
        }
    }

    package func diagnosticsSnapshot() -> SpiceGLZDecoderDiagnostics {
        SpiceGLZDecoderDiagnostics(
            generation: generation,
            dictionaryImages: dictionary.count,
            dictionaryBytes: dictionaryByteCount,
            reservedImages: reservations.count,
            pendingDictionaryWaits: dictionaryWaiters.count,
            pendingDictionaryWaitBytes: pendingDictionaryWaitBytes
        )
    }

    package func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        let program = try Self.parseProgram(descriptor: descriptor, payload: payload, limits: limits)
        guard dictionary[program.imageID] == nil, reservations[program.imageID] == nil else {
            throw .malformedPayload("duplicate GLZ image id")
        }
        let reservation = UUID()
        let decodeGeneration = generationToken
        reservations[program.imageID] = reservation
        defer {
            if reservations[program.imageID] == reservation {
                reservations.removeValue(forKey: program.imageID)
            }
        }
        let dependencies = try await dependencySnapshot(
            ids: program.dependencyImageIDs,
            retainedByteCount: program.waitRetainedByteCount
        )
        guard reservations[program.imageID] == reservation,
              generationToken == decodeGeneration else {
            throw SpiceCodecError.cancelled
        }
        let retained = try Self.retainedByteCount(
            program: program,
            dependencies: dependencies
        )
        let decoded: SpiceDecodedImage
        do {
            decoded = try await executor.executeThrowing(retainedByteCount: retained) {
                () async throws(SpiceCodecError) -> SpiceDecodedImage in
                try Self.execute(program, dependencies: dependencies)
            }
        } catch let error {
            throw Self.codecError(error)
        }
        guard reservations[program.imageID] == reservation,
              generationToken == decodeGeneration else {
            throw SpiceCodecError.cancelled
        }
        try commit(
            imageID: program.imageID,
            reservation: reservation,
            generation: decodeGeneration,
            image: DictionaryImage(
                pixels: decoded.pixelsBGRA,
                pixelCount: program.pixelCount,
                windowHeadDistance: program.windowHeadDistance
            )
        )
        return decoded
    }

    private func dependencySnapshot(
        ids: [UInt64],
        retainedByteCount: Int
    ) async throws(SpiceCodecError) -> [UInt64: GLZDependencyImage] {
        var result: [UInt64: GLZDependencyImage] = [:]
        result.reserveCapacity(ids.count)
        var retainedSnapshotBytes = 0
        for id in ids {
            if Task.isCancelled { throw .cancelled }
            let (waitRetainedBytes, waitOverflow) = retainedByteCount
                .addingReportingOverflow(retainedSnapshotBytes)
            guard !waitOverflow else { throw .integerOverflow }
            let image = try await dictionaryImage(
                id: id,
                retainedByteCount: waitRetainedBytes
            )
            result[id] = GLZDependencyImage(pixels: image.pixels, pixelCount: image.pixelCount)
            retainedSnapshotBytes = try Self.addingDependencySnapshot(
                image.pixels,
                to: retainedSnapshotBytes
            )
        }
        return result
    }

    private func dictionaryImage(
        id: UInt64,
        retainedByteCount: Int
    ) async throws(SpiceCodecError) -> DictionaryImage {
        if let image = dictionary[id] { return image }
        guard id >= oldestImageID else {
            throw .malformedPayload("GLZ dictionary image \(id) was evicted")
        }
        guard dictionaryWaiters.count < limits.maximumPendingDictionaryWaits else {
            throw .malformedPayload("GLZ dictionary wait limit exceeded")
        }
        guard retainedByteCount <= limits.maximumDictionaryBytes - pendingDictionaryWaitBytes else {
            throw .decodedImageTooLarge(
                actual: pendingDictionaryWaitBytes + retainedByteCount,
                maximum: limits.maximumDictionaryBytes
            )
        }
        let waiterID = UUID()
        pendingDictionaryWaitBytes += retainedByteCount
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<DictionaryImage, any Error>) in
                    if Task.isCancelled {
                        pendingDictionaryWaitBytes -= retainedByteCount
                        continuation.resume(throwing: CancellationError())
                    } else if let image = dictionary[id] {
                        pendingDictionaryWaitBytes -= retainedByteCount
                        continuation.resume(returning: image)
                    } else {
                        dictionaryWaiters[waiterID] = DictionaryWaiter(
                            imageID: id,
                            retainedByteCount: retainedByteCount,
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
        guard let waiter = dictionaryWaiters.removeValue(forKey: id) else { return }
        pendingDictionaryWaitBytes -= waiter.retainedByteCount
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func commit(
        imageID: UInt64,
        reservation: UUID,
        generation: UUID,
        image: DictionaryImage
    ) throws(SpiceCodecError) {
        guard generationToken == generation, reservations[imageID] == reservation else {
            throw .cancelled
        }
        guard dictionary[imageID] == nil else {
            throw .malformedPayload("duplicate GLZ image id")
        }
        var candidateTailGap = tailGap
        while candidateTailGap == imageID || dictionary[candidateTailGap] != nil {
            let (next, overflow) = candidateTailGap.addingReportingOverflow(1)
            guard !overflow else { throw .malformedPayload("GLZ image id overflow") }
            candidateTailGap = next
        }
        var candidateOldest = oldestImageID
        if candidateTailGap > 0,
           let newest = candidateTailGap - 1 == imageID ? image : dictionary[candidateTailGap - 1]
        {
            candidateOldest = max(
                candidateOldest,
                candidateTailGap - 1 - UInt64(newest.windowHeadDistance)
            )
        }
        var removedCount = 0
        var removedBytes = 0
        var evictedID = oldestImageID
        while evictedID < candidateOldest {
            if let evicted = dictionary[evictedID] {
                removedCount += 1
                let (next, overflow) = removedBytes.addingReportingOverflow(evicted.pixels.count)
                guard !overflow else { throw .integerOverflow }
                removedBytes = next
            }
            evictedID += 1
        }
        let storesImage = imageID >= candidateOldest
        let candidateCount = dictionary.count + (storesImage ? 1 : 0) - removedCount
        guard candidateCount <= limits.maximumDictionaryImages else {
            throw .decodedImageTooLarge(actual: candidateCount, maximum: limits.maximumDictionaryImages)
        }
        let addedBytes = storesImage ? image.pixels.count : 0
        let (withImage, byteOverflow) = dictionaryByteCount.addingReportingOverflow(addedBytes)
        guard !byteOverflow, withImage >= removedBytes else { throw .integerOverflow }
        let candidateBytes = withImage - removedBytes
        guard candidateBytes <= limits.maximumDictionaryBytes else {
            throw .decodedImageTooLarge(actual: candidateBytes, maximum: limits.maximumDictionaryBytes)
        }
        evictedID = oldestImageID
        while evictedID < candidateOldest {
            dictionary.removeValue(forKey: evictedID)
            evictedID += 1
        }
        if storesImage {
            dictionary[imageID] = image
        }
        reservations.removeValue(forKey: imageID)
        tailGap = candidateTailGap
        oldestImageID = candidateOldest
        dictionaryByteCount = candidateBytes
        let resolved = dictionaryWaiters.compactMap { id, waiter in
            waiter.imageID == imageID || waiter.imageID < candidateOldest ? id : nil
        }
        for id in resolved {
            guard let waiter = dictionaryWaiters.removeValue(forKey: id) else { continue }
            pendingDictionaryWaitBytes -= waiter.retainedByteCount
            if storesImage, waiter.imageID == imageID {
                waiter.continuation.resume(returning: image)
            } else {
                waiter.continuation.resume(
                    throwing: SpiceCodecError.malformedPayload(
                        "GLZ dictionary image \(waiter.imageID) was evicted"
                    )
                )
            }
        }
    }

    private static func retainedByteCount(
        program: GLZProgram,
        dependencies: [UInt64: GLZDependencyImage]
    ) throws(SpiceCodecError) -> Int {
        var result = program.waitRetainedByteCount
        for dependency in dependencies.values {
            result = try addingDependencySnapshot(dependency.pixels, to: result)
        }
        return result
    }

    private static func addingDependencySnapshot(
        _ pixels: Data,
        to retainedByteCount: Int
    ) throws(SpiceCodecError) -> Int {
        let (withPixels, pixelOverflow) = retainedByteCount.addingReportingOverflow(
            pixels.count
        )
        let (withMetadata, metadataOverflow) = withPixels.addingReportingOverflow(128)
        guard !pixelOverflow, !metadataOverflow else { throw .integerOverflow }
        return withMetadata
    }

    private static func codecError(
        _ error: SpiceCodecTaskExecutionError<SpiceCodecError>
    ) -> SpiceCodecError {
        switch error {
        case let .operation(error): error
        case let .executor(error):
            error == .cancelled || error == .closed
                ? .cancelled
                : .backendFailure("codec executor rejected GLZ work: \(error)")
        }
    }
}

private struct GLZDependencyImage: Sendable {
    let pixels: Data
    let pixelCount: Int
}

private struct GLZProgram: Sendable {
    let payload: Data
    let width: Int
    let height: Int
    let topDown: Bool
    let imageType: GLZImageType
    let imageID: UInt64
    let windowHeadDistance: UInt32
    let pixelCount: Int
    let outputByteCount: Int
    let waitRetainedByteCount: Int
    let operations: [GLZOperation]
    let dependencyImageIDs: [UInt64]
}

private enum GLZOperation: Sendable {
    case literals(plane: GLZPlane, input: Range<Int>, destinationPixel: Int, count: Int)
    case currentReference(plane: GLZPlane, sourcePixel: Int, destinationPixel: Int, count: Int)
    case dictionaryReference(
        plane: GLZPlane,
        imageID: UInt64,
        sourcePixel: Int,
        destinationPixel: Int,
        count: Int
    )
}

private extension SpiceGLZDecoder {
    nonisolated static func parseProgram(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data,
        limits: SpiceGLZDecodeLimits
    ) throws(SpiceCodecError) -> GLZProgram {
        // Coordination stays actor-local, but the plan it builds has an
        // explicit operation cap. Pixel allocation and all literal/reference
        // copying happen only after Session executor admission.
        guard !payload.isEmpty else { throw .emptyPayload }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(actual: payload.count, maximum: limits.maximumEncodedBytes)
        }
        var reader = GLZReader(data: payload)
        guard try reader.readUInt32BE() == magic else {
            throw .invalidHeader("bad GLZ magic")
        }
        guard try reader.readUInt32BE() == version else {
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
              width <= limits.maximumDimension, height <= limits.maximumDimension else {
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
        guard !pixelOverflow, !outputOverflow else { throw .integerOverflow }
        guard outputByteCount <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(actual: outputByteCount, maximum: limits.maximumDecodedBytes)
        }
        guard UInt64(windowHeadDistance) <= imageID else {
            throw .invalidHeader("GLZ window head precedes image zero")
        }

        var operations: [GLZOperation] = []
        var dependencies = Set<UInt64>()
        try parsePlane(
            imageType.colorPlane,
            reader: &reader,
            pixelCount: pixelCount,
            imageID: imageID,
            operations: &operations,
            dependencies: &dependencies,
            maximumOperations: limits.maximumProgramOperations
        )
        if imageType.hasAlpha {
            try parsePlane(
                .alpha,
                reader: &reader,
                pixelCount: pixelCount,
                imageID: imageID,
                operations: &operations,
                dependencies: &dependencies,
                maximumOperations: limits.maximumProgramOperations
            )
        }
        guard reader.isAtEnd else {
            throw .malformedPayload("trailing compressed bytes")
        }
        let dependencyImageIDs = dependencies.sorted()
        let waitRetainedByteCount = try conservativeWaitRetainedByteCount(
            outputByteCount: outputByteCount,
            payloadByteCount: payload.count,
            operationCount: operations.count,
            dependencyCount: dependencyImageIDs.count
        )
        return GLZProgram(
            payload: payload,
            width: width,
            height: height,
            topDown: topDown,
            imageType: imageType,
            imageID: imageID,
            windowHeadDistance: windowHeadDistance,
            pixelCount: pixelCount,
            outputByteCount: outputByteCount,
            waitRetainedByteCount: waitRetainedByteCount,
            operations: operations,
            dependencyImageIDs: dependencyImageIDs
        )
    }

    nonisolated static func conservativeWaitRetainedByteCount(
        outputByteCount: Int,
        payloadByteCount: Int,
        operationCount: Int,
        dependencyCount: Int
    ) throws(SpiceCodecError) -> Int {
        var total = 0
        try addRetainedBytes(outputByteCount, to: &total)
        try addRetainedBytes(payloadByteCount, to: &total)

        // Array capacity is intentionally opaque. Charge twice the live
        // element storage plus independent allocator/container allowances so
        // capacity growth and heap metadata are not represented as exact
        // count * stride bytes.
        try addRetainedBytes(
            try conservativeArrayAllocationByteCount(
                elementCount: operationCount,
                elementStride: MemoryLayout<GLZOperation>.stride
            ),
            to: &total
        )
        try addRetainedBytes(
            try conservativeArrayAllocationByteCount(
                elementCount: dependencyCount,
                elementStride: MemoryLayout<UInt64>.stride
            ),
            to: &total
        )
        // GLZProgram, Data's owner/reference, the two array values, and the
        // dependency-snapshot dictionary retained across later waits.
        try addRetainedBytes(768, to: &total)
        return total
    }

    nonisolated static func conservativeArrayAllocationByteCount(
        elementCount: Int,
        elementStride: Int
    ) throws(SpiceCodecError) -> Int {
        guard elementCount >= 0, elementStride >= 0 else { throw .integerOverflow }
        let (capacityElements, capacityOverflow) = elementCount.multipliedReportingOverflow(by: 2)
        let (elementBytes, byteOverflow) = capacityElements.multipliedReportingOverflow(
            by: elementStride
        )
        guard !capacityOverflow, !byteOverflow else { throw .integerOverflow }
        let (result, overheadOverflow) = elementBytes.addingReportingOverflow(256)
        guard !overheadOverflow else { throw .integerOverflow }
        return result
    }

    nonisolated static func addRetainedBytes(
        _ bytes: Int,
        to total: inout Int
    ) throws(SpiceCodecError) {
        guard bytes >= 0 else { throw .integerOverflow }
        let (next, overflow) = total.addingReportingOverflow(bytes)
        guard !overflow else { throw .integerOverflow }
        total = next
    }

    nonisolated static func parsePlane(
        _ plane: GLZPlane,
        reader: inout GLZReader,
        pixelCount: Int,
        imageID: UInt64,
        operations: inout [GLZOperation],
        dependencies: inout Set<UInt64>,
        maximumOperations: Int
    ) throws(SpiceCodecError) {
        guard maximumOperations >= 0 else {
            throw .malformedPayload("GLZ operation limit exceeded")
        }
        var outputPixel = 0
        while outputPixel < pixelCount {
            let control = Int(try reader.readByte())
            if control < 32 {
                let literalCount = control + 1
                guard literalCount <= pixelCount - outputPixel else {
                    throw .malformedPayload("GLZ literal exceeds output")
                }
                let (literalBytes, overflow) = literalCount.multipliedReportingOverflow(
                    by: plane.literalByteCount
                )
                guard !overflow else { throw .integerOverflow }
                try appendOperation(.literals(
                    plane: plane,
                    input: try reader.consumeRange(count: literalBytes),
                    destinationPixel: outputPixel,
                    count: literalCount
                ), to: &operations, maximum: maximumOperations)
                outputPixel += literalCount
                continue
            }

            var length = control >> 5
            if length == 7 {
                var extensionByte: Int
                repeat {
                    extensionByte = Int(try reader.readByte())
                    let (next, overflow) = length.addingReportingOverflow(extensionByte)
                    guard !overflow else { throw .integerOverflow }
                    length = next
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
            let (biasedLength, overflow) = length.addingReportingOverflow(plane.lengthBias)
            guard !overflow, biasedLength <= pixelCount - outputPixel else {
                throw .malformedPayload("GLZ reference exceeds output")
            }
            length = biasedLength
            if imageDistance == 0 {
                pixelOffset += 1
                guard pixelOffset <= outputPixel else {
                    throw .malformedPayload("GLZ reference precedes current image")
                }
                try appendOperation(.currentReference(
                    plane: plane,
                    sourcePixel: outputPixel - pixelOffset,
                    destinationPixel: outputPixel,
                    count: length
                ), to: &operations, maximum: maximumOperations)
            } else {
                guard let distance = UInt64(exactly: imageDistance), distance <= imageID else {
                    throw .malformedPayload("invalid GLZ image distance")
                }
                let referenceID = imageID - distance
                dependencies.insert(referenceID)
                try appendOperation(.dictionaryReference(
                    plane: plane,
                    imageID: referenceID,
                    sourcePixel: pixelOffset,
                    destinationPixel: outputPixel,
                    count: length
                ), to: &operations, maximum: maximumOperations)
            }
            outputPixel += length
        }
    }

    nonisolated static func appendOperation(
        _ operation: GLZOperation,
        to operations: inout [GLZOperation],
        maximum: Int
    ) throws(SpiceCodecError) {
        guard operations.count < maximum else {
            throw .malformedPayload("GLZ operation limit exceeded")
        }
        operations.append(operation)
    }

    nonisolated static func execute(
        _ program: GLZProgram,
        dependencies: [UInt64: GLZDependencyImage]
    ) throws(SpiceCodecError) -> SpiceDecodedImage {
        var output = Data(count: program.outputByteCount)
        for (index, operation) in program.operations.enumerated() {
            if index.isMultiple(of: 256), Task.isCancelled { throw .cancelled }
            switch operation {
            case let .literals(plane, input, destinationPixel, count):
                executeLiterals(
                    plane,
                    payload: program.payload,
                    input: input,
                    output: &output,
                    destinationPixel: destinationPixel,
                    count: count
                )
            case let .currentReference(plane, sourcePixel, destinationPixel, count):
                try copyPixelsWithinOutput(
                    plane,
                    output: &output,
                    sourcePixel: sourcePixel,
                    destinationPixel: destinationPixel,
                    count: count
                )
            case let .dictionaryReference(
                plane,
                imageID,
                sourcePixel,
                destinationPixel,
                count
            ):
                guard let source = dependencies[imageID] else {
                    throw .malformedPayload("missing GLZ dictionary image \(imageID)")
                }
                guard sourcePixel <= source.pixelCount,
                      count <= source.pixelCount - sourcePixel else {
                    throw .malformedPayload("GLZ dictionary reference exceeds image")
                }
                try copyPixels(
                    plane,
                    source: source.pixels,
                    sourcePixel: sourcePixel,
                    destination: &output,
                    destinationPixel: destinationPixel,
                    count: count
                )
            }
        }
        if Task.isCancelled { throw .cancelled }
        return SpiceDecodedImage(
            width: program.width,
            height: program.height,
            bytesPerRow: program.width * 4,
            topDown: program.topDown,
            alphaMode: program.imageType.hasAlpha ? .straight : .opaque,
            pixelsBGRA: output
        )
    }

    nonisolated static func executeLiterals(
        _ plane: GLZPlane,
        payload: Data,
        input: Range<Int>,
        output: inout Data,
        destinationPixel: Int,
        count: Int
    ) {
        payload.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let sourceBase = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let destinationBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return }
                var sourceOffset = input.lowerBound
                for pixel in destinationPixel..<(destinationPixel + count) {
                    let outputOffset = pixel * 4
                    switch plane {
                    case .rgb16:
                        let redBits = sourceBase[sourceOffset]
                        let blueBits = sourceBase[sourceOffset + 1]
                        sourceOffset += 2
                        var green = ((redBits << 6) | (blueBits >> 2)) & ~UInt8(0x07)
                        green |= green >> 5
                        destinationBase[outputOffset] = (blueBits << 3)
                            | ((blueBits >> 2) & 0x07)
                        destinationBase[outputOffset + 1] = green
                        destinationBase[outputOffset + 2] = ((redBits << 1) & ~UInt8(0x07))
                            | ((redBits >> 4) & 0x07)
                    case .color:
                        destinationBase[outputOffset] = sourceBase[sourceOffset]
                        destinationBase[outputOffset + 1] = sourceBase[sourceOffset + 1]
                        destinationBase[outputOffset + 2] = sourceBase[sourceOffset + 2]
                        sourceOffset += 3
                    case .alpha:
                        destinationBase[outputOffset + 3] = sourceBase[sourceOffset]
                        sourceOffset += 1
                    }
                }
            }
        }
    }

    nonisolated static func copyPixelsWithinOutput(
        _ plane: GLZPlane,
        output: inout Data,
        sourcePixel: Int,
        destinationPixel: Int,
        count: Int
    ) throws(SpiceCodecError) {
        var cancelled = false
        output.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            if plane != .alpha {
                let source = base.advanced(by: sourcePixel * 4)
                let destination = base.advanced(by: destinationPixel * 4)
                let distance = destinationPixel - sourcePixel
                var copiedPixels = 0
                while copiedPixels < min(distance, count) {
                    if Task.isCancelled {
                        cancelled = true
                        return
                    }
                    let chunkPixels = min(
                        65_536,
                        min(distance, count) - copiedPixels
                    )
                    memmove(
                        destination.advanced(by: copiedPixels * 4),
                        source.advanced(by: copiedPixels * 4),
                        chunkPixels * 4
                    )
                    copiedPixels += chunkPixels
                }
                while copiedPixels < count {
                    if Task.isCancelled {
                        cancelled = true
                        return
                    }
                    let patternOffset = copiedPixels % distance
                    let chunkPixels = min(
                        65_536,
                        min(distance - patternOffset, count - copiedPixels)
                    )
                    memmove(
                        destination.advanced(by: copiedPixels * 4),
                        destination.advanced(by: patternOffset * 4),
                        chunkPixels * 4
                    )
                    copiedPixels += chunkPixels
                }
                return
            }
            var copiedPixels = 0
            while copiedPixels < count {
                if Task.isCancelled {
                    cancelled = true
                    return
                }
                let chunkPixels = min(65_536, count - copiedPixels)
                spice_copy_bgra_alpha_overlap(
                    base.assumingMemoryBound(to: UInt8.self),
                    sourcePixel + copiedPixels,
                    destinationPixel + copiedPixels,
                    chunkPixels
                )
                copiedPixels += chunkPixels
            }
        }
        if cancelled { throw .cancelled }
    }

    nonisolated static func copyPixels(
        _ plane: GLZPlane,
        source: Data,
        sourcePixel: Int,
        destination: inout Data,
        destinationPixel: Int,
        count: Int
    ) throws(SpiceCodecError) {
        var cancelled = false
        source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeMutableBytes { destinationBytes in
                guard let sourceBase = sourceBytes.baseAddress,
                      let destinationBase = destinationBytes.baseAddress else { return }
                var copiedPixels = 0
                while copiedPixels < count {
                    if Task.isCancelled {
                        cancelled = true
                        return
                    }
                    let chunkPixels = min(65_536, count - copiedPixels)
                    if plane != .alpha {
                        memmove(
                            destinationBase.advanced(
                                by: (destinationPixel + copiedPixels) * 4
                            ),
                            sourceBase.advanced(by: (sourcePixel + copiedPixels) * 4),
                            chunkPixels * 4
                        )
                    } else {
                        spice_copy_bgra_alpha(
                            sourceBase.assumingMemoryBound(to: UInt8.self)
                                .advanced(by: (sourcePixel + copiedPixels) * 4),
                            destinationBase.assumingMemoryBound(to: UInt8.self)
                                .advanced(by: (destinationPixel + copiedPixels) * 4),
                            chunkPixels
                        )
                    }
                    copiedPixels += chunkPixels
                }
            }
        }
        if cancelled { throw .cancelled }
    }

    nonisolated static func integer(
        _ value: UInt32,
        field: String
    ) throws(SpiceCodecError) -> Int {
        guard let result = Int(exactly: value) else {
            throw .invalidHeader("unrepresentable \(field)")
        }
        return result
    }
}

private enum GLZImageType: Sendable {
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

    var colorPlane: GLZPlane { self == .rgb16 ? .rgb16 : .color }
    var hasAlpha: Bool { self == .rgba }
}

private enum GLZPlane: Sendable {
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

    var literalByteCount: Int {
        switch self {
        case .rgb16: 2
        case .color: 3
        case .alpha: 1
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

    mutating func consumeRange(count: Int) throws(SpiceCodecError) -> Range<Int> {
        guard count >= 0, count <= data.count - offset else {
            throw .malformedPayload("truncated GLZ stream")
        }
        let start = offset
        offset += count
        return start..<offset
    }

    mutating func readUInt32BE() throws(SpiceCodecError) -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 { value = (value << 8) | UInt32(try readByte()) }
        return value
    }

    mutating func readUInt64BE() throws(SpiceCodecError) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<8 { value = (value << 8) | UInt64(try readByte()) }
        return value
    }
}
