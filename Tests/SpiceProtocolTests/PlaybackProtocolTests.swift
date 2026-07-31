import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Playback wire protocol")
struct PlaybackProtocolTests {
    @Test func decodesEveryPlaybackMessageBodyExactly() throws {
        #expect(try decode(101, dataBody(time: 10, bytes: Data([1, 2, 3, 4]))) == .data(
            SpicePlaybackPacket(multimediaTime: 10, data: Data([1, 2, 3, 4]))
        ))
        #expect(try decode(102, modeBody(time: 11, mode: 1)) == .mode(SpicePlaybackMode(
            multimediaTime: 11,
            mode: .raw,
            data: Data()
        )))
        #expect(try decode(103, startBody()) == .start(SpicePlaybackStart(
            channels: 2,
            format: .s16,
            frequency: 48_000
        )))
        #expect(try decode(104, Data()) == .stop)
        #expect(try decode(105, volumeBody([10, 20])) == .volume([10, 20]))
        #expect(try decode(106, Data([1])) == .mute(true))
        #expect(try decode(107, uint32Body(200)) == .latency(milliseconds: 200))
    }

    @Test func rejectsTruncationTrailingBytesEnumsAndBounds() throws {
        let valid: [(UInt16, Data)] = [
            (101, dataBody(time: 10, bytes: Data([1]))),
            (102, modeBody(time: 11, mode: 1)),
            (103, startBody()),
            (105, volumeBody([10, 20])),
            (106, Data([1])),
            (107, uint32Body(200)),
        ]
        for (id, body) in valid {
            for length in 0..<body.count {
                #expect(throws: WireError.self) {
                    try decode(id, Data(body.prefix(length)))
                }
            }
        }

        #expect(throws: WireError.invalidEnum(type: "SpiceAudioDataMode", value: 99)) {
            try decode(102, modeBody(time: 1, mode: 99))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try decode(104, Data([0]))
        }
        #expect(throws: WireError.invalidSize(2)) {
            try decode(105, Data([2, 1, 0]))
        }
        let bounded = SpicePlaybackWireDecoder(limits: .init(maximumPacketBytes: 3))
        #expect(throws: WireError.invalidSize(4)) {
            try bounded.decode(id: 101, body: dataBody(
                time: 1,
                bytes: Data(repeating: 0, count: 4)
            ))
        }
    }

    private func decode(_ id: UInt16, _ body: Data) throws -> SpicePlaybackCommand {
        try SpicePlaybackWireDecoder().decode(id: id, body: body)
    }

    private func dataBody(time: UInt32, bytes: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(time)
        writer.writeBytes(bytes)
        return writer.data
    }

    private func modeBody(time: UInt32, mode: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(time)
        writer.writeUInt32LE(mode)
        return writer.data
    }

    private func startBody() -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(2)
        writer.writeUInt16LE(1)
        writer.writeUInt32LE(48_000)
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

    private func uint32Body(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }
}
