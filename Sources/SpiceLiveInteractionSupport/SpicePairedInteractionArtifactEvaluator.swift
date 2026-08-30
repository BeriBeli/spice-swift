import Foundation
import SwiftSpice

package enum SpicePairedInteractionArtifactError: Error, Sendable, Equatable {
    case invalidSpecification
    case duplicateObservation
    case missingObservation
    case reorderedObservation
    case identityMismatch
    case unexpectedVersion
    case reusedRunID
    case unexpectedObservation
    case invalidRecord
    case acknowledgementMismatch
    case missingResourceSample
    case duplicateResourceSample
    case resourceIdentityMismatch
    case invalidResourceSample
    case arithmeticOverflow
    case nonFiniteValue
}

package struct SpicePairedInteractionRunKey: Sendable, Hashable {
    package let clusterID: String
    package let version: String

    package init(clusterID: String, version: String) {
        self.clusterID = clusterID
        self.version = version
    }
}

package struct SpicePairedInteractionArtifactSpecification: Sendable, Equatable {
    package let baselineVersion: String
    package let candidateVersion: String
    package let clusterIDs: [String]
    package let pointerMode: SpicePointerMode
    package let runSequence: [SpicePairedInteractionRunKey]

    package init(
        baselineVersion: String,
        candidateVersion: String,
        clusterIDs: [String],
        pointerMode: SpicePointerMode,
        runSequence: [SpicePairedInteractionRunKey]
    ) throws {
        guard Self.isCanonicalVersion(baselineVersion),
              Self.isCanonicalVersion(candidateVersion),
              baselineVersion != candidateVersion,
              clusterIDs.count == 10,
              Set(clusterIDs).count == clusterIDs.count,
              clusterIDs.allSatisfy(Self.isCanonicalClusterID),
              runSequence.count == clusterIDs.count * 2
        else {
            throw SpicePairedInteractionArtifactError.invalidSpecification
        }

        let expectedRunKeys = Set(clusterIDs.flatMap { clusterID in
            [
                SpicePairedInteractionRunKey(
                    clusterID: clusterID,
                    version: baselineVersion
                ),
                SpicePairedInteractionRunKey(
                    clusterID: clusterID,
                    version: candidateVersion
                ),
            ]
        })
        guard Set(runSequence) == expectedRunKeys,
              Set(runSequence).count == runSequence.count,
              Self.isCounterbalanced(
                  runSequence,
                  clusterIDs: clusterIDs,
                  baselineVersion: baselineVersion,
                  candidateVersion: candidateVersion
              ),
              try Self.hasThirtyDistinctPlanIdentities(clusterIDs: clusterIDs)
        else {
            throw SpicePairedInteractionArtifactError.invalidSpecification
        }

        self.baselineVersion = baselineVersion
        self.candidateVersion = candidateVersion
        self.clusterIDs = clusterIDs
        self.pointerMode = pointerMode
        self.runSequence = runSequence
    }

    private static func isCounterbalanced(
        _ runSequence: [SpicePairedInteractionRunKey],
        clusterIDs: [String],
        baselineVersion: String,
        candidateVersion: String
    ) -> Bool {
        var baselineFirstCount = 0
        for (index, clusterID) in clusterIDs.enumerated() {
            let pairOffset = index * 2
            let first = runSequence[pairOffset]
            let second = runSequence[pairOffset + 1]
            guard first.clusterID == clusterID,
                  second.clusterID == clusterID,
                  first.version != second.version,
                  (first.version == baselineVersion || first.version == candidateVersion),
                  (second.version == baselineVersion || second.version == candidateVersion)
            else {
                return false
            }
            if first.version == baselineVersion {
                baselineFirstCount += 1
            }
        }
        return baselineFirstCount == clusterIDs.count / 2
    }

    private static func isCanonicalClusterID(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static func isCanonicalVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.first == Character("v").asciiValue else { return false }
        let components = bytes.dropFirst().split(
            separator: Character(".").asciiValue!,
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy({ $0 >= 48 && $0 <= 57 }) else {
                return false
            }
            return component.count == 1 || component.first != 48
        }
    }

    private static func hasThirtyDistinctPlanIdentities(
        clusterIDs: [String]
    ) throws -> Bool {
        var identities = Set<PlanIdentity>()
        for clusterID in clusterIDs {
            for step in try completedSteps(clusterID: clusterID) {
                guard identities.insert(PlanIdentity(step: step)).inserted else {
                    return false
                }
            }
        }
        return identities.count == clusterIDs.count * 3
    }
}

