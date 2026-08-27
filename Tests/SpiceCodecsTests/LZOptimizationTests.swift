import Foundation
import Testing
@testable import SpiceCodecs

@Suite("SPICE LZ AIP-31 allocation and copy kernels")
struct LZOptimizationTests {
    @Test(arguments: LZFixtureName.allCases)
    fileprivate func referenceFormatsAreBitExactWithOneDecodedBacking(
        fixtureName: LZFixtureName
    ) async throws {
        let fixture: LZReferenceFixture = try loadFixture(fixtureName.rawValue)
        let payload = try #require(Data(base64Encoded: fixture.compressedBase64))
        let expected = try #require(Data(base64Encoded: fixture.expectedXRGBBase64))

        let result = try await SpiceLZDecoder().decodeWithDiagnostics(
            descriptor: SpiceCodecImageDescriptor(
                width: fixture.width,
                height: fixture.height
            ),
            payload: payload
        )

        #expect(result.image.pixelsBGRA == expected, Comment(rawValue: fixture.generator))
        #expect(result.image.alphaMode == (fixture.hasAlpha ? .straight : .opaque))
        expectOneOutputBacking(result.diagnostics, byteCount: expected.count)
    }

    @Test(arguments: LZPaletteFixtureName.allCases)
    fileprivate func paletteReferenceFormatsExpandDirectlyIntoOneDecodedBacking(
        fixtureName: LZPaletteFixtureName
    ) async throws {
        let fixture: LZPaletteReferenceFixture = try loadFixture(fixtureName.rawValue)
        let payload = try #require(Data(base64Encoded: fixture.compressedBase64))
        let expected = try #require(Data(base64Encoded: fixture.expectedXRGBBase64))

        let result = try await SpiceLZDecoder().decodePaletteWithDiagnostics(
            descriptor: SpiceCodecImageDescriptor(
                width: fixture.width,
                height: fixture.height
            ),
            payload: payload,
            palette: SpiceLZPalette(
                uniqueID: fixture.paletteID,
                entriesARGB: fixture.paletteARGB
            )
        )

        #expect(result.image.pixelsBGRA == expected, Comment(rawValue: fixture.generator))
        expectOneOutputBacking(result.diagnostics, byteCount: expected.count)
        #expect(
            result.diagnostics.paletteLookupExpansions
                == UInt64(fixture.packedStride * fixture.height)
        )
        #expect(
            result.diagnostics.paletteLookupPixels
                == UInt64(fixture.width * fixture.height)
        )
    }

    @Test(arguments: LZReferenceKind.allCases)
    fileprivate func overlappingAndExtendedReferencesRemainBitExactWithBoundedBulkCopies(
        kind: LZReferenceKind
    ) async throws {
        let fixture = makeReferenceFixture(kind)

        let result = try await SpiceLZDecoder().decodeWithDiagnostics(
            descriptor: SpiceCodecImageDescriptor(width: fixture.width, height: 1),
            payload: makeLZPayload(
                type: 7,
                width: fixture.width,
                height: 1,
                stride: fixture.width * 3,
                commands: fixture.commands
            )
        )

        #expect(result.image.pixelsBGRA == bgraPixels(fixture.expectedPixels))
        expectOneOutputBacking(
            result.diagnostics,
            byteCount: fixture.expectedPixels.count * 4
        )
        #expect(result.diagnostics.referenceBulkCopyCalls > 0)
        #expect(
            result.diagnostics.referenceBulkCopyCalls
                <= UInt64(fixture.maximumBulkCopyCalls)
        )
        #expect(
            result.diagnostics.referenceBulkCopyBytes
                == UInt64(fixture.referencePixelCount * 4)
        )
    }

    @Test(arguments: PalettePackingKind.allCases)
    fileprivate func paletteBitOrderTailAndModuloSemanticsAreBitExact(
        kind: PalettePackingKind
    ) async throws {
        let fixture = makePalettePackingFixture(kind)
        let expected = palettePixels(
            indices: fixture.expectedIndices,
            entriesARGB: fixture.palette
        )

        let result = try await SpiceLZDecoder().decodePaletteWithDiagnostics(
            descriptor: SpiceCodecImageDescriptor(width: fixture.width, height: 1),
            payload: makePalettePayload(
                type: fixture.type,
                width: fixture.width,
                height: 1,
                packedCommands: literalBytes(fixture.packedBytes)
            ),
            palette: SpiceLZPalette(uniqueID: 1, entriesARGB: fixture.palette)
        )

        #expect(result.image.pixelsBGRA == expected)
        expectOneOutputBacking(result.diagnostics, byteCount: fixture.width * 4)
        #expect(
            result.diagnostics.paletteLookupExpansions
                == UInt64(fixture.packedBytes.count)
        )
        #expect(result.diagnostics.paletteLookupPixels == UInt64(fixture.width))
    }

    @Test func palettePackedReferenceCrossesRowsBeforeLookupExpansion() async throws {
        let width = 9
        let height = 3
        let palette: [UInt32] = [0x0011_2233, 0x0044_5566]
        // Packed output is [AA, 01, 01, 01, 01, 01]. The distance-one
        // reference starts at row 0's partial byte (packed column 1) and writes
        // row 1's full byte (packed column 0), then continues across row 2.
        let commands = literalBytes([0xaa, 0x01]) + encodeMatch(
            length: 4,
            distance: 1,
            matchLengthBias: 3
        )
        let row0 = bitsLSBFirst(0xaa, count: 8) + [1]
        let repeatedRow = bitsLSBFirst(0x01, count: 8) + [1]
        let expectedIndices = row0 + repeatedRow + repeatedRow
        let outputByteCount = width * height * 4
        let decoder = SpiceLZDecoder(limits: SpiceLZDecodeLimits(
            maximumDecodedBytes: outputByteCount
        ))

        let result = try await decoder.decodePaletteWithDiagnostics(
            descriptor: SpiceCodecImageDescriptor(width: width, height: height),
            payload: makePalettePayload(
                type: 1,
                width: width,
                height: height,
                packedCommands: commands
            ),
            palette: SpiceLZPalette(uniqueID: 2, entriesARGB: palette)
        )

        #expect(
            result.image.pixelsBGRA
                == palettePixels(indices: expectedIndices, entriesARGB: palette)
        )
        expectOneOutputBacking(result.diagnostics, byteCount: outputByteCount)
        #expect(result.diagnostics.referenceBulkCopyCalls <= 3)
        #expect(result.diagnostics.referenceBulkCopyBytes == 4)
        #expect(result.diagnostics.paletteLookupExpansions == 6)
        #expect(result.diagnostics.paletteLookupPixels == 27)
    }

    @Test func rgbaAlphaPlaneOverlapUsesOneBoundedBulkCopy() async throws {
        let width = 4_096
        let color = RGBPixel(blue: 0x12, green: 0x34, red: 0x56)
        let alpha: UInt8 = 0x78
        let referencedAlphaCount = width - 1
        let commands = literalRGB(Array(repeating: color, count: width))
            + literalBytes([alpha])
            + encodeMatch(
                length: referencedAlphaCount,
                distance: 1,
                matchLengthBias: 3
            )

        let result = try await SpiceLZDecoder().decodeWithDiagnostics(
            descriptor: SpiceCodecImageDescriptor(width: width, height: 1),
            payload: makeLZPayload(
                type: 9,
                width: width,
                height: 1,
                stride: width * 4,
                commands: commands
            )
        )

        #expect(
            result.image.pixelsBGRA
                == bgraPixels(
                    Array(repeating: color, count: width),
                    alpha: alpha
                )
        )
        #expect(result.image.alphaMode == .straight)
        expectOneOutputBacking(result.diagnostics, byteCount: width * 4)
        #expect(result.diagnostics.referenceBulkCopyCalls == 1)
        #expect(
            result.diagnostics.referenceBulkCopyBytes
                == UInt64(referencedAlphaCount)
        )
    }

    @Test(arguments: MalformedLZKind.allCases)
    fileprivate func malformedReferencesAndTruncationRemainDeterministicAndAtomic(
        kind: MalformedLZKind
    ) async throws {
        let fixture = makeMalformedFixture(kind)
        let decoder = SpiceLZDecoder()

        for _ in 0..<2 {
            await #expect(throws: fixture.error) {
                try await decoder.decodeWithDiagnostics(
                    descriptor: SpiceCodecImageDescriptor(
                        width: fixture.width,
                        height: 1
                    ),
                    payload: makeLZPayload(
                        type: 7,
                        width: fixture.width,
                        height: 1,
                        stride: fixture.width * 3,
                        commands: fixture.commands
                    )
                )
            }
        }

        let recovery = makeReferenceFixture(.distanceOne)
        let decoded = try await decoder.decodeWithDiagnostics(
            descriptor: SpiceCodecImageDescriptor(width: recovery.width, height: 1),
            payload: makeLZPayload(
                type: 7,
                width: recovery.width,
                height: 1,
                stride: recovery.width * 3,
                commands: recovery.commands
            )
        )
        #expect(decoded.image.pixelsBGRA == bgraPixels(recovery.expectedPixels))
        expectOneOutputBacking(decoded.diagnostics, byteCount: recovery.width * 4)
    }

    @Test func decodedByteLimitRejectsBeforePublicationAndAllowsExactOutput() async throws {
        let fixture = makeReferenceFixture(.distanceOne)
        let payload = makeLZPayload(
            type: 7,
            width: fixture.width,
            height: 1,
            stride: fixture.width * 3,
            commands: fixture.commands
        )
        let outputByteCount = fixture.width * 4

        await #expect(
            throws: SpiceCodecError.decodedImageTooLarge(
                actual: outputByteCount,
                maximum: outputByteCount - 1
            )
        ) {
            try await SpiceLZDecoder(limits: SpiceLZDecodeLimits(
                maximumDecodedBytes: outputByteCount - 1
            )).decodeWithDiagnostics(
                descriptor: SpiceCodecImageDescriptor(width: fixture.width, height: 1),
                payload: payload
            )
        }

        let exact = try await SpiceLZDecoder(limits: SpiceLZDecodeLimits(
            maximumDecodedBytes: outputByteCount
        )).decodeWithDiagnostics(
            descriptor: SpiceCodecImageDescriptor(width: fixture.width, height: 1),
            payload: payload
        )
        #expect(exact.image.pixelsBGRA == bgraPixels(fixture.expectedPixels))
        expectOneOutputBacking(exact.diagnostics, byteCount: outputByteCount)
    }
}

