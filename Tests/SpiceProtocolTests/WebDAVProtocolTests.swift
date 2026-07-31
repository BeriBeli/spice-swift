import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("WebDAV port and mux wire protocol")
struct WebDAVProtocolTests {
    @Test func decodesStrictPortInitializationAndEvents() throws {
        var body = ByteWriter()
        let name = Data("org.spice-space.webdav.0\0".utf8)
        body.writeUInt32LE(UInt32(name.count))
        body.writeBytes(name)
        body.writeUInt8(1)
        #expect(try SpicePortWireCodec().decodeInitialization(body.data) ==
            SpicePortInitialization(name: "org.spice-space.webdav.0", opened: true))
        #expect(try SpicePortWireCodec().decodeEvent(Data([0])) == .opened)
        #expect(try SpicePortWireCodec().decodeEvent(Data([1])) == .closed)
        #expect(try SpicePortWireCodec().decodeEvent(Data([2])) == .break)

        #expect(throws: WireError.invalidEnum(type: "SpicePortOpened", value: 2)) {
            var invalid = body.data
            invalid[invalid.count - 1] = 2
            _ = try SpicePortWireCodec().decodeInitialization(invalid)
        }
        #expect(throws: WireError.trailingBytes(1)) {
            _ = try SpicePortWireCodec().decodeEvent(Data([0, 1]))
        }
    }

    @Test func incrementallyDemultiplexesClientsAndCloseFrames() throws {
        let encoder = SpiceWebDAVMuxEncoder()
        let stream = try encoder.encode(clientID: 4, data: Data("GET ".utf8))
            + encoder.encode(clientID: 9, data: Data())
        var decoder = SpiceWebDAVMuxDecoder()
        var frames: [SpiceWebDAVFrame] = []
        for byte in stream {
            frames += try decoder.append(Data([byte]))
        }
        #expect(frames == [
            SpiceWebDAVFrame(clientID: 4, data: Data("GET ".utf8)),
            SpiceWebDAVFrame(clientID: 9, data: Data()),
        ])
    }

    @Test func boundsMuxFramesAndBufferedPartialInput() throws {
        let encoder = SpiceWebDAVMuxEncoder(limits: .init(maximumFrameBytes: 3))
        #expect(throws: WireError.messageTooLarge(actual: 4, maximum: 3)) {
            try encoder.encode(clientID: 1, data: Data(repeating: 0, count: 4))
        }
        var decoder = SpiceWebDAVMuxDecoder(limits: .init(
            maximumFrameBytes: 3,
            maximumBufferedBytes: 10
        ))
        #expect(try decoder.append(Data(repeating: 0, count: 9)).isEmpty)
        #expect(throws: WireError.messageTooLarge(actual: 11, maximum: 10)) {
            try decoder.append(Data([0, 0]))
        }
    }
}
