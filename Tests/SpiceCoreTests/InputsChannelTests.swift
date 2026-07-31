import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Inputs Channel")
struct InputsChannelTests {
    @Test func preservesKeyboardOrderAndTracksButtonState() async throws {
        let inbound = try [
            encodeMini(SpiceMsgInputsInit(keyboardModifiers: 1)),
            encodeMini(SpiceMsgInputsKeyModifiers(modifiers: 3)),
            encodeMini(SpiceMsgInputsMouseMotionAck()),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = InputsChannel(connection: ChannelConnection(
            key: ChannelKey(type: 3, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        #expect(try await channel.processNext() == .initialized(keyboardModifiers: 1))
        #expect(try await channel.processNext() == .keyboardModifiersChanged(3))
        #expect(try await channel.processNext() == .mouseMotionAcknowledged)

        try await channel.send(.keyDown(scanCode: 0x1e))
        try await channel.send(.keyUp(scanCode: 0x1e))
        try await channel.send(.mousePress(.left))
        try await channel.send(.mouseMotion(dx: -2, dy: 4))
        try await channel.send(.mouseRelease(.left))
        try await channel.send(.mousePosition(x: 100, y: 200, displayID: 1))

        let outbound = await transport.outbound
        #expect(try outbound.map(messageID) == [101, 102, 113, 111, 114, 112])
        #expect(try keyCode(outbound[0]) == 0x1e)
        #expect(try keyCode(outbound[1]) == 0x9e)
        #expect(try buttonsState(outbound[2], offset: 1) == 1)
        #expect(try buttonsState(outbound[3], offset: 8) == 1)
        #expect(try buttonsState(outbound[4], offset: 1) == 0)
        #expect(try buttonsState(outbound[5], offset: 8) == 0)
    }

    @Test func encodesExtendedScanCodePrefixesAndReleaseBit() async throws {
        let transport = FakeTransport()
        try await transport.connect()
        let channel = InputsChannel(connection: ChannelConnection(
            key: ChannelKey(type: 3, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        try await channel.send(.keyDown(scanCode: 0x14b))
        try await channel.send(.keyUp(scanCode: 0x14b))

        let outbound = await transport.outbound
        #expect(try keyCode(outbound[0]) == 0x4be0)
        #expect(try keyCode(outbound[1]) == 0xcbe0)
    }

    private func messageID(_ framed: Data) throws -> UInt16 {
        var reader = try ByteReader(framed)
        return try reader.readUInt16LE()
    }

    private func buttonsState(_ framed: Data, offset: Int) throws -> UInt16 {
        var reader = try ByteReader(framed, offset: 6 + offset)
        return try reader.readUInt16LE()
    }

    private func keyCode(_ framed: Data) throws -> UInt32 {
        var reader = try ByteReader(framed, offset: 6)
        return try reader.readUInt32LE()
    }

    private func encodeMini<Message: SpiceGeneratedMessage>(_ message: Message) throws -> Data {
        let id = try #require(Message.messageID)
        var body = ByteWriter()
        try message.encode(to: &body)
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.data.count))
        writer.writeBytes(body.data)
        return writer.data
    }
}
