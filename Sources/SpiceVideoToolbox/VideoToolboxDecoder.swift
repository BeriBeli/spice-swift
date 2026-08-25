import CoreMedia
import CoreVideo
import Foundation
import SpiceCodecs
import VideoToolbox

package enum SpiceVideoToolboxHardwareDecoderState: Sendable, Equatable {
    case notCreated
    case hardware
    case software
    case queryFailed(OSStatus)
}

package struct SpiceVideoToolboxDiagnostics: Sendable, Equatable {
    package let sessionCreationCount: UInt64
    package let hardwareSessionCount: UInt64
    package let softwareSessionCount: UInt64
    package let hardwareQueryFailureCount: UInt64
    package let decodedFrameCount: UInt64
    package let droppedFrameCount: UInt64
    package let cpuMaterializationCount: UInt64
    package let currentHardwareDecoderState: SpiceVideoToolboxHardwareDecoderState
}

private final class VideoToolboxDiagnosticsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionCreationCount: UInt64 = 0
    private var hardwareSessionCount: UInt64 = 0
    private var softwareSessionCount: UInt64 = 0
    private var hardwareQueryFailureCount: UInt64 = 0
    private var decodedFrameCount: UInt64 = 0
    private var droppedFrameCount: UInt64 = 0
    private var cpuMaterializationCount: UInt64 = 0
    private var currentHardwareDecoderState: SpiceVideoToolboxHardwareDecoderState = .notCreated

    func recordSession(state: SpiceVideoToolboxHardwareDecoderState) {
        lock.lock()
        defer { lock.unlock() }
        sessionCreationCount &+= 1
        currentHardwareDecoderState = state
        switch state {
        case .hardware:
            hardwareSessionCount &+= 1
        case .software:
            softwareSessionCount &+= 1
        case .queryFailed:
            hardwareQueryFailureCount &+= 1
        case .notCreated:
            break
        }
    }

    func recordDecodedFrame() {
        lock.lock()
        decodedFrameCount &+= 1
        lock.unlock()
    }

    func recordDroppedFrame() {
        lock.lock()
        droppedFrameCount &+= 1
        lock.unlock()
    }

    func recordCPUMaterialization() {
        lock.lock()
        cpuMaterializationCount &+= 1
        lock.unlock()
    }

    func snapshot() -> SpiceVideoToolboxDiagnostics {
        lock.lock()
        defer { lock.unlock() }
        return SpiceVideoToolboxDiagnostics(
            sessionCreationCount: sessionCreationCount,
            hardwareSessionCount: hardwareSessionCount,
            softwareSessionCount: softwareSessionCount,
            hardwareQueryFailureCount: hardwareQueryFailureCount,
            decodedFrameCount: decodedFrameCount,
            droppedFrameCount: droppedFrameCount,
            cpuMaterializationCount: cpuMaterializationCount,
            currentHardwareDecoderState: currentHardwareDecoderState
        )
    }
}

