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

    private func uniformPixels(_ pixel: [UInt8], count: Int) -> Data {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(pixel.count * count)
        for _ in 0..<count {
            pixels.append(contentsOf: pixel)
        }
        return Data(pixels)
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
