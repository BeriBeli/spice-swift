import Foundation

package enum ViewerMode: String, CaseIterable, Identifiable, Sendable {
    case offline
    case remote

    package var id: Self { self }

    package var title: String {
        switch self {
        case .offline: "Offline Validation"
        case .remote: "Remote Session"
        }
    }

    package var systemImage: String {
        switch self {
        case .offline: "waveform.path.ecg.rectangle"
        case .remote: "desktopcomputer"
        }
    }
}

package enum ViewerConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case reconnecting(attempt: Int, delaySeconds: Int)
    case connected(sessionID: UInt32)
    case failed(String)

    package var label: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting…"
        case let .reconnecting(attempt, delaySeconds):
            "Reconnect \(attempt) in \(delaySeconds)s…"
        case let .connected(sessionID): "Connected · Session \(sessionID)"
        case .failed: "Connection Failed"
        }
    }

    package var isConnected: Bool {
        if case .connected = self { true } else { false }
    }

    package var isBusy: Bool {
        switch self {
        case .connecting, .reconnecting: true
        case .disconnected, .connected, .failed: false
        }
    }

    package var canDisconnect: Bool {
        isConnected || isBusy
    }
}

package struct ViewerReconnectBackoff: Sendable, Equatable {
    package let maximumRetries: Int
    package let maximumDelaySeconds: Int
    package let attemptTimeoutSeconds: Int

    package init(
        maximumRetries: Int = 5,
        maximumDelaySeconds: Int = 16,
        attemptTimeoutSeconds: Int = 10
    ) {
        self.maximumRetries = max(0, maximumRetries)
        self.maximumDelaySeconds = max(1, maximumDelaySeconds)
        self.attemptTimeoutSeconds = max(1, attemptTimeoutSeconds)
    }

    package func delaySeconds(forRetry retry: Int) -> Int? {
        guard retry > 0, retry <= maximumRetries else { return nil }
        let exponent = min(retry - 1, 30)
        return min(1 << exponent, maximumDelaySeconds)
    }
}
