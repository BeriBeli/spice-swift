import Foundation

package enum SpiceAdvancedVideoCodec: Sendable, Equatable {
    case h264
    case h265
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

package struct SpiceVideoNALUnit: Sendable, Equatable {
    package let type: UInt8
    package let bytes: Data

    package init(type: UInt8, bytes: consuming Data) {
        self.type = type
        self.bytes = bytes
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

package struct SpiceAnnexBParser: Sendable {
    private let limits: SpiceAdvancedVideoDecodeLimits

    package init(limits: SpiceAdvancedVideoDecodeLimits = .init()) {
        self.limits = limits
    }

    package func parse(
        codec: SpiceAdvancedVideoCodec,
        payload: Data
    ) throws(SpiceCodecError) -> SpiceVideoAccessUnit {
        guard !payload.isEmpty else {
            throw .emptyPayload
        }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(
                actual: payload.count,
                maximum: limits.maximumEncodedBytes
            )
        }

        let bytes = [UInt8](payload)
        guard let firstStartCode = startCode(in: bytes, from: 0), firstStartCode.offset == 0 else {
            throw .malformedPayload("advanced video access unit is not Annex-B")
        }

        var nalUnits: [SpiceVideoNALUnit] = []
        var cursor = firstStartCode.offset + firstStartCode.length
        while cursor < bytes.count {
            let next = startCode(in: bytes, from: cursor)
            var end = next?.offset ?? bytes.count
            while end > cursor, bytes[end - 1] == 0 {
                end -= 1
            }
            guard end > cursor else {
                throw .malformedPayload("Annex-B contains an empty NAL unit")
            }
            let count = end - cursor
            guard count <= limits.maximumNALUnitBytes else {
                throw .malformedPayload("NAL unit exceeds configured byte limit")
            }
            guard nalUnits.count < limits.maximumNALUnits else {
                throw .malformedPayload("access unit exceeds configured NAL unit limit")
            }

            let nal = Data(bytes[cursor..<end])
            let type = try nalType(codec: codec, bytes: nal)
            nalUnits.append(SpiceVideoNALUnit(type: type, bytes: nal))

            guard let next else {
                cursor = bytes.count
                break
            }
            cursor = next.offset + next.length
            guard cursor < bytes.count else {
                throw .malformedPayload("Annex-B ends with an empty NAL unit")
            }
        }
        guard !nalUnits.isEmpty else {
            throw .malformedPayload("Annex-B contains no NAL units")
        }

        let parameterSets = nalUnits.filter { isParameterSet(codec: codec, type: $0.type) }
        let sampleUnits = nalUnits.filter { !isParameterSet(codec: codec, type: $0.type) }
        var sampleData = Data()
        sampleData.reserveCapacity(sampleUnits.reduce(0) { $0 + 4 + $1.bytes.count })
        for nal in sampleUnits {
            guard let length = UInt32(exactly: nal.bytes.count) else {
                throw .integerOverflow
            }
            sampleData.append(UInt8(truncatingIfNeeded: length >> 24))
            sampleData.append(UInt8(truncatingIfNeeded: length >> 16))
            sampleData.append(UInt8(truncatingIfNeeded: length >> 8))
            sampleData.append(UInt8(truncatingIfNeeded: length))
            sampleData.append(nal.bytes)
        }

        return SpiceVideoAccessUnit(
            codec: codec,
            nalUnits: nalUnits,
            sampleData: sampleData,
            parameterSets: parameterSets,
            containsPicture: sampleUnits.contains { isPicture(codec: codec, type: $0.type) },
            isRandomAccess: sampleUnits.contains { isRandomAccess(codec: codec, type: $0.type) }
        )
    }

    private func startCode(
        in bytes: [UInt8],
        from start: Int
    ) -> (offset: Int, length: Int)? {
        guard bytes.count >= 3, start <= bytes.count - 3 else {
            return nil
        }
        for offset in start...(bytes.count - 3) {
            guard bytes[offset] == 0, bytes[offset + 1] == 0 else {
                continue
            }
            if offset + 3 < bytes.count,
               bytes[offset + 2] == 0,
               bytes[offset + 3] == 1
            {
                return (offset, 4)
            }
            if bytes[offset + 2] == 1 {
                return (offset, 3)
            }
        }
        return nil
    }

    private func nalType(
        codec: SpiceAdvancedVideoCodec,
        bytes: Data
    ) throws(SpiceCodecError) -> UInt8 {
        guard let first = bytes.first, first & 0x80 == 0 else {
            throw .malformedPayload("NAL unit has a nonzero forbidden bit")
        }
        switch codec {
        case .h264:
            return first & 0x1f
        case .h265:
            guard bytes.count >= 2 else {
                throw .malformedPayload("HEVC NAL unit is shorter than its header")
            }
            guard bytes[bytes.startIndex + 1] & 0x07 != 0 else {
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

package protocol SpiceAdvancedVideoDecoder: Sendable {
    func decode(
        payload: Data,
        multimediaTime: UInt32
    ) async throws(SpiceCodecError) -> SpiceDecodedImage?

    func close() async
}

package protocol SpiceAdvancedVideoDecoderFactory: Sendable {
    func makeDecoder(
        codec: SpiceAdvancedVideoCodec,
        width: Int,
        height: Int
    ) throws(SpiceCodecError) -> any SpiceAdvancedVideoDecoder
}
