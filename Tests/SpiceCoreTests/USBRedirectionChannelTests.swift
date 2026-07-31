import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("USB redirection Channel")
struct USBRedirectionChannelTests {
    @Test func tunnelsOpaqueUSBRedirPacketsInBothDirections() async throws {
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 101, body: Data([1, 2, 3]))),
        ])
        try await transport.connect()
        let channel = USBRedirectionChannel(connection: ChannelConnection(
            key: ChannelKey(type: 9, id: 4),
            transport: transport,
            headerMode: .mini
        ))

        #expect(try await channel.processNext() == .data(
            channelID: 4,
            Data([1, 2, 3])
        ))
        try await channel.send(Data([4, 5, 6]))
        let outbound = try #require((await transport.outbound).last)
        var reader = try ByteReader(outbound)
        #expect(try reader.readUInt16LE() == 101)
        #expect(try reader.readUInt32LE() == 3)
        #expect(try reader.readBytes(count: 3) == Data([4, 5, 6]))
    }

    @Test func rejectsCompressedPacketsWithoutCapability() async throws {
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 102, body: Data([1]))),
        ])
        try await transport.connect()
        let channel = USBRedirectionChannel(connection: ChannelConnection(
            key: ChannelKey(type: 9, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        await #expect(throws: ChannelError.wire(.unsupportedFeature(
            "compressed SpiceVMC data was not negotiated"
        ))) {
            try await channel.processNext()
        }
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }
}
