import Foundation
import PackagePlugin

@main
struct GenerateSpiceProtocol: CommandPlugin {
    func performCommand(
        context: PluginContext,
        arguments: [String]
    ) async throws {
        let tool = try context.tool(named: "SpiceProtocolGenerator")
        let packageDirectory = context.package.directoryURL
        let schema = packageDirectory
            .appending(path: "ProtocolSchema/spice-0.14.5.json")
        let output = packageDirectory
            .appending(path: "Sources/SpiceProtocol/GeneratedMessages.swift")

        let process = Process()
        process.executableURL = tool.url
        process.arguments = [
            "--schema", schema.path(),
            "--output", output.path(),
        ] + arguments

        try process.run()
        process.waitUntilExit()

        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw PluginError.generatorFailed(process.terminationStatus)
        }
    }
}

private enum PluginError: Error, CustomStringConvertible {
    case generatorFailed(Int32)

    var description: String {
        switch self {
        case let .generatorFailed(status):
            "SpiceProtocolGenerator failed with exit status \(status)"
        }
    }
}
