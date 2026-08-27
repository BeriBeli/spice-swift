import Foundation
import Synchronization
import Testing
import SpiceBenchSupport

@Suite("spice-bench artifact contract")
struct SpiceBenchTests {
    @Test("JSON schema is stable, complete, and round-trips")
    func jsonSchemaRoundTrips() throws {
        let report = SpiceBenchReport(
            artifactKind: .microbenchmark,
            metadata: fixtureMetadata,
            cases: [
                SpiceBenchCaseResult(
                    id: "wire.contiguous",
                    warmUpIterations: 2,
                    measuredIterations: 3,
                    checksum: 0x1234,
                    durationSamplesNanoseconds: [10, 20, 40],
                    duration: SpiceBenchDurationStatistics(
                        minimumNanoseconds: 10,
                        medianNanoseconds: 20,
                        meanNanoseconds: 22.5,
                        p95Nanoseconds: 40,
                        maximumNanoseconds: 40
                    ),
                    exactCounters: ["bodyCopyBytes": 0]
                ),
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(report)
        let decoded = try JSONDecoder().decode(SpiceBenchReport.self, from: encoded)
        #expect(decoded == report)

        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(Set(json.keys) == ["artifact_kind", "cases", "metadata", "schema_version"])
        #expect(json["schema_version"] as? Int == SpiceBenchReport.currentSchemaVersion)
        #expect(json["artifact_kind"] as? String == "microbenchmark")

        let metadata = try #require(json["metadata"] as? [String: Any])
        #expect(Set(metadata.keys) == [
            "commit", "toolchain", "hardware", "thermal_state",
            "workload", "date", "source", "mode",
        ])

        let cases = try #require(json["cases"] as? [[String: Any]])
        let result = try #require(cases.first)
        #expect(Set(result.keys) == [
            "id", "warm_up_iterations", "measured_iterations", "checksum",
            "duration_samples_nanoseconds", "duration", "exact_counters",
        ])
        #expect(result["duration_samples_nanoseconds"] as? [Int] == [10, 20, 40])
        let counters = try #require(result["exact_counters"] as? [String: Any])
        #expect(Set(counters.keys) == ["bodyCopyBytes"])
        #expect(counters["bodyCopyBytes"] as? Int == 0)

        var missingRequiredMetadata = json
        var incompleteMetadata = metadata
        incompleteMetadata.removeValue(forKey: "hardware")
        missingRequiredMetadata["metadata"] = incompleteMetadata
        let incompleteJSON = try JSONSerialization.data(withJSONObject: missingRequiredMetadata)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SpiceBenchReport.self, from: incompleteJSON)
        }
    }

    @Test("runner excludes warm-up from timing and retains anti-DCE evidence")
    func runnerExcludesWarmUpFromTiming() async throws {
        let executionCount = Mutex(0)
        let clockState = Mutex((calls: 0, now: UInt64(100)))
        let runner = SpiceBenchRunner {
            clockState.withLock { state in
                state.calls += 1
                defer { state.now += 10 }
                return state.now
            }
        }
        let benchmark = SpiceBenchCase(
            id: "wire.contiguous",
            warmUpIterations: 2,
            measuredIterations: 3
        ) {
            let invocation = executionCount.withLock { count in
                count += 1
                return count
            }
            return SpiceBenchObservation(
                checksum: UInt64(invocation),
                exactCounters: [
                    "bodyCopyBytes": 0,
                    "bodyCoalesces": 0,
                    "queueCompactionBytes": 0,
                ]
            )
        }

        let report = try await runner.run(metadata: fixtureMetadata, catalog: [benchmark])
        let result = try #require(report.cases.first)
        #expect(report.artifactKind == .microbenchmark)
        #expect(executionCount.withLock { $0 } == 5)
        #expect(clockState.withLock { $0.calls } == 6)
        #expect(result.warmUpIterations == 2)
        #expect(result.measuredIterations == 3)
        #expect(result.checksum != 0)
        #expect(result.durationSamplesNanoseconds == [10, 10, 10])
        #expect(result.duration == SpiceBenchDurationStatistics(
            minimumNanoseconds: 10,
            medianNanoseconds: 10,
            meanNanoseconds: 10,
            p95Nanoseconds: 10,
            maximumNanoseconds: 10
        ))
    }

    @Test("fixture preparation and teardown stay outside measured timing")
    func fixtureLifecycleIsOutsideMeasuredTiming() async throws {
        let events = Mutex<[String]>([])
        let runner = SpiceBenchRunner {
            events.withLock { $0.append("clock") }
            return 100
        }
        let benchmark = SpiceBenchCase(
            id: "wire.contiguous",
            warmUpIterations: 1,
            measuredIterations: 2,
            setUp: {
                events.withLock { $0.append("setUp") }
            },
            operation: {
                events.withLock { $0.append("operation") }
                return SpiceBenchObservation(
                    checksum: 1,
                    exactCounters: [
                        "bodyCopyBytes": 0,
                        "bodyCoalesces": 0,
                        "queueCompactionBytes": 0,
                    ]
                )
            },
            tearDown: {
                events.withLock { $0.append("tearDown") }
            }
        )

        _ = try await runner.run(metadata: fixtureMetadata, catalog: [benchmark])
        #expect(events.withLock { $0 } == [
            "setUp", "operation", "tearDown",
            "setUp", "clock", "operation", "clock", "tearDown",
            "setUp", "clock", "operation", "clock", "tearDown",
        ])

        let failedEvents = Mutex<[String]>([])
        let failing = SpiceBenchCase(
            id: "fixture.failure",
            warmUpIterations: 0,
            measuredIterations: 1,
            setUp: {
                failedEvents.withLock { $0.append("setUp") }
            },
            operation: {
                failedEvents.withLock { $0.append("operation") }
                throw FixtureError.injected
            },
            tearDown: {
                failedEvents.withLock { $0.append("tearDown") }
            }
        )
        await #expect(throws: FixtureError.injected) {
            _ = try await runner.run(metadata: fixtureMetadata, catalog: [failing])
        }
        #expect(failedEvents.withLock { $0 } == ["setUp", "operation", "tearDown"])
    }

    @Test("even sample medians average both middle values without truncation")
    func evenSampleMedianUsesBothMiddleValues() async throws {
        let clock = Mutex((index: 0, values: [
            UInt64(100), 110,
            200, 220,
            300, 331,
            400, 440,
        ]))
        let runner = SpiceBenchRunner {
            clock.withLock { state in
                let value = state.values[state.index]
                state.index += 1
                return value
            }
        }
        let benchmark = SpiceBenchCase(
            id: "wire.contiguous",
            warmUpIterations: 0,
            measuredIterations: 4
        ) {
            SpiceBenchObservation(
                checksum: 1,
                exactCounters: [
                    "bodyCopyBytes": 0,
                    "bodyCoalesces": 0,
                    "queueCompactionBytes": 0,
                ]
            )
        }

        let report = try await runner.run(metadata: fixtureMetadata, catalog: [benchmark])
        let result = try #require(report.cases.first)
        #expect(result.durationSamplesNanoseconds == [10, 20, 31, 40])
        #expect(result.duration.medianNanoseconds == 25.5)
        #expect(result.duration.meanNanoseconds == 25.25)

        let encoded = try JSONEncoder().encode(report)
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let cases = try #require(json["cases"] as? [[String: Any]])
        let duration = try #require(cases.first?["duration"] as? [String: Any])
        #expect(duration["median_nanoseconds"] as? Double == 25.5)
    }

    @Test("metadata preflight rejects empty, unknown, and non-Release evidence")
    func metadataPreflightRejectsPlaceholders() async {
        let executions = Mutex(0)
        let benchmark = SpiceBenchCase(
            id: "wire.contiguous",
            warmUpIterations: 0,
            measuredIterations: 1
        ) {
            executions.withLock { $0 += 1 }
            return SpiceBenchObservation(checksum: 1, exactCounters: ["bodyCopyBytes": 0])
        }
        let runner = SpiceBenchRunner(nowNanoseconds: { 1 })
        let requiredFields = [
            "commit", "toolchain", "hardware", "thermalState",
            "workload", "date", "source", "mode",
        ]

        for field in requiredFields {
            for placeholder in ["", "   ", "unknown", "  UNKNOWN  "] {
                let metadata = fixtureMetadata(replacing: field, with: placeholder)
                await #expect(throws: SpiceBenchError.invalidMetadata(field: field)) {
                    _ = try await runner.run(metadata: metadata, catalog: [benchmark])
                }
            }
        }
        await #expect(throws: SpiceBenchError.invalidMetadata(field: "mode")) {
            _ = try await runner.run(
                metadata: fixtureMetadata(replacing: "mode", with: "debug"),
                catalog: [benchmark]
            )
        }
        #expect(executions.withLock { $0 } == 0)
    }

    @Test("build configuration reports whether Release evidence is truthful")
    func buildConfigurationIsTruthful() throws {
        if SpiceBenchBuildConfiguration.isRelease {
            try SpiceBenchBuildConfiguration.requireRelease()
        } else {
            #expect(throws: SpiceBenchError.debugBuildUnsupported) {
                try SpiceBenchBuildConfiguration.requireRelease()
            }
        }
    }

    @Test("repository preflight rejects tracked and untracked dirt before work")
    func repositoryPreflightRequiresStableCleanRevision() async throws {
        let cleanCalls = Mutex(0)
        let cleanWork = Mutex(0)
        let clean = SpiceBenchRepositoryPreflight {
            cleanCalls.withLock { $0 += 1 }
            return SpiceBenchRepositoryState(commit: "abc123", porcelainStatus: "")
        }
        let cleanCommit: String = try await clean.withCleanRepository { commit in
            cleanWork.withLock { $0 += 1 }
            return commit
        }
        #expect(cleanCommit == "abc123")
        #expect(cleanCalls.withLock { $0 } == 2)
        #expect(cleanWork.withLock { $0 } == 1)

        for dirtyStatus in [" M Sources/File.swift", "?? untracked.fixture"] {
            let providerCalls = Mutex(0)
            let work = Mutex(0)
            let dirty = SpiceBenchRepositoryPreflight {
                providerCalls.withLock { $0 += 1 }
                return SpiceBenchRepositoryState(
                    commit: "abc123",
                    porcelainStatus: dirtyStatus
                )
            }
            await #expect(throws: SpiceBenchError.dirtyWorktree) {
                let _: String = try await dirty.withCleanRepository { commit in
                    work.withLock { $0 += 1 }
                    return commit
                }
            }
            #expect(providerCalls.withLock { $0 } == 1)
            #expect(work.withLock { $0 } == 0)
        }

        let states = Mutex([
            SpiceBenchRepositoryState(commit: "abc123", porcelainStatus: ""),
            SpiceBenchRepositoryState(commit: "def456", porcelainStatus: ""),
        ])
        let changedWork = Mutex(0)
        let changedProvider: SpiceBenchRepositoryPreflight.StateProvider = {
            let state = states.withLock { states -> SpiceBenchRepositoryState? in
                states.isEmpty ? nil : states.removeFirst()
            }
            guard let state else { throw SpiceBenchError.repositoryStateUnavailable }
            return state
        }
        let changed = SpiceBenchRepositoryPreflight(stateProvider: changedProvider)
        await #expect(throws: SpiceBenchError.repositoryChanged) {
            let _: String = try await changed.withCleanRepository { commit in
                changedWork.withLock { $0 += 1 }
                return commit
            }
        }
        #expect(changedWork.withLock { $0 } == 1)
    }

    @Test("toolchain evidence comes only from exact injected build metadata")
    func toolchainEvidenceIsExactAndRequired() throws {
        let executableKey = SpiceBenchToolchainEvidence.executableEnvironmentKey
        let versionKey = SpiceBenchToolchainEvidence.versionEnvironmentKey
        #expect(executableKey == "SPICE_BENCH_SWIFT_EXECUTABLE")
        #expect(versionKey == "SPICE_BENCH_SWIFT_VERSION")

        #expect(throws: SpiceBenchError.missingToolchainEvidence(executableKey)) {
            _ = try SpiceBenchToolchainEvidence.resolve(environment: [:])
        }
        #expect(throws: SpiceBenchError.missingToolchainEvidence(versionKey)) {
            _ = try SpiceBenchToolchainEvidence.resolve(environment: [
                executableKey: "/toolchain/usr/bin/swift",
            ])
        }
        let unknown = try SpiceBenchToolchainEvidence.resolve(environment: [
            executableKey: "/toolchain/usr/bin/swift",
            versionKey: "unknown",
        ])
        #expect(throws: SpiceBenchError.toolchainEvidenceMismatch) {
            _ = try unknown.validatedVersion(observedVersion: "unknown")
        }

        let exactVersion = "Apple Swift version 6.4 (fixture-build)"
        let evidence = try SpiceBenchToolchainEvidence.resolve(environment: [
            executableKey: "/toolchain/usr/bin/swift",
            versionKey: exactVersion,
        ])
        #expect(evidence.executablePath == "/toolchain/usr/bin/swift")
        #expect(evidence.capturedVersion == exactVersion)
        #expect(try evidence.validatedVersion(observedVersion: exactVersion) == exactVersion)
        #expect(throws: SpiceBenchError.toolchainEvidenceMismatch) {
            _ = try evidence.validatedVersion(
                observedVersion: "Apple Swift version 6.4 (different-toolchain)"
            )
        }
        let fallbackCommand = SpiceBenchToolchainEvidence(
            executablePath: "xcrun",
            capturedVersion: exactVersion
        )
        #expect(throws: SpiceBenchError.toolchainEvidenceMismatch) {
            _ = try fallbackCommand.validatedVersion(observedVersion: exactVersion)
        }
    }

    @Test("runner rejects invalid catalogs and observations deterministically")
    func runnerRejectsInvalidInputs() async {
        let runner = SpiceBenchRunner(nowNanoseconds: { 1 })
        await #expect(throws: SpiceBenchError.emptyCatalog) {
            _ = try await runner.run(metadata: fixtureMetadata, catalog: [])
        }
        let invalidIterationCatalog = SpiceBenchCatalog.microbenchmarks(
            warmUpIterations: -1,
            measuredIterations: 1
        )
        await #expect(throws: SpiceBenchError.invalidIterationCount(
            caseID: "wire.contiguous"
        )) {
            _ = try await runner.run(
                metadata: fixtureMetadata,
                catalog: invalidIterationCatalog
            )
        }

        let duplicate = SpiceBenchCase(
            id: "wire.contiguous",
            warmUpIterations: 0,
            measuredIterations: 1
        ) {
            SpiceBenchObservation(checksum: 1, exactCounters: ["bodyCopyBytes": 0])
        }
        await #expect(throws: SpiceBenchError.duplicateCaseID("wire.contiguous")) {
            _ = try await runner.run(metadata: fixtureMetadata, catalog: [duplicate, duplicate])
        }

        let zeroChecksum = SpiceBenchCase(
            id: "wire.contiguous",
            warmUpIterations: 0,
            measuredIterations: 1
        ) {
            SpiceBenchObservation(checksum: 0, exactCounters: ["bodyCopyBytes": 0])
        }
        await #expect(throws: SpiceBenchError.zeroChecksum(caseID: "wire.contiguous")) {
            _ = try await runner.run(metadata: fixtureMetadata, catalog: [zeroChecksum])
        }

        let invocation = Mutex(0)
        let inconsistentCounters = SpiceBenchCase(
            id: "wire.contiguous",
            warmUpIterations: 0,
            measuredIterations: 2
        ) {
            let count = invocation.withLock { value in
                value += 1
                return value
            }
            return SpiceBenchObservation(
                checksum: 1,
                exactCounters: ["bodyCopyBytes": UInt64(count - 1)]
            )
        }
        await #expect(throws: SpiceBenchError.inconsistentCounters(caseID: "wire.contiguous")) {
            _ = try await runner.run(metadata: fixtureMetadata, catalog: [inconsistentCounters])
        }
    }

    @Test("catalog IDs and order are stable and unique")
    func catalogIDsAreStable() {
        #expect(SpiceBenchCatalog.workloadID == "aip-00.micro.v2")

        let expected = [
            "wire.contiguous",
            "wire.fragmented",
            "region.normalization",
            "copy_bits",
            "lz",
            "glz",
            "iosurface.transition",
            "advanced_video.sample",
        ]
        let catalog = SpiceBenchCatalog.microbenchmarks(
            warmUpIterations: 1,
            measuredIterations: 1
        )
        #expect(SpiceBenchCatalog.stableCaseIDs == expected)
        #expect(catalog.map(\.id) == expected)
        #expect(Set(catalog.map(\.id)).count == expected.count)
        #expect(catalog.allSatisfy { $0.warmUpIterations == 1 })
        #expect(catalog.allSatisfy { $0.measuredIterations == 1 })
    }

    @Test("microbenchmark catalog executes every required workload with PLAN counters")
    func catalogWorkloadsProduceAcceptanceEvidence() async throws {
        let clock = Mutex(UInt64(0))
        let runner = SpiceBenchRunner {
            clock.withLock { value in
                value += 1
                return value
            }
        }
        let catalog = SpiceBenchCatalog.microbenchmarks(
            warmUpIterations: 1,
            measuredIterations: 1
        )
        let report: SpiceBenchReport
        let supportsRevisionedIOSurface: Bool
        do {
            report = try await runner.run(metadata: fixtureMetadata, catalog: catalog)
            supportsRevisionedIOSurface = true
        } catch SpiceBenchError.unsupportedCapability(let capability)
            where capability == "revisioned-iosurface"
        {
            let remainingCatalog = catalog.filter { $0.id != "iosurface.transition" }
            report = try await runner.run(
                metadata: fixtureMetadata,
                catalog: remainingCatalog
            )
            supportsRevisionedIOSurface = false

            let ioSurfaceCase = try #require(
                catalog.first { $0.id == "iosurface.transition" }
            )
            await #expect(throws: SpiceBenchError.unsupportedCapability(
                "revisioned-iosurface"
            )) {
                _ = try await runner.run(
                    metadata: fixtureMetadata,
                    catalog: [ioSurfaceCase]
                )
            }
        }

        #expect(report.artifactKind == .microbenchmark)
        let expectedIDs = SpiceBenchCatalog.stableCaseIDs.filter {
            supportsRevisionedIOSurface || $0 != "iosurface.transition"
        }
        #expect(report.cases.map(\.id) == expectedIDs)
        #expect(report.cases.allSatisfy { $0.checksum != 0 })
        #expect(report.cases.allSatisfy {
            $0.durationSamplesNanoseconds.count == $0.measuredIterations
        })
        for result in report.cases {
            try SpiceBenchCounterValidator.validate(
                caseID: result.id,
                counters: result.exactCounters
            )
        }

        let byID = Dictionary(uniqueKeysWithValues: report.cases.map { ($0.id, $0) })
        let contiguous = try #require(byID["wire.contiguous"])
        #expect(contiguous.exactCounters["bodyCopyBytes"] == 0)
        #expect(contiguous.exactCounters["bodyCoalesces"] == 0)
        #expect(contiguous.exactCounters["queueCompactionBytes"] == 0)

        let fragmented = try #require(byID["wire.fragmented"])
        let copied = try #require(fragmented.exactCounters["bodyCopyBytes"])
        let body = try #require(fragmented.exactCounters["bodyBytes"])
        #expect(copied <= body)
        #expect(fragmented.exactCounters["bodyCoalesces"] == 1)
        #expect(fragmented.exactCounters["queueCompactionBytes"] == 0)

        let region = try #require(byID["region.normalization"])
        #expect(region.exactCounters["inputClips"] == 512)
        #expect(try #require(region.exactCounters["normalizedBands"]) > 0)
        #expect(try #require(region.exactCounters["normalizedSegments"]) > 0)

        let copyBits = try #require(byID["copy_bits"])
        #expect(copyBits.exactCounters["mutationTransactions"] == 1)
        #expect(copyBits.exactCounters["temporaryCopyBytes"] == 0)
        #expect(copyBits.exactCounters["bulkCopyCalls"] == 1)
        #expect(copyBits.exactCounters["rowCopyCalls"] == 0)

        let lz = try #require(byID["lz"])
        #expect(lz.exactCounters["decodedOutputAllocations"] == 1)
        #expect(lz.exactCounters["temporaryDecodedBackingAllocations"] == 0)
        #expect(lz.exactCounters["temporaryDecodedBackingBytes"] == 0)
        #expect(try #require(lz.exactCounters["referenceBulkCopyCalls"]) > 0)
        #expect(lz.exactCounters["referenceBulkCopyBytes"] == 65_532)
        #expect(lz.exactCounters["overlapReferencePixels"] == 16_383)

        let glz = try #require(byID["glz"])
        #expect(glz.exactCounters["pendingDictionaryWaitBytes"] == 0)
        #expect(glz.exactCounters["overlapReferencePixels"] == 16_383)

        if supportsRevisionedIOSurface {
            let ioSurface = try #require(byID["iosurface.transition"])
            #expect(ioSurface.exactCounters["cpuMaterializationBytes"] == 0)
            #expect(ioSurface.exactCounters["cpuMaterializations"] == 0)
            #expect(ioSurface.exactCounters["directIOSurfaceWriteBytes"] == 4)
        } else {
            #expect(byID["iosurface.transition"] == nil)
        }

        let video = try #require(byID["advanced_video.sample"])
        #expect(video.exactCounters["scanPassCount"] == 1)
        #expect(video.exactCounters["inputCopyBytes"] == 0)
        #expect(video.exactCounters["nalPayloadMaterializations"] == 0)
        #expect(video.exactCounters["nalPayloadCopyBytes"] == 0)
        #expect(video.exactCounters["avccSampleAllocations"] == 1)
        #expect(video.exactCounters["samplePayloadCopyBytes"] == 0)
        let avccPayloadWriteBytes = try #require(
            video.exactCounters["avccPayloadWriteBytes"]
        )
        let avccSampleBytes = try #require(video.exactCounters["avccSampleBytes"])
        let nalUnitCount = try #require(video.exactCounters["nalUnitCount"])
        #expect(avccPayloadWriteBytes > 0)
        #expect(avccPayloadWriteBytes + 4 * nalUnitCount == avccSampleBytes)
    }

    @Test("counter validator rejects missing and nonconforming acceptance evidence")
    func counterValidatorRejectsInvalidEvidence() throws {
        #expect(throws: SpiceBenchError.missingCounter(
            caseID: "wire.contiguous",
            counter: "bodyCopyBytes"
        )) {
            try SpiceBenchCounterValidator.validate(caseID: "wire.contiguous", counters: [:])
        }
        #expect(throws: SpiceBenchError.counterInvariant(
            caseID: "copy_bits",
            counter: "temporaryCopyBytes",
            actual: 4,
            expected: "0"
        )) {
            try SpiceBenchCounterValidator.validate(
                caseID: "copy_bits",
                counters: [
                    "mutationTransactions": 1,
                    "temporaryCopyBytes": 4,
                    "bulkCopyCalls": 1,
                    "rowCopyCalls": 0,
                ]
            )
        }

        for contract in owningCounterContracts {
            try SpiceBenchCounterValidator.validate(
                caseID: contract.caseID,
                counters: contract.validCounters
            )
            for mutation in contract.rejectedMutations {
                var invalidCounters = contract.validCounters
                invalidCounters[mutation.counter] = mutation.actual
                #expect(throws: SpiceBenchError.counterInvariant(
                    caseID: contract.caseID,
                    counter: mutation.counter,
                    actual: mutation.actual,
                    expected: mutation.expected
                )) {
                    try SpiceBenchCounterValidator.validate(
                        caseID: contract.caseID,
                        counters: invalidCounters
                    )
                }
            }
        }
    }

    @Test("live prerequisites are explicit and never inferred")
    func livePrerequisitesAreExplicit() throws {
        #expect(throws: SpiceBenchError.missingLivePrerequisite("SPICE_BENCH_ENDPOINT")) {
            _ = try SpiceBenchLivePrerequisites.resolve(environment: [:])
        }
        #expect(throws: SpiceBenchError.missingLivePrerequisite("SPICE_PASSWORD")) {
            _ = try SpiceBenchLivePrerequisites.resolve(environment: [
                "SPICE_BENCH_ENDPOINT": "spice://fixture.invalid:5900",
            ])
        }

        let resolved = try SpiceBenchLivePrerequisites.resolve(environment: [
            "SPICE_BENCH_ENDPOINT": "spice://fixture.invalid:5900",
            "SPICE_PASSWORD": "fixture-secret",
        ])
        #expect(resolved.endpoint == "spice://fixture.invalid:5900")
        #expect(resolved.credentialEnvironmentVariable == "SPICE_PASSWORD")
    }

    private var fixtureMetadata: SpiceBenchMetadata {
        SpiceBenchMetadata(
            commit: "0123456789abcdef",
            toolchain: "Swift 6.3",
            hardware: "fixture-machine",
            thermalState: "nominal",
            workload: "microbenchmark-catalog-v1",
            date: "2026-08-28T00:00:00Z",
            source: "spice-bench",
            mode: "release"
        )
    }

    private func fixtureMetadata(replacing field: String, with value: String) -> SpiceBenchMetadata {
        let metadata = fixtureMetadata
        return SpiceBenchMetadata(
            commit: field == "commit" ? value : metadata.commit,
            toolchain: field == "toolchain" ? value : metadata.toolchain,
            hardware: field == "hardware" ? value : metadata.hardware,
            thermalState: field == "thermalState" ? value : metadata.thermalState,
            workload: field == "workload" ? value : metadata.workload,
            date: field == "date" ? value : metadata.date,
            source: field == "source" ? value : metadata.source,
            mode: field == "mode" ? value : metadata.mode
        )
    }

    private var owningCounterContracts: [CounterContract] {
        [
            CounterContract(
                caseID: "wire.contiguous",
                validCounters: [
                    "bodyCopyBytes": 0,
                    "bodyCoalesces": 0,
                    "queueCompactionBytes": 0,
                ],
                rejectedMutations: [
                    CounterMutation(counter: "bodyCopyBytes", actual: 1, expected: "0"),
                    CounterMutation(counter: "bodyCoalesces", actual: 1, expected: "0"),
                    CounterMutation(counter: "queueCompactionBytes", actual: 1, expected: "0"),
                ]
            ),
            CounterContract(
                caseID: "wire.fragmented",
                validCounters: [
                    "bodyBytes": 256,
                    "bodyCopyBytes": 256,
                    "bodyCoalesces": 1,
                    "queueCompactionBytes": 0,
                ],
                rejectedMutations: [
                    CounterMutation(
                        counter: "bodyCopyBytes",
                        actual: 257,
                        expected: "at most bodyBytes (256)"
                    ),
                    CounterMutation(counter: "bodyCoalesces", actual: 0, expected: "1"),
                    CounterMutation(counter: "queueCompactionBytes", actual: 1, expected: "0"),
                ]
            ),
            CounterContract(
                caseID: "lz",
                validCounters: [
                    "decodedOutputAllocations": 1,
                    "temporaryDecodedBackingAllocations": 0,
                    "temporaryDecodedBackingBytes": 0,
                    "overlapReferencePixels": 16_383,
                    "referenceBulkCopyCalls": 15,
                    "referenceBulkCopyBytes": 65_532,
                ],
                rejectedMutations: [
                    CounterMutation(counter: "decodedOutputAllocations", actual: 2, expected: "1"),
                    CounterMutation(
                        counter: "temporaryDecodedBackingAllocations",
                        actual: 1,
                        expected: "0"
                    ),
                    CounterMutation(
                        counter: "temporaryDecodedBackingBytes",
                        actual: 4,
                        expected: "0"
                    ),
                    CounterMutation(
                        counter: "overlapReferencePixels",
                        actual: 0,
                        expected: "greater than zero"
                    ),
                    CounterMutation(
                        counter: "referenceBulkCopyCalls",
                        actual: 0,
                        expected: "greater than zero"
                    ),
                    CounterMutation(
                        counter: "referenceBulkCopyBytes",
                        actual: 4,
                        expected: "65532"
                    ),
                ]
            ),
            CounterContract(
                caseID: "glz",
                validCounters: [
                    "pendingDictionaryWaitBytes": 0,
                    "overlapReferencePixels": 16_383,
                ],
                rejectedMutations: [
                    CounterMutation(
                        counter: "pendingDictionaryWaitBytes",
                        actual: 1,
                        expected: "0"
                    ),
                    CounterMutation(
                        counter: "overlapReferencePixels",
                        actual: 0,
                        expected: "greater than zero"
                    ),
                ]
            ),
            CounterContract(
                caseID: "iosurface.transition",
                validCounters: [
                    "revisionedBackingEnabled": 1,
                    "bulkCopyCalls": 1,
                    "rowCopyCalls": 0,
                    "cpuMaterializationBytes": 0,
                    "cpuMaterializations": 0,
                    "directIOSurfaceWriteBytes": 4,
                ],
                rejectedMutations: [
                    CounterMutation(
                        counter: "revisionedBackingEnabled",
                        actual: 0,
                        expected: "1"
                    ),
                    CounterMutation(counter: "bulkCopyCalls", actual: 2, expected: "1"),
                    CounterMutation(counter: "rowCopyCalls", actual: 1, expected: "0"),
                    CounterMutation(
                        counter: "cpuMaterializationBytes",
                        actual: 4,
                        expected: "0"
                    ),
                    CounterMutation(counter: "cpuMaterializations", actual: 1, expected: "0"),
                    CounterMutation(
                        counter: "directIOSurfaceWriteBytes",
                        actual: 0,
                        expected: "4"
                    ),
                ]
            ),
            CounterContract(
                caseID: "advanced_video.sample",
                validCounters: [
                    "scanPassCount": 1,
                    "inputCopyBytes": 0,
                    "nalPayloadMaterializations": 0,
                    "nalPayloadCopyBytes": 0,
                    "avccSampleAllocations": 1,
                    "samplePayloadCopyBytes": 0,
                ],
                rejectedMutations: [
                    CounterMutation(counter: "scanPassCount", actual: 2, expected: "1"),
                    CounterMutation(counter: "inputCopyBytes", actual: 1, expected: "0"),
                    CounterMutation(
                        counter: "nalPayloadMaterializations",
                        actual: 1,
                        expected: "0"
                    ),
                    CounterMutation(counter: "nalPayloadCopyBytes", actual: 1, expected: "0"),
                    CounterMutation(counter: "avccSampleAllocations", actual: 2, expected: "1"),
                    CounterMutation(counter: "samplePayloadCopyBytes", actual: 1, expected: "0"),
                ]
            ),
        ]
    }
}

private enum FixtureError: Error, Equatable {
    case injected
}

private struct CounterContract {
    let caseID: String
    let validCounters: [String: UInt64]
    let rejectedMutations: [CounterMutation]
}

private struct CounterMutation {
    let counter: String
    let actual: UInt64
    let expected: String
}
