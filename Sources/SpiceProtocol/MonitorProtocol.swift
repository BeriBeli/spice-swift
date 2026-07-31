import Foundation
import SpiceWire

package struct VDAgentMonitorConfiguration: Sendable, Equatable {
    package let height: UInt32
    package let width: UInt32
    package let depth: UInt32
    package let x: Int32
    package let y: Int32

    package init(
        width: UInt32,
        height: UInt32,
        depth: UInt32,
        x: Int32 = 0,
        y: Int32 = 0
    ) {
        self.height = height
        self.width = width
        self.depth = depth
        self.x = x
        self.y = y
    }
}

package struct VDAgentMonitorsConfiguration: Sendable, Equatable {
    package static let maximumMonitorCount = 256

    package let usesPositions: Bool
    package let allowsSparse: Bool
    package let monitors: [VDAgentMonitorConfiguration]

    package init(
        usesPositions: Bool,
        allowsSparse: Bool = false,
        monitors: [VDAgentMonitorConfiguration]
    ) {
        self.usesPositions = usesPositions
        self.allowsSparse = allowsSparse
        self.monitors = monitors
    }
}

package enum VDAgentReplyStatus: UInt32, Sendable, Equatable {
    case success = 1
    case error = 2
}

package struct VDAgentMonitorReply: Sendable, Equatable {
    package let status: VDAgentReplyStatus
}

package enum VDAgentMonitorCodec {
    private static let usePositionsFlag: UInt32 = 1
    private static let monitorByteCount = 20

    package static func encode(
        _ configuration: VDAgentMonitorsConfiguration
    ) throws(WireError) -> VDAgentMessage {
        let monitorCount = configuration.monitors.count
        guard monitorCount > 0,
              monitorCount <= VDAgentMonitorsConfiguration.maximumMonitorCount else {
            throw .invalidSize(monitorCount)
        }
        guard configuration.monitors.allSatisfy({ monitor in
            let enabled = monitor.width > 0 && monitor.height > 0
            let disabled = configuration.allowsSparse
                && monitor.width == 0 && monitor.height == 0
            return enabled || disabled
        }) else {
            throw .invalidSize(0)
        }
        let (monitorBytes, overflow) = monitorCount.multipliedReportingOverflow(
            by: monitorByteCount
        )
        guard !overflow else {
            throw .integerOverflow
        }
        var writer = ByteWriter(capacity: 8 + monitorBytes)
        writer.writeUInt32LE(UInt32(monitorCount))
        writer.writeUInt32LE(configuration.usesPositions ? usePositionsFlag : 0)
        for monitor in configuration.monitors {
            writer.writeUInt32LE(monitor.height)
            writer.writeUInt32LE(monitor.width)
            writer.writeUInt32LE(monitor.depth)
            writer.writeInt32LE(monitor.x)
            writer.writeInt32LE(monitor.y)
        }
        return VDAgentMessage(
            type: VDAgentMessageType.monitorsConfig.rawValue,
            data: writer.data
        )
    }

    package static func decodeReply(
        _ message: VDAgentMessage
    ) throws(WireError) -> VDAgentMonitorReply? {
        guard message.protocolID == VDAgentMessage.protocolVersion,
              message.type == VDAgentMessageType.reply.rawValue else {
            return nil
        }
        var reader = try ByteReader(message.data)
        let repliedType = try reader.readUInt32LE()
        let rawStatus = try reader.readUInt32LE()
        try reader.requireFullyConsumed()
        guard repliedType == VDAgentMessageType.monitorsConfig.rawValue else {
            return nil
        }
        guard let status = VDAgentReplyStatus(rawValue: rawStatus) else {
            throw .invalidEnum(type: "VDAgentReplyStatus", value: UInt64(rawStatus))
        }
        return VDAgentMonitorReply(status: status)
    }
}
