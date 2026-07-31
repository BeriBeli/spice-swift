import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Common Channel migration")
struct ChannelMigrationTests {
    @Test func flushesThenPreservesOpaqueMigrationData() async throws {
        let key = ChannelKey(type: 3, id: 0)
        let payload = Data([0xde, 0xad, 0xbe, 0xef])
        let transport = FakeTransport(inbound: [
            .success(mini(id: 1, body: uint32(3))),
            .success(mini(id: 2, body: payload)),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini
        )

        await #expect(throws: ChannelError.migrationRequested(
            key: key,
            data: payload
        )) {
            try await connection.receive()
        }
        let outbound = await transport.outbound
        #expect(outbound.count == 1)
        #expect(try miniID(outbound[0]) == 4)
        #expect(try miniBody(outbound[0]).isEmpty)
    }

    @Test func supportsMigrationWithoutFlushOrStateTransfer() async throws {
        let key = ChannelKey(type: 4, id: 0)
        let transport = FakeTransport(inbound: [
            .success(mini(id: 1, body: uint32(0))),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini
        )

        await #expect(throws: ChannelError.migrationRequested(key: key, data: nil)) {
            try await connection.receive()
        }
        #expect(await transport.outbound.isEmpty)
        await #expect(throws: ChannelError.invalidState) {
            try await connection.send(messageType: 101, body: Data())
        }
        await connection.resumeAfterMigrationCancellation()
        try await connection.send(messageType: 101, body: Data())
        #expect(try miniID((await transport.outbound).last ?? Data()) == 101)
    }

    @Test func rejectsUnknownFlagsAndMissingMigrationData() async throws {
        let key = ChannelKey(type: 2, id: 0)
        let unknownFlags = FakeTransport(inbound: [
            .success(mini(id: 1, body: uint32(4))),
        ])
        try await unknownFlags.connect()
        let unknownConnection = ChannelConnection(
            key: key,
            transport: unknownFlags,
            headerMode: .mini
        )
        await #expect(throws: ChannelError.wire(.invalidEnum(
            type: "SpiceChannelMigrationFlags",
            value: 4
        ))) {
            try await unknownConnection.receive()
        }

        let wrongFollowup = FakeTransport(inbound: [
            .success(mini(id: 1, body: uint32(2))),
            .success(mini(id: 4, body: Data())),
        ])
        try await wrongFollowup.connect()
        let wrongConnection = ChannelConnection(
            key: key,
            transport: wrongFollowup,
            headerMode: .mini
        )
        await #expect(throws: ChannelError.protocolViolation(
            "channel migration expected MIGRATE_DATA after MIGRATE"
        )) {
            try await wrongConnection.receive()
        }
    }

    @Test func sendsOpaqueMigrationDataToDestination() async throws {
        let transport = FakeTransport()
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 1, id: 0),
            transport: transport,
            headerMode: .mini
        )
        let payload = Data([1, 2, 3])

        try await connection.sendMigrationData(payload)
        let outbound = await transport.outbound
        #expect(outbound.count == 1)
        #expect(try miniID(outbound[0]) == 5)
        #expect(try miniBody(outbound[0]) == payload)
    }

    private func mini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }

    private func uint32(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }

    private func miniID(_ data: Data) throws -> UInt16 {
        var reader = try ByteReader(data)
        return try reader.readUInt16LE()
    }

    private func miniBody(_ data: Data) throws -> Data {
        var reader = try ByteReader(data)
        _ = try reader.readUInt16LE()
        let count = Int(try reader.readUInt32LE())
        let body = try reader.readBytes(count: count)
        try reader.requireFullyConsumed()
        return body
    }
}
