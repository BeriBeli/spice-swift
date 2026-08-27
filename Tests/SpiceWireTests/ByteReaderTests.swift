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

    @Test func ownedWireRangesAreCheckedAndBorrowOnlyInsideTheClosure() async throws {
        let owner = OwnedBytes(Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55]))
        let slice = try owner.slice(1..<5)

        #expect(slice.range == 1..<5)
        #expect(slice.count == 4)
        #expect(slice.retainedOwnerByteCount == 6)
        #expect(slice.data == Data([0x11, 0x22, 0x33, 0x44]))
        #expect(slice.sharesOwner(with: owner.wholeSlice))
        #expect(throws: WireError.invalidOffset(0)) {
            try owner.slice(-1..<1)
        }
        #expect(throws: WireError.truncated(expected: 5, remaining: 4)) {
            try slice.slice(0..<5)
        }

        let mailbox = WireSliceMailbox()
        await mailbox.store(slice)
        #expect(await mailbox.bytes() == Data([0x11, 0x22, 0x33, 0x44]))
        #expect(await mailbox.spanChecksum() == 0xaa)
    }

    @Test func wireSliceEqualityIsByteBasedButOwnerIdentityRemainsObservable() throws {
        let firstOwner = OwnedBytes(Data([1, 2, 3, 4]))
        let secondOwner = OwnedBytes(Data([0, 2, 3, 9]))
        let first = try firstOwner.slice(1..<3)
        let second = try secondOwner.slice(1..<3)

        #expect(first == second)
        #expect(!first.sharesOwner(with: second))
        #expect(first.sharesOwner(with: firstOwner.wholeSlice))
    }

    @Test func byteReaderReturnsOwnerRangesWithoutMaterializingPayloadBytes() throws {
        let owner = OwnedBytes(Data([0xff, 1, 2, 3, 4, 5]))
        let source = try owner.slice(1..<6)
        var reader = try ByteReader(source)

        #expect(try reader.readUInt8() == 1)
        let middle = try reader.readSlice(count: 2)
        let remaining = reader.readRemainingSlice()

        #expect(middle.data == Data([2, 3]))
        #expect(remaining.data == Data([4, 5]))
        #expect(middle.sharesOwner(with: source))
        #expect(remaining.sharesOwner(with: source))
        #expect(middle.range == 2..<4)
        #expect(remaining.range == 4..<6)
        #expect(reader.remainingCount == 0)
    }
}

private actor WireSliceMailbox {
    private var value: WireSlice?

    func store(_ value: WireSlice) {
        self.value = value
    }

    func bytes() -> Data? {
        value?.data
    }

    func spanChecksum() -> UInt64? {
        value?.withSpan { bytes in
            bytes.indices.reduce(into: UInt64(0)) { checksum, index in
                checksum += UInt64(bytes[index])
            }
        }
    }
}