package struct SpicePairedInteractionResourceSample: Sendable, Equatable {
    package let runId: String
    package let cpuPercent: Double
    package let peakRSSBytes: UInt64

    package init(runId: String, cpuPercent: Double, peakRSSBytes: UInt64) {
        self.runId = runId
        self.cpuPercent = cpuPercent
        self.peakRSSBytes = peakRSSBytes
    }
}

package struct SpicePairedInteractionHostStages: Sendable, Equatable {
    package let scheduledToHostInputNanoseconds: UInt64
    package let hostInputToSendStartedNanoseconds: UInt64
    package let sendStartedToCompletedNanoseconds: UInt64
    package let sendCompletedToDisplayNanoseconds: UInt64
    package let displayToSurfaceReadyNanoseconds: UInt64
    package let surfaceReadyToSelectedReadyNanoseconds: UInt64
    package let selectedReadyToSelectionNanoseconds: UInt64
    package let selectionToCommitNanoseconds: UInt64
    package let commitToPresentedNanoseconds: UInt64
    package let inputToPresentedNanoseconds: UInt64
    package let guestMarkerDrawNanoseconds: UInt64
}

package struct SpicePairedInteractionObservation: Sendable, Equatable {
    package let runKey: SpicePairedInteractionRunKey
    package let record: SpiceInteractionTraceRecord
    package let stages: SpicePairedInteractionHostStages
}

package struct SpiceLiveQuantiles: Sendable, Equatable {
    package let p50Nanoseconds: Double
    package let p95Nanoseconds: Double
}

package struct SpicePairedInteractionPair: Sendable, Equatable {
    package let clusterID: String
    package let baseline: SpicePairedInteractionObservation
    package let candidate: SpicePairedInteractionObservation
    package let inputToPresentedDeltaNanoseconds: Int64
}

package struct SpicePairedInteractionActionSummary: Sendable, Equatable {
    package let pairs: [SpicePairedInteractionPair]
    package let baselineInputToPresented: SpiceLiveQuantiles
    package let candidateInputToPresented: SpiceLiveQuantiles
    package let pairedInputToPresentedDelta: SpiceLiveQuantiles
}

package struct SpicePairedInteractionResourceObservation: Sendable, Equatable {
    package let runKey: SpicePairedInteractionRunKey
    package let sample: SpicePairedInteractionResourceSample
}

package struct SpicePairedInteractionResourcePair: Sendable, Equatable {
    package let clusterID: String
    package let baseline: SpicePairedInteractionResourceObservation
    package let candidate: SpicePairedInteractionResourceObservation
    package let cpuPercentDelta: Double
    package let peakRSSBytesDelta: Int64
}

/// Resource measurements are reported independently. They never admit,
/// reject, filter, or otherwise alter any latency observation.
package struct SpicePairedInteractionResourceGuardrails: Sendable, Equatable {
    package let observations: [SpicePairedInteractionResourceObservation]
    package let pairs: [SpicePairedInteractionResourcePair]
    package let baselineCPUPercent: SpiceLiveQuantiles
    package let candidateCPUPercent: SpiceLiveQuantiles
    package let pairedCPUPercentDelta: SpiceLiveQuantiles
    package let baselinePeakRSSBytes: SpiceLiveQuantiles
    package let candidatePeakRSSBytes: SpiceLiveQuantiles
    package let pairedPeakRSSBytesDelta: SpiceLiveQuantiles
}

