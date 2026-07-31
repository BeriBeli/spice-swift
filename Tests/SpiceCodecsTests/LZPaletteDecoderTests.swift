import Foundation
import Testing
@testable import SpiceCodecs

@Suite("SPICE LZ palette decoder")
struct LZPaletteDecoderTests {
    @Test func matchesSpiceCommonReferenceFixtures() async throws {
        for fixture in try loadFixtures() {
            let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
            let expected = try #require(Data(base64Encoded: fixture.expectedXRGBBase64))
            let decoded = try await SpiceLZDecoder().decodePalette(
                descriptor: SpiceCodecImageDescriptor(
                    width: fixture.width,
                    height: fixture.height
                ),
                payload: compressed,
                palette: SpiceLZPalette(
                    uniqueID: fixture.paletteID,
                    entriesARGB: fixture.paletteARGB
                )
            )
            #expect(decoded.width == fixture.width)
            #expect(decoded.height == fixture.height)
            #expect(decoded.topDown)
            #expect(decoded.alphaMode == .opaque)
            #expect(decoded.pixelsBGRA == expected, Comment(rawValue: fixture.format))
        }
    }

    @Test func rejectsEveryTruncationAndInvalidPaletteIndex() async throws {
        let decoder = SpiceLZDecoder()
        for fixture in try loadFixtures() {
            let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
            for length in 0..<compressed.count {
                await #expect(throws: SpiceCodecError.self) {
                    try await decoder.decodePalette(
                        descriptor: SpiceCodecImageDescriptor(
                            width: fixture.width,
                            height: fixture.height
                        ),
                        payload: Data(compressed.prefix(length)),
                        palette: SpiceLZPalette(
                            uniqueID: fixture.paletteID,
                            entriesARGB: fixture.paletteARGB
                        )
                    )
                }
            }
        }

        let plt8 = try #require(try loadFixtures().first { $0.format == "plt8" })
        let compressed = try #require(Data(base64Encoded: plt8.compressedBase64))
        await #expect(throws: SpiceCodecError.malformedPayload("palette index out of range")) {
            try await decoder.decodePalette(
                descriptor: SpiceCodecImageDescriptor(width: plt8.width, height: plt8.height),
                payload: compressed,
                palette: SpiceLZPalette(uniqueID: 1, entriesARGB: [0])
            )
        }
    }

    private func loadFixtures() throws -> [LZPaletteFixture] {
        let urls = try #require(Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: nil
        ))
        return try urls.filter { $0.lastPathComponent.hasPrefix("lzplt-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(LZPaletteFixture.self, from: Data(contentsOf: $0)) }
    }
}

private struct LZPaletteFixture: Decodable {
    let generator: String
    let format: String
    let width: Int
    let height: Int
    let paletteID: UInt64
    let paletteARGB: [UInt32]
    let compressedBase64: String
    let expectedXRGBBase64: String
}
