import Foundation
import Testing
@testable import SpiceCodecs

@Suite("Advanced video access-unit parser")
struct AdvancedVideoDecoderTests {
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

    @Test func parameterSetOnlyAccessUnitProducesNoSample() throws {
        let accessUnit = try SpiceAnnexBParser().parse(
            codec: .h264,
            payload: Data([0, 0, 1, 0x67, 0x42, 0x00, 0x1e])
        )

        #expect(!accessUnit.containsPicture)
        #expect(!accessUnit.isRandomAccess)
        #expect(accessUnit.sampleData.isEmpty)
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
