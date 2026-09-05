import Foundation
import Synchronization

package final class SpiceLiveRemoteFixtureLease: Sendable {
    package struct Command: Sendable, Equatable {
        package let executableURL: URL
        package let arguments: [String]

        fileprivate init(executableURL: URL, arguments: [String]) {
            self.executableURL = executableURL
            self.arguments = arguments
        }
    }

    private enum LeaseError: Error, Sendable {
        case invalidConfiguration
        case invalidCommand
        case invalidResult
        case terminal
    }

    private enum Operation: Int, Sendable {
        case stop
        case start
        case health

        var stage: SpiceLiveAttemptStage {
            switch self {
            case .stop: .fixtureStop
            case .start: .fixtureStart
            case .health: .fixtureHealth
            }
        }

        var script: String {
            switch self {
            case .stop: "stop.sh"
            case .start: "start.sh"
            case .health: "status.sh"
            }
        }

        var next: Operation? {
            Operation(rawValue: rawValue + 1)
        }
    }

    private struct State: Sendable {
        var operation: Operation? = .stop
        var evidenceRunID: SpiceLiveEvidenceRunID?
    }

    private let configuration: SpiceRemoteLiveConfiguration
    private let run: SpiceLiveCampaignRun
    private let executionContractDigest: String
    private let recorder: SpiceLiveRealtimeStageRecorder
    private let state = Mutex(State())

    package init(
        configuration: SpiceRemoteLiveConfiguration,
        run: SpiceLiveCampaignRun,
        executionContractDigest: String,
        recorder: SpiceLiveRealtimeStageRecorder
    ) throws {
        let manifest = recorder.snapshot
        let runIndex = manifest.stages.count / 13
        guard configuration.version == run.version,
              configuration.clusterID == run.clusterID,
              Self.isLowerHex(run.campaignID, count: 16),
              Self.isLowerHex(run.runID, count: 16),
              Self.isLowerHex(executionContractDigest, count: 64),
              run.sequence > 0,
              manifest.state == .recording,
              manifest.campaignID == run.campaignID,
              manifest.executionContractDigest == executionContractDigest,
              manifest.executionContract?.remoteImageReference == configuration.image,
              manifest.stages.count.isMultiple(of: 13),
              manifest.runs.indices.contains(runIndex),
              manifest.runs[runIndex].logicalRunID == run.runID,
              manifest.runs[runIndex].version == run.version,
              manifest.runs[runIndex].clusterID == run.clusterID,
              manifest.runs[runIndex].sequence == run.sequence,
              manifest.runs[runIndex].evidenceRunID == nil else {
            throw LeaseError.invalidConfiguration
        }
        self.configuration = configuration
        self.run = run
        self.executionContractDigest = executionContractDigest
        self.recorder = recorder
    }

    package func nextCommand() throws -> Command {
        try state.withLock { state in
            guard let operation = state.operation else {
                throw LeaseError.terminal
            }
            return command(for: operation)
        }
    }

    package func accept(
        result: SpiceLiveProcessResult,
        for command: Command
    ) throws {
        try state.withLock { state in
            guard let operation = state.operation else {
                throw LeaseError.terminal
            }
            guard command == self.command(for: operation) else {
                state.operation = nil
                try recorder.failClosedAfterExternalBoundary()
                throw LeaseError.invalidCommand
            }

            let evidenceRunID: SpiceLiveEvidenceRunID?
            do {
                evidenceRunID = try validate(
                    result: result,
                    operation: operation,
                    expectedEvidenceRunID: state.evidenceRunID
                )
            } catch {
                try fail(operation: operation, state: &state)
                throw error
            }

            do {
                try recorder.record(
                    run: run,
                    stage: operation.stage,
                    outcome: .succeeded,
                    evidenceRunID: evidenceRunID
                )
            } catch {
                state.operation = nil
                throw error
            }
            if let evidenceRunID {
                state.evidenceRunID = evidenceRunID
            }
            state.operation = operation.next
        }
    }

    private func fail(
        operation: Operation,
        state: inout State
    ) throws {
        state.operation = nil
        try recorder.record(
            run: run,
            stage: operation.stage,
            outcome: .failed
        )
    }

    private func command(for operation: Operation) -> Command {
        Command(
            executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
            arguments: [
                "-o", "BatchMode=yes", configuration.sshHost, "/usr/bin/env",
                "SWIFTSPICE_PERF_BASE=\(configuration.base)",
                "SWIFTSPICE_PERF_CONTAINER=\(configuration.container)",
                "SWIFTSPICE_PERF_IMAGE=\(configuration.image)",
                "SWIFTSPICE_PERF_SPICE_PORT=\(configuration.spicePort)",
                "SWIFTSPICE_PERF_CONTROL_PORT=\(configuration.controlPort)",
                "SWIFTSPICE_LIVE_CAMPAIGN_ID=\(run.campaignID)",
                "SWIFTSPICE_LIVE_LOGICAL_RUN_ID=\(run.runID)",
                "SWIFTSPICE_LIVE_VERSION=\(run.version)",
                "SWIFTSPICE_LIVE_CLUSTER_ID=\(run.clusterID)",
                "SWIFTSPICE_LIVE_RUN_SEQUENCE=\(run.sequence)",
                "SWIFTSPICE_LIVE_EXECUTION_CONTRACT_DIGEST=\(executionContractDigest)",
                "\(configuration.base)/remote/\(operation.script)",
            ]
        )
    }

    private func validate(
        result: SpiceLiveProcessResult,
        operation: Operation,
        expectedEvidenceRunID: SpiceLiveEvidenceRunID?
    ) throws -> SpiceLiveEvidenceRunID? {
        guard result.status == 0 else {
            throw LeaseError.invalidResult
        }
        switch operation {
        case .stop:
            return nil
        case .start:
            return try parseEvidenceRunID(lines: result.outputLines)
        case .health:
            guard let expectedEvidenceRunID else {
                throw LeaseError.invalidResult
            }
            try validateHealth(
                lines: result.outputLines,
                expectedEvidenceRunID: expectedEvidenceRunID
            )
            return nil
        }
    }

    private func parseEvidenceRunID(
        lines: [String]
    ) throws -> SpiceLiveEvidenceRunID {
        let prefix = "run_evidence="
        let paths = lines.compactMap { line -> String? in
            guard line.hasPrefix(prefix) else { return nil }
            return String(line.dropFirst(prefix.count))
        }
        let directoryPrefix = "\(configuration.base)/logs/"
        guard paths.count == 1,
              paths[0].hasPrefix(directoryPrefix) else {
            throw LeaseError.invalidResult
        }
        let basename = String(paths[0].dropFirst(directoryPrefix.count))
        let evidenceRunID = try SpiceLiveEvidenceRunID(basename)
        guard paths[0] == directoryPrefix + evidenceRunID.rawValue else {
            throw LeaseError.invalidResult
        }
        return evidenceRunID
    }

    private func validateHealth(
        lines: [String],
        expectedEvidenceRunID: SpiceLiveEvidenceRunID
    ) throws {
        let expected = [
            "campaign_id": run.campaignID,
            "logical_run_id": run.runID,
            "version": run.version,
            "cluster_id": run.clusterID,
            "run_sequence": String(run.sequence),
            "execution_contract_digest": executionContractDigest,
            "state": "running",
            "container": configuration.container,
            "spice": "127.0.0.1:\(configuration.spicePort)",
            "control": "127.0.0.1:\(configuration.controlPort)",
            "run_evidence": "\(configuration.base)/logs/\(expectedEvidenceRunID.rawValue)",
            "spice_listener": "ready",
            "control_listener": "ready",
        ]
        var observed: [String: String] = [:]
        observed.reserveCapacity(expected.count)
        for line in lines {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator])
            let value = String(line[line.index(after: separator)...])
            guard expected[key] != nil else { continue }
            guard observed.updateValue(value, forKey: key) == nil else {
                throw LeaseError.invalidResult
            }
        }
        guard observed == expected else {
            throw LeaseError.invalidResult
        }
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }
}
