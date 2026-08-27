import Dispatch
import Foundation

package enum SpiceBenchArtifactKind: String, Codable, Sendable {
    case microbenchmark
    case live
}

package struct SpiceBenchMetadata: Codable, Sendable, Equatable {
    package let commit: String
    package let toolchain: String
    package let hardware: String
    package let thermalState: String
    package let workload: String
    package let date: String
    package let source: String
    package let mode: String

    package init(
        commit: String,
        toolchain: String,
        hardware: String,
        thermalState: String,
        workload: String,
        date: String,
        source: String,
        mode: String
    ) {
        self.commit = commit
        self.toolchain = toolchain
        self.hardware = hardware
        self.thermalState = thermalState
        self.workload = workload
        self.date = date
        self.source = source
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case commit, toolchain, hardware, workload, date, source, mode
        case thermalState = "thermal_state"
    }
}

package struct SpiceBenchDurationStatistics: Codable, Sendable, Equatable {
    package let minimumNanoseconds: UInt64
    package let medianNanoseconds: UInt64
    package let meanNanoseconds: Double
    package let p95Nanoseconds: UInt64
    package let maximumNanoseconds: UInt64

    package init(
        minimumNanoseconds: UInt64,
        medianNanoseconds: UInt64,
        meanNanoseconds: Double,
        p95Nanoseconds: UInt64,
        maximumNanoseconds: UInt64
    ) {
        self.minimumNanoseconds = minimumNanoseconds
        self.medianNanoseconds = medianNanoseconds
        self.meanNanoseconds = meanNanoseconds
        self.p95Nanoseconds = p95Nanoseconds
        self.maximumNanoseconds = maximumNanoseconds
    }

    enum CodingKeys: String, CodingKey {
        case minimumNanoseconds = "minimum_nanoseconds"
        case medianNanoseconds = "median_nanoseconds"
        case meanNanoseconds = "mean_nanoseconds"
        case p95Nanoseconds = "p95_nanoseconds"
        case maximumNanoseconds = "maximum_nanoseconds"
    }
}

package struct SpiceBenchCaseResult: Codable, Sendable, Equatable {
    package let id: String
    package let warmUpIterations: Int
    package let measuredIterations: Int
    package let checksum: UInt64
    package let durationSamplesNanoseconds: [UInt64]
    package let duration: SpiceBenchDurationStatistics
    package let exactCounters: [String: UInt64]

    package init(
        id: String,
        warmUpIterations: Int,
        measuredIterations: Int,
        checksum: UInt64,
        durationSamplesNanoseconds: [UInt64],
        duration: SpiceBenchDurationStatistics,
        exactCounters: [String: UInt64]
    ) {
        self.id = id
        self.warmUpIterations = warmUpIterations
        self.measuredIterations = measuredIterations
        self.checksum = checksum
        self.durationSamplesNanoseconds = durationSamplesNanoseconds
        self.duration = duration
        self.exactCounters = exactCounters
    }

    enum CodingKeys: String, CodingKey {
        case id, checksum, duration
        case warmUpIterations = "warm_up_iterations"
        case measuredIterations = "measured_iterations"
        case durationSamplesNanoseconds = "duration_samples_nanoseconds"
        case exactCounters = "exact_counters"
    }
}

package struct SpiceBenchReport: Codable, Sendable, Equatable {
    package static let currentSchemaVersion = 1

    package let schemaVersion: Int
    package let artifactKind: SpiceBenchArtifactKind
    package let metadata: SpiceBenchMetadata
    package let cases: [SpiceBenchCaseResult]

    package init(
        schemaVersion: Int = Self.currentSchemaVersion,
        artifactKind: SpiceBenchArtifactKind,
        metadata: SpiceBenchMetadata,
        cases: [SpiceBenchCaseResult]
    ) {
        self.schemaVersion = schemaVersion
        self.artifactKind = artifactKind
        self.metadata = metadata
        self.cases = cases
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case artifactKind = "artifact_kind"
        case metadata, cases
    }
}

package struct SpiceBenchObservation: Sendable, Equatable {
    package let checksum: UInt64
    package let exactCounters: [String: UInt64]

    package init(checksum: UInt64, exactCounters: [String: UInt64]) {
        self.checksum = checksum
        self.exactCounters = exactCounters
    }
}

