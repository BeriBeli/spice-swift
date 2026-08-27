import Foundation
import SpiceWire

package enum SpiceChannelKind: Sendable, Equatable {
    case main
    case display
    case inputs
    case cursor
    case playback
    case record
    case smartcard
    case usbRedirection
    case webDAV
    case unknown(UInt8)

    package init(rawValue: UInt8) {
        switch rawValue {
        case 1: self = .main
        case 2: self = .display
        case 3: self = .inputs
        case 4: self = .cursor
        case 5: self = .playback
        case 6: self = .record
        case 8: self = .smartcard
        case 9: self = .usbRedirection
        case 11: self = .webDAV
        default: self = .unknown(rawValue)
        }
    }
}

package enum SpiceServerMessage: Sendable, Equatable {
    case setAck(SpiceMsgSetAck)
    case ping(SpiceMsgPing)
    case disconnecting(SpiceMsgDisconnect)
    case mainInit(SpiceMsgMainInit)
    case mainChannelsList(SpiceMsgMainChannelsList)
    case mainMouseMode(SpiceMsgMainMouseMode)
    case mainMultimediaTime(SpiceMsgMainMultimediaTime)
    case mainAgentConnected(tokens: UInt32?)
    case mainAgentDisconnected(errorCode: UInt32)
    case mainAgentData(Data)
    case mainAgentToken(UInt32)
    case mainMigration(SpiceMainMigrationCommand)
    case displaySurfaceCreate(SpiceMsgDisplaySurfaceCreate)
    case displaySurfaceDestroy(SpiceMsgDisplaySurfaceDestroy)
    case displayReset
    case displayInvalidateImages([UInt64])
    case displayInvalidateAllImages([SpiceDisplayWaitForChannel])
    case displayInvalidatePalette(UInt64)
    case displayInvalidateAllPalettes
    case displayStreamCreate(SpiceDisplayStreamCreate)
    case displayStreamData(SpiceDisplayStreamData)
    case displayStreamDataSized(SpiceDisplayStreamDataSized)
    case displayStreamClip(SpiceDisplayStreamClip)
    case displayStreamDestroy(UInt32)
    case displayStreamDestroyAll
    case displayMonitorsConfiguration(SpiceDisplayMonitorsConfiguration)
    case displayCopyBits(SpiceDisplayCopyBits)
    case displayDrawFill(SpiceDisplayDrawFill)
    case displayDrawCopy(SpiceDisplayDrawCopy)
    case inputsInit(SpiceMsgInputsInit)
    case inputsKeyModifiers(SpiceMsgInputsKeyModifiers)
    case inputsMouseMotionAck
    case cursor(SpiceCursorCommand)
    case playback(SpicePlaybackCommand)
    case record(SpiceRecordCommand)
    case smartcard(SpiceSmartcardMessage)
    case unknown(id: UInt16, body: Data)
}

package struct SpiceDisplayWaitForChannel: Sendable, Equatable {
    package let channelType: UInt8
    package let channelID: UInt8
    package let messageSerial: UInt64
}

