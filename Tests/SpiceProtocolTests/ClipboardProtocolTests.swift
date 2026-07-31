import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("VDAgent UTF-8 clipboard wire protocol")
struct ClipboardProtocolTests {
    @Test func roundTripsCapabilitiesAndClipboardCommands() throws {
        let commands: [VDAgentClipboardCommand] = [
            .announceCapabilities(requestReply: true, capabilities: .utf8Clipboard),
            .grab(types: [VDAgentClipboardType.utf8Text.rawValue]),
            .request(type: VDAgentClipboardType.utf8Text.rawValue),
            .data(
                type: VDAgentClipboardType.utf8Text.rawValue,
                data: Data("hello".utf8)
            ),
            .release,
        ]

        for command in commands {
            let message = try VDAgentClipboardCodec.encode(command, opaque: 42)
            #expect(message.protocolID == 1)
            #expect(message.opaque == 42)
            #expect(try VDAgentClipboardCodec.decode(message) == command)
        }

        let capabilityMessage = try VDAgentClipboardCodec.encode(commands[0])
        #expect(capabilityMessage.data == Data([1, 0, 0, 0, 0x28, 0, 0, 0]))

        let desktopMessage = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopIntegration
        ))
        #expect(desktopMessage.data == Data([1, 0, 0, 0, 0xae, 0x50, 0, 0]))
    }

    @Test func rejectsMalformedFixedAndVectorPayloads() {
        #expect(throws: WireError.truncated(expected: 4, remaining: 3)) {
            try VDAgentClipboardCodec.decode(message(
                type: .announceCapabilities,
                data: Data(repeating: 0, count: 3)
            ))
        }
        #expect(throws: WireError.invalidSize(1)) {
            try VDAgentClipboardCodec.decode(message(
                type: .announceCapabilities,
                data: Data(repeating: 0, count: 5)
            ))
        }
        #expect(throws: WireError.invalidSize(0)) {
            try VDAgentClipboardCodec.decode(message(type: .clipboardGrab, data: Data()))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try VDAgentClipboardCodec.decode(message(
                type: .clipboardRequest,
                data: Data(repeating: 0, count: 5)
            ))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try VDAgentClipboardCodec.decode(message(
                type: .clipboardRelease,
                data: Data([0])
            ))
        }
    }

    @Test func ignoresUnknownProtocolOrMessageType() throws {
        #expect(try VDAgentClipboardCodec.decode(VDAgentMessage(
            protocolID: 2,
            type: VDAgentMessageType.clipboard.rawValue,
            data: Data()
        )) == nil)
        #expect(try VDAgentClipboardCodec.decode(VDAgentMessage(
            type: 999,
            data: Data()
        )) == nil)
    }

    private func message(type: VDAgentMessageType, data: Data) -> VDAgentMessage {
        VDAgentMessage(type: type.rawValue, data: data)
    }
}
