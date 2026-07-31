import Foundation
import SpiceWire

package enum SpiceSmartcardWire {
    package static let dataMessageID: UInt16 = 101
    package static let undefinedReaderID = UInt32.max
    package static let magic: UInt32 = 0x4443_5356 // "VSCD" on the little-endian wire.
    package static let version: UInt32 = 2 // VSCARD 0.0.2
}

package enum SpiceSmartcardMessageType: UInt32, Sendable, Equatable {
    case initialize = 1
    case error = 2
    case readerAdd = 3
    case readerRemove = 4
    case atr = 5
    case cardRemove = 6
    case apdu = 7
    case flush = 8
    case flushComplete = 9
}

package struct SpiceSmartcardMessage: Sendable, Equatable {
    package let type: SpiceSmartcardMessageType
    package let readerID: UInt32
    package let payload: Data

    package init(
        type: SpiceSmartcardMessageType,
        readerID: UInt32,
        payload: consuming Data = Data()
    ) {
        self.type = type
        self.readerID = readerID
        self.payload = payload
    }
}

package struct SpiceSmartcardInitialization: Sendable, Equatable {
    package let version: UInt32
    package let capabilities: [UInt32]
}

package struct SpiceSmartcardWireLimits: Sendable, Equatable {
    package var maximumPayloadBytes: Int
    package var maximumReaderNameBytes: Int
    package var maximumATRBytes: Int
    package var maximumAPDUBytes: Int

    package init(
        maximumPayloadBytes: Int = 64 * 1_024 + 16,
        maximumReaderNameBytes: Int = 255,
        maximumATRBytes: Int = 40,
        maximumAPDUBytes: Int = 64 * 1_024 + 8
    ) {
        self.maximumPayloadBytes = maximumPayloadBytes
        self.maximumReaderNameBytes = maximumReaderNameBytes
        self.maximumATRBytes = maximumATRBytes
        self.maximumAPDUBytes = maximumAPDUBytes
    }
}

package struct SpiceSmartcardWireCodec: Sendable {
    private let limits: SpiceSmartcardWireLimits

    package init(limits: SpiceSmartcardWireLimits = .init()) {
        self.limits = limits
    }

    package func decode(_ body: Data) throws(WireError) -> SpiceSmartcardMessage {
        var reader = try ByteReader(body)
        let rawType = try reader.readUInt32LE()
        guard let type = SpiceSmartcardMessageType(rawValue: rawType) else {
            throw .invalidEnum(type: "SpiceSmartcardMessageType", value: UInt64(rawType))
        }
        let readerID = try reader.readUInt32LE()
        let declaredLength = try reader.readUInt32LE()
        guard let payloadLength = Int(exactly: declaredLength) else {
            throw .integerOverflow
        }
        guard payloadLength <= limits.maximumPayloadBytes else {
            throw .messageTooLarge(
                actual: payloadLength,
                maximum: limits.maximumPayloadBytes
            )
        }
        guard reader.remainingCount == payloadLength else {
            throw .invalidSize(payloadLength)
        }
        let message = SpiceSmartcardMessage(
            type: type,
            readerID: readerID,
            payload: try reader.readBytes(count: payloadLength)
        )
        try validate(message)
        return message
    }

    package func encode(_ message: SpiceSmartcardMessage) throws(WireError) -> Data {
        try validate(message)
        guard let length = UInt32(exactly: message.payload.count) else {
            throw .integerOverflow
        }
        var writer = ByteWriter(capacity: 12 + message.payload.count)
        writer.writeUInt32LE(message.type.rawValue)
        writer.writeUInt32LE(message.readerID)
        writer.writeUInt32LE(length)
        writer.writeBytes(message.payload)
        return writer.data
    }

    package func decodeInitialization(
        _ message: SpiceSmartcardMessage
    ) throws(WireError) -> SpiceSmartcardInitialization {
        guard message.type == .initialize else {
            throw .invalidEnum(
                type: "SpiceSmartcardMessageType",
                value: UInt64(message.type.rawValue)
            )
        }
        var reader = try ByteReader(message.payload)
        let magic = try reader.readUInt32LE()
        guard magic == SpiceSmartcardWire.magic else {
            throw .invalidMagic(magic)
        }
        let version = try reader.readUInt32LE()
        var capabilities: [UInt32] = []
        capabilities.reserveCapacity(reader.remainingCount / 4)
        while reader.remainingCount > 0 {
            capabilities.append(try reader.readUInt32LE())
        }
        return SpiceSmartcardInitialization(version: version, capabilities: capabilities)
    }

    package func decodeErrorCode(_ message: SpiceSmartcardMessage) throws(WireError) -> UInt32 {
        guard message.type == .error else {
            throw .invalidEnum(
                type: "SpiceSmartcardMessageType",
                value: UInt64(message.type.rawValue)
            )
        }
        var reader = try ByteReader(message.payload)
        let code = try reader.readUInt32LE()
        try reader.requireFullyConsumed()
        return code
    }

    package func readerName(_ message: SpiceSmartcardMessage) throws(WireError) -> String {
        guard message.type == .readerAdd,
              let name = String(data: message.payload, encoding: .utf8) else {
            throw .unsupportedFeature("invalid Smartcard reader name")
        }
        return name
    }

    private func validate(_ message: SpiceSmartcardMessage) throws(WireError) {
        guard message.payload.count <= limits.maximumPayloadBytes else {
            throw .messageTooLarge(
                actual: message.payload.count,
                maximum: limits.maximumPayloadBytes
            )
        }
        switch message.type {
        case .initialize:
            guard message.readerID == SpiceSmartcardWire.undefinedReaderID,
                  message.payload.count >= 8,
                  message.payload.count.isMultiple(of: 4) else {
                throw .invalidSize(message.payload.count)
            }
        case .error:
            guard message.payload.count == 4 else {
                throw .invalidSize(message.payload.count)
            }
        case .readerAdd:
            guard message.readerID == SpiceSmartcardWire.undefinedReaderID,
                  !message.payload.isEmpty,
                  message.payload.count <= limits.maximumReaderNameBytes,
                  !message.payload.contains(0),
                  String(data: message.payload, encoding: .utf8) != nil else {
                throw .invalidSize(message.payload.count)
            }
        case .readerRemove, .cardRemove, .flush, .flushComplete:
            guard message.payload.isEmpty else {
                throw .trailingBytes(message.payload.count)
            }
        case .atr:
            guard !message.payload.isEmpty,
                  message.payload.count <= limits.maximumATRBytes else {
                throw message.payload.count > limits.maximumATRBytes
                    ? .messageTooLarge(
                        actual: message.payload.count,
                        maximum: limits.maximumATRBytes
                    )
                    : .invalidSize(message.payload.count)
            }
        case .apdu:
            guard !message.payload.isEmpty,
                  message.payload.count <= limits.maximumAPDUBytes else {
                throw message.payload.count > limits.maximumAPDUBytes
                    ? .messageTooLarge(
                        actual: message.payload.count,
                        maximum: limits.maximumAPDUBytes
                    )
                    : .invalidSize(message.payload.count)
            }
        }
    }
}
