import Foundation
import SwiftSpice

package struct SpiceLiveChildStageEvent: Codable, Sendable, Equatable {
    package let protocolVersion: SpiceLiveStageProtocolVersion
    package let campaignID: String
    package let runID: String
    package let version: String
    package let clusterID: String
    package let evidenceRunID: SpiceLiveEvidenceRunID
    package let actionClass: SpiceInteractionActionClass
    package let order: UInt64
    package let token: String
    package let checksum: UInt32
    package let stage: SpiceLiveAttemptStage
    package let outcome: SpiceLiveAttemptOutcome
    package let eventSequence: UInt64
    package let previousManifestGeneration: UInt64

    package init(
        protocolVersion: SpiceLiveStageProtocolVersion,
        campaignID: String,
        runID: String,
        version: String,
        clusterID: String,
        evidenceRunID: SpiceLiveEvidenceRunID,
        actionClass: SpiceInteractionActionClass,
        order: UInt64,
        token: String,
        checksum: UInt32,
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome,
        eventSequence: UInt64,
        previousManifestGeneration: UInt64
    ) throws {
        guard protocolVersion == .v1,
              SpiceLiveStageProtocolValidation.isLowerHex(campaignID, count: 16),
              SpiceLiveStageProtocolValidation.isLowerHex(runID, count: 16),
              SpiceLiveStageProtocolValidation.isCanonicalVersion(version),
              SpiceLiveStageProtocolValidation.isLowerHex(clusterID, count: 16),
              (1...3).contains(order),
              SpiceLiveStageProtocolValidation.isLowerHex(token, count: 16),
              SpiceLiveStageProtocolValidation.actionStages.contains(stage),
              eventSequence > 0 else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        self.protocolVersion = protocolVersion
        self.campaignID = campaignID
        self.runID = runID
        self.version = version
        self.clusterID = clusterID
        self.evidenceRunID = evidenceRunID
        self.actionClass = actionClass
        self.order = order
        self.token = token
        self.checksum = checksum
        self.stage = stage
        self.outcome = outcome
        self.eventSequence = eventSequence
        self.previousManifestGeneration = previousManifestGeneration
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(
                SpiceLiveStageProtocolVersion.self,
                forKey: .protocolVersion
            ),
            campaignID: container.decode(String.self, forKey: .campaignID),
            runID: container.decode(String.self, forKey: .runID),
            version: container.decode(String.self, forKey: .version),
            clusterID: container.decode(String.self, forKey: .clusterID),
            evidenceRunID: container.decode(
                SpiceLiveEvidenceRunID.self,
                forKey: .evidenceRunID
            ),
            actionClass: container.decode(
                SpiceInteractionActionClass.self,
                forKey: .actionClass
            ),
            order: container.decode(UInt64.self, forKey: .order),
            token: container.decode(String.self, forKey: .token),
            checksum: container.decode(UInt32.self, forKey: .checksum),
            stage: container.decode(SpiceLiveAttemptStage.self, forKey: .stage),
            outcome: container.decode(
                SpiceLiveAttemptOutcome.self,
                forKey: .outcome
            ),
            eventSequence: container.decode(UInt64.self, forKey: .eventSequence),
            previousManifestGeneration: container.decode(
                UInt64.self,
                forKey: .previousManifestGeneration
            )
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(campaignID, forKey: .campaignID)
        try container.encode(runID, forKey: .runID)
        try container.encode(version, forKey: .version)
        try container.encode(clusterID, forKey: .clusterID)
        try container.encode(evidenceRunID, forKey: .evidenceRunID)
        try container.encode(actionClass, forKey: .actionClass)
        try container.encode(order, forKey: .order)
        try container.encode(token, forKey: .token)
        try container.encode(checksum, forKey: .checksum)
        try container.encode(stage, forKey: .stage)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(eventSequence, forKey: .eventSequence)
        try container.encode(
            previousManifestGeneration,
            forKey: .previousManifestGeneration
        )
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case campaignID = "campaign_id"
        case runID = "run_id"
        case version
        case clusterID = "cluster_id"
        case evidenceRunID = "evidence_run_id"
        case actionClass = "action_class"
        case order
        case token
        case checksum
        case stage
        case outcome
        case eventSequence = "event_sequence"
        case previousManifestGeneration = "previous_manifest_generation"
    }
}

