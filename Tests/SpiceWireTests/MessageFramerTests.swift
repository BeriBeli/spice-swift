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
            #expect(framer.bufferedByteCount == 0)
        }
    }

    @Test func returnsMultipleMessagesFromOneAppend() throws {
        let first = makeMessage(mode: .mini, type: 3, body: Data([1]))
        let second = makeMessage(mode: .mini, type: 4, body: Data([2, 3]))
        var framer = MessageFramer(mode: .mini)

        try framer.append(first + second)
        #expect(try framer.nextMessage()?.type == 3)
        #expect(try framer.nextMessage()?.type == 4)
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

    private func makeMessage(mode: HeaderMode, type: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        if mode == .full {
            writer.writeUInt64LE(1)
        }
        writer.writeUInt16LE(type)
        writer.writeUInt32LE(UInt32(body.count))
        if mode == .full {
            writer.writeUInt32LE(0)
        }
        writer.writeBytes(body)
        return writer.data
    }
}
