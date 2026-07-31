import Foundation
import SwiftSpice

package struct ViewerMonitorStatus: Sendable, Equatable {
    package enum RequestPhase: Sendable, Equatable {
        case idle
        case queued(SpiceDisplayConfiguration)
        case sent(SpiceDisplayConfiguration)
        case acknowledged(SpiceDisplayConfiguration)
        case applied(SpiceDisplayConfiguration)
        case rejected(SpiceDisplayConfiguration)
        case unsupported(SpiceDisplayConfiguration)
        case failed(SpiceDisplayConfiguration?, String)
    }

    package private(set) var configurationsByChannel: [UInt8: SpiceGuestDisplayConfiguration] = [:]
    package private(set) var requestPhase: RequestPhase = .idle
    package private(set) var support = SpiceDisplayConfigurationSupport(
        agentConnected: false,
        hasExplicitPeerCapabilities: false,
        supportsMonitorConfiguration: false,
        supportsSparseMonitors: false,
        supportsMonitorPositions: false
    )

    package var configurations: [SpiceGuestDisplayConfiguration] {
        configurationsByChannel.values.sorted { $0.channelID < $1.channelID }
    }

    package var monitorCount: Int {
        configurations.reduce(0) { $0 + $1.monitors.count }
    }

    package var label: String {
        monitorCount == 0 ? "Displays" : "Displays \(monitorCount)"
    }

    package mutating func consumeAuthoritative(_ configuration: SpiceGuestDisplayConfiguration) {
        guard !configuration.monitors.isEmpty else { return }
        configurationsByChannel[configuration.channelID] = configuration
        if case let .acknowledged(requested) = requestPhase,
           authoritativeInventoryMatches(requested) {
            requestPhase = .applied(requested)
        }
    }

    package mutating func consumeRequest(_ event: SpiceDisplayConfigurationEvent) {
        switch event {
        case let .queued(configuration):
            requestPhase = .queued(configuration)
        case let .sent(configuration):
            requestPhase = .sent(configuration)
        case let .acknowledged(configuration):
            requestPhase = .acknowledged(configuration)
        case let .rejected(configuration):
            requestPhase = .rejected(configuration)
        case let .unsupported(configuration):
            requestPhase = .unsupported(configuration)
        case let .failed(configuration, error):
            requestPhase = .failed(configuration, error.description)
        case let .protocolFailure(error):
            requestPhase = .failed(nil, error.description)
        }
    }

    package mutating func recordSubmissionFailure(_ error: SpiceDisplayConfigurationError) {
        requestPhase = .failed(nil, error.description)
    }

    package mutating func consumeSupport(_ support: SpiceDisplayConfigurationSupport) {
        self.support = support
    }

    package var supportSummary: String {
        guard support.agentConnected else { return "Agent unavailable" }
        guard support.supportsMonitorConfiguration else { return "Monitor configuration unsupported" }
        guard support.hasExplicitPeerCapabilities else { return "Legacy single-layout baseline; advanced capabilities pending" }
        var features: [String] = []
        if support.supportsSparseMonitors { features.append("sparse IDs") }
        if support.supportsMonitorPositions { features.append("signed positions") }
        return features.isEmpty
            ? "Explicit capabilities: contiguous IDs at origin only"
            : "Explicit capabilities: \(features.joined(separator: ", "))"
    }

    package var requestSummary: String {
        switch requestPhase {
        case .idle:
            "No pending resolution request"
        case let .queued(configuration):
            "Queued \(Self.dimensions(configuration))"
        case let .sent(configuration):
            "Sent \(Self.dimensions(configuration)); waiting for Agent reply"
        case let .acknowledged(configuration):
            "Agent acknowledged \(Self.dimensions(configuration)); waiting for authoritative Display update"
        case let .applied(configuration):
            "Display confirmed \(Self.dimensions(configuration))"
        case let .rejected(configuration):
            "Guest rejected \(Self.dimensions(configuration))"
        case let .unsupported(configuration):
            "Guest does not support \(Self.dimensions(configuration))"
        case let .failed(_, reason):
            "Request failed: \(reason)"
        }
    }

    package var requestIsActive: Bool {
        switch requestPhase {
        case .queued, .sent, .acknowledged:
            true
        case .idle, .applied, .rejected, .unsupported, .failed:
            false
        }
    }

    private static func dimensions(_ configuration: SpiceDisplayConfiguration) -> String {
        guard configuration.monitors.count == 1, let monitor = configuration.monitors.first else {
            return "\(configuration.monitors.count) monitors"
        }
        return "\(monitor.width)×\(monitor.height)"
    }

    private func authoritativeInventoryMatches(
        _ requested: SpiceDisplayConfiguration
    ) -> Bool {
        let actual = configurations.flatMap(\.monitors)
        let enabled = requested.monitors.filter(\.isEnabled)
        guard enabled.count == actual.count else { return false }
        let actualIDs = Set(actual.map(\.id))
        if actualIDs.count == actual.count {
            let actualByID = Dictionary(uniqueKeysWithValues: actual.map { (Int($0.id), $0) })
            return enabled.allSatisfy { requestedMonitor in
                guard let actualMonitor = actualByID[requestedMonitor.id] else { return false }
                return requestedMonitor.x == Int(actualMonitor.x)
                    && requestedMonitor.y == Int(actualMonitor.y)
                    && requestedMonitor.width == Int(actualMonitor.width)
                    && requestedMonitor.height == Int(actualMonitor.height)
            }
        }
        let requestedGeometry = enabled.map(Self.geometry).sorted()
        let actualGeometry = actual.map {
            "\($0.x),\($0.y),\($0.width),\($0.height)"
        }.sorted()
        return requestedGeometry == actualGeometry
    }

    private static func geometry(_ monitor: SpiceMonitorConfiguration) -> String {
        "\(monitor.x),\(monitor.y),\(monitor.width),\(monitor.height)"
    }
}
