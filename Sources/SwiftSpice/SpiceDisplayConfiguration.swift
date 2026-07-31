import Foundation

public struct SpiceMonitorConfiguration: Sendable, Equatable {
    public let id: Int
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(
        id: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        self.id = id
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static func disabled(id: Int) -> Self {
        Self(id: id, x: 0, y: 0, width: 0, height: 0)
    }

    public var isEnabled: Bool {
        width > 0 && height > 0
    }
}

public struct SpiceDisplayConfiguration: Sendable, Equatable {
    public let monitors: [SpiceMonitorConfiguration]

    public init(monitors: [SpiceMonitorConfiguration]) {
        self.monitors = monitors
    }

    public init(width: Int, height: Int) {
        monitors = [.init(id: 0, x: 0, y: 0, width: width, height: height)]
    }
}

public struct SpiceDisplayConfigurationSupport: Sendable, Equatable {
    public let agentConnected: Bool
    public let hasExplicitPeerCapabilities: Bool
    public let supportsMonitorConfiguration: Bool
    public let supportsSparseMonitors: Bool
    public let supportsMonitorPositions: Bool

    public init(
        agentConnected: Bool,
        hasExplicitPeerCapabilities: Bool,
        supportsMonitorConfiguration: Bool,
        supportsSparseMonitors: Bool,
        supportsMonitorPositions: Bool
    ) {
        self.agentConnected = agentConnected
        self.hasExplicitPeerCapabilities = hasExplicitPeerCapabilities
        self.supportsMonitorConfiguration = supportsMonitorConfiguration
        self.supportsSparseMonitors = supportsSparseMonitors
        self.supportsMonitorPositions = supportsMonitorPositions
    }
}

public enum SpiceDisplayConfigurationError: Error, Sendable, Equatable,
    CustomStringConvertible {
    case agentManagerNotRunning
    case invalidDimensions(width: Int, height: Int)
    case invalidLayout(String)
    case unsupportedByAgent
    case invalidAgentReply(String)
    case transport(SpiceError)

    public var description: String {
        switch self {
        case .agentManagerNotRunning:
            "SPICE Agent manager is not running"
        case let .invalidDimensions(width, height):
            "invalid display dimensions \(width)x\(height)"
        case let .invalidLayout(reason):
            "invalid display layout: \(reason)"
        case .unsupportedByAgent:
            "guest agent does not support monitor configuration"
        case let .invalidAgentReply(reason):
            "invalid monitor configuration reply: \(reason)"
        case let .transport(error):
            "monitor configuration transport failed: \(error)"
        }
    }
}

public enum SpiceDisplayConfigurationEvent: Sendable, Equatable {
    case queued(SpiceDisplayConfiguration)
    case sent(SpiceDisplayConfiguration)
    case acknowledged(SpiceDisplayConfiguration)
    case rejected(SpiceDisplayConfiguration)
    case unsupported(SpiceDisplayConfiguration)
    case failed(SpiceDisplayConfiguration, SpiceDisplayConfigurationError)
    case protocolFailure(SpiceDisplayConfigurationError)
}

package struct DisplayConfigurationCoordinator: Sendable {
    private(set) package var desired: SpiceDisplayConfiguration?
    private(set) package var inFlight: SpiceDisplayConfiguration?

    package mutating func queue(_ configuration: SpiceDisplayConfiguration) {
        desired = configuration
    }

    package var nextToSend: SpiceDisplayConfiguration? {
        inFlight == nil ? desired : nil
    }

    package mutating func didSend(_ configuration: SpiceDisplayConfiguration) {
        guard nextToSend == configuration else {
            return
        }
        desired = nil
        inFlight = configuration
    }

    package mutating func didReceiveReply() -> SpiceDisplayConfiguration? {
        defer { inFlight = nil }
        return inFlight
    }

    package mutating func disconnected() {
        if desired == nil {
            desired = inFlight
        }
        inFlight = nil
    }

    package mutating func discardDesired() {
        desired = nil
    }

    package mutating func reset() {
        desired = nil
        inFlight = nil
    }
}
