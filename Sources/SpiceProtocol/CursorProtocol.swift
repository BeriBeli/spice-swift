import Foundation
import SpiceWire

package struct SpiceCursorPosition: Sendable, Equatable {
    package let x: Int16
    package let y: Int16

    package init(x: Int16, y: Int16) {
        self.x = x
        self.y = y
    }
}

package enum SpiceCursorType: UInt8, Sendable, Equatable {
    case alpha = 0
    case mono = 1
    case color4 = 2
    case color8 = 3
    case color16 = 4
    case color24 = 5
    case color32 = 6
}

package struct SpiceCursorHeader: Sendable, Equatable {
    package let unique: UInt64
    package let type: SpiceCursorType
    package let width: UInt16
    package let height: UInt16
    package let hotSpotX: UInt16
    package let hotSpotY: UInt16
}

package struct SpiceCursorPayload: Sendable, Equatable {
    package let flags: UInt16
    package let header: SpiceCursorHeader?
    package let data: Data

    package var isNone: Bool { flags & 0x01 != 0 }
    package var shouldCache: Bool { flags & 0x02 != 0 }
    package var isFromCache: Bool { flags & 0x04 != 0 }
}

package enum SpiceCursorCommand: Sendable, Equatable {
    case initialize(
        position: SpiceCursorPosition,
        trailLength: UInt16,
        trailFrequency: UInt16,
        visible: Bool,
        cursor: SpiceCursorPayload
    )
    case reset
    case set(position: SpiceCursorPosition, visible: Bool, cursor: SpiceCursorPayload)
    case move(SpiceCursorPosition)
    case hide
    case trail(length: UInt16, frequency: UInt16)
    case invalidateOne(UInt64)
    case invalidateAll
}

package struct SpiceCursorWireLimits: Sendable, Equatable {
    package var maximumDimension: Int
    package var maximumDataBytes: Int

    package init(maximumDimension: Int = 1_024, maximumDataBytes: Int = 4 * 1_024 * 1_024) {
        self.maximumDimension = maximumDimension
        self.maximumDataBytes = maximumDataBytes
    }
}