package struct SpicePairedInteractionArtifactReport: Sendable, Equatable {
    package let recordCount: Int
    package let runCount: Int
    package let observations: [SpicePairedInteractionObservation]
    package let resourceGuardrails: SpicePairedInteractionResourceGuardrails

    private let clickSummary: SpicePairedInteractionActionSummary
    private let keySummary: SpicePairedInteractionActionSummary
    private let motionSummary: SpicePairedInteractionActionSummary

    fileprivate init(
        recordCount: Int,
        runCount: Int,
        observations: [SpicePairedInteractionObservation],
        resourceGuardrails: SpicePairedInteractionResourceGuardrails,
        clickSummary: SpicePairedInteractionActionSummary,
        keySummary: SpicePairedInteractionActionSummary,
        motionSummary: SpicePairedInteractionActionSummary
    ) {
        self.recordCount = recordCount
        self.runCount = runCount
        self.observations = observations
        self.resourceGuardrails = resourceGuardrails
        self.clickSummary = clickSummary
        self.keySummary = keySummary
        self.motionSummary = motionSummary
    }

    package func summary(
        for actionClass: SpiceInteractionActionClass
    ) -> SpicePairedInteractionActionSummary {
        switch actionClass {
        case .click:
            clickSummary
        case .key:
            keySummary
        case .motion:
            motionSummary
        }
    }
}

