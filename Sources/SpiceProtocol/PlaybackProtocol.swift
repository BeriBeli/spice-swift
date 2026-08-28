import Foundation
import SpiceWire

package enum SpiceAudioDataMode: UInt16, Sendable, Equatable {
    case raw = 1
    case celt051 = 2
    case opus = 3
}

package enum SpiceAudioFormat: UInt16, Sendable, Equatable {
    case s16 = 1
}

package struct SpicePlaybackPacket: Sendable, Equatable {
    package let multimediaTime: UInt32
    package let data: Data
}

package struct SpicePlaybackMode: Sendable, Equatable {
    package let multimediaTime: UInt32
    package let mode: SpiceAudioDataMode
    package let data: Data
}

package struct SpicePlaybackStart: Sendable, Equatable {
    package let channels: UInt32
    package let format: SpiceAudioFormat
    package let frequency: UInt32
    package let multimediaTime: UInt32
}

package enum SpicePlaybackCommand: Sendable, Equatable {
    case data(SpicePlaybackPacket)
    case mode(SpicePlaybackMode)
    case start(SpicePlaybackStart)
    case stop
    case volume([UInt16])
    case mute(Bool)
    case latency(milliseconds: UInt32)
}

package struct SpicePlaybackWireLimits: Sendable, Equatable {
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

package struct SpicePlaybackWireDecoder: Sendable {
    private let limits: SpicePlaybackWireLimits

    package init(limits: SpicePlaybackWireLimits = .init()) {
        self.limits = limits
    }

    package func decode(id: UInt16, body: Data) throws(WireError) -> SpicePlaybackCommand {
        try decode(id: id, body: OwnedBytes(body).wholeSlice)
    }

    package func decode(id: UInt16, body: WireSlice) throws(WireError) -> SpicePlaybackCommand {
        var reader = try ByteReader(body)
        let command: SpicePlaybackCommand
        switch id {
        case 101:
            let multimediaTime = try reader.readUInt32LE()
            guard reader.remainingCount > 0,
                  reader.remainingCount <= limits.maximumPacketBytes
            else {
                throw .invalidSize(reader.remainingCount)
            }
            command = .data(SpicePlaybackPacket(
                multimediaTime: multimediaTime,
                data: reader.readRemainingBytes()
            ))
        case 102:
            let multimediaTime = try reader.readUInt32LE()
            let rawMode = try reader.readUInt16LE()
            guard let mode = SpiceAudioDataMode(rawValue: rawMode) else {
                throw .invalidEnum(type: "SpiceAudioDataMode", value: UInt64(rawMode))
            }
            guard reader.remainingCount <= limits.maximumModeDataBytes else {
                throw .messageTooLarge(
                    actual: reader.remainingCount,
                    maximum: limits.maximumModeDataBytes
                )
            }
            command = .mode(SpicePlaybackMode(
                multimediaTime: multimediaTime,
                mode: mode,
                data: reader.readRemainingBytes()
            ))
        case 103:
            let channels = try reader.readUInt32LE()
            let rawFormat = try reader.readUInt16LE()
            guard let format = SpiceAudioFormat(rawValue: rawFormat) else {
                throw .invalidEnum(type: "SpiceAudioFormat", value: UInt64(rawFormat))
            }
            let frequency = try reader.readUInt32LE()
            let multimediaTime = try reader.readUInt32LE()
            try reader.requireFullyConsumed()
            command = .start(SpicePlaybackStart(
                channels: channels,
                format: format,
                frequency: frequency,
                multimediaTime: multimediaTime
            ))
        case 104:
            try reader.requireFullyConsumed()
            command = .stop
        case 105:
            let channelCount = Int(try reader.readUInt8())
            guard channelCount > 0, channelCount <= limits.maximumChannels,
                  reader.remainingCount == channelCount * 2
            else {
                throw .invalidSize(channelCount)
            }
            var volume: [UInt16] = []
            volume.reserveCapacity(channelCount)
            for _ in 0..<channelCount {
                volume.append(try reader.readUInt16LE())
            }
            command = .volume(volume)
        case 106:
            let rawMute = try reader.readUInt8()
            guard rawMute <= 1 else {
                throw .invalidEnum(type: "SpiceAudioMute", value: UInt64(rawMute))
            }
            try reader.requireFullyConsumed()
            command = .mute(rawMute == 1)
        case 107:
            let latency = try reader.readUInt32LE()
            try reader.requireFullyConsumed()
            command = .latency(milliseconds: latency)
        default:
            throw .unsupportedFeature("Playback message \(id)")
        }
        return command
    }
}
