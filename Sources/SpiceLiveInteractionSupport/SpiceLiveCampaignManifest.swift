import CryptoKit
import Foundation
import SwiftSpice

package enum SpiceLiveCampaignThermalState: String, Codable, Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
    case unknown
}

package struct SpiceLiveCampaignManifestMetadata: Codable, Sendable, Equatable {
    package let baselineSourceCommit: String
    package let candidateSourceCommit: String
    package let toolchain: String
    package let hardware: String
    package let thermalState: SpiceLiveCampaignThermalState
    package let workload: String
    package let startedAtUTC: String

    package init(
        baselineSourceCommit: String,
        candidateSourceCommit: String,
        toolchain: String,
        hardware: String,
        thermalState: SpiceLiveCampaignThermalState,
        workload: String,
        startedAtUTC: String
    ) throws {
        guard Self.isLowerHex(baselineSourceCommit, count: 40),
              Self.isLowerHex(candidateSourceCommit, count: 40),
              Self.isBoundedText(toolchain, maximumBytes: 256),
              Self.isBoundedText(hardware, maximumBytes: 256),
              Self.isBoundedText(workload, maximumBytes: 256),
              Self.isCanonicalUTCSecond(startedAtUTC) else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        self.baselineSourceCommit = baselineSourceCommit
        self.candidateSourceCommit = candidateSourceCommit
        self.toolchain = toolchain
        self.hardware = hardware
        self.thermalState = thermalState
        self.workload = workload
        self.startedAtUTC = startedAtUTC
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            baselineSourceCommit: container.decode(
                String.self,
                forKey: .baselineSourceCommit
            ),
            candidateSourceCommit: container.decode(
                String.self,
                forKey: .candidateSourceCommit
            ),
            toolchain: container.decode(String.self, forKey: .toolchain),
            hardware: container.decode(String.self, forKey: .hardware),
            thermalState: container.decode(
                SpiceLiveCampaignThermalState.self,
                forKey: .thermalState
            ),
            workload: container.decode(String.self, forKey: .workload),
            startedAtUTC: container.decode(String.self, forKey: .startedAtUTC)
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baselineSourceCommit, forKey: .baselineSourceCommit)
        try container.encode(candidateSourceCommit, forKey: .candidateSourceCommit)
        try container.encode(toolchain, forKey: .toolchain)
        try container.encode(hardware, forKey: .hardware)
        try container.encode(thermalState, forKey: .thermalState)
        try container.encode(workload, forKey: .workload)
        try container.encode(startedAtUTC, forKey: .startedAtUTC)
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    private static func isBoundedText(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f
        }
    }

    private static func isCanonicalUTCSecond(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 20,
              bytes[4] == 0x2d,
              bytes[7] == 0x2d,
              bytes[10] == 0x54,
              bytes[13] == 0x3a,
              bytes[16] == 0x3a,
              bytes[19] == 0x5a else {
            return false
        }
        let digitOffsets = [
            0, 1, 2, 3, 5, 6, 8, 9,
            11, 12, 14, 15, 17, 18,
        ]
        guard digitOffsets.allSatisfy({ bytes[$0] >= 0x30 && bytes[$0] <= 0x39 }) else {
            return false
        }
        func number(_ range: Range<Int>) -> Int {
            range.reduce(0) { partial, index in
                partial * 10 + Int(bytes[index] - 0x30)
            }
        }
        let year = number(0..<4)
        let month = number(5..<7)
        let day = number(8..<10)
        let hour = number(11..<13)
        let minute = number(14..<16)
        let second = number(17..<19)
        guard year > 0,
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute),
              (0...59).contains(second) else {
            return false
        }
        let leapYear = year.isMultiple(of: 4)
            && (!year.isMultiple(of: 100) || year.isMultiple(of: 400))
        let days = [
            31, leapYear ? 29 : 28, 31, 30, 31, 30,
            31, 31, 30, 31, 30, 31,
        ]
        return (1...days[month - 1]).contains(day)
    }

    enum CodingKeys: String, CodingKey {
        case baselineSourceCommit = "baseline_source_commit"
        case candidateSourceCommit = "candidate_source_commit"
        case toolchain
        case hardware
        case thermalState = "thermal_state"
        case workload
        case startedAtUTC = "started_at_utc"
    }
}

