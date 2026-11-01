import Benchmark
import CryptoKit
import Foundation
import SpiceCodecs

private struct ReferenceImage: Decodable, Sendable {
    let width: Int
    let height: Int
    let compressedBase64: String
    let expectedBGRABase64: String?
    let expectedXRGBBase64: String?

    func input() throws -> (SpiceCodecImageDescriptor, Data, Data) {
        guard let encoded = Data(base64Encoded: compressedBase64),
              let expected = Data(base64Encoded: expectedBGRABase64 ?? expectedXRGBBase64 ?? ""),
              expected.count == width * height * 4 else {
            throw BenchmarkInputError.invalidInput("codec reference")
        }
        return (.init(width: width, height: height), encoded, expected)
    }
}

private struct GLZSequence: Decodable {
    let entries: [ReferenceImage]
}

private struct JPEGInput: Decodable, Sendable {
    let file: String
    let width: Int
    let height: Int
    let encodedSHA256: String
    let decodedSHA256: String
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func registerCodecBenchmarks() throws {
    for (name, file, decoder) in [
        ("LZ/reference-6x3", "lz-rgb32-6x3.json", SpiceLZDecoder() as any SpiceImageDecoder),
        ("QUIC/reference-7x5", "quic-rgb32-7x5.json", SpiceQUICDecoder() as any SpiceImageDecoder),
    ] {
        let fixture = try JSONDecoder().decode(ReferenceImage.self, from: resource(file))
        let (descriptor, payload, expected) = try fixture.input()
        Benchmark(name, configuration: .init(scalingFactor: .kilo), closure: { benchmark in
            for _ in benchmark.scaledIterations {
                blackHole(try await decoder.decode(descriptor: descriptor, payload: payload))
            }
        }, setup: {
            let result = try await decoder.decode(descriptor: descriptor, payload: payload)
            try require(result.pixelsBGRA == expected, name)
        })
    }

    let sequence = try JSONDecoder().decode(GLZSequence.self, from: resource("glz-reference-sequence.json"))
    let entries = try sequence.entries.map { try $0.input() }
    Benchmark("GLZ/reference-sequence", closure: { benchmark in
        // Every iteration starts a fresh dictionary; setup is outside timing.
        let decoder = SpiceGLZDecoder()
        benchmark.startMeasurement()
        for (descriptor, payload, _) in entries {
            blackHole(try await decoder.decode(descriptor: descriptor, payload: payload))
        }
        benchmark.stopMeasurement()
    }, setup: {
        let decoder = SpiceGLZDecoder()
        for (descriptor, payload, expected) in entries {
            let result = try await decoder.decode(descriptor: descriptor, payload: payload)
            try require(result.pixelsBGRA == expected, "GLZ reference sequence")
        }
    })

    for input in try JSONDecoder().decode([JPEGInput].self, from: resource("jpeg-manifest.json")) {
        let payload = try resource(input.file)
        try require(sha256(payload) == input.encodedSHA256, input.file)
        let descriptor = SpiceCodecImageDescriptor(width: input.width, height: input.height)
        let decoder = SpiceJPEGDecoder()
        Benchmark("JPEG/\(input.width)x\(input.height)", closure: { _ in
            blackHole(try await decoder.decode(descriptor: descriptor, payload: payload))
        }, setup: {
            let decoded = try await decoder.decode(descriptor: descriptor, payload: payload)
            try require(sha256(decoded.pixelsBGRA) == input.decodedSHA256, input.file)
        })

        let stream = try SpiceMJPEGStreamDecoder(limiter: .init())
        Benchmark("MJPEG/IOSurface/\(input.width)x\(input.height)", closure: { _ in
            blackHole(try await stream.decodeVideoFrame(descriptor: descriptor, payload: payload))
        }, setup: {
            let frame = try await stream.decodeVideoFrame(descriptor: descriptor, payload: payload)
            try require(frame is SpiceMJPEGFrame, "MJPEG unexpectedly fell back to Data")
            try require(sha256(try frame.copyBGRA().pixelsBGRA) == input.decodedSHA256, input.file)
        })
    }
}
