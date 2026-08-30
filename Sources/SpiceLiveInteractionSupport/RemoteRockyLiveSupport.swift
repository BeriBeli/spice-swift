import Foundation

package struct SpiceRemoteCommand: Sendable, Equatable {
    package let executable: String
    package let arguments: [String]

    package init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

package struct SpiceRemoteFixturePaths: Sendable, Equatable {
    package let base: String
    package let remoteDirectory: String
    package let startScript: String
    package let stopScript: String
    package let healthScript: String
    package let controlScript: String
    package let logsDirectory: String

    package init(base: String) throws {
        guard SpiceRemoteLiveConfiguration.isCanonicalAbsolutePath(base) else {
            throw SpiceLiveInteractionSupportError.invalidConfiguration
        }
        let remoteDirectory = "\(base)/remote"
        let logsDirectory = "\(base)/logs"
        self.base = base
        self.remoteDirectory = remoteDirectory
        startScript = "\(remoteDirectory)/start.sh"
        stopScript = "\(remoteDirectory)/stop.sh"
        healthScript = "\(remoteDirectory)/status.sh"
        controlScript = "\(remoteDirectory)/control.sh"
        self.logsDirectory = logsDirectory
    }
}

package enum SpiceRemoteFixtureOperation: String, Sendable, Equatable {
    case stop
    case start
    case health

    package func command(
        configuration: SpiceRemoteLiveConfiguration
    ) -> SpiceRemoteCommand {
        let script = switch self {
        case .stop: configuration.paths.stopScript
        case .start: configuration.paths.startScript
        case .health: configuration.paths.healthScript
        }
        return SpiceRemoteCommand(
            executable: "/usr/bin/ssh",
            arguments: configuration.sshArguments + [script]
        )
    }
}

package struct SpiceRemoteLiveConfiguration: Sendable, Equatable {
    package let sshHost: String
    package let base: String
    package let container: String
    package let image: String
    package let spicePort: UInt16
    package let controlPort: UInt16
    package let endpointHost: String
    package let endpointPort: UInt16
    package let campaignID: String
    package let runID: String
    package let version: String
    package let clusterID: String
    package let paths: SpiceRemoteFixturePaths

    package init(environment: [String: String]) throws {
        guard environment["SWIFTSPICE_LIVE_INTERACTION"] == "1" else {
            throw SpiceLiveInteractionSupportError.notExplicitlyEnabled
        }
        let keys = [
            "SWIFTSPICE_ROCKY_SSH_HOST",
            "SWIFTSPICE_PERF_BASE",
            "SWIFTSPICE_PERF_CONTAINER",
            "SWIFTSPICE_PERF_IMAGE",
            "SWIFTSPICE_PERF_SPICE_PORT",
            "SWIFTSPICE_PERF_CONTROL_PORT",
            "SWIFTSPICE_LIVE_ENDPOINT_HOST",
            "SWIFTSPICE_LIVE_ENDPOINT_PORT",
            "SWIFTSPICE_LIVE_CAMPAIGN_ID",
            "SWIFTSPICE_LIVE_RUN_ID",
            "SWIFTSPICE_LIVE_VERSION",
            "SWIFTSPICE_LIVE_CLUSTER_ID",
        ]
        guard keys.allSatisfy({ !(environment[$0] ?? "").isEmpty }) else {
            throw SpiceLiveInteractionSupportError.incompleteConfiguration
        }

        let sshHost = environment["SWIFTSPICE_ROCKY_SSH_HOST"]!
        let base = environment["SWIFTSPICE_PERF_BASE"]!
        let container = environment["SWIFTSPICE_PERF_CONTAINER"]!
        let image = environment["SWIFTSPICE_PERF_IMAGE"]!
        let endpointHost = environment["SWIFTSPICE_LIVE_ENDPOINT_HOST"]!
        let campaignID = environment["SWIFTSPICE_LIVE_CAMPAIGN_ID"]!
        let runID = environment["SWIFTSPICE_LIVE_RUN_ID"]!
        let version = environment["SWIFTSPICE_LIVE_VERSION"]!
        let clusterID = environment["SWIFTSPICE_LIVE_CLUSTER_ID"]!
        guard Self.isSafeSSHHost(sshHost),
              Self.isCanonicalAbsolutePath(base),
              Self.isSafeContainer(container),
              Self.isSafeImage(image),
              Self.isSafeEndpointHost(endpointHost),
              SpiceLiveValidation.isCanonicalLowerHex(campaignID, count: 16),
              SpiceLiveValidation.isCanonicalLowerHex(runID, count: 16),
              SpiceLiveValidation.isCanonicalVersion(version),
              SpiceLiveValidation.isCanonicalLowerHex(clusterID, count: 16),
              let spicePort = UInt16(environment["SWIFTSPICE_PERF_SPICE_PORT"]!),
              let controlPort = UInt16(environment["SWIFTSPICE_PERF_CONTROL_PORT"]!),
              let endpointPort = UInt16(environment["SWIFTSPICE_LIVE_ENDPOINT_PORT"]!),
              spicePort >= 1_024,
              controlPort >= 1_024,
              endpointPort >= 1_024,
              spicePort != controlPort,
              endpointPort != spicePort,
              endpointPort != 5_935,
              endpointPort != 15_935,
              container != "swiftspice-perf-ab-qemu",
              !(spicePort == 5_935 && controlPort == 5_936),
              !base.hasSuffix("/swiftspice-remote-closure/perf-ab") else {
            throw SpiceLiveInteractionSupportError.invalidConfiguration
        }

        self.sshHost = sshHost
        self.base = base
        self.container = container
        self.image = image
        self.spicePort = spicePort
        self.controlPort = controlPort
        self.endpointHost = endpointHost
        self.endpointPort = endpointPort
        self.campaignID = campaignID
        self.runID = runID
        self.version = version
        self.clusterID = clusterID
        paths = try SpiceRemoteFixturePaths(base: base)
    }

    package func freshBootCommands(
        for run: SpiceLiveCampaignRun
    ) throws -> [SpiceRemoteCommand] {
        guard run.freshBootRequired,
              run.automaticRetryLimit == 0,
              run.campaignID == campaignID,
              run.runID == runID,
              run.version == version,
              run.clusterID == clusterID else {
            throw SpiceLiveInteractionSupportError.invalidConfiguration
        }
        return [
            SpiceRemoteFixtureOperation.stop.command(configuration: self),
            SpiceRemoteFixtureOperation.start.command(configuration: self),
            SpiceRemoteFixtureOperation.health.command(configuration: self),
        ]
    }

    fileprivate var sshArguments: [String] {
        [
            "-o",
            "BatchMode=yes",
            sshHost,
            "/usr/bin/env",
            "SWIFTSPICE_PERF_BASE=\(base)",
            "SWIFTSPICE_PERF_CONTAINER=\(container)",
            "SWIFTSPICE_PERF_IMAGE=\(image)",
            "SWIFTSPICE_PERF_SPICE_PORT=\(spicePort)",
            "SWIFTSPICE_PERF_CONTROL_PORT=\(controlPort)",
            "SWIFTSPICE_LIVE_CAMPAIGN_ID=\(campaignID)",
            "SWIFTSPICE_LIVE_RUN_ID=\(runID)",
            "SWIFTSPICE_LIVE_VERSION=\(version)",
            "SWIFTSPICE_LIVE_CLUSTER_ID=\(clusterID)",
        ]
    }

    fileprivate static func isCanonicalAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value != "/"
            && !value.hasSuffix("/")
            && !value.contains("//")
            && value.utf8.allSatisfy(isPathByte)
            && !value.split(separator: "/").contains(".")
            && !value.split(separator: "/").contains("..")
    }

    private static func isSafeSSHHost(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value.first != "-"
            && value.utf8.allSatisfy {
                isASCIIAlphaNumeric($0) || [46, 58, 64, 95, 45].contains($0)
            }
    }

    private static func isSafeEndpointHost(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && value.utf8.allSatisfy {
                isASCIIAlphaNumeric($0) || [46, 58, 95, 45].contains($0)
            }
    }

    private static func isSafeContainer(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count),
              let first = bytes.first,
              isASCIILowerOrDigit(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            isASCIILowerOrDigit($0) || [46, 95, 45].contains($0)
        }
    }

    private static func isSafeImage(_ value: String) -> Bool {
        guard (1...255).contains(value.utf8.count) else { return false }
        let tagged = value.split(
            separator: ":",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard (1...2).contains(tagged.count),
              tagged[0].split(
                  separator: "/",
                  omittingEmptySubsequences: false
              ).allSatisfy({ component in
                  guard let first = component.utf8.first,
                        isASCIILowerOrDigit(first) else { return false }
                  return component.utf8.dropFirst().allSatisfy {
                      isASCIILowerOrDigit($0) || [46, 95, 45].contains($0)
                  }
              }) else { return false }
        if tagged.count == 2 {
            let tag = tagged[1].utf8
            guard (1...128).contains(tag.count),
                  let first = tag.first,
                  isASCIIAlphaNumeric(first) || first == 95,
                  tag.dropFirst().allSatisfy({
                      isASCIIAlphaNumeric($0) || [46, 95, 45].contains($0)
                  }) else { return false }
        }
        return true
    }

    private static func isPathByte(_ byte: UInt8) -> Bool {
        isASCIIAlphaNumeric(byte) || [47, 46, 95, 45].contains(byte)
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57)
            || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122)
    }

    private static func isASCIILowerOrDigit(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
    }
}