package struct SpiceLiveStageAcknowledgement: Codable, Sendable, Equatable {
    package let protocolVersion: SpiceLiveStageProtocolVersion
    package let campaignID: String
    package let runID: String
    package let version: String
    package let clusterID: String
    package let evidenceRunID: SpiceLiveEvidenceRunID
    package let actionClass: SpiceInteractionActionClass
    package let order: UInt64
    package let token: String
    package let checksum: UInt32
    package let stage: SpiceLiveAttemptStage
    package let outcome: SpiceLiveAttemptOutcome
    package let eventSequence: UInt64
    package let previousManifestGeneration: UInt64
    package let durableManifestGeneration: UInt64

    init(
        event: SpiceLiveChildStageEvent,
        durableManifestGeneration: UInt64
    ) throws {
        guard durableManifestGeneration > event.previousManifestGeneration else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        protocolVersion = event.protocolVersion
        campaignID = event.campaignID
        runID = event.runID
        version = event.version
        clusterID = event.clusterID
        evidenceRunID = event.evidenceRunID
        actionClass = event.actionClass
        order = event.order
        token = event.token
        checksum = event.checksum
        stage = event.stage
        outcome = event.outcome
        eventSequence = event.eventSequence
        previousManifestGeneration = event.previousManifestGeneration
        self.durableManifestGeneration = durableManifestGeneration
    }

    private init(
        protocolVersion: SpiceLiveStageProtocolVersion,
        campaignID: String,
        runID: String,
        version: String,
        clusterID: String,
        evidenceRunID: SpiceLiveEvidenceRunID,
        actionClass: SpiceInteractionActionClass,
        order: UInt64,
        token: String,
        checksum: UInt32,
        stage: SpiceLiveAttemptStage,
        outcome: SpiceLiveAttemptOutcome,
        eventSequence: UInt64,
        previousManifestGeneration: UInt64,
        durableManifestGeneration: UInt64
    ) throws {
        let event = try SpiceLiveChildStageEvent(
            protocolVersion: protocolVersion,
            campaignID: campaignID,
            runID: runID,
            version: version,
            clusterID: clusterID,
            evidenceRunID: evidenceRunID,
            actionClass: actionClass,
            order: order,
            token: token,
            checksum: checksum,
            stage: stage,
            outcome: outcome,
            eventSequence: eventSequence,
            previousManifestGeneration: previousManifestGeneration
        )
        try self.init(
            event: event,
            durableManifestGeneration: durableManifestGeneration
        )
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            protocolVersion: container.decode(
                SpiceLiveStageProtocolVersion.self,
                forKey: .protocolVersion
            ),
            campaignID: container.decode(String.self, forKey: .campaignID),
            runID: container.decode(String.self, forKey: .runID),
            version: container.decode(String.self, forKey: .version),
            clusterID: container.decode(String.self, forKey: .clusterID),
            evidenceRunID: container.decode(
                SpiceLiveEvidenceRunID.self,
                forKey: .evidenceRunID
            ),
            actionClass: container.decode(
                SpiceInteractionActionClass.self,
                forKey: .actionClass
            ),
            order: container.decode(UInt64.self, forKey: .order),
            token: container.decode(String.self, forKey: .token),
            checksum: container.decode(UInt32.self, forKey: .checksum),
            stage: container.decode(SpiceLiveAttemptStage.self, forKey: .stage),
            outcome: container.decode(
                SpiceLiveAttemptOutcome.self,
                forKey: .outcome
            ),
            eventSequence: container.decode(UInt64.self, forKey: .eventSequence),
            previousManifestGeneration: container.decode(
                UInt64.self,
                forKey: .previousManifestGeneration
            ),
            durableManifestGeneration: container.decode(
                UInt64.self,
                forKey: .durableManifestGeneration
            )
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(protocolVersion, forKey: .protocolVersion)
        try container.encode(campaignID, forKey: .campaignID)
        try container.encode(runID, forKey: .runID)
        try container.encode(version, forKey: .version)
        try container.encode(clusterID, forKey: .clusterID)
        try container.encode(evidenceRunID, forKey: .evidenceRunID)
        try container.encode(actionClass, forKey: .actionClass)
        try container.encode(order, forKey: .order)
        try container.encode(token, forKey: .token)
        try container.encode(checksum, forKey: .checksum)
        try container.encode(stage, forKey: .stage)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(eventSequence, forKey: .eventSequence)
        try container.encode(
            previousManifestGeneration,
            forKey: .previousManifestGeneration
        )
        try container.encode(
            durableManifestGeneration,
            forKey: .durableManifestGeneration
        )
    }

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case campaignID = "campaign_id"
        case runID = "run_id"
        case version
        case clusterID = "cluster_id"
        case evidenceRunID = "evidence_run_id"
        case actionClass = "action_class"
        case order
        case token
        case checksum
        case stage
        case outcome
        case eventSequence = "event_sequence"
        case previousManifestGeneration = "previous_manifest_generation"
        case durableManifestGeneration = "durable_manifest_generation"
    }
}

package enum SpiceLiveStageProtocolCodec {
    package static let maximumFrameBytes = 4_096

    package static func encodeEvent(
        _ event: SpiceLiveChildStageEvent
    ) throws -> Data {
        try encodeFrame(event)
    }

    package static func decodeEvent(
        _ frame: Data
    ) throws -> SpiceLiveChildStageEvent {
        try decodeFrame(SpiceLiveChildStageEvent.self, from: frame)
    }

    package static func encodeAcknowledgement(
        _ acknowledgement: SpiceLiveStageAcknowledgement
    ) throws -> Data {
        try encodeFrame(acknowledgement)
    }

    package static func decodeAcknowledgement(
        _ frame: Data
    ) throws -> SpiceLiveStageAcknowledgement {
        try decodeFrame(SpiceLiveStageAcknowledgement.self, from: frame)
    }

    private static func encodeFrame<Value: Encodable>(
        _ value: Value
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var frame = try encoder.encode(value)
        frame.append(0x0a)
        guard frame.count <= maximumFrameBytes else {
            throw SpiceLiveInteractionSupportError.outputLimitExceeded
        }
        return frame
    }

    private static func decodeFrame<Value: Codable>(
        _ type: Value.Type,
        from frame: Data
    ) throws -> Value {
        guard frame.count > 1,
              frame.count <= maximumFrameBytes,
              frame.last == 0x0a,
              !frame.dropLast().contains(0x0a) else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        let decoded: Value
        do {
            decoded = try JSONDecoder().decode(Value.self, from: frame)
        } catch {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        guard try encodeFrame(decoded) == frame else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        return decoded
    }
}

private enum SpiceLiveStageProtocolValidation {
    static let actionStages: Set<SpiceLiveAttemptStage> = [
        .preArm, .arm, .postArm,
    ]

    static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    static func isCanonicalVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.first == 0x76 else { return false }
        let components = bytes.dropFirst().split(
            separator: 0x2e,
            omittingEmptySubsequences: false
        )
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && component.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
                && (component.count == 1 || component.first != 0x30)
        }
    }
}
