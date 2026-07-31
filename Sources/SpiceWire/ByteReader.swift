import Foundation

package struct ByteReader: Sendable {
    private let data: Data
    package private(set) var offset: Int

    package init(_ data: Data, offset: Int = 0) throws(WireError) {
        guard offset >= 0, offset <= data.count else {
            throw .invalidOffset(UInt64(max(offset, 0)))
        }
        self.data = data
        self.offset = offset
    }

    package var remainingCount: Int {
        data.count - offset
    }

    package mutating func readUInt8() throws(WireError) -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    package mutating func readUInt16LE() throws(WireError) -> UInt16 {
        let bytes = try readIntegerBytes(count: 2)
        return UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
    }

    package mutating func readInt16LE() throws(WireError) -> Int16 {
        Int16(bitPattern: try readUInt16LE())
    }

    package mutating func readUInt32LE() throws(WireError) -> UInt32 {
        let bytes = try readIntegerBytes(count: 4)
        return UInt32(bytes[0])
            | (UInt32(bytes[1]) << 8)
            | (UInt32(bytes[2]) << 16)
            | (UInt32(bytes[3]) << 24)
    }

    package mutating func readInt32LE() throws(WireError) -> Int32 {
        Int32(bitPattern: try readUInt32LE())
    }

    package mutating func readUInt64LE() throws(WireError) -> UInt64 {
        let bytes = try readIntegerBytes(count: 8)
        var value: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            value |= UInt64(byte) << UInt64(index * 8)
        }
        return value
    }

    package mutating func readBytes(count: Int) throws(WireError) -> Data {
        guard count >= 0 else {
            throw .invalidSize(count)
        }
        try require(count)
        let start = data.startIndex + offset
        let range = start..<(start + count)
        offset += count
        return data.subdata(in: range)
    }

    package mutating func readRemainingBytes() -> Data {
        let start = data.startIndex + offset
        let bytes = data.subdata(in: start..<data.endIndex)
        offset = data.count
        return bytes
    }

    package func requireFullyConsumed() throws(WireError) {
        guard remainingCount == 0 else {
            throw .trailingBytes(remainingCount)
        }
    }

    private mutating func readIntegerBytes(count: Int) throws(WireError) -> [UInt8] {
        try require(count)
        let start = offset
        offset += count
        return (0..<count).map { data[data.startIndex + start + $0] }
    }

    private func require(_ count: Int) throws(WireError) {
        guard count >= 0 else {
            throw .invalidSize(count)
        }
        guard remainingCount >= count else {
            throw .truncated(expected: count, remaining: remainingCount)
        }
    }
}