package struct SpiceBenchCase: Sendable {
    package let id: String
    package let warmUpIterations: Int
    package let measuredIterations: Int
    package let setUp: @Sendable () async throws -> Void
    package let operation: @Sendable () async throws -> SpiceBenchObservation
    package let tearDown: @Sendable () async -> Void

    package init(
        id: String,
        warmUpIterations: Int,
        measuredIterations: Int,
        setUp: @escaping @Sendable () async throws -> Void = {},
        operation: @escaping @Sendable () async throws -> SpiceBenchObservation,
        tearDown: @escaping @Sendable () async -> Void = {}
    ) {
        self.id = id
        self.warmUpIterations = warmUpIterations
        self.measuredIterations = measuredIterations
        self.setUp = setUp
        self.operation = operation
        self.tearDown = tearDown
    }
}

package enum SpiceBenchError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidIterationCount(caseID: String)
    case duplicateCaseID(String)
    case emptyCatalog
    case nonMonotonicClock
    case zeroChecksum(caseID: String)
    case inconsistentCounters(caseID: String)
    case missingCounter(caseID: String, counter: String)
    case counterInvariant(caseID: String, counter: String, actual: UInt64, expected: String)
    case missingLivePrerequisite(String)
    case liveRequiresExternalRunner
    case debugBuildUnsupported
    case invalidMetadata(field: String)

    package var description: String {
        switch self {
        case let .invalidIterationCount(caseID):
            "invalid iteration count for benchmark case \(caseID)"
        case let .duplicateCaseID(caseID):
            "duplicate benchmark case id \(caseID)"
        case .emptyCatalog:
            "benchmark catalog is empty"
        case .nonMonotonicClock:
            "benchmark clock moved backwards"
        case let .zeroChecksum(caseID):
            "benchmark case \(caseID) produced a zero checksum"
        case let .inconsistentCounters(caseID):
            "benchmark case \(caseID) produced inconsistent exact counters"
        case let .missingCounter(caseID, counter):
            "benchmark case \(caseID) did not report required counter \(counter)"
        case let .counterInvariant(caseID, counter, actual, expected):
            "benchmark case \(caseID) counter \(counter) was \(actual); expected \(expected)"
        case let .missingLivePrerequisite(name):
            "live benchmark prerequisite \(name) is not configured"
        case .liveRequiresExternalRunner:
            "live artifacts require the external paired runner; spice-bench only emits microbenchmark artifacts"
        case .debugBuildUnsupported:
            "spice-bench artifacts require a Release build"
        case let .invalidMetadata(field):
            "benchmark metadata field \(field) is missing or invalid"
        }
    }
}

package enum SpiceBenchBuildConfiguration {
    package static var isRelease: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    package static func requireRelease() throws(SpiceBenchError) {
        guard isRelease else { throw .debugBuildUnsupported }
    }
}

