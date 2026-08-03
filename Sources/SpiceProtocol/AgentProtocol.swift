import Foundation
import SpiceWire

package struct VDAgentMessage: Sendable, Equatable {
    package static let protocolVersion: UInt32 = 1
    package static let headerByteCount = 20

    package let protocolID: UInt32
    package let type: UInt32
    package let opaque: UInt64
    package let data: Data

    package init(
        protocolID: UInt32 = Self.protocolVersion,
        type: UInt32,
        opaque: UInt64 = 0,
        data: consuming Data
    ) {
        self.protocolID = protocolID
        self.type = type
        self.opaque = opaque
        self.data = data
    }
}

package struct VDAgentWireLimits: Sendable, Equatable {
    package var maximumPacketBytes: Int
    package var maximumMessageDataBytes: Int

    package init(
        maximumPacketBytes: Int = 2_048,
        maximumMessageDataBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.maximumPacketBytes = max(1, maximumPacketBytes)
        self.maximumMessageDataBytes = max(0, maximumMessageDataBytes)
    }
}

package struct VDAgentStreamDecoder: Sendable {
    private let limits: VDAgentWireLimits
    private var buffered = Data()

    package init(limits: VDAgentWireLimits = .init()) {
        self.limits = limits
    }

    package mutating func append(packet: Data) throws(WireError) -> [VDAgentMessage] {
        guard packet.count <= limits.maximumPacketBytes else {
            throw .messageTooLarge(
                actual: packet.count,
                maximum: limits.maximumPacketBytes
            )
        }
        let (messageBytes, headerOverflow) = limits.maximumMessageDataBytes
            .addingReportingOverflow(VDAgentMessage.headerByteCount)
        let (maximumBuffered, packetOverflow) = messageBytes.addingReportingOverflow(
            limits.maximumPacketBytes
        )
        guard !headerOverflow, !packetOverflow else {
            throw .integerOverflow
        }
        guard packet.count <= maximumBuffered - buffered.count else {
            throw .messageTooLarge(
                actual: buffered.count + packet.count,
                maximum: maximumBuffered
            )
        }
        buffered.append(packet)

        var messages: [VDAgentMessage] = []
        while buffered.count >= VDAgentMessage.headerByteCount {
            var reader = try ByteReader(buffered)
            let protocolID = try reader.readUInt32LE()
            let type = try reader.readUInt32LE()
            let opaque = try reader.readUInt64LE()
            let declaredSize = try reader.readUInt32LE()
            guard let dataSize = Int(exactly: declaredSize) else {
                throw .integerOverflow
            }
            guard dataSize <= limits.maximumMessageDataBytes else {
                throw .messageTooLarge(
                    actual: dataSize,
                    maximum: limits.maximumMessageDataBytes
                )
            }
            let (totalSize, overflow) = VDAgentMessage.headerByteCount
                .addingReportingOverflow(dataSize)
            guard !overflow else {
                throw .integerOverflow
            }
            guard buffered.count >= totalSize else {
                break
            }
            let data = try reader.readBytes(count: dataSize)
            messages.append(VDAgentMessage(
                protocolID: protocolID,
                type: type,
                opaque: opaque,
                data: data
            ))
            // Rebase and release consumed storage before accepting more data.
            buffered = Data(buffered.dropFirst(totalSize))
        }
        return messages
    }

    package mutating func reset() {
        buffered.removeAll(keepingCapacity: false)
    }
}

package enum VDAgentWireEncoder {
    package struct EncodedMessage: Sendable, Equatable {
        private let bytes: Data
        private let maximumPacketBytes: Int
        package let payloadByteCount: Int

        package var fragmentCount: Int {
            let completePackets = bytes.count / maximumPacketBytes
            return completePackets + (bytes.count.isMultiple(of: maximumPacketBytes) ? 0 : 1)
        }

        fileprivate init(
            bytes: consuming Data,
            maximumPacketBytes: Int,
            payloadByteCount: Int
        ) {
            self.bytes = bytes
            self.maximumPacketBytes = maximumPacketBytes
            self.payloadByteCount = payloadByteCount
        }

        package func fragment(at index: Int) -> Data? {
            guard index >= 0 else { return nil }
            let (start, overflow) = index.multipliedReportingOverflow(by: maximumPacketBytes)
            guard !overflow, start < bytes.count else { return nil }
            let (candidateEnd, endOverflow) = start.addingReportingOverflow(maximumPacketBytes)
            let end = endOverflow ? bytes.count : min(candidateEnd, bytes.count)
            return bytes.subdata(in: start..<end)
        }
    }

    package static func encode(
        _ message: VDAgentMessage,
        limits: VDAgentWireLimits = .init()
    ) throws(WireError) -> EncodedMessage {
        guard message.data.count <= limits.maximumMessageDataBytes else {
            throw .messageTooLarge(
                actual: message.data.count,
                maximum: limits.maximumMessageDataBytes
            )
        }
        guard limits.maximumPacketBytes > 0,
              message.data.count <= Int(UInt32.max) else {
            throw .integerOverflow
        }
        let (wireSize, wireOverflow) = VDAgentMessage.headerByteCount
            .addingReportingOverflow(message.data.count)
        guard !wireOverflow else {
            throw .integerOverflow
        }
        var writer = ByteWriter(capacity: wireSize)
        writer.writeUInt32LE(message.protocolID)
        writer.writeUInt32LE(message.type)
        writer.writeUInt64LE(message.opaque)
        writer.writeUInt32LE(UInt32(message.data.count))
        writer.writeBytes(message.data)
        return EncodedMessage(
            bytes: writer.data,
            maximumPacketBytes: limits.maximumPacketBytes,
            payloadByteCount: message.data.count
        )
    }

    package static func fragments(
        for message: VDAgentMessage,
        limits: VDAgentWireLimits = .init()
    ) throws(WireError) -> [Data] {
        let encoded = try encode(message, limits: limits)
        var fragments: [Data] = []
        fragments.reserveCapacity(encoded.fragmentCount)
        for index in 0..<encoded.fragmentCount {
            guard let fragment = encoded.fragment(at: index) else {
                throw .integerOverflow
            }
            fragments.append(fragment)
        }
        return fragments
    }
}

package enum SpiceMainAgentWire {
    package static let serverConnected: UInt16 = 107
    package static let serverDisconnected: UInt16 = 108
    package static let serverData: UInt16 = 109
    package static let serverToken: UInt16 = 110
    package static let serverConnectedTokens: UInt16 = 115

    package static let clientStart: UInt16 = 106
    package static let clientData: UInt16 = 107
    package static let clientToken: UInt16 = 108
}
