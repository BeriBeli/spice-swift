import Foundation
import Testing

@Suite("Remote Rocky fixture scripts")
struct RemoteRockyFixtureTests {
    @Test func buildPublicationAndEndpointStartupShareOneLifecycleLock() throws {
        let buildScript = try script("Integration/RemoteRocky/build-guest.sh")
        let commonScript = try script("Integration/RemoteRocky/remote/common.sh")
        let startScript = try script("Integration/RemoteRocky/remote/start.sh")

        #expect(buildScript.contains("readonly state=/work/state"))
        #expect(buildScript.contains(#"readonly lifecycle_lock="${state}/lifecycle.lock""#))
        #expect(commonScript.contains(#"readonly PERF_STATE="${PERF_BASE}/state""#))
        #expect(commonScript.contains(
            #"readonly PERF_LIFECYCLE_LOCK="${PERF_STATE}/lifecycle.lock""#
        ))

        let buildLock = try #require(buildScript.range(of: "flock -x 9"))
        let verifiedInitramfsHash = try #require(buildScript.range(
            of: #"actual_initramfs_sha256="$(sha256sum "${artifacts}/perf-initramfs.cpio.gz""#
        ))
        let stagedEvidence = try #require(buildScript.range(of: "du -h \\"))
        let rootfsPublication = try #require(buildScript.range(
            of: #"mv "${rootfs}" "${rootfs_target}""#,
            range: buildLock.upperBound..<buildScript.endIndex
        ))
        let artifactsPublication = try #require(buildScript.range(
            of: #"mv "${artifacts}" "${artifacts_target}""#,
            range: buildLock.upperBound..<buildScript.endIndex
        ))

        #expect(verifiedInitramfsHash.lowerBound < buildLock.lowerBound)
        #expect(stagedEvidence.lowerBound < buildLock.lowerBound)
        #expect(buildLock.lowerBound < rootfsPublication.lowerBound)
        #expect(buildLock.lowerBound < artifactsPublication.lowerBound)

        let startLock = try #require(startScript.range(of: "acquire_lifecycle_lock"))
        let startHash = try #require(startScript.range(of: "actual_kernel_sha256="))
        let evidenceCopy = try #require(startScript.range(
            of: #"cp "${manifest}" "${run_dir}/guest-build-manifest.env""#
        ))
        let containerDetach = try #require(startScript.range(of: "podman run --detach"))

        #expect(startLock.lowerBound < startHash.lowerBound)
        #expect(startLock.lowerBound < evidenceCopy.lowerBound)
        #expect(startLock.lowerBound < containerDetach.lowerBound)
    }

    @Test func lifecycleShellClosesLockFDForDetachedChildrenAndStopTrapsSignals() throws {
        let commonScript = try String(
            contentsOf: repositoryRoot.appending(path: "Integration/RemoteRocky/remote/common.sh"),
            encoding: .utf8
        )
        let startScript = try script("Integration/RemoteRocky/remote/start.sh")
        let stopScript = try script("Integration/RemoteRocky/remote/stop.sh")

        #expect(commonScript.contains(#"exec 9>"${PERF_LIFECYCLE_LOCK}""#))
        #expect(commonScript.contains("flock --exclusive 9"))

        let detach = try #require(startScript.range(of: "podman run --detach"))
        let detachEnd = try #require(startScript.range(
            of: #"9>&-)"#,
            range: detach.upperBound..<startScript.endIndex
        ))
        let logFollower = try #require(startScript.range(of: "nohup podman logs --follow"))
        let logFollowerClose = try #require(startScript.range(
            of: "9>&-",
            range: logFollower.upperBound..<startScript.endIndex
        ))
        #expect(detach.lowerBound < detachEnd.lowerBound)
        #expect(logFollower.lowerBound < logFollowerClose.lowerBound)

        #expect(stopScript.contains("trap 'stop_interrupted=true' HUP INT TERM"))
        #expect(stopScript.contains("stop_endpoint_locked"))
        #expect(stopScript.contains("trap - HUP INT TERM"))
    }

    @Test func buildManifestIsCompleteAndArtifactHashesAreVerified() throws {
        let buildScript = try String(
            contentsOf: repositoryRoot.appending(path: "Integration/RemoteRocky/build-guest.sh"),
            encoding: .utf8
        )
        let requiredKeys = RemoteRockyFixture.requiredManifestKeys

        for key in requiredKeys {
            #expect(buildScript.contains(key), "build manifest must record \(key)")
        }

        for missingKey in requiredKeys {
            let fixture = try RemoteRockyFixture()
            defer { fixture.remove() }
            try fixture.writeManifest(omitting: missingKey)

            let result = try fixture.run("remote/start.sh", ssMode: "both")
            #expect(result.status != 0, "start accepted a manifest missing \(missingKey)")
            #expect(!fixture.didDetachContainer)
        }

        let duplicateFixture = try RemoteRockyFixture()
        defer { duplicateFixture.remove() }
        try duplicateFixture.writeManifest(duplicating: "guest_spice_vdagent")
        let duplicateResult = try duplicateFixture.run("remote/start.sh", ssMode: "both")
        #expect(duplicateResult.status != 0)
        #expect(!duplicateFixture.didDetachContainer)

        for corruptedArtifact in ["kernel", "initramfs"] {
            let fixture = try RemoteRockyFixture()
            defer { fixture.remove() }
            try fixture.writeManifest(
                kernelHash: corruptedArtifact == "kernel"
                    ? String(repeating: "c", count: 64)
                    : nil,
                initramfsHash: corruptedArtifact == "initramfs"
                    ? String(repeating: "c", count: 64)
                    : nil
            )

            let result = try fixture.run("remote/start.sh", ssMode: "both")
            #expect(
                result.status != 0,
                "start accepted a mismatched \(corruptedArtifact) hash"
            )
            #expect(!fixture.didDetachContainer)
        }
    }

    @Test(arguments: ["spice-only", "control-only"])
    func readinessRequiresBothLoopbackPortsAndCleansFailedStart(ssMode: String) throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }

        let result = try fixture.run("remote/start.sh", ssMode: ssMode)

        #expect(result.status != 0)
        #expect(fixture.didStopContainer)
        #expect(!fixture.isContainerRunning)
        #expect(!fixture.stateFileExists("ticket"))
        #expect(!fixture.stateFileExists("current-run"))
        #expect(!fixture.stateFileExists("log-follower.pid"))
    }

    @Test func failedStartPreservesAuditableStateWhenEndpointTeardownFails() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }

        let result = try fixture.run(
            "remote/start.sh",
            ssMode: "spice-only",
            additionalEnvironment: [
                "MOCK_FAIL_STOP": "1",
                "MOCK_FAIL_RM": "1",
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains(
            "Performance endpoint teardown failed; active state was preserved."
        ))
        #expect(fixture.isContainerRunning)
        #expect(fixture.containerExists)
        #expect(fixture.stateFileExists("ticket"))
        #expect(fixture.stateFileExists("current-run"))
        #expect(fixture.stateFileExists("log-follower.pid"))
        #expect(fixture.stateFileExists("stop-failed"))
        #expect(fixture.stateFileExists("rm-failed"))

        let stopResult = try fixture.run(
            "remote/stop.sh",
            ssMode: "both",
            additionalEnvironment: [
                "MOCK_FAIL_STOP": "1",
                "MOCK_FAIL_RM": "1",
            ]
        )

        #expect(stopResult.status != 0)
        #expect(stopResult.output.contains(
            "Performance endpoint teardown failed; active state was preserved."
        ))
        #expect(fixture.isContainerRunning)
        #expect(fixture.containerExists)
        #expect(fixture.stateFileExists("ticket"))
        #expect(fixture.stateFileExists("current-run"))
        #expect(fixture.stateFileExists("log-follower.pid"))
    }

    @Test func preflightFailureDiscardsStaleFollowerPIDWithoutKillingItsProcess() throws {
        let startScript = try script("Integration/RemoteRocky/remote/start.sh")
        let staleStateDiscard = try #require(startScript.range(of: "remove_inactive_endpoint_locked"))
        let cleanupTrap = try #require(startScript.range(of: "trap cleanup_failed_start EXIT"))
        #expect(staleStateDiscard.lowerBound < cleanupTrap.lowerBound)

        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer {
            if sleeper.isRunning {
                sleeper.terminate()
            }
            sleeper.waitUntilExit()
        }

        try fixture.prepareStaleActiveState(logFollowerPID: sleeper.processIdentifier)
        try FileManager.default.removeItem(
            at: fixture.base.appending(path: "artifacts/build-manifest.env")
        )

        let result = try fixture.run("remote/start.sh", ssMode: "both")

        #expect(result.status != 0)
        #expect(sleeper.isRunning)
        #expect(!fixture.didDetachContainer)
        #expect(!fixture.stateFileExists("ticket"))
        #expect(!fixture.stateFileExists("current-run"))
        #expect(!fixture.stateFileExists("log-follower.pid"))
    }

    @Test func stopDiscardsStaleFollowerPIDWithoutKillingItsProcess() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }

        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer {
            if sleeper.isRunning {
                sleeper.terminate()
            }
            sleeper.waitUntilExit()
        }

        try fixture.prepareStaleActiveState(logFollowerPID: sleeper.processIdentifier)
        #expect(!fixture.isContainerRunning)

        let result = try fixture.run("remote/stop.sh", ssMode: "both")

        #expect(result.status == 0)
        #expect(sleeper.isRunning)
        #expect(!fixture.isContainerRunning)
        #expect(!fixture.didDetachContainer)
        #expect(!fixture.stateFileExists("ticket"))
        #expect(!fixture.stateFileExists("current-run"))
        #expect(!fixture.stateFileExists("log-follower.pid"))
    }

    @Test(arguments: ["spice-only", "control-only"])
    func statusCannotPassWithOnlyOneListener(ssMode: String) throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        try fixture.prepareRunningState()

        let result = try fixture.run("remote/status.sh", ssMode: ssMode)

        #expect(result.status != 0)
    }

    @Test func statusAcceptsExactlyBothLoopbackListeners() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        try fixture.prepareRunningState()

        let result = try fixture.run("remote/status.sh", ssMode: "both")

        #expect(result.status == 0)
        #expect(result.output.contains("spice=127.0.0.1:5935"))
        #expect(result.output.contains("control=127.0.0.1:5936"))
    }

    @Test func startsWithinTheSameSecondUseDistinctEvidenceDirectories() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }

        let firstStart = try fixture.run("remote/start.sh", ssMode: "both")
        #expect(firstStart.status == 0)
        let firstRun = try fixture.currentRunID()
        #expect(fixture.runDirectoryExists(firstRun))

        let stop = try fixture.run("remote/stop.sh", ssMode: "both")
        #expect(stop.status == 0)

        let secondStart = try fixture.run("remote/start.sh", ssMode: "both")
        #expect(secondStart.status == 0)
        let secondRun = try fixture.currentRunID()

        #expect(secondRun != firstRun)
        #expect(fixture.runDirectoryExists(firstRun))
        #expect(fixture.runDirectoryExists(secondRun))
    }

    @Test func concurrentStartsShareOneEndpointWithoutLosingActiveState() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }

        let first = try fixture.launch(
            "remote/start.sh",
            ssMode: "both",
            additionalEnvironment: ["MOCK_WAIT_FOR_INSPECT": "second-inspected"]
        )
        try fixture.waitForMockState("detach-entered")
        let second = try fixture.launch(
            "remote/start.sh",
            ssMode: "both",
            additionalEnvironment: ["MOCK_INSPECT_SIGNAL": "second-inspected"]
        )

        let firstResult = first.finish()
        let secondResult = second.finish()

        #expect(firstResult.status == 0)
        #expect(secondResult.status == 0)
        #expect(try fixture.mockEventCount("detached") == 1)
        #expect(fixture.isContainerRunning)
        #expect(fixture.stateFileExists("ticket"))
        #expect(fixture.stateFileExists("current-run"))
    }

    @Test func successfulStartReleasesLockWhileLogFollowerRemainsActive() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        defer { fixture.releaseMockState("log-follower") }

        let firstStart = try fixture.run(
            "remote/start.sh",
            ssMode: "both",
            additionalEnvironment: ["MOCK_HOLD_LOG_FOLLOWER": "1"]
        )
        #expect(firstStart.status == 0)
        try fixture.waitForMockState("log-follower-entered")
        #expect(!fixture.stateFileExists("fd9-inherited-detach"))
        #expect(!fixture.stateFileExists("fd9-inherited-log-follower"))

        let secondStart = try fixture.launch("remote/start.sh", ssMode: "both")
        let secondResult = try secondStart.finish(within: .seconds(3))

        #expect(secondResult.status == 0)
        #expect(try fixture.mockEventCount("detached") == 1)

        fixture.releaseMockState("log-follower")
        try fixture.waitForMockState("log-follower-finished")
    }

    @Test func terminationDuringStartupAndStopLeavesNoConcurrentStateRace() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        defer {
            fixture.releaseMockState("detach")
            fixture.releaseMockState("stop")
        }

        let starting = try fixture.launch(
            "remote/start.sh",
            ssMode: "both",
            additionalEnvironment: ["MOCK_HOLD_DETACH": "1"]
        )
        try fixture.waitForMockState("detach-entered")
        starting.terminate()
        fixture.releaseMockState("detach")
        let interruptedStart = try starting.finish(within: .seconds(3))

        #expect(interruptedStart.status != 0)
        #expect(!fixture.isContainerRunning)
        #expect(!fixture.stateFileExists("ticket"))
        #expect(!fixture.stateFileExists("current-run"))

        let recoveredStart = try fixture.run("remote/start.sh", ssMode: "both")
        #expect(recoveredStart.status == 0)

        let stopping = try fixture.launch(
            "remote/stop.sh",
            ssMode: "both",
            additionalEnvironment: ["MOCK_HOLD_STOP": "1"]
        )
        try fixture.waitForMockState("stop-entered")
        stopping.terminate()
        fixture.releaseMockState("stop")
        let interruptedStop = try stopping.finish(within: .seconds(3))

        #expect(interruptedStop.status != 0)
        #expect(!fixture.isContainerRunning)
        #expect(!fixture.stateFileExists("ticket"))
        #expect(!fixture.stateFileExists("current-run"))

        let finalStart = try fixture.run("remote/start.sh", ssMode: "both")
        #expect(finalStart.status == 0)
    }

    @Test func ticketIsPrivateNeverLoggedDeletedAndRotated() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }

        let firstStart = try fixture.run("remote/start.sh", ssMode: "both")
        #expect(firstStart.status == 0)
        let firstTicket = try fixture.ticket()
        #expect(firstTicket.range(of: "^[0-9a-f]{48}$", options: .regularExpression) != nil)
        #expect(try fixture.ticketPermissions() == 0o600)
        #expect(!fixture.evidenceOrArgumentsContain(firstTicket))

        let firstStop = try fixture.run("remote/stop.sh", ssMode: "both")
        #expect(firstStop.status == 0)
        #expect(!fixture.stateFileExists("ticket"))
        #expect(!fixture.evidenceOrArgumentsContain(firstTicket))

        let secondStart = try fixture.run("remote/start.sh", ssMode: "both")
        #expect(secondStart.status == 0)
        let secondTicket = try fixture.ticket()
        #expect(secondTicket.range(of: "^[0-9a-f]{48}$", options: .regularExpression) != nil)
        #expect(secondTicket != firstTicket)
        #expect(try fixture.ticketPermissions() == 0o600)
        #expect(!fixture.evidenceOrArgumentsContain(secondTicket))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func script(_ relativePath: String) throws -> String {
        try String(
            contentsOf: repositoryRoot.appending(path: relativePath),
            encoding: .utf8
        )
    }
}

