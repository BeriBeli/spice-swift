import Foundation

package struct ByteWriter: Sendable {
    private(set) package var data = Data()

    package init(capacity: Int = 0) {
        if capacity > 0 {
            data.reserveCapacity(capacity)
        }
    }

    package mutating func writeUInt8(_ value: UInt8) {
        data.append(value)
    }

    package mutating func writeUInt16LE(_ value: UInt16) {
        for shift in stride(from: 0, to: 16, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt16(shift)))
        }
    }

    package mutating func writeInt16LE(_ value: Int16) {
        writeUInt16LE(UInt16(bitPattern: value))
    }

    package mutating func writeUInt32LE(_ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    package mutating func writeInt32LE(_ value: Int32) {
        writeUInt32LE(UInt32(bitPattern: value))
    }

    package mutating func writeUInt64LE(_ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    package mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }
}
