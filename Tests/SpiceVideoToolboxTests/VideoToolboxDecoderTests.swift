import Foundation
import Testing
@testable import SpiceCodecs
@testable import SpiceVideoToolbox

@Suite("VideoToolbox decoder boundary")
struct VideoToolboxDecoderTests {
    @Test func factoryRejectsInvalidOrOverLimitGeometry() throws {
        let factory = SpiceVideoToolboxDecoderFactory(limits: .init(
            maximumEncodedBytes: 1_024,
            maximumNALUnits: 16,
            maximumNALUnitBytes: 512,
            maximumDimension: 64,
            maximumDecodedBytes: 64 * 64 * 4
        ))

        #expect(throws: SpiceCodecError.invalidDimensions(width: 0, height: 1)) {
            try factory.makeDecoder(codec: .h264, width: 0, height: 1)
        }
        #expect(throws: SpiceCodecError.invalidDimensions(width: 65, height: 64)) {
            try factory.makeDecoder(codec: .h265, width: 65, height: 64)
        }
    }

    @Test func pictureBeforeParameterSetsFailsInsideTypedBoundary() async throws {
        let decoder = try SpiceVideoToolboxDecoder(
            codec: .h264,
            width: 16,
            height: 16
        )

        await #expect(throws: SpiceCodecError.self) {
            try await decoder.decode(
                payload: Data([0, 0, 0, 1, 0x65, 0x88, 0x84]),
                multimediaTime: 1
            )
        }
        await decoder.close()
    }
}
