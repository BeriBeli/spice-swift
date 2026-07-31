import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceRenderer
@testable import SpiceWire

@Suite("Golden Display frames")
struct GoldenFrameTests {
    @Test func replaysCheckedInMessageSequence() async throws {
        let fixture = try loadFixture(named: "basic-desktop")
        #expect(fixture.protocolName == "spice-protocol 0.14.5")
        #expect(fixture.headerMode == "mini")

        let messages = try fixture.messages.map { message in
            encodeMini(id: message.id, body: try decodeHex(message.bodyHex))
        }
        let transport = FakeTransport(inbound: messages.map(Result.success))
        try await transport.connect()
        let channel = DisplayChannel(connection: ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini
        ))
        for _ in fixture.messages {
            _ = try await channel.processNext()
        }

        let snapshot = try await channel.snapshot(surfaceID: fixture.surfaceID)
        #expect(snapshot.width == fixture.expected.width)
        #expect(snapshot.height == fixture.expected.height)
        #expect(snapshot.bytesPerRow == fixture.expected.bytesPerRow)
        #expect(snapshot.pixels == (try decodeHex(fixture.expected.pixelsBGRAHex)))
    }

    private func loadFixture(named name: String) throws -> GoldenFixture {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "json"
            )
        )
        return try JSONDecoder().decode(
            GoldenFixture.self,
            from: Data(contentsOf: url)
        )
    }

    private func decodeHex(_ text: String) throws -> Data {
        guard text.count.isMultiple(of: 2) else {
            throw GoldenFixtureError.invalidHex
        }
        var bytes = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else {
                throw GoldenFixtureError.invalidHex
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }
}

private struct GoldenFixture: Decodable {
    let protocolName: String
    let headerMode: String
    let surfaceID: UInt32
    let messages: [Message]
    let expected: Expected

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case headerMode
        case surfaceID
        case messages
        case expected
    }

    struct Message: Decodable {
        let id: UInt16
        let bodyHex: String
    }

    struct Expected: Decodable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixelsBGRAHex: String
    }
}

private enum GoldenFixtureError: Error {
    case invalidHex
}
