import Foundation
import SpiceWire

package struct SpiceRecordStart: Sendable, Equatable {
    package let channels: UInt32
    package let format: SpiceAudioFormat
    package let frequency: UInt32
}

package enum SpiceRecordCommand: Sendable, Equatable {
    case start(SpiceRecordStart)
    case stop
    case volume([UInt16])
    case mute(Bool)
}

package struct SpiceRecordWireLimits: Sendable, Equatable {
    package var maximumPacketBytes: Int
    package var maximumModeDataBytes: Int
    package var maximumChannels: Int

    package init(
        maximumPacketBytes: Int = 256 * 1_024,
        maximumModeDataBytes: Int = 64 * 1_024,
        maximumChannels: Int = 32
    ) {
        self.maximumPacketBytes = maximumPacketBytes
        self.maximumModeDataBytes = maximumModeDataBytes
        self.maximumChannels = maximumChannels
    }
}

package struct SpiceRecordWireCodec: Sendable {
    private let limits: SpiceRecordWireLimits

    package init(limits: SpiceRecordWireLimits = .init()) {
        self.limits = limits
    }

    package func decodeServer(id: UInt16, body: Data) throws(WireError) -> SpiceRecordCommand {
        var reader = try ByteReader(body)
        let command: SpiceRecordCommand
        switch id {
        case 101:
            let channels = try reader.readUInt32LE()
            let rawFormat = try reader.readUInt16LE()
            guard let format = SpiceAudioFormat(rawValue: rawFormat) else {
                throw .invalidEnum(type: "SpiceAudioFormat", value: UInt64(rawFormat))
            }
            let frequency = try reader.readUInt32LE()
            try reader.requireFullyConsumed()
            command = .start(SpiceRecordStart(
                channels: channels,
                format: format,
                frequency: frequency
            ))
        case 102:
            try reader.requireFullyConsumed()
            command = .stop
        case 103:
            let channelCount = Int(try reader.readUInt8())
            guard channelCount > 0,
                  channelCount <= limits.maximumChannels,
                  reader.remainingCount == channelCount * 2 else {
                throw .invalidSize(channelCount)
            }
            var values: [UInt16] = []
            values.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                values.append(try reader.readUInt16LE())
            }
            command = .volume(values)
        case 104:
            let rawMute = try reader.readUInt8()
            guard rawMute <= 1 else {
                throw .invalidEnum(type: "SpiceAudioMute", value: UInt64(rawMute))
            }
            try reader.requireFullyConsumed()
            command = .mute(rawMute == 1)
        default:
            throw .unsupportedFeature("Record message \(id)")
        }
        return command
    }

    package func encodeMode(
        timestamp: UInt32,
        mode: SpiceAudioDataMode = .raw,
        data: Data = Data()
    ) throws(WireError) -> Data {
        guard data.count <= limits.maximumModeDataBytes else {
            throw .messageTooLarge(actual: data.count, maximum: limits.maximumModeDataBytes)
        }
        var writer = ByteWriter(capacity: 6 + data.count)
        writer.writeUInt32LE(timestamp)
        writer.writeUInt16LE(mode.rawValue)
        writer.writeBytes(data)
        return writer.data
    }

    package func encodeStartMark(timestamp: UInt32) -> Data {
        var writer = ByteWriter(capacity: 4)
        writer.writeUInt32LE(timestamp)
        return writer.data
    }

    package func encodeData(timestamp: UInt32, data: Data) throws(WireError) -> Data {
        guard !data.isEmpty, data.count <= limits.maximumPacketBytes else {
            throw data.count > limits.maximumPacketBytes
                ? .messageTooLarge(actual: data.count, maximum: limits.maximumPacketBytes)
                : .invalidSize(data.count)
        }
        var writer = ByteWriter(capacity: 4 + data.count)
        writer.writeUInt32LE(timestamp)
        writer.writeBytes(data)
        return writer.data
    }
}