package enum SpiceLiveCampaignManifestState: String, Codable, Sendable, Equatable {
    case recording
    case failed
    case interrupted
    case finalized
}

package struct SpiceLiveCampaignManifestRun: Codable, Sendable, Equatable {
    package let logicalRunID: String
    package let version: String
    package let clusterID: String
    package let sequence: UInt64
    package var evidenceRunID: SpiceLiveEvidenceRunID?

    package init(run: SpiceLiveCampaignRun) {
        logicalRunID = run.runID
        version = run.version
        clusterID = run.clusterID
        sequence = run.sequence
        evidenceRunID = nil
    }

    enum CodingKeys: String, CodingKey {
        case logicalRunID = "logical_run_id"
        case version
        case clusterID = "cluster_id"
        case sequence
        case evidenceRunID = "evidence_run_id"
    }
}

package struct SpiceLiveCampaignManifest: Codable, Sendable, Equatable {
    private enum ExecutionIdentity: Sendable, Equatable {
        case legacySchema1
        case current(
            contract: SpiceLiveCampaignExecutionContract,
            digest: String
        )
    }

    package static let currentSchemaVersion: UInt64 = 2
    static let legacySchemaVersion: UInt64 = 1

    package let schemaVersion: UInt64
    package var generation: UInt64
    package var state: SpiceLiveCampaignManifestState
    package let campaignID: String
    package let planDigest: String
    package let baselineVersion: String
    package let candidateVersion: String
    package let metadata: SpiceLiveCampaignManifestMetadata
    private let executionIdentity: ExecutionIdentity
    package var runs: [SpiceLiveCampaignManifestRun]
    package var stages: [SpiceLiveAttemptLedgerEntry]

    package var executionContract: SpiceLiveCampaignExecutionContract? {
        guard case let .current(contract, _) = executionIdentity else { return nil }
        return contract
    }

    package var executionContractDigest: String? {
        guard case let .current(_, digest) = executionIdentity else { return nil }
        return digest
    }

    package init(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata,
        executionContract: SpiceLiveCampaignExecutionContract
    ) {
        schemaVersion = Self.currentSchemaVersion
        generation = 0
        state = .recording
        campaignID = plan.campaignID
        planDigest = Self.digest(plan: plan)
        baselineVersion = plan.baselineVersion
        candidateVersion = plan.candidateVersion
        self.metadata = metadata
        executionIdentity = .current(
            contract: executionContract,
            digest: executionContract.digest
        )
        runs = plan.runs.map(SpiceLiveCampaignManifestRun.init)
        stages = []
        stages.reserveCapacity(260)
    }

    package static func expectedPlanDigest(_ plan: SpiceLiveCampaignPlan) -> String {
        digest(plan: plan)
    }

    package func hasSameImmutableIdentity(
        as other: SpiceLiveCampaignManifest
    ) -> Bool {
        schemaVersion == other.schemaVersion
            && campaignID == other.campaignID
            && planDigest == other.planDigest
            && baselineVersion == other.baselineVersion
            && candidateVersion == other.candidateVersion
            && metadata == other.metadata
            && executionContract == other.executionContract
            && executionContractDigest == other.executionContractDigest
            && runs.map(Self.runIdentity) == other.runs.map(Self.runIdentity)
    }

    var isLegacySchemaOne: Bool {
        schemaVersion == Self.legacySchemaVersion
            && executionIdentity == .legacySchema1
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt64.self, forKey: .schemaVersion)
        let executionIdentity: ExecutionIdentity
        switch schemaVersion {
        case Self.legacySchemaVersion:
            guard !container.contains(.executionContract),
                  !container.contains(.executionContractDigest) else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
            executionIdentity = .legacySchema1
        case Self.currentSchemaVersion:
            let contract = try container.decode(
                SpiceLiveCampaignExecutionContract.self,
                forKey: .executionContract
            )
            let contractDigest = try container.decode(
                String.self,
                forKey: .executionContractDigest
            )
            guard contractDigest == contract.digest else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
            executionIdentity = .current(
                contract: contract,
                digest: contractDigest
            )
        default:
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        self.schemaVersion = schemaVersion
        generation = try container.decode(UInt64.self, forKey: .generation)
        state = try container.decode(SpiceLiveCampaignManifestState.self, forKey: .state)
        campaignID = try container.decode(String.self, forKey: .campaignID)
        planDigest = try container.decode(String.self, forKey: .planDigest)
        baselineVersion = try container.decode(String.self, forKey: .baselineVersion)
        candidateVersion = try container.decode(String.self, forKey: .candidateVersion)
        metadata = try container.decode(
            SpiceLiveCampaignManifestMetadata.self,
            forKey: .metadata
        )
        self.executionIdentity = executionIdentity
        runs = try container.decode([SpiceLiveCampaignManifestRun].self, forKey: .runs)
        stages = try container.decode([SpiceLiveAttemptLedgerEntry].self, forKey: .stages)
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generation, forKey: .generation)
        try container.encode(state, forKey: .state)
        try container.encode(campaignID, forKey: .campaignID)
        try container.encode(planDigest, forKey: .planDigest)
        try container.encode(baselineVersion, forKey: .baselineVersion)
        try container.encode(candidateVersion, forKey: .candidateVersion)
        try container.encode(metadata, forKey: .metadata)
        switch (schemaVersion, executionIdentity) {
        case (Self.legacySchemaVersion, .legacySchema1):
            break
        case let (Self.currentSchemaVersion, .current(executionContract, digest)):
            guard digest == executionContract.digest else {
                throw SpiceLiveCampaignManifestError.invalidManifest
            }
            try container.encode(executionContract, forKey: .executionContract)
            try container.encode(digest, forKey: .executionContractDigest)
        default:
            throw SpiceLiveCampaignManifestError.invalidManifest
        }
        try container.encode(runs, forKey: .runs)
        try container.encode(stages, forKey: .stages)
    }

    private static func runIdentity(
        _ run: SpiceLiveCampaignManifestRun
    ) -> String {
        "\(run.logicalRunID):\(run.version):\(run.clusterID):\(run.sequence)"
    }

    private static func digest(plan: SpiceLiveCampaignPlan) -> String {
        var material = Data("swiftspice-live-campaign-plan-v1".utf8)
        func append(_ value: String) {
            material.append(Data("\n\(value.utf8.count):".utf8))
            material.append(Data(value.utf8))
        }
        append(plan.campaignID)
        append(plan.baselineVersion)
        append(plan.candidateVersion)
        for clusterID in plan.clusterIDs { append(clusterID) }
        for run in plan.runs {
            append(run.runID)
            append(run.version)
            append(run.clusterID)
            append(String(run.sequence))
            append(run.freshBootRequired ? "1" : "0")
            append(String(run.automaticRetryLimit))
            for step in run.steps {
                append(String(step.order))
                append(step.actionClass.rawValue)
                append(step.token)
                append(step.pairID)
                append(String(format: "%08x", step.checksum))
            }
        }
        return SHA256.hash(data: material).map {
            String(format: "%02x", $0)
        }.joined()
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generation
        case state
        case campaignID = "campaign_id"
        case planDigest = "plan_digest"
        case baselineVersion = "baseline_version"
        case candidateVersion = "candidate_version"
        case metadata
        case executionContract = "execution_contract"
        case executionContractDigest = "execution_contract_digest"
        case runs
        case stages
    }
}
