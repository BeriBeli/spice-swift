import Dispatch

/// Controls opt-in, aggregate-only hot-path phase timing.
///
/// Production sessions leave diagnostics disabled. Benchmark callers can sample
/// one command out of every `commandPeriod` commands without paying for a clock
/// read on unsampled commands.
package enum RenderDiagnosticsMode: Sendable, Equatable {
    case disabled
    case sampled(commandPeriod: UInt64)

    package var normalizedCommandPeriod: UInt64? {
        switch self {
        case .disabled:
            nil
        case let .sampled(commandPeriod):
            max(1, commandPeriod)
        }
    }
}

package struct RenderPhaseMetrics: Sendable, Equatable {
    /// The normalized selection period. `nil` means timing was disabled.
    /// `sampledNanoseconds` is the sum of selected samples, not an estimate of
    /// total phase time across unsampled work.
    package let samplePeriod: UInt64?
    package let samples: UInt64
    package let sampledNanoseconds: UInt64

    package init(
        samplePeriod: UInt64? = nil,
        samples: UInt64 = 0,
        sampledNanoseconds: UInt64 = 0
    ) {
        self.samplePeriod = samplePeriod
        self.samples = samples
        self.sampledNanoseconds = sampledNanoseconds
    }

    /// Combines metrics from sequential owners configured with the same
    /// sampling period, such as connections replaced during migration or
    /// publishers retired after a run. A disabled owner contributes no period.
    package func accumulating(_ other: Self) -> Self {
        assert(
            samplePeriod == nil
                || other.samplePeriod == nil
                || samplePeriod == other.samplePeriod,
            "cannot combine phase metrics with different sampling periods"
        )
        return Self(
            samplePeriod: samplePeriod ?? other.samplePeriod,
            samples: Self.saturatingAdd(samples, other.samples),
            sampledNanoseconds: Self.saturatingAdd(
                sampledNanoseconds,
                other.sampledNanoseconds
            )
        )
    }

    /// Returns work recorded after an earlier snapshot of the same owner.
    /// A zero/default snapshot is accepted as the baseline for a newly active
    /// owner. Counters are monotonic; saturation protects diagnostic output if
    /// a caller accidentally supplies a newer baseline.
    package func subtracting(_ earlier: Self) -> Self {
        assert(
            samplePeriod == nil
                || earlier.samplePeriod == nil
                || samplePeriod == earlier.samplePeriod,
            "cannot subtract phase metrics with different sampling periods"
        )
        return Self(
            samplePeriod: samplePeriod,
            samples: Self.saturatingSubtract(samples, earlier.samples),
            sampledNanoseconds: Self.saturatingSubtract(
                sampledNanoseconds,
                earlier.sampledNanoseconds
            )
        )
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }

    private static func saturatingSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }
}

package struct RenderPhaseSample: Sendable, Equatable {
    fileprivate var startedAtNanoseconds: UInt64?
    fileprivate var accumulatedNanoseconds: UInt64 = 0
}

/// Selects one complete work item so every phase recorder observes the same
/// item instead of independently drifting after an early failure.
package struct RenderCommandSampler: Sendable {
    package let commandPeriod: UInt64?
    private var commandsUntilSample: UInt64

    package init(mode: RenderDiagnosticsMode = .disabled) {
        commandPeriod = mode.normalizedCommandPeriod
        commandsUntilSample = commandPeriod ?? 0
    }

    package mutating func shouldSampleCommand() -> Bool {
        guard let commandPeriod else {
            return false
        }
        if commandsUntilSample > 1 {
            commandsUntilSample -= 1
            return false
        }
        commandsUntilSample = commandPeriod
        return true
    }
}

/// Actor-isolated recorder for one hot-path phase.
///
/// The recorder intentionally does not synchronize internally. Its owner keeps
/// it in an actor or otherwise serializes access, avoiding a lock on the hot
/// path. `clock` is injectable so sampling and elapsed-time accounting are
/// deterministic in tests.
package struct RenderPhaseRecorder: Sendable {
    package typealias Clock = @Sendable () -> UInt64

    package static let systemClock: Clock = {
        DispatchTime.now().uptimeNanoseconds
    }

    private let commandPeriod: UInt64?
    private let clock: Clock
    private var commandsUntilSample: UInt64
    private var samples: UInt64 = 0
    private var sampledNanoseconds: UInt64 = 0

    package init(
        mode: RenderDiagnosticsMode = .disabled,
        clock: @escaping Clock = RenderPhaseRecorder.systemClock
    ) {
        commandPeriod = mode.normalizedCommandPeriod
        commandsUntilSample = commandPeriod ?? 0
        self.clock = clock
    }

    /// Begins a sample only when this command reaches the configured period.
    /// Unsampled and disabled calls do not read the clock.
    package mutating func beginCommand() -> RenderPhaseSample? {
        guard let commandPeriod else {
            return nil
        }
        if commandsUntilSample > 1 {
            commandsUntilSample -= 1
            return nil
        }
        commandsUntilSample = commandPeriod
        return RenderPhaseSample(startedAtNanoseconds: clock())
    }

    /// Begins a phase for a command selected by a shared sampler. This keeps all
    /// phase metrics aligned to the same command while retaining the recorder's
    /// normalized period in its output.
    package mutating func beginSelectedCommand(_ selected: Bool) -> RenderPhaseSample? {
        guard selected, commandPeriod != nil else {
            return nil
        }
        return RenderPhaseSample(startedAtNanoseconds: clock())
    }

    /// Temporarily excludes nested work from an outer phase. A disabled or
    /// unselected phase performs no clock read.
    package mutating func pauseCommand(_ sample: inout RenderPhaseSample?) {
        guard var current = sample,
              let startedAtNanoseconds = current.startedAtNanoseconds
        else {
            return
        }
        current.accumulatedNanoseconds = Self.saturatingAdd(
            current.accumulatedNanoseconds,
            elapsed(since: startedAtNanoseconds, until: clock())
        )
        current.startedAtNanoseconds = nil
        sample = current
    }

    package mutating func resumeCommand(_ sample: inout RenderPhaseSample?) {
        guard var current = sample, current.startedAtNanoseconds == nil else {
            return
        }
        current.startedAtNanoseconds = clock()
        sample = current
    }

    package mutating func finishCommand(_ sample: RenderPhaseSample?) {
        guard var sample else {
            return
        }
        if let startedAtNanoseconds = sample.startedAtNanoseconds {
            sample.accumulatedNanoseconds = Self.saturatingAdd(
                sample.accumulatedNanoseconds,
                elapsed(since: startedAtNanoseconds, until: clock())
            )
        }
        samples = Self.saturatingAdd(samples, 1)
        sampledNanoseconds = Self.saturatingAdd(
            sampledNanoseconds,
            sample.accumulatedNanoseconds
        )
    }

    package mutating func finishCommand(_ sample: inout RenderPhaseSample?) {
        finishCommand(sample)
        sample = nil
    }

    package var metrics: RenderPhaseMetrics {
        RenderPhaseMetrics(
            samplePeriod: commandPeriod,
            samples: samples,
            sampledNanoseconds: sampledNanoseconds
        )
    }

    private func elapsed(since start: UInt64, until finish: UInt64) -> UInt64 {
        finish >= start ? finish - start : 0
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}
