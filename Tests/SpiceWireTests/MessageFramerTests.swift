import Foundation
import Testing
@testable import SpiceWire

@Suite("MessageFramer")
struct MessageFramerTests {
    @Test(arguments: [HeaderMode.full, .mini])
    func everySplitProducesSameMessage(mode: HeaderMode) throws {
        let body = Data([1, 2, 3, 4, 5])
        let wire = makeMessage(mode: mode, type: 103, body: body)

        for split in 0...wire.count {
            var framer = MessageFramer(mode: mode)
            try framer.append(wire.prefix(split))
            let message: FramedMessage?
            if split < wire.count {
                #expect(try framer.nextMessage() == nil)
                try framer.append(wire.suffix(wire.count - split))
                message = try framer.nextMessage()
            } else {
                message = try framer.nextMessage()
            }
            #expect(message?.type == 103)
            #expect(message?.body == body)
            #expect(message?.serial == (mode == .full ? 1 : nil))
            #expect(message?.subListOffset == (mode == .full ? 0 : nil))
            #expect(framer.bufferedByteCount == 0)
        }
    }

    @Test(arguments: [HeaderMode.full, .mini])
    func returnsMultipleMessagesFromOneAppend(mode: HeaderMode) throws {
        let firstBody = Data([1])
        let secondBody = Data([2, 3])
        let first = makeMessage(
            mode: mode,
            type: 3,
            body: firstBody,
            serial: 11,
            subListOffset: 1
        )
        let second = makeMessage(
            mode: mode,
            type: 4,
            body: secondBody,
            serial: 12,
            subListOffset: 2
        )
        var framer = MessageFramer(mode: mode)

        try framer.append(first + second)
        let framedFirst = try framer.nextMessage()
        let firstMessage = try #require(framedFirst)
        #expect(firstMessage.type == 3)
        #expect(firstMessage.body == firstBody)
        #expect(firstMessage.serial == (mode == .full ? 11 : nil))
        #expect(firstMessage.subListOffset == (mode == .full ? 1 : nil))

        let framedSecond = try framer.nextMessage()
        let secondMessage = try #require(framedSecond)
        #expect(secondMessage.type == 4)
        #expect(secondMessage.body == secondBody)
        #expect(secondMessage.serial == (mode == .full ? 12 : nil))
        #expect(secondMessage.subListOffset == (mode == .full ? 2 : nil))
        #expect(try framer.nextMessage() == nil)
    }

    @Test func rejectsOversizedBodyBeforeBufferingIt() throws {
        var writer = ByteWriter()
        writer.writeUInt16LE(7)
        writer.writeUInt32LE(11)
        var framer = MessageFramer(
            mode: .mini,
            limits: WireLimits(maximumMessageSize: 10, maximumBufferedBytes: 100)
        )
        try framer.append(writer.data)

        #expect(throws: WireError.messageTooLarge(actual: 11, maximum: 10)) {
            try framer.nextMessage()
        }
    }

    private func makeMessage(
        mode: HeaderMode,
        type: UInt16,
        body: Data,
        serial: UInt64 = 1,
        subListOffset: UInt32 = 0
    ) -> Data {
        var writer = ByteWriter()
        if mode == .full {
            writer.writeUInt64LE(serial)
        }
        writer.writeUInt16LE(type)
        writer.writeUInt32LE(UInt32(body.count))
        if mode == .full {
            writer.writeUInt32LE(subListOffset)
        }
        writer.writeBytes(body)
        return writer.data
    }
}
