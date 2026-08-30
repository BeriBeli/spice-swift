import Foundation
import SwiftSpice

/// A bounded, fail-closed admission gate for one predeclared paired campaign.
/// It performs no I/O and does not retry or replace any run evidence.
package struct SpiceLiveCampaignArtifactAccumulator: Sendable {
    private enum Phase: Sendable {
        case collecting
        case evaluated
        case failed
    }

    private let plan: SpiceLiveCampaignPlan
    private let pointerMode: SpicePointerMode
    private var phase: Phase = .collecting
    private var nextRunIndex = 0
    private var evidenceRunIDsByLogicalRunID: [String: String] = [:]
    private var usedEvidenceRunIDs = Set<String>()
    private var records: [SpiceInteractionTraceRecord] = []
    private var resourceSamplesByLogicalRunID:
        [String: SpicePairedInteractionResourceSample] = [:]

    package init(plan: SpiceLiveCampaignPlan, pointerMode: SpicePointerMode) {
        self.plan = plan
        self.pointerMode = pointerMode
        evidenceRunIDsByLogicalRunID.reserveCapacity(20)
        usedEvidenceRunIDs.reserveCapacity(20)
        records.reserveCapacity(60)
        resourceSamplesByLogicalRunID.reserveCapacity(20)
    }

    package mutating func recordRun(
        logicalRunID: String,
        evidenceRunID: String,
        canonicalRecords: [Data]
    ) throws {
        do {
            guard case .collecting = phase,
                  plan.runs.indices.contains(nextRunIndex),
                  plan.runs[nextRunIndex].runID == logicalRunID,
                  !evidenceRunID.isEmpty,
                  canonicalRecords.count == 3,
                  records.count <= 60 - canonicalRecords.count,
                  evidenceRunIDsByLogicalRunID[logicalRunID] == nil,
                  !usedEvidenceRunIDs.contains(evidenceRunID) else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }

            let run = plan.runs[nextRunIndex]
            let decoded = try canonicalRecords.map(Self.decodeCanonicalRecord)
            guard decoded.count == run.steps.count else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }
            for (record, step) in zip(decoded, run.steps) {
                guard record.schemaVersion == SpiceInteractionTraceRecord.currentSchemaVersion,
                      record.valid,
                      record.invalidReason == nil,
                      record.runId == evidenceRunID,
                      record.version == run.version,
                      record.order == step.order,
                      record.actionClass == step.actionClass,
                      record.pairId == step.pairID,
                      record.token == step.token,
                      record.markerChecksum == String(format: "%08x", step.checksum)
                else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
            }
            if let sample = resourceSamplesByLogicalRunID[logicalRunID] {
                guard sample.runId == evidenceRunID else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
            }

            evidenceRunIDsByLogicalRunID[logicalRunID] = evidenceRunID
            usedEvidenceRunIDs.insert(evidenceRunID)
            records.append(contentsOf: decoded)
            nextRunIndex += 1
        } catch {
            phase = .failed
            throw error
        }
    }

    package mutating func recordResourceSample(
        logicalRunID: String,
        sample: SpicePairedInteractionResourceSample
    ) throws {
        do {
            guard case .collecting = phase,
                  plan.runs.contains(where: { $0.runID == logicalRunID }),
                  resourceSamplesByLogicalRunID.count < 20,
                  resourceSamplesByLogicalRunID[logicalRunID] == nil,
                  !sample.runId.isEmpty,
                  sample.cpuPercent.isFinite,
                  sample.cpuPercent >= 0 else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }
            if let evidenceRunID = evidenceRunIDsByLogicalRunID[logicalRunID] {
                guard sample.runId == evidenceRunID else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
            }
            resourceSamplesByLogicalRunID[logicalRunID] = sample
        } catch {
            phase = .failed
            throw error
        }
    }

    package func evidenceRunID(forLogicalRunID logicalRunID: String) -> String? {
        evidenceRunIDsByLogicalRunID[logicalRunID]
    }

    package mutating func evaluate(
        execution: SpiceLiveCampaignExecution
    ) throws -> SpicePairedInteractionArtifactReport {
        do {
            let canonicalLedger = try Self.canonicalLedger(for: plan)
            guard case .collecting = phase,
                  nextRunIndex == plan.runs.count,
                  records.count == 60,
                  resourceSamplesByLogicalRunID.count == 20,
                  execution.plan == plan,
                  execution.campaignCompleted,
                  !execution.campaignFailed,
                  execution.entries == canonicalLedger
            else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }

            var resources: [SpicePairedInteractionResourceSample] = []
            resources.reserveCapacity(20)
            for run in plan.runs {
                guard let evidenceRunID = evidenceRunIDsByLogicalRunID[run.runID],
                      let sample = resourceSamplesByLogicalRunID[run.runID],
                      sample.runId == evidenceRunID else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
                resources.append(sample)
            }

            let report = try SpicePairedInteractionArtifactEvaluator.evaluate(
                records: records,
                resourceSamples: resources,
                specification: try plan.specification(pointerMode: pointerMode)
            )
            phase = .evaluated
            return report
        } catch {
            phase = .failed
            throw error
        }
    }

    private static func decodeCanonicalRecord(
        _ line: Data
    ) throws -> SpiceInteractionTraceRecord {
        guard !line.isEmpty,
              line.count <= SpiceInteractionTraceJSONLWriter.maximumRecordBytes,
              line.last == 0x0a else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let record = try JSONDecoder().decode(
            SpiceInteractionTraceRecord.self,
            from: Data(line.dropLast())
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var canonical = try encoder.encode(record)
        canonical.append(0x0a)
        guard canonical == line else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return record
    }

    private static func canonicalLedger(
        for plan: SpiceLiveCampaignPlan
    ) throws -> [SpiceLiveAttemptLedgerEntry] {
        var execution = SpiceLiveCampaignExecution(plan: plan)
        for _ in plan.runs {
            _ = try execution.beginNextRun()
            for stage in [
                SpiceLiveAttemptStage.fixtureStop,
                .fixtureStart,
                .fixtureHealth,
                .preArm, .arm, .postArm,
                .preArm, .arm, .postArm,
                .preArm, .arm, .postArm,
                .teardown,
            ] {
                try execution.record(stage: stage, outcome: .succeeded)
            }
        }
        guard execution.campaignCompleted,
              execution.entries.count == 260 else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return execution.entries
    }
}
