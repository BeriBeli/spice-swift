import Foundation
import Testing
@testable import SpiceCodecs

@Suite("SPICE GLZ decoder")
struct GLZDecoderTests {
    @Test func matchesSpiceCommonReferenceSequence() async throws {
        let url = try #require(Bundle.module.url(
            forResource: "glz-reference-sequence",
            withExtension: "json"
        ))
        let fixture = try JSONDecoder().decode(
            GLZReferenceFixture.self,
            from: Data(contentsOf: url)
        )
        let decoder = SpiceGLZDecoder()
        for entry in fixture.entries {
            let compressed = try #require(Data(base64Encoded: entry.compressedBase64))
            let expected = try #require(Data(base64Encoded: entry.expectedBGRABase64))
            let decoded = try await decoder.decode(
                descriptor: .init(width: entry.width, height: entry.height),
                payload: compressed
            )
            #expect(decoded.pixelsBGRA == expected, Comment(rawValue: fixture.generator))
        }
    }

    @Test func decodesLiteralSameImageAndCrossImageReferences() async throws {
        let decoder = SpiceGLZDecoder()
        let literal = glzPayload(
            type: 8,
            width: 2,
            height: 1,
            imageID: 0,
            windowHeadDistance: 0,
            compressed: [1, 1, 2, 3, 4, 5, 6]
        )
        let first = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: literal
        )
        #expect(first.pixelsBGRA == Data([1, 2, 3, 0, 4, 5, 6, 0]))

        let crossImage = glzPayload(
            type: 8,
            width: 2,
            height: 1,
            imageID: 1,
            windowHeadDistance: 1,
            compressed: [0x40, 0, 1]
        )
        let second = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: crossImage
        )
        #expect(second.pixelsBGRA == first.pixelsBGRA)

        let sameImage = glzPayload(
            type: 8,
            width: 4,
            height: 1,
            imageID: 2,
            windowHeadDistance: 2,
            compressed: [0, 9, 8, 7, 0x60, 0, 0]
        )
        let repeated = try await decoder.decode(
            descriptor: .init(width: 4, height: 1),
            payload: sameImage
        )
        #expect(repeated.pixelsBGRA == Data([
            9, 8, 7, 0, 9, 8, 7, 0,
            9, 8, 7, 0, 9, 8, 7, 0,
        ]))

        let alternating = try await SpiceGLZDecoder().decode(
            descriptor: .init(width: 7, height: 1),
            payload: glzPayload(
                type: 8,
                width: 7,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [
                    1, 1, 2, 3, 4, 5, 6,
                    0xa1, 0, 0,
                ]
            )
        )
        #expect(alternating.pixelsBGRA == Data([
            1, 2, 3, 0, 4, 5, 6, 0,
            1, 2, 3, 0, 4, 5, 6, 0,
            1, 2, 3, 0, 4, 5, 6, 0,
            1, 2, 3, 0,
        ]))
    }

    @Test func decodesRGB16AndRGBAPlanes() async throws {
        let rgb16 = try await SpiceGLZDecoder().decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 6,
                width: 2,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [1, 0x7c, 0x00, 0x03, 0xe0]
            )
        )
        #expect(rgb16.pixelsBGRA == Data([0, 0, 255, 0, 0, 255, 0, 0]))

        let rgb24 = try await SpiceGLZDecoder().decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 7,
                width: 2,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [1, 1, 2, 3, 4, 5, 6]
            )
        )
        #expect(rgb24.pixelsBGRA == Data([1, 2, 3, 0, 4, 5, 6, 0]))

        let decoder = SpiceGLZDecoder()
        let rgbaLiteral = glzPayload(
            type: 9,
            width: 3,
            height: 1,
            imageID: 0,
            windowHeadDistance: 0,
            compressed: [
                2, 1, 2, 3, 4, 5, 6, 7, 8, 9,
                2, 0x20, 0x40, 0x80,
            ]
        )
        let first = try await decoder.decode(
            descriptor: .init(width: 3, height: 1),
            payload: rgbaLiteral
        )
        #expect(first.alphaMode == .straight)
        #expect(first.pixelsBGRA == Data([
            1, 2, 3, 0x20, 4, 5, 6, 0x40, 7, 8, 9, 0x80,
        ]))

        let rgbaReference = glzPayload(
            type: 9,
            width: 3,
            height: 1,
            imageID: 1,
            windowHeadDistance: 1,
            compressed: [0x60, 0, 1, 0x20, 0, 1]
        )
        let second = try await decoder.decode(
            descriptor: .init(width: 3, height: 1),
            payload: rgbaReference
        )
        #expect(second.pixelsBGRA == first.pixelsBGRA)
    }

    @Test func expandsLongOverlappingRGBAReferencesWithoutChangingColor() async throws {
        let width = 16_383
        var compressed: [UInt8] = [
            2,
            1, 2, 3,
            4, 5, 6,
            7, 8, 9,
        ]
        appendSameImageReference(
            length: width - 3,
            lengthBias: 0,
            pixelOffset: 3,
            to: &compressed
        )
        compressed.append(contentsOf: [2, 0x20, 0x40, 0x80])
        appendSameImageReference(
            length: width - 3,
            lengthBias: 2,
            pixelOffset: 3,
            to: &compressed
        )

        let decoded = try await SpiceGLZDecoder().decode(
            descriptor: .init(width: width, height: 1),
            payload: glzPayload(
                type: 9,
                width: UInt32(width),
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: compressed
            )
        )
        let pattern: [[UInt8]] = [
            [1, 2, 3, 0x20],
            [4, 5, 6, 0x40],
            [7, 8, 9, 0x80],
        ]
        var expected = Data(capacity: width * 4)
        for index in 0..<width {
            expected.append(contentsOf: pattern[index % pattern.count])
        }
        #expect(decoded.pixelsBGRA == expected)
    }

    @Test func shortDistanceColorOverlapPlanUsesBoundedDoublingChunks() {
        let referenceCount = 16_383
        var chunkCount = 0
        var copiedPixels = 0

        for chunk in SpiceGLZColorOverlapCopyPlan(distance: 1, count: referenceCount) {
            #expect(chunk.pixelCount > 0)
            #expect(chunk.pixelCount <= 65_536)
            #expect(chunk.destinationPixelOffset == copiedPixels)
            #expect(
                chunk.sourcePixelOffset + chunk.pixelCount
                    <= 1 + chunk.destinationPixelOffset
            )
            chunkCount += 1
            copiedPixels += chunk.pixelCount
        }

        #expect(copiedPixels == referenceCount)
        #expect(chunkCount <= 16)
    }

    @Test(arguments: GLZShortDistanceColorFormat.allCases)
    func shortDistanceColorReferencesRemainBitExact(
        format: GLZShortDistanceColorFormat
    ) async throws {
        let width = 16_384
        var compressed: [UInt8] = [0]
        compressed.append(contentsOf: format.literalBytes)
        appendSameImageReference(
            length: width - 1,
            lengthBias: format.referenceLengthBias,
            pixelOffset: 1,
            to: &compressed
        )

        let decoded = try await SpiceGLZDecoder().decode(
            descriptor: .init(width: width, height: 1),
            payload: glzPayload(
                type: format.wireType,
                width: UInt32(width),
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: compressed
            )
        )

        #expect(decoded.pixelsBGRA == uniformPixels(format.expectedBGRA, count: width))
    }

    @Test func largeDistanceCurrentReferencePreservesOffsetsAcrossCopyChunks() async throws {
        let width = 16_384
        let height = 13
        let pixelCount = width * height
        let pixelOffset = 65_537
        let referenceCount = pixelCount - pixelOffset
        #expect(referenceCount > 2 * 65_536)

        var compressed = indexedRGBLiteralCommands(count: pixelOffset)
        appendLargeSameImageReference(
            length: referenceCount,
            pixelOffset: pixelOffset,
            to: &compressed
        )

        let decoded = try await SpiceGLZDecoder().decode(
            descriptor: .init(width: width, height: height),
            payload: glzPayload(
                type: 8,
                width: UInt32(width),
                height: UInt32(height),
                imageID: 0,
                windowHeadDistance: 0,
                compressed: compressed
            )
        )

        #expect(decoded.pixelsBGRA.count == pixelCount * 4)
        decoded.pixelsBGRA.withUnsafeBytes { (rawBytes: UnsafeRawBufferPointer) in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            for pixel in 0..<pixelCount {
                let sourcePixel = pixel < pixelOffset ? pixel : (pixel - pixelOffset) % pixelOffset
                let byteOffset = pixel * 4
                #expect(bytes[byteOffset] == UInt8(truncatingIfNeeded: sourcePixel))
                #expect(bytes[byteOffset + 1] == UInt8(truncatingIfNeeded: sourcePixel >> 8))
                #expect(bytes[byteOffset + 2] == UInt8(truncatingIfNeeded: sourcePixel >> 16))
                #expect(bytes[byteOffset + 3] == 0)
            }
        }
    }

    @Test func malformedInputDoesNotMutateDictionary() async throws {
        let decoder = SpiceGLZDecoder()
        let image0 = glzPayload(
            type: 8,
            width: 2,
            height: 1,
            imageID: 0,
            windowHeadDistance: 0,
            compressed: [1, 1, 2, 3, 4, 5, 6]
        )
        _ = try await decoder.decode(descriptor: .init(width: 2, height: 1), payload: image0)

        let validImage1 = glzPayload(
            type: 8,
            width: 2,
            height: 1,
            imageID: 1,
            windowHeadDistance: 1,
            compressed: [0x40, 0, 1]
        )
        var truncated = validImage1
        truncated.removeLast()
        await #expect(throws: SpiceCodecError.self) {
            try await decoder.decode(
                descriptor: .init(width: 2, height: 1),
                payload: truncated
            )
        }
        let decoded = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: validImage1
        )
        #expect(decoded.pixelsBGRA == Data([1, 2, 3, 0, 4, 5, 6, 0]))
    }

    @Test func rejectsEveryTruncationAndEvictedReference() async throws {
        let literal = glzPayload(
            type: 8,
            width: 2,
            height: 1,
            imageID: 0,
            windowHeadDistance: 0,
            compressed: [1, 1, 2, 3, 4, 5, 6]
        )
        for length in 0..<literal.count {
            await #expect(throws: SpiceCodecError.self) {
                try await SpiceGLZDecoder().decode(
                    descriptor: .init(width: 2, height: 1),
                    payload: Data(literal.prefix(length))
                )
            }
        }

        let decoder = SpiceGLZDecoder()
        _ = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: literal
        )
        _ = try await decoder.decode(
            descriptor: .init(width: 1, height: 1),
            payload: glzPayload(
                type: 8,
                width: 1,
                height: 1,
                imageID: 1,
                windowHeadDistance: 0,
                compressed: [0, 9, 8, 7]
            )
        )
        await #expect(throws: SpiceCodecError.self) {
            try await decoder.decode(
                descriptor: .init(width: 2, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 2,
                    height: 1,
                    imageID: 2,
                    windowHeadDistance: 2,
                    compressed: [0x40, 0, 2]
                )
            )
        }
    }

    @Test func waitsForOutOfOrderCrossDisplayImageAndSupportsCancellation() async throws {
        let decoder = SpiceGLZDecoder()
        let dependent = Task {
            try await decoder.decode(
                descriptor: .init(width: 2, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 2,
                    height: 1,
                    imageID: 1,
                    windowHeadDistance: 1,
                    compressed: [0x40, 0, 1]
                )
            )
        }
        await Task.yield()
        let source = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 8,
                width: 2,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [1, 1, 2, 3, 4, 5, 6]
            )
        )
        #expect(try await dependent.value.pixelsBGRA == source.pixelsBGRA)

        let cancelledDecoder = SpiceGLZDecoder()
        let cancelled = Task {
            try await cancelledDecoder.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: 1,
                    windowHeadDistance: 1,
                    compressed: [0x20, 0, 1]
                )
            )
        }
        await Task.yield()
        cancelled.cancel()
        await #expect(throws: SpiceCodecError.cancelled) {
            try await cancelled.value
        }

        let bounded = SpiceGLZDecoder(limits: .init(maximumPendingDictionaryWaits: 0))
        await #expect(throws: SpiceCodecError.self) {
            try await bounded.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: 1,
                    windowHeadDistance: 1,
                    compressed: [0x20, 0, 1]
                )
            )
        }
    }

    @Test func widthOneExecutorLeavesDictionaryDependencyWaitOutsidePermit() async throws {
        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 4,
            maximumQueuedRetainedBytes: 1_024
        ))
        let decoder = SpiceGLZDecoder(executor: executor)
        let dependent = Task {
            try await decoder.decode(
                descriptor: .init(width: 2, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 2,
                    height: 1,
                    imageID: 1,
                    windowHeadDistance: 1,
                    compressed: [0x40, 0, 1]
                )
            )
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 1 && $0.pendingDictionaryWaits == 1
        }
        var executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.activeJobs == 0)
        #expect(executorDiagnostics.queuedJobs == 0)

        let source = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 8,
                width: 2,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [1, 1, 2, 3, 4, 5, 6]
            )
        )
        #expect(try await dependent.value.pixelsBGRA == source.pixelsBGRA)

        let glzDiagnostics = await decoder.diagnosticsSnapshot()
        #expect(glzDiagnostics.reservedImages == 0)
        #expect(glzDiagnostics.pendingDictionaryWaits == 0)
        #expect(glzDiagnostics.pendingDictionaryWaitBytes == 0)
        executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.activeJobs == 0)
        #expect(executorDiagnostics.queuedJobs == 0)
        #expect(executorDiagnostics.currentRetainedBytes == 0)
        #expect(executorDiagnostics.peakActiveJobs == 1)
        #expect(executorDiagnostics.completedJobs == 2)
    }

    @Test func concurrentHostileWaitersChargeAggregateProgramRetentionAtExactLimit() async throws {
        let pixelCount = 4_096
        let descriptor = SpiceCodecImageDescriptor(width: pixelCount, height: 1)
        let payloads = [UInt64(1), 3, 5].map {
            hostileMissingDependencyPayload(pixelCount: pixelCount, imageID: $0)
        }
        let programLimits = SpiceGLZDecodeLimits(maximumProgramOperations: pixelCount)

        let probeExecutor = SpiceCodecTaskExecutor()
        let probeDecoder = SpiceGLZDecoder(executor: probeExecutor, limits: programLimits)
        let probe = Task {
            try await probeDecoder.decode(descriptor: descriptor, payload: payloads[0])
        }
        await waitForGLZ(probeDecoder) {
            $0.reservedImages == 1 && $0.pendingDictionaryWaits == 1
        }
        let baseCharge = await probeDecoder.diagnosticsSnapshot().pendingDictionaryWaitBytes
        #expect(baseCharge > pixelCount * 4 + payloads[0].count)
        #expect(await probeExecutor.diagnosticsSnapshot().currentRetainedBytes == 0)
        probe.cancel()
        await #expect(throws: SpiceCodecError.cancelled) {
            try await probe.value
        }
        await waitForGLZ(probeDecoder) {
            $0.reservedImages == 0
                && $0.pendingDictionaryWaits == 0
                && $0.pendingDictionaryWaitBytes == 0
        }

        let aggregateLimit = baseCharge * 2
        let executor = SpiceCodecTaskExecutor()
        let decoder = SpiceGLZDecoder(
            executor: executor,
            limits: .init(
                maximumDictionaryBytes: aggregateLimit,
                maximumProgramOperations: pixelCount
            )
        )
        let first = Task {
            try await decoder.decode(descriptor: descriptor, payload: payloads[0])
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 1
                && $0.pendingDictionaryWaits == 1
                && $0.pendingDictionaryWaitBytes == baseCharge
        }
        let second = Task {
            try await decoder.decode(descriptor: descriptor, payload: payloads[1])
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 2
                && $0.pendingDictionaryWaits == 2
                && $0.pendingDictionaryWaitBytes == aggregateLimit
        }

        await #expect(throws: SpiceCodecError.decodedImageTooLarge(
            actual: baseCharge * 3,
            maximum: aggregateLimit
        )) {
            try await decoder.decode(descriptor: descriptor, payload: payloads[2])
        }
        var diagnostics = await decoder.diagnosticsSnapshot()
        #expect(diagnostics.dictionaryImages == 0)
        #expect(diagnostics.dictionaryBytes == 0)
        #expect(diagnostics.reservedImages == 2)
        #expect(diagnostics.pendingDictionaryWaits == 2)
        #expect(diagnostics.pendingDictionaryWaitBytes == aggregateLimit)
        var executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.activeJobs == 0)
        #expect(executorDiagnostics.queuedJobs == 0)
        #expect(executorDiagnostics.currentRetainedBytes == 0)
        #expect(executorDiagnostics.completedJobs == 0)
        #expect(executorDiagnostics.failedJobs == 0)
        #expect(executorDiagnostics.rejectedJobs == 0)

        first.cancel()
        await #expect(throws: SpiceCodecError.cancelled) {
            try await first.value
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 1
                && $0.pendingDictionaryWaits == 1
                && $0.pendingDictionaryWaitBytes == baseCharge
        }

        let replacement = Task {
            try await decoder.decode(descriptor: descriptor, payload: payloads[2])
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 2
                && $0.pendingDictionaryWaits == 2
                && $0.pendingDictionaryWaitBytes == aggregateLimit
        }
        await decoder.clear()
        await #expect(throws: SpiceCodecError.cancelled) {
            try await second.value
        }
        await #expect(throws: SpiceCodecError.cancelled) {
            try await replacement.value
        }
        await waitForGLZ(decoder) {
            $0.dictionaryImages == 0
                && $0.dictionaryBytes == 0
                && $0.reservedImages == 0
                && $0.pendingDictionaryWaits == 0
                && $0.pendingDictionaryWaitBytes == 0
        }
        diagnostics = await decoder.diagnosticsSnapshot()
        #expect(diagnostics.pendingDictionaryWaitBytes == 0)
        executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.activeJobs == 0)
        #expect(executorDiagnostics.queuedJobs == 0)
        #expect(executorDiagnostics.currentRetainedBytes == 0)
    }

    @Test func queuedHostileProgramsChargeConservativeRetentionAtExactLimit() async throws {
        let pixelCount = 4_096
        let descriptor = SpiceCodecImageDescriptor(width: pixelCount, height: 1)
        let payloads = [UInt64(0), 1].map {
            largeLiteralGLZPayload(
                width: pixelCount,
                height: 1,
                imageID: $0
            )
        }
        let decoderLimits = SpiceGLZDecodeLimits(maximumProgramOperations: pixelCount)

        let probeExecutor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 2,
            maximumQueuedRetainedBytes: 256 * 1_024 * 1_024
        ))
        let probeGate = GLZOperationGate()
        let probeBlocker = Task {
            try await probeExecutor.execute(retainedByteCount: 1) {
                await probeGate.run()
            }
        }
        await probeGate.waitUntilStarted()
        let probeDecoder = SpiceGLZDecoder(executor: probeExecutor, limits: decoderLimits)
        let probe = Task {
            try await probeDecoder.decode(descriptor: descriptor, payload: payloads[0])
        }
        await waitForExecutor(probeExecutor) {
            $0.queuedJobs == 1 && $0.queuedRetainedBytes > 0
        }
        let baseCharge = await probeExecutor.diagnosticsSnapshot().queuedRetainedBytes
        #expect(baseCharge > pixelCount * 4 + payloads[0].count)
        #expect(await probeDecoder.diagnosticsSnapshot().reservedImages == 1)
        probe.cancel()
        await #expect(throws: SpiceCodecError.cancelled) {
            try await probe.value
        }
        await waitForExecutor(probeExecutor) {
            $0.queuedJobs == 0 && $0.queuedRetainedBytes == 0
        }
        await waitForGLZ(probeDecoder) { $0.reservedImages == 0 }
        await probeGate.release()
        _ = try await probeBlocker.value
        #expect(await probeExecutor.diagnosticsSnapshot().currentRetainedBytes == 0)

        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 2,
            maximumQueuedRetainedBytes: baseCharge
        ))
        let gate = GLZOperationGate()
        let blocker = Task {
            try await executor.execute(retainedByteCount: 1) {
                await gate.run()
            }
        }
        await gate.waitUntilStarted()
        let decoder = SpiceGLZDecoder(executor: executor, limits: decoderLimits)
        let admitted = Task {
            try await decoder.decode(descriptor: descriptor, payload: payloads[0])
        }
        await waitForExecutor(executor) {
            $0.queuedJobs == 1 && $0.queuedRetainedBytes == baseCharge
        }
        #expect(await decoder.diagnosticsSnapshot().reservedImages == 1)

        await #expect(throws: SpiceCodecError.backendFailure(
            "codec executor rejected GLZ work: queuedRetainedBytesExceeded("
                + "actual: \(baseCharge * 2), maximum: \(baseCharge))"
        )) {
            try await decoder.decode(descriptor: descriptor, payload: payloads[1])
        }
        var executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.activeJobs == 1)
        #expect(executorDiagnostics.queuedJobs == 1)
        #expect(executorDiagnostics.queuedRetainedBytes == baseCharge)
        #expect(executorDiagnostics.rejectedJobs == 1)
        var decoderDiagnostics = await decoder.diagnosticsSnapshot()
        #expect(decoderDiagnostics.dictionaryImages == 0)
        #expect(decoderDiagnostics.reservedImages == 1)
        #expect(decoderDiagnostics.pendingDictionaryWaits == 0)
        #expect(decoderDiagnostics.pendingDictionaryWaitBytes == 0)

        admitted.cancel()
        await #expect(throws: SpiceCodecError.cancelled) {
            try await admitted.value
        }
        await waitForExecutor(executor) {
            $0.queuedJobs == 0 && $0.queuedRetainedBytes == 0
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 0
                && $0.pendingDictionaryWaits == 0
                && $0.pendingDictionaryWaitBytes == 0
        }
        await gate.release()
        _ = try await blocker.value
        executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.activeJobs == 0)
        #expect(executorDiagnostics.queuedJobs == 0)
        #expect(executorDiagnostics.currentRetainedBytes == 0)
        #expect(executorDiagnostics.cancelledJobs == 1)
        #expect(executorDiagnostics.rejectedJobs == 1)
        decoderDiagnostics = await decoder.diagnosticsSnapshot()
        #expect(decoderDiagnostics.dictionaryImages == 0)
        #expect(decoderDiagnostics.reservedImages == 0)
    }

    @Test func retainedOwnerChargesInternalExecutorQueueAtExactBoundary() async throws {
        let descriptor = SpiceCodecImageDescriptor(width: 2, height: 1)
        let payload = glzPayload(
            type: 8,
            width: 2,
            height: 1,
            imageID: 0,
            windowHeadDistance: 0,
            compressed: [1, 1, 2, 3, 4, 5, 6]
        )

        let probeExecutor = SpiceCodecTaskExecutor(limits: .init(maximumConcurrentJobs: 1))
        let probeGate = GLZOperationGate()
        let probeBlocker = Task {
            try await probeExecutor.execute(retainedByteCount: 1) { await probeGate.run() }
        }
        await probeGate.waitUntilStarted()
        let probeDecoder = SpiceGLZDecoder(executor: probeExecutor)
        let probe = Task {
            try await probeDecoder.decode(
                descriptor: descriptor,
                payload: payload,
                retainedOwnerByteCount: 0
            )
        }
        await waitForExecutor(probeExecutor) { $0.queuedJobs == 1 }
        let programBase = await probeExecutor.diagnosticsSnapshot().queuedRetainedBytes
        #expect(programBase > payload.count)
        probe.cancel()
        await #expect(throws: SpiceCodecError.cancelled) { try await probe.value }
        await waitForExecutor(probeExecutor) {
            $0.queuedJobs == 0 && $0.queuedRetainedBytes == 0
        }
        await waitForGLZ(probeDecoder) { $0.reservedImages == 0 }
        await probeGate.release()
        _ = try await probeBlocker.value

        let ownerBytes = 32 * 1_024
        let exactCharge = programBase + ownerBytes
        let admittedExecutor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumQueuedRetainedBytes: exactCharge
        ))
        let admittedGate = GLZOperationGate()
        let admittedBlocker = Task {
            try await admittedExecutor.execute(retainedByteCount: 1) {
                await admittedGate.run()
            }
        }
        await admittedGate.waitUntilStarted()
        let admittedDecoder = SpiceGLZDecoder(executor: admittedExecutor)
        let admitted = Task {
            try await admittedDecoder.decode(
                descriptor: descriptor,
                payload: payload,
                retainedOwnerByteCount: ownerBytes
            )
        }
        await waitForExecutor(admittedExecutor) {
            $0.queuedJobs == 1 && $0.queuedRetainedBytes == exactCharge
        }
        #expect(await admittedDecoder.diagnosticsSnapshot().reservedImages == 1)
        admitted.cancel()
        await #expect(throws: SpiceCodecError.cancelled) { try await admitted.value }
        await waitForExecutor(admittedExecutor) {
            $0.queuedJobs == 0 && $0.queuedRetainedBytes == 0
        }
        await waitForGLZ(admittedDecoder) { $0.reservedImages == 0 }
        await admittedGate.release()
        _ = try await admittedBlocker.value
        #expect(await admittedExecutor.diagnosticsSnapshot().currentRetainedBytes == 0)

        let rejectedExecutor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumQueuedRetainedBytes: exactCharge - 1
        ))
        let rejectedGate = GLZOperationGate()
        let rejectedBlocker = Task {
            try await rejectedExecutor.execute(retainedByteCount: 1) {
                await rejectedGate.run()
            }
        }
        await rejectedGate.waitUntilStarted()
        let rejectedDecoder = SpiceGLZDecoder(executor: rejectedExecutor)
        await #expect(throws: SpiceCodecError.backendFailure(
            "codec executor rejected GLZ work: queuedRetainedBytesExceeded("
                + "actual: \(exactCharge), maximum: \(exactCharge - 1))"
        )) {
            try await rejectedDecoder.decode(
                descriptor: descriptor,
                payload: payload,
                retainedOwnerByteCount: ownerBytes
            )
        }
        #expect(await rejectedDecoder.diagnosticsSnapshot().reservedImages == 0)
        var rejectedDiagnostics = await rejectedExecutor.diagnosticsSnapshot()
        #expect(rejectedDiagnostics.queuedJobs == 0)
        #expect(rejectedDiagnostics.queuedRetainedBytes == 0)
        #expect(rejectedDiagnostics.rejectedJobs == 1)
        await rejectedGate.release()
        _ = try await rejectedBlocker.value
        rejectedDiagnostics = await rejectedExecutor.diagnosticsSnapshot()
        #expect(rejectedDiagnostics.currentRetainedBytes == 0)
    }

    @Test func retainedOwnerChargesDictionaryWaitAndRejectsOverflowAtomically() async throws {
        let descriptor = SpiceCodecImageDescriptor(width: 2, height: 1)
        let payload = glzPayload(
            type: 8,
            width: 2,
            height: 1,
            imageID: 1,
            windowHeadDistance: 1,
            compressed: [0x40, 0, 1]
        )
        let executor = SpiceCodecTaskExecutor()
        let probeDecoder = SpiceGLZDecoder(executor: executor)
        let probe = Task {
            try await probeDecoder.decode(
                descriptor: descriptor,
                payload: payload,
                retainedOwnerByteCount: 0
            )
        }
        await waitForGLZ(probeDecoder) { $0.pendingDictionaryWaits == 1 }
        let programBase = await probeDecoder.diagnosticsSnapshot().pendingDictionaryWaitBytes
        #expect(programBase > payload.count)
        probe.cancel()
        await #expect(throws: SpiceCodecError.cancelled) { try await probe.value }
        await waitForGLZ(probeDecoder) {
            $0.reservedImages == 0
                && $0.pendingDictionaryWaits == 0
                && $0.pendingDictionaryWaitBytes == 0
        }

        let ownerBytes = 32 * 1_024
        let exactCharge = programBase + ownerBytes
        let admittedDecoder = SpiceGLZDecoder(
            executor: executor,
            limits: .init(maximumDictionaryBytes: exactCharge)
        )
        let admitted = Task {
            try await admittedDecoder.decode(
                descriptor: descriptor,
                payload: payload,
                retainedOwnerByteCount: ownerBytes
            )
        }
        await waitForGLZ(admittedDecoder) {
            $0.reservedImages == 1
                && $0.pendingDictionaryWaits == 1
                && $0.pendingDictionaryWaitBytes == exactCharge
        }
        await admittedDecoder.clear()
        await #expect(throws: SpiceCodecError.cancelled) { try await admitted.value }
        await waitForGLZ(admittedDecoder) {
            $0.dictionaryImages == 0
                && $0.reservedImages == 0
                && $0.pendingDictionaryWaits == 0
                && $0.pendingDictionaryWaitBytes == 0
        }

        let rejectedDecoder = SpiceGLZDecoder(
            executor: executor,
            limits: .init(maximumDictionaryBytes: exactCharge - 1)
        )
        await #expect(throws: SpiceCodecError.decodedImageTooLarge(
            actual: exactCharge,
            maximum: exactCharge - 1
        )) {
            try await rejectedDecoder.decode(
                descriptor: descriptor,
                payload: payload,
                retainedOwnerByteCount: ownerBytes
            )
        }
        await #expect(throws: SpiceCodecError.integerOverflow) {
            try await rejectedDecoder.decode(
                descriptor: descriptor,
                payload: payload,
                retainedOwnerByteCount: -1
            )
        }
        await #expect(throws: SpiceCodecError.integerOverflow) {
            try await rejectedDecoder.decode(
                descriptor: descriptor,
                payload: payload,
                retainedOwnerByteCount: .max
            )
        }
        let diagnostics = await rejectedDecoder.diagnosticsSnapshot()
        #expect(diagnostics.dictionaryImages == 0)
        #expect(diagnostics.dictionaryBytes == 0)
        #expect(diagnostics.reservedImages == 0)
        #expect(diagnostics.pendingDictionaryWaits == 0)
        #expect(diagnostics.pendingDictionaryWaitBytes == 0)
        #expect(await executor.diagnosticsSnapshot().currentRetainedBytes == 0)
    }

    @Test func inFlightIDsFailuresAndCancellationReleaseEveryReservation() async throws {
        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 4,
            maximumQueuedRetainedBytes: 1_024
        ))
        let decoder = SpiceGLZDecoder(executor: executor)
        let dependentPayload = glzPayload(
            type: 8,
            width: 2,
            height: 1,
            imageID: 1,
            windowHeadDistance: 1,
            compressed: [0x40, 0, 1]
        )
        let dependent = Task {
            try await decoder.decode(
                descriptor: .init(width: 2, height: 1),
                payload: dependentPayload
            )
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 1 && $0.pendingDictionaryWaits == 1
        }

        await #expect(throws: SpiceCodecError.malformedPayload(
            "duplicate GLZ image id"
        )) {
            try await decoder.decode(
                descriptor: .init(width: 2, height: 1),
                payload: dependentPayload
            )
        }
        #expect(await decoder.diagnosticsSnapshot().reservedImages == 1)
        dependent.cancel()
        await #expect(throws: SpiceCodecError.cancelled) {
            try await dependent.value
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 0
                && $0.pendingDictionaryWaits == 0
                && $0.pendingDictionaryWaitBytes == 0
        }

        await #expect(throws: SpiceCodecError.malformedPayload(
            "truncated GLZ stream"
        )) {
            try await decoder.decode(
                descriptor: .init(width: 2, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 2,
                    height: 1,
                    imageID: 1,
                    windowHeadDistance: 1,
                    compressed: [1, 1, 2]
                )
            )
        }
        #expect(await decoder.diagnosticsSnapshot().reservedImages == 0)

        let source = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 8,
                width: 2,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [1, 9, 8, 7, 6, 5, 4]
            )
        )
        let recovered = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: dependentPayload
        )
        #expect(recovered.pixelsBGRA == source.pixelsBGRA)
        let finalGLZ = await decoder.diagnosticsSnapshot()
        #expect(finalGLZ.reservedImages == 0)
        #expect(finalGLZ.pendingDictionaryWaits == 0)
        #expect(finalGLZ.pendingDictionaryWaitBytes == 0)
        #expect(await executor.diagnosticsSnapshot().currentRetainedBytes == 0)
    }

    @Test func clearRejectsAQueuedOldGenerationWithoutLateDictionaryCommit() async throws {
        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 4,
            maximumQueuedRetainedBytes: 64 * 1_024
        ))
        let blockerGate = GLZOperationGate()
        let blocker = Task {
            try await executor.execute(retainedByteCount: 1) {
                await blockerGate.run()
            }
        }
        await blockerGate.waitUntilStarted()
        let decoder = SpiceGLZDecoder(executor: executor)
        let stale = Task {
            try await decoder.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: 0,
                    windowHeadDistance: 0,
                    compressed: [0, 1, 2, 3]
                )
            )
        }
        let dependencyWaiter = Task {
            try await decoder.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: 2,
                    windowHeadDistance: 1,
                    compressed: [0x20, 0, 1]
                )
            )
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 2
                && $0.pendingDictionaryWaits == 1
                && $0.pendingDictionaryWaitBytes > 4
        }
        await waitForExecutor(executor) { $0.queuedJobs == 1 }
        let generation = await decoder.diagnosticsSnapshot().generation

        await decoder.clear()
        #expect(await decoder.diagnosticsSnapshot().generation == generation + 1)
        await #expect(throws: SpiceCodecError.cancelled) {
            try await dependencyWaiter.value
        }
        await blockerGate.release()
        _ = try await blocker.value
        await #expect(throws: SpiceCodecError.cancelled) {
            try await stale.value
        }
        await waitForGLZ(decoder) {
            $0.dictionaryImages == 0
                && $0.dictionaryBytes == 0
                && $0.reservedImages == 0
                && $0.pendingDictionaryWaits == 0
                && $0.pendingDictionaryWaitBytes == 0
        }

        let replacement = try await decoder.decode(
            descriptor: .init(width: 1, height: 1),
            payload: glzPayload(
                type: 8,
                width: 1,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [0, 9, 8, 7]
            )
        )
        let dependent = try await decoder.decode(
            descriptor: .init(width: 1, height: 1),
            payload: glzPayload(
                type: 8,
                width: 1,
                height: 1,
                imageID: 1,
                windowHeadDistance: 1,
                compressed: [0x20, 0, 1]
            )
        )
        #expect(replacement.pixelsBGRA == Data([9, 8, 7, 0]))
        #expect(dependent.pixelsBGRA == replacement.pixelsBGRA)
        #expect(await executor.diagnosticsSnapshot().currentRetainedBytes == 0)
    }

    @Test func independentLargeImagesOverlapAtWidthTwoAndEvictDeterministically() async throws {
        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 2,
            maximumPendingJobs: 4,
            maximumQueuedRetainedBytes: 1_024 * 1_024
        ))
        let decoder = SpiceGLZDecoder(executor: executor)
        let width = 16_384
        let height = 64
        let pixelCount = width * height
        let secondPixel: [UInt8] = [4, 5, 6, 0]
        let firstPayload = largeLiteralGLZPayload(
            width: width,
            height: height,
            imageID: 0
        )
        let first = Task {
            try await decoder.decode(
                descriptor: .init(width: width, height: height),
                payload: firstPayload
            )
        }
        await waitForExecutor(executor, maximumYields: 1_000_000) {
            $0.activeJobs == 1
        }
        let second = Task {
            try await decoder.decode(
                descriptor: .init(width: width, height: height),
                payload: largeRepeatedGLZPayload(
                    width: width,
                    height: height,
                    imageID: 1,
                    pixel: Array(secondPixel.prefix(3))
                )
            )
        }

        let firstImage = try await first.value
        let secondImage = try await second.value
        expectLiteralPixels(firstImage.pixelsBGRA, count: pixelCount)
        expectUniformPixels(secondImage.pixelsBGRA, pixel: secondPixel, count: pixelCount)
        let executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.peakActiveJobs == 2)
        #expect(executorDiagnostics.activeJobs == 0)
        #expect(executorDiagnostics.queuedJobs == 0)
        #expect(executorDiagnostics.currentRetainedBytes == 0)
        #expect(executorDiagnostics.completedJobs == 2)
        let glzDiagnostics = await decoder.diagnosticsSnapshot()
        #expect(glzDiagnostics.dictionaryImages == 1)
        #expect(glzDiagnostics.dictionaryBytes == pixelCount * 4)
        #expect(glzDiagnostics.reservedImages == 0)
        #expect(glzDiagnostics.pendingDictionaryWaits == 0)
    }

    @Test(arguments: [1, 3, 32])
    func boundedProgramRejectsBeforeReservationOrExecutorAdmission(
        maximumOperations: Int
    ) async throws {
        let executor = SpiceCodecTaskExecutor()
        let decoder = SpiceGLZDecoder(
            executor: executor,
            limits: .init(maximumProgramOperations: maximumOperations)
        )
        let excessiveCommands = literalGLZCommands(count: maximumOperations + 1)
        await #expect(throws: SpiceCodecError.malformedPayload(
            "GLZ operation limit exceeded"
        )) {
            try await decoder.decode(
                descriptor: .init(width: maximumOperations + 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: UInt32(maximumOperations + 1),
                    height: 1,
                    imageID: 0,
                    windowHeadDistance: 0,
                    compressed: excessiveCommands
                )
            )
        }
        var glzDiagnostics = await decoder.diagnosticsSnapshot()
        #expect(glzDiagnostics.dictionaryImages == 0)
        #expect(glzDiagnostics.dictionaryBytes == 0)
        #expect(glzDiagnostics.reservedImages == 0)
        #expect(glzDiagnostics.pendingDictionaryWaits == 0)
        #expect(glzDiagnostics.pendingDictionaryWaitBytes == 0)
        var executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.activeJobs == 0)
        #expect(executorDiagnostics.queuedJobs == 0)
        #expect(executorDiagnostics.currentRetainedBytes == 0)
        #expect(executorDiagnostics.completedJobs == 0)
        #expect(executorDiagnostics.failedJobs == 0)
        #expect(executorDiagnostics.rejectedJobs == 0)

        let recovered = try await decoder.decode(
            descriptor: .init(width: maximumOperations, height: 1),
            payload: glzPayload(
                type: 8,
                width: UInt32(maximumOperations),
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: literalGLZCommands(count: maximumOperations)
            )
        )
        #expect(recovered.pixelsBGRA == literalGLZPixels(count: maximumOperations))
        glzDiagnostics = await decoder.diagnosticsSnapshot()
        #expect(glzDiagnostics.dictionaryImages == 1)
        #expect(glzDiagnostics.reservedImages == 0)
        executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.completedJobs == 1)
        #expect(executorDiagnostics.currentRetainedBytes == 0)
    }

    @Test func outOfOrderTailAdvanceEvictsOlderWaiterAndReleasesItsBudget() async throws {
        let executor = SpiceCodecTaskExecutor()
        let decoder = SpiceGLZDecoder(executor: executor)
        let dependent = Task {
            try await decoder.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: 2,
                    windowHeadDistance: 1,
                    compressed: [0x20, 0, 2]
                )
            )
        }
        await waitForGLZ(decoder) {
            $0.reservedImages == 1
                && $0.pendingDictionaryWaits == 1
                && $0.pendingDictionaryWaitBytes > 4
        }

        _ = try await decoder.decode(
            descriptor: .init(width: 1, height: 1),
            payload: glzPayload(
                type: 8,
                width: 1,
                height: 1,
                imageID: 1,
                windowHeadDistance: 0,
                compressed: [0, 9, 8, 7]
            )
        )
        _ = try await decoder.decode(
            descriptor: .init(width: 1, height: 1),
            payload: glzPayload(
                type: 8,
                width: 1,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [0, 1, 2, 3]
            )
        )
        await #expect(throws: SpiceCodecError.malformedPayload(
            "GLZ dictionary image 0 was evicted"
        )) {
            try await dependent.value
        }

        let glzDiagnostics = await decoder.diagnosticsSnapshot()
        #expect(glzDiagnostics.dictionaryImages == 1)
        #expect(glzDiagnostics.dictionaryBytes == 4)
        #expect(glzDiagnostics.reservedImages == 0)
        #expect(glzDiagnostics.pendingDictionaryWaits == 0)
        #expect(glzDiagnostics.pendingDictionaryWaitBytes == 0)
        let executorDiagnostics = await executor.diagnosticsSnapshot()
        #expect(executorDiagnostics.activeJobs == 0)
        #expect(executorDiagnostics.queuedJobs == 0)
        #expect(executorDiagnostics.currentRetainedBytes == 0)
    }

    @Test func decodesLongPixelOffsetAndLongImageDistance() async throws {
        var longOffsetBody: [UInt8] = [0, 1, 2, 3, 0xe0]
        longOffsetBody.append(contentsOf: repeatElement(255, count: 32))
        longOffsetBody.append(24)
        longOffsetBody.append(contentsOf: [0, 0])
        longOffsetBody.append(contentsOf: [0x3f, 0xff, 0x01])
        let longOffset = try await SpiceGLZDecoder().decode(
            descriptor: .init(width: 8_193, height: 1),
            payload: glzPayload(
                type: 8,
                width: 8_193,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: longOffsetBody
            )
        )
        #expect(longOffset.pixelsBGRA.count == 8_193 * 4)
        for offset in stride(from: 0, to: longOffset.pixelsBGRA.count, by: 4) {
            #expect(longOffset.pixelsBGRA[offset..<(offset + 4)] == Data([1, 2, 3, 0]))
        }

        let decoder = SpiceGLZDecoder()
        _ = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 8,
                width: 2,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [1, 9, 8, 7, 6, 5, 4]
            )
        )
        let distant = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 8,
                width: 2,
                height: 1,
                imageID: 300,
                windowHeadDistance: 300,
                compressed: [0x40, 0, 0x6c, 4]
            )
        )
        #expect(distant.pixelsBGRA == Data([9, 8, 7, 0, 6, 5, 4, 0]))
    }

    @Test func decodesVeryLongPixelOffsetAndTwoByteImageDistance() async throws {
        var veryLongOffsetBody: [UInt8] = [0, 1, 2, 3, 0xe0]
        veryLongOffsetBody.append(contentsOf: repeatElement(255, count: 513))
        veryLongOffsetBody.append(250)
        veryLongOffsetBody.append(contentsOf: [0, 0])
        veryLongOffsetBody.append(contentsOf: [0x30, 0, 0x20, 1])
        veryLongOffsetBody.append(0xe0)
        veryLongOffsetBody.append(contentsOf: repeatElement(255, count: 64))
        veryLongOffsetBody.append(55)
        veryLongOffsetBody.append(contentsOf: [0, 0])

        let veryLongOffset = try await SpiceGLZDecoder().decode(
            descriptor: .init(width: 16_384, height: 9),
            payload: glzPayload(
                type: 8,
                width: 16_384,
                height: 9,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: veryLongOffsetBody
            )
        )
        #expect(veryLongOffset.pixelsBGRA == uniformPixels(
            [1, 2, 3, 0],
            count: 16_384 * 9
        ))

        let decoder = SpiceGLZDecoder()
        let source = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 8,
                width: 2,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [1, 9, 8, 7, 6, 5, 4]
            )
        )
        let twoByteDistance = try await decoder.decode(
            descriptor: .init(width: 2, height: 1),
            payload: glzPayload(
                type: 8,
                width: 2,
                height: 1,
                imageID: 70_000,
                windowHeadDistance: 70_000,
                compressed: [0x40, 0, 0xb0, 69, 4]
            )
        )
        #expect(twoByteDistance.pixelsBGRA == source.pixelsBGRA)
    }

    @Test func resolvesConcurrentDependencyChainAcrossRepeatedRollover() async throws {
        let decoder = SpiceGLZDecoder(limits: .init(maximumDictionaryImages: 5))
        let dependents = (1...20).reversed().map { imageID in
            Task {
                try await decoder.decode(
                    descriptor: .init(width: 1, height: 1),
                    payload: glzPayload(
                        type: 8,
                        width: 1,
                        height: 1,
                        imageID: UInt64(imageID),
                        windowHeadDistance: UInt32(min(imageID, 3)),
                        compressed: [0x20, 0, 1]
                    )
                )
            }
        }
        await Task.yield()

        let source = try await decoder.decode(
            descriptor: .init(width: 1, height: 1),
            payload: glzPayload(
                type: 8,
                width: 1,
                height: 1,
                imageID: 0,
                windowHeadDistance: 0,
                compressed: [0, 7, 8, 9]
            )
        )
        for dependent in dependents {
            #expect(try await dependent.value.pixelsBGRA == source.pixelsBGRA)
        }

        let retained = try await decoder.decode(
            descriptor: .init(width: 1, height: 1),
            payload: glzPayload(
                type: 8,
                width: 1,
                height: 1,
                imageID: 21,
                windowHeadDistance: 3,
                compressed: [0x20, 0, 3]
            )
        )
        #expect(retained.pixelsBGRA == source.pixelsBGRA)
        await #expect(throws: SpiceCodecError.self) {
            try await decoder.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: 22,
                    windowHeadDistance: 4,
                    compressed: [0x20, 0, 21]
                )
            )
        }
    }

    @Test func rollsDictionaryWindowAndRetainsOnlyAdvertisedHistory() async throws {
        let decoder = SpiceGLZDecoder(limits: .init(maximumDictionaryImages: 4))
        for imageID: UInt64 in 0...20 {
            _ = try await decoder.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: imageID,
                    windowHeadDistance: UInt32(min(imageID, 2)),
                    compressed: [0, UInt8(imageID), 2, 3]
                )
            )
        }
        let retained = try await decoder.decode(
            descriptor: .init(width: 1, height: 1),
            payload: glzPayload(
                type: 8,
                width: 1,
                height: 1,
                imageID: 21,
                windowHeadDistance: 3,
                compressed: [0x20, 0, 3]
            )
        )
        #expect(retained.pixelsBGRA == Data([18, 2, 3, 0]))
        await #expect(throws: SpiceCodecError.self) {
            try await decoder.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: 22,
                    windowHeadDistance: 4,
                    compressed: [0x20, 0, 5]
                )
            )
        }
    }

    @Test func retainsAdvertisedWindowBeyondLegacyImageCount() async throws {
        let decoder = SpiceGLZDecoder()
        for imageID: UInt64 in 0...1_024 {
            _ = try await decoder.decode(
                descriptor: .init(width: 1, height: 1),
                payload: glzPayload(
                    type: 8,
                    width: 1,
                    height: 1,
                    imageID: imageID,
                    windowHeadDistance: UInt32(imageID),
                    compressed: [0, UInt8(truncatingIfNeeded: imageID), 2, 3]
                )
            )
        }
    }

    private func glzPayload(
        type: UInt8,
        width: UInt32,
        height: UInt32,
        imageID: UInt64,
        windowHeadDistance: UInt32,
        compressed: [UInt8]
    ) -> Data {
        var data = Data([0x20, 0x20, 0x5a, 0x4c, 0, 1, 0, 1, type | 0x10])
        appendBE(width, to: &data)
        appendBE(height, to: &data)
        let bytesPerPixel: UInt32 = type == 6 ? 2 : (type == 7 ? 3 : 4)
        appendBE(width * bytesPerPixel, to: &data)
        appendBE(imageID, to: &data)
        appendBE(windowHeadDistance, to: &data)
        data.append(contentsOf: compressed)
        return data
    }

    private func appendBE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private func appendBE(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private func appendSameImageReference(
        length: Int,
        lengthBias: Int,
        pixelOffset: Int,
        to bytes: inout [UInt8]
    ) {
        var encodedLength = length - lengthBias
        precondition(encodedLength >= 7)
        precondition((1...16).contains(pixelOffset))
        bytes.append(0xe0 | UInt8(pixelOffset - 1))
        encodedLength -= 7
        while encodedLength >= 255 {
            bytes.append(255)
            encodedLength -= 255
        }
        bytes.append(UInt8(encodedLength))
        bytes.append(0)
        bytes.append(0)
    }

    private func appendLargeSameImageReference(
        length: Int,
        pixelOffset: Int,
        to bytes: inout [UInt8]
    ) {
        precondition(length >= 7)
        precondition(pixelOffset > 65_536)
        let encodedOffset = pixelOffset - 1
        precondition(encodedOffset < 1 << 25)

        bytes.append(0xf0 | UInt8(encodedOffset & 0x0f))
        var remainingLength = length - 7
        while remainingLength >= 255 {
            bytes.append(255)
            remainingLength -= 255
        }
        bytes.append(UInt8(remainingLength))
        bytes.append(UInt8(truncatingIfNeeded: encodedOffset >> 4))
        var referenceCode = UInt8((encodedOffset >> 12) & 0x1f)
        if encodedOffset >= 1 << 17 {
            referenceCode |= 0x20
        }
        bytes.append(referenceCode)
        if referenceCode & 0x20 != 0 {
            bytes.append(UInt8(truncatingIfNeeded: encodedOffset >> 17))
        }
    }

    private func indexedRGBLiteralCommands(count: Int) -> [UInt8] {
        var commands: [UInt8] = []
        commands.reserveCapacity(count * 3 + (count + 31) / 32)
        var pixel = 0
        while pixel < count {
            let literalCount = min(32, count - pixel)
            commands.append(UInt8(literalCount - 1))
            for index in pixel..<(pixel + literalCount) {
                commands.append(UInt8(truncatingIfNeeded: index))
                commands.append(UInt8(truncatingIfNeeded: index >> 8))
                commands.append(UInt8(truncatingIfNeeded: index >> 16))
            }
            pixel += literalCount
        }
        return commands
    }

    private func hostileMissingDependencyPayload(
        pixelCount: Int,
        imageID: UInt64
    ) -> Data {
        precondition(pixelCount > 1)
        precondition(imageID > 0)
        var compressed: [UInt8] = [0x20, 0, 1]
        compressed.append(contentsOf: literalGLZCommands(count: pixelCount - 1))
        return glzPayload(
            type: 8,
            width: UInt32(pixelCount),
            height: 1,
            imageID: imageID,
            windowHeadDistance: 0,
            compressed: compressed
        )
    }

    private func largeRepeatedGLZPayload(
        width: Int,
        height: Int,
        imageID: UInt64,
        pixel: [UInt8]
    ) -> Data {
        precondition(pixel.count == 3)
        let pixelCount = width * height
        var compressed: [UInt8] = [0]
        compressed.append(contentsOf: pixel)
        appendSameImageReference(
            length: pixelCount - 1,
            lengthBias: 0,
            pixelOffset: 1,
            to: &compressed
        )
        return glzPayload(
            type: 8,
            width: UInt32(width),
            height: UInt32(height),
            imageID: imageID,
            windowHeadDistance: 0,
            compressed: compressed
        )
    }

    private func largeLiteralGLZPayload(
        width: Int,
        height: Int,
        imageID: UInt64
    ) -> Data {
        glzPayload(
            type: 8,
            width: UInt32(width),
            height: UInt32(height),
            imageID: imageID,
            windowHeadDistance: 0,
            compressed: literalGLZCommands(count: width * height)
        )
    }

    private func literalGLZCommands(count: Int) -> [UInt8] {
        var commands: [UInt8] = []
        commands.reserveCapacity(count * 4)
        for index in 0..<count {
            commands.append(0)
            commands.append(UInt8(truncatingIfNeeded: index * 3 + 1))
            commands.append(UInt8(truncatingIfNeeded: index * 3 + 2))
            commands.append(UInt8(truncatingIfNeeded: index * 3 + 3))
        }
        return commands
    }

    private func literalGLZPixels(count: Int) -> Data {
        var pixels = Data(capacity: count * 4)
        for index in 0..<count {
            pixels.append(UInt8(truncatingIfNeeded: index * 3 + 1))
            pixels.append(UInt8(truncatingIfNeeded: index * 3 + 2))
            pixels.append(UInt8(truncatingIfNeeded: index * 3 + 3))
            pixels.append(0)
        }
        return pixels
    }

    private func uniformPixels(_ pixel: [UInt8], count: Int) -> Data {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(pixel.count * count)
        for _ in 0..<count {
            pixels.append(contentsOf: pixel)
        }
        return Data(pixels)
    }

    private func expectUniformPixels(_ pixels: Data, pixel: [UInt8], count: Int) {
        #expect(pixel.count == 4)
        #expect(pixels.count == count * 4)
        let mismatch = pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            for index in 0..<count {
                let offset = index * 4
                if bytes[offset] != pixel[0]
                    || bytes[offset + 1] != pixel[1]
                    || bytes[offset + 2] != pixel[2]
                    || bytes[offset + 3] != pixel[3]
                {
                    return index
                }
            }
            return nil
        }
        #expect(mismatch == nil, "first mismatching pixel: \(String(describing: mismatch))")
    }

    private func expectLiteralPixels(_ pixels: Data, count: Int) {
        #expect(pixels.count == count * 4)
        let mismatch = pixels.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int? in
            for index in 0..<count {
                let offset = index * 4
                if bytes[offset] != UInt8(truncatingIfNeeded: index * 3 + 1)
                    || bytes[offset + 1] != UInt8(truncatingIfNeeded: index * 3 + 2)
                    || bytes[offset + 2] != UInt8(truncatingIfNeeded: index * 3 + 3)
                    || bytes[offset + 3] != 0
                {
                    return index
                }
            }
            return nil
        }
        #expect(mismatch == nil, "first mismatching pixel: \(String(describing: mismatch))")
    }
}

