import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Main migration wire protocol")
struct MigrationProtocolTests {
    @Test func decodesBeginSeamlessAndSwitchHost() throws {
        let body = destinationBody(
            port: 5_900,
            securePort: 5_901,
            host: Data("target.example\0".utf8),
            certificateSubject: Data("CN=target\0".utf8)
        )
        let destination = SpiceMigrationDestination(
            host: "target.example",
            port: 5_900,
            securePort: 5_901,
            certificateSubject: "CN=target"
        )

        #expect(try SpiceMainMigrationCodec.decode(id: 101, body: body) == .begin(destination))
        #expect(try SpiceMainMigrationCodec.decode(
            id: 116,
            body: body + uint32(7)
        ) == .beginSeamless(destination: destination, sourceVersion: 7))
        #expect(try SpiceMainMigrationCodec.decode(
            id: 111,
            body: body
        ) == .switchHost(destination))
    }

    @Test func decodesOnlyExactEmptyCommands() throws {
        #expect(try SpiceMainMigrationCodec.decode(id: 102, body: Data()) == .cancel)
        #expect(try SpiceMainMigrationCodec.decode(id: 112, body: Data()) == .end)
        #expect(try SpiceMainMigrationCodec.decode(
            id: 117,
            body: Data()
        ) == .destinationSeamlessAccepted)
        #expect(try SpiceMainMigrationCodec.decode(
            id: 118,
            body: Data()
        ) == .destinationSeamlessRejected)
        #expect(try SpiceMainMigrationCodec.decode(id: 999, body: Data([1])) == nil)
        #expect(throws: WireError.trailingBytes(1)) {
            try SpiceMainMigrationCodec.decode(id: 102, body: Data([0]))
        }
    }

    @Test func rejectsMalformedDestinationStringsAndPorts() throws {
        #expect(throws: WireError.unsupportedFeature(
            "migration destination has no usable port"
        )) {
            try SpiceMainMigrationCodec.decode(
                id: 101,
                body: destinationBody(
                    port: 0,
                    securePort: 0,
                    host: Data("target\0".utf8),
                    certificateSubject: Data()
                )
            )
        }
        #expect(throws: WireError.unsupportedFeature(
            "migration host is not NUL terminated"
        )) {
            try SpiceMainMigrationCodec.decode(
                id: 101,
                body: destinationBody(host: Data("target".utf8))
            )
        }
        #expect(throws: WireError.unsupportedFeature(
            "migration host contains an embedded NUL"
        )) {
            try SpiceMainMigrationCodec.decode(
                id: 101,
                body: destinationBody(host: Data([0x61, 0, 0x62, 0]))
            )
        }
        #expect(throws: WireError.unsupportedFeature(
            "migration host is not valid UTF-8"
        )) {
            try SpiceMainMigrationCodec.decode(
                id: 101,
                body: destinationBody(host: Data([0xff, 0]))
            )
        }
        #expect(throws: WireError.messageTooLarge(actual: 4_097, maximum: 4_096)) {
            var writer = ByteWriter()
            writer.writeUInt16LE(5_900)
            writer.writeUInt16LE(0)
            writer.writeUInt32LE(4_097)
            _ = try SpiceMainMigrationCodec.decode(id: 101, body: writer.data)
        }
    }

    @Test func encodesClientReplyIDsAndSeamlessVersion() {
        #expect(SpiceMainMigrationCodec.encode(.connected).id == 102)
        #expect(SpiceMainMigrationCodec.encode(.connectError).id == 103)
        #expect(SpiceMainMigrationCodec.encode(.end).id == 109)
        #expect(SpiceMainMigrationCodec.encode(.connectedSeamless).id == 111)
        let seamless = SpiceMainMigrationCodec.encode(.destinationDoSeamless(sourceVersion: 9))
        #expect(seamless.id == 110)
        #expect(seamless.body == uint32(9))
    }

    private func destinationBody(
        port: UInt16 = 5_900,
        securePort: UInt16 = 0,
        host: Data = Data("target\0".utf8),
        certificateSubject: Data = Data()
    ) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(port)
        writer.writeUInt16LE(securePort)
        writer.writeUInt32LE(UInt32(host.count))
        writer.writeBytes(host)
        writer.writeUInt32LE(UInt32(certificateSubject.count))
        writer.writeBytes(certificateSubject)
        return writer.data
    }

    private func uint32(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