private enum LZFixtureName: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case rgb16 = "lz-rgb16-6x3"
    case rgb24 = "lz-rgb24-6x3"
    case rgb32 = "lz-rgb32-6x3"
    case rgba = "lz-rgba-6x3"
    case xxxa = "lz-xxxa-6x3"
    case a8 = "lz-a8-6x3"

    var testDescription: String { rawValue }
}

private enum LZPaletteFixtureName: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case plt1LE = "lzplt-plt1le-9x3"
    case plt1BE = "lzplt-plt1be-9x3"
    case plt4LE = "lzplt-plt4le-9x3"
    case plt4BE = "lzplt-plt4be-9x3"
    case plt8 = "lzplt-plt8-9x3"

    var testDescription: String { rawValue }
}

private enum LZReferenceKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case distanceOne
    case distanceThree
    case longRepeat
    case extendedDistance

    var testDescription: String { rawValue }
}

private enum PalettePackingKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case oneBitLE
    case oneBitBE
    case fourBitLEModulo
    case fourBitBEModulo
    case eightBit

    var testDescription: String { rawValue }
}

private enum MalformedLZKind: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case referenceBeforeOutput
    case referenceBeyondOutput
    case truncatedLengthExtension
    case trailingBytes

    var testDescription: String { rawValue }
}