private struct RemoteRockyFixture {
    static let requiredManifestKeys = [
        "manifest_version",
        "guest_kernel",
        "guest_alpine_base",
        "guest_dbus",
        "guest_font_dejavu",
        "guest_linux_virt",
        "guest_openbox",
        "guest_spice_vdagent",
        "guest_spice_webdavd",
        "guest_xclip",
        "guest_xorg_server",
        "guest_xrandr",
        "guest_xsetroot",
        "guest_xterm",
        "guest_kernel_sha256",
        "guest_initramfs_sha256",
    ]

    private static let kernelHash = String(repeating: "a", count: 64)
    private static let initramfsHash = String(repeating: "b", count: 64)
    private let fileManager = FileManager.default
    let root: URL
    let base: URL
    let mockState: URL
    private let mockBin: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "remote-rocky-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        base = root.appending(path: "perf-ab", directoryHint: .isDirectory)
        mockState = root.appending(path: "mock-state", directoryHint: .isDirectory)
        mockBin = root.appending(path: "bin", directoryHint: .isDirectory)

        try fileManager.createDirectory(at: base.appending(path: "artifacts"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: base.appending(path: "state"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: base.appending(path: "logs"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mockState, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: mockBin, withIntermediateDirectories: true)
        try Data("kernel".utf8).write(to: base.appending(path: "artifacts/vmlinuz-virt"))
        try Data("initramfs".utf8).write(to: base.appending(path: "artifacts/perf-initramfs.cpio.gz"))
        try writeManifest()
        try writeMocks()
    }

    var didDetachContainer: Bool {
        ((try? mockEventCount("detached")) ?? 0) > 0
    }

    var didStopContainer: Bool {
        stateFileExists("stopped")
    }

    var isContainerRunning: Bool {
        fileManager.fileExists(atPath: mockState.appending(path: "running").path)
    }

    var containerExists: Bool {
        fileManager.fileExists(atPath: mockState.appending(path: "container").path)
    }

    func remove() {
        try? fileManager.removeItem(at: root)
    }

    func writeManifest(
        omitting omittedKey: String? = nil,
        duplicating duplicatedKey: String? = nil,
        kernelHash: String? = nil,
        initramfsHash: String? = nil
    ) throws {
        let values = [
            "manifest_version": "1",
            "guest_kernel": "linux-virt-6.12.103-r0",
            "guest_alpine_base": "3.22.5-r0",
            "guest_dbus": "1.16.2-r1",
            "guest_font_dejavu": "2.37-r6",
            "guest_linux_virt": "6.12.103-r0",
            "guest_openbox": "3.6.1-r8",
            "guest_spice_vdagent": "0.22.1-r2",
            "guest_spice_webdavd": "3.0-r4",
            "guest_xclip": "0.13-r3",
            "guest_xorg_server": "21.1.19-r0",
            "guest_xrandr": "1.5.2-r0",
            "guest_xsetroot": "1.1.1-r2",
            "guest_xterm": "399-r0",
            "guest_kernel_sha256": kernelHash ?? Self.kernelHash,
            "guest_initramfs_sha256": initramfsHash ?? Self.initramfsHash,
        ]
        var lines = Self.requiredManifestKeys.compactMap { key -> String? in
            guard key != omittedKey, let value = values[key] else { return nil }
            return "\(key)=\(value)"
        }
        if let duplicatedKey, let value = values[duplicatedKey] {
            lines.append("\(duplicatedKey)=\(value)")
        }
        let contents = lines.joined(separator: "\n") + "\n"
        try Data(contents.utf8).write(to: base.appending(path: "artifacts/build-manifest.env"))
    }

    func prepareRunningState() throws {
        let runID = "20260828T010203Z"
        try fileManager.createDirectory(
            at: base.appending(path: "logs/\(runID)"),
            withIntermediateDirectories: true
        )
        try Data("\(runID)\n".utf8).write(to: base.appending(path: "state/current-run"))
        try Data().write(to: mockState.appending(path: "running"))
    }

    func prepareStaleActiveState(logFollowerPID: Int32) throws {
        let state = base.appending(path: "state")
        try Data("stale-ticket".utf8).write(to: state.appending(path: "ticket"))
        try Data("stale-run\n".utf8).write(to: state.appending(path: "current-run"))
        try Data("\(logFollowerPID)\n".utf8).write(to: state.appending(path: "log-follower.pid"))
    }

    func run(
        _ relativePath: String,
        ssMode: String,
        additionalEnvironment: [String: String] = [:]
    ) throws -> ScriptResult {
        try launch(
            relativePath,
            ssMode: ssMode,
            additionalEnvironment: additionalEnvironment
        ).finish()
    }

    func launch(
        _ relativePath: String,
        ssMode: String,
        additionalEnvironment: [String: String] = [:]
    ) throws -> RunningScript {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repositoryRoot
            .appending(path: "Integration/RemoteRocky/\(relativePath)").path]
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(mockBin.path):/usr/bin:/bin:/usr/sbin:/sbin"
        environment["HOME"] = root.path
        environment["SWIFTSPICE_PERF_BASE"] = base.path
        environment["MOCK_PODMAN_STATE"] = mockState.path
        environment["MOCK_SS_MODE"] = ssMode
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }
        process.environment = environment
        try process.run()
        return RunningScript(process: process, output: output)
    }

