import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import SpiceCodecs
@testable import SpiceVideoToolbox

@Suite("VideoToolbox decoder boundary")
struct VideoToolboxDecoderTests {
    enum SampleBuilderOutcome: String, Sendable {
        case success
        case blockCreationFailure
        case sampleCreationFailure
    }

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

    @Test(arguments: [
        SampleBuilderOutcome.success,
        .blockCreationFailure,
        .sampleCreationFailure,
    ])
    func coreMediaSampleOwnerIsReleasedExactlyOnce(
        _ outcome: SampleBuilderOutcome
    ) throws {
        let injectedStatus = OSStatus(-12_345)
        let builder = SpiceVideoToolboxSampleBufferBuilder(
            blockBufferCreationFailureForAttempt: { attempt in
                outcome == .blockCreationFailure && attempt == 1 ? injectedStatus : nil
            },
            sampleBufferCreationFailureForAttempt: { attempt in
                outcome == .sampleCreationFailure && attempt == 1 ? injectedStatus : nil
            }
        )
        let formatDescription = try makeVideoFormatDescription()
        let sampleData = Data([0, 0, 0, 3, 0x65, 0x88, 0x84])

        switch outcome {
        case .success:
            try buildInspectAndReleaseSample(
                builder: builder,
                data: sampleData,
                formatDescription: formatDescription
            )
        case .blockCreationFailure:
            #expect(throws: SpiceCodecError.backendFailure(
                "CoreMedia block allocation status \(injectedStatus)"
            )) {
                try builder.makeSampleBuffer(
                    data: sampleData,
                    multimediaTime: 7,
                    formatDescription: formatDescription
                )
            }
        case .sampleCreationFailure:
            #expect(throws: SpiceCodecError.backendFailure(
                "CoreMedia sample creation status \(injectedStatus)"
            )) {
                try builder.makeSampleBuffer(
                    data: sampleData,
                    multimediaTime: 7,
                    formatDescription: formatDescription
                )
            }
        }

        let released = builder.diagnosticsSnapshot()
        #expect(released.coreMediaBlockCopyBytes == 0)
        #expect(released.sampleOwnerRetainCount == 1)
        #expect(released.sampleOwnerReleaseCount == 1)
        #expect(released.activeSampleOwnerCount == 0)
    }

    @Test func cancellingTaskHoldingSampleReleasesOwnerExactlyOnce() async throws {
        let builder = SpiceVideoToolboxSampleBufferBuilder()
        let formatDescription = try makeVideoFormatDescription()
        let gate = SampleCancellationGate()
        let task = Task {
            let sampleBuffer = try builder.makeSampleBuffer(
                data: Data([0, 0, 0, 3, 0x65, 0x88, 0x84]),
                multimediaTime: 11,
                formatDescription: formatDescription
            )
            await withTaskCancellationHandler {
                await gate.hold()
                withExtendedLifetime(sampleBuffer) {}
            } onCancel: {
                Task { await gate.cancel() }
            }
        }

        await gate.waitUntilStarted()
        let retained = builder.diagnosticsSnapshot()
        #expect(retained.sampleOwnerRetainCount == 1)
        #expect(retained.sampleOwnerReleaseCount == 0)
        #expect(retained.activeSampleOwnerCount == 1)

        task.cancel()
        await gate.waitUntilCancelled()
        try await task.value

        let released = builder.diagnosticsSnapshot()
        #expect(released.coreMediaBlockCopyBytes == 0)
        #expect(released.sampleOwnerRetainCount == 1)
        #expect(released.sampleOwnerReleaseCount == 1)
        #expect(released.activeSampleOwnerCount == 0)
    }

    private func buildInspectAndReleaseSample(
        builder: SpiceVideoToolboxSampleBufferBuilder,
        data: Data,
        formatDescription: CMVideoFormatDescription
    ) throws {
        let sampleBuffer = try builder.makeSampleBuffer(
            data: data,
            multimediaTime: 7,
            formatDescription: formatDescription
        )
        let retained = builder.diagnosticsSnapshot()
        #expect(retained.coreMediaBlockCopyBytes == 0)
        #expect(retained.sampleOwnerRetainCount == 1)
        #expect(retained.sampleOwnerReleaseCount == 0)
        #expect(retained.activeSampleOwnerCount == 1)

        let blockBuffer = try #require(CMSampleBufferGetDataBuffer(sampleBuffer))
        #expect(CMBlockBufferGetDataLength(blockBuffer) == data.count)
        var copied = Data(count: data.count)
        let status = copied.withUnsafeMutableBytes {
            (bytes: UnsafeMutableRawBufferPointer) in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: data.count,
                destination: bytes.baseAddress!
            )
        }
        #expect(status == kCMBlockBufferNoErr)
        #expect(copied == data)
    }

    private func makeVideoFormatDescription() throws -> CMVideoFormatDescription {
        var formatDescription: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil,
            codecType: kCMVideoCodecType_H264,
            width: 16,
            height: 16,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        #expect(status == noErr)
        return try #require(formatDescription)
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

private actor SampleCancellationGate {
    private var started = false
    private var cancelled = false
    private var release: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func hold() async {
        started = true
        for waiter in startWaiters {
            waiter.resume()
        }
        startWaiters.removeAll()
        guard !cancelled else {
            return
        }
        await withCheckedContinuation { continuation in
            if cancelled {
                continuation.resume()
            } else {
                release = continuation
            }
        }
    }

    func waitUntilStarted() async {
        guard !started else {
            return
        }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !cancelled else {
            return
        }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    func cancel() {
        cancelled = true
        release?.resume()
        release = nil
        for waiter in cancellationWaiters {
            waiter.resume()
        }
        cancellationWaiters.removeAll()
    }
}
