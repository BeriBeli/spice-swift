import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Playback Channel")
struct PlaybackChannelTests {
    @Test func executesRawS16LifecycleAndSynchronizesActualSinkDelay() async throws {
        let clock = RecordingPlaybackClock()
        let inbound = [
            encodeMini(id: 102, body: modeBody(time: 100, mode: 1)),
            encodeMini(id: 103, body: startBody(channels: 2, format: 1, frequency: 48_000)),
            encodeMini(id: 101, body: dataBody(time: 120, bytes: Data(repeating: 7, count: 8))),
            encodeMini(id: 105, body: volumeBody([100, 200])),
            encodeMini(id: 106, body: Data([1])),
            encodeMini(id: 107, body: uint32Body(40)),
            encodeMini(id: 104, body: Data()),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = PlaybackChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 5, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            multimediaClock: clock
        )

        #expect(try await channel.processNext() == .modeChanged(
            multimediaTime: 100,
            mode: .raw
        ))
        #expect(try await channel.processNext() == .started(SpicePlaybackStart(
            channels: 2,
            format: .s16,
            frequency: 48_000,
            multimediaTime: 100
        )))
        #expect(try await channel.processNext() == .packet(SpicePlaybackPacket(
            multimediaTime: 120,
            data: Data(repeating: 7, count: 8)
        )))
        try await channel.reportDelay(milliseconds: 20)
        #expect(await clock.synchronizations == [PlaybackSynchronization(
            playbackTime: 120,
            delay: 20
        )])
        #expect(try await channel.processNext() == .volumeChanged([100, 200]))
        #expect(try await channel.processNext() == .muteChanged(true))
        #expect(try await channel.processNext() == .minimumLatencyChanged(milliseconds: 40))
        #expect(try await channel.processNext() == .stopped)
    }

    @Test func rejectsUnsupportedModeInvalidOrderingAndMisalignedPCM() async throws {
        let clock = RecordingPlaybackClock()
        let unsupported = try await makeChannel(
            clock: clock,
            messages: [encodeMini(id: 102, body: modeBody(time: 1, mode: 3))]
        )
        await #expect(throws: ChannelError.protocolViolation("unsupported Playback mode 3")) {
            try await unsupported.processNext()
        }

        let stopped = try await makeChannel(
            clock: clock,
            messages: [encodeMini(id: 101, body: dataBody(time: 1, bytes: Data([1, 2])))]
        )
        await #expect(throws: ChannelError.protocolViolation(
            "Playback DATA while stream is stopped"
        )) {
            try await stopped.processNext()
        }

        let misaligned = try await makeChannel(clock: clock, messages: [
            encodeMini(id: 102, body: modeBody(time: 1, mode: 1)),
            encodeMini(id: 103, body: startBody(channels: 2, format: 1, frequency: 48_000)),
            encodeMini(id: 101, body: dataBody(time: 2, bytes: Data([1, 2]))),
        ])
        _ = try await misaligned.processNext()
        _ = try await misaligned.processNext()
        await #expect(throws: ChannelError.protocolViolation(
            "Playback DATA size 2 is not aligned to 4"
        )) {
            try await misaligned.processNext()
        }
    }

    @Test func rebindingPreservesActiveStreamAndMultimediaClockState() async throws {
        let clock = RecordingPlaybackClock()
        let source = try await makeChannel(clock: clock, messages: [
            encodeMini(id: 102, body: modeBody(time: 100, mode: 1)),
            encodeMini(id: 103, body: startBody(channels: 2, format: 1, frequency: 48_000)),
            encodeMini(id: 101, body: dataBody(time: 120, bytes: Data(repeating: 7, count: 8))),
        ])
        _ = try await source.processNext()
        _ = try await source.processNext()
        _ = try await source.processNext()

        let target = FakeTransport(inbound: [
            .success(encodeMini(id: 104, body: Data())),
        ])
        try await target.connect()
        _ = try await source.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 5, id: 0),
            transport: target,
            headerMode: .mini
        ))
        try await source.reportDelay(milliseconds: 20)
        #expect(await clock.synchronizations == [PlaybackSynchronization(
            playbackTime: 120,
            delay: 20
        )])
        #expect(try await source.processNext() == .stopped)
    }

    private func makeChannel(
        clock: RecordingPlaybackClock,
        messages: [Data]
    ) async throws -> PlaybackChannel {
        let transport = FakeTransport(inbound: messages.map(Result.success))
        try await transport.connect()
        return PlaybackChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 5, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            multimediaClock: clock
        )
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }

    private func modeBody(time: UInt32, mode: UInt16) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(time)
        writer.writeUInt16LE(mode)
        return writer.data
    }

    private func startBody(channels: UInt32, format: UInt16, frequency: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(channels)
        writer.writeUInt16LE(format)
        writer.writeUInt32LE(frequency)
        writer.writeUInt32LE(100)
        return writer.data
    }

    private func dataBody(time: UInt32, bytes: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(time)
        writer.writeBytes(bytes)
        return writer.data
    }

    private func volumeBody(_ volume: [UInt16]) -> Data {
        var writer = ByteWriter()
        writer.writeUInt8(UInt8(volume.count))
        for value in volume {
            writer.writeUInt16LE(value)
        }
        return writer.data
    }

    private func uint32Body(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }
}

private struct PlaybackSynchronization: Sendable, Equatable {
    let playbackTime: UInt32
    let delay: UInt32
}

private actor RecordingPlaybackClock: MultimediaClockScheduling {
    private(set) var synchronizations: [PlaybackSynchronization] = []

    func reset(to multimediaTime: UInt32) {}

    func synchronize(playbackTime: UInt32, delayMilliseconds: UInt32) {
        synchronizations.append(PlaybackSynchronization(
            playbackTime: playbackTime,
            delay: delayMilliseconds
        ))
    }

    func timing(for multimediaTime: UInt32) -> MultimediaFrameTiming { .due }

    func wait(until multimediaTime: UInt32) -> MultimediaFrameTiming { .due }
}
