import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("WebDAV Channel")
struct WebDAVChannelTests {
    @Test func initializesDemultiplexesFragmentedRequestsAndSendsResponses() async throws {
        let mux = try SpiceWebDAVMuxEncoder().encode(
            clientID: 7,
            data: Data("GET / HTTP/1.1\r\n\r\n".utf8)
        )
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 201, body: portInit(opened: true))),
            .success(encodeMini(id: 101, body: Data(mux.prefix(5)))),
            .success(encodeMini(id: 101, body: Data(mux.dropFirst(5)))),
        ])
        try await transport.connect()
        let channel = makeChannel(transport)

        #expect(try await channel.processNext() == .initialized(
            SpicePortInitialization(name: "org.spice-space.webdav.0", opened: true)
        ))
        #expect(try await channel.processNext() == .request(
            clientID: 7,
            data: Data("GET / HTTP/1.1\r\n\r\n".utf8)
        ))
        try await channel.send(clientID: 7, data: Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
        let outbound = try #require((await transport.outbound).last)
        var reader = try ByteReader(outbound)
        #expect(try reader.readUInt16LE() == 101)
        let size = try reader.readUInt32LE()
        var decoder = SpiceWebDAVMuxDecoder()
        #expect(try decoder.append(reader.readBytes(count: Int(size))) == [
            SpiceWebDAVFrame(clientID: 7, data: Data("HTTP/1.1 200 OK\r\n\r\n".utf8)),
        ])
    }

    @Test func appliesPortEventsAndRejectsClosedData() async throws {
        let frame = try SpiceWebDAVMuxEncoder().encode(clientID: 1, data: Data([1]))
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 201, body: portInit(opened: false))),
            .success(encodeMini(id: 202, body: Data([0]))),
            .success(encodeMini(id: 202, body: Data([1]))),
            .success(encodeMini(id: 101, body: frame)),
        ])
        try await transport.connect()
        let channel = makeChannel(transport)
        _ = try await channel.processNext()
        #expect(try await channel.processNext() == .port(.opened))
        #expect(try await channel.processNext() == .port(.closed))
        await #expect(throws: ChannelError.protocolViolation(
            "WebDAV data received while port is closed"
        )) {
            try await channel.processNext()
        }
    }

    private func makeChannel(_ transport: FakeTransport) -> WebDAVChannel {
        WebDAVChannel(connection: ChannelConnection(
            key: ChannelKey(type: 11, id: 0),
            transport: transport,
            headerMode: .mini
        ))
    }

    private func portInit(opened: Bool) -> Data {
        let name = Data("org.spice-space.webdav.0\0".utf8)
        var writer = ByteWriter()
        writer.writeUInt32LE(UInt32(name.count))
        writer.writeUInt32LE(9)
        writer.writeUInt8(opened ? 1 : 0)
        writer.writeBytes(name)
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
