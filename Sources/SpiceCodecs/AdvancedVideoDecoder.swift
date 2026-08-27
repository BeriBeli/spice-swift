import Foundation

package enum SpiceAdvancedVideoCodec: Sendable, Equatable {
    case h264
    case h265
}

/// The storage format retained by an advanced-video decoder.
///
/// This is package-only so platform-native storage can remain an implementation
/// detail while display code can still avoid an unnecessary BGRA materialization.
package enum SpiceDecodedVideoPixelFormat: Sendable, Equatable {
    case bgra8
    case nv12
    case unsupported(UInt32)
}

package enum SpiceVideoColorMatrix: Sendable, Equatable {
    case bt601
    case bt709
    case unknown(String?)
}

package enum SpiceVideoColorRange: Sendable, Equatable {
    case video
    case full
    case unknown
}

/// An immutable decoded video frame whose packed-BGRA representation is an
/// explicit fallback rather than the required canonical storage.
package protocol SpiceDecodedVideoFrame: Sendable {
    var width: Int { get }
    var height: Int { get }
    var pixelFormat: SpiceDecodedVideoPixelFormat { get }
    var colorMatrix: SpiceVideoColorMatrix { get }
    var colorRange: SpiceVideoColorRange { get }

    func copyBGRA() throws(SpiceCodecError) -> SpiceDecodedImage
}

extension SpiceDecodedImage: SpiceDecodedVideoFrame {
    package var pixelFormat: SpiceDecodedVideoPixelFormat { .bgra8 }
    package var colorMatrix: SpiceVideoColorMatrix { .unknown(nil) }
    package var colorRange: SpiceVideoColorRange { .full }

    package func copyBGRA() throws(SpiceCodecError) -> SpiceDecodedImage {
        self
    }
}

package struct SpiceAdvancedVideoDecodeLimits: Sendable, Equatable {
    package var maximumEncodedBytes: Int
    package var maximumNALUnits: Int
    package var maximumNALUnitBytes: Int
    package var maximumDimension: Int
    package var maximumDecodedBytes: Int

    package init(
        maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
        maximumNALUnits: Int = 1_024,
        maximumNALUnitBytes: Int = 32 * 1_024 * 1_024,
        maximumDimension: Int = 16_384,
        maximumDecodedBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumNALUnits = maximumNALUnits
        self.maximumNALUnitBytes = maximumNALUnitBytes
        self.maximumDimension = maximumDimension
        self.maximumDecodedBytes = maximumDecodedBytes
    }
}

/// Backend-neutral aggregate state. Platform decoder handles and CoreVideo
/// objects remain inside their implementation target.
package struct SpiceAdvancedVideoDecoderDiagnostics: Sendable, Equatable {
    package var sessionCreationCount: UInt64
    package var hardwareSessionCount: UInt64
    package var softwareSessionCount: UInt64
    package var hardwareQueryFailureCount: UInt64
    package var decodedFrameCount: UInt64
    package var droppedFrameCount: UInt64
    package var cpuMaterializationCount: UInt64

    package init(
        sessionCreationCount: UInt64 = 0,
        hardwareSessionCount: UInt64 = 0,
        softwareSessionCount: UInt64 = 0,
        hardwareQueryFailureCount: UInt64 = 0,
        decodedFrameCount: UInt64 = 0,
        droppedFrameCount: UInt64 = 0,
        cpuMaterializationCount: UInt64 = 0
    ) {
        self.sessionCreationCount = sessionCreationCount
        self.hardwareSessionCount = hardwareSessionCount
        self.softwareSessionCount = softwareSessionCount
        self.hardwareQueryFailureCount = hardwareQueryFailureCount
        self.decodedFrameCount = decodedFrameCount
        self.droppedFrameCount = droppedFrameCount
        self.cpuMaterializationCount = cpuMaterializationCount
    }

    package mutating func accumulate(_ other: Self) {
        sessionCreationCount &+= other.sessionCreationCount
        hardwareSessionCount &+= other.hardwareSessionCount
        softwareSessionCount &+= other.softwareSessionCount
        hardwareQueryFailureCount &+= other.hardwareQueryFailureCount
        decodedFrameCount &+= other.decodedFrameCount
        droppedFrameCount &+= other.droppedFrameCount
        cpuMaterializationCount &+= other.cpuMaterializationCount
    }
}

