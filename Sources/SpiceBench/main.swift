import Darwin
import Foundation
import SpiceBenchSupport

@main
struct SpiceBenchCommand {
    static func main() async {
        do {
            try SpiceBenchBuildConfiguration.requireRelease()
            let configuration = try Configuration(arguments: Array(CommandLine.arguments.dropFirst()))
            if configuration.requestsLiveArtifact {
                _ = try SpiceBenchLivePrerequisites.resolve(
                    environment: ProcessInfo.processInfo.environment
                )
                throw SpiceBenchError.liveRequiresExternalRunner
            }
            let metadata = SpiceBenchMetadata(
                commit: try requiredCommandOutput(
                    "/usr/bin/git",
                    ["rev-parse", "HEAD"],
                    field: "commit"
                ),
                toolchain: try requiredCommandOutput(
                    "/usr/bin/xcrun",
                    ["swift", "--version"],
                    field: "toolchain"
                ),
                hardware: try hardwareDescription(),
                thermalState: try thermalState(),
                workload: "aip-00.micro.v1",
                date: Date().formatted(.iso8601),
                source: "local",
                mode: "release"
            )
            let report = try await SpiceBenchRunner().run(
                metadata: metadata,
                catalog: SpiceBenchCatalog.microbenchmarks(
                    warmUpIterations: configuration.warmUpIterations,
                    measuredIterations: configuration.measuredIterations
                )
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let encoded = try encoder.encode(report)
            FileHandle.standardOutput.write(encoded)
            FileHandle.standardOutput.write(Data([0x0a]))
        } catch {
            let message = "spice-bench: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func thermalState() throws(SpiceBenchError) -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: throw .invalidMetadata(field: "thermalState")
        }
    }

    private static func hardwareDescription() throws(SpiceBenchError) -> String {
        let processInfo = ProcessInfo.processInfo
        guard let architecture = commandOutput("/usr/bin/uname", ["-m"]),
              processInfo.processorCount > 0,
              processInfo.activeProcessorCount > 0,
              processInfo.physicalMemory > 0,
              !processInfo.operatingSystemVersionString.isEmpty
        else {
            throw .invalidMetadata(field: "hardware")
        }
        let fallback = [
            "arch=\(architecture)",
            "logical_cpus=\(processInfo.processorCount)",
            "active_cpus=\(processInfo.activeProcessorCount)",
            "physical_memory=\(processInfo.physicalMemory)",
            "os=\(processInfo.operatingSystemVersionString)",
        ].joined(separator: ";")
        guard let model = commandOutput("/usr/sbin/sysctl", ["-n", "hw.model"]) else {
            return fallback
        }
        return "model=\(model);\(fallback)"
    }

    private static func requiredCommandOutput(
        _ executable: String,
        _ arguments: [String],
        field: String
    ) throws(SpiceBenchError) -> String {
        guard let output = commandOutput(executable, arguments) else {
            throw .invalidMetadata(field: field)
        }
        return output
    }

    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            let value = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        } catch {
            return nil
        }
    }
}

private struct Configuration {
    let warmUpIterations: Int
    let measuredIterations: Int
    let requestsLiveArtifact: Bool

    init(arguments: [String]) throws {
        var warmUpIterations = 3
        var measuredIterations = 10
        var requestsLiveArtifact = false
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--warmup":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
                    throw SpiceBenchCLIError.invalidArgument("--warmup")
                }
                warmUpIterations = value
            case "--iterations":
                index += 1
                guard index < arguments.count, let value = Int(arguments[index]), value > 0 else {
                    throw SpiceBenchCLIError.invalidArgument("--iterations")
                }
                measuredIterations = value
            case "--live":
                requestsLiveArtifact = true
            default:
                throw SpiceBenchCLIError.invalidArgument(arguments[index])
            }
            index += 1
        }
        self.warmUpIterations = warmUpIterations
        self.measuredIterations = measuredIterations
        self.requestsLiveArtifact = requestsLiveArtifact
    }
}

private enum SpiceBenchCLIError: Error, CustomStringConvertible {
    case invalidArgument(String)

    var description: String {
        switch self {
        case let .invalidArgument(argument):
            "invalid argument \(argument); usage: spice-bench [--warmup N] [--iterations N] [--live]"
        }
    }
}
