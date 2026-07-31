import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Smartcard Channel")
struct SmartcardChannelTests {
    @Test func decodesInitializationAPDUAndFlushRequests() async throws {
        let initialization = SpiceSmartcardMessage(
            type: .initialize,
            readerID: .max,
            payload: uint32(SpiceSmartcardWire.magic) + uint32(2) + uint32(0)
        )
        let transport = FakeTransport(inbound: try [
            encodeServer(initialization),
            encodeServer(SpiceSmartcardMessage(
                type: .apdu,
                readerID: 7,
                payload: Data([0, 0xa4, 4, 0])
            )),
            encodeServer(SpiceSmartcardMessage(type: .flush, readerID: 7)),
        ].map(Result.success))
        try await transport.connect()
        let channel = makeChannel(transport: transport)

        #expect(try await channel.processNext() == .initialized(
            SpiceSmartcardInitialization(version: 2, capabilities: [0])
        ))
        #expect(try await channel.processNext() == .apdu(
            readerID: 7,
            data: Data([0, 0xa4, 4, 0])
        ))
        #expect(try await channel.processNext() == .flushRequested(readerID: 7))
    }

    @Test func serializesControlOperationsAndPreservesQueueAcrossRebinding() async throws {
        let source = FakeTransport()
        try await source.connect()
        let channel = makeChannel(transport: source)

        try await channel.addReader(name: "Reader A")
        try await channel.removeReader(id: 7)
        try await channel.respondToAPDU(readerID: 7, data: Data([0x90, 0]))
        #expect(await source.outbound.count == 2)
        #expect(try outboundType((await source.outbound)[0]) == .readerAdd)
        #expect(try outboundType((await source.outbound)[1]) == .apdu)

        let target = FakeTransport(inbound: try [
            encodeServer(SpiceSmartcardMessage(
                type: .error,
                readerID: 7,
                payload: uint32(0)
            )),
            encodeServer(SpiceSmartcardMessage(
                type: .error,
                readerID: 7,
                payload: uint32(0)
            )),
        ].map(Result.success))
        try await target.connect()
        _ = try await channel.replaceConnection(with: ChannelConnection(
            key: ChannelKey(type: 8, id: 0),
            transport: target,
            headerMode: .mini
        ))

        #expect(try await channel.processNext() == .operationCompleted(
            request: .readerAdd,
            readerID: 7,
            errorCode: 0
        ))
        #expect(await target.outbound.count == 1)
        #expect(try outboundType((await target.outbound)[0]) == .readerRemove)
        #expect(try await channel.processNext() == .operationCompleted(
            request: .readerRemove,
            readerID: 7,
            errorCode: 0
        ))
    }

    @Test func rejectsUnsolicitedResultsClientOnlyMessagesAndBounds() async throws {
        let unsolicited = FakeTransport(inbound: [
            .success(try encodeServer(SpiceSmartcardMessage(
                type: .error,
                readerID: 7,
                payload: uint32(0)
            ))),
        ])
        try await unsolicited.connect()
        await #expect(throws: ChannelError.protocolViolation(
            "unsolicited Smartcard operation result"
        )) {
            try await makeChannel(transport: unsolicited).processNext()
        }

        let wrongDirection = FakeTransport(inbound: [
            .success(try encodeServer(SpiceSmartcardMessage(
                type: .readerAdd,
                readerID: .max,
                payload: Data("Reader".utf8)
            ))),
        ])
        try await wrongDirection.connect()
        await #expect(throws: ChannelError.protocolViolation(
            "client-only Smartcard message 3 received from server"
        )) {
            try await makeChannel(transport: wrongDirection).processNext()
        }

        let boundedTransport = FakeTransport()
        try await boundedTransport.connect()
        let bounded = makeChannel(transport: boundedTransport, maximumQueued: 1)
        try await bounded.addReader(name: "Reader")
        await #expect(throws: ChannelError.protocolViolation(
            "Smartcard control queue is full"
        )) {
            try await bounded.removeReader(id: 1)
        }
    }

    private func makeChannel(
        transport: FakeTransport,
        maximumQueued: Int = 64
    ) -> SmartcardChannel {
        SmartcardChannel(
            connection: ChannelConnection(
                key: ChannelKey(type: 8, id: 0),
                transport: transport,
                headerMode: .mini
            ),
            maximumQueuedControlMessages: maximumQueued
        )
    }

    private func encodeServer(_ message: SpiceSmartcardMessage) throws -> Data {
        let body = try SpiceSmartcardWireCodec().encode(message)
        var writer = ByteWriter()
        writer.writeUInt16LE(SpiceSmartcardWire.dataMessageID)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }

    private func outboundType(_ framed: Data) throws -> SpiceSmartcardMessageType {
        var reader = try ByteReader(framed)
        #expect(try reader.readUInt16LE() == SpiceSmartcardWire.dataMessageID)
        let length = try reader.readUInt32LE()
        return try SpiceSmartcardWireCodec().decode(
            reader.readBytes(count: Int(length))
        ).type
    }

    private func uint32(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }
}
