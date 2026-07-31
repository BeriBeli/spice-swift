package enum SpanByteReader {
    package static func readUInt8(
        from bytes: borrowing Span<UInt8>,
        offset: inout Int
    ) throws(WireError) -> UInt8 {
        try require(1, in: bytes, at: offset)
        defer { offset += 1 }
        return bytes[offset]
    }

    package static func readUInt16LE(
        from bytes: borrowing Span<UInt8>,
        offset: inout Int
    ) throws(WireError) -> UInt16 {
        try require(2, in: bytes, at: offset)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    package static func readUInt32LE(
        from bytes: borrowing Span<UInt8>,
        offset: inout Int
    ) throws(WireError) -> UInt32 {
        try require(4, in: bytes, at: offset)
        defer { offset += 4 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    package static func readUInt64LE(
        from bytes: borrowing Span<UInt8>,
        offset: inout Int
    ) throws(WireError) -> UInt64 {
        try require(8, in: bytes, at: offset)
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(bytes[offset + index]) << UInt64(index * 8)
        }
        offset += 8
        return value
    }

    private static func require(
        _ count: Int,
        in bytes: borrowing Span<UInt8>,
        at offset: Int
    ) throws(WireError) {
        guard offset >= 0, count >= 0 else {
            throw .invalidOffset(UInt64(max(offset, 0)))
        }
        let (end, overflow) = offset.addingReportingOverflow(count)
        guard !overflow else {
            throw .integerOverflow
        }
        guard end <= bytes.count else {
            throw .truncated(expected: count, remaining: max(bytes.count - offset, 0))
        }
    }
}