private struct LZReferenceFixture: Decodable {
    let generator: String
    let format: String
    let width: Int
    let height: Int
    let compressedBase64: String
    let expectedXRGBBase64: String

    var hasAlpha: Bool {
        format == "rgba" || format == "xxxa" || format == "a8"
    }
}

private struct LZPaletteReferenceFixture: Decodable {
    let generator: String
    let format: String
    let width: Int
    let height: Int
    let paletteID: UInt64
    let paletteARGB: [UInt32]
    let compressedBase64: String
    let expectedXRGBBase64: String

    var pixelsPerByte: Int {
        switch format {
        case "plt1le", "plt1be": 8
        case "plt4le", "plt4be": 2
        default: 1
        }
    }

    var packedStride: Int {
        (width + pixelsPerByte - 1) / pixelsPerByte
    }
}

private struct RGBPixel: Sendable, Equatable {
    let blue: UInt8
    let green: UInt8
    let red: UInt8
}

private struct ReferenceFixture {
    let width: Int
    let commands: Data
    let expectedPixels: [RGBPixel]
    let referencePixelCount: Int
    let maximumBulkCopyCalls: Int
}

private struct PalettePackingFixture {
    let type: UInt32
    let width: Int
    let packedBytes: [UInt8]
    let palette: [UInt32]
    let expectedIndices: [Int]
}

