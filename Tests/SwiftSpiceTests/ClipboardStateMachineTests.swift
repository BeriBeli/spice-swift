import Foundation
import Testing
@testable import SpiceProtocol
@testable import SwiftSpice

@Suite("VDAgent clipboard ownership state machine")
struct ClipboardStateMachineTests {
    @Test func ownershipCapabilitiesUseSerialRegrabWithoutRelease() throws {
        var state = try ownershipReadyState()
        let first = SpiceClipboardOfferID(rawValue: 20)
        let second = SpiceClipboardOfferID(rawValue: 21)

        #expect(try state.offerManualText("one", id: first, leaseGeneration: 1) == [
            .send(.serialGrab(
                serial: 1,
                types: [VDAgentClipboardType.utf8Text.rawValue]
            )),
            .emit(.localTextOffered(byteCount: 3)),
        ])
        #expect(try state.offerManualText("two", id: second, leaseGeneration: 2) == [
            .manualOffer(.emit(.init(id: first, result: .superseded))),
            .send(.serialGrab(
                serial: 2,
                types: [VDAgentClipboardType.utf8Text.rawValue]
            )),
            .emit(.localTextOffered(byteCount: 3)),
        ])
    }

    @Test func peerWithoutNoReleaseCapabilityGetsReleaseBeforeSerialRegrab() throws {
        var state = try ownershipReadyState(noRelease: false)
        _ = try state.offerManualText(
            "one",
            id: SpiceClipboardOfferID(rawValue: 22),
            leaseGeneration: 1
        )
        let actions = try state.offerManualText(
            "two",
            id: SpiceClipboardOfferID(rawValue: 23),
            leaseGeneration: 2
        )
        #expect(Array(actions.dropFirst()) == [
            .send(.release),
            .send(.serialGrab(
                serial: 2,
                types: [VDAgentClipboardType.utf8Text.rawValue]
            )),
            .emit(.localTextOffered(byteCount: 3)),
        ])
    }

    @Test func peerGrabSerialDropsEqualAndStaleValuesButAcceptsWraparound() throws {
        var state = try ownershipReadyState()
        #expect(try state.receive(.serialGrab(
            serial: 0xffff_fffe,
            types: [VDAgentClipboardType.utf8Text.rawValue]
        )).isEmpty)

        let id = SpiceClipboardOfferID(rawValue: 24)
        _ = try state.offerManualText("current", id: id, leaseGeneration: 1)
        #expect(try state.receive(.serialGrab(
            serial: 0xffff_fffe,
            types: [VDAgentClipboardType.utf8Text.rawValue]
        )).isEmpty)
        #expect(try state.receive(.serialGrab(
            serial: 0xffff_fffd,
            types: [VDAgentClipboardType.utf8Text.rawValue]
        )).isEmpty)
        #expect(try state.receive(.serialGrab(
            serial: 1,
            types: [VDAgentClipboardType.utf8Text.rawValue]
        )) == [.manualOffer(.emit(.init(id: id, result: .superseded)))])
    }

    @Test func negotiatedGrabShapeIsEnforcedInBothDirections() throws {
        var serialState = try ownershipReadyState()
        #expect(throws: SpiceClipboardError.invalidAgentMessage(
            "clipboard GRAB is missing negotiated serial"
        )) {
            try serialState.receive(.grab(types: [
                VDAgentClipboardType.utf8Text.rawValue,
            ]))
        }

        var legacyState = try manualReadyState()
        #expect(throws: SpiceClipboardError.invalidAgentMessage(
            "clipboard GRAB serial received before capability negotiation"
        )) {
            try legacyState.receive(.serialGrab(
                serial: 1,
                types: [VDAgentClipboardType.utf8Text.rawValue]
            ))
        }
    }

    @Test func droppingOwnershipCapabilitiesRestoresLegacyGrabAndRelease() throws {
        var state = try ownershipReadyState()
        #expect(state.expectsPeerGrabSerial)
        #expect(try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .utf8Clipboard
        )).isEmpty)
        #expect(!state.expectsPeerGrabSerial)

        let first = SpiceClipboardOfferID(rawValue: 25)
        let second = SpiceClipboardOfferID(rawValue: 26)
        #expect(try state.offerManualText("one", id: first, leaseGeneration: 1) == [
            .send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])),
            .emit(.localTextOffered(byteCount: 3)),
        ])
        #expect(try state.offerManualText("two", id: second, leaseGeneration: 2) == [
            .manualOffer(.emit(.init(id: first, result: .superseded))),
            .send(.release),
            .send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])),
            .emit(.localTextOffered(byteCount: 3)),
        ])
        #expect(try state.receive(.grab(types: [
            VDAgentClipboardType.utf8Text.rawValue,
        ])) == [.manualOffer(.emit(.init(id: second, result: .superseded)))])
    }

    @Test func manualOnlyModeNegotiatesClipboardWithoutReadingGuestData() throws {
        var state = ClipboardStateMachine(
            maximumTextBytes: 100,
            clipboardEnabled: false,
            manualClipboardOffersEnabled: true
        )
        #expect(state.connected() == [.send(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopIntegration
        ))])
        #expect(try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .utf8Clipboard
        )) == [.emit(.ready)])

        let id = SpiceClipboardOfferID(rawValue: 1)
        _ = try state.offerManualText("private", id: id, leaseGeneration: 4)
        #expect(try state.receive(.grab(types: [
            VDAgentClipboardType.utf8Text.rawValue,
        ])) == [.manualOffer(.emit(.init(id: id, result: .superseded)))])
        #expect(try state.receive(.data(
            type: VDAgentClipboardType.utf8Text.rawValue,
            data: Data("guest".utf8)
        )).isEmpty)
    }

    @Test func manualOfferRequestAndPhysicalSendHaveDistinctResults() throws {
        var state = try manualReadyState()
        let id = SpiceClipboardOfferID(rawValue: 7)
        let data = Data("中文🙂".utf8)

        #expect(try state.offerManualText("中文🙂", id: id, leaseGeneration: 9) == [
            .send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])),
            .emit(.localTextOffered(byteCount: data.count)),
        ])
        #expect(try state.receive(.request(
            type: VDAgentClipboardType.utf8Text.rawValue
        )) == [
            .manualOffer(.emit(.init(id: id, result: .requested))),
            .manualOffer(.sendData(
                .data(type: VDAgentClipboardType.utf8Text.rawValue, data: data),
                id: id,
                leaseGeneration: 9
            )),
        ])
        #expect(state.didSendManualOfferData(id: id, leaseGeneration: 9) == [
            .manualOffer(.emit(.init(id: id, result: .dataSent))),
        ])
        #expect(state.didSendManualOfferData(id: id, leaseGeneration: 9).isEmpty)
    }

    @Test func replacingRequestedOfferCompletesOldOfferOnlyOnce() throws {
        var state = try manualReadyState()
        let first = SpiceClipboardOfferID(rawValue: 10)
        let second = SpiceClipboardOfferID(rawValue: 11)
        _ = try state.offerManualText("first", id: first, leaseGeneration: 2)
        _ = try state.receive(.request(type: VDAgentClipboardType.utf8Text.rawValue))

        #expect(try state.offerManualText("second", id: second, leaseGeneration: 3) == [
            .manualOffer(.emit(.init(id: first, result: .superseded))),
            .send(.release),
            .send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])),
            .emit(.localTextOffered(byteCount: 6)),
        ])
        #expect(state.didSendManualOfferData(id: first, leaseGeneration: 2).isEmpty)
        #expect(state.revokeManualOffer(id: second, leaseGeneration: 3) == [
            .manualOffer(.emit(.init(id: second, result: .revoked))),
            .send(.release),
        ])
        #expect(state.revokeManualOffer(id: second, leaseGeneration: 3).isEmpty)
    }

    @Test func unchangedPasteboardCannotSupersedeManualOfferButRealChangeCan() throws {
        var state = try manualReadyState(generalPasteboard: true)
        _ = state.localPasteboardChanged(changeCount: 5, text: "old")
        let id = SpiceClipboardOfferID(rawValue: 12)
        _ = try state.offerManualText("private", id: id, leaseGeneration: 1)

        #expect(state.localPasteboardChanged(changeCount: 5, text: "old").isEmpty)
        #expect(state.localPasteboardChanged(changeCount: 6, text: "new") == [
            .manualOffer(.emit(.init(id: id, result: .superseded))),
            .send(.release),
            .send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])),
            .emit(.localTextOffered(byteCount: 3)),
        ])
    }

    @Test func disconnectRevokesManualOfferWithoutSendingRelease() throws {
        var state = try manualReadyState()
        let id = SpiceClipboardOfferID(rawValue: 15)
        _ = try state.offerManualText("private", id: id, leaseGeneration: 1)

        #expect(state.disconnected() == [
            .manualOffer(.emit(.init(id: id, result: .revoked))),
            .emit(.unavailable),
        ])
    }

    @Test func modeChangesPreserveIndependentClipboardAuthorities() throws {
        var state = try manualReadyState(generalPasteboard: true)
        let id = SpiceClipboardOfferID(rawValue: 13)
        _ = try state.offerManualText("private", id: id, leaseGeneration: 8)

        #expect(state.setClipboardModes(
            generalPasteboardSynchronizationEnabled: false,
            manualClipboardOffersEnabled: true
        ).isEmpty)
        #expect(try state.receive(.grab(types: [
            VDAgentClipboardType.utf8Text.rawValue,
        ])) == [.manualOffer(.emit(.init(id: id, result: .superseded)))])

        let next = SpiceClipboardOfferID(rawValue: 14)
        _ = try state.offerManualText("next", id: next, leaseGeneration: 9)
        #expect(state.setClipboardModes(
            generalPasteboardSynchronizationEnabled: false,
            manualClipboardOffersEnabled: false
        ) == [
            .manualOffer(.emit(.init(id: next, result: .revoked))),
            .send(.release),
            .send(.announceCapabilities(
                requestReply: true,
                capabilities: .desktopServicesWithoutClipboard
            )),
            .emit(.unavailable),
        ])
    }

    @Test func manualOfferHonorsNegotiatedPeerLimit() throws {
        var state = ClipboardStateMachine(
            maximumTextBytes: 100,
            clipboardEnabled: false,
            manualClipboardOffersEnabled: true,
            negotiatesClipboardLimit: true
        )
        let actions = state.connected()
        if case let .send(command) = actions.first {
            state.didSend(command)
        }
        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: clipboardCapabilities(maximum: true)
        ))
        _ = try state.receive(.maxClipboard(3))

        #expect(throws: SpiceClipboardError.invalidAgentMessage(
            "manual text size 4 exceeds 3"
        )) {
            try state.offerManualText(
                "four",
                id: SpiceClipboardOfferID(rawValue: 16),
                leaseGeneration: 1
            )
        }
    }

    @Test func extendedLimitNegotiationIsOptInAndAdvertisesLocalReceiveLimit() throws {
        var legacy = ClipboardStateMachine(maximumTextBytes: 100)
        #expect(legacy.connected() == [.send(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopIntegration
        ))])

        var state = ClipboardStateMachine(
            maximumTextBytes: 100,
            negotiatesClipboardLimit: true
        )
        #expect(state.connected() == [.send(.announceCapabilities(
            requestReply: true,
            capabilities: .desktopIntegrationWithClipboardLimit
        ))])
        #expect(state.effectiveManualOfferMaximumTextBytes == 16_000)

        #expect(try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: clipboardCapabilities(maximum: true)
        )) == [
            .send(.maxClipboard(100)),
            .emit(.ready),
        ])
        #expect(state.effectiveManualOfferMaximumTextBytes == 16_000)
    }

    @Test func peerLimitUsesSignedValuesAndResetsWhenCapabilityDrops() throws {
        var state = try extendedReadyState()

        #expect(try state.receive(.maxClipboard(0)).isEmpty)
        #expect(state.effectiveManualOfferMaximumTextBytes == 0)
        #expect(try state.receive(.maxClipboard(7)).isEmpty)
        #expect(state.effectiveManualOfferMaximumTextBytes == 7)
        #expect(try state.receive(.maxClipboard(-1)).isEmpty)
        #expect(state.effectiveManualOfferMaximumTextBytes == 16_000)
        #expect(throws: SpiceClipboardError.invalidAgentMessage(
            "invalid MAX_CLIPBOARD value -2"
        )) {
            try state.receive(.maxClipboard(-2))
        }
        #expect(state.effectiveManualOfferMaximumTextBytes == 16_000)

        #expect(try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .utf8Clipboard
        )).isEmpty)
        #expect(state.effectiveManualOfferMaximumTextBytes == 16_000)
        #expect(throws: SpiceClipboardError.invalidAgentMessage(
            "MAX_CLIPBOARD received before capability negotiation"
        )) {
            try state.receive(.maxClipboard(1))
        }
    }

    @Test func peerLimitClearsAcrossReconnectAndCapWithoutValueUsesLocalPolicy() throws {
        var state = try extendedReadyState()
        _ = try state.receive(.maxClipboard(9))
        #expect(state.effectiveManualOfferMaximumTextBytes == 9)

        _ = state.disconnected()
        _ = state.connected()
        #expect(state.effectiveManualOfferMaximumTextBytes == 16_000)
        #expect(try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: clipboardCapabilities(maximum: true)
        )) == [
            .send(.maxClipboard(100)),
            .emit(.ready),
        ])
        #expect(state.effectiveManualOfferMaximumTextBytes == 16_000)
    }

    @Test func rejectsPeerLimitWhenLocalLimitCapabilityIsDisabled() throws {
        var state = try readyState()
        #expect(throws: SpiceClipboardError.invalidAgentMessage(
            "MAX_CLIPBOARD received before capability negotiation"
        )) {
            try state.receive(.maxClipboard(1))
        }
    }

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
        #expect(throws: SpiceClipboardError.invalidAgentMessage(
            "unsolicited clipboard data"
        )) {
            try state.receive(.data(
                type: VDAgentClipboardType.utf8Text.rawValue,
                data: Data("unexpected".utf8)
            ))
        }

        _ = try state.receive(.grab(types: [VDAgentClipboardType.utf8Text.rawValue]))
        #expect(throws: SpiceClipboardError.invalidUTF8) {
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

    private func extendedReadyState() throws -> ClipboardStateMachine {
        var state = ClipboardStateMachine(
            maximumTextBytes: 100,
            negotiatesClipboardLimit: true
        )
        _ = state.connected()
        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: clipboardCapabilities(maximum: true)
        ))
        return state
    }

    private func manualReadyState(
        generalPasteboard: Bool = false
    ) throws -> ClipboardStateMachine {
        var state = ClipboardStateMachine(
            maximumTextBytes: 100,
            clipboardEnabled: generalPasteboard,
            manualClipboardOffersEnabled: true
        )
        let actions = state.connected()
        if case let .send(command) = actions.first {
            state.didSend(command)
        }
        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: .utf8Clipboard
        ))
        return state
    }

    private func ownershipReadyState(
        noRelease: Bool = true
    ) throws -> ClipboardStateMachine {
        var state = ClipboardStateMachine(
            maximumTextBytes: 100,
            clipboardEnabled: false,
            manualClipboardOffersEnabled: true,
            negotiatesClipboardOwnership: true
        )
        let actions = state.connected()
        if case let .send(command) = actions.first {
            state.didSend(command)
        }
        _ = try state.receive(.announceCapabilities(
            requestReply: false,
            capabilities: clipboardOwnershipCapabilities(noRelease: noRelease)
        ))
        return state
    }

    private func clipboardCapabilities(maximum: Bool) -> VDAgentCapabilities {
        var word = UInt32(1) << UInt32(VDAgentCapability.clipboardByDemand.rawValue)
        if maximum {
            word |= UInt32(1) << UInt32(VDAgentCapability.maxClipboard.rawValue)
        }
        return VDAgentCapabilities(words: [word])
    }

    private func clipboardOwnershipCapabilities(
        noRelease: Bool = true
    ) -> VDAgentCapabilities {
        var word = UInt32(1) << UInt32(VDAgentCapability.clipboardByDemand.rawValue)
        word |= UInt32(1) << UInt32(VDAgentCapability.maxClipboard.rawValue)
        word |= UInt32(1) << UInt32(VDAgentCapability.clipboardGrabSerial.rawValue)
        if noRelease {
            word |= UInt32(1) << UInt32(
                VDAgentCapability.clipboardNoReleaseOnRegrab.rawValue
            )
        }
        return VDAgentCapabilities(words: [word])
    }
}