package enum SpicePairedInteractionArtifactEvaluator {
    package static func evaluate(
        records: [SpiceInteractionTraceRecord],
        resourceSamples: [SpicePairedInteractionResourceSample],
        specification: SpicePairedInteractionArtifactSpecification
    ) throws -> SpicePairedInteractionArtifactReport {
        let accepted = try acceptRecords(records, specification: specification)
        let resources = try acceptResources(
            resourceSamples,
            runIDs: accepted.runIDs,
            specification: specification
        )

        return SpicePairedInteractionArtifactReport(
            recordCount: records.count,
            runCount: accepted.runIDs.count,
            observations: accepted.observations,
            resourceGuardrails: try resourceGuardrails(
                observations: resources,
                specification: specification
            ),
            clickSummary: try actionSummary(
                .click,
                observations: accepted.observations,
                specification: specification
            ),
            keySummary: try actionSummary(
                .key,
                observations: accepted.observations,
                specification: specification
            ),
            motionSummary: try actionSummary(
                .motion,
                observations: accepted.observations,
                specification: specification
            )
        )
    }

    private struct AcceptedRecords {
        let observations: [SpicePairedInteractionObservation]
        let runIDs: [SpicePairedInteractionRunKey: String]
    }

    private static func acceptRecords(
        _ records: [SpiceInteractionTraceRecord],
        specification: SpicePairedInteractionArtifactSpecification
    ) throws -> AcceptedRecords {
        guard records.allSatisfy({ $0.valid && $0.invalidReason == nil }) else {
            throw SpicePairedInteractionArtifactError.invalidRecord
        }
        let acceptedVersions = [
            specification.baselineVersion,
            specification.candidateVersion,
        ]
        guard records.allSatisfy({ acceptedVersions.contains($0.version) }) else {
            throw SpicePairedInteractionArtifactError.unexpectedVersion
        }

        var observationKeys = Set<RecordObservationKey>()
        for record in records {
            guard observationKeys.insert(RecordObservationKey(record)).inserted else {
                throw SpicePairedInteractionArtifactError.duplicateObservation
            }
        }

        let expectedCount = specification.runSequence.count * 3
        guard records.count >= expectedCount else {
            throw SpicePairedInteractionArtifactError.missingObservation
        }
        guard records.count <= expectedCount else {
            throw SpicePairedInteractionArtifactError.unexpectedObservation
        }

        var observations: [SpicePairedInteractionObservation] = []
        observations.reserveCapacity(expectedCount)
        var runIDs: [SpicePairedInteractionRunKey: String] = [:]
        var usedRunIDs = Set<String>()

        for (runOffset, runKey) in specification.runSequence.enumerated() {
            let recordOffset = runOffset * 3
            let runRecords = records[recordOffset..<(recordOffset + 3)]
            guard let first = runRecords.first,
                  runRecords.allSatisfy({ $0.runId == first.runId }),
                  runRecords.allSatisfy({ $0.version == runKey.version }) else {
                throw SpicePairedInteractionArtifactError.reorderedObservation
            }
            guard usedRunIDs.insert(first.runId).inserted else {
                throw SpicePairedInteractionArtifactError.reusedRunID
            }
            runIDs[runKey] = first.runId

            let steps = try completedSteps(clusterID: runKey.clusterID)
            for (record, step) in zip(runRecords, steps) {
                guard record.order == step.order else {
                    throw SpicePairedInteractionArtifactError.reorderedObservation
                }
                guard record.actionClass == step.actionClass,
                      record.pairId == step.pairID,
                      record.token == step.token,
                      record.markerChecksum == String(format: "%08x", step.checksum)
                else {
                    throw SpicePairedInteractionArtifactError.identityMismatch
                }
                let requiresAcknowledgement = step.requiresMotionAcknowledgement(
                    for: specification.pointerMode
                )
                guard (record.motionAckNs != nil) == requiresAcknowledgement else {
                    throw SpicePairedInteractionArtifactError.acknowledgementMismatch
                }
                observations.append(SpicePairedInteractionObservation(
                    runKey: runKey,
                    record: record,
                    stages: try stages(for: record)
                ))
            }
        }

        guard runIDs.count == specification.runSequence.count else {
            throw SpicePairedInteractionArtifactError.missingObservation
        }
        return AcceptedRecords(observations: observations, runIDs: runIDs)
    }

    private static func acceptResources(
        _ samples: [SpicePairedInteractionResourceSample],
        runIDs: [SpicePairedInteractionRunKey: String],
        specification: SpicePairedInteractionArtifactSpecification
    ) throws -> [SpicePairedInteractionResourceObservation] {
        guard samples.allSatisfy({
            !$0.runId.isEmpty && $0.cpuPercent.isFinite && $0.cpuPercent >= 0
        }) else {
            throw SpicePairedInteractionArtifactError.invalidResourceSample
        }

        var samplesByRunID: [String: SpicePairedInteractionResourceSample] = [:]
        for sample in samples {
            guard samplesByRunID.updateValue(sample, forKey: sample.runId) == nil else {
                throw SpicePairedInteractionArtifactError.duplicateResourceSample
            }
        }
        guard samples.count >= specification.runSequence.count else {
            throw SpicePairedInteractionArtifactError.missingResourceSample
        }
        guard samples.count <= specification.runSequence.count else {
            throw SpicePairedInteractionArtifactError.resourceIdentityMismatch
        }

        let acceptedRunIDs = Set(runIDs.values)
        guard Set(samplesByRunID.keys) == acceptedRunIDs else {
            throw SpicePairedInteractionArtifactError.resourceIdentityMismatch
        }
        return try specification.runSequence.map { runKey in
            guard let runID = runIDs[runKey],
                  let sample = samplesByRunID[runID] else {
                throw SpicePairedInteractionArtifactError.missingResourceSample
            }
            return SpicePairedInteractionResourceObservation(
                runKey: runKey,
                sample: sample
            )
        }
    }

    private static func stages(
        for record: SpiceInteractionTraceRecord
    ) throws -> SpicePairedInteractionHostStages {
        guard let scheduled = record.scheduledNs,
              let hostInput = record.hostInputNs,
              let sendStarted = record.sendStartedNs,
              let sendCompleted = record.sendCompletedNs,
              let displayReceive = record.displayReceiveNs,
              let surfaceReady = record.surfaceReadyNs,
              let selectedReady = record.selectedRevisionReadyNs,
              let selection = record.selectionNs,
              let commit = record.metalCommitNs,
              let presented = record.presentedNs,
              let guestReceived = record.guestReceivedNs,
              let guestDrawn = record.guestMarkerDrawnNs,
              let sendToDisplay = record.sendToDisplayNanoseconds
        else {
            throw SpicePairedInteractionArtifactError.invalidRecord
        }
        return SpicePairedInteractionHostStages(
            scheduledToHostInputNanoseconds: try checkedDifference(hostInput, scheduled),
            hostInputToSendStartedNanoseconds: try checkedDifference(sendStarted, hostInput),
            sendStartedToCompletedNanoseconds: try checkedDifference(sendCompleted, sendStarted),
            sendCompletedToDisplayNanoseconds: sendToDisplay,
            displayToSurfaceReadyNanoseconds: try checkedDifference(
                surfaceReady,
                displayReceive
            ),
            surfaceReadyToSelectedReadyNanoseconds: try checkedDifference(
                selectedReady,
                surfaceReady
            ),
            selectedReadyToSelectionNanoseconds: try checkedDifference(
                selection,
                selectedReady
            ),
            selectionToCommitNanoseconds: try checkedDifference(commit, selection),
            commitToPresentedNanoseconds: try checkedDifference(presented, commit),
            inputToPresentedNanoseconds: try checkedDifference(presented, hostInput),
            guestMarkerDrawNanoseconds: try checkedDifference(guestDrawn, guestReceived)
        )
    }

    private static func actionSummary(
        _ actionClass: SpiceInteractionActionClass,
        observations: [SpicePairedInteractionObservation],
        specification: SpicePairedInteractionArtifactSpecification
    ) throws -> SpicePairedInteractionActionSummary {
        var indexed: [ObservationIndex: SpicePairedInteractionObservation] = [:]
        for observation in observations where observation.record.actionClass == actionClass {
            let index = ObservationIndex(
                clusterID: observation.runKey.clusterID,
                version: observation.runKey.version,
                actionClass: actionClass
            )
            guard indexed.updateValue(observation, forKey: index) == nil else {
                throw SpicePairedInteractionArtifactError.duplicateObservation
            }
        }

        let pairs = try specification.clusterIDs.map { clusterID in
            let baselineIndex = ObservationIndex(
                clusterID: clusterID,
                version: specification.baselineVersion,
                actionClass: actionClass
            )
            let candidateIndex = ObservationIndex(
                clusterID: clusterID,
                version: specification.candidateVersion,
                actionClass: actionClass
            )
            guard let baseline = indexed[baselineIndex],
                  let candidate = indexed[candidateIndex] else {
                throw SpicePairedInteractionArtifactError.missingObservation
            }
            return SpicePairedInteractionPair(
                clusterID: clusterID,
                baseline: baseline,
                candidate: candidate,
                inputToPresentedDeltaNanoseconds: try checkedSignedDifference(
                    candidate.stages.inputToPresentedNanoseconds,
                    baseline.stages.inputToPresentedNanoseconds
                )
            )
        }
        return SpicePairedInteractionActionSummary(
            pairs: pairs,
            baselineInputToPresented: try quantiles(
                pairs.map { $0.baseline.stages.inputToPresentedNanoseconds }
            ),
            candidateInputToPresented: try quantiles(
                pairs.map { $0.candidate.stages.inputToPresentedNanoseconds }
            ),
            pairedInputToPresentedDelta: try quantiles(
                pairs.map(\.inputToPresentedDeltaNanoseconds)
            )
        )
    }

    private static func resourceGuardrails(
        observations: [SpicePairedInteractionResourceObservation],
        specification: SpicePairedInteractionArtifactSpecification
    ) throws -> SpicePairedInteractionResourceGuardrails {
        let indexed = Dictionary(uniqueKeysWithValues: observations.map {
            ($0.runKey, $0)
        })
        let pairs = try specification.clusterIDs.map { clusterID in
            let baselineKey = SpicePairedInteractionRunKey(
                clusterID: clusterID,
                version: specification.baselineVersion
            )
            let candidateKey = SpicePairedInteractionRunKey(
                clusterID: clusterID,
                version: specification.candidateVersion
            )
            guard let baseline = indexed[baselineKey],
                  let candidate = indexed[candidateKey] else {
                throw SpicePairedInteractionArtifactError.missingResourceSample
            }
            let cpuDelta = candidate.sample.cpuPercent - baseline.sample.cpuPercent
            guard cpuDelta.isFinite else {
                throw SpicePairedInteractionArtifactError.nonFiniteValue
            }
            return SpicePairedInteractionResourcePair(
                clusterID: clusterID,
                baseline: baseline,
                candidate: candidate,
                cpuPercentDelta: cpuDelta,
                peakRSSBytesDelta: try checkedSignedDifference(
                    candidate.sample.peakRSSBytes,
                    baseline.sample.peakRSSBytes
                )
            )
        }
        return SpicePairedInteractionResourceGuardrails(
            observations: observations,
            pairs: pairs,
            baselineCPUPercent: try quantiles(pairs.map { $0.baseline.sample.cpuPercent }),
            candidateCPUPercent: try quantiles(pairs.map { $0.candidate.sample.cpuPercent }),
            pairedCPUPercentDelta: try quantiles(pairs.map(\.cpuPercentDelta)),
            baselinePeakRSSBytes: try quantiles(pairs.map { $0.baseline.sample.peakRSSBytes }),
            candidatePeakRSSBytes: try quantiles(pairs.map { $0.candidate.sample.peakRSSBytes }),
            pairedPeakRSSBytesDelta: try quantiles(pairs.map(\.peakRSSBytesDelta))
        )
    }

    private static func checkedDifference(
        _ later: UInt64,
        _ earlier: UInt64
    ) throws -> UInt64 {
        let (difference, overflow) = later.subtractingReportingOverflow(earlier)
        guard !overflow else {
            throw SpicePairedInteractionArtifactError.arithmeticOverflow
        }
        return difference
    }

    private static func checkedSignedDifference(
        _ candidate: UInt64,
        _ baseline: UInt64
    ) throws -> Int64 {
        if candidate >= baseline {
            let magnitude = candidate - baseline
            guard magnitude <= UInt64(Int64.max) else {
                throw SpicePairedInteractionArtifactError.arithmeticOverflow
            }
            return Int64(magnitude)
        }
        let magnitude = baseline - candidate
        guard magnitude <= UInt64(Int64.max) else {
            throw SpicePairedInteractionArtifactError.arithmeticOverflow
        }
        return -Int64(magnitude)
    }

    private static func quantiles(_ values: [UInt64]) throws -> SpiceLiveQuantiles {
        try quantiles(values.map { Double($0) })
    }

    private static func quantiles(_ values: [Int64]) throws -> SpiceLiveQuantiles {
        try quantiles(values.map { Double($0) })
    }

    private static func quantiles(_ values: [Double]) throws -> SpiceLiveQuantiles {
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            throw SpicePairedInteractionArtifactError.nonFiniteValue
        }
        let sorted = values.sorted()
        return SpiceLiveQuantiles(
            p50Nanoseconds: try typeSevenQuantile(sorted: sorted, probability: 0.50),
            p95Nanoseconds: try typeSevenQuantile(sorted: sorted, probability: 0.95)
        )
    }

    private static func typeSevenQuantile(
        sorted: [Double],
        probability: Double
    ) throws -> Double {
        guard !sorted.isEmpty,
              probability.isFinite,
              probability >= 0,
              probability <= 1 else {
            throw SpicePairedInteractionArtifactError.nonFiniteValue
        }
        let position = Double(sorted.count - 1) * probability
        guard position.isFinite else {
            throw SpicePairedInteractionArtifactError.nonFiniteValue
        }
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        let fraction = position - Double(lower)
        let result = sorted[lower] + fraction * (sorted[upper] - sorted[lower])
        guard result.isFinite else {
            throw SpicePairedInteractionArtifactError.nonFiniteValue
        }
        return result
    }
}

