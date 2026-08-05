import Foundation
import SpiceWire

package enum VDAgentMessageType: UInt32, Sendable {
    case monitorsConfig = 2
    case reply = 3
    case clipboard = 4
    case announceCapabilities = 6
    case clipboardGrab = 7
    case clipboardRequest = 8
    case clipboardRelease = 9
    case fileTransferStart = 10
    case fileTransferStatus = 11
    case fileTransferData = 12
    case clientDisconnected = 13
    case maxClipboard = 14
}

package enum VDAgentClipboardType: UInt32, Sendable {
    case none = 0
    case utf8Text = 1
}

package enum VDAgentCapability: Int, Sendable {
    case monitorsConfig = 1
    case reply = 2
    case clipboard = 3
    case clipboardByDemand = 5
    case maxClipboard = 10
    case sparseMonitorsConfig = 7
    case monitorsConfigPosition = 12
    case fileTransferDisabled = 13
    case fileTransferDetailedErrors = 14
    case clipboardNoReleaseOnRegrab = 16
    case clipboardGrabSerial = 17
}

package struct VDAgentCapabilities: Sendable, Equatable {
    private let words: [UInt32]

    package init(words: [UInt32]) {
        self.words = words
    }

    package static let utf8Clipboard = Self(words: [
        (UInt32(1) << UInt32(VDAgentCapability.clipboard.rawValue))
            | (UInt32(1) << UInt32(VDAgentCapability.clipboardByDemand.rawValue)),
    ])

    package static let desktopServicesWithoutClipboard = Self(words: [
        (UInt32(1) << UInt32(VDAgentCapability.monitorsConfig.rawValue))
            | (UInt32(1) << UInt32(VDAgentCapability.reply.rawValue))
            | (UInt32(1) << UInt32(VDAgentCapability.sparseMonitorsConfig.rawValue))
            | (UInt32(1) << UInt32(VDAgentCapability.monitorsConfigPosition.rawValue))
            | (UInt32(1) << UInt32(VDAgentCapability.fileTransferDetailedErrors.rawValue)),
    ])

    package static let desktopIntegration = Self(words: [
        desktopServicesWithoutClipboard.words[0] | utf8Clipboard.words[0],
    ])

    package static let desktopIntegrationWithClipboardLimit = Self(words: [
        desktopIntegration.words[0]
            | (UInt32(1) << UInt32(VDAgentCapability.maxClipboard.rawValue)),
    ])

    package static let desktopIntegrationWithClipboardOwnership = Self(words: [
        desktopIntegrationWithClipboardLimit.words[0]
            | (UInt32(1) << UInt32(
                VDAgentCapability.clipboardNoReleaseOnRegrab.rawValue
            ))
            | (UInt32(1) << UInt32(
                VDAgentCapability.clipboardGrabSerial.rawValue
            )),
    ])

    package func contains(_ capability: VDAgentCapability) -> Bool {
        let word = capability.rawValue / 32
        let bit = capability.rawValue % 32
        guard word < words.count else {
            return false
        }
        return words[word] & (UInt32(1) << UInt32(bit)) != 0
    }

    package var wireWords: [UInt32] {
        words
    }
}

package enum VDAgentClipboardCommand: Sendable, Equatable {
    case announceCapabilities(requestReply: Bool, capabilities: VDAgentCapabilities)
    case grab(types: [UInt32])
    case serialGrab(serial: UInt32, types: [UInt32])
    case request(type: UInt32)
    case data(type: UInt32, data: Data)
    case release
    case maxClipboard(Int32)
}

