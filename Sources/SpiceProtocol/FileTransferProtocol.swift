import Foundation
import SpiceWire

package enum VDAgentFileTransferResult: UInt32, Sendable, Equatable {
    case canSendData = 0
    case cancelled = 1
    case error = 2
    case success = 3
    case notEnoughSpace = 4
    case sessionLocked = 5
    case agentNotConnected = 6
    case disabled = 7
}

package enum VDAgentFileTransferStatusDetail: Sendable, Equatable {
    case glibIO(errorCode: UInt32)
    case diskFreeSpace(UInt64)
}

package struct VDAgentFileTransferStatus: Sendable, Equatable {
    package let id: UInt32
    package let result: VDAgentFileTransferResult
    package let detail: VDAgentFileTransferStatusDetail?
}

package enum VDAgentFileTransferCommand: Sendable, Equatable {
    case start(id: UInt32, metadata: Data)
    case status(VDAgentFileTransferStatus)
    case data(id: UInt32, Data)
}

package struct VDAgentFileTransferWireLimits: Sendable, Equatable {
    package var maximumMetadataBytes: Int
    package var maximumChunkBytes: Int

    package init(
        maximumMetadataBytes: Int = 4 * 1_024,
        maximumChunkBytes: Int = 16_000
    ) {
        self.maximumMetadataBytes = max(1, maximumMetadataBytes)
        self.maximumChunkBytes = max(1, maximumChunkBytes)
    }
}

package struct VDAgentFileTransferCodec: Sendable {
    private let limits: VDAgentFileTransferWireLimits

    package init(limits: VDAgentFileTransferWireLimits = .init()) {
        self.limits = limits
    }

    package func decode(_ message: VDAgentMessage) throws(WireError) -> VDAgentFileTransferCommand? {
        guard message.protocolID == VDAgentMessage.protocolVersion else {
            return nil
        }
        var reader = try ByteReader(message.data)
        switch message.type {
        case VDAgentMessageType.fileTransferStart.rawValue:
            let id = try reader.readUInt32LE()
            guard reader.remainingCount > 0,
                  reader.remainingCount <= limits.maximumMetadataBytes else {
                throw .invalidSize(reader.remainingCount)
            }
            return .start(id: id, metadata: reader.readRemainingBytes())
        case VDAgentMessageType.fileTransferStatus.rawValue:
            let id = try reader.readUInt32LE()
            let rawResult = try reader.readUInt32LE()
            guard let result = VDAgentFileTransferResult(rawValue: rawResult) else {
                throw .invalidEnum(type: "VDAgentFileTransferResult", value: UInt64(rawResult))
            }
            let detail: VDAgentFileTransferStatusDetail?
            switch result {
            case .error:
                if reader.remainingCount == 0 {
                    detail = nil
                } else {
                    let errorType = try reader.readUInt8()
                    guard errorType == 0 else {
                        throw .invalidEnum(
                            type: "VDAgentFileTransferErrorType",
                            value: UInt64(errorType)
                        )
                    }
                    detail = .glibIO(errorCode: try reader.readUInt32LE())
                    try reader.requireFullyConsumed()
                }
            case .notEnoughSpace:
                if reader.remainingCount == 0 {
                    detail = nil
                } else {
                    detail = .diskFreeSpace(try reader.readUInt64LE())
                    try reader.requireFullyConsumed()
                }
            case .canSendData,
                 .cancelled,
                 .success,
                 .sessionLocked,
                 .agentNotConnected,
                 .disabled:
                try reader.requireFullyConsumed()
                detail = nil
            }
            return .status(VDAgentFileTransferStatus(
                id: id,
                result: result,
                detail: detail
            ))
        case VDAgentMessageType.fileTransferData.rawValue:
            let id = try reader.readUInt32LE()
            let declaredSize = try reader.readUInt64LE()
            guard let size = Int(exactly: declaredSize) else {
                throw .integerOverflow
            }
            guard size <= limits.maximumChunkBytes,
                  reader.remainingCount == size else {
                throw .invalidSize(size)
            }
            return .data(id: id, reader.readRemainingBytes())
        default:
            return nil
        }
    }

    package func encodeStart(
        id: UInt32,
        name: String,
        size: UInt64
    ) throws(WireError) -> VDAgentMessage {
        let metadata = try metadata(name: name, size: size)
        var writer = ByteWriter(capacity: 4 + metadata.count)
        writer.writeUInt32LE(id)
        writer.writeBytes(metadata)
        return VDAgentMessage(
            type: VDAgentMessageType.fileTransferStart.rawValue,
            data: writer.data
        )
    }

    package func encodeStatus(
        id: UInt32,
        result: VDAgentFileTransferResult
    ) -> VDAgentMessage {
        var writer = ByteWriter(capacity: 8)
        writer.writeUInt32LE(id)
        writer.writeUInt32LE(result.rawValue)
        return VDAgentMessage(
            type: VDAgentMessageType.fileTransferStatus.rawValue,
            data: writer.data
        )
    }

    package func encodeData(id: UInt32, data: Data) throws(WireError) -> VDAgentMessage {
        guard data.count <= limits.maximumChunkBytes else {
            throw .messageTooLarge(actual: data.count, maximum: limits.maximumChunkBytes)
        }
        var writer = ByteWriter(capacity: 12 + data.count)
        writer.writeUInt32LE(id)
        writer.writeUInt64LE(UInt64(data.count))
        writer.writeBytes(data)
        return VDAgentMessage(
            type: VDAgentMessageType.fileTransferData.rawValue,
            data: writer.data
        )
    }

    private func metadata(name: String, size: UInt64) throws(WireError) -> Data {
        let scalars = name.unicodeScalars
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              name == trimmed,
              name != ".",
              name != "..",
              !scalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f || $0 == "/" || $0 == "\\"
              }) else {
            throw .unsupportedFeature("unsafe file-transfer basename")
        }
        var data = Data("[vdagent-file-xfer]\nname=\(name)\nsize=\(size)\n".utf8)
        data.append(0)
        guard data.count <= limits.maximumMetadataBytes else {
            throw .messageTooLarge(actual: data.count, maximum: limits.maximumMetadataBytes)
        }
        return data
    }
}
