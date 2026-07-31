import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("VDAgent stream protocol")
struct AgentProtocolTests {
    @Test func reassemblesHeaderAndPayloadAcrossPackets() throws {
        let limits = VDAgentWireLimits(maximumPacketBytes: 7, maximumMessageDataBytes: 64)
        let expected = VDAgentMessage(
            protocolID: 1,
            type: 6,
            opaque: 0x0102_0304_0506_0708,
            data: Data("clipboard".utf8)
        )
        let fragments = try VDAgentWireEncoder.fragments(for: expected, limits: limits)
        var decoder = VDAgentStreamDecoder(limits: limits)
        var decoded: [VDAgentMessage] = []

        for fragment in fragments {
            decoded += try decoder.append(packet: fragment)
        }

        #expect(fragments.allSatisfy { $0.count <= 7 })
        #expect(decoded == [expected])
    }

    @Test func decodesMultipleMessagesAndPreservesUnknownProtocol() throws {
        let first = VDAgentMessage(type: 3, data: Data())
        let second = VDAgentMessage(
            protocolID: 99,
            type: 4_000,
            opaque: 7,
            data: Data([1, 2, 3])
        )
        let firstBytes = try #require(VDAgentWireEncoder.fragments(for: first).first)
        let secondBytes = try #require(VDAgentWireEncoder.fragments(for: second).first)
        var decoder = VDAgentStreamDecoder()

        #expect(try decoder.append(packet: firstBytes + secondBytes) == [first, second])
    }

    @Test func rejectsPacketAndDeclaredMessageBeyondLimits() throws {
        var packetBounded = VDAgentStreamDecoder(limits: .init(
            maximumPacketBytes: 4,
            maximumMessageDataBytes: 16
        ))
        #expect(throws: WireError.messageTooLarge(actual: 5, maximum: 4)) {
            try packetBounded.append(packet: Data(repeating: 0, count: 5))
        }

        var writer = ByteWriter()
        writer.writeUInt32LE(1)
        writer.writeUInt32LE(4)
        writer.writeUInt64LE(0)
        writer.writeUInt32LE(17)
        var messageBounded = VDAgentStreamDecoder(limits: .init(
            maximumPacketBytes: 64,
            maximumMessageDataBytes: 16
        ))
        #expect(throws: WireError.messageTooLarge(actual: 17, maximum: 16)) {
            try messageBounded.append(packet: writer.data)
        }
    }

    @Test func decodesEveryMainAgentEnvelopeStrictly() throws {
        #expect(try SpiceServerMessageDecoder.decode(
            id: SpiceMainAgentWire.serverConnected,
            body: Data(),
            channel: .main
        ) == .mainAgentConnected(tokens: nil))
        #expect(try SpiceServerMessageDecoder.decode(
            id: SpiceMainAgentWire.serverDisconnected,
            body: uint32(9),
            channel: .main
        ) == .mainAgentDisconnected(errorCode: 9))
        #expect(try SpiceServerMessageDecoder.decode(
            id: SpiceMainAgentWire.serverData,
            body: Data([1, 2]),
            channel: .main
        ) == .mainAgentData(Data([1, 2])))
        #expect(try SpiceServerMessageDecoder.decode(
            id: SpiceMainAgentWire.serverToken,
            body: uint32(3),
            channel: .main
        ) == .mainAgentToken(3))
        #expect(try SpiceServerMessageDecoder.decode(
            id: SpiceMainAgentWire.serverConnectedTokens,
            body: uint32(5),
            channel: .main
        ) == .mainAgentConnected(tokens: 5))

        #expect(throws: WireError.trailingBytes(1)) {
            try SpiceServerMessageDecoder.decode(
                id: SpiceMainAgentWire.serverConnected,
                body: Data([0]),
                channel: .main
            )
        }
        #expect(throws: WireError.truncated(expected: 4, remaining: 3)) {
            try SpiceServerMessageDecoder.decode(
                id: SpiceMainAgentWire.serverToken,
                body: Data(repeating: 0, count: 3),
                channel: .main
            )
        }
        #expect(throws: WireError.messageTooLarge(actual: 2_049, maximum: 2_048)) {
            try SpiceServerMessageDecoder.decode(
                id: SpiceMainAgentWire.serverData,
                body: Data(repeating: 0, count: 2_049),
                channel: .main
            )
        }
    }

    private func uint32(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }
}
