import Foundation
import SpiceBenchSupport
import Testing

@Suite("spice-bench build script contract")
struct SpiceBenchBuildScriptTests {
    @Test("revision macro reaches the C compiler without shell escape bytes")
    func revisionMacroArgumentContainsQuotesWithoutBackslashes() throws {
        let fixture = try RunMicroFixture.make()
        defer { fixture.remove() }

        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: [fixture.scriptURL.path],
            environment: [
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "SWIFT_EXECUTABLE": fixture.swiftURL.path,
                "TMPDIR": fixture.temporaryDirectory.path,
                "HOME": fixture.homeURL.path,
                "CFFIXED_USER_HOME": fixture.homeURL.path,
            ],
            currentDirectory: fixture.repositoryURL
        )
        try #require(result.status == 0, Comment(rawValue: result.standardError))

        let arguments = try String(contentsOf: fixture.argumentLogURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let revision = try fixture.gitOutput(["rev-parse", "--verify", "HEAD"])
        let define = try #require(
            arguments.first { $0.hasPrefix("-DSPICE_BENCH_BUILD_REVISION=") }
        )
        #expect(define == "-DSPICE_BENCH_BUILD_REVISION=\"\(revision)\"")
        #expect(!define.contains("\\"))

        let metadataDefine = try #require(
            arguments.first { $0.hasPrefix("-DSPICE_BENCH_BUILD_METADATA_HEX=") }
        )
        #expect(metadataDefine.hasPrefix("-DSPICE_BENCH_BUILD_METADATA_HEX=\""))
        #expect(metadataDefine.hasSuffix("\""))
        #expect(!metadataDefine.contains("\\"))
        let prefix = "-DSPICE_BENCH_BUILD_METADATA_HEX=\""
        let metadataHex = String(metadataDefine.dropFirst(prefix.count).dropLast())
        let buildInfo = try SpiceBenchExecutableBuildInfo.decode(
            embeddedRevision: revision,
            metadataHex: metadataHex
        )
        let canonicalSwiftPath = try fixture.canonicalSwiftPath()
        #expect(try buildInfo.revision.validate(runtimeRevision: revision) == revision)
        #expect(buildInfo.metadata.swiftExecutable == canonicalSwiftPath)
        #expect(buildInfo.metadata.swiftVersion == "Apple Swift version 6.4 (fixture toolchain)")
        #expect(buildInfo.metadata.swiftTargetInfo == #"{"target":{"triple":"arm64-apple-macosx14.0"}}"#)
        #expect(buildInfo.metadata.configuration == "release")
    }

    @Test("embedded toolchain metadata is immune to runtime environment drift")
    func embeddedToolchainMetadataDoesNotConsultRuntimeEnvironment() throws {
        let revision = "4e14b4cdd25855a4dd521d3e255b08dee795e0cb"
        let fields = [
            "/build/toolchain/usr/bin/swift",
            "Apple Swift version 6.4 (build toolchain)",
            #"{"target":{"triple":"arm64-apple-macosx14.0"}}"#,
            "/Applications/BuildXcode.app/Contents/Developer",
            "build-toolchain",
            "/BuildSDKRoot",
            "/Applications/BuildXcode.app/SDKs/MacOSX.sdk",
            "26.0",
            "release",
        ]
        let metadataHex = nulTerminatedHex(fields)
        let expected = SpiceBenchBuildMetadata(
            swiftExecutable: fields[0],
            swiftVersion: fields[1],
            swiftTargetInfo: fields[2],
            developerDirectory: fields[3],
            toolchains: fields[4],
            sdkRoot: fields[5],
            sdkPath: fields[6],
            sdkVersion: fields[7],
            configuration: fields[8]
        )
        let driftedRuntimeEnvironments = [
            [
                "DEVELOPER_DIR": "/Applications/RuntimeXcode.app/Contents/Developer",
                "TOOLCHAINS": "runtime-toolchain",
                "SDKROOT": "/RuntimeSDKRoot",
                "SWIFT_EXECUTABLE": "/runtime/toolchain/usr/bin/swift",
            ],
            [
                "DEVELOPER_DIR": "",
                "TOOLCHAINS": "",
                "SDKROOT": "",
                "SWIFT_EXECUTABLE": "/another/runtime/swift",
            ],
        ]

        for runtimeEnvironment in driftedRuntimeEnvironments {
            #expect(runtimeEnvironment["SWIFT_EXECUTABLE"] != expected.swiftExecutable)
            let decoded = try SpiceBenchExecutableBuildInfo.decode(
                embeddedRevision: revision,
                metadataHex: metadataHex
            )
            #expect(try decoded.revision.validate(runtimeRevision: revision) == revision)
            #expect(decoded.metadata == expected)
        }

        #expect(throws: SpiceBenchError.missingBuildMetadata) {
            _ = try SpiceBenchExecutableBuildInfo.decode(
                embeddedRevision: revision,
                metadataHex: nil
            )
        }
        #expect(throws: SpiceBenchError.missingBuildMetadata) {
            _ = try SpiceBenchExecutableBuildInfo.decode(
                embeddedRevision: revision,
                metadataHex: ""
            )
        }
        for malformedHex in ["0", "not-hex", nulTerminatedHex(Array(fields.dropLast()))] {
            #expect(throws: SpiceBenchError.malformedBuildMetadata) {
                _ = try SpiceBenchExecutableBuildInfo.decode(
                    embeddedRevision: revision,
                    metadataHex: malformedHex
                )
            }
        }

        var invalidUTF8 = Data([0xff, 0x00])
        for field in fields.dropFirst() {
            invalidUTF8.append(contentsOf: field.utf8)
            invalidUTF8.append(0)
        }
        #expect(throws: SpiceBenchError.malformedBuildMetadata) {
            _ = try SpiceBenchExecutableBuildInfo.decode(
                embeddedRevision: revision,
                metadataHex: hexEncoded(invalidUTF8)
            )
        }

        var debugFields = fields
        debugFields[8] = "debug"
        #expect(throws: SpiceBenchError.malformedBuildMetadata) {
            _ = try SpiceBenchExecutableBuildInfo.decode(
                embeddedRevision: revision,
                metadataHex: nulTerminatedHex(debugFields)
            )
        }
    }
}

