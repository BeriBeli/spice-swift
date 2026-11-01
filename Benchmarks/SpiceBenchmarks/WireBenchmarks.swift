import Benchmark
import Foundation
import SpiceProtocol
import SpiceWire

func registerWireBenchmarks() throws {
    let payload = Data((0..<65_536).map { UInt8(truncatingIfNeeded: $0) })
    var writer = ByteWriter()
    writer.writeUInt16LE(103)
    writer.writeUInt32LE(UInt32(payload.count))
    writer.writeBytes(payload)
    let wire = writer.data

    for fragmented in [false, true] {
        let chunks = fragmented
            ? stride(from: 0, to: wire.count, by: 1_024).map {
                Data(wire[$0..<min($0 + 1_024, wire.count)])
            }
            : [wire]
        // Verify complete payload consumption before registering a timed path.
        var check = MessageFramer(mode: .mini)
        for chunk in chunks { try check.append(chunk) }
        try require(try check.nextMessage()?.body == payload, "framed payload")
        try require(check.bufferedByteCount == 0, "framer did not drain")
        Benchmark("Wire/64KiB/\(fragmented ? "1KiB-fragments" : "contiguous")",
                  configuration: .init(scalingFactor: .kilo)) { benchmark in
            for _ in benchmark.scaledIterations {
                var framer = MessageFramer(mode: .mini)
                for chunk in chunks {
                    try framer.append(chunk)
                    // Exercise production-style partial-header/body polling.
                    if let message = try framer.nextMessage() { blackHole(message) }
                }
            }
        }
    }

    var ping = ByteWriter()
    ping.writeUInt32LE(42)
    ping.writeUInt64LE(1_234_567)
    let body = OwnedBytes(ping.data).wholeSlice
    guard case let .ping(decoded) = try SpiceServerMessageDecoder.decode(id: 4, body: body, channel: .main),
          decoded.id == 42, decoded.time == 1_234_567 else {
        throw BenchmarkInputError.incorrectResult("ping parser")
    }
    Benchmark("Protocol/Ping", configuration: .init(scalingFactor: .kilo)) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(try SpiceServerMessageDecoder.decode(id: 4, body: body, channel: .main))
        }
    }
}
