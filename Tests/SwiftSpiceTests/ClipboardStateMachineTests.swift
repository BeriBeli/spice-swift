import Foundation
import Testing
@testable import SpiceProtocol
@testable import SwiftSpice

@Suite("VDAgent clipboard ownership state machine")
struct ClipboardStateMachineTests {
    @Test func disabledClipboardAdvertisesOnlyNonPasteboardServices() throws {
        var state = ClipboardStateMachine(maximumTextBytes: 100, clipboardEnabled: false)
        #expect(state.connected() == [.send(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopServicesWithoutClipboard
        ))])
        #expect(try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        )).isEmpty)
        #expect(!state.isReady)
        #expect(try state.receive(.grab(types: [
            VDAgentClipboardType.utf8Text.rawValue,
        ])).isEmpty)

        #expect(state.setClipboardEnabled(true) == [
            .send(.announceCapabilities(
                requestReply: true,
                capabilities: .desktopIntegration
            )),
            .emit(.ready),
        ])
        #expect(state.isReady)
    }

    @Test func negotiatesCapabilitiesAndBecomesReady() throws {
        var state = ClipboardStateMachine(maximumTextBytes: 100)

        let announcement = state.connected()
        #expect(announcement == [.send(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopIntegration
        ))])
        if case let .send(command) = announcement[0] {
            state.didSend(command)
        }
        #expect(state.announcementIfNeeded().isEmpty)

        #expect(try state.receive(.announceCapabilities(
            requestReply: true,
            capabilities: .utf8Clipboard
        )) == [
            .send(.announceCapabilities(
                requestReply: false,
                capabilities: .desktopIntegration
            )),
            .emit(.ready),
        ])
        #expect(state.isReady)
    }

    @Test func acceptsLinuxDemandClipboardWithoutLegacyClipboardBit() throws {
        var state = ClipboardStateMachine(maximumTextBytes: 100)
        _ = state.connected()
        let linuxCapabilities = VDAgentCapabilities(words: [
            UInt32(1) << UInt32(VDAgentCapability.clipboardByDemand.rawValue),
        ])

        #expect(try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: linuxCapabilities
        )) == [.emit(.ready)])
        #expect(state.isReady)
    }

    @Test func offersLocalTextAndAnswersDemandRequest() throws {
        var state = try readyState()
        let bytes = Data("local text".utf8)

        #expect(state.localPasteboardChanged(changeCount: 1, text: "local text") == [
            .send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])),
            .emit(.localTextOffered(byteCount: bytes.count)),
        ])
        #expect(try state.receive(.request(
            type: VDAgentClipboardType.utf8Text.rawValue
        )) == [.send(.data(
            type: VDAgentClipboardType.utf8Text.rawValue,
            data: bytes
        ))])
    }

    @Test func requestsGuestTextWritesItAndSuppressesPasteboardEcho() throws {
        var state = try readyState()

        #expect(try state.receive(.grab(types: [
            VDAgentClipboardType.utf8Text.rawValue,
        ])) == [.send(.request(type: VDAgentClipboardType.utf8Text.rawValue))])
        #expect(try state.receive(.data(
            type: VDAgentClipboardType.utf8Text.rawValue,
            data: Data("guest text".utf8)
        )) == [
            .writeGuestText("guest text"),
            .emit(.guestText("guest text")),
        ])

        state.didWriteGuestText(changeCount: 7)
        #expect(state.localPasteboardChanged(changeCount: 7, text: "guest text").isEmpty)
    }

    @Test func successiveGuestGrabImplicitlyReplacesLocalOwnership() throws {
        var state = try readyState()
        _ = state.localPasteboardChanged(changeCount: 1, text: "local")

        #expect(try state.receive(.grab(types: [99])).isEmpty)
        #expect(try state.receive(.request(
            type: VDAgentClipboardType.utf8Text.rawValue
        )) == [.send(.data(type: VDAgentClipboardType.none.rawValue, data: Data()))])
    }

    @Test func rejectsOversizedLocalTextAndReleasesPriorGrab() throws {
        var state = try readyState(maximumTextBytes: 3)
        _ = state.localPasteboardChanged(changeCount: 1, text: "ok")

        #expect(state.localPasteboardChanged(changeCount: 2, text: "four") == [
            .send(.release),
            .emit(.oversizedLocalText(byteCount: 4, maximum: 3)),
        ])
    }

    @Test func rejectsUnsolicitedOrInvalidGuestData() throws {
        var state = try readyState()
        #expect(throws: ClipboardStateMachineFailure(
            error: .invalidAgentMessage("unsolicited clipboard data"),
            category: .unsolicitedData
        )) {
            try state.receive(.data(
                type: VDAgentClipboardType.utf8Text.rawValue,
                data: Data("unexpected".utf8)
            ))
        }

        _ = try state.receive(.grab(types: [VDAgentClipboardType.utf8Text.rawValue]))
        #expect(throws: ClipboardStateMachineFailure(
            error: .invalidUTF8,
            category: .invalidUTF8
        )) {
            try state.receive(.data(
                type: VDAgentClipboardType.utf8Text.rawValue,
                data: Data([0xff])
            ))
        }
    }

    @Test func reconnectAllowsSamePasteboardChangeToBeOfferedAgain() throws {
        var state = try readyState()
        _ = state.localPasteboardChanged(changeCount: 5, text: "same")
        _ = state.disconnected()
        _ = state.connected()
        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .utf8Clipboard
        ))

        #expect(state.localPasteboardChanged(changeCount: 5, text: "same") == [
            .send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])),
            .emit(.localTextOffered(byteCount: 4)),
        ])
    }

    @Test func repeatedCapabilitiesDoNotRepeatActiveLocalGrab() throws {
        var state = try readyState()
        _ = state.localPasteboardChanged(changeCount: 1, text: "local")

        #expect(try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .utf8Clipboard
        )).isEmpty)
    }

    @Test func monitorSupportUsesLegacyBaselineThenExplicitCapabilities() throws {
        var state = ClipboardStateMachine(maximumTextBytes: 100)
        _ = state.connected()
        #expect(state.supportsMonitorConfiguration)

        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .utf8Clipboard
        ))
        #expect(state.hasExplicitPeerCapabilities)
        #expect(!state.supportsMonitorConfiguration)
    }

    @Test func fileTransferWaitsForExplicitCapabilitiesAndHonorsDisableBit() throws {
        var state = ClipboardStateMachine(maximumTextBytes: 100)
        _ = state.connected()
        #expect(!state.hasFileTransferCapabilityState)
        #expect(!state.supportsFileTransfer)

        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .desktopIntegration
        ))
        #expect(state.hasFileTransferCapabilityState)
        #expect(state.supportsFileTransfer)

        let disabled = VDAgentCapabilities(words: [
            UInt32(1) << UInt32(VDAgentCapability.fileTransferDisabled.rawValue),
        ])
        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: disabled
        ))
        #expect(!state.supportsFileTransfer)
    }

    private func readyState(
        maximumTextBytes: Int = 100
    ) throws -> ClipboardStateMachine {
        var state = ClipboardStateMachine(maximumTextBytes: maximumTextBytes)
        _ = state.connected()
        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .utf8Clipboard
        ))
        return state
    }
}
