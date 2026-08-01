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
        try readInteger(UInt16.self)
    }

    package mutating func readInt16LE() throws(WireError) -> Int16 {
        Int16(bitPattern: try readUInt16LE())
    }

    package mutating func readUInt32LE() throws(WireError) -> UInt32 {
        try readInteger(UInt32.self)
    }

    package mutating func readInt32LE() throws(WireError) -> Int32 {
        Int32(bitPattern: try readUInt32LE())
    }

    package mutating func readUInt64LE() throws(WireError) -> UInt64 {
        try readInteger(UInt64.self)
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

    private mutating func readInteger<T: FixedWidthInteger>(
        _ type: T.Type
    ) throws(WireError) -> T {
        let count = MemoryLayout<T>.size
        try require(count)
        let value = data.withUnsafeBytes {
            $0.loadUnaligned(fromByteOffset: offset, as: type)
        }
        offset += count
        return T(littleEndian: value)
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
