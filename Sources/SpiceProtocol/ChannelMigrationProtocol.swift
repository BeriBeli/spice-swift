import Foundation
import SpiceWire

package struct SpiceChannelMigrationFlags: OptionSet, Sendable, Equatable {
    package let rawValue: UInt32

    package init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    package static let needFlush = Self(rawValue: 1 << 0)
    package static let needDataTransfer = Self(rawValue: 1 << 1)
    package static let known: Self = [.needFlush, .needDataTransfer]
}

package enum SpiceChannelMigrationWire {
    package static let serverMigrate: UInt16 = 1
    package static let serverMigrateData: UInt16 = 2
    package static let clientFlushMark: UInt16 = 4
    package static let clientMigrateData: UInt16 = 5
}

package enum SpiceChannelMigrationCodec {
    package static func decodeFlags(
        _ body: Data
    ) throws(WireError) -> SpiceChannelMigrationFlags {
        try decodeFlags(OwnedBytes(body).wholeSlice)
    }

    package static func decodeFlags(
        _ body: WireSlice
    ) throws(WireError) -> SpiceChannelMigrationFlags {
        var reader = try ByteReader(body)
        let flags = SpiceChannelMigrationFlags(rawValue: try reader.readUInt32LE())
        try reader.requireFullyConsumed()
        guard flags.subtracting(.known).isEmpty else {
            throw .invalidEnum(
                type: "SpiceChannelMigrationFlags",
                value: UInt64(flags.rawValue)
            )
        }
        return flags
    }
}
