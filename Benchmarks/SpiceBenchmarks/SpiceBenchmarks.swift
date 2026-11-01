import Benchmark
import Foundation

let benchmarks: @Sendable () -> Void = {
    Benchmark.defaultConfiguration = .init(
        metrics: [.wallClock, .cpuTotal, .throughput, .mallocCountTotal],
        warmupIterations: 5,
        maxDuration: .seconds(2),
        maxIterations: 1_000
    )
    do {
        try registerCodecBenchmarks()
        try registerWireBenchmarks()
        registerSurfaceBenchmarks()
    } catch {
        fatalError("Cannot register benchmarks: \(error)")
    }
}

enum BenchmarkInputError: Error {
    case missingResource(String)
    case invalidInput(String)
    case incorrectResult(String)
}

func resource(_ name: String) throws -> Data {
    if name.hasSuffix(".jpg"),
       let path = ProcessInfo.processInfo.environment["SWIFTSPICE_BENCHMARK_FIXTURES"] {
        return try Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(name))
    }
    guard let url = Bundle.module.url(forResource: name, withExtension: nil) else {
        throw BenchmarkInputError.missingResource(name)
    }
    return try Data(contentsOf: url)
}

func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw BenchmarkInputError.incorrectResult(message) }
}
