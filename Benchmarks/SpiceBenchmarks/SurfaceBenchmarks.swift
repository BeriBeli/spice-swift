import Benchmark
import Foundation
import SpiceRenderer

private enum SurfaceOperation: String, CaseIterable, Sendable {
    case fill = "fill"
    case copy = "copy-bits"
    case partial = "partial-fill-64x64"
    case publish = "iosurface-publish"
    case readback = "iosurface-cpu-readback"
}

func registerSurfaceBenchmarks() {
    for (width, height) in [(1_920, 1_080), (3_840, 2_160)] {
        for operation in SurfaceOperation.allCases {
            Benchmark("Surface/\(operation.rawValue)/\(width)x\(height)") { benchmark in
                let native = operation == .publish || operation == .readback
                let store = SurfaceStore(backingPolicy: native ? .automatic : .dataOnly)
                try await store.create(id: 1, width: UInt32(width), height: UInt32(height), format: 32)
                try await store.fill(
                    surfaceID: 1,
                    rectangle: .init(x: 0, y: 0, width: width, height: height),
                    colorARGB: 0x0011_2233
                )
                if operation == .copy {
                    try await store.fill(
                        surfaceID: 1,
                        rectangle: .init(x: 0, y: 0, width: width / 2, height: height / 2),
                        colorARGB: 0x00aa_bbcc
                    )
                }
                // A new frame for each readback prevents timing the cached Data getter.
                let input = operation == .readback ? try await store.snapshot(surfaceID: 1) : nil
                if let input {
                    try require(input.ioSurfaceFrame != nil, "readback requires IOSurface")
                }
                benchmark.startMeasurement()
                switch operation {
                case .fill, .partial:
                    try await store.fill(
                        surfaceID: 1,
                        rectangle: .init(x: 0, y: 0,
                                         width: operation == .fill ? width : 64,
                                         height: operation == .fill ? height : 64),
                        colorARGB: 0x00aa_bbcc
                    )
                case .copy:
                    try await store.copyBits(
                        surfaceID: 1,
                        destination: .init(x: width / 2, y: height / 2,
                                           width: width / 2, height: height / 2),
                        sourceX: 0, sourceY: 0
                    )
                case .publish:
                    let frame = try await store.snapshot(surfaceID: 1)
                    benchmark.stopMeasurement()
                    try require(frame.ioSurfaceFrame != nil, "publication requires IOSurface")
                    blackHole(frame)
                case .readback:
                    blackHole(input!.pixels)
                }
                if operation != .publish { benchmark.stopMeasurement() }
                // Result checks and cleanup stay outside the measurement window.
                let output = try await store.snapshot(surfaceID: 1)
                let pixels = output.pixels
                let offset = operation == .copy ? ((height / 2) * width + width / 2) * 4 : 0
                let expected: [UInt8] = native ? [0x33, 0x22, 0x11, 0xff] : [0xcc, 0xbb, 0xaa, 0xff]
                try require(Array(pixels[offset..<offset + 4]) == expected, operation.rawValue)
                try await store.destroy(id: 1)
            }
        }
    }
}
