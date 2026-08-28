import Foundation
import SpiceWire

package struct SpiceDisplayMonitorHead: Sendable, Equatable {
    package let id: UInt32
    package let surfaceID: UInt32
    package let width: UInt32
    package let height: UInt32
    package let x: UInt32
    package let y: UInt32
    package let flags: UInt32
}

package struct SpiceDisplayMonitorsConfiguration: Sendable, Equatable {
    package let maximumAllowed: UInt16
    package let monitors: [SpiceDisplayMonitorHead]
}

package enum SpiceDisplayMonitorCodec {
    private static let maximumMonitorCount = 256
    private static let headByteCount = 28

    package static func decode(
        _ data: Data
    ) throws(WireError) -> SpiceDisplayMonitorsConfiguration {
        try decode(OwnedBytes(data).wholeSlice)
    }

    package static func decode(
        _ data: WireSlice
    ) throws(WireError) -> SpiceDisplayMonitorsConfiguration {
        var reader = try ByteReader(data)
        let count = Int(try reader.readUInt16LE())
        let maximumAllowed = try reader.readUInt16LE()
        guard count <= maximumMonitorCount else {
            throw .invalidSize(count)
        }
        guard maximumAllowed == 0 || maximumAllowed <= maximumMonitorCount else {
            throw .invalidSize(Int(maximumAllowed))
        }
        guard maximumAllowed == 0 || count <= maximumAllowed else {
            throw .invalidSize(count)
        }
        let (expectedBytes, overflow) = count.multipliedReportingOverflow(by: headByteCount)
        guard !overflow else {
            throw .integerOverflow
        }
        guard reader.remainingCount == expectedBytes else {
            if reader.remainingCount < expectedBytes {
                throw .truncated(expected: expectedBytes, remaining: reader.remainingCount)
            }
            throw .trailingBytes(reader.remainingCount - expectedBytes)
        }

        var monitors: [SpiceDisplayMonitorHead] = []
        monitors.reserveCapacity(count)
        var monitorIDs: Set<UInt32> = []
        for _ in 0..<count {
            let id = try reader.readUInt32LE()
            let surfaceID = try reader.readUInt32LE()
            let width = try reader.readUInt32LE()
            let height = try reader.readUInt32LE()
            let x = try reader.readUInt32LE()
            let y = try reader.readUInt32LE()
            let flags = try reader.readUInt32LE()
            guard id < maximumMonitorCount else {
                throw .invalidEnum(type: "SpiceDisplayMonitorID", value: UInt64(id))
            }
            guard monitorIDs.insert(id).inserted else {
                throw .unsupportedFeature("duplicate Display monitor id \(id)")
            }
            guard width > 0, height > 0 else {
                throw .invalidSize(0)
            }
            guard !x.addingReportingOverflow(width).overflow,
                  !y.addingReportingOverflow(height).overflow else {
                throw .integerOverflow
            }
            monitors.append(SpiceDisplayMonitorHead(
                id: id,
                surfaceID: surfaceID,
                width: width,
                height: height,
                x: x,
                y: y,
                flags: flags
            ))
        }
        return SpiceDisplayMonitorsConfiguration(
            maximumAllowed: maximumAllowed,
            monitors: monitors
        )
    }
}
