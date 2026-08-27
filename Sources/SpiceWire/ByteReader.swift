import Foundation

package struct ByteReader: Sendable {
    private let bytes: WireSlice
    package private(set) var offset: Int

    package init(_ data: Data, offset: Int = 0) throws(WireError) {
        try self.init(OwnedBytes(data).wholeSlice, offset: offset)
    }

    package init(_ bytes: WireSlice, offset: Int = 0) throws(WireError) {
        guard offset >= 0, offset <= bytes.count else {
            throw .invalidOffset(UInt64(max(offset, 0)))
        }
        self.bytes = bytes
        self.offset = offset
    }

    package var remainingCount: Int {
        bytes.count - offset
    }

    package mutating func readUInt8() throws(WireError) -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes.withSpan { $0[offset] }
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
        try readSlice(count: count).data
    }

    package mutating func readSlice(count: Int) throws(WireError) -> WireSlice {
        guard count >= 0 else {
            throw .invalidSize(count)
        }
        try require(count)
        let start = offset
        offset += count
        return try bytes.slice(start..<offset)
    }

    package mutating func readRemainingBytes() -> Data {
        readRemainingSlice().data
    }

    package mutating func readRemainingSlice() -> WireSlice {
        let start = offset
        offset = bytes.count
        // Both bounds derive from the already validated reader slice.
        return try! bytes.slice(start..<bytes.count)
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
        let value = bytes.withSpan { span in
            var value: T = 0
            withUnsafeMutableBytes(of: &value) { destination in
                for index in 0..<count {
                    destination[index] = span[offset + index]
                }
            }
            return value
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
