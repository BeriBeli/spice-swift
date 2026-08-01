import CoreVideo
import Foundation
import Testing
@testable import SpiceCodecs
@testable import SpiceVideoToolbox

@Suite("VideoToolbox decoder boundary")
struct VideoToolboxDecoderTests {
    @Test func nativeNV12FrameReportsMetadataAndMaterializesBGRA() throws {
        let pixelBuffer = try makeNV12PixelBuffer(
            width: 2,
            height: 2,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2
        )
        let frame = try SpiceVideoToolboxFrame(
            pixelBuffer: pixelBuffer,
            expectedWidth: 2,
            expectedHeight: 2,
            maximumDecodedBytes: 16
        )

        #expect(frame.width == 2)
        #expect(frame.height == 2)
        #expect(frame.pixelFormat == .nv12)
        #expect(frame.colorMatrix == .bt709)
        #expect(frame.colorRange == .video)
        #expect(try frame.copyBGRA().pixelsBGRA == Data([
            0, 0, 0, 255, 0, 0, 0, 255,
            0, 0, 0, 255, 0, 0, 0, 255,
        ]))
    }

    @Test func oddNV12AndUnknownMatrixRemainCPUMaterializable() throws {
        let pixelBuffer = try makeNV12PixelBuffer(
            width: 3,
            height: 3,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020
        )
        let frame = try SpiceVideoToolboxFrame(
            pixelBuffer: pixelBuffer,
            expectedWidth: 3,
            expectedHeight: 3,
            maximumDecodedBytes: 36
        )

        #expect(frame.pixelFormat == .nv12)
        #expect(frame.colorRange == .full)
        if case .unknown = frame.colorMatrix {
            // An unsupported matrix stays explicit so Metal can reject it.
        } else {
            Issue.record("BT.2020 must not be silently relabeled as BT.601 or BT.709")
        }
        #expect(try frame.copyBGRA().pixelsBGRA.count == 36)
    }

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

    private func makeNV12PixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        matrix: CFString
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            nil,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        CVBufferSetAttachment(
            buffer,
            kCVImageBufferYCbCrMatrixKey,
            matrix,
            .shouldPropagate
        )

        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<height {
            for column in 0..<width {
                luma[row * lumaStride + column] = pixelFormat ==
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0
            }
        }
        for row in 0..<((height + 1) / 2) {
            for column in 0..<((width + 1) / 2) {
                chroma[row * chromaStride + column * 2] = 128
                chroma[row * chromaStride + column * 2 + 1] = 128
            }
        }
        return buffer
    }
}
