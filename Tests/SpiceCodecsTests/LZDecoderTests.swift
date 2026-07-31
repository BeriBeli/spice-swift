import Foundation
import Testing
@testable import SpiceCodecs

@Suite("SPICE LZ decoder")
struct LZDecoderTests {
    @Test func matchesSpiceCommonReferenceFixtures() async throws {
        for fixture in try loadFixtures() {
            let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
            let expected = try #require(Data(base64Encoded: fixture.expectedXRGBBase64))
            let decoded = try await SpiceLZDecoder().decode(
                descriptor: SpiceCodecImageDescriptor(
                    width: fixture.width,
                    height: fixture.height
                ),
                payload: compressed
            )
            #expect(decoded.width == fixture.width)
            #expect(decoded.height == fixture.height)
            #expect(decoded.topDown)
            #expect(decoded.alphaMode == (fixture.hasAlpha ? .straight : .opaque))
            #expect(decoded.pixelsBGRA == expected, Comment(rawValue: fixture.generator))
        }
    }

    @Test func rejectsTruncationBadReferencesAndTrailingBytes() async throws {
        let decoder = SpiceLZDecoder()
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
        let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
        var invalidReference = compressed
        invalidReference.replaceSubrange(28..<31, with: Data([0xe0, 0, 0]))
        await #expect(throws: SpiceCodecError.self) {
            try await decoder.decode(
                descriptor: SpiceCodecImageDescriptor(width: 6, height: 3),
                payload: invalidReference
            )
        }

        var trailing = compressed
        trailing.append(0)
        await #expect(throws: SpiceCodecError.malformedPayload("trailing compressed bytes")) {
            try await decoder.decode(
                descriptor: SpiceCodecImageDescriptor(width: 6, height: 3),
                payload: trailing
            )
        }
    }

    private func loadFixtures() throws -> [LZFixture] {
        let urls = try #require(Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: nil
        ))
        return try urls.filter { $0.lastPathComponent.hasPrefix("lz-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(LZFixture.self, from: Data(contentsOf: $0)) }
    }
}

private struct LZFixture: Decodable {
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
