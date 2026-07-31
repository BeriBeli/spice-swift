import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Smartcard wire protocol")
struct SmartcardProtocolTests {
    @Test func roundTripsEveryVSCMessageTypeExactly() throws {
        let messages = [
            SpiceSmartcardMessage(
                type: .initialize,
                readerID: .max,
                payload: uint32(SpiceSmartcardWire.magic) + uint32(2) + uint32(0)
            ),
            SpiceSmartcardMessage(type: .error, readerID: 7, payload: uint32(0)),
            SpiceSmartcardMessage(
                type: .readerAdd,
                readerID: .max,
                payload: Data("Reader A".utf8)
            ),
            SpiceSmartcardMessage(type: .readerRemove, readerID: 7),
            SpiceSmartcardMessage(type: .atr, readerID: 7, payload: Data([0x3b, 0x00])),
            SpiceSmartcardMessage(type: .cardRemove, readerID: 7),
            SpiceSmartcardMessage(type: .apdu, readerID: 7, payload: Data([0, 0xa4, 4, 0])),
            SpiceSmartcardMessage(type: .flush, readerID: 7),
            SpiceSmartcardMessage(type: .flushComplete, readerID: 7),
        ]
        let codec = SpiceSmartcardWireCodec()
        for message in messages {
            #expect(try codec.decode(codec.encode(message)) == message)
        }

        let initialization = try codec.decodeInitialization(messages[0])
        #expect(initialization.version == 2)
        #expect(initialization.capabilities == [0])
        #expect(try codec.decodeErrorCode(messages[1]) == 0)
        #expect(try codec.readerName(messages[2]) == "Reader A")
    }

    @Test func rejectsTruncationLengthMismatchUnknownTypesAndPayloadBounds() throws {
        let codec = SpiceSmartcardWireCodec()
        let valid = try codec.encode(SpiceSmartcardMessage(
            type: .apdu,
            readerID: 1,
            payload: Data([0, 0xa4, 4, 0])
        ))
        for length in 0..<valid.count {
            #expect(throws: WireError.self) {
                try codec.decode(Data(valid.prefix(length)))
            }
        }

        var wrongLength = valid
        wrongLength.replaceSubrange(8..<12, with: uint32(5))
        #expect(throws: WireError.invalidSize(5)) {
            try codec.decode(wrongLength)
        }

        var unknown = valid
        unknown.replaceSubrange(0..<4, with: uint32(99))
        #expect(throws: WireError.invalidEnum(
            type: "SpiceSmartcardMessageType",
            value: 99
        )) {
            try codec.decode(unknown)
        }

        #expect(throws: WireError.invalidSize(0)) {
            try codec.encode(SpiceSmartcardMessage(type: .apdu, readerID: 1))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try codec.encode(SpiceSmartcardMessage(
                type: .flush,
                readerID: 1,
                payload: Data([0])
            ))
        }
        #expect(throws: WireError.invalidSize(256)) {
            try codec.encode(SpiceSmartcardMessage(
                type: .readerAdd,
                readerID: .max,
                payload: Data(repeating: 1, count: 256)
            ))
        }
        let bounded = SpiceSmartcardWireCodec(limits: .init(maximumAPDUBytes: 3))
        #expect(throws: WireError.messageTooLarge(actual: 4, maximum: 3)) {
            try bounded.encode(SpiceSmartcardMessage(
                type: .apdu,
                readerID: 1,
                payload: Data(repeating: 0, count: 4)
            ))
        }
    }

    @Test func validatesInitializationMagicAndReaderNames() throws {
        let codec = SpiceSmartcardWireCodec()
        let invalidMagic = SpiceSmartcardMessage(
            type: .initialize,
            readerID: .max,
            payload: uint32(0) + uint32(2)
        )
        #expect(throws: WireError.invalidMagic(0)) {
            try codec.decodeInitialization(invalidMagic)
        }
        #expect(throws: WireError.invalidSize(3)) {
            try codec.encode(SpiceSmartcardMessage(
                type: .readerAdd,
                readerID: .max,
                payload: Data([0x61, 0, 0x62])
            ))
        }
        #expect(throws: WireError.invalidSize(1)) {
            try codec.encode(SpiceSmartcardMessage(
                type: .readerAdd,
                readerID: .max,
                payload: Data([0xff])
            ))
        }
    }

    private func uint32(_ value: UInt32) -> Data {
        var writer = ByteWriter()
        writer.writeUInt32LE(value)
        return writer.data
    }
}