private struct MalformedFixture {
    let width: Int
    let commands: Data
    let error: SpiceCodecError
}

private func loadFixture<Fixture: Decodable>(_ name: String) throws -> Fixture {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
}

private func expectOneOutputBacking(
    _ diagnostics: SpiceLZDecodeDiagnostics,
    byteCount: Int
) {
    #expect(diagnostics.decodedOutputAllocations == 1)
    #expect(diagnostics.decodedOutputBytes == UInt64(byteCount))
    #expect(diagnostics.temporaryDecodedBackingAllocations == 0)
    #expect(diagnostics.temporaryDecodedBackingBytes == 0)
}

private func makeReferenceFixture(_ kind: LZReferenceKind) -> ReferenceFixture {
    switch kind {
    case .distanceOne:
        let seed = RGBPixel(blue: 1, green: 2, red: 3)
        let referenceCount = 127
        return ReferenceFixture(
            width: 128,
            commands: literalRGB([seed]) + encodeMatch(
                length: referenceCount,
                distance: 1,
                matchLengthBias: 1
            ),
            expectedPixels: Array(repeating: seed, count: 128),
            referencePixelCount: referenceCount,
            maximumBulkCopyCalls: maximumDoublingCalls(
                length: referenceCount,
                distance: 1
            )
        )
    case .distanceThree:
        let seed = [
            RGBPixel(blue: 1, green: 2, red: 3),
            RGBPixel(blue: 4, green: 5, red: 6),
            RGBPixel(blue: 7, green: 8, red: 9),
        ]
        let referenceCount = 125
        return ReferenceFixture(
            width: 128,
            commands: literalRGB(seed) + encodeMatch(
                length: referenceCount,
                distance: 3,
                matchLengthBias: 1
            ),
            expectedPixels: (0..<128).map { seed[$0 % seed.count] },
            referencePixelCount: referenceCount,
            maximumBulkCopyCalls: maximumDoublingCalls(
                length: referenceCount,
                distance: 3
            )
        )
    case .longRepeat:
        let seed = RGBPixel(blue: 0x12, green: 0x34, red: 0x56)
        let referenceCount = 4_095
        return ReferenceFixture(
            width: 4_096,
            commands: literalRGB([seed]) + encodeMatch(
                length: referenceCount,
                distance: 1,
                matchLengthBias: 1
            ),
            expectedPixels: Array(repeating: seed, count: 4_096),
            referencePixelCount: referenceCount,
            maximumBulkCopyCalls: maximumDoublingCalls(
                length: referenceCount,
                distance: 1
            )
        )
    case .extendedDistance:
        let literalCount = 8_192
        let seed = (0..<literalCount).map { index in
            RGBPixel(
                blue: UInt8(truncatingIfNeeded: index),
                green: UInt8(truncatingIfNeeded: index >> 3),
                red: UInt8(truncatingIfNeeded: index >> 7)
            )
        }
        let referenceCount = 8
        return ReferenceFixture(
            width: literalCount + referenceCount,
            commands: literalRGB(seed) + encodeMatch(
                length: referenceCount,
                distance: 8_192,
                matchLengthBias: 1
            ),
            expectedPixels: seed + Array(seed.prefix(referenceCount)),
            referencePixelCount: referenceCount,
            maximumBulkCopyCalls: 1
        )
    }
}

