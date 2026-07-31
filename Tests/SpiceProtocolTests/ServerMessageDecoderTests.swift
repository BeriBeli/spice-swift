import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Server message dispatch")
struct ServerMessageDecoderTests {
    @Test func decodesDisplaySurfaceLifecycle() throws {
        let create = SpiceMsgDisplaySurfaceCreate(
            surfaceID: 9,
            width: 800,
            height: 600,
            format: 32,
            flags: 0
        )
        var createWriter = ByteWriter()
        try create.encode(to: &createWriter)
        #expect(
            try SpiceServerMessageDecoder.decode(
                id: 314,
                body: createWriter.data,
                channel: .display
            ) == .displaySurfaceCreate(create)
        )

        let destroy = SpiceMsgDisplaySurfaceDestroy(surfaceID: 9)
        var destroyWriter = ByteWriter()
        try destroy.encode(to: &destroyWriter)
        #expect(
            try SpiceServerMessageDecoder.decode(
                id: 315,
                body: destroyWriter.data,
                channel: .display
            ) == .displaySurfaceDestroy(destroy)
        )
    }

    @Test func decodesKnownMainMessage() throws {
        let expected = SpiceMsgMainMouseMode(supportedModes: 3, currentMode: 2)
        var writer = ByteWriter()
        try expected.encode(to: &writer)

        let decoded = try SpiceServerMessageDecoder.decode(
            id: 105,
            body: writer.data,
            channel: .main
        )
        #expect(decoded == .mainMouseMode(expected))
    }

    @Test func decodesMainMultimediaClockReset() throws {
        let expected = SpiceMsgMainMultimediaTime(multimediaTime: UInt32.max - 7)
        var writer = ByteWriter()
        try expected.encode(to: &writer)

        #expect(try SpiceServerMessageDecoder.decode(
            id: 106,
            body: writer.data,
            channel: .main
        ) == .mainMultimediaTime(expected))
    }

    @Test func preservesUnknownMessageBody() throws {
        let body = Data([1, 2, 3])
        let decoded = try SpiceServerMessageDecoder.decode(
            id: 999,
            body: body,
            channel: .unknown(250)
        )
        #expect(decoded == .unknown(id: 999, body: body))
    }

    @Test func decodesBandwidthProbePingWithPadding() throws {
        let expected = SpiceMsgPing(id: 3, time: 987_654)
        var writer = ByteWriter()
        try expected.encode(to: &writer)
        writer.writeBytes(Data(repeating: 0, count: 256_000))

        #expect(try SpiceServerMessageDecoder.decode(
            id: 4,
            body: writer.data,
            channel: .main
        ) == .ping(expected))
    }

    @Test func rejectsTrailingBytesForKnownMessage() {
        #expect(throws: WireError.trailingBytes(1)) {
            try SpiceServerMessageDecoder.decode(
                id: 3,
                body: Data(repeating: 0, count: SpiceMsgSetAck.minimumWireSize + 1),
                channel: .main
            )
        }
    }
}