private struct PlanIdentity: Hashable {
    let pairID: String
    let token: String
    let checksum: UInt32

    init(step: SpiceLiveInteractionClusterPlan.Step) {
        pairID = step.pairID
        token = step.token
        checksum = step.checksum
    }
}

private struct RecordObservationKey: Hashable {
    let runID: String
    let version: String
    let order: UInt64
    let actionClass: String
    let pairID: String
    let token: String

    init(_ record: SpiceInteractionTraceRecord) {
        runID = record.runId
        version = record.version
        order = record.order
        actionClass = record.actionClass.rawValue
        pairID = record.pairId
        token = record.token
    }
}

private struct ObservationIndex: Hashable {
    let clusterID: String
    let version: String
    let actionClass: String

    init(
        clusterID: String,
        version: String,
        actionClass: SpiceInteractionActionClass
    ) {
        self.clusterID = clusterID
        self.version = version
        self.actionClass = actionClass.rawValue
    }
}

private func completedSteps(
    clusterID: String
) throws -> [SpiceLiveInteractionClusterPlan.Step] {
    var plan = try SpiceLiveInteractionClusterPlan(clusterID: clusterID)
    var steps: [SpiceLiveInteractionClusterPlan.Step] = []
    steps.reserveCapacity(3)
    for _ in 0..<3 {
        let step = try plan.beginNextStep()
        steps.append(step)
        try plan.recordExactPresentation(order: step.order)
        try plan.recordAppendCompleted(order: step.order)
    }
    return steps
}