private func makePalettePackingFixture(_ kind: PalettePackingKind) -> PalettePackingFixture {
    let palette: [UInt32] = [0x0011_2233, 0x0044_5566, 0x0077_8899]
    switch kind {
    case .oneBitLE:
        return PalettePackingFixture(
            type: 1,
            width: 9,
            packedBytes: [0b1010_0101, 0b1111_1110],
            palette: palette,
            expectedIndices: bitsLSBFirst(0b1010_0101, count: 8) + [0]
        )
    case .oneBitBE:
        return PalettePackingFixture(
            type: 2,
            width: 9,
            packedBytes: [0b1010_0101, 0b1111_1111],
            palette: palette,
            expectedIndices: bitsMSBFirst(0b1010_0101, count: 8) + [1]
        )
    case .fourBitLEModulo:
        return PalettePackingFixture(
            type: 3,
            width: 3,
            packedBytes: [0xe5, 0xf0],
            palette: palette,
            expectedIndices: [5 % 3, 14 % 3, 0]
        )
    case .fourBitBEModulo:
        return PalettePackingFixture(
            type: 4,
            width: 3,
            packedBytes: [0xe5, 0x0f],
            palette: palette,
            expectedIndices: [14 % 3, 5 % 3, 0]
        )
    case .eightBit:
        return PalettePackingFixture(
            type: 5,
            width: 3,
            packedBytes: [2, 1, 0],
            palette: palette,
            expectedIndices: [2, 1, 0]
        )
    }
}

private func makeMalformedFixture(_ kind: MalformedLZKind) -> MalformedFixture {
    let seed = RGBPixel(blue: 1, green: 2, red: 3)
    switch kind {
    case .referenceBeforeOutput:
        return MalformedFixture(
            width: 4,
            commands: encodeMatch(length: 4, distance: 1, matchLengthBias: 1),
            error: .malformedPayload("LZ reference precedes output")
        )
    case .referenceBeyondOutput:
        return MalformedFixture(
            width: 2,
            commands: literalRGB([seed]) + encodeMatch(
                length: 3,
                distance: 1,
                matchLengthBias: 1
            ),
            error: .malformedPayload("LZ reference exceeds output")
        )
    case .truncatedLengthExtension:
        return MalformedFixture(
            width: 16,
            commands: literalRGB([seed]) + Data([0xe0]),
            error: .malformedPayload("truncated LZ stream")
        )
    case .trailingBytes:
        return MalformedFixture(
            width: 1,
            commands: literalRGB([seed]) + Data([0xff]),
            error: .malformedPayload("trailing compressed bytes")
        )
    }
}

private func makeLZPayload(
    type: UInt32,
    width: Int,
    height: Int,
    stride: Int,
    commands: Data
) -> Data {
    var payload = Data()
    appendUInt32BE(0x2020_5a4c, to: &payload)
    appendUInt32BE(0x0001_0001, to: &payload)
    appendUInt32BE(type, to: &payload)
    appendUInt32BE(UInt32(width), to: &payload)
    appendUInt32BE(UInt32(height), to: &payload)
    appendUInt32BE(UInt32(stride), to: &payload)
    appendUInt32BE(1, to: &payload)
    payload.append(commands)
    return payload
}

