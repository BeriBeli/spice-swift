import Foundation
import SpiceWire

package struct SpiceMigrationDestination: Sendable, Equatable {
    package let host: String
    package let port: UInt16
    package let securePort: UInt16
    package let certificateSubject: String?
}

package enum SpiceMainMigrationCommand: Sendable, Equatable {
    case begin(SpiceMigrationDestination)
    case beginSeamless(destination: SpiceMigrationDestination, sourceVersion: UInt32)
    case cancel
    case switchHost(SpiceMigrationDestination)
    case end
    case destinationSeamlessAccepted
    case destinationSeamlessRejected
}

package enum SpiceMainMigrationReply: Sendable, Equatable {
    case connected
    case connectError
    case end
    case destinationDoSeamless(sourceVersion: UInt32)
    case connectedSeamless
}

package enum SpiceMainMigrationWire {
    package static let serverBegin: UInt16 = 101
    package static let serverCancel: UInt16 = 102
    package static let serverSwitchHost: UInt16 = 111
    package static let serverEnd: UInt16 = 112
    package static let serverBeginSeamless: UInt16 = 116
    package static let serverDestinationSeamlessAck: UInt16 = 117
    package static let serverDestinationSeamlessNack: UInt16 = 118

    package static let clientConnected: UInt16 = 102
    package static let clientConnectError: UInt16 = 103
    package static let clientEnd: UInt16 = 109
    package static let clientDestinationDoSeamless: UInt16 = 110
    package static let clientConnectedSeamless: UInt16 = 111
}

package enum SpiceMainMigrationCodec {
    private static let maximumStringBytes = 4_096

    package static func decode(
        id: UInt16,
        body: Data
    ) throws(WireError) -> SpiceMainMigrationCommand? {
        switch id {
        case SpiceMainMigrationWire.serverBegin:
            var reader = try ByteReader(body)
            let destination = try decodeDestination(from: &reader)
            try reader.requireFullyConsumed()
            return .begin(destination)
        case SpiceMainMigrationWire.serverBeginSeamless:
            var reader = try ByteReader(body)
            let destination = try decodeDestination(from: &reader)
            let sourceVersion = try reader.readUInt32LE()
            try reader.requireFullyConsumed()
            return .beginSeamless(destination: destination, sourceVersion: sourceVersion)
        case SpiceMainMigrationWire.serverSwitchHost:
            var reader = try ByteReader(body)
            let destination = try decodeDestination(from: &reader)
            try reader.requireFullyConsumed()
            return .switchHost(destination)
        case SpiceMainMigrationWire.serverCancel:
            try requireEmpty(body)
            return .cancel
        case SpiceMainMigrationWire.serverEnd:
            try requireEmpty(body)
            return .end
        case SpiceMainMigrationWire.serverDestinationSeamlessAck:
            try requireEmpty(body)
            return .destinationSeamlessAccepted
        case SpiceMainMigrationWire.serverDestinationSeamlessNack:
            try requireEmpty(body)
            return .destinationSeamlessRejected
        default:
            return nil
        }
    }

    package static func encode(
        _ reply: SpiceMainMigrationReply
    ) -> (id: UInt16, body: Data) {
        switch reply {
        case .connected:
            return (SpiceMainMigrationWire.clientConnected, Data())
        case .connectError:
            return (SpiceMainMigrationWire.clientConnectError, Data())
        case .end:
            return (SpiceMainMigrationWire.clientEnd, Data())
        case let .destinationDoSeamless(sourceVersion):
            var writer = ByteWriter(capacity: 4)
            writer.writeUInt32LE(sourceVersion)
            return (SpiceMainMigrationWire.clientDestinationDoSeamless, writer.data)
        case .connectedSeamless:
            return (SpiceMainMigrationWire.clientConnectedSeamless, Data())
        }
    }

    private static func decodeDestination(
        from reader: inout ByteReader
    ) throws(WireError) -> SpiceMigrationDestination {
        let port = try reader.readUInt16LE()
        let securePort = try reader.readUInt16LE()
        guard port != 0 || securePort != 0 else {
            throw .unsupportedFeature("migration destination has no usable port")
        }
        let host = try decodeCString(
            from: &reader,
            field: "migration host",
            allowsEmpty: false
        )
        let certificateSubject = try decodeCString(
            from: &reader,
            field: "migration certificate subject",
            allowsEmpty: true
        )
        return SpiceMigrationDestination(
            host: host,
            port: port,
            securePort: securePort,
            certificateSubject: certificateSubject.isEmpty ? nil : certificateSubject
        )
    }

    private static func decodeCString(
        from reader: inout ByteReader,
        field: String,
        allowsEmpty: Bool
    ) throws(WireError) -> String {
        let sizeValue = try reader.readUInt32LE()
        guard let size = Int(exactly: sizeValue), size <= maximumStringBytes else {
            throw .messageTooLarge(actual: Int(sizeValue), maximum: maximumStringBytes)
        }
        if size == 0 {
            guard allowsEmpty else {
                throw .invalidSize(0)
            }
            return ""
        }
        let bytes = try reader.readBytes(count: size)
        guard bytes.last == 0 else {
            throw .unsupportedFeature("\(field) is not NUL terminated")
        }
        let contents = bytes.dropLast()
        guard !contents.contains(0) else {
            throw .unsupportedFeature("\(field) contains an embedded NUL")
        }
        guard allowsEmpty || !contents.isEmpty else {
            throw .invalidSize(0)
        }
        guard let value = String(data: Data(contents), encoding: .utf8) else {
            throw .unsupportedFeature("\(field) is not valid UTF-8")
        }
        return value
    }

    private static func requireEmpty(_ body: Data) throws(WireError) {
        let reader = try ByteReader(body)
        try reader.requireFullyConsumed()
    }
}
