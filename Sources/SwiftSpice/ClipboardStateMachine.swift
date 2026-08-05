import Foundation
import SpiceProtocol

public enum SpiceClipboardError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyRunning
    case invalidAgentMessage(String)
    case invalidUTF8
    case pasteboardWriteFailed
    case transport(SpiceError)

    public var description: String {
        switch self {
        case .alreadyRunning:
            "clipboard synchronization is already running"
        case let .invalidAgentMessage(reason):
            "invalid clipboard agent message: \(reason)"
        case .invalidUTF8:
            "guest clipboard is not valid UTF-8"
        case .pasteboardWriteFailed:
            "macOS pasteboard rejected the UTF-8 text"
        case let .transport(error):
            "clipboard transport failed: \(error)"
        }
    }
}

public enum SpiceClipboardEvent: Sendable, Equatable {
    case ready
    case unavailable
    case guestText(String)
    case localTextOffered(byteCount: Int)
    case oversizedLocalText(byteCount: Int, maximum: Int)
    case failed(SpiceClipboardError)
}

public struct SpiceClipboardOfferID: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// `requested` is an observable intermediate result. The remaining cases are
/// terminal, and a manual offer emits at most one of them.
public enum SpiceClipboardOfferResult: Sendable, Equatable {
    case superseded
    case revoked
    case requested
    case dataSent
}

public struct SpiceClipboardOfferEvent: Sendable, Equatable {
    public let id: SpiceClipboardOfferID
    public let result: SpiceClipboardOfferResult

    public init(id: SpiceClipboardOfferID, result: SpiceClipboardOfferResult) {
        self.id = id
        self.result = result
    }
}