private func makePalettePayload(
    type: UInt32,
    width: Int,
    height: Int,
    packedCommands: Data
) -> Data {
    let pixelsPerByte: Int
    switch type {
    case 1, 2: pixelsPerByte = 8
    case 3, 4: pixelsPerByte = 2
    default: pixelsPerByte = 1
    }
    return makeLZPayload(
        type: type,
        width: width,
        height: height,
        stride: (width + pixelsPerByte - 1) / pixelsPerByte,
        commands: packedCommands
    )
}

private func literalRGB(_ pixels: [RGBPixel]) -> Data {
    var result = Data()
    for start in stride(from: 0, to: pixels.count, by: 32) {
        let end = min(start + 32, pixels.count)
        result.append(UInt8(end - start - 1))
        for pixel in pixels[start..<end] {
            result.append(contentsOf: [pixel.blue, pixel.green, pixel.red])
        }
    }
    return result
}

private func literalBytes(_ bytes: [UInt8]) -> Data {
    var result = Data()
    for start in stride(from: 0, to: bytes.count, by: 32) {
        let end = min(start + 32, bytes.count)
        result.append(UInt8(end - start - 1))
        result.append(contentsOf: bytes[start..<end])
    }
    return result
}

private func encodeMatch(
    length: Int,
    distance: Int,
    matchLengthBias: Int
) -> Data {
    precondition(length >= matchLengthBias)
    precondition(distance > 0 && distance <= 8_192 + Int(UInt16.max))
    let encodedLength = length - matchLengthBias
    let extendedLength = encodedLength >= 6
    let highLength = extendedLength ? 7 : encodedLength + 1
    let encodedDistance = distance - 1
    let extendedDistance = distance >= 8_192
    let distanceHigh = extendedDistance ? 31 : encodedDistance >> 8
    var result = Data([UInt8((highLength << 5) | distanceHigh)])

    if extendedLength {
        var remainder = encodedLength - 6
        while remainder >= 255 {
            result.append(255)
            remainder -= 255
        }
        result.append(UInt8(remainder))
    }

    if extendedDistance {
        result.append(255)
        let farDistance = UInt16(distance - 8_192)
        result.append(UInt8(truncatingIfNeeded: farDistance >> 8))
        result.append(UInt8(truncatingIfNeeded: farDistance))
    } else {
        result.append(UInt8(encodedDistance & 0xff))
    }
    return result
}

private func bgraPixels(_ pixels: some Sequence<RGBPixel>) -> Data {
    var output = Data()
    for pixel in pixels {
        output.append(contentsOf: [pixel.blue, pixel.green, pixel.red, 0])
    }
    return output
}

private func bgraPixels(
    _ pixels: some Sequence<RGBPixel>,
    alpha: UInt8
) -> Data {
    var output = Data()
    for pixel in pixels {
        output.append(contentsOf: [pixel.blue, pixel.green, pixel.red, alpha])
    }
    return output
}

private func palettePixels(indices: [Int], entriesARGB: [UInt32]) -> Data {
    var output = Data()
    for index in indices {
        let entry = entriesARGB[index]
        output.append(contentsOf: [
            UInt8(truncatingIfNeeded: entry),
            UInt8(truncatingIfNeeded: entry >> 8),
            UInt8(truncatingIfNeeded: entry >> 16),
            0,
        ])
    }
    return output
}

private func bitsLSBFirst(_ byte: UInt8, count: Int) -> [Int] {
    (0..<count).map { Int((byte >> $0) & 1) }
}

private func bitsMSBFirst(_ byte: UInt8, count: Int) -> [Int] {
    (0..<count).map { Int((byte >> (7 - $0)) & 1) }
}

private func maximumDoublingCalls(length: Int, distance: Int) -> Int {
    var copied = min(length, distance)
    var calls = copied > 0 ? 1 : 0
    var remaining = length - copied
    while remaining > 0 {
        let next = min(copied, remaining)
        copied += next
        remaining -= next
        calls += 1
    }
    return calls
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
        UInt8(truncatingIfNeeded: value >> 24),
        UInt8(truncatingIfNeeded: value >> 16),
        UInt8(truncatingIfNeeded: value >> 8),
        UInt8(truncatingIfNeeded: value),
    ])
}
