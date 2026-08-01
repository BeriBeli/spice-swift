import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Link handshake")
struct LinkHandshakeTests {
    @Test func advertisesOnlyImplementedDisplayStreamCapabilities() {
        let main = LinkRequest.main()
        #expect(main.channelCapabilities == [0xd])

        let semiSeamlessTarget = LinkRequest.migrationTargetMain(
            requestsSeamless: false
        )
        #expect(semiSeamlessTarget.channelCapabilities == [0x5])
        let seamlessTarget = LinkRequest.migrationTargetMain(
            requestsSeamless: true
        )
        #expect(seamlessTarget.channelCapabilities == [0xd])

        let display = LinkRequest.channel(
            connectionID: 9,
            key: ChannelKey(type: 2, id: 0)
        )
        #expect(display.channelCapabilities == [0x303])
        let h264Display = LinkRequest.channel(
            connectionID: 9,
            key: ChannelKey(type: 2, id: 0),
            advertisesH264: true
        )
        #expect(h264Display.channelCapabilities == [0xb03])
        let h265Display = LinkRequest.channel(
            connectionID: 9,
            key: ChannelKey(type: 2, id: 0),
            advertisesH265: true
        )
        #expect(h265Display.channelCapabilities == [0x4303])

        let inputs = LinkRequest.channel(
            connectionID: 9,
            key: ChannelKey(type: 3, id: 0)
        )
        #expect(inputs.channelCapabilities.isEmpty)

        let playback = LinkRequest.channel(
            connectionID: 9,
            key: ChannelKey(type: 5, id: 0)
        )
        #expect(playback.channelCapabilities == [0x6])
    }

    @Test func negotiatesTicketAuthenticationAndMiniHeader() async throws {
        let responses = try makeLinkResponses(commonCapabilities: 0b1011)
        let transport = FakeTransport(inbound: responses.map(Result.success))
        try await transport.connect()

        let result = try await LinkHandshake().perform(
            transport: transport,
            request: .main(),
            password: Data("secret".utf8),
            ticketEncryptor: FixedTicketEncryptor()
        )

        #expect(result.headerMode == .mini)
        #expect(result.commonCapabilities.contains(.protocolAuthSelection))
        #expect(result.commonCapabilities.contains(.authSpice))

        let outbound = await transport.outbound
        #expect(outbound.count == 3)
        #expect(outbound[1] == Data([1, 0, 0, 0]))
        #expect(outbound[2] == Data(repeating: 0xa5, count: 128))

        var reader = try ByteReader(outbound[0])
        let header = try SpiceLinkHeader.decode(from: &reader)
        let message = try SpiceLinkMessage.decode(from: &reader)
        let commonCapabilityWord = try reader.readUInt32LE()
        let mainCapabilityWord = try reader.readUInt32LE()
        try reader.requireFullyConsumed()
        #expect(header.size == 26)
        #expect(message.channelType == 1)
        #expect(message.capabilitiesOffset == 18)
        #expect(commonCapabilityWord == 0b1011)
        #expect(mainCapabilityWord == 0xd)
    }

    @Test func rejectsServerWithoutAdvertisedSpiceAuth() async throws {
        let responses = try makeLinkResponses(commonCapabilities: 0b1001)
        let transport = FakeTransport(inbound: responses.map(Result.success))
        try await transport.connect()

        await #expect(throws: ChannelError.authentication(.unsupportedMethod)) {
            try await LinkHandshake().perform(
                transport: transport,
                request: .main(),
                password: Data(),
                ticketEncryptor: FixedTicketEncryptor()
            )
        }
    }

    private func makeLinkResponses(
        commonCapabilities: UInt32
    ) throws -> [Data] {
        let reply = SpiceLinkReply(
            error: 0,
            publicKey: Data(repeating: 0, count: 162),
            commonCapabilityWordCount: 1,
            channelCapabilityWordCount: 0,
            capabilitiesOffset: UInt32(SpiceLinkReply.minimumWireSize)
        )
        var bodyWriter = ByteWriter()
        try reply.encode(to: &bodyWriter)
        bodyWriter.writeUInt32LE(commonCapabilities)

        let header = SpiceLinkHeader(
            magic: SpiceProtocolConstants.magic,
            majorVersion: 2,
            minorVersion: 2,
            size: UInt32(bodyWriter.data.count)
        )
        var headerWriter = ByteWriter()
        try header.encode(to: &headerWriter)

        var resultWriter = ByteWriter()
        try SpiceLinkResult(error: 0).encode(to: &resultWriter)
        return [headerWriter.data, bodyWriter.data, resultWriter.data]
    }
}

private struct FixedTicketEncryptor: TicketEncrypting {
    func encryptTicket(
        password: consuming Data,
        publicKeyDER: Data
    ) throws(AuthenticationError) -> Data {
        #expect(password == Data("secret".utf8) || password.isEmpty)
        #expect(publicKeyDER.count == 162)
        return Data(repeating: 0xa5, count: 128)
    }
}
