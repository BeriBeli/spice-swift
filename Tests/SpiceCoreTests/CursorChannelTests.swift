import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Cursor Channel")
struct CursorChannelTests {
    @Test func initializesCachesMovesAndHidesCursor() async throws {
        let inbound = [
            encodeMini(id: 101, body: cursorInitBody()),
            encodeMini(id: 103, body: cachedCursorSetBody()),
            encodeMini(id: 104, body: positionBody(x: 30, y: 40)),
            encodeMini(id: 105, body: Data()),
            encodeMini(id: 107, body: invalidationBody(id: 77)),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = CursorChannel(connection: ChannelConnection(
            key: ChannelKey(type: 4, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        guard case let .initialized(initial) = try await channel.processNext() else {
            Issue.record("expected Cursor Init")
            return
        }
        #expect(initial.position == SpiceCursorPosition(x: 10, y: 20))
        #expect(initial.visible)
        #expect(initial.cursor?.data == Data([1, 2, 3, 4, 5, 6, 7, 8]))

        guard case let .updated(cached) = try await channel.processNext() else {
            Issue.record("expected cached Cursor Set")
            return
        }
        #expect(cached.position == SpiceCursorPosition(x: 11, y: 21))
        #expect(cached.cursor?.header?.unique == 77)
        #expect(cached.cursor?.data == initial.cursor?.data)

        _ = try await channel.processNext()
        #expect(await channel.snapshot().position == SpiceCursorPosition(x: 30, y: 40))
        _ = try await channel.processNext()
        #expect(!(await channel.snapshot().visible))
        #expect(try await channel.processNext() == .cacheInvalidated)
    }

    @Test func rejectsTruncatedAlphaCursorData() {
        var body = cursorInitBody()
        body.removeLast()
        #expect(throws: WireError.invalidSize(7)) {
            try SpiceCursorWireDecoder().decode(id: 101, body: body)
        }
    }

    @Test func rejectsUnknownCachedCursor() async throws {
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 101, body: cursorNoneInitBody())),
            .success(encodeMini(id: 103, body: cachedCursorSetBody())),
        ])
        try await transport.connect()
        let channel = CursorChannel(connection: ChannelConnection(
            key: ChannelKey(type: 4, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.processNext()
        await #expect(throws: ChannelError.protocolViolation("unknown cached Cursor 77")) {
            try await channel.processNext()
        }
    }

    @Test func repeatedInitResetsCursorStateAndCache() async throws {
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 101, body: cursorInitBody())),
            .success(encodeMini(id: 101, body: cursorNoneInitBody())),
            .success(encodeMini(id: 103, body: cachedCursorSetBody())),
        ])
        try await transport.connect()
        let channel = CursorChannel(connection: ChannelConnection(
            key: ChannelKey(type: 4, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        _ = try await channel.processNext()

        guard case let .initialized(reset) = try await channel.processNext() else {
            Issue.record("expected repeated Cursor Init")
            return
        }
        #expect(!reset.visible)
        #expect(reset.cursor == nil)
        await #expect(throws: ChannelError.protocolViolation("unknown cached Cursor 77")) {
            try await channel.processNext()
        }
    }

    @Test func rebindingPreservesCursorCacheAndSnapshot() async throws {
        let source = FakeTransport(inbound: [
            .success(encodeMini(id: 101, body: cursorInitBody())),
        ])
        try await source.connect()
        let channel = CursorChannel(connection: ChannelConnection(
            key: ChannelKey(type: 4, id: 0),
            transport: source,
            headerMode: .mini
        ))
        _ = try await channel.processNext()

        let target = FakeTransport(inbound: [
            .success(encodeMini(id: 103, body: cachedCursorSetBody())),
        ])
        try await target.connect()
        _ = try await channel.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 4, id: 0),
            transport: target,
            headerMode: .mini
        ))

        guard case let .updated(snapshot) = try await channel.processNext() else {
            Issue.record("expected cached Cursor Set after rebinding")
            return
        }
        #expect(snapshot.cursor?.header?.unique == 77)
        #expect(snapshot.cursor?.data == Data([1, 2, 3, 4, 5, 6, 7, 8]))
    }

    private func cursorInitBody() -> Data {
        var writer = ByteWriter()
        writer.writeInt16LE(10)
        writer.writeInt16LE(20)
        writer.writeUInt16LE(2)
        writer.writeUInt16LE(3)
        writer.writeUInt8(1)
        writer.writeUInt16LE(0x02) // CACHE_ME
        writeCursorHeader(to: &writer)
        writer.writeBytes(Data([1, 2, 3, 4, 5, 6, 7, 8]))
        return writer.data
    }

    private func cursorNoneInitBody() -> Data {
        var writer = ByteWriter()
        writer.writeInt16LE(0)
        writer.writeInt16LE(0)
        writer.writeUInt16LE(0)
        writer.writeUInt16LE(0)
        writer.writeUInt8(0)
        writer.writeUInt16LE(0x01) // NONE
        return writer.data
    }

    private func cachedCursorSetBody() -> Data {
        var writer = ByteWriter()
        writer.writeInt16LE(11)
        writer.writeInt16LE(21)
        writer.writeUInt8(1)
        writer.writeUInt16LE(0x04) // FROM_CACHE
        writeCursorHeader(to: &writer)
        return writer.data
    }

    private func writeCursorHeader(to writer: inout ByteWriter) {
        writer.writeUInt64LE(77)
        writer.writeUInt8(0) // ALPHA
        writer.writeUInt16LE(2)
        writer.writeUInt16LE(1)
        writer.writeUInt16LE(0)
        writer.writeUInt16LE(0)
    }

    private func positionBody(x: Int16, y: Int16) -> Data {
        var writer = ByteWriter()
        writer.writeInt16LE(x)
        writer.writeInt16LE(y)
        return writer.data
    }

    private func invalidationBody(id: UInt64) -> Data {
        var writer = ByteWriter()
        writer.writeUInt64LE(id)
        return writer.data
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }
}
