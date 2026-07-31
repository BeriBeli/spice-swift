import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Generated protocol messages")
struct GeneratedMessageTests {
    @Test func everyGeneratedMessageRoundTripsAndRejectsTruncation() throws {
        try verify(SpiceLinkHeader(
            magic: SpiceProtocolConstants.magic,
            majorVersion: 2,
            minorVersion: 2,
            size: 18
        ))
        try verify(SpiceLinkMessage(
            connectionID: 42,
            channelType: 1,
            channelID: 0,
            commonCapabilityWordCount: 1,
            channelCapabilityWordCount: 1,
            capabilitiesOffset: 18
        ))
        try verify(SpiceLinkReply(
            error: 0,
            publicKey: Data(repeating: 0xa5, count: 162),
            commonCapabilityWordCount: 1,
            channelCapabilityWordCount: 0,
            capabilitiesOffset: 178
        ))
        try verify(SpiceLinkAuthMechanism(authenticationMechanism: 1))
        try verify(SpiceLinkEncryptedTicket(encryptedData: Data(repeating: 0x5a, count: 128)))
        try verify(SpiceLinkResult(error: 0))
        try verify(SpiceChannelID(type: 2, id: 0))
        try verify(SpiceMsgSetAck(generation: 7, window: 20))
        try verify(SpiceMsgPing(id: 9, time: 123_456))
        try verify(SpiceMsgDisconnect(timeStamp: 123, reason: 7))
        try verify(SpiceMsgcAckSync(generation: 7))
        try verify(SpiceMsgcAck())
        try verify(SpiceMsgcPong(id: 9, time: 123_456))
        try verify(SpiceMsgcDisconnect(timeStamp: 123, reason: 7))
        try verify(SpiceMsgMainInit(
            sessionID: 11,
            displayChannelsHint: 1,
            supportedMouseModes: 3,
            currentMouseMode: 2,
            agentConnected: 0,
            agentTokens: 0,
            multimediaTime: 99,
            ramHint: 64 * 1024 * 1024
        ))
        try verify(SpiceMsgMainChannelsList(channels: [
            SpiceChannelID(type: 2, id: 0),
            SpiceChannelID(type: 3, id: 0),
            SpiceChannelID(type: 4, id: 0),
        ]))
        try verify(SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 2))
        try verify(SpiceMsgcMainAttachChannels())
        try verify(SpiceMsgcMainMouseModeRequest(mode: 2))
        try verify(SpiceMsgDisplaySurfaceCreate(
            surfaceID: 7,
            width: 1_920,
            height: 1_080,
            format: 32,
            flags: 1
        ))
        try verify(SpiceMsgDisplaySurfaceDestroy(surfaceID: 7))
        try verify(SpiceMsgcDisplayInit(
            pixmapCacheID: 1,
            pixmapCacheSize: 16 * 1_024 * 1_024,
            glzDictionaryID: 1,
            glzDictionaryWindowSize: 8 * 1_024 * 1_024
        ))
        try verify(SpiceMsgcInputsKeyDown(code: 0x1e))
        try verify(SpiceMsgcInputsKeyUp(code: 0x9e))
        try verify(SpiceMsgcInputsKeyModifiers(modifiers: 0x03))
        try verify(SpiceMsgcInputsMouseMotion(dx: -4, dy: 7, buttonsState: 1))
        try verify(SpiceMsgcInputsMousePosition(
            x: 100,
            y: 200,
            buttonsState: 1,
            displayID: 0
        ))
        try verify(SpiceMsgcInputsMousePress(button: 1, buttonsState: 1))
        try verify(SpiceMsgcInputsMouseRelease(button: 1, buttonsState: 0))
        try verify(SpiceMsgInputsInit(keyboardModifiers: 0x02))
        try verify(SpiceMsgInputsKeyModifiers(modifiers: 0x03))
        try verify(SpiceMsgInputsMouseMotionAck())
    }

    @Test func fixedSizeByteFieldsValidateBeforeEncoding() {
        let invalid = SpiceLinkEncryptedTicket(encryptedData: Data(repeating: 0, count: 127))
        var writer = ByteWriter()

        #expect(throws: WireError.invalidSize(127)) {
            try invalid.encode(to: &writer)
        }
    }

    @Test func channelListRejectsCountBeyondRemainingBody() throws {
        var writer = ByteWriter()
        writer.writeUInt32LE(2)
        writer.writeUInt8(1)
        writer.writeUInt8(0)
        var reader = try ByteReader(writer.data)

        #expect(throws: WireError.invalidSize(2)) {
            try SpiceMsgMainChannelsList.decode(from: &reader)
        }
    }

    @Test func linkHeaderValidation() throws {
        try SpiceLinkHeader(
            magic: SpiceProtocolConstants.magic,
            majorVersion: 2,
            minorVersion: 2,
            size: 0
        ).validate()

        #expect(throws: WireError.invalidMagic(0)) {
            try SpiceLinkHeader(magic: 0, majorVersion: 2, minorVersion: 2, size: 0).validate()
        }

        try SpiceLinkHeader(
            magic: SpiceProtocolConstants.magic,
            majorVersion: 2,
            minorVersion: 99,
            size: 0
        ).validate()
    }

    private func verify<Message: SpiceGeneratedMessage>(_ message: Message) throws {
        var writer = ByteWriter()
        try message.encode(to: &writer)

        var reader = try ByteReader(writer.data)
        let decoded = try Message.decode(from: &reader)
        #expect(decoded == message)
        try reader.requireFullyConsumed()

        guard !writer.data.isEmpty else {
            return
        }
        for length in 0..<writer.data.count {
            var truncatedReader = try ByteReader(writer.data.prefix(length))
            #expect(throws: WireError.self) {
                try Message.decode(from: &truncatedReader)
            }
        }
    }
}