package struct SpiceBenchRunner: Sendable {
    package typealias Clock = @Sendable () -> UInt64

    private let nowNanoseconds: Clock

    package init(
        nowNanoseconds: @escaping Clock = { DispatchTime.now().uptimeNanoseconds }
    ) {
        self.nowNanoseconds = nowNanoseconds
    }

    package func run(
        metadata: SpiceBenchMetadata,
        catalog: [SpiceBenchCase]
    ) async throws -> SpiceBenchReport {
        try Self.validate(metadata: metadata)
        guard !catalog.isEmpty else { throw SpiceBenchError.emptyCatalog }
        var caseIDs = Set<String>()
        for benchmark in catalog {
            guard benchmark.warmUpIterations >= 0, benchmark.measuredIterations > 0 else {
                throw SpiceBenchError.invalidIterationCount(caseID: benchmark.id)
            }
            guard caseIDs.insert(benchmark.id).inserted else {
                throw SpiceBenchError.duplicateCaseID(benchmark.id)
            }
        }
        var results: [SpiceBenchCaseResult] = []
        results.reserveCapacity(catalog.count)
        for benchmark in catalog {
            for _ in 0 ..< benchmark.warmUpIterations {
                _ = try await perform(benchmark, measuring: false)
            }

            var durations: [UInt64] = []
            durations.reserveCapacity(benchmark.measuredIterations)
            var checksum: UInt64 = 0xcbf2_9ce4_8422_2325
            var exactCounters: [String: UInt64]?
            for _ in 0 ..< benchmark.measuredIterations {
                let measured = try await perform(benchmark, measuring: true)
                let observation = measured.observation
                guard observation.checksum != 0 else {
                    throw SpiceBenchError.zeroChecksum(caseID: benchmark.id)
                }
                if let exactCounters, exactCounters != observation.exactCounters {
                    throw SpiceBenchError.inconsistentCounters(caseID: benchmark.id)
                }
                exactCounters = observation.exactCounters
                durations.append(measured.durationNanoseconds)
                checksum ^= observation.checksum
                checksum &*= 0x0000_0100_0000_01b3
            }
            if checksum == 0 { checksum = 1 }
            let counters = exactCounters ?? [:]
            try SpiceBenchCounterValidator.validate(caseID: benchmark.id, counters: counters)
            results.append(
                SpiceBenchCaseResult(
                    id: benchmark.id,
                    warmUpIterations: benchmark.warmUpIterations,
                    measuredIterations: benchmark.measuredIterations,
                    checksum: checksum,
                    durationSamplesNanoseconds: durations,
                    duration: Self.statistics(durations),
                    exactCounters: counters
                )
            )
        }
        return SpiceBenchReport(
            artifactKind: .microbenchmark,
            metadata: metadata,
            cases: results
        )
    }

    private func perform(
        _ benchmark: SpiceBenchCase,
        measuring: Bool
    ) async throws -> (observation: SpiceBenchObservation, durationNanoseconds: UInt64) {
        do {
            try await benchmark.setUp()
        } catch {
            await benchmark.tearDown()
            throw error
        }
        let start = measuring ? nowNanoseconds() : 0
        let outcome: Result<SpiceBenchObservation, any Error>
        do {
            outcome = .success(try await benchmark.operation())
        } catch {
            outcome = .failure(error)
        }
        let end = measuring ? nowNanoseconds() : 0
        await benchmark.tearDown()
        switch outcome {
        case let .success(observation):
            guard !measuring || end >= start else { throw SpiceBenchError.nonMonotonicClock }
            return (
                observation,
                measuring ? end - start : 0
            )
        case let .failure(error):
            throw error
        }
    }

    private static func validate(metadata: SpiceBenchMetadata) throws(SpiceBenchError) {
        let required = [
            ("commit", metadata.commit),
            ("toolchain", metadata.toolchain),
            ("hardware", metadata.hardware),
            ("thermalState", metadata.thermalState),
            ("workload", metadata.workload),
            ("date", metadata.date),
            ("source", metadata.source),
            ("mode", metadata.mode),
        ]
        for (field, value) in required {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, normalized.lowercased() != "unknown" else {
                throw SpiceBenchError.invalidMetadata(field: field)
            }
        }
        guard metadata.mode.lowercased() == "release" else {
            throw SpiceBenchError.invalidMetadata(field: "mode")
        }
    }

    private static func statistics(_ durations: [UInt64]) -> SpiceBenchDurationStatistics {
        let sorted = durations.sorted()
        let total = sorted.reduce(0.0) { $0 + Double($1) }
        let p95Index = max(0, (sorted.count * 95 + 99) / 100 - 1)
        return SpiceBenchDurationStatistics(
            minimumNanoseconds: sorted[0],
            medianNanoseconds: sorted[sorted.count / 2],
            meanNanoseconds: total / Double(sorted.count),
            p95Nanoseconds: sorted[p95Index],
            maximumNanoseconds: sorted[sorted.count - 1]
        )
    }
}