private final class SpiceVideoPayloadOwner: @unchecked Sendable {
    let data: Data

    init(_ data: consuming Data) {
        self.data = data
    }
}

package struct SpiceVideoNALUnit: Sendable, Equatable {
    package let type: UInt8
    package let sourceRange: Range<Int>
    private let owner: SpiceVideoPayloadOwner

    package var bytes: Data {
        if sourceRange == 0..<owner.data.count {
            return owner.data
        }
        return owner.data.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
            guard let baseAddress = source.baseAddress else {
                return Data()
            }
            return Data(
                bytes: baseAddress.advanced(by: sourceRange.lowerBound),
                count: sourceRange.count
            )
        }
    }

    package init(type: UInt8, bytes: consuming Data) {
        let count = bytes.count
        self.type = type
        sourceRange = 0..<count
        owner = SpiceVideoPayloadOwner(bytes)
    }

    fileprivate init(
        type: UInt8,
        owner: SpiceVideoPayloadOwner,
        sourceRange: Range<Int>
    ) {
        self.type = type
        self.owner = owner
        self.sourceRange = sourceRange
    }

    package func sharesOwner(with other: Self) -> Bool {
        owner === other.owner
    }

    package func contentEquals(_ data: Data) -> Bool {
        guard sourceRange.count == data.count else {
            return false
        }
        return owner.data.withUnsafeBytes { (sourceBytes: UnsafeRawBufferPointer) in
            data.withUnsafeBytes { (comparisonBytes: UnsafeRawBufferPointer) in
                let source = sourceBytes.bindMemory(to: UInt8.self)
                let comparison = comparisonBytes.bindMemory(to: UInt8.self)
                return source[sourceRange].elementsEqual(comparison)
            }
        }
    }

    package static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.type == rhs.type, lhs.sourceRange.count == rhs.sourceRange.count else {
            return false
        }
        if lhs.owner === rhs.owner, lhs.sourceRange == rhs.sourceRange {
            return true
        }
        return lhs.owner.data.withUnsafeBytes { (lhsBytes: UnsafeRawBufferPointer) in
            rhs.owner.data.withUnsafeBytes { (rhsBytes: UnsafeRawBufferPointer) in
                let lhsBuffer = lhsBytes.bindMemory(to: UInt8.self)
                let rhsBuffer = rhsBytes.bindMemory(to: UInt8.self)
                return lhsBuffer[lhs.sourceRange].elementsEqual(rhsBuffer[rhs.sourceRange])
            }
        }
    }
}

package struct SpiceVideoAccessUnit: Sendable, Equatable {
    package let codec: SpiceAdvancedVideoCodec
    package let nalUnits: [SpiceVideoNALUnit]
    package let sampleData: Data
    package let parameterSets: [SpiceVideoNALUnit]
    package let containsPicture: Bool
    package let isRandomAccess: Bool

    package init(
        codec: SpiceAdvancedVideoCodec,
        nalUnits: [SpiceVideoNALUnit],
        sampleData: consuming Data,
        parameterSets: [SpiceVideoNALUnit],
        containsPicture: Bool,
        isRandomAccess: Bool
    ) {
        self.codec = codec
        self.nalUnits = nalUnits
        self.sampleData = sampleData
        self.parameterSets = parameterSets
        self.containsPicture = containsPicture
        self.isRandomAccess = isRandomAccess
    }
}

package struct SpiceAnnexBParserDiagnostics: Sendable, Equatable {
    package let scanPassCount: Int
    package let inputCopyBytes: Int
    package let nalPayloadMaterializations: Int
    package let nalPayloadCopyBytes: Int
    package let avccSampleAllocations: Int
    package let avccSampleBytes: Int
    /// Source payload bytes written directly into the AVCC allocation.
    package let samplePayloadCopyBytes: Int
    /// Copies performed after the single AVCC sample allocation has been
    /// constructed. The direct range writer keeps this at zero.
    package let additionalSamplePayloadCopyBytes: Int
    package let nalUnitCount: Int
}

