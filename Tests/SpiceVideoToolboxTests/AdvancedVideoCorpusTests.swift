import Foundation
import Testing
@testable import SpiceCodecs
@testable import SpiceVideoToolbox

@Suite("VideoToolbox advanced-video corpus")
struct AdvancedVideoCorpusTests {
    @Test func decodesIndependentH264AndH265Goldens() async throws {
        for fixture in try loadFixtures() {
            let encoded = try #require(Data(base64Encoded: fixture.annexBBase64))
            let expected = try #require(Data(base64Encoded: fixture.expectedBGRABase64))
            let decoder = try SpiceVideoToolboxDecoder(
                codec: fixture.codec.decoderCodec,
                width: fixture.width,
                height: fixture.height
            )

            let decoded = try #require(try await decoder.decode(
                payload: encoded,
                multimediaTime: 1
            ))
            await decoder.close()

            #expect(decoded.width == fixture.width, Comment(rawValue: fixture.generator))
            #expect(decoded.height == fixture.height, Comment(rawValue: fixture.generator))
            #expect(decoded.bytesPerRow == fixture.width * 4)
            try expectBGRA(decoded.pixelsBGRA, matches: expected, maximumColorDelta: 4)
        }
    }

    @Test func rebuildsH264SessionWhenParameterSetsChange() async throws {
        let high = try loadFixture(named: "h264-high-128x128")
        let baseline = try loadFixture(named: "h264-baseline-128x128")
        let highPayload = try #require(Data(base64Encoded: high.annexBBase64))
        let baselinePayload = try #require(Data(base64Encoded: baseline.annexBBase64))
        let decoder = try SpiceVideoToolboxDecoder(codec: .h264, width: 128, height: 128)

        let first = try #require(try await decoder.decode(
            payload: highPayload,
            multimediaTime: 10
        ))
        let second = try #require(try await decoder.decode(
            payload: baselinePayload,
            multimediaTime: 20
        ))
        await decoder.close()

        try expectBGRA(
            first.pixelsBGRA,
            matches: try #require(Data(base64Encoded: high.expectedBGRABase64)),
            maximumColorDelta: 4
        )
        try expectBGRA(
            second.pixelsBGRA,
            matches: try #require(Data(base64Encoded: baseline.expectedBGRABase64)),
            maximumColorDelta: 4
        )
    }

    private func loadFixture(named name: String) throws -> AdvancedVideoFixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(AdvancedVideoFixture.self, from: Data(contentsOf: url))
    }

    private func loadFixtures() throws -> [AdvancedVideoFixture] {
        try [
            "h264-baseline-128x128",
            "h264-high-128x128",
            "h265-main-128x128",
        ].map(loadFixture(named:))
    }

    private func expectBGRA(
        _ actual: Data,
        matches expected: Data,
        maximumColorDelta: UInt8
    ) throws {
        #expect(actual.count == expected.count)
        guard actual.count == expected.count else {
            return
        }
        var largestDelta: UInt8 = 0
        for offset in actual.indices {
            if offset % 4 == 3 {
                #expect(actual[offset] == 255)
                #expect(expected[offset] == 255)
                continue
            }
            let delta = UInt8(abs(Int(actual[offset]) - Int(expected[offset])))
            largestDelta = max(largestDelta, delta)
        }
        #expect(largestDelta <= maximumColorDelta, "largest RGB delta was \(largestDelta)")
    }
}

private struct AdvancedVideoFixture: Decodable {
    enum Codec: String, Decodable {
        case h264
        case h265

        var decoderCodec: SpiceAdvancedVideoCodec {
            switch self {
            case .h264: .h264
            case .h265: .h265
            }
        }
    }

    let generator: String
    let codec: Codec
    let width: Int
    let height: Int
    let annexBBase64: String
    let expectedBGRABase64: String
}