private func waitForGLZ(
    _ decoder: SpiceGLZDecoder,
    where predicate: (SpiceGLZDecoderDiagnostics) -> Bool
) async {
    for _ in 0..<10_000 {
        if predicate(await decoder.diagnosticsSnapshot()) { return }
        await Task.yield()
    }
    Issue.record("GLZ diagnostics did not reach the expected state")
}

private func waitForExecutor(
    _ executor: SpiceCodecTaskExecutor,
    maximumYields: Int = 10_000,
    where predicate: (SpiceCodecTaskExecutorDiagnostics) -> Bool
) async {
    for _ in 0..<maximumYields {
        if predicate(await executor.diagnosticsSnapshot()) { return }
        await Task.yield()
    }
    Issue.record("codec executor diagnostics did not reach the expected state")
}

private actor GLZOperationGate {
    private var started = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

enum GLZShortDistanceColorFormat: CaseIterable, Sendable {
    case rgb16
    case rgb24

    var wireType: UInt8 {
        switch self {
        case .rgb16: 6
        case .rgb24: 7
        }
    }

    var literalBytes: [UInt8] {
        switch self {
        case .rgb16: [0x7c, 0x00]
        case .rgb24: [0x12, 0x34, 0x56]
        }
    }

    var expectedBGRA: [UInt8] {
        switch self {
        case .rgb16: [0x00, 0x00, 0xff, 0x00]
        case .rgb24: [0x12, 0x34, 0x56, 0x00]
        }
    }

    var referenceLengthBias: Int {
        switch self {
        case .rgb16: 1
        case .rgb24: 0
        }
    }
}

private struct GLZReferenceFixture: Decodable {
    struct Entry: Decodable {
        let width: Int
        let height: Int
        let compressedBase64: String
        let expectedBGRABase64: String
    }

    let generator: String
    let entries: [Entry]
}
