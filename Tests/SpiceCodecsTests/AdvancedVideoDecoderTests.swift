import Foundation
import Testing
@testable import SpiceCodecs

@Suite("Advanced video access-unit parser")
struct AdvancedVideoDecoderTests {
    enum MixedStartCodeCase: String, Sendable {
        case h264
        case h265

        var codec: SpiceAdvancedVideoCodec {
            switch self {
            case .h264: .h264
            case .h265: .h265
            }
        }

        var payload: Data {
            switch self {
            case .h264:
                Data([
                    0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1e,
                    0, 0, 1, 0x68, 0xce, 0x06,
                    0, 0, 0, 1, 0x65, 0x88, 0x84,
                    0, 0, 1, 0x61, 0x12, 0x34, 0x56,
                ])
            case .h265:
                Data([
                    0, 0, 0, 1, 0x40, 0x01, 0xaa,
                    0, 0, 1, 0x42, 0x01, 0xbb,
                    0, 0, 0, 1, 0x44, 0x01, 0xcc,
                    0, 0, 1, 0x26, 0x01, 0xdd,
                ])
            }
        }

        var expectedTypes: [UInt8] {
            switch self {
            case .h264: [7, 8, 5, 1]
            case .h265: [32, 33, 34, 19]
            }
        }

        var expectedParameterTypes: [UInt8] {
            switch self {
            case .h264: [7, 8]
            case .h265: [32, 33, 34]
            }
        }

        var expectedSample: Data {
            switch self {
            case .h264:
                Data([
                    0, 0, 0, 3, 0x65, 0x88, 0x84,
                    0, 0, 0, 4, 0x61, 0x12, 0x34, 0x56,
                ])
            case .h265:
                Data([0, 0, 0, 3, 0x26, 0x01, 0xdd])
            }
        }
    }

    @Test func packedImageProvidesTheNativeVideoFallbackContract() throws {
        let image = SpiceDecodedImage(
            width: 2,
            height: 1,
            bytesPerRow: 8,
            pixelsBGRA: Data([1, 2, 3, 255, 4, 5, 6, 255])
        )
        let frame: any SpiceDecodedVideoFrame = image

        #expect(frame.width == 2)
        #expect(frame.height == 1)
        #expect(frame.pixelFormat == .bgra8)
        #expect(frame.colorMatrix == .unknown(nil))
        #expect(frame.colorRange == .full)
        #expect(try frame.copyBGRA() == image)
    }

    @Test func convertsMixedH264AnnexBStartCodesToLengthPrefixedSample() throws {
        let payload = Data([
            0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1e,
            0, 0, 1, 0x68, 0xce, 0x06,
            0, 0, 0, 1, 0x65, 0x88, 0x84,
        ])

        let accessUnit = try SpiceAnnexBParser().parse(codec: .h264, payload: payload)

        #expect(accessUnit.nalUnits.map(\.type) == [7, 8, 5])
        #expect(accessUnit.parameterSets.map(\.type) == [7, 8])
        #expect(accessUnit.containsPicture)
        #expect(accessUnit.isRandomAccess)
        #expect(accessUnit.sampleData == Data([0, 0, 0, 3, 0x65, 0x88, 0x84]))
    }

    @Test func recognizesHEVCParameterSetsAndIRAPPicture() throws {
        let payload = Data([
            0, 0, 1, 0x40, 0x01, 0xaa, // VPS, type 32
            0, 0, 1, 0x42, 0x01, 0xbb, // SPS, type 33
            0, 0, 1, 0x44, 0x01, 0xcc, // PPS, type 34
            0, 0, 1, 0x26, 0x01, 0xdd, // IDR_W_RADL, type 19
        ])

        let accessUnit = try SpiceAnnexBParser().parse(codec: .h265, payload: payload)

        #expect(accessUnit.nalUnits.map(\.type) == [32, 33, 34, 19])
        #expect(accessUnit.parameterSets.map(\.type) == [32, 33, 34])
        #expect(accessUnit.containsPicture)
        #expect(accessUnit.isRandomAccess)
        #expect(accessUnit.sampleData == Data([0, 0, 0, 3, 0x26, 0x01, 0xdd]))
    }

