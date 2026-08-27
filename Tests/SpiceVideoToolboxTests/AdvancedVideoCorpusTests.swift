import CoreVideo
import Foundation
import IOSurface
import Testing
import VideoToolbox
@testable import SpiceCodecs
@testable import SpiceMetalCompositor
@testable import SpiceVideoToolbox

@Suite("VideoToolbox advanced-video corpus", .serialized)
struct AdvancedVideoCorpusTests {
    @Test func decodesIndependentH264AndH265Goldens() async throws {
        for fixture in try loadFixtures() {
            let encoded = try #require(Data(base64Encoded: fixture.annexBBase64))
            let expected = try #require(Data(base64Encoded: fixture.expectedBGRABase64))
            let parserResult = try SpiceAnnexBParser().parseWithDiagnostics(
                codec: fixture.codec.decoderCodec,
                payload: encoded
            )
            let decoder = try SpiceVideoToolboxDecoder(
                codec: fixture.codec.decoderCodec,
                width: fixture.width,
                height: fixture.height
            )

            let frame = try #require(try await decoder.decodeVideoFrame(
                payload: encoded,
                multimediaTime: 1
            ))
            #expect(frame is SpiceVideoToolboxFrame)
            let nativeDiagnostics = await decoder.diagnosticsSnapshot()
            #expect(nativeDiagnostics.sessionCreationCount == 1)
            #expect(nativeDiagnostics.decodedFrameCount == 1)
            #expect(nativeDiagnostics.cpuMaterializationCount == 0)
            #expect(nativeDiagnostics.hardwareSessionCount == 1)
            #expect(nativeDiagnostics.softwareSessionCount == 0)
            #expect(nativeDiagnostics.hardwareQueryFailureCount == 0)
            let videoToolboxDiagnostics = await decoder.videoToolboxDiagnosticsSnapshot()
            #expect(videoToolboxDiagnostics.annexBScanPassCount == 1)
            #expect(videoToolboxDiagnostics.annexBInputCopyBytes == 0)
            #expect(videoToolboxDiagnostics.annexBNALPayloadMaterializations == 0)
            #expect(videoToolboxDiagnostics.annexBNALPayloadCopyBytes == 0)
            #expect(videoToolboxDiagnostics.avccSampleAllocations == 1)
            #expect(videoToolboxDiagnostics.avccSampleBytes == UInt64(
                parserResult.diagnostics.avccSampleBytes
            ))
            #expect(videoToolboxDiagnostics.samplePayloadCopyBytes == UInt64(
                parserResult.diagnostics.samplePayloadCopyBytes
            ))
            #expect(videoToolboxDiagnostics.parameterSetMaterializationCount == UInt64(
                parserResult.accessUnit.parameterSets.count
            ))
            #expect(videoToolboxDiagnostics.parameterSetMaterializationBytes == UInt64(
                parserResult.accessUnit.parameterSets.reduce(0) { $0 + $1.bytes.count }
            ))
            #expect(videoToolboxDiagnostics.coreMediaBlockCopyBytes == 0)
            #expect(videoToolboxDiagnostics.sampleOwnerRetainCount == 1)
            #expect(videoToolboxDiagnostics.sampleOwnerReleaseCount == 1)
            #expect(videoToolboxDiagnostics.activeSampleOwnerCount == 0)

            if let compositor = try makeCompositorIfSupported() {
                let destination = try makeBGRAIOSurface(
                    width: fixture.width,
                    height: fixture.height
                )
                do {
                    try await compositor.composite(
                        frame: frame,
                        orientation: .topDown,
                        into: destination,
                        destinationRect: .init(
                            x: 0,
                            y: 0,
                            width: fixture.width,
                            height: fixture.height
                        ),
                        clip: .init(
                            x: 0,
                            y: 0,
                            width: fixture.width,
                            height: fixture.height
                        )
                    )
                    try expectBGRA(
                        copyPixels(
                            from: destination,
                            width: fixture.width,
                            height: fixture.height
                        ),
                        matches: expected,
                        maximumColorDelta: 4
                    )
                } catch let error as SpiceMetalCompositorError {
                    if case .unknown = frame.colorMatrix {
                        // Metadata-free corpus frames must stay on CPU fallback.
                    } else {
                        Issue.record("known matrix unexpectedly rejected by Metal")
                    }
                    #expect(error == .unsupportedColorMatrix)
                    #expect(error.fallback == .frame)
                }
            }

            let decoded = try frame.copyBGRA()
            #expect(try frame.copyBGRA() == decoded)
            let materializedDiagnostics = await decoder.diagnosticsSnapshot()
            #expect(materializedDiagnostics.cpuMaterializationCount == 1)
            await decoder.close()
            let closedDiagnostics = await decoder.videoToolboxDiagnosticsSnapshot()
            #expect(closedDiagnostics.sampleOwnerRetainCount == 1)
            #expect(closedDiagnostics.sampleOwnerReleaseCount == 1)
            #expect(closedDiagnostics.activeSampleOwnerCount == 0)

            #expect(decoded.width == fixture.width, Comment(rawValue: fixture.generator))
            #expect(decoded.height == fixture.height, Comment(rawValue: fixture.generator))
            #expect(decoded.bytesPerRow == fixture.width * 4)
            try expectBGRA(decoded.pixelsBGRA, matches: expected, maximumColorDelta: 4)
        }
    }

    private func makeCompositorIfSupported() throws -> SpiceMetalCompositor? {
        do {
            return try SpiceMetalCompositor()
        } catch let error where error == .unsupportedDevice {
            return nil
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

    @Test func retriesTheSameParameterSetAfterSessionCreationFailure() async throws {
        let high = try loadFixture(named: "h264-high-128x128")
        let baseline = try loadFixture(named: "h264-baseline-128x128")
        let highPayload = try #require(Data(base64Encoded: high.annexBBase64))
        let baselinePayload = try #require(Data(base64Encoded: baseline.annexBBase64))
        let decoder = try SpiceVideoToolboxDecoder(
            codec: .h264,
            width: 128,
            height: 128,
            sessionCreationFailureForAttempt: { attempt in
                attempt == 2 ? OSStatus(-1) : nil
            }
        )

        _ = try #require(try await decoder.decode(
            payload: highPayload,
            multimediaTime: 10
        ))
        await #expect(throws: SpiceCodecError.self) {
            _ = try await decoder.decode(
                payload: baselinePayload,
                multimediaTime: 20
            )
        }
        let recovered = try #require(try await decoder.decode(
            payload: baselinePayload,
            multimediaTime: 30
        ))
        let diagnostics = await decoder.diagnosticsSnapshot()
        let videoToolboxDiagnostics = await decoder.videoToolboxDiagnosticsSnapshot()
        await decoder.close()

        #expect(diagnostics.sessionCreationCount == 2)
        let highAccessUnit = try SpiceAnnexBParser().parse(
            codec: .h264,
            payload: highPayload
        )
        let baselineAccessUnit = try SpiceAnnexBParser().parse(
            codec: .h264,
            payload: baselinePayload
        )
        let distinctParameterSets = highAccessUnit.parameterSets +
            baselineAccessUnit.parameterSets
        #expect(videoToolboxDiagnostics.annexBScanPassCount == 3)
        #expect(videoToolboxDiagnostics.avccSampleAllocations == 3)
        #expect(videoToolboxDiagnostics.parameterSetMaterializationCount == UInt64(
            distinctParameterSets.count
        ))
        #expect(videoToolboxDiagnostics.parameterSetMaterializationBytes == UInt64(
            distinctParameterSets.reduce(0) { $0 + $1.bytes.count }
        ))
        #expect(videoToolboxDiagnostics.coreMediaBlockCopyBytes == 0)
        #expect(videoToolboxDiagnostics.sampleOwnerRetainCount == 2)
        #expect(videoToolboxDiagnostics.sampleOwnerReleaseCount == 2)
        #expect(videoToolboxDiagnostics.activeSampleOwnerCount == 0)
        try expectBGRA(
            recovered.pixelsBGRA,
            matches: try #require(Data(base64Encoded: baseline.expectedBGRABase64)),
            maximumColorDelta: 4
        )
    }

    @Test func reportsSoftwareSessionAsTypedHardwareUnavailability() async throws {
        let fixture = try loadFixture(named: "h264-baseline-128x128")
        let payload = try #require(Data(base64Encoded: fixture.annexBBase64))
        let decoder = try SpiceVideoToolboxDecoder(
            codec: .h264,
            width: fixture.width,
            height: fixture.height,
            hardwareStateForSession: { _ in .software }
        )

        do {
            _ = try await decoder.decodeVideoFrame(payload: payload, multimediaTime: 1)
            Issue.record("software VideoToolbox session was accepted")
        } catch let error {
            #expect(error == .videoHardwareUnavailable(codec: .h264, status: nil))
        }
        let diagnostics = await decoder.diagnosticsSnapshot()
        #expect(diagnostics.sessionCreationCount == 1)
        #expect(diagnostics.softwareSessionCount == 1)
        #expect(diagnostics.decodedFrameCount == 0)
        await decoder.close()
    }

    @Test func mapsUnsupportedFormatBeforeBitstreamFailures() async throws {
        let fixture = try loadFixture(named: "h264-baseline-128x128")
        let payload = try #require(Data(base64Encoded: fixture.annexBBase64))
        let decoder = try SpiceVideoToolboxDecoder(
            codec: .h264,
            width: fixture.width,
            height: fixture.height,
            sessionCreationFailureForAttempt: { attempt in
                attempt == 1 ? kVTVideoDecoderUnsupportedDataFormatErr : nil
            }
        )

        do {
            _ = try await decoder.decodeVideoFrame(payload: payload, multimediaTime: 1)
            Issue.record("unsupported hardware format was accepted")
        } catch let error {
            #expect(error == .unsupportedVideoFormat(
                codec: .h264,
                status: kVTVideoDecoderUnsupportedDataFormatErr
            ))
        }
        await decoder.close()
    }

    @Test func mapsRejectedParameterSetProfileToUnsupportedFormat() async throws {
        let fixture = try loadFixture(named: "h264-high-128x128")
        let payload = try #require(Data(base64Encoded: fixture.annexBBase64))
        let decoder = try SpiceVideoToolboxDecoder(
            codec: .h264,
            width: fixture.width,
            height: fixture.height,
            formatDescriptionFailureForAttempt: { attempt in
                attempt == 1 ? kCMFormatDescriptionError_ValueNotAvailable : nil
            }
        )

        do {
            _ = try await decoder.decodeVideoFrame(payload: payload, multimediaTime: 1)
            Issue.record("unsupported parameter-set profile was accepted")
        } catch let error {
            #expect(error == .unsupportedVideoFormat(
                codec: .h264,
                status: kCMFormatDescriptionError_ValueNotAvailable
            ))
        }
        await decoder.close()
    }

    @Test func synchronousSubmissionFailureReleasesSampleOwnerBeforeClose() async throws {
        let fixture = try loadFixture(named: "h264-baseline-128x128")
        let payload = try #require(Data(base64Encoded: fixture.annexBBase64))
        let injectedStatus = OSStatus(-12_345)
        let decoder = try SpiceVideoToolboxDecoder(
            codec: .h264,
            width: fixture.width,
            height: fixture.height,
            decodeSubmissionFailureForAttempt: { attempt in
                attempt == 1 ? injectedStatus : nil
            }
        )

        await #expect(throws: SpiceCodecError.backendFailure(
            "VideoToolbox submission status \(injectedStatus)"
        )) {
            _ = try await decoder.decodeVideoFrame(payload: payload, multimediaTime: 1)
        }
        let failed = await decoder.videoToolboxDiagnosticsSnapshot()
        #expect(failed.annexBScanPassCount == 1)
        #expect(failed.coreMediaBlockCopyBytes == 0)
        #expect(failed.sampleOwnerRetainCount == 1)
        #expect(failed.sampleOwnerReleaseCount == 1)
        #expect(failed.activeSampleOwnerCount == 0)

        await decoder.close()
        let closed = await decoder.videoToolboxDiagnosticsSnapshot()
        #expect(closed.sampleOwnerRetainCount == 1)
        #expect(closed.sampleOwnerReleaseCount == 1)
        #expect(closed.activeSampleOwnerCount == 0)
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

    private func makeBGRAIOSurface(width: Int, height: Int) throws -> IOSurfaceRef {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ]
        return try #require(IOSurfaceCreate(properties as CFDictionary))
    }

    private func copyPixels(
        from surface: IOSurfaceRef,
        width: Int,
        height: Int
    ) throws -> Data {
        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, .readOnly, &seed) == 0 else {
            throw CorpusError.ioSurfaceLock
        }
        defer { IOSurfaceUnlock(surface, .readOnly, &seed) }
        let rowBytes = width * 4
        let sourceStride = IOSurfaceGetBytesPerRow(surface)
        let source = IOSurfaceGetBaseAddress(surface)
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else {
                return
            }
            for row in 0..<height {
                destination.advanced(by: row * rowBytes).copyMemory(
                    from: source.advanced(by: row * sourceStride),
                    byteCount: rowBytes
                )
            }
        }
        return pixels
    }
}

private enum CorpusError: Error {
    case ioSurfaceLock
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