    func currentRunID() throws -> String {
        try String(contentsOf: base.appending(path: "state/current-run"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func runDirectoryExists(_ runID: String) -> Bool {
        fileManager.fileExists(atPath: base.appending(path: "logs/\(runID)").path)
    }

    func stateFileExists(_ name: String) -> Bool {
        fileManager.fileExists(atPath: mockState.appending(path: name).path)
            || fileManager.fileExists(atPath: base.appending(path: "state/\(name)").path)
    }

    func ticket() throws -> String {
        try String(contentsOf: base.appending(path: "state/ticket"), encoding: .utf8)
    }

    func ticketPermissions() throws -> Int {
        let attributes = try fileManager.attributesOfItem(
            atPath: base.appending(path: "state/ticket").path
        )
        return try #require(attributes[.posixPermissions] as? Int)
    }

    func evidenceOrArgumentsContain(_ text: String) -> Bool {
        let roots = [base.appending(path: "logs"), mockState.appending(path: "commands")]
        for root in roots {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory) else {
                continue
            }
            if !isDirectory.boolValue {
                if let data = fileManager.contents(atPath: root.path),
                   String(decoding: data, as: UTF8.self).contains(text) {
                    return true
                }
                continue
            }
            guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let fileURL as URL in enumerator {
                if let data = fileManager.contents(atPath: fileURL.path),
                   String(decoding: data, as: UTF8.self).contains(text) {
                    return true
                }
            }
        }
        return false
    }

    func waitForMockState(_ name: String) throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        let path = mockState.appending(path: name).path
        while !fileManager.fileExists(atPath: path) {
            guard ContinuousClock().now < deadline else {
                throw RemoteRockyFixtureError.timedOutWaitingForMockState(name)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    func releaseMockState(_ name: String) {
        _ = fileManager.createFile(
            atPath: mockState.appending(path: "release-\(name)").path,
            contents: Data()
        )
    }

    func mockEventCount(_ event: String) throws -> Int {
        guard fileManager.fileExists(atPath: mockState.appending(path: "events").path) else {
            return 0
        }
        return try String(
            contentsOf: mockState.appending(path: "events"),
            encoding: .utf8
        ).split(separator: "\n").filter { $0 == event }.count
    }

    private func writeMocks() throws {
        try writeExecutable(name: "flock", contents: #"""
        #!/bin/bash
        set -euo pipefail
        [[ "${1:-}" == --exclusive ]]
        [[ "${2:-}" == 9 ]]
        [[ $# == 2 ]]
        exec /usr/bin/python3 -c 'import fcntl; fcntl.flock(9, fcntl.LOCK_EX)'
        """#)
        try writeExecutable(name: "podman", contents: #"""
        #!/bin/bash
        set -euo pipefail
        state="${MOCK_PODMAN_STATE:?}"
        command="${1:-}"
        shift || true
        printf '%s' "$command" >> "$state/commands"
        printf ' %s' "$@" >> "$state/commands"
        printf '\n' >> "$state/commands"
        case "$command" in
            container)
                [[ "${1:-}" == exists ]]
                [[ "${2:-}" == swiftspice-perf-ab-qemu ]]
                [[ $# == 2 ]]
                [[ -d "$state/container" ]]
                ;;
            inspect)
                [[ "${1:-}" == --format ]]
                [[ "${2:-}" == '{{.State.Running}}' ]]
                [[ "${3:-}" == swiftspice-perf-ab-qemu ]]
                [[ $# == 3 ]]
                if [[ -n "${MOCK_INSPECT_SIGNAL:-}" ]]; then
                    : > "$state/$MOCK_INSPECT_SIGNAL"
                fi
                [[ -f "$state/running" ]] && printf 'true\n'
                ;;
            rm)
                [[ "${1:-}" == --force ]]
                [[ "${2:-}" == swiftspice-perf-ab-qemu ]]
                [[ $# == 2 ]]
                if [[ "${MOCK_FAIL_RM:-}" == 1 && -d "$state/container" ]]; then
                    : > "$state/rm-failed"
                    exit 71
                fi
                rm -f "$state/running"
                rmdir "$state/container" 2>/dev/null || true
                ;;
            stop)
                [[ "${1:-}" == --time ]]
                [[ "${2:-}" == 10 ]]
                [[ "${3:-}" == swiftspice-perf-ab-qemu ]]
                [[ $# == 3 ]]
                if [[ "${MOCK_HOLD_STOP:-}" == 1 ]]; then
                    : > "$state/stop-entered"
                    while [[ ! -f "$state/release-stop" ]]; do /bin/sleep 0.01; done
                fi
                if [[ "${MOCK_FAIL_STOP:-}" == 1 ]]; then
                    : > "$state/stop-failed"
                    exit 70
                fi
                rm -f "$state/running"
                rmdir "$state/container" 2>/dev/null || true
                : > "$state/stopped"
                ;;
            run)
                if [[ " $* " == *" --detach "* ]]; then
                    if [[ -e /dev/fd/9 ]]; then
                        : > "$state/fd9-inherited-detach"
                        exit 65
                    fi
                    [[ " $* " == *" --name swiftspice-perf-ab-qemu "* ]]
                    [[ " $* " == *" -object secret,id=spice-password,file=/state/ticket "* ]]
                    [[ " $* " != *"0123456789abcdef"* ]]
                    : > "$state/detach-entered"
                    if [[ -n "${MOCK_WAIT_FOR_INSPECT:-}" ]]; then
                        for _ in $(seq 1 100); do
                            [[ -f "$state/$MOCK_WAIT_FOR_INSPECT" ]] && break
                            /bin/sleep 0.01
                        done
                    fi
                    if [[ "${MOCK_HOLD_DETACH:-}" == 1 ]]; then
                        while [[ ! -f "$state/release-detach" ]]; do /bin/sleep 0.01; done
                    fi
                    mkdir "$state/container"
                    : > "$state/running"
                    printf 'detached\n' >> "$state/events"
                    printf 'mock-container-id\n'
                elif [[ " $* " == *" qemu-system-x86_64 --version "* ]]; then
                    [[ "${1:-}" == --rm ]]
                    printf 'QEMU emulator version mock\n'
                elif [[ " $* " == *" dpkg-query "* ]]; then
                    [[ "${1:-}" == --rm ]]
                    printf 'libspice-server1 mock\n'
                else
                    exit 64
                fi
                ;;
            logs)
                if [[ "${1:-}" == --follow ]]; then
                    [[ "${2:-}" == swiftspice-perf-ab-qemu ]]
                    [[ $# == 2 ]]
                    if [[ -e /dev/fd/9 ]]; then
                        : > "$state/fd9-inherited-log-follower"
                        exit 65
                    fi
                elif [[ "${1:-}" == --tail ]]; then
                    [[ "${2:-}" == 12 ]]
                    [[ "${3:-}" == swiftspice-perf-ab-qemu ]]
                    [[ $# == 3 ]]
                else
                    [[ "${1:-}" == swiftspice-perf-ab-qemu ]]
                    [[ $# == 1 ]]
                fi
                printf 'PERF_READY resolution=1280x720\n'
                if [[ "${1:-}" == --follow && "${MOCK_HOLD_LOG_FOLLOWER:-}" == 1 ]]; then
                    : > "$state/log-follower-entered"
                    while [[ ! -f "$state/release-log-follower" ]]; do /bin/sleep 0.01; done
                    : > "$state/log-follower-finished"
                fi
                ;;
            version)
                [[ $# == 0 ]]
                printf 'podman version mock\n'
                ;;
            *)
                printf 'unexpected podman command: %s\n' "$command" >&2
                exit 64
                ;;
        esac
        """#)
        try writeExecutable(name: "ss", contents: #"""
        #!/bin/bash
        set -euo pipefail
        [[ "$*" == '-ltnH' ]]
        case "${MOCK_SS_MODE:-both}" in
            both)
                printf 'LISTEN 0 1 127.0.0.1:5935 0.0.0.0:*\n'
                printf 'LISTEN 0 1 127.0.0.1:5936 0.0.0.0:*\n'
                ;;
            spice-only)
                printf 'LISTEN 0 1 127.0.0.1:5935 0.0.0.0:*\n'
                ;;
            control-only)
                printf 'LISTEN 0 1 127.0.0.1:5936 0.0.0.0:*\n'
                ;;
            none) ;;
            *) exit 64 ;;
        esac
        """#)
        try writeExecutable(name: "openssl", contents: #"""
        #!/bin/bash
        set -euo pipefail
        [[ "${1:-}" == rand && "${2:-}" == -hex && "${3:-}" == 24 ]]
        lock="$MOCK_PODMAN_STATE/ticket-counter.lock"
        until mkdir "$lock" 2>/dev/null; do /bin/sleep 0.01; done
        counter=0
        [[ -f "$MOCK_PODMAN_STATE/ticket-counter" ]] \
            && counter="$(<"$MOCK_PODMAN_STATE/ticket-counter")"
        counter=$((counter + 1))
        printf '%s\n' "$counter" > "$MOCK_PODMAN_STATE/ticket-counter"
        rmdir "$lock"
        printf '%048x\n' "$counter"
        """#)
        try writeExecutable(name: "date", contents: #"""
        #!/bin/bash
        set -euo pipefail
        if [[ "$*" == '-u +%Y%m%dT%H%M%SZ' ]]; then
            printf '20260828T010203Z\n'
        else
            exec /bin/date "$@"
        fi
        """#)
        try writeExecutable(name: "sleep", contents: #"""
        #!/bin/bash
        exec /bin/sleep 0.01
        """#)
        try writeExecutable(name: "sha256sum", contents: #"""
        #!/bin/bash
        set -euo pipefail
        for path in "$@"; do
            case "$(basename "$path")" in
                vmlinuz-virt)
                    printf '%s  %s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$path"
                    ;;
                perf-initramfs.cpio.gz)
                    printf '%s  %s\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$path"
                    ;;
                *) exit 64 ;;
            esac
        done
        """#)
    }

    private func writeExecutable(name: String, contents: String) throws {
        let url = mockBin.appending(path: name)
        try Data(contents.utf8).write(to: url)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private struct ScriptResult {
    let status: Int32
    let output: String
}

private struct RunningScript {
    let process: Process
    let output: Pipe

    func finish() -> ScriptResult {
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ScriptResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    func finish(within timeout: Duration) throws -> ScriptResult {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while process.isRunning, ContinuousClock().now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            process.waitUntilExit()
            throw RemoteRockyFixtureError.timedOutWaitingForScript
        }
        return finish()
    }

    func terminate() {
        process.terminate()
    }
}

private enum RemoteRockyFixtureError: Error {
    case timedOutWaitingForMockState(String)
    case timedOutWaitingForScript
}