    @Test(arguments: [MixedStartCodeCase.h264, .h265])
    func mixedThreeAndFourByteStartCodesRemainBitExact(
        _ fixture: MixedStartCodeCase
    ) throws {
        let result = try SpiceAnnexBParser().parseWithDiagnostics(
            codec: fixture.codec,
            payload: fixture.payload
        )
        let accessUnit = result.accessUnit

        #expect(accessUnit.nalUnits.map(\.type) == fixture.expectedTypes)
        #expect(accessUnit.parameterSets.map(\.type) == fixture.expectedParameterTypes)
        #expect(accessUnit.containsPicture)
        #expect(accessUnit.isRandomAccess)
        #expect(accessUnit.sampleData == fixture.expectedSample)

        let expectedSamplePayloadBytes = fixture.expectedSample.count -
            4 * (fixture.expectedTypes.count - fixture.expectedParameterTypes.count)
        #expect(result.diagnostics == SpiceAnnexBParserDiagnostics(
            scanPassCount: 1,
            inputCopyBytes: 0,
            nalPayloadMaterializations: 0,
            nalPayloadCopyBytes: 0,
            avccSampleAllocations: 1,
            avccSampleBytes: fixture.expectedSample.count,
            samplePayloadCopyBytes: expectedSamplePayloadBytes,
            nalUnitCount: fixture.expectedTypes.count
        ))

        let first = try #require(accessUnit.nalUnits.first)
        for nal in accessUnit.nalUnits.dropFirst() {
            #expect(first.sharesOwner(with: nal))
        }
        for parameterSet in accessUnit.parameterSets {
            #expect(first.sharesOwner(with: parameterSet))
        }
        for nal in accessUnit.nalUnits {
            let sourceBytes = fixture.payload.withUnsafeBytes {
                (payloadBytes: UnsafeRawBufferPointer) -> Data in
                Data(
                    bytes: payloadBytes.baseAddress!.advanced(by: nal.sourceRange.lowerBound),
                    count: nal.sourceRange.count
                )
            }
            #expect(nal.bytes == sourceBytes)
        }
    }

    @Test func annexBPaddingAndEmptyNALBoundariesAreDeterministic() throws {
        let parser = SpiceAnnexBParser()
        let padded = try parser.parse(
            codec: .h264,
            payload: Data([
                0, 0, 0, 1, 0x67, 0x42, 0x00, 0x1e,
                0, 0, 0,
                0, 0, 1, 0x65, 0x88, 0x84,
                0, 0,
            ])
        )
        #expect(padded.nalUnits.map(\.bytes) == [
            Data([0x67, 0x42, 0x00, 0x1e]),
            Data([0x65, 0x88, 0x84]),
        ])
        #expect(padded.sampleData == Data([0, 0, 0, 3, 0x65, 0x88, 0x84]))

        #expect(throws: SpiceCodecError.malformedPayload(
            "Annex-B contains an empty NAL unit"
        )) {
            try parser.parse(
                codec: .h264,
                payload: Data([0, 0, 1, 0, 0, 0, 1, 0x65])
            )
        }
        #expect(throws: SpiceCodecError.malformedPayload(
            "Annex-B ends with an empty NAL unit"
        )) {
            try parser.parse(
                codec: .h264,
                payload: Data([0, 0, 1, 0x65, 0x88, 0, 0, 0, 1])
            )
        }
    }

    @Test func configuredNALCountAndByteLimitsAreExactAndFailureAtomic() throws {
        let parser = SpiceAnnexBParser(limits: .init(
            maximumEncodedBytes: 14,
            maximumNALUnits: 2,
            maximumNALUnitBytes: 3,
            maximumDimension: 64,
            maximumDecodedBytes: 16_384
        ))
        let exact = Data([
            0, 0, 1, 0x67, 0x42, 0x1e,
            0, 0, 0, 1, 0x65, 0x88, 0x84,
        ])
        let accessUnit = try parser.parse(codec: .h264, payload: exact)
        #expect(accessUnit.nalUnits.map(\.bytes) == [
            Data([0x67, 0x42, 0x1e]),
            Data([0x65, 0x88, 0x84]),
        ])

        #expect(throws: SpiceCodecError.malformedPayload(
            "NAL unit exceeds configured byte limit"
        )) {
            try parser.parse(
                codec: .h264,
                payload: Data([0, 0, 1, 0x65, 1, 2, 3])
            )
        }
        #expect(throws: SpiceCodecError.malformedPayload(
            "access unit exceeds configured NAL unit limit"
        )) {
            try parser.parse(
                codec: .h264,
                payload: Data([
                    0, 0, 1, 0x67,
                    0, 0, 1, 0x68,
                    0, 0, 1, 0x65,
                ])
            )
        }
        #expect(throws: SpiceCodecError.encodedImageTooLarge(actual: 15, maximum: 14)) {
            try parser.parse(
                codec: .h264,
                payload: Data([0, 0, 1, 0x65] + Array(repeating: 1, count: 11))
            )
        }

        let retried = try parser.parse(codec: .h264, payload: exact)
        #expect(retried == accessUnit)
    }

    @Test func parameterSetOnlyAccessUnitProducesNoSample() throws {
        let result = try SpiceAnnexBParser().parseWithDiagnostics(
            codec: .h264,
            payload: Data([0, 0, 1, 0x67, 0x42, 0x00, 0x1e])
        )
        let accessUnit = result.accessUnit

        #expect(!accessUnit.containsPicture)
        #expect(!accessUnit.isRandomAccess)
        #expect(accessUnit.sampleData.isEmpty)
        #expect(result.diagnostics.avccSampleAllocations == 0)
        #expect(result.diagnostics.avccSampleBytes == 0)
        #expect(result.diagnostics.samplePayloadCopyBytes == 0)
        #expect(result.diagnostics.nalUnitCount == 1)
    }

    @Test func rejectsMalformedHeadersEmptyNALsAndConfiguredBounds() throws {
        let parser = SpiceAnnexBParser(limits: SpiceAdvancedVideoDecodeLimits(
            maximumEncodedBytes: 16,
            maximumNALUnits: 1,
            maximumNALUnitBytes: 4,
            maximumDimension: 64,
            maximumDecodedBytes: 16_384
        ))

        #expect(throws: SpiceCodecError.self) {
            try parser.parse(codec: .h264, payload: Data([0x65, 1, 2]))
        }
        #expect(throws: SpiceCodecError.self) {
            try parser.parse(codec: .h264, payload: Data([0, 0, 1]))
        }
        #expect(throws: SpiceCodecError.self) {
            try parser.parse(codec: .h264, payload: Data([0, 0, 1, 0x65, 0, 0, 1]))
        }
        #expect(throws: SpiceCodecError.self) {
            try parser.parse(codec: .h265, payload: Data([0, 0, 1, 0x26]))
        }
        #expect(throws: SpiceCodecError.self) {
            try parser.parse(codec: .h265, payload: Data([0, 0, 1, 0x26, 0]))
        }
        #expect(throws: SpiceCodecError.self) {
            try parser.parse(codec: .h264, payload: Data([0, 0, 1, 0xe5, 1]))
        }
        #expect(throws: SpiceCodecError.self) {
            try parser.parse(codec: .h264, payload: Data([0, 0, 1, 0x65, 1, 2, 3, 4]))
        }
        #expect(throws: SpiceCodecError.self) {
            try parser.parse(
                codec: .h264,
                payload: Data([0, 0, 1, 0x65, 1, 0, 0, 1, 0x61, 2])
            )
        }
    }
}
