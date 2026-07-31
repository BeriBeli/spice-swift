import Foundation
import Testing
@testable import SpiceCodecs

@Suite("SPICE ZLIB GLZ inflator")
struct ZlibInflatorTests {
    @Test func inflatesExactReferenceFixture() async throws {
        let fixture = try loadFixture()
        let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
        let expected = try #require(Data(base64Encoded: fixture.expectedGLZBase64))
        let inflated = try await SpiceZlibInflator().inflate(
            payload: compressed,
            exactOutputByteCount: expected.count
        )
        #expect(inflated == expected, Comment(rawValue: fixture.generator))
    }

    @Test func rejectsTruncationTrailingInputAndWrongDeclaredSize() async throws {
        let fixture = try loadFixture()
        let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
        let expected = try #require(Data(base64Encoded: fixture.expectedGLZBase64))
        for length in 0..<compressed.count {
            await #expect(throws: SpiceCodecError.self) {
                try await SpiceZlibInflator().inflate(
                    payload: Data(compressed.prefix(length)),
                    exactOutputByteCount: expected.count
                )
            }
        }

        var trailing = compressed
        trailing.append(0)
        await #expect(throws: SpiceCodecError.self) {
            try await SpiceZlibInflator().inflate(
                payload: trailing,
                exactOutputByteCount: expected.count
            )
        }
        for wrongSize in [expected.count - 1, expected.count + 1] {
            await #expect(throws: SpiceCodecError.self) {
                try await SpiceZlibInflator().inflate(
                    payload: compressed,
                    exactOutputByteCount: wrongSize
                )
            }
        }
    }

    @Test func rejectsDeclaredExpansionBeyondLimitBeforeAllocation() async throws {
        let fixture = try loadFixture()
        let compressed = try #require(Data(base64Encoded: fixture.compressedBase64))
        let inflator = SpiceZlibInflator(limits: .init(maximumDecodedBytes: 32))
        await #expect(throws: SpiceCodecError.decodedImageTooLarge(actual: 40, maximum: 32)) {
            try await inflator.inflate(payload: compressed, exactOutputByteCount: 40)
        }
    }

    private func loadFixture() throws -> ZlibGLZFixture {
        let url = try #require(Bundle.module.url(
            forResource: "zlib-glz-rgb32",
            withExtension: "json"
        ))
        return try JSONDecoder().decode(
            ZlibGLZFixture.self,
            from: Data(contentsOf: url)
        )
    }
}

private struct ZlibGLZFixture: Decodable {
    let generator: String
    let compressedBase64: String
    let expectedGLZBase64: String
}
