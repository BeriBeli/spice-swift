import Foundation

package actor SpiceLiveStageDriver {
    private enum RunPhase: Sendable {
        case receiving
        case sending(SpiceLiveStageAcknowledgement)
    }

    package enum State: Sendable, Equatable {
        case idle
        case running
        case completed
        case terminal
    }

    package enum DriverError: Error, Sendable, Equatable {
        case alreadyRunning
        case terminal
        case cancelled
        case unexpectedEndOfFile
        case receiveFailed
        case invalidEventFrame
        case acknowledgementEncodingFailed
        case acknowledgementSendFailed
        case childReportedFailure
    }

    package private(set) var state: State = .idle

    private let gate: SpiceLiveDurableStageGate
    private let transport: SpiceLiveStageTransport
    private var runPhase: RunPhase?
    private var runTaskCancellationClaimed = false

    package init(
        gate: SpiceLiveDurableStageGate,
        transport: SpiceLiveStageTransport
    ) {
        self.gate = gate
        self.transport = transport
    }

    package func run() async throws {
        switch state {
        case .idle:
            state = .running
            runPhase = .receiving
            runTaskCancellationClaimed = false
        case .running:
            throw DriverError.alreadyRunning
        case .completed:
            return
        case .terminal:
            throw DriverError.terminal
        }

        while true {
            if Task.isCancelled {
                try await terminateForObservedTaskCancellation()
            }

            runPhase = .receiving
            let received: Data?
            do {
                received = try await withTaskCancellationHandler(
                    operation: {
                        try await transport.receiveFrame(
                            maximumBytes: SpiceLiveStageProtocolCodec
                                .maximumFrameBytes
                        )
                    },
                    onCancel: {
                        Task { await self.runTaskCancelled() }
                    }
                )
            } catch {
                try requireRunning()
                if Task.isCancelled {
                    try await terminateForObservedTaskCancellation()
                }
                try await terminateWithoutPendingAcknowledgement(
                    gateTransition: { try gate.cancel() },
                    failure: .receiveFailed
                )
            }
            try requireRunning()
            if Task.isCancelled {
                try await terminateForObservedTaskCancellation()
            }
            guard let frame = received else {
                try await terminateWithoutPendingAcknowledgement(
                    gateTransition: { try gate.childReachedEOF() },
                    failure: .unexpectedEndOfFile
                )
            }

            let event: SpiceLiveChildStageEvent
            do {
                event = try SpiceLiveStageProtocolCodec.decodeEvent(frame)
            } catch {
                try await terminateWithoutPendingAcknowledgement(
                    gateTransition: { try gate.cancel() },
                    failure: .invalidEventFrame
                )
            }
            if Task.isCancelled {
                try await terminateForObservedTaskCancellation()
            }

            let acknowledgement: SpiceLiveStageAcknowledgement
            do {
                acknowledgement = try gate.accept(event)
            } catch {
                // accept owns its durable/poisoned terminal transition. A
                // second gate call could retry an uncertain filesystem
                // boundary for the same child event.
                state = .terminal
                runPhase = nil
                await transport.close()
                throw error
            }
            runPhase = .sending(acknowledgement)

            if Task.isCancelled {
                try await terminateForObservedTaskCancellation()
            }

            let acknowledgementFrame: Data
            do {
                acknowledgementFrame = try SpiceLiveStageProtocolCodec
                    .encodeAcknowledgement(acknowledgement)
            } catch {
                try await terminateWithPendingAcknowledgement(
                    acknowledgement,
                    failure: .acknowledgementEncodingFailed
                )
            }

            do {
                try await withTaskCancellationHandler(
                    operation: {
                        try await transport.sendFrame(acknowledgementFrame)
                    },
                    onCancel: {
                        Task { await self.runTaskCancelled() }
                    }
                )
            } catch {
                try requireRunning()
                if Task.isCancelled {
                    try await terminateForObservedTaskCancellation()
                }
                try await terminateWithPendingAcknowledgement(
                    acknowledgement,
                    failure: .acknowledgementSendFailed
                )
            }

            try requireRunning()
            if Task.isCancelled {
                try await terminateForObservedTaskCancellation()
            }

            do {
                try gate.acknowledgementDelivered(acknowledgement)
                runPhase = .receiving
            } catch {
                state = .terminal
                runPhase = nil
                await transport.close()
                throw error
            }

            if event.outcome == .failed {
                state = .terminal
                runPhase = nil
                await transport.close()
                throw DriverError.childReportedFailure
            }
            if gate.isCompleted {
                state = .completed
                runPhase = nil
                await transport.close()
                return
            }
        }
    }

    package func cancel() async {
        switch state {
        case .idle, .running:
            // Claim termination before the close await. Even when the
            // durable failure transition is uncertain, close must release a
            // suspended reader/writer and no caller may retry the gate.
            state = .terminal
            runPhase = nil
            try? gate.cancel()
            await transport.close()
        case .completed, .terminal:
            return
        }
    }

    private func runTaskCancelled() async {
        guard state == .running else {
            return
        }
        let phase = runPhase
        runTaskCancellationClaimed = true
        state = .terminal
        runPhase = nil
        do {
            switch phase {
            case .receiving, .none:
                try gate.cancel()
            case let .sending(acknowledgement):
                try gate.acknowledgementDeliveryFailed(acknowledgement)
            }
        } catch {
            // The gate owns the durable or poisoned terminal state. Retrying
            // here could publish a second successor across an uncertain
            // persistence boundary.
        }
        await transport.close()
    }

    private func terminateForObservedTaskCancellation() async throws -> Never {
        await runTaskCancelled()
        throw runTaskCancellationClaimed
            ? DriverError.cancelled
            : DriverError.terminal
    }

    private func requireRunning() throws {
        guard state == .running else {
            throw runTaskCancellationClaimed
                ? DriverError.cancelled
                : DriverError.terminal
        }
    }

    private func terminateWithoutPendingAcknowledgement(
        gateTransition: () throws -> Void,
        failure: DriverError
    ) async throws -> Never {
        guard state == .running else {
            throw DriverError.terminal
        }
        state = .terminal
        runPhase = nil
        do {
            try gateTransition()
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
        throw failure
    }

    private func terminateWithPendingAcknowledgement(
        _ acknowledgement: SpiceLiveStageAcknowledgement,
        failure: DriverError
    ) async throws -> Never {
        guard state == .running else {
            throw DriverError.terminal
        }
        state = .terminal
        runPhase = nil
        do {
            try gate.acknowledgementDeliveryFailed(acknowledgement)
        } catch {
            // The gate retains the exact acknowledgement even if persisting
            // the terminal successor crossed an uncertain fsync boundary.
            await transport.close()
            throw error
        }
        await transport.close()
        throw failure
    }
}
