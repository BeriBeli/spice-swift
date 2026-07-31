import Foundation
import Testing
@testable import SpiceWire

@Suite("ByteReader and ByteWriter")
struct ByteReaderTests {
    @Test func littleEndianRoundTrip() throws {
        var writer = ByteWriter()
        writer.writeUInt8(0x7f)
        writer.writeUInt16LE(0x1234)
        writer.writeUInt32LE(0x89ab_cdef)
        writer.writeUInt64LE(0x0123_4567_89ab_cdef)

        var reader = try ByteReader(writer.data)
        #expect(try reader.readUInt8() == 0x7f)
        #expect(try reader.readUInt16LE() == 0x1234)
        #expect(try reader.readUInt32LE() == 0x89ab_cdef)
        #expect(try reader.readUInt64LE() == 0x0123_4567_89ab_cdef)
        #expect(reader.remainingCount == 0)
    }

    @Test func truncationDoesNotAdvanceOffset() throws {
        var reader = try ByteReader(Data([0x01, 0x02, 0x03]))

        #expect(throws: WireError.truncated(expected: 4, remaining: 3)) {
            try reader.readUInt32LE()
        }
        #expect(reader.offset == 0)
        #expect(try reader.readUInt16LE() == 0x0201)
    }

    @Test func spanPathMatchesDataPath() throws {
        let bytes: [UInt8] = [0xef, 0xcd, 0xab, 0x89, 0x67, 0x45, 0x23, 0x01]
        var spanOffset = 0
        let spanValue = try SpanByteReader.readUInt64LE(from: bytes.span, offset: &spanOffset)
        var dataReader = try ByteReader(Data(bytes))
        let dataValue = try dataReader.readUInt64LE()

        #expect(spanValue == dataValue)
        #expect(spanOffset == 8)
    }

    @Test func trailingBytesAreRejected() throws {
        let reader = try ByteReader(Data([1]))
        #expect(throws: WireError.trailingBytes(1)) {
            try reader.requireFullyConsumed()
        }
    }

    @Test func bulkReadsHonorNonzeroDataSliceIndices() throws {
        let slice = Data([0xff, 1, 2, 3, 4]).dropFirst()
        #expect(slice.startIndex != 0)
        var reader = try ByteReader(slice)

        #expect(try reader.readBytes(count: 2) == Data([1, 2]))
        #expect(reader.readRemainingBytes() == Data([3, 4]))
    }
}
