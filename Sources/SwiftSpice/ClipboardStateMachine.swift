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

/// Content-free classification of a clipboard synchronization failure.
///
/// Categories intentionally omit clipboard contents, byte counts, protocol
/// payloads, endpoint details, and underlying error strings.
public enum SpiceClipboardFailureCategory: String, Sendable, Equatable {
    case agentDisconnected = "agent_disconnected"
    case clipboardNotReady = "clipboard_not_ready"
    case unsolicitedData = "unsolicited_data"
    case unexpectedType = "unexpected_type"
    case oversizedGuestText = "oversized_guest_text"
    case invalidUTF8 = "invalid_utf8"
    case decodeFailure = "decode_failure"
    case encodeFailure = "encode_failure"
    case pasteboardWrite = "pasteboard_write"
    case transport
    case other
}

public enum SpiceClipboardEvent: Sendable, Equatable {
    case ready
    case unavailable
    case guestText(String)
    case localTextOffered(byteCount: Int)
    case oversizedLocalText(byteCount: Int, maximum: Int)
    case failed(SpiceClipboardError)
}

package struct ClipboardStateMachineFailure: Error, Sendable, Equatable {
    package let error: SpiceClipboardError
    package let category: SpiceClipboardFailureCategory
}

package struct ClipboardStateMachine: Sendable {
    package enum Action: Sendable, Equatable {
        case send(VDAgentClipboardCommand)
        case writeGuestText(String)
        case emit(SpiceClipboardEvent)
    }

    private let maximumTextBytes: Int
    private var clipboardEnabled: Bool
    private var agentConnected = false
    private var localCapabilitiesAnnounced = false
    private var peerCapabilities: VDAgentCapabilities?
    private var wasReady = false
    private var localTextData: Data?
    private var localGrabActive = false
    private var guestGrabActive = false
    private var awaitingGuestData = false
    private var lastPasteboardChangeCount: Int?

    package init(maximumTextBytes: Int, clipboardEnabled: Bool = true) {
        self.maximumTextBytes = max(0, maximumTextBytes)
        self.clipboardEnabled = clipboardEnabled
    }

    package var isReady: Bool {
        guard clipboardEnabled, agentConnected, let peerCapabilities else {
            return false
        }
        // Modern Linux spice-vdagent advertises the demand protocol without
        // also setting the legacy VD_AGENT_CAP_CLIPBOARD bit.
        return peerCapabilities.contains(.clipboardByDemand)
    }

    package var isAgentConnected: Bool {
        agentConnected
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
        resetConnectionState()
        return notify ? [.emit(.unavailable)] : []
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
        guard clipboardEnabled != enabled else { return [] }
        var actions: [Action] = []
        if !enabled, isReady, localGrabActive {
            actions.append(.send(.release))
        }
        let notifyUnavailable = !enabled && wasReady
        clipboardEnabled = enabled
        localCapabilitiesAnnounced = false
        localTextData = nil
        localGrabActive = false
        guestGrabActive = false
        awaitingGuestData = false
        lastPasteboardChangeCount = nil
        if agentConnected {
            actions.append(contentsOf: announcementIfNeeded())
        }
        if notifyUnavailable {
            wasReady = false
            actions.append(.emit(.unavailable))
        } else if enabled, isReady, !wasReady {
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

    package mutating func receive(
        _ command: VDAgentClipboardCommand
    ) throws(ClipboardStateMachineFailure) -> [Action] {
        guard agentConnected else {
            throw failure(
                .invalidAgentMessage("message received while agent is disconnected"),
                category: .agentDisconnected
            )
        }
        switch command {
        case let .announceCapabilities(requestReply, capabilities):
            peerCapabilities = capabilities
            var actions: [Action] = []
            if requestReply {
                actions.append(.send(.announceCapabilities(
                    requestReply: false,
                    capabilities: localCapabilities
                )))
            }
            let ready = isReady
            if ready != wasReady {
                wasReady = ready
                actions.append(.emit(ready ? .ready : .unavailable))
            }
            if ready, !localGrabActive, let localTextData {
                localGrabActive = true
                actions.append(.send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])))
                actions.append(.emit(.localTextOffered(byteCount: localTextData.count)))
            }
            return actions
        case let .grab(types):
            guard clipboardEnabled else { return [] }
            try requireReady()
            localTextData = nil
            localGrabActive = false
            guestGrabActive = true
            if types.contains(VDAgentClipboardType.utf8Text.rawValue) {
                awaitingGuestData = true
                return [.send(.request(type: VDAgentClipboardType.utf8Text.rawValue))]
            }
            awaitingGuestData = false
            return []
        case let .request(type):
            guard clipboardEnabled else { return [] }
            try requireReady()
            guard type == VDAgentClipboardType.utf8Text.rawValue,
                  localGrabActive,
                  let localTextData else {
                return [.send(.data(type: VDAgentClipboardType.none.rawValue, data: Data()))]
            }
            return [.send(.data(type: type, data: localTextData))]
        case let .data(type, data):
            guard clipboardEnabled else { return [] }
            try requireReady()
            guard awaitingGuestData, guestGrabActive else {
                throw failure(
                    .invalidAgentMessage("unsolicited clipboard data"),
                    category: .unsolicitedData
                )
            }
            awaitingGuestData = false
            if type == VDAgentClipboardType.none.rawValue {
                return []
            }
            guard type == VDAgentClipboardType.utf8Text.rawValue else {
                throw failure(
                    .invalidAgentMessage("unexpected clipboard type \(type)"),
                    category: .unexpectedType
                )
            }
            guard data.count <= maximumTextBytes else {
                throw failure(
                    .invalidAgentMessage(
                        "guest text size \(data.count) exceeds \(maximumTextBytes)"
                    ),
                    category: .oversizedGuestText
                )
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw failure(.invalidUTF8, category: .invalidUTF8)
            }
            return [.writeGuestText(text), .emit(.guestText(text))]
        case .release:
            guard clipboardEnabled else { return [] }
            try requireReady()
            guestGrabActive = false
            awaitingGuestData = false
            return []
        }
    }

    package mutating func localPasteboardChanged(
        changeCount: Int,
        text: String?
    ) -> [Action] {
        guard clipboardEnabled else { return [] }
        guard lastPasteboardChangeCount != changeCount else {
            return []
        }
        lastPasteboardChangeCount = changeCount
        guestGrabActive = false
        awaitingGuestData = false

        guard let text else {
            localTextData = nil
            if isReady, localGrabActive {
                localGrabActive = false
                return [.send(.release)]
            }
            localGrabActive = false
            return []
        }
        let data = Data(text.utf8)
        guard data.count <= maximumTextBytes else {
            localTextData = nil
            var actions: [Action] = []
            if isReady, localGrabActive {
                actions.append(.send(.release))
            }
            localGrabActive = false
            actions.append(.emit(.oversizedLocalText(
                byteCount: data.count,
                maximum: maximumTextBytes
            )))
            return actions
        }
        localTextData = data
        guard isReady else {
            localGrabActive = false
            return []
        }
        localGrabActive = true
        return [
            .send(.grab(types: [VDAgentClipboardType.utf8Text.rawValue])),
            .emit(.localTextOffered(byteCount: data.count)),
        ]
    }

    package mutating func didWriteGuestText(changeCount: Int) {
        lastPasteboardChangeCount = changeCount
        localTextData = nil
        localGrabActive = false
    }

    private func requireReady() throws(ClipboardStateMachineFailure) {
        guard isReady else {
            throw failure(
                .invalidAgentMessage("clipboard message before capability negotiation"),
                category: .clipboardNotReady
            )
        }
    }

    private func failure(
        _ error: SpiceClipboardError,
        category: SpiceClipboardFailureCategory
    ) -> ClipboardStateMachineFailure {
        ClipboardStateMachineFailure(error: error, category: category)
    }

    private var localCapabilities: VDAgentCapabilities {
        clipboardEnabled ? .desktopIntegration : .desktopServicesWithoutClipboard
    }

    private mutating func resetConnectionState() {
        agentConnected = false
        localCapabilitiesAnnounced = false
        peerCapabilities = nil
        wasReady = false
        localTextData = nil
        localGrabActive = false
        guestGrabActive = false
        awaitingGuestData = false
        lastPasteboardChangeCount = nil
    }
}