private struct RunMicroFixture {
    let temporaryDirectory: URL
    let repositoryURL: URL
    let scriptURL: URL
    let swiftURL: URL
    let argumentLogURL: URL
    let homeURL: URL

    static func make() throws -> Self {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("spice-bench-script-tests-\(UUID().uuidString)")
        let repositoryURL = temporaryDirectory.appendingPathComponent("repository")
        let benchmarksURL = repositoryURL.appendingPathComponent("Benchmarks")
        let toolchainURL = temporaryDirectory.appendingPathComponent("toolchain")
        let binaryURL = temporaryDirectory.appendingPathComponent("bin")
        let homeURL = temporaryDirectory.appendingPathComponent("home")
        try fileManager.createDirectory(at: benchmarksURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: toolchainURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binaryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)

        let sourceRepository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceScript = sourceRepository.appendingPathComponent("Benchmarks/run_micro.sh")
        let scriptURL = benchmarksURL.appendingPathComponent("run_micro.sh")
        try fileManager.copyItem(at: sourceScript, to: scriptURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )

        let argumentLogURL = temporaryDirectory.appendingPathComponent("swift-build-arguments.txt")
        let swiftURL = toolchainURL.appendingPathComponent("swift")
        let fakeSwiftTemplate = """
        #!/bin/sh
        set -eu
        if [ "${1-}" = "--version" ]; then
            printf '%s\\n' 'Apple Swift version 6.4 (fixture toolchain)'
            exit 0
        fi
        if [ "${1-}" = "-print-target-info" ]; then
            printf '%s\\n' '{"target":{"triple":"arm64-apple-macosx14.0"}}'
            exit 0
        fi
        if [ "${1-}" != "build" ]; then
            exit 64
        fi
        show_bin_path=0
        for argument do
            if [ "$argument" = "--show-bin-path" ]; then
                show_bin_path=1
            fi
        done
        if [ "$show_bin_path" -eq 1 ]; then
            printf '%s\\n' __BINARY_PATH__
            exit 0
        fi
        : > __ARGUMENT_LOG_PATH__
        for argument do
            printf '%s\\n' "$argument" >> __ARGUMENT_LOG_PATH__
        done
        """
        let fakeSwift = fakeSwiftTemplate
            .replacingOccurrences(of: "__BINARY_PATH__", with: shellQuote(binaryURL.path))
            .replacingOccurrences(
                of: "__ARGUMENT_LOG_PATH__",
                with: shellQuote(argumentLogURL.path)
            )
        try Data(fakeSwift.utf8).write(to: swiftURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: swiftURL.path
        )

        let benchmarkURL = binaryURL.appendingPathComponent("spice-bench")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: benchmarkURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: benchmarkURL.path
        )

        let fixture = Self(
            temporaryDirectory: temporaryDirectory,
            repositoryURL: repositoryURL,
            scriptURL: scriptURL,
            swiftURL: swiftURL,
            argumentLogURL: argumentLogURL,
            homeURL: homeURL
        )
        _ = try fixture.git(["init", "--quiet"])
        _ = try fixture.git(["config", "user.name", "Spice Bench Tests"])
        _ = try fixture.git(["config", "user.email", "spice-bench-tests@example.invalid"])
        _ = try fixture.git(["add", "Benchmarks/run_micro.sh"])
        _ = try fixture.git([
            "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture",
        ])
        return fixture
    }

    func remove() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func git(_ arguments: [String]) throws -> ProcessResult {
        try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectory: repositoryURL
        )
    }

    func gitOutput(_ arguments: [String]) throws -> String {
        let result = try git(arguments)
        guard result.status == 0 else {
            throw FixtureProcessError.failed(result.standardError)
        }
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func canonicalSwiftPath() throws -> String {
        let result = try runProcess(
            executable: URL(fileURLWithPath: "/bin/pwd"),
            arguments: ["-P"],
            currentDirectory: swiftURL.deletingLastPathComponent()
        )
        guard result.status == 0 else {
            throw FixtureProcessError.failed(result.standardError)
        }
        let directory = result.standardOutput
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(directory)/\(swiftURL.lastPathComponent)"
    }
}

private struct ProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String
}

private enum FixtureProcessError: Error {
    case failed(String)
}

private func runProcess(
    executable: URL,
    arguments: [String],
    environment: [String: String]? = nil,
    currentDirectory: URL
) throws -> ProcessResult {
    let process = Process()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = executable
    process.arguments = arguments
    process.environment = environment
    process.currentDirectoryURL = currentDirectory
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    process.waitUntilExit()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let error = standardError.fileHandleForReading.readDataToEndOfFile()
    return ProcessResult(
        status: process.terminationStatus,
        standardOutput: String(decoding: output, as: UTF8.self),
        standardError: String(decoding: error, as: UTF8.self)
    )
}

private func shellQuote(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}

private func nulTerminatedHex(_ fields: [String]) -> String {
    var bytes = Data()
    for field in fields {
        bytes.append(contentsOf: field.utf8)
        bytes.append(0)
    }
    return hexEncoded(bytes)
}

private func hexEncoded(_ bytes: Data) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}
