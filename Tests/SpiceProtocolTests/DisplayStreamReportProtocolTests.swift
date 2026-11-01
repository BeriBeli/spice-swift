import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Display stream feedback wire protocol")
struct DisplayStreamReportProtocolTests {
    @Test func activationDecodesExactUpstreamLayoutAndRejectsMalformedBodies() throws {
        // spice.proto server Display 319: four little-endian uint32 fields.
        let bytes = Data([7, 0, 0, 0, 42, 0, 0, 0, 5, 0, 0, 0, 0xe8, 3, 0, 0])
        #expect(try SpiceServerMessageDecoder.decode(id: 319, body: bytes, channel: .display)
            == .displayStreamActivateReport(.init(
                streamID: 7, uniqueID: 42, maximumWindowSize: 5, timeoutMilliseconds: 1_000
            )))
        for count in 0..<bytes.count {
            #expect(throws: WireError.self) {
                try SpiceServerMessageDecoder.decode(id: 319, body: bytes.prefix(count), channel: .display)
            }
        }
        #expect(throws: WireError.self) {
            try SpiceServerMessageDecoder.decode(id: 319, body: bytes + Data([0]), channel: .display)
        }
    }

    @Test func reportEncodesSignedDelayAndNoAudioSentinel() throws {
        let report = SpiceMsgcDisplayStreamReport(
            streamID: 7, uniqueID: 42, startFrameMultimediaTime: 100,
            endFrameMultimediaTime: 150, frameCount: 5, dropCount: 3,
            lastFrameDelay: -20, audioDelay: .max
        )
        var writer = ByteWriter()
        try report.encode(to: &writer)
        #expect(SpiceMsgcDisplayStreamReport.messageID == 102)
        #expect(writer.data == Data([
            7, 0, 0, 0, 42, 0, 0, 0, 100, 0, 0, 0, 150, 0, 0, 0,
            5, 0, 0, 0, 3, 0, 0, 0, 0xec, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        ]))
    }
}
