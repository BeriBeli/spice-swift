import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Record wire protocol")
struct RecordProtocolTests {
    @Test func decodesEveryServerCommandAndDispatchesByChannel() throws {
        let start = startBody(channels: 2, format: 1, frequency: 48_000)
        #expect(try decode(101, start) == .start(SpiceRecordStart(
            channels: 2,
            format: .s16,
            frequency: 48_000
        )))
        #expect(try decode(102, Data()) == .stop)
        #expect(try decode(103, volumeBody([100, 200])) == .volume([100, 200]))
        #expect(try decode(104, Data([1])) == .mute(true))
        #expect(try SpiceServerMessageDecoder.decode(
            id: 101,
            body: start,
            channel: .record
        ) == .record(.start(SpiceRecordStart(
            channels: 2,
            format: .s16,
            frequency: 48_000
        ))))
    }

    @Test func encodesRawModeStartMarkAndDataExactly() throws {
        let codec = SpiceRecordWireCodec()
        #expect(try codec.encodeMode(timestamp: 10) == uint32(10) + uint32(1))
        #expect(codec.encodeStartMark(timestamp: 11) == uint32(11))
        #expect(try codec.encodeData(
            timestamp: 12,
            data: Data([1, 2, 3, 4])
        ) == uint32(12) + Data([1, 2, 3, 4]))
    }

    @Test func rejectsTruncationTrailingBytesEnumsAndBounds() throws {
        let valid = startBody(channels: 2, format: 1, frequency: 48_000)
        for length in 0..<valid.count {
            #expect(throws: WireError.self) {
                try decode(101, Data(valid.prefix(length)))
            }
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try decode(102, Data([0]))
        }
        #expect(throws: WireError.invalidEnum(type: "SpiceAudioFormat", value: 9)) {
            try decode(101, startBody(channels: 2, format: 9, frequency: 48_000))
        }
        #expect(throws: WireError.invalidSize(2)) {
            try decode(103, Data([2, 1, 0]))
        }
        #expect(throws: WireError.invalidEnum(type: "SpiceAudioMute", value: 2)) {
            try decode(104, Data([2]))
        }

        let bounded = SpiceRecordWireCodec(limits: .init(maximumPacketBytes: 3))
        #expect(throws: WireError.messageTooLarge(actual: 4, maximum: 3)) {
            try bounded.encodeData(timestamp: 1, data: Data(repeating: 0, count: 4))
        }
        #expect(throws: WireError.invalidSize(0)) {
            try bounded.encodeData(timestamp: 1, data: Data())
        }
    }

    private func decode(_ id: UInt16, _ body: Data) throws -> SpiceRecordCommand {
        try SpiceRecordWireCodec().decodeServer(id: id, body: body)
    }

    private func startBody(channels: UInt32, format: UInt16, frequency: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(channels)
        writer.writeUInt16LE(format)
        writer.writeUInt32LE(frequency)
        return writer.data
    }

    private func volumeBody(_ volume: [UInt16]) -> Data {
        var writer = ByteWriter()
        writer.writeUInt8(UInt8(volume.count))
        for value in volume {
            writer.writeUInt16LE(value)
        }
        return writer.data
    }

    private func uint32(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }
}
