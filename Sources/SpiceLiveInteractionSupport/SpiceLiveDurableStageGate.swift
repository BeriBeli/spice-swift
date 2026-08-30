import Synchronization

package final class SpiceLiveDurableStageGate: Sendable {
    private struct Position: Sendable {
        let run: SpiceLiveCampaignRun
        let evidenceRunID: SpiceLiveEvidenceRunID
        let stepIndex: Int
        let stageIndex: Int
        let eventSequence: UInt64
        let manifestGeneration: UInt64
    }

    private struct Pending: Sendable {
        let acknowledgement: SpiceLiveStageAcknowledgement
        let next: Position?
        let recorderRemainsActive: Bool
    }

    private enum State: Sendable {
        case active(Position)
        case pending(Pending)
        case completed
        case terminal(pendingAcknowledgement: SpiceLiveStageAcknowledgement?)
    }

    private static let actionStages: [SpiceLiveAttemptStage] = [
        .preArm, .arm, .postArm,
    ]

    private let recorder: SpiceLiveRealtimeStageRecorder
    private let state: Mutex<State>

    package var pendingAcknowledgement: SpiceLiveStageAcknowledgement? {
        state.withLock { state in
            switch state {
            case let .pending(pending):
                pending.acknowledgement
            case let .terminal(pendingAcknowledgement):
                pendingAcknowledgement
            case .active, .completed:
                nil
            }
        }
    }

    package var isCompleted: Bool {
        state.withLock { state in
            if case .completed = state { true } else { false }
        }
    }

    package var isTerminal: Bool {
        state.withLock { state in
            if case .terminal = state { true } else { false }
        }
    }

    package init(
        plan: SpiceLiveCampaignPlan,
        recorder: SpiceLiveRealtimeStageRecorder
    ) throws {
        let manifest = recorder.snapshot
        guard manifest.state == .recording,
              manifest.campaignID == plan.campaignID,
              manifest.planDigest == SpiceLiveCampaignManifest.expectedPlanDigest(plan),
              manifest.baselineVersion == plan.baselineVersion,
              manifest.candidateVersion == plan.candidateVersion,
              manifest.generation == UInt64(manifest.stages.count),
              manifest.stages.count % 13 == 3,
              let contract = manifest.executionContract,
              contract.stageProtocolVersion == .v1 else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        do {
            try contract.validate(plan: plan, metadata: manifest.metadata)
        } catch {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }

        let runIndex = manifest.stages.count / 13
        guard plan.runs.indices.contains(runIndex),
              manifest.runs.indices.contains(runIndex),
              manifest.runs.count == plan.runs.count else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let run = plan.runs[runIndex]
        let manifestRun = manifest.runs[runIndex]
        guard manifestRun.logicalRunID == run.runID,
              manifestRun.version == run.version,
              manifestRun.clusterID == run.clusterID,
              manifestRun.sequence == run.sequence,
              let evidenceRunID = manifestRun.evidenceRunID,
              run.steps.count == 3 else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }

        let lifecycleEntries = Array(manifest.stages.suffix(3))
        let expectedLifecycle: [SpiceLiveAttemptStage] = [
            .fixtureStop, .fixtureStart, .fixtureHealth,
        ]
        guard lifecycleEntries.count == expectedLifecycle.count else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        for (entry, expectedStage) in zip(lifecycleEntries, expectedLifecycle) {
            guard entry.campaignID == run.campaignID,
                  entry.runID == run.runID,
                  entry.version == run.version,
                  entry.clusterID == run.clusterID,
                  entry.runSequence == run.sequence,
                  entry.actionClass == run.steps[0].actionClass,
                  entry.order == run.steps[0].order,
                  entry.checksum == run.steps[0].checksum,
                  entry.token == run.steps[0].token,
                  entry.attemptNumber == 1,
                  entry.stage == expectedStage,
                  entry.outcome == .succeeded else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }
        }

        self.recorder = recorder
        state = Mutex(.active(Position(
            run: run,
            evidenceRunID: evidenceRunID,
            stepIndex: 0,
            stageIndex: 0,
            eventSequence: 1,
            manifestGeneration: manifest.generation
        )))
    }

    package func accept(
        _ event: SpiceLiveChildStageEvent
    ) throws -> SpiceLiveStageAcknowledgement {
        try state.withLock { state in
            switch state {
            case let .active(position):
                guard matches(event, position: position) else {
                    try becomeTerminal(
                        state: &state,
                        pendingAcknowledgement: nil,
                        recorderRemainsActive: true
                    )
                }

                let durableGeneration: UInt64
                do {
                    durableGeneration = try recorder.record(
                        run: position.run,
                        stage: event.stage,
                        outcome: event.outcome
                    )
                } catch {
                    // The recorder poisons itself when persistence is
                    // uncertain. Retrying a terminal write here could publish
                    // a second successor for the same external effect.
                    state = .terminal(pendingAcknowledgement: nil)
                    throw error
                }
                let expectedGeneration = position.manifestGeneration.addingReportingOverflow(1)
                guard !expectedGeneration.overflow,
                      durableGeneration == expectedGeneration.partialValue else {
                    try becomeTerminal(
                        state: &state,
                        pendingAcknowledgement: nil,
                        recorderRemainsActive: event.outcome == .succeeded
                    )
                }

                let acknowledgement: SpiceLiveStageAcknowledgement
                do {
                    acknowledgement = try SpiceLiveStageAcknowledgement(
                        event: event,
                        durableManifestGeneration: durableGeneration
                    )
                } catch {
                    try becomeTerminal(
                        state: &state,
                        pendingAcknowledgement: nil,
                        recorderRemainsActive: event.outcome == .succeeded
                    )
                }
                let next = event.outcome == .succeeded
                    ? nextPosition(after: position, generation: durableGeneration)
                    : nil
                state = .pending(Pending(
                    acknowledgement: acknowledgement,
                    next: next,
                    recorderRemainsActive: event.outcome == .succeeded
                ))
                return acknowledgement

            case let .pending(pending):
                try becomeTerminal(
                    state: &state,
                    pendingAcknowledgement: pending.acknowledgement,
                    recorderRemainsActive: pending.recorderRemainsActive
                )
            case .completed:
                try becomeTerminal(
                    state: &state,
                    pendingAcknowledgement: nil,
                    recorderRemainsActive: true
                )
            case .terminal:
                throw SpiceLiveCampaignManifestError.recorderTerminal
            }
        }
    }

    package func acknowledgementDelivered(
        _ acknowledgement: SpiceLiveStageAcknowledgement
    ) throws {
        try state.withLock { state in
            guard case let .pending(pending) = state else {
                if case .terminal = state {
                    throw SpiceLiveCampaignManifestError.recorderTerminal
                }
                try becomeTerminal(
                    state: &state,
                    pendingAcknowledgement: nil,
                    recorderRemainsActive: true
                )
            }
            guard acknowledgement == pending.acknowledgement else {
                try becomeTerminal(
                    state: &state,
                    pendingAcknowledgement: pending.acknowledgement,
                    recorderRemainsActive: pending.recorderRemainsActive
                )
            }
            if !pending.recorderRemainsActive {
                state = .terminal(pendingAcknowledgement: nil)
            } else if let next = pending.next {
                state = .active(next)
            } else {
                state = .completed
            }
        }
    }

    package func acknowledgementDeliveryFailed(
        _ acknowledgement: SpiceLiveStageAcknowledgement
    ) throws {
        try state.withLock { state in
            guard case let .pending(pending) = state else {
                if case .terminal = state {
                    throw SpiceLiveCampaignManifestError.recorderTerminal
                }
                try becomeTerminal(
                    state: &state,
                    pendingAcknowledgement: nil,
                    recorderRemainsActive: true
                )
            }
            let retained = pending.acknowledgement
            guard acknowledgement == retained else {
                try becomeTerminal(
                    state: &state,
                    pendingAcknowledgement: retained,
                    recorderRemainsActive: pending.recorderRemainsActive
                )
            }
            try persistTerminal(
                state: &state,
                pendingAcknowledgement: retained,
                recorderRemainsActive: pending.recorderRemainsActive
            )
        }
    }

    package func childReachedEOF() throws {
        try terminateExternalBoundary()
    }

    package func cancel() throws {
        try terminateExternalBoundary()
    }

    private func terminateExternalBoundary() throws {
        try state.withLock { state in
            switch state {
            case .active:
                try persistTerminal(
                    state: &state,
                    pendingAcknowledgement: nil,
                    recorderRemainsActive: true
                )
            case let .pending(pending):
                try persistTerminal(
                    state: &state,
                    pendingAcknowledgement: pending.acknowledgement,
                    recorderRemainsActive: pending.recorderRemainsActive
                )
            case .completed:
                try persistTerminal(
                    state: &state,
                    pendingAcknowledgement: nil,
                    recorderRemainsActive: true
                )
            case .terminal:
                throw SpiceLiveCampaignManifestError.recorderTerminal
            }
        }
    }

    private func matches(
        _ event: SpiceLiveChildStageEvent,
        position: Position
    ) -> Bool {
        let step = position.run.steps[position.stepIndex]
        return event.protocolVersion == .v1
            && event.campaignID == position.run.campaignID
            && event.runID == position.run.runID
            && event.version == position.run.version
            && event.clusterID == position.run.clusterID
            && event.evidenceRunID == position.evidenceRunID
            && event.actionClass == step.actionClass
            && event.order == step.order
            && event.token == step.token
            && event.checksum == step.checksum
            && event.stage == Self.actionStages[position.stageIndex]
            && event.eventSequence == position.eventSequence
            && event.previousManifestGeneration == position.manifestGeneration
    }

    private func nextPosition(
        after position: Position,
        generation: UInt64
    ) -> Position? {
        let nextSequence = position.eventSequence + 1
        if Self.actionStages.indices.contains(position.stageIndex + 1) {
            return Position(
                run: position.run,
                evidenceRunID: position.evidenceRunID,
                stepIndex: position.stepIndex,
                stageIndex: position.stageIndex + 1,
                eventSequence: nextSequence,
                manifestGeneration: generation
            )
        }
        guard position.run.steps.indices.contains(position.stepIndex + 1) else {
            return nil
        }
        return Position(
            run: position.run,
            evidenceRunID: position.evidenceRunID,
            stepIndex: position.stepIndex + 1,
            stageIndex: 0,
            eventSequence: nextSequence,
            manifestGeneration: generation
        )
    }

    private func becomeTerminal(
        state: inout State,
        pendingAcknowledgement: SpiceLiveStageAcknowledgement?,
        recorderRemainsActive: Bool
    ) throws -> Never {
        try persistTerminal(
            state: &state,
            pendingAcknowledgement: pendingAcknowledgement,
            recorderRemainsActive: recorderRemainsActive
        )
        throw SpiceLiveInteractionSupportError.invalidTraceProtocol
    }

    private func persistTerminal(
        state: inout State,
        pendingAcknowledgement: SpiceLiveStageAcknowledgement?,
        recorderRemainsActive: Bool
    ) throws {
        if recorderRemainsActive {
            do {
                try recorder.failClosedAfterExternalBoundary()
            } catch {
                state = .terminal(
                    pendingAcknowledgement: pendingAcknowledgement
                )
                throw error
            }
        }
        state = .terminal(pendingAcknowledgement: pendingAcknowledgement)
    }
}