package struct SpiceAnnexBParseResult: Sendable, Equatable {
    package let accessUnit: SpiceVideoAccessUnit
    package let diagnostics: SpiceAnnexBParserDiagnostics
}

package struct SpiceAnnexBParser: Sendable {
    private struct NALDescriptor: Sendable {
        let type: UInt8
        let sourceRange: Range<Int>
        let isParameterSet: Bool
    }

    private struct ScanResult: Sendable {
        let descriptors: [NALDescriptor]
        let sampleData: Data
        let samplePayloadCopyBytes: Int
        let containsPicture: Bool
        let isRandomAccess: Bool
    }

    private let limits: SpiceAdvancedVideoDecodeLimits

    package init(limits: SpiceAdvancedVideoDecodeLimits = .init()) {
        self.limits = limits
    }

    package func parse(
        codec: SpiceAdvancedVideoCodec,
        payload: Data
    ) throws(SpiceCodecError) -> SpiceVideoAccessUnit {
        try parseWithDiagnostics(codec: codec, payload: payload).accessUnit
    }

    package func parseWithDiagnostics(
        codec: SpiceAdvancedVideoCodec,
        payload: Data
    ) throws(SpiceCodecError) -> SpiceAnnexBParseResult {
        guard !payload.isEmpty else {
            throw .emptyPayload
        }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(
                actual: payload.count,
                maximum: limits.maximumEncodedBytes
            )
        }

        let scanOutcome: Result<ScanResult, any Error> =
            payload.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                Result { try scan(codec: codec, bytes: bytes) }
            }
        let scanResult: ScanResult
        switch scanOutcome {
        case .success(let result):
            scanResult = result
        case .failure(let error):
            guard let codecError = error as? SpiceCodecError else {
                throw .malformedPayload("unexpected Annex-B parser failure")
            }
            throw codecError
        }
        let owner = SpiceVideoPayloadOwner(payload)
        var nalUnits: [SpiceVideoNALUnit] = []
        var parameterSets: [SpiceVideoNALUnit] = []
        nalUnits.reserveCapacity(scanResult.descriptors.count)
        for descriptor in scanResult.descriptors {
            let nal = SpiceVideoNALUnit(
                type: descriptor.type,
                owner: owner,
                sourceRange: descriptor.sourceRange
            )
            nalUnits.append(nal)
            if descriptor.isParameterSet {
                parameterSets.append(nal)
            }
        }

        let accessUnit = SpiceVideoAccessUnit(
            codec: codec,
            nalUnits: nalUnits,
            sampleData: scanResult.sampleData,
            parameterSets: parameterSets,
            containsPicture: scanResult.containsPicture,
            isRandomAccess: scanResult.isRandomAccess
        )
        return SpiceAnnexBParseResult(
            accessUnit: accessUnit,
            diagnostics: SpiceAnnexBParserDiagnostics(
                scanPassCount: 1,
                inputCopyBytes: 0,
                nalPayloadMaterializations: 0,
                nalPayloadCopyBytes: 0,
                avccSampleAllocations: scanResult.sampleData.isEmpty ? 0 : 1,
                avccSampleBytes: scanResult.sampleData.count,
                samplePayloadCopyBytes: scanResult.samplePayloadCopyBytes,
                additionalSamplePayloadCopyBytes: 0,
                nalUnitCount: scanResult.descriptors.count
            )
        )
    }

    private func scan(
        codec: SpiceAdvancedVideoCodec,
        bytes: UnsafeRawBufferPointer
    ) throws(SpiceCodecError) -> ScanResult {
        let bytes = bytes.bindMemory(to: UInt8.self)
        guard let firstStartCodeLength = startCodeLength(in: bytes, at: 0) else {
            throw .malformedPayload("advanced video access unit is not Annex-B")
        }

        var descriptors: [NALDescriptor] = []
        var sampleByteCount = 0
        var samplePayloadCopyBytes = 0
        var containsPicture = false
        var containsRandomAccess = false
        var nalStart = firstStartCodeLength
        var cursor = nalStart
        while cursor < bytes.count {
            if let startCodeLength = startCodeLength(in: bytes, at: cursor) {
                var nalEnd = cursor
                while nalEnd > nalStart, bytes[nalEnd - 1] == 0 {
                    nalEnd -= 1
                }
                try appendDescriptor(
                    codec: codec,
                    bytes: bytes,
                    range: nalStart..<nalEnd,
                    descriptors: &descriptors,
                    sampleByteCount: &sampleByteCount,
                    samplePayloadCopyBytes: &samplePayloadCopyBytes,
                    containsPicture: &containsPicture,
                    containsRandomAccess: &containsRandomAccess
                )
                let (nextNALStart, overflow) = cursor.addingReportingOverflow(startCodeLength)
                guard !overflow else {
                    throw .integerOverflow
                }
                guard nextNALStart < bytes.count else {
                    throw .malformedPayload("Annex-B ends with an empty NAL unit")
                }
                nalStart = nextNALStart
                cursor = nextNALStart
            } else {
                cursor += 1
            }
        }

        if nalStart < bytes.count {
            var nalEnd = bytes.count
            while nalEnd > nalStart, bytes[nalEnd - 1] == 0 {
                nalEnd -= 1
            }
            try appendDescriptor(
                codec: codec,
                bytes: bytes,
                range: nalStart..<nalEnd,
                descriptors: &descriptors,
                sampleByteCount: &sampleByteCount,
                samplePayloadCopyBytes: &samplePayloadCopyBytes,
                containsPicture: &containsPicture,
                containsRandomAccess: &containsRandomAccess
            )
        }
        guard !descriptors.isEmpty else {
            throw .malformedPayload("Annex-B contains no NAL units")
        }

        var sampleData = Data(count: sampleByteCount)
        if sampleByteCount > 0 {
            sampleData.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
                var destinationOffset = 0
                for descriptor in descriptors where !descriptor.isParameterSet {
                    let count = descriptor.sourceRange.count
                    let length = UInt32(count)
                    destination[destinationOffset] = UInt8(truncatingIfNeeded: length >> 24)
                    destination[destinationOffset + 1] = UInt8(truncatingIfNeeded: length >> 16)
                    destination[destinationOffset + 2] = UInt8(truncatingIfNeeded: length >> 8)
                    destination[destinationOffset + 3] = UInt8(truncatingIfNeeded: length)
                    destinationOffset += 4
                    destination.baseAddress?.advanced(by: destinationOffset).copyMemory(
                        from: bytes.baseAddress!.advanced(by: descriptor.sourceRange.lowerBound),
                        byteCount: count
                    )
                    destinationOffset += count
                }
            }
        }
        return ScanResult(
            descriptors: descriptors,
            sampleData: sampleData,
            samplePayloadCopyBytes: samplePayloadCopyBytes,
            containsPicture: containsPicture,
            isRandomAccess: containsRandomAccess
        )
    }

    private func appendDescriptor(
        codec: SpiceAdvancedVideoCodec,
        bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>,
        descriptors: inout [NALDescriptor],
        sampleByteCount: inout Int,
        samplePayloadCopyBytes: inout Int,
        containsPicture: inout Bool,
        containsRandomAccess: inout Bool
    ) throws(SpiceCodecError) {
        guard !range.isEmpty else {
            throw .malformedPayload("Annex-B contains an empty NAL unit")
        }
        guard range.count <= limits.maximumNALUnitBytes else {
            throw .malformedPayload("NAL unit exceeds configured byte limit")
        }
        guard descriptors.count < limits.maximumNALUnits else {
            throw .malformedPayload("access unit exceeds configured NAL unit limit")
        }
        let type = try nalType(codec: codec, bytes: bytes, range: range)
        let parameterSet = isParameterSet(codec: codec, type: type)
        descriptors.append(
            NALDescriptor(type: type, sourceRange: range, isParameterSet: parameterSet)
        )
        guard !parameterSet else {
            return
        }
        guard UInt32(exactly: range.count) != nil else {
            throw .integerOverflow
        }
        let (withHeader, headerOverflow) = range.count.addingReportingOverflow(4)
        let (nextSampleByteCount, sampleOverflow) = sampleByteCount.addingReportingOverflow(withHeader)
        let (nextPayloadCopyBytes, payloadOverflow) =
            samplePayloadCopyBytes.addingReportingOverflow(range.count)
        guard !headerOverflow, !sampleOverflow, !payloadOverflow else {
            throw .integerOverflow
        }
        sampleByteCount = nextSampleByteCount
        samplePayloadCopyBytes = nextPayloadCopyBytes
        containsPicture = containsPicture || isPicture(codec: codec, type: type)
        containsRandomAccess = containsRandomAccess || isRandomAccess(codec: codec, type: type)
    }

    private func startCodeLength(
        in bytes: UnsafeBufferPointer<UInt8>,
        at offset: Int
    ) -> Int? {
        guard offset >= 0, offset <= bytes.count - 3,
              bytes[offset] == 0, bytes[offset + 1] == 0
        else {
            return nil
        }
        if offset <= bytes.count - 4,
           bytes[offset + 2] == 0,
           bytes[offset + 3] == 1
        {
            return 4
        }
        return bytes[offset + 2] == 1 ? 3 : nil
    }

    private func nalType(
        codec: SpiceAdvancedVideoCodec,
        bytes: UnsafeBufferPointer<UInt8>,
        range: Range<Int>
    ) throws(SpiceCodecError) -> UInt8 {
        let first = bytes[range.lowerBound]
        guard first & 0x80 == 0 else {
            throw .malformedPayload("NAL unit has a nonzero forbidden bit")
        }
        switch codec {
        case .h264:
            return first & 0x1f
        case .h265:
            guard range.count >= 2 else {
                throw .malformedPayload("HEVC NAL unit is shorter than its header")
            }
            guard bytes[range.lowerBound + 1] & 0x07 != 0 else {
                throw .malformedPayload("HEVC temporal_id_plus1 is zero")
            }
            return (first >> 1) & 0x3f
        }
    }

    private func isParameterSet(codec: SpiceAdvancedVideoCodec, type: UInt8) -> Bool {
        switch codec {
        case .h264:
            type == 7 || type == 8 || type == 13
        case .h265:
            (32...34).contains(type)
        }
    }

    private func isPicture(codec: SpiceAdvancedVideoCodec, type: UInt8) -> Bool {
        switch codec {
        case .h264:
            (1...5).contains(type)
        case .h265:
            type <= 31
        }
    }

    private func isRandomAccess(codec: SpiceAdvancedVideoCodec, type: UInt8) -> Bool {
        switch codec {
        case .h264:
            type == 5
        case .h265:
            (16...23).contains(type)
        }
    }
}