package enum VDAgentClipboardCodec {
    private static let maximumCapabilityWords = 16
    private static let maximumGrabTypes = 64

    package static func decode(
        _ message: VDAgentMessage,
        grabHasSerial: Bool = false
    ) throws(WireError) -> VDAgentClipboardCommand? {
        guard message.protocolID == VDAgentMessage.protocolVersion,
              let type = VDAgentMessageType(rawValue: message.type) else {
            return nil
        }
        var reader = try ByteReader(message.data)
        switch type {
        case .monitorsConfig,
             .reply,
             .clientDisconnected,
             .fileTransferStart,
             .fileTransferStatus,
             .fileTransferData:
            return nil
        case .announceCapabilities:
            let requestReply = try reader.readUInt32LE() != 0
            guard reader.remainingCount.isMultiple(of: MemoryLayout<UInt32>.size) else {
                throw .invalidSize(reader.remainingCount)
            }
            let wordCount = reader.remainingCount / MemoryLayout<UInt32>.size
            guard wordCount <= maximumCapabilityWords else {
                throw .invalidSize(wordCount)
            }
            var words: [UInt32] = []
            words.reserveCapacity(wordCount)
            for _ in 0..<wordCount {
                words.append(try reader.readUInt32LE())
            }
            return .announceCapabilities(
                requestReply: requestReply,
                capabilities: VDAgentCapabilities(words: words)
            )
        case .clipboardGrab:
            guard reader.remainingCount.isMultiple(of: MemoryLayout<UInt32>.size) else {
                throw .invalidSize(reader.remainingCount)
            }
            let wordCount = reader.remainingCount / MemoryLayout<UInt32>.size
            let typeCount = wordCount - (grabHasSerial ? 1 : 0)
            guard typeCount > 0, typeCount <= maximumGrabTypes else {
                throw .invalidSize(typeCount)
            }
            let serial = grabHasSerial ? try reader.readUInt32LE() : nil
            var types: [UInt32] = []
            types.reserveCapacity(typeCount)
            for _ in 0..<typeCount {
                types.append(try reader.readUInt32LE())
            }
            if let serial {
                return .serialGrab(serial: serial, types: types)
            }
            return .grab(types: types)
        case .clipboardRequest:
            let clipboardType = try reader.readUInt32LE()
            try reader.requireFullyConsumed()
            return .request(type: clipboardType)
        case .clipboard:
            let clipboardType = try reader.readUInt32LE()
            return .data(type: clipboardType, data: reader.readRemainingBytes())
        case .clipboardRelease:
            try reader.requireFullyConsumed()
            return .release
        case .maxClipboard:
            let maximum = try reader.readInt32LE()
            try reader.requireFullyConsumed()
            return .maxClipboard(maximum)
        }
    }

    package static func encode(
        _ command: VDAgentClipboardCommand,
        opaque: UInt64 = 0
    ) throws(WireError) -> VDAgentMessage {
        var writer = ByteWriter()
        let type: VDAgentMessageType
        switch command {
        case let .announceCapabilities(requestReply, capabilities):
            type = .announceCapabilities
            guard capabilities.wireWords.count <= maximumCapabilityWords else {
                throw .invalidSize(capabilities.wireWords.count)
            }
            writer.writeUInt32LE(requestReply ? 1 : 0)
            for word in capabilities.wireWords {
                writer.writeUInt32LE(word)
            }
        case let .grab(types):
            type = .clipboardGrab
            guard !types.isEmpty, types.count <= maximumGrabTypes else {
                throw .invalidSize(types.count)
            }
            for clipboardType in types {
                writer.writeUInt32LE(clipboardType)
            }
        case let .serialGrab(serial, types):
            type = .clipboardGrab
            guard !types.isEmpty, types.count <= maximumGrabTypes else {
                throw .invalidSize(types.count)
            }
            writer.writeUInt32LE(serial)
            for clipboardType in types {
                writer.writeUInt32LE(clipboardType)
            }
        case let .request(clipboardType):
            type = .clipboardRequest
            writer.writeUInt32LE(clipboardType)
        case let .data(clipboardType, data):
            type = .clipboard
            writer.writeUInt32LE(clipboardType)
            writer.writeBytes(data)
        case .release:
            type = .clipboardRelease
        case let .maxClipboard(maximum):
            type = .maxClipboard
            writer.writeInt32LE(maximum)
        }
        return VDAgentMessage(
            type: type.rawValue,
            opaque: opaque,
            data: writer.data
        )
    }
}
