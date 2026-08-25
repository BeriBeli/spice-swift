import Foundation
import Testing
@testable import SpiceCodecs

@Suite("JPEG decoder")
struct JPEGDecoderTests {
    @Test func turboJPEGIsBitExactWithLibjpegTurboGolden() async throws {
        for fixture in try loadFixtures() {
            let jpeg = try #require(Data(base64Encoded: fixture.jpegBase64))
            let expectedRGB = try #require(Data(base64Encoded: fixture.expectedRGBBase64))

            let decoded = try await SpiceJPEGDecoder().decode(
                descriptor: SpiceCodecImageDescriptor(
                    width: fixture.width,
                    height: fixture.height
                ),
                payload: jpeg
            )

            #expect(decoded.width == fixture.width, Comment(rawValue: fixture.generator))
            #expect(decoded.height == fixture.height, Comment(rawValue: fixture.generator))
            #expect(decoded.bytesPerRow == fixture.width * 4)
            #expect(
                decoded.pixelsBGRA == bgra(fromRGB: expectedRGB),
                Comment(rawValue: fixture.generator)
            )
        }
    }

    @Test func validatesBoundsAndDescriptorBeforeDecode() async throws {
        let fixture = try loadFixture()
        let jpeg = try #require(Data(base64Encoded: fixture.jpegBase64))
        let decoder = SpiceJPEGDecoder(limits: SpiceJPEGDecodeLimits(
            maximumDimension: 8,
            maximumEncodedBytes: jpeg.count - 1,
            maximumDecodedBytes: 8 * 8 * 4
        ))

        await #expect(throws: SpiceCodecError.encodedImageTooLarge(
            actual: jpeg.count,
            maximum: jpeg.count - 1
        )) {
            try await decoder.decode(
                descriptor: SpiceCodecImageDescriptor(width: 8, height: 8),
                payload: jpeg
            )
        }
        await #expect(throws: SpiceCodecError.dimensionMismatch(
            expectedWidth: 7,
            expectedHeight: 8,
            actualWidth: 8,
            actualHeight: 8
        )) {
            try await SpiceJPEGDecoder().decode(
                descriptor: SpiceCodecImageDescriptor(width: 7, height: 8),
                payload: jpeg
            )
        }
    }

    @Test func truncatedCorpusNeverEscapesValidatedResultOrTypedError() async throws {
        let fixture = try loadFixture()
        let jpeg = try #require(Data(base64Encoded: fixture.jpegBase64))
        let decoder = SpiceJPEGDecoder()
        for length in stride(from: 0, to: jpeg.count, by: 17) {
            do {
                let decoded = try await decoder.decode(
                    descriptor: SpiceCodecImageDescriptor(width: 8, height: 8),
                    payload: Data(jpeg.prefix(length))
                )
                #expect(decoded.pixelsBGRA.count == 8 * 8 * 4)
            } catch {
                // Every rejected truncation remains inside the typed codec boundary.
            }
        }
    }

    @Test func profileBearingFixtureContainsICCMarker() throws {
        let fixture = try loadFixture(named: "jpeg-icc-6x5")
        let jpeg = try #require(Data(base64Encoded: fixture.jpegBase64))

        #expect(jpeg.range(of: Data("ICC_PROFILE".utf8)) != nil)
    }

    @Test func missingEOIWarningIsRejectedAtTypedCodecBoundary() async throws {
        let fixture = try loadFixture(named: "jpeg-icc-6x5")
        var jpeg = try #require(Data(base64Encoded: fixture.jpegBase64))
        #expect(jpeg.suffix(2) == Data([0xFF, 0xD9]))
        jpeg.removeLast(2)

        do {
            _ = try await SpiceJPEGDecoder().decode(
                descriptor: SpiceCodecImageDescriptor(
                    width: fixture.width,
                    height: fixture.height
                ),
                payload: jpeg
            )
            Issue.record("missing JPEG EOI was unexpectedly accepted")
        } catch let error {
            guard case let .backendFailure(reason) = error else {
                Issue.record("unexpected codec error: \(error)")
                return
            }
            #expect(reason.contains("Premature end of JPEG file"))
        }
    }

    @Test func mjpegStreamKeepsOneHandleAndReusesThreeIOSurfaces() async throws {
        let fixture = try loadFixture(named: "jpeg-420-9x7")
        let jpeg = try #require(Data(base64Encoded: fixture.jpegBase64))
        let limiter = SpiceMJPEGDecodeLimiter(maximumConcurrent: 2)
        let decoder = try SpiceMJPEGStreamDecoder(limiter: limiter)
        let descriptor = SpiceCodecImageDescriptor(
            width: fixture.width,
            height: fixture.height
        )

        var leasedFrames: [any SpiceDecodedVideoFrame] = []
        for _ in 0..<3 {
            let frame = try await decoder.decodeVideoFrame(
                descriptor: descriptor,
                payload: jpeg
            )
            #expect(frame is SpiceMJPEGFrame)
            leasedFrames.append(frame)
        }

        // None of the three slots can be stolen while a renderer retains it.
        // The fourth frame takes the bounded Data fallback immediately.
        let fallback = try await decoder.decodeVideoFrame(
            descriptor: descriptor,
            payload: jpeg
        )
        #expect(fallback is SpiceDecodedImage)
        var diagnostics = await decoder.diagnosticsSnapshot()
        #expect(diagnostics.handleCreationCount == 1)
        #expect(diagnostics.ioSurfaceAllocationCount == 3)
        #expect(diagnostics.ioSurfaceFrameCount == 3)
        #expect(diagnostics.dataFallbackCount == 1)
        #expect(diagnostics.peakBuffersInUse == 3)

        leasedFrames.removeAll()
        do {
            let reused = try await decoder.decodeVideoFrame(
                descriptor: descriptor,
                payload: jpeg
            )
            #expect(reused is SpiceMJPEGFrame)
        }
        for _ in 0..<100 {
            let warmedFrame = try await decoder.decodeVideoFrame(
                descriptor: descriptor,
                payload: jpeg
            )
            #expect(warmedFrame is SpiceMJPEGFrame)
        }
        diagnostics = await decoder.diagnosticsSnapshot()
        #expect(diagnostics.handleCreationCount == 1)
        #expect(diagnostics.ioSurfaceAllocationCount == 3)
        #expect(diagnostics.decodedFrameCount == 105)
        #expect(diagnostics.ioSurfaceFrameCount == 104)
        #expect(diagnostics.dataFallbackCount == 1)
        await decoder.close()
    }

    @Test func mjpegStreamPreservesExactJPEGColor() async throws {
        let fixture = try loadFixture(named: "jpeg-420-9x7")
        let jpeg = try #require(Data(base64Encoded: fixture.jpegBase64))
        let expectedRGB = try #require(Data(base64Encoded: fixture.expectedRGBBase64))
        let expectedBGRA = bgra(fromRGB: expectedRGB)
        let decoder = try SpiceMJPEGStreamDecoder(
            limiter: SpiceMJPEGDecodeLimiter(),
            poolCapacity: 0
        )

        let frame = try await decoder.decodeVideoFrame(
            descriptor: SpiceCodecImageDescriptor(
                width: fixture.width,
                height: fixture.height
            ),
            payload: jpeg
        )
        let actual = try frame.copyBGRA().pixelsBGRA
        #expect(actual == expectedBGRA)
        await decoder.close()
    }

    @Test func mjpegSessionLimiterCapsConcurrentStreamDecodesAtTwo() async throws {
        let fixture = try loadFixture(named: "jpeg-420-9x7")
        let jpeg = try #require(Data(base64Encoded: fixture.jpegBase64))
        let descriptor = SpiceCodecImageDescriptor(
            width: fixture.width,
            height: fixture.height
        )
        let limiter = SpiceMJPEGDecodeLimiter(maximumConcurrent: 2)
        let decoders = try (0..<4).map { _ in
            try SpiceMJPEGStreamDecoder(limiter: limiter)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for decoder in decoders {
                group.addTask {
                    for _ in 0..<50 {
                        _ = try await decoder.decodeVideoFrame(
                            descriptor: descriptor,
                            payload: jpeg
                        )
                    }
                }
            }
            try await group.waitForAll()
        }

        let diagnostics = await limiter.diagnosticsSnapshot()
        #expect(diagnostics.activeDecodeCount == 0)
        #expect(diagnostics.queuedDecodeCount == 0)
        #expect(diagnostics.peakDecodeCount <= 2)
        for decoder in decoders {
            await decoder.close()
        }
    }

    private func loadFixture() throws -> JPEGFixture {
        try loadFixture(named: "jpeg-8x8")
    }

    private func loadFixture(named name: String) throws -> JPEGFixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        return try JSONDecoder().decode(JPEGFixture.self, from: Data(contentsOf: url))
    }

    private func loadFixtures() throws -> [JPEGFixture] {
        let urls = try #require(Bundle.module.urls(
            forResourcesWithExtension: "json",
            subdirectory: nil
        ))
        return try urls.filter { $0.lastPathComponent.hasPrefix("jpeg-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try JSONDecoder().decode(JPEGFixture.self, from: Data(contentsOf: $0)) }
    }

    private func bgra(fromRGB rgb: Data) -> Data {
        var output = Data(capacity: rgb.count / 3 * 4)
        for offset in stride(from: 0, to: rgb.count, by: 3) {
            output.append(rgb[offset + 2])
            output.append(rgb[offset + 1])
            output.append(rgb[offset])
            output.append(255)
        }
        return output
    }
}

private struct JPEGFixture: Decodable {
    let generator: String
    let width: Int
    let height: Int
    let jpegBase64: String
    let expectedRGBBase64: String
}
