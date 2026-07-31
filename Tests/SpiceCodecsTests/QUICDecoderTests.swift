import Foundation
import Testing
@testable import SpiceCodecs

@Suite("SPICE QUIC decoder")
struct QUICDecoderTests {
    @Test func matchesSpiceCommonReferenceFixtures() async throws {
        for fixture in try loadFixtures() {
            let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
            let expected = try #require(Data(base64Encoded: fixture.expectedBGRABase64))
            let decoded = try await SpiceQUICDecoder().decode(
                descriptor: SpiceCodecImageDescriptor(
                    width: fixture.width,
                    height: fixture.height
                ),
                payload: compressed
            )
            #expect(decoded.width == fixture.width)
            #expect(decoded.height == fixture.height)
            #expect(!decoded.topDown)
            #expect(decoded.alphaMode == (fixture.format == "rgba" ? .straight : .opaque))
            #expect(decoded.pixelsBGRA == expected, Comment(rawValue: fixture.generator))
        }
    }

    @Test func truncatedAndMutatedCorpusReturnsTypedErrors() async throws {
        let decoder = SpiceQUICDecoder()
        for fixture in try loadFixtures() {
            let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
            for length in 0..<compressed.count {
                await #expect(throws: SpiceCodecError.self) {
                    try await decoder.decode(
                        descriptor: SpiceCodecImageDescriptor(
                            width: fixture.width,
                            height: fixture.height
                        ),
                        payload: Data(compressed.prefix(length))
                    )
                }
            }
        }

        let fixture = try #require(try loadFixtures().first)
        var badMagic = try #require(Data(base64Encoded: fixture.compressedBase64))
        badMagic[0] ^= 0xff
        await #expect(throws: SpiceCodecError.self) {
            try await decoder.decode(
                descriptor: SpiceCodecImageDescriptor(
                    width: fixture.width,
                    height: fixture.height
                ),
                payload: badMagic
            )
        }
    }

    @Test func validatesLimitsAndDescriptorDimensionsBeforeOutput() async throws {
        let fixture = try #require(try loadFixtures().first)
        let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
        await #expect(throws: SpiceCodecError.dimensionMismatch(
            expectedWidth: fixture.width + 1,
            expectedHeight: fixture.height,
            actualWidth: fixture.width,
            actualHeight: fixture.height
        )) {
            try await SpiceQUICDecoder().decode(
                descriptor: SpiceCodecImageDescriptor(
                    width: fixture.width + 1,
                    height: fixture.height
                ),
                payload: compressed
            )
        }
        await #expect(throws: SpiceCodecError.decodedImageTooLarge(
            actual: fixture.width * fixture.height * 4,
            maximum: 16
        )) {
            try await SpiceQUICDecoder(limits: SpiceQUICDecodeLimits(
                maximumDecodedBytes: 16
            )).decode(
                descriptor: SpiceCodecImageDescriptor(
                    width: fixture.width,
                    height: fixture.height
                ),
                payload: compressed
            )
        }
    }

    private func loadFixtures() throws -> [QUICFixture] {
        let urls = try #require(Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: nil
        ))
        return try urls.filter { $0.lastPathComponent.hasPrefix("quic-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(QUICFixture.self, from: Data(contentsOf: $0)) }
    }
}

private struct QUICFixture: Decodable {
    let generator: String
    let format: String
    let width: Int
    let height: Int
    let compressedBase64: String
    let expectedBGRABase64: String
}
