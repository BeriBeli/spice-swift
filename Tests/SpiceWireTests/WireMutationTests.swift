import Foundation
import Testing
@testable import SpiceWire

@Suite("Bounded wire mutation corpus")
struct WireMutationTests {
    @Test func mutatedHeadersNeverEscapeLimits() throws {
        let seeds: [Data] = [
            Data(),
            Data(repeating: 0, count: 6),
            Data([3, 0, 0, 0, 0, 0]),
            Data(repeating: 0xff, count: 18),
        ]

        for seed in seeds {
            for byteIndex in seed.indices {
                for mask: UInt8 in [0x01, 0x80, 0xff] {
                    var mutation = seed
                    mutation[byteIndex] ^= mask
                    for mode in [HeaderMode.full, .mini] {
                        var framer = MessageFramer(
                            mode: mode,
                            limits: WireLimits(maximumMessageSize: 1_024, maximumBufferedBytes: 4_096)
                        )
                        do {
                            try framer.append(mutation)
                            _ = try framer.nextMessage()
                        } catch let error {
                            _ = error
                        }
                        #expect(framer.bufferedByteCount <= 4_096)
                    }
                }
            }
        }
    }
}
