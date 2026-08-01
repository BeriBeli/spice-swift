import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Record Channel")
struct RecordChannelTests {
    @Test func executesRawLifecycleAndSendsModeMarkThenPCM() async throws {
        let transport = FakeTransport(inbound: [
            encodeMini(id: 101, body: startBody(channels: 2, format: 1, frequency: 48_000)),
            encodeMini(id: 103, body: volumeBody([100, 200])),
            encodeMini(id: 104, body: Data([1])),
            encodeMini(id: 102, body: Data()),
        ].map(Result.success))
        try await transport.connect()
        let channel = RecordChannel(connection: ChannelConnection(
            key: ChannelKey(type: 6, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        #expect(try await channel.processNext() == .started(SpiceRecordStart(
            channels: 2,
            format: .s16,
            frequency: 48_000
        )))
        try await channel.begin(timestamp: 10)
        try await channel.send(timestamp: 11, pcm: Data([1, 2, 3, 4]))
        #expect(try await channel.processNext() == .volumeChanged([100, 200]))
        #expect(try await channel.processNext() == .muteChanged(true))
        #expect(try await channel.processNext() == .stopped)

        let outbound = await transport.outbound
        #expect(try outbound.map(messageID) == [102, 103, 101])
        #expect(try messageBody(outbound[0]) == uint32(10) + uint16(1))
        #expect(try messageBody(outbound[1]) == uint32(10))
        #expect(try messageBody(outbound[2]) == uint32(11) + Data([1, 2, 3, 4]))
    }

    @Test func rejectsInvalidOrderingConfigurationAndPCMAlignment() async throws {
        let stopped = try await makeChannel(messages: [])
        await #expect(throws: ChannelError.protocolViolation(
            "Record stream marked while stopped"
        )) {
            try await stopped.begin(timestamp: 1)
        }

        let active = try await makeChannel(messages: [
            encodeMini(id: 101, body: startBody(channels: 2, format: 1, frequency: 48_000)),
        ])
        _ = try await active.processNext()
        await #expect(throws: ChannelError.protocolViolation(
            "Record DATA before MODE and START_MARK"
        )) {
            try await active.send(timestamp: 1, pcm: Data([1, 2, 3, 4]))
        }
        try await active.begin(timestamp: 1)
        await #expect(throws: ChannelError.protocolViolation(
            "Record DATA size 2 is not aligned to 4"
        )) {
            try await active.send(timestamp: 2, pcm: Data([1, 2]))
        }

        let invalid = try await makeChannel(messages: [
            encodeMini(id: 101, body: startBody(channels: 0, format: 1, frequency: 48_000)),
        ])
        await #expect(throws: ChannelError.protocolViolation(
            "invalid Record channel count 0"
        )) {
            try await invalid.processNext()
        }
    }

    @Test func rebindingPreservesActiveCaptureAndStartMark() async throws {
        let source = try await makeChannel(messages: [
            encodeMini(id: 101, body: startBody(channels: 2, format: 1, frequency: 48_000)),
        ])
        _ = try await source.processNext()
        try await source.begin(timestamp: 10)

        let target = FakeTransport()
        try await target.connect()
        _ = try await source.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 6, id: 0),
            transport: target,
            headerMode: .mini
        ))
        try await source.send(timestamp: 11, pcm: Data([1, 2, 3, 4]))

        let outbound = await target.outbound
        #expect(try outbound.map(messageID) == [101])
        #expect(try messageBody(outbound[0]) == uint32(11) + Data([1, 2, 3, 4]))
    }

    private func makeChannel(messages: [Data]) async throws -> RecordChannel {
        let transport = FakeTransport(inbound: messages.map(Result.success))
        try await transport.connect()
        return RecordChannel(connection: ChannelConnection(
            key: ChannelKey(type: 6, id: 0),
            transport: transport,
            headerMode: .mini
        ))
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }

    private func startBody(channels: UInt32, format: UInt16, frequency: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(channels)
        writer.writeUInt16LE(format)
        writer.writeUInt32LE(frequency)
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

    private func messageID(_ message: Data) throws -> UInt16 {
        var reader = try ByteReader(message)
        return try reader.readUInt16LE()
    }

    private func messageBody(_ message: Data) throws -> Data {
        var reader = try ByteReader(message)
        _ = try reader.readUInt16LE()
        let size = Int(try reader.readUInt32LE())
        return try reader.readBytes(count: size)
    }

    private func uint32(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }

    private func uint16(_ value: UInt16) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(value)
        return writer.data
    }
}
