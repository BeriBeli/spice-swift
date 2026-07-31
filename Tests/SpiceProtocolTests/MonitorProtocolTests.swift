import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("VDAgent monitor configuration wire protocol")
struct MonitorProtocolTests {
    @Test func encodesSingleMonitorInHeaderFieldOrder() throws {
        let message = try VDAgentMonitorCodec.encode(.init(
            usesPositions: false,
            monitors: [.init(width: 1_920, height: 1_080, depth: 32)]
        ))
        var expected = uint32(1)
        for value: UInt32 in [0, 1_080, 1_920, 32, 0, 0] {
            expected.append(uint32(value))
        }

        #expect(message.type == VDAgentMessageType.monitorsConfig.rawValue)
        #expect(message.data == expected)
    }

    @Test func encodesSignedPositionsOnlyWhenRequested() throws {
        let message = try VDAgentMonitorCodec.encode(.init(
            usesPositions: true,
            monitors: [.init(width: 800, height: 600, depth: 32, x: -800, y: 20)]
        ))
        var reader = try ByteReader(message.data)

        #expect(try reader.readUInt32LE() == 1)
        #expect(try reader.readUInt32LE() == 1)
        #expect(try reader.readUInt32LE() == 600)
        #expect(try reader.readUInt32LE() == 800)
        #expect(try reader.readUInt32LE() == 32)
        #expect(try reader.readInt32LE() == -800)
        #expect(try reader.readInt32LE() == 20)
        #expect(reader.remainingCount == 0)
    }

    @Test func rejectsEmptyOversizedOrDisabledMonitorLists() throws {
        #expect(throws: WireError.invalidSize(0)) {
            try VDAgentMonitorCodec.encode(.init(usesPositions: false, monitors: []))
        }
        #expect(throws: WireError.invalidSize(257)) {
            try VDAgentMonitorCodec.encode(.init(
                usesPositions: false,
                monitors: Array(
                    repeating: .init(width: 1, height: 1, depth: 32),
                    count: 257
                )
            ))
        }

        _ = try VDAgentMonitorCodec.encode(.init(
            usesPositions: true,
            allowsSparse: true,
            monitors: [
                .init(width: 800, height: 600, depth: 32),
                .init(width: 0, height: 0, depth: 32),
            ]
        ))
        #expect(throws: WireError.invalidSize(0)) {
            try VDAgentMonitorCodec.encode(.init(
                usesPositions: false,
                monitors: [.init(width: 0, height: 600, depth: 32)]
            ))
        }
    }

    @Test func decodesOnlyStrictMonitorReplies() throws {
        #expect(try VDAgentMonitorCodec.decodeReply(reply(status: 1)) == .init(
            status: .success
        ))
        #expect(try VDAgentMonitorCodec.decodeReply(reply(status: 2)) == .init(
            status: .error
        ))
        #expect(try VDAgentMonitorCodec.decodeReply(VDAgentMessage(
            type: VDAgentMessageType.reply.rawValue,
            data: uint32(VDAgentMessageType.clipboard.rawValue) + uint32(1)
        )) == nil)
        #expect(throws: WireError.invalidEnum(
            type: "VDAgentReplyStatus",
            value: 3
        )) {
            try VDAgentMonitorCodec.decodeReply(reply(status: 3))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try VDAgentMonitorCodec.decodeReply(VDAgentMessage(
                type: VDAgentMessageType.reply.rawValue,
                data: reply(status: 1).data + Data([0])
            ))
        }
    }

    private func reply(status: UInt32) -> VDAgentMessage {
        VDAgentMessage(
            type: VDAgentMessageType.reply.rawValue,
            data: uint32(VDAgentMessageType.monitorsConfig.rawValue) + uint32(status)
        )
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