package protocol SpiceAdvancedVideoDecoder: AnyObject, Sendable {
    func decode(
        payload: Data,
        multimediaTime: UInt32
    ) async throws(SpiceCodecError) -> SpiceDecodedImage?

    /// Returns the decoder's immutable native frame when it has one. Callers
    /// that cannot consume it can use `copyBGRA()` or the compatibility
    /// `decode(payload:multimediaTime:)` entry point.
    func decodeVideoFrame(
        payload: Data,
        multimediaTime: UInt32
    ) async throws(SpiceCodecError) -> (any SpiceDecodedVideoFrame)?

    func diagnosticsSnapshot() async -> SpiceAdvancedVideoDecoderDiagnostics
    func close() async
}

package extension SpiceAdvancedVideoDecoder {
    func decodeVideoFrame(
        payload: Data,
        multimediaTime: UInt32
    ) async throws(SpiceCodecError) -> (any SpiceDecodedVideoFrame)? {
        try await decode(payload: payload, multimediaTime: multimediaTime)
    }

    func diagnosticsSnapshot() async -> SpiceAdvancedVideoDecoderDiagnostics {
        .init()
    }
}

package protocol SpiceAdvancedVideoDecoderFactory: Sendable {
    func makeDecoder(
        codec: SpiceAdvancedVideoCodec,
        width: Int,
        height: Int
    ) throws(SpiceCodecError) -> any SpiceAdvancedVideoDecoder
}
