import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("VDAgent UTF-8 clipboard wire protocol")
struct ClipboardProtocolTests {
    @Test func extendedCapabilitiesKeepOfficialWireIndicesAndRemainOptIn() throws {
        #expect(VDAgentCapability.maxClipboard.rawValue == 10)
        #expect(VDAgentCapability.clipboardNoReleaseOnRegrab.rawValue == 16)
        #expect(VDAgentCapability.clipboardGrabSerial.rawValue == 17)
        #expect(!VDAgentCapabilities.desktopIntegration.contains(.maxClipboard))
        #expect(!VDAgentCapabilities.desktopIntegration.contains(
            .clipboardNoReleaseOnRegrab
        ))
        #expect(!VDAgentCapabilities.desktopIntegration.contains(.clipboardGrabSerial))

        let extended = VDAgentCapabilities(words: [
            (UInt32(1) << 10) | (UInt32(1) << 16) | (UInt32(1) << 17),
        ])
        let message = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: false,
            capabilities: extended
        ))
        #expect(message.data == Data([
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x04, 0x03, 0x00,
        ]))
    }

    @Test func roundTripsCapabilitiesAndClipboardCommands() throws {
        let commands: [VDAgentClipboardCommand] = [
            .announceCapabilities(requestReply: true, capabilities: .utf8Clipboard),
            .grab(types: [VDAgentClipboardType.utf8Text.rawValue]),
            .serialGrab(serial: 0xffff_fffe, types: [
                VDAgentClipboardType.utf8Text.rawValue,
            ]),
            .request(type: VDAgentClipboardType.utf8Text.rawValue),
            .data(
                type: VDAgentClipboardType.utf8Text.rawValue,
                data: Data("hello".utf8)
            ),
            .release,
            .maxClipboard(-1),
        ]

        for command in commands {
            let message = try VDAgentClipboardCodec.encode(command, opaque: 42)
            #expect(message.protocolID == 1)
            #expect(message.opaque == 42)
            let hasSerial: Bool
            if case .serialGrab = command {
                hasSerial = true
            } else {
                hasSerial = false
            }
            #expect(try VDAgentClipboardCodec.decode(
                message,
                grabHasSerial: hasSerial
            ) == command)
        }

        let capabilityMessage = try VDAgentClipboardCodec.encode(commands[0])
        #expect(capabilityMessage.data == Data([1, 0, 0, 0, 0x28, 0, 0, 0]))

        let desktopMessage = try VDAgentClipboardCodec.encode(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopIntegration
        ))
        #expect(desktopMessage.data == Data([1, 0, 0, 0, 0xae, 0x50, 0, 0]))

        let serialGrab = try VDAgentClipboardCodec.encode(.serialGrab(
            serial: 0x1234_5678,
            types: [VDAgentClipboardType.utf8Text.rawValue]
        ))
        #expect(serialGrab.data == Data([
            0x78, 0x56, 0x34, 0x12,
            0x01, 0x00, 0x00, 0x00,
        ]))

        let unlimited = try VDAgentClipboardCodec.encode(.maxClipboard(-1))
        #expect(unlimited.type == VDAgentMessageType.maxClipboard.rawValue)
        #expect(unlimited.data == Data([0xff, 0xff, 0xff, 0xff]))
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
        #expect(throws: WireError.invalidSize(0)) {
            try VDAgentClipboardCodec.decode(
                message(type: .clipboardGrab, data: Data(repeating: 0, count: 4)),
                grabHasSerial: true
            )
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try VDAgentClipboardCodec.decode(message(
                type: .maxClipboard,
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
