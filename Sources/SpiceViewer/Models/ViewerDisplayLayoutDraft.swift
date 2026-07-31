import Foundation
import SwiftSpice

package struct ViewerDisplayLayoutDraft: Sendable, Equatable {
    package struct Monitor: Identifiable, Sendable, Equatable {
        package let id: UUID
        package var monitorID: String
        package var x: String
        package var y: String
        package var width: String
        package var height: String

        package init(
            id: UUID = UUID(),
            monitorID: String,
            x: String,
            y: String,
            width: String,
            height: String
        ) {
            self.id = id
            self.monitorID = monitorID
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    package struct Validation: Sendable, Equatable {
        package let configuration: SpiceDisplayConfiguration?
        package let message: String
        package let usesSparseIDs: Bool
        package let usesPositions: Bool

        package var canSubmit: Bool { configuration != nil }
    }

    package var monitors: [Monitor]
    package private(set) var sourceNote: String

    package init(
        configurations: [SpiceGuestDisplayConfiguration] = []
    ) {
        monitors = []
        sourceNote = "New request layout"
        load(configurations: configurations)
    }

    package mutating func load(configurations: [SpiceGuestDisplayConfiguration]) {
        let sortedConfigurations = configurations.sorted { $0.channelID < $1.channelID }
        let actual = sortedConfigurations.flatMap { configuration in
            configuration.monitors.sorted { $0.id < $1.id }
        }
        guard !actual.isEmpty else {
            monitors = [Self.monitor(id: 0, x: 0, y: 0, width: 1_920, height: 1_080)]
            sourceNote = "No authoritative inventory; using a one-monitor draft"
            return
        }

        let preservesIDs = sortedConfigurations.count == 1
        monitors = actual.enumerated().map { index, monitor in
            Self.monitor(
                id: preservesIDs ? Int(monitor.id) : index,
                x: Int(monitor.x),
                y: Int(monitor.y),
                width: Int(monitor.width),
                height: Int(monitor.height)
            )
        }
        sourceNote = preservesIDs
            ? "Loaded authoritative Display Channel \(sortedConfigurations[0].channelID) inventory"
            : "Loaded \(sortedConfigurations.count) Display Channels; request IDs were remapped sequentially"
    }

    package mutating func addMonitor() {
        let usedIDs = Set(monitors.compactMap { Int($0.monitorID) })
        let nextID = (0..<256).first { !usedIDs.contains($0) } ?? monitors.count
        let rightEdge = monitors.compactMap { monitor -> Int? in
            guard let x = Int(monitor.x), let width = Int(monitor.width) else { return nil }
            let (edge, overflow) = x.addingReportingOverflow(width)
            return overflow ? nil : edge
        }.max() ?? 0
        monitors.append(Self.monitor(
            id: nextID,
            x: Int32(exactly: rightEdge) == nil ? 0 : rightEdge,
            y: 0,
            width: 1_280,
            height: 720
        ))
    }

    package mutating func removeMonitor(id: UUID) {
        guard monitors.count > 1 else { return }
        monitors.removeAll { $0.id == id }
    }

    package func validation(
        support: SpiceDisplayConfigurationSupport
    ) -> Validation {
        guard !monitors.isEmpty else {
            return invalid("At least one monitor is required")
        }
        guard monitors.count <= 256 else {
            return invalid("Monitor count exceeds 256")
        }

        var parsed: [SpiceMonitorConfiguration] = []
        var IDs: Set<Int> = []
        for (index, monitor) in monitors.enumerated() {
            let label = "Row \(index + 1)"
            guard let id = Int(monitor.monitorID), (0..<256).contains(id) else {
                return invalid("\(label): ID must be in 0...255")
            }
            guard IDs.insert(id).inserted else {
                return invalid("Duplicate monitor ID \(id)")
            }
            guard let width = Int(monitor.width), width > 0,
                  UInt32(exactly: width) != nil,
                  let height = Int(monitor.height), height > 0,
                  UInt32(exactly: height) != nil else {
                return invalid("\(label): width and height must be positive UInt32 values")
            }
            guard let x = Int(monitor.x), Int32(exactly: x) != nil,
                  let y = Int(monitor.y), Int32(exactly: y) != nil else {
                return invalid("\(label): x and y must be signed Int32 values")
            }
            parsed.append(.init(id: id, x: x, y: y, width: width, height: height))
        }

        parsed.sort { $0.id < $1.id }
        let maximumID = parsed.last?.id ?? 0
        let usesSparse = parsed.count != maximumID + 1
        let usesPositions = parsed.contains { $0.x != 0 || $0.y != 0 }
        guard support.agentConnected else {
            return invalid("Waiting for the guest Agent", sparse: usesSparse, positions: usesPositions)
        }
        guard support.supportsMonitorConfiguration else {
            return invalid("The guest Agent does not support monitor configuration", sparse: usesSparse, positions: usesPositions)
        }
        if usesSparse || usesPositions {
            guard support.hasExplicitPeerCapabilities else {
                return invalid("Waiting for explicit guest monitor capabilities", sparse: usesSparse, positions: usesPositions)
            }
        }
        guard !usesSparse || support.supportsSparseMonitors else {
            return invalid("The guest Agent does not advertise sparse monitor IDs", sparse: true, positions: usesPositions)
        }
        guard !usesPositions || support.supportsMonitorPositions else {
            return invalid("The guest Agent does not advertise monitor positions", sparse: usesSparse, positions: true)
        }
        return Validation(
            configuration: SpiceDisplayConfiguration(monitors: parsed),
            message: "Layout is valid for the negotiated Agent capabilities",
            usesSparseIDs: usesSparse,
            usesPositions: usesPositions
        )
    }

    private func invalid(
        _ message: String,
        sparse: Bool = false,
        positions: Bool = false
    ) -> Validation {
        Validation(
            configuration: nil,
            message: message,
            usesSparseIDs: sparse,
            usesPositions: positions
        )
    }

    private static func monitor(
        id: Int,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) -> Monitor {
        Monitor(
            monitorID: String(id),
            x: String(x),
            y: String(y),
            width: String(width),
            height: String(height)
        )
    }
}