package enum SpiceServerMessageDecoder {
    package static func decode(
        id: UInt16,
        body: Data,
        channel: SpiceChannelKind
    ) throws(WireError) -> SpiceServerMessage {
        try decode(
            id: id,
            body: OwnedBytes(body).wholeSlice,
            channel: channel
        )
    }

    package static func decode(
        id: UInt16,
        body: WireSlice,
        channel: SpiceChannelKind
    ) throws(WireError) -> SpiceServerMessage {
        switch id {
        case 3:
            return .setAck(try decodeBody(SpiceMsgSetAck.self, from: body))
        case 4:
            // SPICE servers may append payload bytes to PING messages when
            // measuring connection bandwidth. Only the fixed prefix belongs
            // to SpiceMsgPing; the remaining bytes are intentional padding.
            var reader = try ByteReader(body)
            return .ping(try SpiceMsgPing.decode(from: &reader))
        case 6:
            return .disconnecting(try decodeBody(SpiceMsgDisconnect.self, from: body))
        default:
            break
        }

        if channel == .main {
            if let migration = try SpiceMainMigrationCodec.decode(id: id, body: body) {
                return .mainMigration(migration)
            }
            switch id {
            case 103:
                return .mainInit(try decodeBody(SpiceMsgMainInit.self, from: body))
            case 104:
                return .mainChannelsList(try decodeBody(SpiceMsgMainChannelsList.self, from: body))
            case 105:
                return .mainMouseMode(try decodeBody(SpiceMsgMainMouseMode.self, from: body))
            case 106:
                return .mainMultimediaTime(
                    try decodeBody(SpiceMsgMainMultimediaTime.self, from: body)
                )
            case SpiceMainAgentWire.serverConnected:
                let reader = try ByteReader(body)
                try reader.requireFullyConsumed()
                return .mainAgentConnected(tokens: nil)
            case SpiceMainAgentWire.serverDisconnected:
                var reader = try ByteReader(body)
                let errorCode = try reader.readUInt32LE()
                try reader.requireFullyConsumed()
                return .mainAgentDisconnected(errorCode: errorCode)
            case SpiceMainAgentWire.serverData:
                guard body.count <= VDAgentWireLimits().maximumPacketBytes else {
                    throw .messageTooLarge(
                        actual: body.count,
                        maximum: VDAgentWireLimits().maximumPacketBytes
                    )
                }
                return .mainAgentData(body.data)
            case SpiceMainAgentWire.serverToken:
                var reader = try ByteReader(body)
                let tokens = try reader.readUInt32LE()
                try reader.requireFullyConsumed()
                return .mainAgentToken(tokens)
            case SpiceMainAgentWire.serverConnectedTokens:
                var reader = try ByteReader(body)
                let tokens = try reader.readUInt32LE()
                try reader.requireFullyConsumed()
                return .mainAgentConnected(tokens: tokens)
            default:
                break
            }
        }

        if channel == .display {
            switch id {
            case 103:
                let reader = try ByteReader(body)
                try reader.requireFullyConsumed()
                return .displayReset
            case 104:
                return .displayCopyBits(
                    try SpiceDisplayWireDecoder().decodeCopyBitsMessage(body)
                )
            case 105:
                var reader = try ByteReader(body)
                let countValue = try reader.readUInt16LE()
                let count = Int(countValue)
                guard count <= 4_096, count <= reader.remainingCount / 9 else {
                    throw .invalidSize(count)
                }
                var imageIDs: [UInt64] = []
                imageIDs.reserveCapacity(count)
                for _ in 0..<count {
                    let resourceType = try reader.readUInt8()
                    guard resourceType == 1 else {
                        throw .invalidEnum(
                            type: "SpiceResourceType",
                            value: UInt64(resourceType)
                        )
                    }
                    imageIDs.append(try reader.readUInt64LE())
                }
                try reader.requireFullyConsumed()
                return .displayInvalidateImages(imageIDs)
            case 106:
                var reader = try ByteReader(body)
                let count = Int(try reader.readUInt8())
                guard count <= reader.remainingCount / 10 else {
                    throw .invalidSize(count)
                }
                var waits: [SpiceDisplayWaitForChannel] = []
                waits.reserveCapacity(count)
                for _ in 0..<count {
                    waits.append(SpiceDisplayWaitForChannel(
                        channelType: try reader.readUInt8(),
                        channelID: try reader.readUInt8(),
                        messageSerial: try reader.readUInt64LE()
                    ))
                }
                try reader.requireFullyConsumed()
                return .displayInvalidateAllImages(waits)
            case 107:
                var reader = try ByteReader(body)
                let paletteID = try reader.readUInt64LE()
                try reader.requireFullyConsumed()
                return .displayInvalidatePalette(paletteID)
            case 108:
                let reader = try ByteReader(body)
                try reader.requireFullyConsumed()
                return .displayInvalidateAllPalettes
            case 122:
                return .displayStreamCreate(
                    try SpiceDisplayWireDecoder().decodeStreamCreateMessage(body)
                )
            case 123:
                return .displayStreamData(
                    try SpiceDisplayWireDecoder().decodeStreamDataMessage(body)
                )
            case 124:
                return .displayStreamClip(
                    try SpiceDisplayWireDecoder().decodeStreamClipMessage(body)
                )
            case 125:
                return .displayStreamDestroy(
                    try SpiceDisplayWireDecoder().decodeStreamDestroyMessage(body)
                )
            case 126:
                try SpiceDisplayWireDecoder().decodeStreamDestroyAllMessage(body)
                return .displayStreamDestroyAll
            case 302:
                return .displayDrawFill(
                    try SpiceDisplayWireDecoder().decodeDrawFillMessage(body)
                )
            case 304:
                return .displayDrawCopy(
                    try SpiceDisplayWireDecoder().decodeDrawCopyMessage(body)
                )
            case 314:
                return .displaySurfaceCreate(
                    try decodeBody(SpiceMsgDisplaySurfaceCreate.self, from: body)
                )
            case 315:
                return .displaySurfaceDestroy(
                    try decodeBody(SpiceMsgDisplaySurfaceDestroy.self, from: body)
                )
            case 316:
                return .displayStreamDataSized(
                    try SpiceDisplayWireDecoder().decodeStreamDataSizedMessage(body)
                )
            case 317:
                return .displayMonitorsConfiguration(
                    try SpiceDisplayMonitorCodec.decode(body)
                )
            default:
                break
            }
        }

        if channel == .smartcard, id == SpiceSmartcardWire.dataMessageID {
            return .smartcard(try SpiceSmartcardWireCodec().decode(body))
        }

        if channel == .inputs {
            switch id {
            case 101:
                return .inputsInit(try decodeBody(SpiceMsgInputsInit.self, from: body))
            case 102:
                return .inputsKeyModifiers(
                    try decodeBody(SpiceMsgInputsKeyModifiers.self, from: body)
                )
            case 111:
                _ = try decodeBody(SpiceMsgInputsMouseMotionAck.self, from: body)
                return .inputsMouseMotionAck
            default:
                break
            }
        }

        if channel == .cursor, (101...108).contains(id) {
            return .cursor(try SpiceCursorWireDecoder().decode(id: id, body: body))
        }

        if channel == .playback, (101...107).contains(id) {
            return .playback(try SpicePlaybackWireDecoder().decode(id: id, body: body))
        }

        if channel == .record, (101...104).contains(id) {
            return .record(try SpiceRecordWireCodec().decodeServer(id: id, body: body))
        }

        return .unknown(id: id, body: body.data)
    }

    private static func decodeBody<Message: SpiceGeneratedMessage>(
        _ type: Message.Type,
        from body: WireSlice
    ) throws(WireError) -> Message {
        try type.decode(from: body)
    }
}