package enum SpiceBenchCounterValidator {
    package static func validate(
        caseID: String,
        counters: [String: UInt64]
    ) throws(SpiceBenchError) {
        switch caseID {
        case "wire.contiguous":
            try require(counters, caseID: caseID, counter: "bodyCopyBytes", equals: 0)
            try require(counters, caseID: caseID, counter: "bodyCoalesces", equals: 0)
            try require(counters, caseID: caseID, counter: "queueCompactionBytes", equals: 0)
        case "wire.fragmented":
            try require(counters, caseID: caseID, counter: "bodyCoalesces", equals: 1)
            try require(counters, caseID: caseID, counter: "queueCompactionBytes", equals: 0)
            let copied = try value(counters, caseID: caseID, counter: "bodyCopyBytes")
            let body = try value(counters, caseID: caseID, counter: "bodyBytes")
            guard copied <= body else {
                throw .counterInvariant(
                    caseID: caseID,
                    counter: "bodyCopyBytes",
                    actual: copied,
                    expected: "at most bodyBytes (\(body))"
                )
            }
        case "copy_bits":
            try require(counters, caseID: caseID, counter: "mutationTransactions", equals: 1)
            try require(counters, caseID: caseID, counter: "temporaryCopyBytes", equals: 0)
            try require(counters, caseID: caseID, counter: "bulkCopyCalls", equals: 1)
            try require(counters, caseID: caseID, counter: "rowCopyCalls", equals: 0)
        case "lz":
            try require(
                counters,
                caseID: caseID,
                counter: "decodedOutputAllocations",
                equals: 1
            )
            try require(
                counters,
                caseID: caseID,
                counter: "temporaryDecodedBackingAllocations",
                equals: 0
            )
            try require(
                counters,
                caseID: caseID,
                counter: "temporaryDecodedBackingBytes",
                equals: 0
            )
            let referencePixels = try value(
                counters,
                caseID: caseID,
                counter: "overlapReferencePixels"
            )
            guard referencePixels > 0 else {
                throw .counterInvariant(
                    caseID: caseID,
                    counter: "overlapReferencePixels",
                    actual: referencePixels,
                    expected: "greater than zero"
                )
            }
            let calls = try value(
                counters,
                caseID: caseID,
                counter: "referenceBulkCopyCalls"
            )
            guard calls > 0 else {
                throw .counterInvariant(
                    caseID: caseID,
                    counter: "referenceBulkCopyCalls",
                    actual: calls,
                    expected: "greater than zero"
                )
            }
            let (expectedBytes, overflow) = referencePixels.multipliedReportingOverflow(by: 4)
            guard !overflow else {
                throw .counterInvariant(
                    caseID: caseID,
                    counter: "overlapReferencePixels",
                    actual: referencePixels,
                    expected: "a byte-count-safe pixel value"
                )
            }
            try require(
                counters,
                caseID: caseID,
                counter: "referenceBulkCopyBytes",
                equals: expectedBytes
            )
        case "glz":
            try require(
                counters,
                caseID: caseID,
                counter: "pendingDictionaryWaitBytes",
                equals: 0
            )
            let referencePixels = try value(
                counters,
                caseID: caseID,
                counter: "overlapReferencePixels"
            )
            guard referencePixels > 0 else {
                throw .counterInvariant(
                    caseID: caseID,
                    counter: "overlapReferencePixels",
                    actual: referencePixels,
                    expected: "greater than zero"
                )
            }
        case "iosurface.transition":
            try require(
                counters,
                caseID: caseID,
                counter: "revisionedBackingEnabled",
                equals: 1
            )
            try require(counters, caseID: caseID, counter: "bulkCopyCalls", equals: 1)
            try require(counters, caseID: caseID, counter: "rowCopyCalls", equals: 0)
            try require(counters, caseID: caseID, counter: "cpuMaterializationBytes", equals: 0)
            try require(counters, caseID: caseID, counter: "cpuMaterializations", equals: 0)
            try require(
                counters,
                caseID: caseID,
                counter: "directIOSurfaceWriteBytes",
                equals: 4
            )
        case "advanced_video.sample":
            try require(counters, caseID: caseID, counter: "scanPassCount", equals: 1)
            try require(counters, caseID: caseID, counter: "inputCopyBytes", equals: 0)
            try require(
                counters,
                caseID: caseID,
                counter: "nalPayloadMaterializations",
                equals: 0
            )
            try require(counters, caseID: caseID, counter: "nalPayloadCopyBytes", equals: 0)
            try require(counters, caseID: caseID, counter: "avccSampleAllocations", equals: 1)
            try require(counters, caseID: caseID, counter: "samplePayloadCopyBytes", equals: 0)
        default:
            break
        }
    }

    private static func value(
        _ counters: [String: UInt64],
        caseID: String,
        counter: String
    ) throws(SpiceBenchError) -> UInt64 {
        guard let value = counters[counter] else {
            throw .missingCounter(caseID: caseID, counter: counter)
        }
        return value
    }

    private static func require(
        _ counters: [String: UInt64],
        caseID: String,
        counter: String,
        equals expected: UInt64
    ) throws(SpiceBenchError) {
        let actual = try value(counters, caseID: caseID, counter: counter)
        guard actual == expected else {
            throw .counterInvariant(
                caseID: caseID,
                counter: counter,
                actual: actual,
                expected: String(expected)
            )
        }
    }
}

package struct SpiceBenchLivePrerequisites: Sendable, Equatable {
    package let endpoint: String
    package let credentialEnvironmentVariable: String

    package init(endpoint: String, credentialEnvironmentVariable: String) {
        self.endpoint = endpoint
        self.credentialEnvironmentVariable = credentialEnvironmentVariable
    }

    package static func resolve(
        environment: [String: String]
    ) throws(SpiceBenchError) -> Self {
        guard let endpoint = environment["SPICE_BENCH_ENDPOINT"], !endpoint.isEmpty else {
            throw .missingLivePrerequisite("SPICE_BENCH_ENDPOINT")
        }
        guard let password = environment["SPICE_PASSWORD"], !password.isEmpty else {
            throw .missingLivePrerequisite("SPICE_PASSWORD")
        }
        return SpiceBenchLivePrerequisites(
            endpoint: endpoint,
            credentialEnvironmentVariable: "SPICE_PASSWORD"
        )
    }
}
