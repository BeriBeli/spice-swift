import Synchronization

package final class SpiceLiveRealtimeStageRecorder: Sendable {
    private enum State: Sendable {
        case active(
            execution: SpiceLiveCampaignExecution,
            manifest: SpiceLiveCampaignManifest
        )
        case terminal(SpiceLiveCampaignManifest)
        case poisoned(SpiceLiveCampaignManifest)

        var manifest: SpiceLiveCampaignManifest {
            switch self {
            case let .active(_, manifest),
                 let .terminal(manifest),
                 let .poisoned(manifest):
                manifest
            }
        }
    }

    private let plan: SpiceLiveCampaignPlan
    private let manifestWriter: SpiceLiveCampaignManifestWriter
    private let state: Mutex<State>

    package var snapshot: SpiceLiveCampaignManifest {
        state.withLock { $0.manifest }
    }

    package init(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata,
        manifestWriter: SpiceLiveCampaignManifestWriter
    ) throws {
        let manifest = SpiceLiveCampaignManifest(plan: plan, metadata: metadata)
        try manifestWriter.create(manifest)
        self.plan = plan
        self.manifestWriter = manifestWriter
        state = Mutex(.active(
            execution: SpiceLiveCampaignExecution(plan: plan),
            manifest: manifest
        ))
    }

    private init(
        plan: SpiceLiveCampaignPlan,
        manifestWriter: SpiceLiveCampaignManifestWriter,
        terminalManifest: SpiceLiveCampaignManifest
    ) {
        self.plan = plan
        self.manifestWriter = manifestWriter
        state = Mutex(.terminal(terminalManifest))
    }

    package static func resume(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata,
        manifestWriter: SpiceLiveCampaignManifestWriter
    ) throws -> SpiceLiveRealtimeStageRecorder {
        guard var manifest = try manifestWriter.load() else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        _ = try validateAndReplay(
            manifest: manifest,
            plan: plan,
            metadata: metadata
        )
        if manifest.state == .recording {
            let (nextGeneration, overflow) = manifest.generation
                .addingReportingOverflow(1)
            guard !overflow else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
            manifest.generation = nextGeneration
            manifest.state = .interrupted
            try manifestWriter.persist(manifest)
        }
        return SpiceLiveRealtimeStageRecorder(
            plan: plan,
            manifestWriter: manifestWriter,
            terminalManifest: manifest
        )
    }

    package func record(
        run: SpiceLiveCampaignRun,
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome,
        evidenceRunID: SpiceLiveEvidenceRunID? = nil
    ) throws {
        try state.withLock { state in
            guard case let .active(execution, manifest) = state else {
                throw SpiceLiveCampaignManifestError.recorderTerminal
            }

            let candidate: (
                execution: SpiceLiveCampaignExecution,
                manifest: SpiceLiveCampaignManifest
            )
            do {
                candidate = try makeCandidate(
                    execution: execution,
                    manifest: manifest,
                    run: run,
                    stage: stage,
                    outcome: outcome,
                    evidenceRunID: evidenceRunID
                )
            } catch {
                try persistInvalidTransition(from: manifest, state: &state)
                throw error
            }

            do {
                try manifestWriter.persist(candidate.manifest)
            } catch {
                state = .poisoned(manifest)
                throw error
            }
            state = outcome == .failed
                ? .terminal(candidate.manifest)
                : .active(
                    execution: candidate.execution,
                    manifest: candidate.manifest
                )
        }
    }

    package func finalize() throws -> SpiceLiveCampaignManifest {
        try state.withLock { state in
            guard case let .active(execution, manifest) = state else {
                throw SpiceLiveCampaignManifestError.recorderTerminal
            }
            let evidence = manifest.runs.compactMap(\.evidenceRunID)
            guard execution.campaignCompleted,
                  !execution.campaignFailed,
                  execution.entries.count == 260,
                  execution.entries.allSatisfy({ $0.outcome == .succeeded }),
                  manifest.stages == execution.entries,
                  evidence.count == 20,
                  Set(evidence).count == 20 else {
                try persistInvalidTransition(from: manifest, state: &state)
                throw SpiceLiveCampaignManifestError.invalidTransition
            }

            var candidate = manifest
            let (nextGeneration, overflow) = candidate.generation
                .addingReportingOverflow(1)
            guard !overflow else {
                state = .poisoned(manifest)
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
            candidate.generation = nextGeneration
            candidate.state = .finalized
            do {
                try manifestWriter.persist(candidate)
            } catch {
                state = .poisoned(manifest)
                throw error
            }
            state = .terminal(candidate)
            return candidate
        }
    }

    private func makeCandidate(
        execution: SpiceLiveCampaignExecution,
        manifest: SpiceLiveCampaignManifest,
        run: SpiceLiveCampaignRun,
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome,
        evidenceRunID: SpiceLiveEvidenceRunID?
    ) throws -> (
        execution: SpiceLiveCampaignExecution,
        manifest: SpiceLiveCampaignManifest
    ) {
        let runIndex = execution.entries.count / 13
        guard plan.runs.indices.contains(runIndex),
              plan.runs[runIndex] == run else {
            throw SpiceLiveCampaignManifestError.invalidTransition
        }

        var candidateExecution = execution
        if execution.entries.count.isMultiple(of: 13) {
            let begun = try candidateExecution.beginNextRun()
            guard begun == run else {
                throw SpiceLiveCampaignManifestError.invalidTransition
            }
        }

        var candidateManifest = manifest
        if let evidenceRunID {
            guard stage == .fixtureStart,
                  outcome == .succeeded,
                  candidateManifest.runs[runIndex].evidenceRunID == nil,
                  !candidateManifest.runs.contains(where: {
                      $0.evidenceRunID == evidenceRunID
                  }) else {
                throw SpiceLiveCampaignManifestError.invalidTransition
            }
            candidateManifest.runs[runIndex].evidenceRunID = evidenceRunID
        }
        if stage == .fixtureStart, outcome == .succeeded {
            guard candidateManifest.runs[runIndex].evidenceRunID != nil else {
                throw SpiceLiveCampaignManifestError.invalidTransition
            }
        } else if evidenceRunID != nil {
            throw SpiceLiveCampaignManifestError.invalidTransition
        }

        try candidateExecution.record(stage: stage, outcome: outcome)
        guard let entry = candidateExecution.entries.last,
              entry.runID == run.runID else {
            throw SpiceLiveCampaignManifestError.invalidTransition
        }
        candidateManifest.stages = candidateExecution.entries
        let (nextGeneration, overflow) = candidateManifest.generation
            .addingReportingOverflow(1)
        guard !overflow else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        candidateManifest.generation = nextGeneration
        candidateManifest.state = outcome == .failed ? .failed : .recording
        return (candidateExecution, candidateManifest)
    }

    private func persistInvalidTransition(
        from manifest: SpiceLiveCampaignManifest,
        state: inout State
    ) throws {
        var failed = manifest
        let (nextGeneration, overflow) = failed.generation.addingReportingOverflow(1)
        guard !overflow else {
            state = .poisoned(manifest)
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        failed.generation = nextGeneration
        failed.state = .failed
        do {
            try manifestWriter.persist(failed)
            state = .terminal(failed)
        } catch {
            state = .poisoned(manifest)
            throw error
        }
    }

    private static func validateAndReplay(
        manifest: SpiceLiveCampaignManifest,
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata
    ) throws -> SpiceLiveCampaignExecution {
        let expected = SpiceLiveCampaignManifest(plan: plan, metadata: metadata)
        guard manifest.hasSameImmutableIdentity(as: expected),
              manifest.runs.count == plan.runs.count,
              manifest.stages.count <= 260 else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }

        let evidence = manifest.runs.compactMap(\.evidenceRunID)
        guard Set(evidence).count == evidence.count else {
            throw SpiceLiveCampaignManifestError.invalidManifest
        }

        var execution = SpiceLiveCampaignExecution(plan: plan)
        for (index, persisted) in manifest.stages.enumerated() {
            if index.isMultiple(of: 13) {
                _ = try execution.beginNextRun()
            }
            try execution.record(stage: persisted.stage, outcome: persisted.outcome)
            guard execution.entries.last == persisted else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
            if persisted.outcome == .failed,
               index != manifest.stages.index(before: manifest.stages.endIndex) {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
        }

        for runIndex in plan.runs.indices {
            let runEntries = manifest.stages.filter {
                $0.runID == plan.runs[runIndex].runID
            }
            let boundEvidence = manifest.runs[runIndex].evidenceRunID
            let fixtureStartSucceeded = runEntries.contains {
                $0.stage == .fixtureStart && $0.outcome == .succeeded
            }
            guard fixtureStartSucceeded == (boundEvidence != nil) else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
        }

        switch manifest.state {
        case .recording:
            guard !execution.campaignFailed,
                  manifest.stages.allSatisfy({ $0.outcome == .succeeded }),
                  manifest.generation == UInt64(manifest.stages.count) else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
        case .failed:
            let appendedFailure = manifest.stages.last?.outcome == .failed
            let expectedGeneration = UInt64(manifest.stages.count)
                + (appendedFailure ? 0 : 1)
            guard manifest.generation == expectedGeneration else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
        case .interrupted:
            guard manifest.stages.allSatisfy({ $0.outcome == .succeeded }),
                  manifest.generation == UInt64(manifest.stages.count + 1) else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
        case .finalized:
            guard execution.campaignCompleted,
                  !execution.campaignFailed,
                  manifest.stages.count == 260,
                  evidence.count == 20,
                  manifest.generation == 261 else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
        }
        return execution
    }
}
