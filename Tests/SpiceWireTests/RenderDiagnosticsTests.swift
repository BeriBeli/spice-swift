import Synchronization
import Testing
@testable import SpiceWire

@Suite("Render diagnostics")
struct RenderDiagnosticsTests {
    @Test func disabledRecorderDoesNotReadClock() {
        let clockCalls = Mutex(0)
        var recorder = RenderPhaseRecorder(
            mode: .disabled,
            clock: {
                clockCalls.withLock { calls in
                    calls += 1
                    return UInt64(calls)
                }
            }
        )

        for _ in 0..<10 {
            let sample = recorder.beginCommand()
            #expect(sample == nil)
            recorder.finishCommand(sample)
        }

        #expect(clockCalls.withLock { $0 } == 0)
        #expect(recorder.metrics == RenderPhaseMetrics())
    }

    @Test func sharedCommandSamplerNormalizesAndSelectsOneCommandPerPeriod() {
        var disabled = RenderCommandSampler(mode: .disabled)
        #expect(disabled.commandPeriod == nil)
        let disabledSelection = disabled.shouldSampleCommand()
        #expect(!disabledSelection)

        var normalized = RenderCommandSampler(mode: .sampled(commandPeriod: 0))
        #expect(normalized.commandPeriod == 1)
        let normalizedSelection = normalized.shouldSampleCommand()
        #expect(normalizedSelection)

        var everyThird = RenderCommandSampler(mode: .sampled(commandPeriod: 3))
        #expect(everyThird.commandPeriod == 3)
        let first = everyThird.shouldSampleCommand()
        let second = everyThird.shouldSampleCommand()
        let third = everyThird.shouldSampleCommand()
        let fourth = everyThird.shouldSampleCommand()
        #expect(!first)
        #expect(!second)
        #expect(third)
        #expect(!fourth)
    }

    @Test func sampledRecorderReportsRawSamplesAndNanoseconds() {
        let readings = Mutex<[UInt64]>([100, 145, 1_000, 900])
        var recorder = RenderPhaseRecorder(
            mode: .sampled(commandPeriod: 2),
            clock: {
                readings.withLock { readings in
                    readings.removeFirst()
                }
            }
        )

        #expect(recorder.beginCommand() == nil)
        let firstSample = recorder.beginCommand()
        recorder.finishCommand(firstSample)
        #expect(recorder.beginCommand() == nil)
        let secondSample = recorder.beginCommand()
        recorder.finishCommand(secondSample)

        #expect(recorder.metrics == RenderPhaseMetrics(
            samplePeriod: 2,
            samples: 2,
            sampledNanoseconds: 45
        ))
        #expect(readings.withLock { $0.isEmpty })
    }

    @Test func zeroSamplePeriodIsSafelyNormalizedToOne() {
        let nextReading = Mutex<UInt64>(10)
        var recorder = RenderPhaseRecorder(
            mode: .sampled(commandPeriod: 0),
            clock: {
                nextReading.withLock { reading in
                    defer { reading += 10 }
                    return reading
                }
            }
        )

        let sample = recorder.beginCommand()
        recorder.finishCommand(sample)

        #expect(recorder.metrics == RenderPhaseMetrics(
            samplePeriod: 1,
            samples: 1,
            sampledNanoseconds: 10
        ))
    }

    @Test func selectedSegmentedSampleExcludesPausedWork() {
        let readings = Mutex<[UInt64]>([100, 130, 1_000, 1_050])
        var recorder = RenderPhaseRecorder(
            mode: .sampled(commandPeriod: 32),
            clock: {
                readings.withLock { readings in
                    readings.removeFirst()
                }
            }
        )

        var sample = recorder.beginSelectedCommand(true)
        recorder.pauseCommand(&sample)
        recorder.resumeCommand(&sample)
        recorder.finishCommand(&sample)

        #expect(sample == nil)
        #expect(recorder.metrics == RenderPhaseMetrics(
            samplePeriod: 32,
            samples: 1,
            sampledNanoseconds: 80
        ))
        #expect(readings.withLock { $0.isEmpty })
    }

    @Test func phaseMetricsAccumulateSequentialOwners() {
        let first = RenderPhaseMetrics(
            samplePeriod: 64,
            samples: 2,
            sampledNanoseconds: 30
        )
        let second = RenderPhaseMetrics(
            samplePeriod: 64,
            samples: 3,
            sampledNanoseconds: 70
        )

        #expect(first.accumulating(second) == RenderPhaseMetrics(
            samplePeriod: 64,
            samples: 5,
            sampledNanoseconds: 100
        ))
        #expect(
            RenderPhaseMetrics().accumulating(second)
                == RenderPhaseMetrics(
                    samplePeriod: 64,
                    samples: 3,
                    sampledNanoseconds: 70
                )
        )
    }

    @Test func phaseMetricsSubtractAnEarlierOwnerSnapshot() {
        let earlier = RenderPhaseMetrics(
            samplePeriod: 64,
            samples: 2,
            sampledNanoseconds: 30
        )
        let current = RenderPhaseMetrics(
            samplePeriod: 64,
            samples: 5,
            sampledNanoseconds: 100
        )

        #expect(current.subtracting(earlier) == RenderPhaseMetrics(
            samplePeriod: 64,
            samples: 3,
            sampledNanoseconds: 70
        ))
        #expect(current.subtracting(RenderPhaseMetrics()) == current)
    }
}
