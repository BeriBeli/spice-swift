import CryptoKit
import Foundation
import SwiftSpice

package enum SpiceLiveStageProtocolVersion: String, Codable, Sendable, Equatable {
    case v1
}

package struct SpiceLiveCampaignExecutionContract: Sendable, Equatable, Codable {
    package let baselineVersion: String
    package let candidateVersion: String
    package let baselineSourceCommit: String
    package let candidateSourceCommit: String
    package let baselineReleaseBinarySHA256: String
    package let candidateReleaseBinarySHA256: String
    package let runnerSourceCommit: String
    package let runnerReleaseBinarySHA256: String
    package let remoteImageReference: String
    package let remoteImageDigest: String
    package let guestBuildManifestSHA256: String
    package let fixtureSourcesSHA256: String
    package let controlSourceSHA256: String
    package let pointerMode: SpicePointerMode
    package let stageProtocolVersion: SpiceLiveStageProtocolVersion

    package var digest: String {
        var material = Data("swiftspice-live-execution-contract-v1".utf8)
        func append(_ label: String, _ value: String) {
            material.append(Data("\n\(label.utf8.count):\(label):\(value.utf8.count):".utf8))
            material.append(Data(value.utf8))
        }
        append("baseline_version", baselineVersion)
        append("candidate_version", candidateVersion)
        append("baseline_source_commit", baselineSourceCommit)
        append("candidate_source_commit", candidateSourceCommit)
        append("baseline_release_binary_sha256", baselineReleaseBinarySHA256)
        append("candidate_release_binary_sha256", candidateReleaseBinarySHA256)
        append("runner_source_commit", runnerSourceCommit)
        append("runner_release_binary_sha256", runnerReleaseBinarySHA256)
        append("remote_image_reference", remoteImageReference)
        append("remote_image_digest", remoteImageDigest)
        append("guest_build_manifest_sha256", guestBuildManifestSHA256)
        append("fixture_sources_sha256", fixtureSourcesSHA256)
        append("control_source_sha256", controlSourceSHA256)
        append("pointer_mode", pointerModeValue)
        append("stage_protocol_version", stageProtocolVersion.rawValue)
        return SHA256.hash(data: material).map {
            String(format: "%02x", $0)
        }.joined()
    }

    package init(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata,
        baselineVersion: String,
        candidateVersion: String,
        baselineSourceCommit: String,
        candidateSourceCommit: String,
        baselineReleaseBinarySHA256: String,
        candidateReleaseBinarySHA256: String,
        runnerSourceCommit: String,
        runnerReleaseBinarySHA256: String,
        remoteImageReference: String,
        remoteImageDigest: String,
        guestBuildManifestSHA256: String,
        fixtureSourcesSHA256: String,
        controlSourceSHA256: String,
        pointerMode: SpicePointerMode,
        stageProtocolVersion: SpiceLiveStageProtocolVersion
    ) throws {
        try self.init(
            baselineVersion: baselineVersion,
            candidateVersion: candidateVersion,
            baselineSourceCommit: baselineSourceCommit,
            candidateSourceCommit: candidateSourceCommit,
            baselineReleaseBinarySHA256: baselineReleaseBinarySHA256,
            candidateReleaseBinarySHA256: candidateReleaseBinarySHA256,
            runnerSourceCommit: runnerSourceCommit,
            runnerReleaseBinarySHA256: runnerReleaseBinarySHA256,
            remoteImageReference: remoteImageReference,
            remoteImageDigest: remoteImageDigest,
            guestBuildManifestSHA256: guestBuildManifestSHA256,
            fixtureSourcesSHA256: fixtureSourcesSHA256,
            controlSourceSHA256: controlSourceSHA256,
            pointerMode: pointerMode,
            stageProtocolVersion: stageProtocolVersion
        )
        try validate(plan: plan, metadata: metadata)
    }

    private init(
        baselineVersion: String,
        candidateVersion: String,
        baselineSourceCommit: String,
        candidateSourceCommit: String,
        baselineReleaseBinarySHA256: String,
        candidateReleaseBinarySHA256: String,
        runnerSourceCommit: String,
        runnerReleaseBinarySHA256: String,
        remoteImageReference: String,
        remoteImageDigest: String,
        guestBuildManifestSHA256: String,
        fixtureSourcesSHA256: String,
        controlSourceSHA256: String,
        pointerMode: SpicePointerMode,
        stageProtocolVersion: SpiceLiveStageProtocolVersion
    ) throws {
        guard Self.isCanonicalVersion(baselineVersion),
              Self.isCanonicalVersion(candidateVersion),
              baselineVersion != candidateVersion,
              Self.isLowerHex(baselineSourceCommit, count: 40),
              Self.isLowerHex(candidateSourceCommit, count: 40),
              Self.isLowerHex(baselineReleaseBinarySHA256, count: 64),
              Self.isLowerHex(candidateReleaseBinarySHA256, count: 64),
              Self.isLowerHex(runnerSourceCommit, count: 40),
              Self.isLowerHex(runnerReleaseBinarySHA256, count: 64),
              Self.isCanonicalRemoteReference(remoteImageReference),
              Self.isLowerHex(remoteImageDigest, count: 64),
              Self.isLowerHex(guestBuildManifestSHA256, count: 64),
              Self.isLowerHex(fixtureSourcesSHA256, count: 64),
              Self.isLowerHex(controlSourceSHA256, count: 64) else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        self.baselineVersion = baselineVersion
        self.candidateVersion = candidateVersion
        self.baselineSourceCommit = baselineSourceCommit
        self.candidateSourceCommit = candidateSourceCommit
        self.baselineReleaseBinarySHA256 = baselineReleaseBinarySHA256
        self.candidateReleaseBinarySHA256 = candidateReleaseBinarySHA256
        self.runnerSourceCommit = runnerSourceCommit
        self.runnerReleaseBinarySHA256 = runnerReleaseBinarySHA256
        self.remoteImageReference = remoteImageReference
        self.remoteImageDigest = remoteImageDigest
        self.guestBuildManifestSHA256 = guestBuildManifestSHA256
        self.fixtureSourcesSHA256 = fixtureSourcesSHA256
        self.controlSourceSHA256 = controlSourceSHA256
        self.pointerMode = pointerMode
        self.stageProtocolVersion = stageProtocolVersion
    }

    package func validate(
        plan: SpiceLiveCampaignPlan,
        metadata: SpiceLiveCampaignManifestMetadata
    ) throws {
        guard baselineVersion == plan.baselineVersion,
              candidateVersion == plan.candidateVersion else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        try validate(
            baselineVersion: plan.baselineVersion,
            candidateVersion: plan.candidateVersion,
            metadata: metadata
        )
    }

    package func validate(
        baselineVersion expectedBaselineVersion: String,
        candidateVersion expectedCandidateVersion: String,
        metadata: SpiceLiveCampaignManifestMetadata
    ) throws {
        guard baselineVersion == expectedBaselineVersion,
              candidateVersion == expectedCandidateVersion,
              baselineSourceCommit == metadata.baselineSourceCommit,
              candidateSourceCommit == metadata.candidateSourceCommit else {
            throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pointerModeValue = try container.decode(String.self, forKey: .pointerMode)
        let pointerMode: SpicePointerMode
        switch pointerModeValue {
        case "absolute": pointerMode = .absolute
        case "relative": pointerMode = .relative
        default: throw SpiceLiveInteractionSupportError.invalidTraceProtocol
        }
        try self.init(
            baselineVersion: container.decode(String.self, forKey: .baselineVersion),
            candidateVersion: container.decode(String.self, forKey: .candidateVersion),
            baselineSourceCommit: container.decode(String.self, forKey: .baselineSourceCommit),
            candidateSourceCommit: container.decode(String.self, forKey: .candidateSourceCommit),
            baselineReleaseBinarySHA256: container.decode(String.self, forKey: .baselineReleaseBinarySHA256),
            candidateReleaseBinarySHA256: container.decode(String.self, forKey: .candidateReleaseBinarySHA256),
            runnerSourceCommit: container.decode(String.self, forKey: .runnerSourceCommit),
            runnerReleaseBinarySHA256: container.decode(String.self, forKey: .runnerReleaseBinarySHA256),
            remoteImageReference: container.decode(String.self, forKey: .remoteImageReference),
            remoteImageDigest: container.decode(String.self, forKey: .remoteImageDigest),
            guestBuildManifestSHA256: container.decode(String.self, forKey: .guestBuildManifestSHA256),
            fixtureSourcesSHA256: container.decode(String.self, forKey: .fixtureSourcesSHA256),
            controlSourceSHA256: container.decode(String.self, forKey: .controlSourceSHA256),
            pointerMode: pointerMode,
            stageProtocolVersion: container.decode(SpiceLiveStageProtocolVersion.self, forKey: .stageProtocolVersion)
        )
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baselineVersion, forKey: .baselineVersion)
        try container.encode(candidateVersion, forKey: .candidateVersion)
        try container.encode(baselineSourceCommit, forKey: .baselineSourceCommit)
        try container.encode(candidateSourceCommit, forKey: .candidateSourceCommit)
        try container.encode(baselineReleaseBinarySHA256, forKey: .baselineReleaseBinarySHA256)
        try container.encode(candidateReleaseBinarySHA256, forKey: .candidateReleaseBinarySHA256)
        try container.encode(runnerSourceCommit, forKey: .runnerSourceCommit)
        try container.encode(runnerReleaseBinarySHA256, forKey: .runnerReleaseBinarySHA256)
        try container.encode(remoteImageReference, forKey: .remoteImageReference)
        try container.encode(remoteImageDigest, forKey: .remoteImageDigest)
        try container.encode(guestBuildManifestSHA256, forKey: .guestBuildManifestSHA256)
        try container.encode(fixtureSourcesSHA256, forKey: .fixtureSourcesSHA256)
        try container.encode(controlSourceSHA256, forKey: .controlSourceSHA256)
        try container.encode(pointerModeValue, forKey: .pointerMode)
        try container.encode(stageProtocolVersion, forKey: .stageProtocolVersion)
    }

    private var pointerModeValue: String {
        switch pointerMode {
        case .absolute: "absolute"
        case .relative: "relative"
        }
    }

    private static func isLowerHex(_ value: String, count: Int) -> Bool {
        value.utf8.count == count && value.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66)
        }
    }

    private static func isCanonicalVersion(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.first == 0x76 else { return false }
        let components = bytes.dropFirst().split(separator: 0x2e, omittingEmptySubsequences: false)
        guard components.count == 3 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty
                && component.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
                && (component.count == 1 || component.first != 0x30)
        }
    }

    private static func isCanonicalRemoteReference(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 512 else {
            return false
        }
        let pattern = #"\A[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?\z"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: fullRange)?.range == fullRange
    }

    private enum CodingKeys: String, CodingKey {
        case baselineVersion = "baseline_version"
        case candidateVersion = "candidate_version"
        case baselineSourceCommit = "baseline_source_commit"
        case candidateSourceCommit = "candidate_source_commit"
        case baselineReleaseBinarySHA256 = "baseline_release_binary_sha256"
        case candidateReleaseBinarySHA256 = "candidate_release_binary_sha256"
        case runnerSourceCommit = "runner_source_commit"
        case runnerReleaseBinarySHA256 = "runner_release_binary_sha256"
        case remoteImageReference = "remote_image_reference"
        case remoteImageDigest = "remote_image_digest"
        case guestBuildManifestSHA256 = "guest_build_manifest_sha256"
        case fixtureSourcesSHA256 = "fixture_sources_sha256"
        case controlSourceSHA256 = "control_source_sha256"
        case pointerMode = "pointer_mode"
        case stageProtocolVersion = "stage_protocol_version"
    }
}