/// VideoToolbox's immutable decoded image. The CoreVideo handle is package-only
/// and is retained until all consumers (including Metal command buffers) finish.
package final class SpiceVideoToolboxFrame: SpiceDecodedVideoFrame, @unchecked Sendable {
    package let width: Int
    package let height: Int
    package let pixelFormat: SpiceDecodedVideoPixelFormat
    package let colorMatrix: SpiceVideoColorMatrix
    package let colorRange: SpiceVideoColorRange
    package let pixelBuffer: CVPixelBuffer

    private let maximumDecodedBytes: Int
    private let diagnostics: VideoToolboxDiagnosticsCounter?
    private let materializationLock = NSLock()
    private var materializedBGRA: Result<SpiceDecodedImage, SpiceCodecError>?

    package convenience init(
        pixelBuffer: CVPixelBuffer,
        expectedWidth: Int,
        expectedHeight: Int,
        maximumDecodedBytes: Int
    ) throws(SpiceCodecError) {
        try self.init(
            pixelBuffer: pixelBuffer,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            maximumDecodedBytes: maximumDecodedBytes,
            diagnostics: nil
        )
    }

    fileprivate init(
        pixelBuffer: CVPixelBuffer,
        expectedWidth: Int,
        expectedHeight: Int,
        maximumDecodedBytes: Int,
        diagnostics: VideoToolboxDiagnosticsCounter?
    ) throws(SpiceCodecError) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width == expectedWidth, height == expectedHeight else {
            throw .dimensionMismatch(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: width,
                actualHeight: height
            )
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (decodedBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else {
            throw .integerOverflow
        }
        guard decodedBytes <= maximumDecodedBytes else {
            throw .decodedImageTooLarge(actual: decodedBytes, maximum: maximumDecodedBytes)
        }

        let cvPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        switch cvPixelFormat {
        case kCVPixelFormatType_32BGRA:
            self.pixelFormat = .bgra8
            self.colorRange = .full
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            self.pixelFormat = .nv12
            self.colorRange = .video
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            self.pixelFormat = .nv12
            self.colorRange = .full
        default:
            self.pixelFormat = .unsupported(cvPixelFormat)
            self.colorRange = .unknown
        }

        self.width = width
        self.height = height
        self.colorMatrix = Self.readColorMatrix(from: pixelBuffer)
        self.pixelBuffer = pixelBuffer
        self.maximumDecodedBytes = maximumDecodedBytes
        self.diagnostics = diagnostics
    }

    package func copyBGRA() throws(SpiceCodecError) -> SpiceDecodedImage {
        materializationLock.lock()
        defer { materializationLock.unlock() }
        if let materializedBGRA {
            return try materializedBGRA.get()
        }

        diagnostics?.recordCPUMaterialization()
        let result = SpiceVideoToolboxDecoder.copyDecodedPixels(
            from: pixelBuffer,
            expectedWidth: width,
            expectedHeight: height,
            maximumDecodedBytes: maximumDecodedBytes
        )
        materializedBGRA = result
        return try result.get()
    }

    private static func readColorMatrix(from pixelBuffer: CVPixelBuffer) -> SpiceVideoColorMatrix {
        guard let attachment = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            nil
        ) else {
            return .unknown(nil)
        }
        if CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_601_4) {
            return .bt601
        }
        if CFEqual(attachment, kCVImageBufferYCbCrMatrix_ITU_R_709_2) {
            return .bt709
        }
        return .unknown((attachment as? String) ?? String(describing: attachment))
    }
}

private final class SynchronousDecodeOutput {
    let codec: SpiceAdvancedVideoCodec
    let expectedWidth: Int
    let expectedHeight: Int
    let maximumDecodedBytes: Int
    let diagnostics: VideoToolboxDiagnosticsCounter
    var result: Result<SpiceVideoToolboxFrame?, SpiceCodecError>?

    init(
        codec: SpiceAdvancedVideoCodec,
        expectedWidth: Int,
        expectedHeight: Int,
        maximumDecodedBytes: Int,
        diagnostics: VideoToolboxDiagnosticsCounter
    ) {
        self.codec = codec
        self.expectedWidth = expectedWidth
        self.expectedHeight = expectedHeight
        self.maximumDecodedBytes = maximumDecodedBytes
        self.diagnostics = diagnostics
    }
}

private let synchronousDecodeCallback: VTDecompressionOutputCallback = {
    _, sourceFrameRefCon, status, flags, imageBuffer, _, _ in
    guard let sourceFrameRefCon else {
        return
    }
    let output = Unmanaged<SynchronousDecodeOutput>
        .fromOpaque(sourceFrameRefCon)
        .takeUnretainedValue()
    if status != noErr {
        output.result = .failure(
            videoToolboxCompatibilityError(codec: output.codec, status: status)
                ?? .backendFailure("VideoToolbox decode status \(status)")
        )
    } else if flags.contains(.frameDropped) || imageBuffer == nil {
        output.diagnostics.recordDroppedFrame()
        output.result = .success(nil)
    } else {
        do {
            let frame = try SpiceVideoToolboxFrame(
                pixelBuffer: imageBuffer!,
                expectedWidth: output.expectedWidth,
                expectedHeight: output.expectedHeight,
                maximumDecodedBytes: output.maximumDecodedBytes,
                diagnostics: output.diagnostics
            )
            output.diagnostics.recordDecodedFrame()
            output.result = .success(frame)
        } catch let error as SpiceCodecError {
            output.result = .failure(error)
        } catch {
            output.result = .failure(.backendFailure(String(describing: error)))
        }
    }
}