package struct SpiceCursorWireDecoder: Sendable {
    private let limits: SpiceCursorWireLimits

    package init(limits: SpiceCursorWireLimits = .init()) {
        self.limits = limits
    }

    package func decode(id: UInt16, body: Data) throws(WireError) -> SpiceCursorCommand {
        try decode(id: id, body: OwnedBytes(body).wholeSlice)
    }

    package func decode(id: UInt16, body: WireSlice) throws(WireError) -> SpiceCursorCommand {
        var reader = try ByteReader(body)
        let command: SpiceCursorCommand
        switch id {
        case 101:
            let position = try decodePosition(from: &reader)
            let trailLength = try reader.readUInt16LE()
            let trailFrequency = try reader.readUInt16LE()
            let visible = try decodeBoolean(try reader.readUInt8())
            command = .initialize(
                position: position,
                trailLength: trailLength,
                trailFrequency: trailFrequency,
                visible: visible,
                cursor: try decodeCursor(from: &reader)
            )
        case 102:
            command = .reset
        case 103:
            let position = try decodePosition(from: &reader)
            let visible = try decodeBoolean(try reader.readUInt8())
            command = .set(
                position: position,
                visible: visible,
                cursor: try decodeCursor(from: &reader)
            )
        case 104:
            command = .move(try decodePosition(from: &reader))
        case 105:
            command = .hide
        case 106:
            command = .trail(
                length: try reader.readUInt16LE(),
                frequency: try reader.readUInt16LE()
            )
        case 107:
            command = .invalidateOne(try reader.readUInt64LE())
        case 108:
            command = .invalidateAll
        default:
            throw .unsupportedFeature("Cursor message \(id)")
        }
        try reader.requireFullyConsumed()
        return command
    }

    private func decodePosition(from reader: inout ByteReader) throws(WireError) -> SpiceCursorPosition {
        SpiceCursorPosition(x: try reader.readInt16LE(), y: try reader.readInt16LE())
    }

    private func decodeBoolean(_ value: UInt8) throws(WireError) -> Bool {
        switch value {
        case 0: false
        case 1: true
        default: throw .invalidEnum(type: "boolean", value: UInt64(value))
        }
    }

    private func decodeCursor(from reader: inout ByteReader) throws(WireError) -> SpiceCursorPayload {
        let flags = try reader.readUInt16LE()
        guard flags & ~UInt16(0x07) == 0 else {
            throw .invalidEnum(type: "SpiceCursorFlags", value: UInt64(flags))
        }
        if flags & 0x01 != 0 {
            let data = reader.readRemainingBytes()
            guard data.isEmpty else {
                throw .trailingBytes(data.count)
            }
            return SpiceCursorPayload(flags: flags, header: nil, data: data)
        }

        let typeValue: UInt8
        let unique = try reader.readUInt64LE()
        typeValue = try reader.readUInt8()
        guard let type = SpiceCursorType(rawValue: typeValue) else {
            throw .invalidEnum(type: "SpiceCursorType", value: UInt64(typeValue))
        }
        let width = try reader.readUInt16LE()
        let height = try reader.readUInt16LE()
        let hotSpotX = try reader.readUInt16LE()
        let hotSpotY = try reader.readUInt16LE()
        guard width > 0, height > 0,
              Int(width) <= limits.maximumDimension, Int(height) <= limits.maximumDimension,
              hotSpotX <= width, hotSpotY <= height
        else {
            throw .invalidSize(Int(width))
        }
        let header = SpiceCursorHeader(
            unique: unique,
            type: type,
            width: width,
            height: height,
            hotSpotX: hotSpotX,
            hotSpotY: hotSpotY
        )
        let data = reader.readRemainingBytes()
        guard data.count <= limits.maximumDataBytes else {
            throw .messageTooLarge(actual: data.count, maximum: limits.maximumDataBytes)
        }
        if flags & 0x04 != 0 {
            guard data.isEmpty else {
                throw .trailingBytes(data.count)
            }
        } else {
            let expected = try expectedDataSize(type: type, width: Int(width), height: Int(height))
            guard data.count == expected else {
                throw .invalidSize(data.count)
            }
        }
        return SpiceCursorPayload(flags: flags, header: header, data: data)
    }

    private func expectedDataSize(
        type: SpiceCursorType,
        width: Int,
        height: Int
    ) throws(WireError) -> Int {
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        guard !pixelOverflow else {
            throw .integerOverflow
        }
        let maskBytes = (pixels + 7) / 8
        switch type {
        case .alpha:
            return try checkedMultiply(pixels, 4)
        case .mono:
            let rowBytes = (width + 7) / 8
            return try checkedMultiply(try checkedMultiply(rowBytes, height), 2)
        case .color4:
            let colorBytes = try checkedMultiply((width + 1) / 2, height)
            let (withPalette, paletteOverflow) = colorBytes.addingReportingOverflow(64)
            let (total, maskOverflow) = withPalette.addingReportingOverflow(maskBytes)
            guard !paletteOverflow, !maskOverflow else { throw .integerOverflow }
            return total
        case .color16:
            let colorBytes = try checkedMultiply(pixels, 2)
            let (total, overflow) = colorBytes.addingReportingOverflow(maskBytes)
            guard !overflow else { throw .integerOverflow }
            return total
        case .color32:
            let colorBytes = try checkedMultiply(pixels, 4)
            let (total, overflow) = colorBytes.addingReportingOverflow(maskBytes)
            guard !overflow else { throw .integerOverflow }
            return total
        case .color8, .color24:
            throw .unsupportedFeature("Cursor format \(type.rawValue)")
        }
    }

    private func checkedMultiply(_ lhs: Int, _ rhs: Int) throws(WireError) -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow, result <= limits.maximumDataBytes else {
            throw .messageTooLarge(actual: overflow ? Int.max : result, maximum: limits.maximumDataBytes)
        }
        return result
    }
}
