import Foundation
import PackagePlugin

@main
struct CompileMetalShaders: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) async throws -> [Command] {
        guard target is SwiftSourceModuleTarget else {
            throw PluginError.unsupportedTarget(target.name)
        }

        let shaderSource = target.directoryURL
            .appending(path: "Shaders/SpiceVideoCompositor.metal")
        guard FileManager.default.fileExists(atPath: shaderSource.path()) else {
            throw PluginError.missingShader(shaderSource.path())
        }

        let compilerScript = context.package.directoryURL
            .appending(path: "Plugins/CompileMetalShaders/compile-metal.sh")
        let intermediateAIR = context.pluginWorkDirectoryURL
            .appending(path: "SpiceVideoCompositor.air")
        let outputLibrary = context.pluginWorkDirectoryURL
            .appending(path: "SpiceVideoCompositor.metallib")

        return [
            .buildCommand(
                displayName: "Compile Spice Metal video compositor",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    compilerScript.path(),
                    shaderSource.path(),
                    intermediateAIR.path(),
                    outputLibrary.path(),
                ],
                inputFiles: [shaderSource, compilerScript],
                outputFiles: [outputLibrary]
            ),
        ]
    }
}

private enum PluginError: Error, CustomStringConvertible {
    case missingShader(String)
    case unsupportedTarget(String)

    var description: String {
        switch self {
        case let .missingShader(path):
            "Metal shader source is missing at \(path)"
        case let .unsupportedTarget(name):
            "CompileMetalShaders can only be attached to a Swift target; got \(name)"
        }
    }
}