package struct SpiceVideoToolboxDecoderFactory: SpiceAdvancedVideoDecoderFactory {
    private let limits: SpiceAdvancedVideoDecodeLimits

    package init(limits: SpiceAdvancedVideoDecodeLimits = .init()) {
        self.limits = limits
    }

    package func makeDecoder(
        codec: SpiceAdvancedVideoCodec,
        width: Int,
        height: Int
    ) throws(SpiceCodecError) -> any SpiceAdvancedVideoDecoder {
        try SpiceVideoToolboxDecoder(
            codec: codec,
            width: width,
            height: height,
            limits: limits
        )
    }
}

package actor SpiceVideoToolboxDecoder: SpiceAdvancedVideoDecoder {
    private let codec: SpiceAdvancedVideoCodec
    private let expectedWidth: Int
    private let expectedHeight: Int
    private let limits: SpiceAdvancedVideoDecodeLimits
    private let parser: SpiceAnnexBParser
    private var parameterSets: [UInt8: Data] = [:]
    private var formatDescription: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    private var sessionRebuildRequired = false
    private let sessionCreationFailureForAttempt: @Sendable (Int) -> OSStatus?
    private let hardwareStateForSession: @Sendable (
        VTDecompressionSession
    ) -> SpiceVideoToolboxHardwareDecoderState
    private let formatDescriptionFailureForAttempt: @Sendable (Int) -> OSStatus?
    private var sessionCreationAttempt = 0
    private var formatDescriptionCreationAttempt = 0
    private let diagnosticsCounter = VideoToolboxDiagnosticsCounter()

    package init(
        codec: SpiceAdvancedVideoCodec,
        width: Int,
        height: Int,
        limits: SpiceAdvancedVideoDecodeLimits = .init(),
        sessionCreationFailureForAttempt: @escaping @Sendable (Int) -> OSStatus? = { _ in nil },
        hardwareStateForSession: @escaping @Sendable (
            VTDecompressionSession
        ) -> SpiceVideoToolboxHardwareDecoderState = {
            SpiceVideoToolboxDecoder.hardwareDecoderState(for: $0)
        },
        formatDescriptionFailureForAttempt: @escaping @Sendable (Int) -> OSStatus? = {
            _ in nil
        }
    ) throws(SpiceCodecError) {
        guard width > 0, height > 0,
              width <= limits.maximumDimension,
              height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: width, height: height)
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (decodedBytes, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else {
            throw .integerOverflow
        }
        guard decodedBytes <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(
                actual: decodedBytes,
                maximum: limits.maximumDecodedBytes
            )
        }
        self.codec = codec
        self.expectedWidth = width
        self.expectedHeight = height
        self.limits = limits
        self.parser = SpiceAnnexBParser(limits: limits)
        self.sessionCreationFailureForAttempt = sessionCreationFailureForAttempt
        self.hardwareStateForSession = hardwareStateForSession
        self.formatDescriptionFailureForAttempt = formatDescriptionFailureForAttempt
    }

    package func decode(
        payload: Data,
        multimediaTime: UInt32
    ) async throws(SpiceCodecError) -> SpiceDecodedImage? {
        guard let frame = try await decodeVideoFrame(
            payload: payload,
            multimediaTime: multimediaTime
        ) else {
            return nil
        }
        return try frame.copyBGRA()
    }

    package func decodeVideoFrame(
        payload: Data,
        multimediaTime: UInt32
    ) async throws(SpiceCodecError) -> (any SpiceDecodedVideoFrame)? {
        let accessUnit = try parser.parse(codec: codec, payload: payload)
        var changed = false
        for parameterSet in accessUnit.parameterSets {
            if parameterSets[parameterSet.type] != parameterSet.bytes {
                parameterSets[parameterSet.type] = parameterSet.bytes
                changed = true
            }
        }
        if changed {
            sessionRebuildRequired = true
        }
        if sessionRebuildRequired || formatDescription == nil {
            try rebuildSessionIfReady()
        }
        guard accessUnit.containsPicture else {
            return nil
        }
        guard let formatDescription, let session else {
            throw .malformedPayload("picture arrived before complete codec parameter sets")
        }
        guard !accessUnit.sampleData.isEmpty else {
            throw .malformedPayload("picture access unit produced an empty sample")
        }

        let sampleBuffer = try makeSampleBuffer(
            data: accessUnit.sampleData,
            multimediaTime: multimediaTime,
            formatDescription: formatDescription
        )
        let output = SynchronousDecodeOutput(
            codec: codec,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            maximumDecodedBytes: limits.maximumDecodedBytes,
            diagnostics: diagnosticsCounter
        )
        var infoFlags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: Unmanaged.passUnretained(output).toOpaque(),
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            throw videoToolboxCompatibilityError(codec: codec, status: status)
                ?? .backendFailure("VideoToolbox submission status \(status)")
        }
        guard let result = output.result else {
            throw .backendFailure("VideoToolbox synchronous decode produced no callback")
        }
        return try result.get()
    }

    package func diagnosticsSnapshot() async -> SpiceAdvancedVideoDecoderDiagnostics {
        let diagnostics = diagnosticsCounter.snapshot()
        return SpiceAdvancedVideoDecoderDiagnostics(
            sessionCreationCount: diagnostics.sessionCreationCount,
            hardwareSessionCount: diagnostics.hardwareSessionCount,
            softwareSessionCount: diagnostics.softwareSessionCount,
            hardwareQueryFailureCount: diagnostics.hardwareQueryFailureCount,
            decodedFrameCount: diagnostics.decodedFrameCount,
            droppedFrameCount: diagnostics.droppedFrameCount,
            cpuMaterializationCount: diagnostics.cpuMaterializationCount
        )
    }

    package func videoToolboxDiagnosticsSnapshot() -> SpiceVideoToolboxDiagnostics {
        diagnosticsCounter.snapshot()
    }

    package func close() async {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        sessionRebuildRequired = false
        parameterSets.removeAll(keepingCapacity: false)
    }

    private func rebuildSessionIfReady() throws(SpiceCodecError) {
        let orderedTypes: [UInt8]
        switch codec {
        case .h264:
            guard parameterSets[7] != nil, parameterSets[8] != nil else {
                return
            }
            orderedTypes = [7, 8, 13]
        case .h265:
            guard parameterSets[32] != nil,
                  parameterSets[33] != nil,
                  parameterSets[34] != nil
            else {
                return
            }
            orderedTypes = [32, 33, 34]
        }
        let sets = orderedTypes.compactMap { parameterSets[$0] }.map { $0 as NSData }
        let pointers = sets.map { $0.bytes.assumingMemoryBound(to: UInt8.self) }
        let sizes = sets.map(\.length)
        var description: CMFormatDescription?
        formatDescriptionCreationAttempt &+= 1
        let status: OSStatus
        if let injectedStatus = formatDescriptionFailureForAttempt(
            formatDescriptionCreationAttempt
        ) {
            status = injectedStatus
        } else {
            switch codec {
            case .h264:
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            case .h265:
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil,
                    parameterSetCount: pointers.count,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            if status == noErr {
                throw .backendFailure(
                    "CoreMedia returned no format description without an error"
                )
            }
            if status == kCMFormatDescriptionError_AllocationFailed {
                throw .backendFailure("CoreMedia format description status \(status)")
            }
            throw .unsupportedVideoFormat(codec: codec, status: status)
        }

        var newSession: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: synchronousDecodeCallback,
            decompressionOutputRefCon: nil
        )
        let decoderSpecification = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ] as CFDictionary
        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey:
                NSNumber(value: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary
        sessionCreationAttempt &+= 1
        if let injectedStatus = sessionCreationFailureForAttempt(sessionCreationAttempt) {
            throw Self.sessionCreationError(
                codec: codec,
                status: injectedStatus,
                context: "injected"
            )
        }
        let sessionStatus = VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: description,
            decoderSpecification: decoderSpecification,
            imageBufferAttributes: imageBufferAttributes,
            outputCallback: &callback,
            decompressionSessionOut: &newSession
        )
        guard sessionStatus == noErr, let newSession else {
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            throw Self.sessionCreationError(
                codec: codec,
                status: sessionStatus,
                context: "subtype \(subtype), dimensions " +
                    "\(dimensions.width)x\(dimensions.height)"
            )
        }
        let realTimeStatus = VTSessionSetProperty(
            newSession,
            key: kVTDecompressionPropertyKey_RealTime,
            value: kCFBooleanTrue
        )
        guard realTimeStatus == noErr else {
            VTDecompressionSessionInvalidate(newSession)
            throw .backendFailure(
                "VideoToolbox real-time configuration status \(realTimeStatus)"
            )
        }

        let hardwareState = hardwareStateForSession(newSession)
        diagnosticsCounter.recordSession(state: hardwareState)
        switch hardwareState {
        case .hardware:
            break
        case .software:
            VTDecompressionSessionInvalidate(newSession)
            throw .videoHardwareUnavailable(codec: codec, status: nil)
        case let .queryFailed(status):
            VTDecompressionSessionInvalidate(newSession)
            throw .videoHardwareUnavailable(codec: codec, status: status)
        case .notCreated:
            VTDecompressionSessionInvalidate(newSession)
            throw .videoHardwareUnavailable(codec: codec, status: nil)
        }
        let previousSession = self.session
        self.formatDescription = description
        self.session = newSession
        sessionRebuildRequired = false
        if let previousSession {
            VTDecompressionSessionInvalidate(previousSession)
        }
    }

    private nonisolated static func hardwareDecoderState(
        for session: VTDecompressionSession
    ) -> SpiceVideoToolboxHardwareDecoderState {
        var value: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &value) { valueOut in
            VTSessionCopyProperty(
                session,
                key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
                allocator: nil,
                valueOut: valueOut
            )
        }
        guard status == noErr else {
            return .queryFailed(status)
        }
        guard let number = value as? NSNumber else {
            return .queryFailed(kVTPropertyNotSupportedErr)
        }
        return number.boolValue ? .hardware : .software
    }

    private nonisolated static func sessionCreationError(
        codec: SpiceAdvancedVideoCodec,
        status: OSStatus,
        context: String
    ) -> SpiceCodecError {
        if let compatibilityError = videoToolboxCompatibilityError(
            codec: codec,
            status: status
        ) {
            return compatibilityError
        }
        return .backendFailure(
            "VideoToolbox session creation status \(status) (\(context))"
        )
    }

    private func makeSampleBuffer(
        data: Data,
        multimediaTime: UInt32,
        formatDescription: CMVideoFormatDescription
    ) throws(SpiceCodecError) -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw .backendFailure("CoreMedia block allocation status \(status)")
        }
        status = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        guard status == kCMBlockBufferNoErr else {
            throw .backendFailure("CoreMedia block copy status \(status)")
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(multimediaTime), timescale: 1_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: nil,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw .backendFailure("CoreMedia sample creation status \(status)")
        }
        return sampleBuffer
    }

    fileprivate nonisolated static func copyDecodedPixels(
        from pixelBuffer: CVPixelBuffer,
        expectedWidth: Int,
        expectedHeight: Int,
        maximumDecodedBytes: Int
    ) -> Result<SpiceDecodedImage, SpiceCodecError> {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width == expectedWidth, height == expectedHeight else {
            return .failure(.dimensionMismatch(
                expectedWidth: expectedWidth,
                expectedHeight: expectedHeight,
                actualWidth: width,
                actualHeight: height
            ))
        }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !countOverflow else {
            return .failure(.integerOverflow)
        }
        guard byteCount <= maximumDecodedBytes else {
            return .failure(.decodedImageTooLarge(
                actual: byteCount,
                maximum: maximumDecodedBytes
            ))
        }

        switch CVPixelBufferGetPixelFormatType(pixelBuffer) {
        case kCVPixelFormatType_32BGRA:
            return copyPackedBGRA(
                from: pixelBuffer,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                byteCount: byteCount
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            return copyNV12(
                from: pixelBuffer,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                byteCount: byteCount,
                fullRange: false
            )
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return copyNV12(
                from: pixelBuffer,
                width: width,
                height: height,
                bytesPerRow: bytesPerRow,
                byteCount: byteCount,
                fullRange: true
            )
        case let format:
            return .failure(.backendFailure(
                "VideoToolbox emitted unsupported pixel format \(format)"
            ))
        }
    }

    private nonisolated static func copyPackedBGRA(
        from pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        byteCount: Int
    ) -> Result<SpiceDecodedImage, SpiceCodecError> {
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            return .failure(.backendFailure("CVPixelBuffer lock status \(lockStatus)"))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return .failure(.backendFailure("CVPixelBuffer has no base address"))
        }
        let sourceStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard sourceStride >= bytesPerRow else {
            return .failure(.backendFailure("CVPixelBuffer stride is shorter than one BGRA row"))
        }
        var pixels = Data(capacity: byteCount)
        for row in 0..<height {
            pixels.append(base.advanced(by: row * sourceStride).assumingMemoryBound(to: UInt8.self), count: bytesPerRow)
        }
        return .success(SpiceDecodedImage(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelsBGRA: pixels
        ))
    }

    private nonisolated static func copyNV12(
        from pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        byteCount: Int,
        fullRange: Bool
    ) -> Result<SpiceDecodedImage, SpiceCodecError> {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2 else {
            return .failure(.backendFailure("NV12 pixel buffer does not have two planes"))
        }
        let lockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        guard lockStatus == kCVReturnSuccess else {
            return .failure(.backendFailure("CVPixelBuffer lock status \(lockStatus)"))
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else {
            return .failure(.backendFailure("NV12 pixel buffer has a missing plane"))
        }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        guard lumaStride >= width,
              chromaStride >= ((width + 1) / 2) * 2,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) >= width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) >= height,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) >= (width + 1) / 2,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) >= (height + 1) / 2
        else {
            return .failure(.backendFailure("NV12 plane geometry is smaller than the frame"))
        }

        let matrix = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferYCbCrMatrixKey,
            nil
        )
        let useBT709 = (matrix as? String) == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)
        var pixels = Data(count: byteCount)
        pixels.withUnsafeMutableBytes { destinationBytes in
            let destination = destinationBytes.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let yValue = Int(luma[y * lumaStride + x])
                    let chromaOffset = (y / 2) * chromaStride + (x / 2) * 2
                    let cb = Int(chroma[chromaOffset]) - 128
                    let cr = Int(chroma[chromaOffset + 1]) - 128
                    let red: Int
                    let green: Int
                    let blue: Int
                    if fullRange {
                        red = yValue + ((useBT709 ? 403 : 359) * cr + 128) / 256
                        green = yValue - ((useBT709 ? 48 : 88) * cb +
                            (useBT709 ? 120 : 183) * cr + 128) / 256
                        blue = yValue + ((useBT709 ? 475 : 454) * cb + 128) / 256
                    } else {
                        let scaledY = max(0, yValue - 16) * 298
                        red = (scaledY + (useBT709 ? 459 : 409) * cr + 128) / 256
                        green = (scaledY - (useBT709 ? 55 : 100) * cb -
                            (useBT709 ? 136 : 208) * cr + 128) / 256
                        blue = (scaledY + (useBT709 ? 541 : 516) * cb + 128) / 256
                    }
                    let offset = y * bytesPerRow + x * 4
                    destination[offset] = UInt8(clamping: blue)
                    destination[offset + 1] = UInt8(clamping: green)
                    destination[offset + 2] = UInt8(clamping: red)
                    destination[offset + 3] = 255
                }
            }
        }
        return .success(SpiceDecodedImage(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelsBGRA: pixels
        ))
    }
}

private func videoToolboxCompatibilityError(
    codec: SpiceAdvancedVideoCodec,
    status: OSStatus
) -> SpiceCodecError? {
    switch status {
    case kVTVideoDecoderUnsupportedDataFormatErr,
         kVTFormatDescriptionChangeNotSupportedErr:
        .unsupportedVideoFormat(codec: codec, status: status)
    case kVTCouldNotFindVideoDecoderErr,
         kVTCouldNotCreateInstanceErr,
         kVTVideoDecoderMalfunctionErr,
         kVTVideoDecoderNotAvailableNowErr,
         kVTVideoDecoderAuthorizationErr,
         kVTVideoDecoderRemovedErr,
         kVTSessionMalfunctionErr,
         kVTVideoDecoderNeedsRosettaErr:
        .videoHardwareUnavailable(codec: codec, status: status)
    default:
        nil
    }
}