package struct ClipboardStateMachine: Sendable {
    package static let manualOfferMaximumTextBytes = 16_000

    package enum Action: Sendable, Equatable {
        case send(VDAgentClipboardCommand)
        case manualOffer(ManualOfferAction)
        case writeGuestText(String)
        case emit(SpiceClipboardEvent)
    }

    package enum ManualOfferAction: Sendable, Equatable {
        case sendData(
            VDAgentClipboardCommand,
            id: SpiceClipboardOfferID,
            leaseGeneration: UInt64
        )
        case emit(SpiceClipboardOfferEvent)
    }

    private enum LocalSource: Sendable, Equatable {
        case generalPasteboard(changeCount: Int)
        case manual(id: SpiceClipboardOfferID, leaseGeneration: UInt64)
    }

    private struct ManualOfferState: Sendable, Equatable {
        let id: SpiceClipboardOfferID
        let leaseGeneration: UInt64
        var requested = false
        var terminalResult: SpiceClipboardOfferResult?
    }

    private let maximumTextBytes: Int
    private let negotiatesClipboardLimit: Bool
    private let negotiatesClipboardOwnership: Bool
    private var generalPasteboardSynchronizationEnabled: Bool
    private var manualClipboardOffersEnabled: Bool
    private var agentConnected = false
    private var localCapabilitiesAnnounced = false
    private var peerCapabilities: VDAgentCapabilities?
    private var peerMaximumClipboardBytes: Int?
    private var wasReady = false
    private var localTextData: Data?
    private var localSource: LocalSource?
    private var manualOfferState: ManualOfferState?
    private var localGrabActive = false
    private var guestGrabActive = false
    private var awaitingGuestData = false
    private var lastPasteboardChangeCount: Int?
    private var lastPeerGrabSerial: UInt32?
    private var nextLocalGrabSerial: UInt32 = 1

    package init(maximumTextBytes: Int, clipboardEnabled: Bool = true) {
        self.init(
            maximumTextBytes: maximumTextBytes,
            clipboardEnabled: clipboardEnabled,
            manualClipboardOffersEnabled: false
        )
    }

    package init(
        maximumTextBytes: Int,
        clipboardEnabled: Bool = true,
        negotiatesClipboardLimit: Bool
    ) {
        self.init(
            maximumTextBytes: maximumTextBytes,
            clipboardEnabled: clipboardEnabled,
            manualClipboardOffersEnabled: false,
            negotiatesClipboardLimit: negotiatesClipboardLimit
        )
    }

    package init(
        maximumTextBytes: Int,
        clipboardEnabled: Bool = true,
        manualClipboardOffersEnabled: Bool,
        negotiatesClipboardLimit: Bool = false,
        negotiatesClipboardOwnership: Bool = false
    ) {
        self.maximumTextBytes = max(0, maximumTextBytes)
        generalPasteboardSynchronizationEnabled = clipboardEnabled
        self.manualClipboardOffersEnabled = manualClipboardOffersEnabled
        self.negotiatesClipboardLimit = negotiatesClipboardLimit
            || negotiatesClipboardOwnership
        self.negotiatesClipboardOwnership = negotiatesClipboardOwnership
    }

    package var isReady: Bool {
        guard clipboardNegotiationEnabled, agentConnected, let peerCapabilities else {
            return false
        }
        // Modern Linux spice-vdagent advertises the demand protocol without
        // also setting the legacy VD_AGENT_CAP_CLIPBOARD bit.
        return peerCapabilities.contains(.clipboardByDemand)
    }

    package var isAgentConnected: Bool {
        agentConnected
    }

    package var effectiveManualOfferMaximumTextBytes: Int {
        min(
            Self.manualOfferMaximumTextBytes,
            peerMaximumClipboardBytes ?? Self.manualOfferMaximumTextBytes
        )
    }

    package var expectsPeerGrabSerial: Bool {
        negotiatesClipboardOwnership
            && peerCapabilities?.contains(.clipboardGrabSerial) == true
    }

    /// MONITORS_CONFIG and REPLY are legacy baseline capabilities until the
    /// peer sends an explicit capability announcement.
    package var supportsMonitorConfiguration: Bool {
        guard agentConnected else {
            return false
        }
        guard let peerCapabilities else {
            return true
        }
        return peerCapabilities.contains(.monitorsConfig)
            && peerCapabilities.contains(.reply)
    }

    package var hasExplicitPeerCapabilities: Bool {
        peerCapabilities != nil
    }

    package var supportsSparseMonitorConfiguration: Bool {
        peerCapabilities?.contains(.sparseMonitorsConfig) == true
    }

    package var supportsMonitorPositions: Bool {
        peerCapabilities?.contains(.monitorsConfigPosition) == true
    }

    package var displayConfigurationSupport: SpiceDisplayConfigurationSupport {
        SpiceDisplayConfigurationSupport(
            agentConnected: agentConnected,
            hasExplicitPeerCapabilities: hasExplicitPeerCapabilities,
            supportsMonitorConfiguration: supportsMonitorConfiguration,
            supportsSparseMonitors: supportsSparseMonitorConfiguration,
            supportsMonitorPositions: supportsMonitorPositions
        )
    }

    package var hasFileTransferCapabilityState: Bool {
        agentConnected && peerCapabilities != nil
    }

    package var supportsFileTransfer: Bool {
        guard hasFileTransferCapabilityState else {
            return false
        }
        return peerCapabilities?.contains(.fileTransferDisabled) != true
    }

    package var supportsFileTransferDetailedErrors: Bool {
        peerCapabilities?.contains(.fileTransferDetailedErrors) == true
    }

    package mutating func connected() -> [Action] {
        resetConnectionState()
        agentConnected = true
        return announcementIfNeeded()
    }

    package mutating func disconnected() -> [Action] {
        let notify = wasReady
        let terminal = completeManualOfferIfNeeded(.revoked)
        resetConnectionState()
        return terminal + (notify ? [.emit(.unavailable)] : [])
    }

    package mutating func announcementIfNeeded() -> [Action] {
        guard agentConnected, !localCapabilitiesAnnounced else {
            return []
        }
        return [.send(.announceCapabilities(
            requestReply: true,
            capabilities: localCapabilities
        ))]
    }

    package mutating func setClipboardEnabled(_ enabled: Bool) -> [Action] {
        setClipboardModes(
            generalPasteboardSynchronizationEnabled: enabled,
            manualClipboardOffersEnabled: manualClipboardOffersEnabled
        )
    }

    package mutating func setClipboardModes(
        generalPasteboardSynchronizationEnabled generalEnabled: Bool,
        manualClipboardOffersEnabled manualEnabled: Bool
    ) -> [Action] {
        guard generalPasteboardSynchronizationEnabled != generalEnabled
                || manualClipboardOffersEnabled != manualEnabled else {
            return []
        }
        var actions: [Action] = []
        let wasNegotiating = clipboardNegotiationEnabled
        let disablesCurrentSource: Bool
        switch localSource {
        case .generalPasteboard:
            disablesCurrentSource = !generalEnabled
        case .manual:
            disablesCurrentSource = !manualEnabled
            if disablesCurrentSource {
                actions.append(contentsOf: completeManualOfferIfNeeded(.revoked))
            }
        case nil:
            disablesCurrentSource = false
        }
        if disablesCurrentSource, isReady, localGrabActive {
            actions.append(.send(.release))
        }
        if disablesCurrentSource {
            clearLocalOffer()
        }
        generalPasteboardSynchronizationEnabled = generalEnabled
        manualClipboardOffersEnabled = manualEnabled
        let isNegotiating = clipboardNegotiationEnabled
        if wasNegotiating != isNegotiating {
            localCapabilitiesAnnounced = false
        }
        if !generalEnabled {
            awaitingGuestData = false
        }
        if !isNegotiating {
            guestGrabActive = false
            awaitingGuestData = false
        }
        if agentConnected {
            actions.append(contentsOf: announcementIfNeeded())
        }
        if !isNegotiating, wasReady {
            wasReady = false
            actions.append(.emit(.unavailable))
        } else if isReady, !wasReady {
            wasReady = true
            actions.append(.emit(.ready))
        }
        return actions
    }

    package mutating func didSend(
        _ command: VDAgentClipboardCommand
    ) {
        if case .announceCapabilities = command {
            localCapabilitiesAnnounced = true
        }
    }

    package mutating func didSendManualOfferData(
        id: SpiceClipboardOfferID,
        leaseGeneration: UInt64
    ) -> [Action] {
        guard case let .manual(currentID, currentLeaseGeneration) = localSource,
              currentID == id,
              currentLeaseGeneration == leaseGeneration,
              manualOfferState?.id == id,
              manualOfferState?.leaseGeneration == leaseGeneration,
              manualOfferState?.requested == true else {
            return []
        }
        return completeManualOfferIfNeeded(.dataSent)
    }

    package mutating func receive(
        _ command: VDAgentClipboardCommand
    ) throws(SpiceClipboardError) -> [Action] {
        guard agentConnected else {
            throw .invalidAgentMessage("message received while agent is disconnected")
        }
        switch command {
        case let .announceCapabilities(requestReply, capabilities):
            peerCapabilities = capabilities
            if !capabilities.contains(.maxClipboard) {
                peerMaximumClipboardBytes = nil
            }
            if !capabilities.contains(.clipboardGrabSerial) {
                lastPeerGrabSerial = nil
            }
            var actions: [Action] = []
            if requestReply {
                actions.append(.send(.announceCapabilities(
                    requestReply: false,
                    capabilities: localCapabilities
                )))
            }
            if negotiatesClipboardLimit, capabilities.contains(.maxClipboard) {
                actions.append(.send(.maxClipboard(Int32(min(
                    maximumTextBytes,
                    Int(Int32.max)
                )))))
            }
            let ready = isReady
            if ready != wasReady {
                wasReady = ready
                actions.append(.emit(ready ? .ready : .unavailable))
            }
            if ready, !localGrabActive, let localTextData {
                localGrabActive = true
                actions.append(.send(makeLocalGrabCommand()))
                actions.append(.emit(.localTextOffered(byteCount: localTextData.count)))
            }
            return actions
        case let .grab(types):
            guard !expectsPeerGrabSerial else {
                throw .invalidAgentMessage("clipboard GRAB is missing negotiated serial")
            }
            return try receivePeerGrab(types: types, serial: nil)
        case let .serialGrab(serial, types):
            guard expectsPeerGrabSerial else {
                throw .invalidAgentMessage(
                    "clipboard GRAB serial received before capability negotiation"
                )
            }
            return try receivePeerGrab(types: types, serial: serial)
        case let .request(type):
            guard clipboardNegotiationEnabled else { return [] }
            try requireReady()
            guard type == VDAgentClipboardType.utf8Text.rawValue,
                  localGrabActive,
                  let localTextData else {
                return [.send(.data(type: VDAgentClipboardType.none.rawValue, data: Data()))]
            }
            if case let .manual(id, leaseGeneration) = localSource {
                var actions: [Action] = []
                if manualOfferState?.requested == false {
                    manualOfferState?.requested = true
                    actions.append(.manualOffer(.emit(SpiceClipboardOfferEvent(
                        id: id,
                        result: .requested
                    ))))
                }
                actions.append(.manualOffer(.sendData(
                    .data(type: type, data: localTextData),
                    id: id,
                    leaseGeneration: leaseGeneration
                )))
                return actions
            }
            return [.send(.data(type: type, data: localTextData))]
        case let .data(type, data):
            guard generalPasteboardSynchronizationEnabled else { return [] }
            try requireReady()
            guard awaitingGuestData, guestGrabActive else {
                throw .invalidAgentMessage("unsolicited clipboard data")
            }
            awaitingGuestData = false
            if type == VDAgentClipboardType.none.rawValue {
                return []
            }
            guard type == VDAgentClipboardType.utf8Text.rawValue else {
                throw .invalidAgentMessage("unexpected clipboard type \(type)")
            }
            guard data.count <= maximumTextBytes else {
                throw .invalidAgentMessage(
                    "guest text size \(data.count) exceeds \(maximumTextBytes)"
                )
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw .invalidUTF8
            }
            return [.writeGuestText(text), .emit(.guestText(text))]
        case .release:
            guard clipboardNegotiationEnabled else { return [] }
            try requireReady()
            guestGrabActive = false
            awaitingGuestData = false
            return []
        case let .maxClipboard(maximum):
            guard negotiatesClipboardLimit,
                  peerCapabilities?.contains(.maxClipboard) == true else {
                throw .invalidAgentMessage(
                    "MAX_CLIPBOARD received before capability negotiation"
                )
            }
            guard maximum >= -1 else {
                throw .invalidAgentMessage("invalid MAX_CLIPBOARD value \(maximum)")
            }
            peerMaximumClipboardBytes = maximum == -1
                ? Self.manualOfferMaximumTextBytes
                : Int(maximum)
            return []
        }
    }

    package mutating func localPasteboardChanged(
        changeCount: Int,
        text: String?
    ) -> [Action] {
        guard generalPasteboardSynchronizationEnabled else { return [] }
        guard lastPasteboardChangeCount != changeCount else {
            return []
        }
        lastPasteboardChangeCount = changeCount
        guestGrabActive = false
        awaitingGuestData = false
        let replacesManualOffer: Bool
        if case .manual = localSource {
            replacesManualOffer = true
        } else {
            replacesManualOffer = false
        }
        var actions = completeManualOfferIfNeeded(.superseded)

        guard let text else {
            if isReady, localGrabActive {
                localGrabActive = false
                actions.append(.send(.release))
            }
            clearLocalOffer()
            return actions
        }
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else {
            if isReady, localGrabActive {
                actions.append(.send(.release))
            }
            clearLocalOffer()
            actions.append(.emit(.oversizedLocalText(
                byteCount: data.count,
                maximum: maximumTextBytes
            )))
            return actions
        }
        localTextData = data
        localSource = .generalPasteboard(changeCount: changeCount)
        manualOfferState = nil
        guard isReady else {
            localGrabActive = false
            return actions
        }
        if localGrabActive,
           (replacesManualOffer || negotiatesClipboardOwnership),
           shouldReleaseBeforeLocalRegrab {
            actions.append(.send(.release))
        }
        localGrabActive = true
        actions.append(.send(makeLocalGrabCommand()))
        actions.append(.emit(.localTextOffered(byteCount: data.count)))
        return actions
    }

    package mutating func offerManualText(
        _ text: String,
        id: SpiceClipboardOfferID,
        leaseGeneration: UInt64
    ) throws(SpiceClipboardError) -> [Action] {
        guard manualClipboardOffersEnabled else {
            throw .invalidAgentMessage("manual clipboard offers are disabled")
        }
        let data = Data(text.utf8)
        let maximum = effectiveManualOfferMaximumTextBytes
        guard data.count <= maximum else {
            throw .invalidAgentMessage(
                "manual text size \(data.count) exceeds \(maximum)"
            )
        }

        var actions = completeManualOfferIfNeeded(.superseded)
        let replacesLocalGrab = localGrabActive
        localTextData = data
        localSource = .manual(id: id, leaseGeneration: leaseGeneration)
        manualOfferState = ManualOfferState(
            id: id,
            leaseGeneration: leaseGeneration
        )
        guestGrabActive = false
        awaitingGuestData = false
        guard isReady else {
            localGrabActive = false
            return actions
        }
        if replacesLocalGrab, shouldReleaseBeforeLocalRegrab {
            actions.append(.send(.release))
        }
        localGrabActive = true
        actions.append(.send(makeLocalGrabCommand()))
        actions.append(.emit(.localTextOffered(byteCount: data.count)))
        return actions
    }

    package mutating func revokeManualOffer(
        id: SpiceClipboardOfferID,
        leaseGeneration: UInt64
    ) -> [Action] {
        guard case let .manual(currentID, currentLeaseGeneration) = localSource,
              currentID == id,
              currentLeaseGeneration == leaseGeneration else {
            return []
        }
        var actions = completeManualOfferIfNeeded(.revoked)
        if isReady, localGrabActive {
            actions.append(.send(.release))
        }
        clearLocalOffer()
        return actions
    }

    package mutating func didWriteGuestText(changeCount: Int) {
        lastPasteboardChangeCount = changeCount
        clearLocalOffer()
    }

    private func requireReady() throws(SpiceClipboardError) {
        guard isReady else {
            throw .invalidAgentMessage("clipboard message before capability negotiation")
        }
    }

    private mutating func receivePeerGrab(
        types: [UInt32],
        serial: UInt32?
    ) throws(SpiceClipboardError) -> [Action] {
        guard clipboardNegotiationEnabled else { return [] }
        try requireReady()
        if let serial {
            if let lastPeerGrabSerial,
               !Self.isNewerSerial(serial, than: lastPeerGrabSerial) {
                return []
            }
            lastPeerGrabSerial = serial
        }
        var actions = completeManualOfferIfNeeded(.superseded)
        clearLocalOffer()
        guestGrabActive = true
        if generalPasteboardSynchronizationEnabled,
           types.contains(VDAgentClipboardType.utf8Text.rawValue) {
            awaitingGuestData = true
            actions.append(.send(.request(
                type: VDAgentClipboardType.utf8Text.rawValue
            )))
            return actions
        }
        awaitingGuestData = false
        return actions
    }

    private static func isNewerSerial(_ candidate: UInt32, than current: UInt32) -> Bool {
        let distance = candidate &- current
        return distance != 0 && distance < (UInt32(1) << 31)
    }

    private var shouldReleaseBeforeLocalRegrab: Bool {
        !(negotiatesClipboardOwnership
            && peerCapabilities?.contains(.clipboardNoReleaseOnRegrab) == true)
    }

    private mutating func makeLocalGrabCommand() -> VDAgentClipboardCommand {
        let types = [VDAgentClipboardType.utf8Text.rawValue]
        guard expectsPeerGrabSerial else {
            return .grab(types: types)
        }
        let serial = nextLocalGrabSerial
        nextLocalGrabSerial &+= 1
        return .serialGrab(serial: serial, types: types)
    }

    private var localCapabilities: VDAgentCapabilities {
        guard clipboardNegotiationEnabled else {
            return .desktopServicesWithoutClipboard
        }
        if negotiatesClipboardOwnership {
            return .desktopIntegrationWithClipboardOwnership
        }
        return negotiatesClipboardLimit
            ? .desktopIntegrationWithClipboardLimit
            : .desktopIntegration
    }

    private var clipboardNegotiationEnabled: Bool {
        generalPasteboardSynchronizationEnabled || manualClipboardOffersEnabled
    }

    private mutating func completeManualOfferIfNeeded(
        _ result: SpiceClipboardOfferResult
    ) -> [Action] {
        guard var manualOfferState,
              manualOfferState.terminalResult == nil else {
            return []
        }
        manualOfferState.terminalResult = result
        self.manualOfferState = manualOfferState
        return [.manualOffer(.emit(SpiceClipboardOfferEvent(
            id: manualOfferState.id,
            result: result
        )))]
    }

    private mutating func clearLocalOffer() {
        localTextData = nil
        localSource = nil
        manualOfferState = nil
        localGrabActive = false
    }

    private mutating func resetConnectionState() {
        agentConnected = false
        localCapabilitiesAnnounced = false
        peerCapabilities = nil
        peerMaximumClipboardBytes = nil
        wasReady = false
        localTextData = nil
        localSource = nil
        manualOfferState = nil
        localGrabActive = false
        guestGrabActive = false
        awaitingGuestData = false
        lastPasteboardChangeCount = nil
        lastPeerGrabSerial = nil
        nextLocalGrabSerial = 1
    }
}
