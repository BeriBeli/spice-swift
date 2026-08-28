import Darwin
import Foundation
import Testing

@Suite("Remote Rocky fixture scripts")
struct RemoteRockyFixtureTests {
    @Test func guestBuilderOwnsBuildToolsAndRuntimeRemainsMinimal() throws {
        let builder = try script("Integration/RemoteRocky/GuestBuilder.Containerfile")
        let runtime = try script("Integration/RemoteRocky/Containerfile")
        let readme = try script("Integration/RemoteRocky/REMOTE_ROCKY.md")
        let buildGuest = try script("Integration/RemoteRocky/build-guest.sh")

        #expect(builder.contains("FROM docker.io/library/alpine:3.22"))
        #expect(builder.contains("build-base=0.5-r3"))
        #expect(builder.contains("fortify-headers=1.1-r5"))
        #expect(builder.contains("flock=2.41-r9"))

        let compilerCheck = try #require(buildGuest.range(of: "command -v cc"))
        let lockCheck = try #require(buildGuest.range(of: "command -v flock"))
        let firstStagingDirectory = try #require(buildGuest.range(of: "mktemp -d /work/.rootfs"))
        #expect(compilerCheck.lowerBound < firstStagingDirectory.lowerBound)
        #expect(lockCheck.lowerBound < firstStagingDirectory.lowerBound)
        #expect(buildGuest.contains("\ncc -std=c11 -Os -Wall -Wextra -Werror -static"))
        #expect(!buildGuest.contains("musl-gcc"))

        for forbiddenPackage in ["gcc", "musl-tools", "musl-dev", "build-base"] {
            #expect(!runtime.contains(forbiddenPackage))
        }

        let buildCommand = try #require(readme.range(of: "podman build \\"))
        let recipe = try #require(readme.range(
            of: "--file Integration/RemoteRocky/GuestBuilder.Containerfile",
            range: buildCommand.lowerBound..<readme.endIndex
        ))
        let builderImage = try #require(readme.range(
            of: "localhost/swiftspice-guest-builder:alpine-3.22",
            range: recipe.lowerBound..<readme.endIndex
        ))
        let runCommand = try #require(readme.range(
            of: "podman run --rm \\",
            range: builderImage.lowerBound..<readme.endIndex
        ))
        let mount = try #require(readme.range(
            of: #"--volume "$PWD/Integration/RemoteRocky:/work:Z""#,
            range: runCommand.lowerBound..<readme.endIndex
        ))
        let runImage = try #require(readme.range(
            of: "localhost/swiftspice-guest-builder:alpine-3.22",
            range: mount.lowerBound..<readme.endIndex
        ))
        let guestBuild = try #require(readme.range(
            of: "/work/build-guest.sh",
            range: runImage.lowerBound..<readme.endIndex
        ))
        #expect(buildCommand.lowerBound < recipe.lowerBound)
        #expect(recipe.lowerBound < builderImage.lowerBound)
        #expect(builderImage.lowerBound < runCommand.lowerBound)
        #expect(runCommand.lowerBound < mount.lowerBound)
        #expect(mount.lowerBound < runImage.lowerBound)
        #expect(runImage.lowerBound < guestBuild.lowerBound)
        let runInvocation = readme[runCommand.lowerBound..<guestBuild.upperBound]
        #expect(!runInvocation.contains("--userns=keep-id"))
    }

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

        #expect(buildScript.contains("linux-virt=6.12.107-r0"))
        #expect(!buildScript.contains("linux-virt=6.12.103-r0"))
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

    @Test func guestInputMonitorUsesThePinnedLineBufferingProvider() throws {
        let buildScript = try script("Integration/RemoteRocky/build-guest.sh")
        let startScript = try script("Integration/RemoteRocky/remote/start.sh")
        let monitorScript = try script("Integration/RemoteRocky/guest/input-marker-monitor.sh")

        #expect(buildScript.contains("coreutils="))
        #expect(buildScript.contains("record_package coreutils guest_coreutils"))
        #expect(buildScript.contains("xf86-input-libinput=1.5.0-r0"))
        #expect(buildScript.contains(
            "record_package xf86-input-libinput guest_xf86_input_libinput"
        ))
        #expect(startScript.contains("guest_coreutils"))
        #expect(startScript.contains("guest_xf86_input_libinput"))
        #expect(monitorScript.contains("stdbuf -oL -eL xinput test-xi2 --root"))
        #expect(!monitorScript.contains("\nxinput test-xi2 --root |"))
    }

    @Test func markerDrawsInsideBothFullscreenWorkloadsBeforeAcknowledgment() throws {
        let guestInit = try script("Integration/RemoteRocky/guest/init")
        let renderer = try script(
            "Integration/RemoteRocky/guest/input-marker-renderer.sh"
        )
        let animationGenerator = try script(
            "Integration/RemoteRocky/guest/animation-generator.sh"
        )
        let workloads = [
            try script("Integration/RemoteRocky/guest/static-desktop.sh"),
            try script("Integration/RemoteRocky/guest/animation-load.sh"),
        ]

        for workload in workloads {
            let fullscreen = try #require(workload.range(of: "-fullscreen"))
            let terminalCommand = try #require(workload.range(
                of: "input-marker-renderer.sh",
                range: fullscreen.upperBound..<workload.endIndex
            ))
            #expect(fullscreen.lowerBound < terminalCommand.lowerBound)
        }

        #expect(!renderer.contains("exec xterm"))
        #expect(!guestInit.contains("/usr/local/bin/input-marker-renderer.sh &"))
        #expect(renderer.contains(#"printf '\033[1;1H"#))
        #expect(renderer.contains("Rows 1-4 are reserved"))
        #expect(renderer.contains("printf '\\033[2J\\033[6;1H'"))
        #expect(animationGenerator.contains("printf '\\033[6;1H"))
        #expect(!animationGenerator.contains("printf '\\033[1;1H"))
        let visibleDraw = try #require(renderer.range(of: "CAUSAL INPUT MARKER"))
        let visibilityBarrier = try #require(renderer.range(
            of: "terminal_visibility_barrier",
            range: visibleDraw.upperBound..<renderer.endIndex
        ))
        let acknowledgment = try #require(renderer.range(
            of: #"> "${ack_fifo}""#,
            range: visibilityBarrier.upperBound..<renderer.endIndex
        ))
        #expect(visibleDraw.lowerBound < visibilityBarrier.lowerBound)
        #expect(visibilityBarrier.lowerBound < acknowledgment.lowerBound)
    }

    @Test func markerWorkloadsDrawAndCrossTheVisibilityBarrierBeforeAcknowledgment() throws {
        let marker = "SWIFTSPICE_MARKER token=0123456789abcdef "
            + "marker_revision=17 checksum=9f9f5111\n"

        for workload in ["static", "animation"] {
            let result = try runGuestScript(
                "input-marker-renderer.sh",
                arguments: ["--self-test-workload", workload],
                standardInput: marker
            )
            let lines = result.output.split(separator: "\n").map(String.init)
            let common = "workload=\(workload) token=0123456789abcdef marker_revision=17"

            #expect(result.status == 0)
            #expect(lines == [
                "PERF_MARKER_WORKLOAD action=draw \(common)",
                "PERF_MARKER_WORKLOAD action=barrier \(common)",
                "PERF_MARKER_WORKLOAD action=ack \(common)",
            ])
        }

        let invalidWorkload = try runGuestScript(
            "input-marker-renderer.sh",
            arguments: ["--self-test-workload", "unknown"],
            standardInput: marker
        )
        #expect(invalidWorkload.status != 0)
        #expect(!invalidWorkload.output.contains("action=ack"))

        let malformedMarker = try runGuestScript(
            "input-marker-renderer.sh",
            arguments: ["--self-test-workload", "static"],
            standardInput: "NOT_A_MARKER token=0123456789abcdef "
                + "marker_revision=17 checksum=9f9f5111\n"
        )
        #expect(malformedMarker.status != 0)
        #expect(!malformedMarker.output.contains("action=ack"))
    }

    @Test func markerRendererKeepsTheRequestFIFOReadableBetweenMarkers() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "guest-marker-renderer-fifo-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let requestFIFO = directory.appending(path: "request")
        let acknowledgmentFIFO = directory.appending(path: "ack")
        let afterProcess = directory.appending(path: "after-process")
        let outputURL = directory.appending(path: "renderer-output.log")
        try makeFIFOs(requestFIFO, acknowledgmentFIFO)
        FileManager.default.createFile(atPath: outputURL.path, contents: Data())
        let output = try FileHandle(forWritingTo: outputURL)

        let renderer = Process()
        renderer.executableURL = URL(fileURLWithPath: "/bin/sh")
        renderer.arguments = [
            repositoryRoot.appending(
                path: "Integration/RemoteRocky/guest/input-marker-renderer.sh"
            ).path,
            "--self-test-fifo",
        ]
        renderer.standardOutput = output
        renderer.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["PERF_MARKER_REQUEST_FIFO"] = requestFIFO.path
        environment["PERF_MARKER_ACK_FIFO"] = acknowledgmentFIFO.path
        environment["PERF_MARKER_SELF_TEST_REQUEST_COUNT"] = "2"
        environment["PERF_MARKER_SELF_TEST_AFTER_PROCESS_FILE"] = afterProcess.path
        renderer.environment = environment
        try renderer.run()
        try output.close()
        try waitForText("PERF_MARKER_WORKLOAD action=ready", count: 1, in: outputURL)

        let firstWriterFinished = directory.appending(path: "first-writer-finished")
        let firstWriter = try launchFIFORecordWriter(
            "SWIFTSPICE_MARKER token=0000000000000001 "
                + "marker_revision=1 checksum=665e9948",
            FIFO: requestFIFO,
            completion: firstWriterFinished
        )
        try waitForPath(firstWriterFinished)
        #expect(try firstWriter.finish(within: .seconds(2)).status == 0)
        try waitForPath(afterProcess.appendingPathExtension("entered.1"))

        // The renderer is deliberately between process_marker and its next read.
        // A persistent reader lets this publication complete without waiting for
        // the first iteration's gate to be released.
        let secondWriterFinished = directory.appending(path: "second-writer-finished")
        let secondWriter = try launchFIFORecordWriter(
            "SWIFTSPICE_MARKER token=0000000000000002 "
                + "marker_revision=2 checksum=cd04a475",
            FIFO: requestFIFO,
            completion: secondWriterFinished
        )
        try waitForPath(secondWriterFinished)
        #expect(try secondWriter.finish(within: .seconds(2)).status == 0)

        try Data().write(to: afterProcess.appendingPathExtension("release.1"))
        try waitForPath(afterProcess.appendingPathExtension("entered.2"))
        try Data().write(to: afterProcess.appendingPathExtension("release.2"))
        try waitForExit(renderer, within: .seconds(3))

        let records = perfRecords(
            prefix: "PERF_MARKER_WORKLOAD",
            in: try String(contentsOf: outputURL, encoding: .utf8)
        )
        #expect(renderer.terminationStatus == 0)
        #expect(records.compactMap { $0["action"] } == [
            "ready", "draw", "barrier", "ack", "draw", "barrier", "ack",
        ])
        #expect(records.compactMap { $0["marker_revision"] } == [
            "1", "1", "1", "2", "2", "2",
        ])
    }

    @Test func markerVisibilityBarrierAcceptsOnlyTheExactTerminalResponse() throws {
        let escape = "\u{1B}"
        let unrelatedPrefix = String(repeating: "ordinary-n:X;", count: 128)
            + "\(escape)[1n"
        let accepted = try runGuestScript(
            "input-marker-renderer.sh",
            arguments: ["--self-test-barrier"],
            standardInput: "\(unrelatedPrefix)\(escape)[0n",
            environment: ["PERF_MARKER_SELF_TEST_BARRIER_DIAGNOSTICS": "1"]
        )
        #expect(accepted.status == 0)
        let acceptedLines = accepted.output.split(separator: "\n").map(String.init)
        #expect(acceptedLines.contains("PERF_MARKER_BARRIER accepted"))
        // The host fallback may perform several bounded os.read calls, but it
        // must keep one transport process for the complete absolute deadline.
        #expect(acceptedLines.contains("PERF_MARKER_BARRIER_TRANSPORT runs=1"))

        for malformed in [
            "ordinary n bytes\n",
            "\(escape)[0m",
            "\(escape)[00n",
            "noise\(escape)[1n",
        ] {
            let rejected = try runGuestScript(
                "input-marker-renderer.sh",
                arguments: ["--self-test-barrier"],
                standardInput: malformed,
                environment: ["PERF_MARKER_SELF_TEST_BARRIER_TIMEOUT_NS": "50000000"]
            )
            #expect(rejected.status != 0)
            #expect(rejected.output.contains("PERF_MARKER_BARRIER rejected"))
            #expect(!rejected.output.contains("accepted"))
        }

        // Keep stdin open: rejection must come from the one aggregate deadline,
        // not EOF and not a deadline restarted by unrelated bytes.
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            repositoryRoot.appending(
                path: "Integration/RemoteRocky/guest/input-marker-renderer.sh"
            ).path,
            "--self-test-barrier",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["PERF_MARKER_SELF_TEST_BARRIER_TIMEOUT_NS"] = "50000000"
        environment["PERF_MARKER_SELF_TEST_BARRIER_DIAGNOSTICS"] = "1"
        process.environment = environment
        try process.run()
        input.fileHandleForWriting.write(Data(unrelatedPrefix.utf8))
        let timedOut = try RunningScript(process: process, output: output).finish(
            within: .seconds(2)
        )
        try input.fileHandleForWriting.close()

        #expect(timedOut.status != 0)
        #expect(timedOut.output.contains("PERF_MARKER_BARRIER rejected"))
        let transportRecord = try #require(perfRecords(
            prefix: "PERF_MARKER_BARRIER_TRANSPORT",
            in: timedOut.output
        ).first)
        let transportRuns = try #require(transportRecord["runs"].flatMap(Int.init))
        #expect((0...1).contains(transportRuns))
        #expect(!timedOut.output.contains("accepted"))
    }

    @Test func lateTerminalStatusCannotSatisfyTheNextMarkerBarrier() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "guest-marker-barrier-sequence-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let terminalFIFO = directory.appending(path: "terminal")
        let outputURL = directory.appending(path: "renderer-output.log")
        try makeFIFOs(terminalFIFO)
        FileManager.default.createFile(atPath: outputURL.path, contents: Data())
        let output = try FileHandle(forWritingTo: outputURL)
        let renderer = Process()
        renderer.executableURL = URL(fileURLWithPath: "/bin/sh")
        renderer.arguments = [
            repositoryRoot.appending(
                path: "Integration/RemoteRocky/guest/input-marker-renderer.sh"
            ).path,
            "--self-test-barrier-sequence",
        ]
        renderer.standardOutput = output
        renderer.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["PERF_MARKER_SELF_TEST_TERMINAL_FIFO"] = terminalFIFO.path
        environment["PERF_MARKER_SELF_TEST_BARRIER_TIMEOUT_NS"] = "50000000"
        renderer.environment = environment
        try renderer.run()
        try output.close()
        defer {
            if renderer.isRunning {
                renderer.terminate()
                renderer.waitUntilExit()
            }
        }

        try waitForText(
            "PERF_MARKER_BARRIER_SEQUENCE phase=first result=rejected tainted=true",
            count: 1,
            in: outputURL
        )
        try waitForText(
            "PERF_MARKER_BARRIER_SEQUENCE phase=resync query=cpr",
            count: 1,
            in: outputURL
        )
        let terminal = try FileHandle(forWritingTo: terminalFIFO)
        defer { try? terminal.close() }
        let escape = "\u{1B}"

        // This is the exact response to the timed-out first DSR. The second
        // request is waiting for a different CPR grammar, so it must drain and
        // identify the stale response without drawing or accepting marker two.
        terminal.write(Data("\(escape)[0n".utf8))
        try waitForText(
            "PERF_MARKER_BARRIER_SEQUENCE phase=resync ignored=dsr",
            count: 1,
            in: outputURL
        )
        let afterStaleResponse = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(!afterStaleResponse.contains("phase=resync result=accepted"))
        #expect(!afterStaleResponse.contains("phase=second action=draw"))

        terminal.write(Data("\(escape)[1;1R".utf8))
        try waitForText(
            "PERF_MARKER_BARRIER_SEQUENCE phase=resync result=accepted tainted=false",
            count: 1,
            in: outputURL
        )
        try waitForText(
            "PERF_MARKER_BARRIER_SEQUENCE phase=second query=dsr",
            count: 1,
            in: outputURL
        )
        terminal.write(Data("\(escape)[0n".utf8))
        try waitForText(
            "PERF_MARKER_BARRIER_SEQUENCE phase=second action=ack",
            count: 1,
            in: outputURL
        )
        try waitForExit(renderer, within: .seconds(3))

        let lines = try String(contentsOf: outputURL, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(renderer.terminationStatus == 0)
        #expect(lines == [
            "PERF_MARKER_BARRIER_SEQUENCE phase=first query=dsr",
            "PERF_MARKER_BARRIER_SEQUENCE phase=first result=rejected tainted=true",
            "PERF_MARKER_BARRIER_SEQUENCE phase=resync query=cpr",
            "PERF_MARKER_BARRIER_SEQUENCE phase=resync ignored=dsr",
            "PERF_MARKER_BARRIER_SEQUENCE phase=resync result=accepted tainted=false",
            "PERF_MARKER_BARRIER_SEQUENCE phase=second action=draw",
            "PERF_MARKER_BARRIER_SEQUENCE phase=second query=dsr",
            "PERF_MARKER_BARRIER_SEQUENCE phase=second result=accepted tainted=false",
            "PERF_MARKER_BARRIER_SEQUENCE phase=second action=ack",
        ])
    }

    @Test func guestStartsPinnedEudevDiscoveryBeforeXorg() throws {
        let buildScript = try script("Integration/RemoteRocky/build-guest.sh")
        let startScript = try script("Integration/RemoteRocky/remote/start.sh")
        let guestInit = try script("Integration/RemoteRocky/guest/init")

        #expect(buildScript.contains("eudev=3.2.14-r5"))
        #expect(buildScript.contains("record_package eudev guest_eudev"))
        #expect(startScript.contains("guest_eudev"))

        let daemon = try #require(guestInit.range(of: "udevd --daemon"))
        let subsystemTrigger = try #require(guestInit.range(
            of: "udevadm trigger --action=add --type=subsystems"
        ))
        let deviceTrigger = try #require(guestInit.range(
            of: "udevadm trigger --action=add --type=devices"
        ))
        let settle = try #require(guestInit.range(of: "udevadm settle --timeout=10"))
        let xorg = try #require(guestInit.range(of: "Xorg :0"))
        #expect(daemon.lowerBound < subsystemTrigger.lowerBound)
        #expect(subsystemTrigger.lowerBound < deviceTrigger.lowerBound)
        #expect(deviceTrigger.lowerBound < settle.lowerBound)
        #expect(settle.lowerBound < xorg.lowerBound)

        let mdevCount = guestInit.components(separatedBy: "mdev -s").count - 1
        let virtioPortWait = try #require(guestInit.range(
            of: "while ! test -e /dev/virtio-ports"
        ))
        let lastMdev = try #require(guestInit.range(of: "mdev -s", options: .backwards))
        #expect(mdevCount == 2)
        #expect(virtioPortWait.lowerBound < lastMdev.lowerBound)
        #expect(lastMdev.lowerBound < xorg.lowerBound)
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

    @Test func failedStartDoesNotSignalAReusedLogFollowerPID() throws {
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

        let result = try fixture.run(
            "remote/start.sh",
            ssMode: "spice-only",
            additionalEnvironment: [
                "MOCK_REUSED_FOLLOWER_PID": "\(sleeper.processIdentifier)",
            ]
        )

        #expect(result.status != 0)
        #expect(result.output.contains("active state was removed"))
        #expect(fixture.stateFileExists("follower-pid-reused"))
        #expect(sleeper.isRunning)
        #expect(fixture.didStopContainer)
        #expect(!fixture.isContainerRunning)
        #expect(!fixture.containerExists)
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

    @Test func controlArmsOnlySupportedActionsWithCanonicalTokens() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        try fixture.prepareRunningState()

        let cases = [
            (actionClass: "click", token: "0000000000000001"),
            (actionClass: "key", token: "0000000000000002"),
            (actionClass: "motion", token: "0000000000000003"),
        ]
        for testCase in cases {
            let result = try fixture.run(
                "remote/control.sh",
                arguments: ["arm", testCase.actionClass, testCase.token],
                ssMode: "both"
            )
            #expect(result.status == 0)
            #expect(try fixture.lastControlInvocation().contains(
                "arm action_class=\(testCase.actionClass) token=\(testCase.token)"
            ))
        }
        #expect(try fixture.mockEventCount("control-exec") == cases.count)

        let invalidArguments = [
            ["arm", "tap", "0000000000000004"],
            ["arm", "click", "ABCDEF0123456789"],
            ["arm", "key", "000000000000005"],
            ["arm", "motion", "00000000000000006"],
            ["arm", "click", "000000000000000g"],
            ["arm", "click"],
        ]
        for arguments in invalidArguments {
            let result = try fixture.run(
                "remote/control.sh",
                arguments: arguments,
                ssMode: "both"
            )
            #expect(result.status != 0)
        }
        #expect(try fixture.mockEventCount("control-exec") == cases.count)
    }

    @Test func controlArmWaitsForExactGuestAcceptanceOrRejection() throws {
        let cases = [
            (
                result: "accepted",
                succeeds: true,
                expectedLine: "PERF_ARMED action_class=click token=0000000000000010"
            ),
            (
                result: "arm_outstanding",
                succeeds: false,
                expectedLine: "PERF_ARM_REJECTED action_class=click token=0000000000000010 reason=arm_outstanding"
            ),
            (
                result: "duplicate_token",
                succeeds: false,
                expectedLine: "PERF_ARM_REJECTED action_class=click token=0000000000000010 reason=duplicate_token"
            ),
        ]

        for testCase in cases {
            let fixture = try RemoteRockyFixture()
            defer { fixture.remove() }
            try fixture.prepareRunningState()

            let result = try fixture.run(
                "remote/control.sh",
                arguments: ["arm", "click", "0000000000000010"],
                ssMode: "both",
                additionalEnvironment: [
                    "MOCK_ARM_RESULT": testCase.result,
                    "MOCK_ARM_CRLF_NOISE": "1",
                ]
            )

            #expect((result.status == 0) == testCase.succeeds)
            #expect(result.output.contains(testCase.expectedLine))
            #expect(!result.output.contains("\r"))
            #expect(try fixture.mockEventCount("control-exec") == 1)
        }

        let timeoutFixture = try RemoteRockyFixture()
        defer { timeoutFixture.remove() }
        try timeoutFixture.prepareRunningState()
        let timeout = try timeoutFixture.run(
            "remote/control.sh",
            arguments: ["arm", "click", "0000000000000011"],
            ssMode: "both",
            additionalEnvironment: ["MOCK_ARM_RESULT": "timeout"]
        )
        #expect(timeout.status != 0)
        #expect(!timeout.output.contains("PERF_ARMED"))
        #expect(!timeout.output.contains("PERF_ARM_REJECTED"))
    }

    @Test func controlArmRetryCannotReuseADelayedPriorAcceptance() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        try fixture.prepareRunningState()
        let environment = [
            "MOCK_ARM_RETRY_RACE": "1",
            "PERF_CONTROL_WAIT_ATTEMPTS": "1",
        ]
        let arguments = ["arm", "click", "0000000000000012"]

        let timedOut = try fixture.run(
            "remote/control.sh",
            arguments: arguments,
            ssMode: "both",
            additionalEnvironment: environment
        )
        #expect(timedOut.status != 0)
        #expect(timedOut.output.contains(
            "PERF_ARM_ERROR action_class=click token=0000000000000012 reason=timeout"
        ))
        #expect(!timedOut.output.contains("PERF_ARMED"))

        let retry = try fixture.run(
            "remote/control.sh",
            arguments: arguments,
            ssMode: "both",
            additionalEnvironment: environment
        )
        #expect(retry.status != 0)
        #expect(retry.output.contains(
            "PERF_ARM_REJECTED action_class=click token=0000000000000012 reason=duplicate_token"
        ))
        #expect(!retry.output.contains("PERF_ARMED"))
        #expect(try fixture.mockEventCount("control-sync") == 2)
        #expect(try fixture.mockEventCount("control-exec") == 2)
    }

    @Test func concurrentHostArmsSerializeAroundOneGuestPendingSlot() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        try fixture.prepareRunningState()
        let environment = [
            "MOCK_ARM_STATEFUL": "1",
            "MOCK_ARM_CRLF_NOISE": "1",
        ]

        let first = try fixture.launch(
            "remote/control.sh",
            arguments: ["arm", "click", "0000000000000020"],
            ssMode: "both",
            additionalEnvironment: environment
        )
        let second = try fixture.launch(
            "remote/control.sh",
            arguments: ["arm", "click", "0000000000000021"],
            ssMode: "both",
            additionalEnvironment: environment
        )
        let results = [first.finish(), second.finish()]

        #expect(results.filter { $0.status == 0 }.count == 1)
        #expect(results.filter { $0.status != 0 }.count == 1)
        let combinedOutput = results.map(\.output).joined(separator: "\n")
        #expect(combinedOutput.contains("PERF_ARMED action_class=click"))
        #expect(combinedOutput.contains(
            "PERF_ARM_REJECTED action_class=click"
        ))
        #expect(combinedOutput.contains("reason=arm_outstanding"))
        #expect(!combinedOutput.contains("\r"))
        #expect(try fixture.mockEventCount("control-exec") == 2)
    }

    @Test func controlDiagnosesGuestInputWithNoAdditionalArguments() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        try fixture.prepareRunningState()

        let diagnosis = try fixture.run(
            "remote/control.sh",
            arguments: ["diagnose-input"],
            ssMode: "both"
        )
        #expect(diagnosis.status == 0)
        let invocation = try fixture.lastControlInvocation()
        #expect(invocation.contains("'diagnose-input'"))
        #expect(try fixture.mockEventCount("control-exec") == 1)

        let guestInit = try script("Integration/RemoteRocky/guest/init")
        let diagnosisCase = try #require(guestInit.range(of: "diagnose-input)"))
        let diagnosisScript = try #require(guestInit.range(
            of: "/usr/local/bin/input-diagnostics.sh",
            range: diagnosisCase.upperBound..<guestInit.endIndex
        ))
        #expect(diagnosisCase.lowerBound < diagnosisScript.lowerBound)

        let extraArgument = try fixture.run(
            "remote/control.sh",
            arguments: ["diagnose-input", "unexpected"],
            ssMode: "both"
        )
        #expect(extraArgument.status != 0)
        #expect(try fixture.mockEventCount("control-exec") == 1)
    }

    @Test func controlReturnsTheCompleteLatestInputDiagnosisBlock() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }
        try fixture.prepareRunningState()

        let diagnosisLines = [
            "PERF_INPUT_DIAGNOSTIC_BEGIN",
            "PERF_INPUT_DIAGNOSTIC source=xinput text=device-01",
            "PERF_INPUT_DIAGNOSTIC source=xinput text=device-02",
            "PERF_INPUT_DIAGNOSTIC source=xinput text=device-03",
            "PERF_INPUT_DIAGNOSTIC source=xinput text=device-04",
            "PERF_INPUT_DIAGNOSTIC source=xinput text=device-05",
            "PERF_INPUT_DIAGNOSTIC source=xinput text=device-06",
            "PERF_INPUT_DIAGNOSTIC source=xinput text=device-07",
            "PERF_INPUT_DIAGNOSTIC source=xinput text=device-08",
            "PERF_INPUT_DIAGNOSTIC source=xorg text=libinput-keyboard",
            "PERF_INPUT_DIAGNOSTIC source=xorg text=libinput-pointer",
            "PERF_INPUT_DIAGNOSTIC source=proc_input text=N: Name=QEMU keyboard",
            "PERF_INPUT_DIAGNOSTIC source=proc_input text=H: Handlers=kbd event0",
            "PERF_INPUT_DIAGNOSTIC source=proc_input text=N: Name=spice tablet",
            "PERF_INPUT_DIAGNOSTIC source=proc_input text=H: Handlers=mouse0 event2",
            "PERF_INPUT_DIAGNOSTIC_END",
        ]
        let containerLog = fixture.mockState.appending(path: "container.log")
        let logLines = ["older unrelated output"] + diagnosisLines
        try Data((logLines.joined(separator: "\r\n") + "\r\n").utf8).write(to: containerLog)

        let result = try fixture.run(
            "remote/control.sh",
            arguments: ["diagnose-input"],
            ssMode: "both",
            additionalEnvironment: ["MOCK_CONTAINER_LOG_FILE": containerLog.path]
        )

        #expect(result.status == 0)
        #expect(!result.output.contains("\r"))
        let outputLines = result.output.split(separator: "\n").map(String.init)
        #expect(outputLines == diagnosisLines)
        let beginCount = result.output.components(
            separatedBy: "PERF_INPUT_DIAGNOSTIC_BEGIN"
        ).count - 1
        let endCount = result.output.components(
            separatedBy: "PERF_INPUT_DIAGNOSTIC_END"
        ).count - 1
        #expect(beginCount == 1)
        #expect(endCount == 1)
    }

    @Test func guestInputDiagnosisFramesEveryDeviceLineAndOnlyRelevantXorgLines() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "guest-input-diagnostics-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let xinputLines = [
            "Virtual core pointer id=2 [master pointer (3)]",
            "Virtual core keyboard id=3 [master keyboard (2)]",
        ]
        let relevantXorgLines = [
            "[ 1.000] (II) config/udev: Adding input device QEMU USB Tablet",
            "[ 1.001] (II) libinput: AT Translated Set 2 keyboard initialized",
        ]
        let irrelevantXorgLine = "[ 1.002] (II) modeset(0): Output HDMI-1 enabled"
        let inputDeviceLines = [
            "N: Name=\"QEMU Virtio Keyboard\"",
            "H: Handlers=sysrq kbd event0",
            "N: Name=\"spice tablet\"",
            "H: Handlers=mouse0 event2",
        ]
        let irrelevantInputDeviceLine = "B: EV=120013"
        let xinput = directory.appending(path: "xinput.txt")
        let xorg = directory.appending(path: "Xorg.0.log")
        let inputDevices = directory.appending(path: "input-devices.txt")
        try Data((xinputLines.joined(separator: "\n") + "\n").utf8).write(to: xinput)
        let xorgContents = (relevantXorgLines + [irrelevantXorgLine]).joined(separator: "\n") + "\n"
        try Data(xorgContents.utf8).write(to: xorg)
        let inputDeviceContents = (inputDeviceLines + [irrelevantInputDeviceLine])
            .joined(separator: "\n") + "\n"
        try Data(inputDeviceContents.utf8).write(to: inputDevices)

        let result = try runGuestScript(
            "input-diagnostics.sh",
            environment: [
                "PERF_XINPUT_LIST_FILE": xinput.path,
                "PERF_XORG_LOG": xorg.path,
                "PERF_INPUT_DEVICES_FILE": inputDevices.path,
                "TMPDIR": directory.path,
            ]
        )

        #expect(result.status == 0)
        let lines = result.output.split(separator: "\n").map(String.init)
        let expected = ["PERF_INPUT_DIAGNOSTIC_BEGIN"]
            + xinputLines.map { "PERF_INPUT_DIAGNOSTIC source=xinput text=\($0)" }
            + relevantXorgLines.map { "PERF_INPUT_DIAGNOSTIC source=xorg text=\($0)" }
            + inputDeviceLines.map { "PERF_INPUT_DIAGNOSTIC source=proc_input text=\($0)" }
            + ["PERF_INPUT_DIAGNOSTIC_END"]
        #expect(lines == expected)
        #expect(!result.output.contains(irrelevantXorgLine))
        #expect(!result.output.contains(irrelevantInputDeviceLine))
    }

    @Test func guestInputDiagnosisSafelyFramesEmptyAndMissingEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "guest-input-diagnostics-empty-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let emptyXinput = directory.appending(path: "empty-xinput.txt")
        let emptyXorg = directory.appending(path: "empty-Xorg.0.log")
        let emptyInputDevices = directory.appending(path: "empty-input-devices.txt")
        try Data().write(to: emptyXinput)
        try Data().write(to: emptyXorg)
        try Data().write(to: emptyInputDevices)

        let cases = [
            (
                xinput: emptyXinput.path,
                xorg: emptyXorg.path,
                inputDevices: emptyInputDevices.path,
                expected: [
                    "PERF_INPUT_DIAGNOSTIC_BEGIN",
                    "PERF_INPUT_DIAGNOSTIC source=xinput text=<empty>",
                    "PERF_INPUT_DIAGNOSTIC source=xorg text=<empty>",
                    "PERF_INPUT_DIAGNOSTIC source=proc_input text=<empty>",
                    "PERF_INPUT_DIAGNOSTIC_END",
                ]
            ),
            (
                xinput: directory.appending(path: "missing-xinput.txt").path,
                xorg: directory.appending(path: "missing-Xorg.0.log").path,
                inputDevices: directory.appending(path: "missing-input-devices.txt").path,
                expected: [
                    "PERF_INPUT_DIAGNOSTIC_BEGIN",
                    "PERF_INPUT_DIAGNOSTIC source=xinput text=<missing>",
                    "PERF_INPUT_DIAGNOSTIC source=xorg text=<missing>",
                    "PERF_INPUT_DIAGNOSTIC source=proc_input text=<missing>",
                    "PERF_INPUT_DIAGNOSTIC_END",
                ]
            ),
        ]

        for testCase in cases {
            let result = try runGuestScript(
                "input-diagnostics.sh",
                environment: [
                    "PERF_XINPUT_LIST_FILE": testCase.xinput,
                    "PERF_XORG_LOG": testCase.xorg,
                    "PERF_INPUT_DEVICES_FILE": testCase.inputDevices,
                    "TMPDIR": directory.path,
                ]
            )
            #expect(result.status == 0)
            let lines = result.output.split(separator: "\n").map(String.init)
            #expect(lines == testCase.expected)
        }
    }

    @Test func guestInputMonitorCoalescesRawAndDeliveredXI2Counterparts() throws {
        let events = [
            "EVENT type 13 (RawKeyPress)",
            "    detail: 38",
            "    time: 1000",
            "EVENT type 2 (KeyPress)",
            "    detail: 38",
            "    time: 1000",
            "EVENT type 13 (RawKeyPress)",
            "    detail: 39",
            "    time: 1001",
            "EVENT type 2 (KeyPress)",
            "    detail: 39",
            "    time: 1001",
            "EVENT type 15 (RawButtonPress)",
            "    detail: 1",
            "    time: 1002",
            "EVENT type 4 (ButtonPress)",
            "    detail: 1",
            "    time: 1002",
            "EVENT type 17 (RawMotion)",
            "    time: 1003",
            "EVENT type 6 (Motion)",
            "    time: 1003",
            "EVENT type 14 (RawKeyRelease)",
            "EVENT type 11 (HierarchyChanged)",
            "    device: 2 (Virtual core pointer)",
        ]
        let input = events.joined(separator: "\n") + "\n"
        let result = try runGuestScript(
            "input-marker-monitor.sh",
            arguments: ["--self-test-events"],
            standardInput: input
        )

        #expect(result.status == 0)
        let matches = result.output.split(separator: "\n").map(String.init)
        #expect(matches == [
            "PERF_INPUT_MATCH action_class=key",
            "PERF_INPUT_MATCH action_class=key",
            "PERF_INPUT_MATCH action_class=click",
            "PERF_INPUT_MATCH action_class=motion",
        ])
    }

    @Test func guestInputMonitorDrainsMotionWhileTheMarkerAgentIsBlocked() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "guest-input-motion-burst-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let agent = directory.appending(path: "agent-stub.sh")
        try writeExecutable(agent, contents: #"""
        #!/bin/sh
        set -eu
        state="${PERF_MARKER_MONITOR_STATE_DIR:?}"
        printf '%s\n' "$*" >> "${state}/agent-calls"
        calls="$(wc -l < "${state}/agent-calls" | tr -d ' ')"
        if test "${calls}" = 1; then
            : > "${state}/first-agent-entered"
            while ! test -e "${state}/release-first-agent"; do
                sleep 0.01
            done
            : > "${state}/first-agent-finished"
        else
            : > "${state}/second-agent-entered"
        fi
        """#)

        let outputURL = directory.appending(path: "monitor-output.log")
        FileManager.default.createFile(atPath: outputURL.path, contents: Data())
        let output = try FileHandle(forWritingTo: outputURL)
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            repositoryRoot.appending(
                path: "Integration/RemoteRocky/guest/input-marker-monitor.sh"
            ).path,
            "--self-test-motion-burst",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["PERF_MARKER_AGENT_COMMAND"] = agent.path
        environment["PERF_MARKER_MONITOR_STATE_DIR"] = directory.path
        let beforeRead = directory.appending(path: "before-read")
        environment["PERF_MARKER_MONITOR_BEFORE_READ_FILE"] = beforeRead.path
        process.environment = environment

        try process.run()
        try output.close()
        let writer = input.fileHandleForWriting
        writer.write(Data("EVENT type 17 (RawMotion)\n".utf8))
        try waitForPath(beforeRead.appendingPathExtension("entered.1"))
        try Data().write(to: beforeRead.appendingPathExtension("release.1"))
        try waitForPath(directory.appending(path: "first-agent-entered"))

        let burstCount = 32
        let burst = Array(repeating: "EVENT type 17 (RawMotion)", count: burstCount)
            .joined(separator: "\n") + "\n"
        writer.write(Data(burst.utf8))

        // The first stale RawMotion is already in the event pipe, but its reader
        // is held. Complete the worker first to exercise the race where a naive
        // active flag would clear before the old pipe backlog is drained.
        try waitForPath(beforeRead.appendingPathExtension("entered.2"))
        try Data().write(to: directory.appending(path: "release-first-agent"))
        try waitForPath(directory.appending(path: "first-agent-finished"))

        for index in 2...(burstCount + 1) {
            try waitForPath(beforeRead.appendingPathExtension("entered.\(index)"))
            try Data().write(to: beforeRead.appendingPathExtension("release.\(index)"))
        }
        try writer.close()
        try waitForText(
            "PERF_INPUT_COALESCED action_class=motion",
            count: burstCount,
            in: outputURL
        )
        try waitForExit(process, within: .seconds(3))
        let calls = try String(
            contentsOf: directory.appending(path: "agent-calls"),
            encoding: .utf8
        ).split(separator: "\n").map(String.init)
        let monitorOutput = try String(contentsOf: outputURL, encoding: .utf8)

        #expect(process.terminationStatus == 0)
        #expect(calls == ["input motion"])
        #expect(monitorOutput.components(
            separatedBy: "PERF_INPUT_COALESCED action_class=motion"
        ).count - 1 == burstCount)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "second-agent-entered").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appending(path: "motion-active").path
        ))
    }

    @Test func inputCheckpointRotatesTheXI2SourceBeforeOpeningTheNextEpoch() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "guest-input-source-epoch-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = directory.appending(path: "monitor-state", directoryHint: .isDirectory)
        #expect(!FileManager.default.fileExists(atPath: state.path))

        let agent = directory.appending(path: "agent-stub.sh")
        try writeExecutable(agent, contents: #"""
        #!/bin/sh
        set -eu
        state="${PERF_MARKER_MONITOR_STATE_DIR:?}"
        printf '%s\n' "$*" >> "${state}/agent-calls"
        calls="$(wc -l < "${state}/agent-calls" | tr -d ' ')"
        : > "${state}/agent-call-${calls}"
        """#)
        let source = directory.appending(path: "source-stub.sh")
        try writeExecutable(source, contents: #"""
        #!/bin/sh
        set -eu
        generation="${1:?}"
        ready_path="${2:?}"
        state="${PERF_MARKER_MONITOR_STATE_DIR:?}"
        if test "${generation}" = 1; then
            trap 'printf "%s\n" "EVENT type 17 (RawMotion)"; : > "${state}/old-motion-emitted"; exit 0' TERM
            : > "${state}/source-${generation}-started"
            : > "${ready_path}"
            while true; do sleep 0.01; done
        fi
        trap 'exit 0' TERM
        : > "${state}/source-${generation}-started"
        : > "${ready_path}"
        while ! test -e "${state}/release-new-motion"; do sleep 0.01; done
        printf '%s\n' 'EVENT type 17 (RawMotion)'
        : > "${state}/new-motion-emitted"
        while true; do sleep 0.01; done
        """#)

        let monitorOutputURL = directory.appending(path: "monitor-output.log")
        FileManager.default.createFile(atPath: monitorOutputURL.path, contents: Data())
        let monitorOutput = try FileHandle(forWritingTo: monitorOutputURL)
        let monitor = Process()
        monitor.executableURL = URL(fileURLWithPath: "/bin/sh")
        monitor.arguments = [repositoryRoot.appending(
            path: "Integration/RemoteRocky/guest/input-marker-monitor.sh"
        ).path]
        monitor.standardOutput = monitorOutput
        monitor.standardError = monitorOutput
        var environment = ProcessInfo.processInfo.environment
        environment["PERF_MARKER_AGENT_COMMAND"] = agent.path
        environment["PERF_MARKER_EVENT_SOURCE_COMMAND"] = source.path
        environment["PERF_MARKER_MONITOR_STATE_DIR"] = state.path
        let sourceReadyGate = directory.appending(path: "source-ready")
        environment["PERF_MARKER_MONITOR_BEFORE_SOURCE_READY_FILE"] = sourceReadyGate.path
        monitor.environment = environment

        let invocation = "00000000000000000000000000000002"
        let checkpoint = Process()
        let checkpointOutput = Pipe()
        checkpoint.executableURL = URL(fileURLWithPath: "/bin/sh")
        checkpoint.arguments = [
            repositoryRoot.appending(
                path: "Integration/RemoteRocky/guest/input-marker-monitor.sh"
            ).path,
            "checkpoint",
            invocation,
        ]
        checkpoint.standardOutput = checkpointOutput
        checkpoint.standardError = checkpointOutput
        checkpoint.environment = environment
        try checkpoint.run()
        defer {
            if checkpoint.isRunning {
                checkpoint.terminate()
                checkpoint.waitUntilExit()
            }
        }

        // A checkpoint may race the first monitor startup before its state
        // root exists. It must remain pending instead of failing while it
        // waits for the initial event-source subscription.
        Thread.sleep(forTimeInterval: 0.1)
        #expect(checkpoint.isRunning)

        try monitor.run()
        try monitorOutput.close()
        defer {
            if monitor.isRunning {
                monitor.terminate()
                monitor.waitUntilExit()
            }
        }

        // The checkpoint begins immediately, before generation one publishes
        // readiness. It must wait rather than hitting the shell's default USR1
        // action or losing a rotate request against an uninitialized source.
        try waitForPath(sourceReadyGate.appendingPathExtension("entered.1"))
        #expect(checkpoint.isRunning)
        try Data().write(to: sourceReadyGate.appendingPathExtension("release.1"))
        try waitForPath(state.appending(path: "old-motion-emitted"))

        // Generation two must establish its subscription endpoint before the
        // worker publishes the checkpoint ACK that permits the host to arm.
        try waitForPath(sourceReadyGate.appendingPathExtension("entered.2"))
        #expect(checkpoint.isRunning)
        try Data().write(to: sourceReadyGate.appendingPathExtension("release.2"))
        let checkpointResult = try RunningScript(
            process: checkpoint,
            output: checkpointOutput
        ).finish(within: .seconds(3))

        #expect(checkpointResult.status == 0)
        #expect(FileManager.default.fileExists(
            atPath: state.appending(path: "old-motion-emitted").path
        ))
        #expect(FileManager.default.fileExists(
            atPath: state.appending(path: "source-2-started").path
        ))
        try waitForPath(state.appending(path: "agent-call-1"))
        let callsAtEpochBoundary = try String(
            contentsOf: state.appending(path: "agent-calls"),
            encoding: .utf8
        ).split(separator: "\n")
        #expect(callsAtEpochBoundary.count == 1)

        try Data().write(to: state.appending(path: "release-new-motion"))
        try waitForPath(state.appending(path: "agent-call-2"))
        let finalCalls = try String(
            contentsOf: state.appending(path: "agent-calls"),
            encoding: .utf8
        ).split(separator: "\n").map(String.init)
        #expect(finalCalls == ["input motion", "input motion"])

        monitor.terminate()
        try waitForExit(monitor, within: .seconds(3))
    }

    @Test func inputCheckpointRejectsAStaleUnrelatedMonitorPIDWithoutSignalingIt() throws {
        let state = FileManager.default.temporaryDirectory.appending(
            path: "guest-input-stale-monitor-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        try makeFIFOs(state.appending(path: "events"))

        // SIGUSR1 has a terminating default action, so this unrelated sleeper
        // detects both an unsafe signal and PID-reuse identity confusion.
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer {
            if sleeper.isRunning {
                sleeper.terminate()
            }
            sleeper.waitUntilExit()
        }
        try Data("\(sleeper.processIdentifier)\n".utf8).write(
            to: state.appending(path: "monitor-pid")
        )

        let checkpoint = Process()
        let output = Pipe()
        checkpoint.executableURL = URL(fileURLWithPath: "/bin/sh")
        checkpoint.arguments = [
            repositoryRoot.appending(
                path: "Integration/RemoteRocky/guest/input-marker-monitor.sh"
            ).path,
            "checkpoint",
            "00000000000000000000000000000003",
        ]
        checkpoint.standardOutput = output
        checkpoint.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["PERF_MARKER_MONITOR_STATE_DIR"] = state.path
        environment["PERF_MARKER_MONITOR_CHECKPOINT_ATTEMPTS"] = "10"
        checkpoint.environment = environment
        try checkpoint.run()
        let result = try RunningScript(process: checkpoint, output: output).finish(
            within: .seconds(2)
        )

        #expect(result.status != 0)
        #expect(sleeper.isRunning)
        #expect(!FileManager.default.fileExists(
            atPath: state.appending(path: "checkpoint-active").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: state.appending(path: "checkpoint-request").path
        ))
    }

    @Test func guestMarkerClockUsesAHighResolutionMonotonicSource() throws {
        let state = FileManager.default.temporaryDirectory.appending(
            path: "guest-marker-clock-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }
        let clockSourceURL = repositoryRoot.appending(
            path: "Integration/RemoteRocky/guest/monotonic-nanoseconds.c"
        )
        let clockExecutable = state.appending(path: "monotonic-nanoseconds")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [
            "-std=c11", "-Wall", "-Wextra", "-Werror",
            clockSourceURL.path, "-o", clockExecutable.path,
        ]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)

        let result = try runGuestScript(
            "input-marker-agent.sh",
            arguments: ["--self-test-clock", "64"],
            environment: [
                "PERF_MARKER_STATE_DIR": state.path,
                "PERF_MARKER_CLOCK_COMMAND": clockExecutable.path,
            ]
        )
        #expect(result.status == 0)

        let samples = perfRecords(prefix: "PERF_MARKER_CLOCK", in: result.output)
            .compactMap { record in
                record["monotonic_ns"].flatMap(UInt64.init)
            }
        #expect(samples.count == 64)
        let deltas: [UInt64] = zip(samples, samples.dropFirst()).compactMap { earlier, later in
            guard later >= earlier else { return nil }
            return later - earlier
        }
        #expect(deltas.count == 63)
        #expect(deltas.contains { $0 > 0 && $0 < 10_000_000 })
        #expect(Set(samples.map { $0 % 10_000_000 }).count > 1)

        let clockSource = try String(contentsOf: clockSourceURL, encoding: .utf8)
        let buildScript = try script("Integration/RemoteRocky/build-guest.sh")
        let startScript = try script("Integration/RemoteRocky/remote/start.sh")
        #expect(clockSource.contains("clock_gettime(CLOCK_MONOTONIC"))
        #expect(buildScript.contains("monotonic-nanoseconds.c"))
        #expect(buildScript.contains("guest_marker_clock=clock_gettime-monotonic-v1"))
        #expect(startScript.contains("guest_marker_clock"))
    }

    @Test func guestMarkerConsumesOnlyTheNextMatchingInputAndRendersItsToken() throws {
        let result = try runGuestMarkerSelfTest([
            "arm action_class=click token=0000000000000001",
            "input action_class=key guest_ns=90",
            "input action_class=click guest_ns=100",
            "input action_class=click guest_ns=110",
        ])

        #expect(result.status == 0)
        let traces = perfRecords(prefix: "PERF_TRACE", in: result.output)
        #expect(traces.count == 2)
        #expect(traces.map { $0["event"] } == ["guest_received", "marker_drawn"])
        #expect(traces.allSatisfy { $0["action_class"] == "click" })
        #expect(traces.allSatisfy { $0["token"] == "0000000000000001" })
        #expect(traces.first?["guest_ns"] == "100")
        #expect(traces.first?["marker_revision"] == traces.last?["marker_revision"])

        let renderRecords = perfRecords(prefix: "PERF_MARKER_RENDER", in: result.output)
        #expect(renderRecords.count == 1)
        let render = try #require(renderRecords.first)
        #expect(render["token"] == "0000000000000001")
        #expect(render["marker_revision"] == traces.first?["marker_revision"])
        #expect(render["checksum"] == "665e9948")
        #expect(render["foreground"] == "000000")
        #expect(render["background"] == "ffffff")
    }

    @Test func guestMarkerAcknowledgmentIsBoundedAndReleasesItsStateLock() throws {
        let timeout = try runGuestMarkerFIFOHandshake(acknowledgedRevision: nil)
        #expect(timeout.input.status != 0)
        #expect(timeout.input.output.contains("PERF_ERROR input_marker=marker_ack_timeout"))
        #expect(!timeout.input.output.contains("event=marker_drawn"))
        #expect(timeout.request.contains("marker_revision=1"))
        #expect(timeout.rearm.status == 0)
        #expect(timeout.rearm.output.contains(
            "PERF_ARMED action_class=key token=0000000000000002"
        ))

        let acknowledged = try runGuestMarkerFIFOHandshake(acknowledgedRevision: "1")
        #expect(acknowledged.input.status == 0)
        let acknowledgedTraces = perfRecords(prefix: "PERF_TRACE", in: acknowledged.input.output)
        #expect(acknowledgedTraces.map { $0["event"] } == [
            "guest_received", "marker_drawn",
        ])
        #expect(acknowledgedTraces.allSatisfy { $0["marker_revision"] == "1" })
        #expect(!acknowledged.input.output.contains("PERF_ERROR"))
        #expect(acknowledged.rearm.status == 0)

        let mismatched = try runGuestMarkerFIFOHandshake(acknowledgedRevision: "99")
        #expect(mismatched.input.status != 0)
        #expect(mismatched.input.output.contains("PERF_ERROR input_marker=marker_ack_mismatch"))
        #expect(!mismatched.input.output.contains("event=marker_drawn"))
        #expect(mismatched.rearm.status == 0)
    }

    @Test func guestMarkerRequestPublicationIsBoundedWithoutARenderer() throws {
        let state = FileManager.default.temporaryDirectory.appending(
            path: "guest-marker-no-renderer-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }

        let requestFIFO = state.appending(path: "request")
        let acknowledgmentFIFO = state.appending(path: "ack")
        try makeFIFOs(requestFIFO, acknowledgmentFIFO)
        let arm = try runGuestMarkerCommand(
            ["arm", "click", "0000000000000001"],
            state: state
        )
        try #require(arm.status == 0)

        let input = try launchGuestMarkerCommand(
            ["input", "click", "100", "101"],
            state: state,
            additionalEnvironment: [
                "PERF_MARKER_TEST_MODE": "0",
                "PERF_MARKER_REQUEST_FIFO": requestFIFO.path,
                "PERF_MARKER_ACK_FIFO": acknowledgmentFIFO.path,
                "PERF_MARKER_ACK_TIMEOUT_SECONDS": "1",
            ]
        ).finish(within: .seconds(3))

        #expect(input.status != 0)
        #expect(input.output.contains("PERF_ERROR input_marker=marker_ack_timeout"))
        #expect(!input.output.contains("event=marker_drawn"))
        #expect(!FileManager.default.fileExists(atPath: state.appending(path: "lock").path))

        let rearm = try runGuestMarkerCommand(
            ["arm", "key", "0000000000000002"],
            state: state
        )
        #expect(rearm.status == 0)
        #expect(rearm.output.contains(
            "PERF_ARMED action_class=key token=0000000000000002"
        ))
    }

    @Test func lateMarkerAcknowledgmentCannotValidateANewerRevision() throws {
        let agent = try script("Integration/RemoteRocky/guest/input-marker-agent.sh")
        let renderer = try script("Integration/RemoteRocky/guest/input-marker-renderer.sh")
        #expect(agent.contains(#"ack_timeout_seconds="${PERF_MARKER_ACK_TIMEOUT_SECONDS:-2}""#))
        #expect(renderer.contains("barrier_timeout_ns=500000000"))

        let state = FileManager.default.temporaryDirectory.appending(
            path: "guest-marker-stale-ack-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }

        let requestFIFO = state.appending(path: "request")
        let acknowledgmentFIFO = state.appending(path: "ack")
        let releaseStale = state.appending(path: "release-stale")
        let staleWritten = state.appending(path: "stale-written")
        try makeFIFOs(requestFIFO, acknowledgmentFIFO)
        let responder = try launchStaleMarkerAcknowledgmentStub(
            requestFIFO: requestFIFO,
            acknowledgmentFIFO: acknowledgmentFIFO,
            releaseStale: releaseStale,
            staleWritten: staleWritten
        )
        defer {
            if responder.process.isRunning {
                responder.terminate()
                responder.process.waitUntilExit()
            }
        }

        let environment = [
            "PERF_MARKER_TEST_MODE": "0",
            "PERF_MARKER_REQUEST_FIFO": requestFIFO.path,
            "PERF_MARKER_ACK_FIFO": acknowledgmentFIFO.path,
            "PERF_MARKER_ACK_TIMEOUT_SECONDS": "1",
        ]

        let firstArm = try runGuestMarkerCommand(
            ["arm", "click", "0000000000000001"],
            state: state
        )
        try #require(firstArm.status == 0)
        let timedOut = try launchGuestMarkerCommand(
            ["input", "click", "100", "101"],
            state: state,
            additionalEnvironment: environment
        ).finish(within: .seconds(3))
        #expect(timedOut.status != 0)
        #expect(timedOut.output.contains("PERF_ERROR input_marker=marker_ack_timeout"))
        #expect(!timedOut.output.contains("event=marker_drawn"))

        try Data().write(to: releaseStale)
        try waitForPath(staleWritten)
        let secondArm = try runGuestMarkerCommand(
            ["arm", "key", "0000000000000002"],
            state: state
        )
        try #require(secondArm.status == 0)
        let staleIgnored = try launchGuestMarkerCommand(
            ["input", "key", "200", "201"],
            state: state,
            additionalEnvironment: environment
        ).finish(within: .seconds(3))
        #expect(staleIgnored.status == 0)
        let recoveredTraces = perfRecords(prefix: "PERF_TRACE", in: staleIgnored.output)
        #expect(recoveredTraces.map { $0["event"] } == [
            "guest_received", "marker_drawn",
        ])
        #expect(recoveredTraces.allSatisfy { $0["marker_revision"] == "2" })
        #expect(!staleIgnored.output.contains("PERF_ERROR"))

        let requests = try responder.finish(within: .seconds(3)).output
        #expect(requests.contains("marker_revision=1"))
        #expect(requests.contains("marker_revision=2"))
        #expect(!FileManager.default.fileExists(atPath: state.appending(path: "lock").path))
    }

    @Test func guestMarkerRejectsInvalidConcurrentAndReusedArmsDeterministically() throws {
        let result = try runGuestMarkerSelfTest([
            "arm action_class=click token=0000000000000001",
            "arm action_class=key token=0000000000000002",
            "input action_class=motion guest_ns=90",
            "input action_class=click guest_ns=100",
            "arm action_class=motion token=0000000000000001",
            "arm action_class=tap token=0000000000000003",
            "arm action_class=key token=ABCDEF0123456789",
            "arm action_class=key token=0000000000000002",
            "input action_class=key guest_ns=200",
        ])

        #expect(result.status == 0)
        let traces = perfRecords(prefix: "PERF_TRACE", in: result.output)
        #expect(traces.count == 4)
        #expect(traces.map { $0["token"] } == [
            "0000000000000001", "0000000000000001",
            "0000000000000002", "0000000000000002",
        ])
        #expect(traces.map { $0["marker_revision"] } == ["1", "1", "2", "2"])

        let errors = result.output.split(separator: "\n").filter {
            $0.hasPrefix("PERF_ERROR")
        }
        #expect(errors.count == 2)
        #expect(errors.contains("PERF_ERROR input_marker=invalid_action_class"))
        #expect(errors.contains("PERF_ERROR input_marker=invalid_token"))
        let rejected = result.output.split(separator: "\n").filter {
            $0.hasPrefix("PERF_ARM_REJECTED")
        }
        #expect(rejected == [
            "PERF_ARM_REJECTED action_class=key token=0000000000000002 reason=arm_outstanding",
            "PERF_ARM_REJECTED action_class=motion token=0000000000000001 reason=duplicate_token",
        ])

        let renders = perfRecords(prefix: "PERF_MARKER_RENDER", in: result.output)
        #expect(renders.map { $0["checksum"] } == ["665e9948", "000f6f4a"])
        #expect(renders.allSatisfy {
            $0["foreground"] == "000000" && $0["background"] == "ffffff"
        })
    }

    @Test func guestMarkerSignalsReleaseTheLockBeforeAnyMutation() throws {
        let signals = [SIGHUP, SIGTERM]
        for (index, signal) in signals.enumerated() {
            let state = FileManager.default.temporaryDirectory.appending(
                path: "guest-marker-signal-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
            try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: state) }

            let hold = state.appending(path: "hold")
            let token = String(format: "%016x", index + 4)
            let running = try launchGuestMarkerCommand(
                ["arm", "click", token],
                state: state,
                additionalEnvironment: ["PERF_MARKER_HOLD_AFTER_LOCK_FILE": hold.path]
            )
            defer {
                if running.process.isRunning {
                    _ = Darwin.kill(running.process.processIdentifier, SIGKILL)
                    running.process.waitUntilExit()
                }
            }

            try waitForPath(hold.appendingPathExtension("entered"))
            #expect(Darwin.kill(running.process.processIdentifier, signal) == 0)
            let interrupted = try running.finish(within: .seconds(3))

            #expect(interrupted.status != 0)
            #expect(!interrupted.output.contains("PERF_ARMED"))
            #expect(!interrupted.output.contains("PERF_TRACE"))
            #expect(!interrupted.output.contains("PERF_MARKER_RENDER"))
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "lock").path))
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "armed").path))
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "used-tokens").path))
            #expect(!FileManager.default.fileExists(atPath: state.appending(path: "marker-revision").path))

            let retry = try runGuestMarkerCommand(["arm", "click", token], state: state)
            #expect(retry.status == 0)
            #expect(retry.output.contains("PERF_ARMED action_class=click token=\(token)"))
        }
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

    @Test func successfulStartCreatesAPrivateCanonicalInputTraceArtifact() throws {
        let fixture = try RemoteRockyFixture()
        defer { fixture.remove() }

        let result = try fixture.run("remote/start.sh", ssMode: "both")
        #expect(result.status == 0)
        let runID = try fixture.currentRunID()
        let trace = fixture.base.appending(path: "logs/\(runID)/input-events.jsonl")
        let configuration = try String(
            contentsOf: fixture.base.appending(path: "logs/\(runID)/configuration.txt"),
            encoding: .utf8
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: trace.path)
        let traceData = try Data(contentsOf: trace)

        #expect(FileManager.default.fileExists(atPath: trace.path))
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect(traceData.isEmpty)
        #expect(configuration.contains("interaction_trace_path=\(trace.path)"))
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
        try fixture.waitForMockStateRemoval("log-follower-active")
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
        try fixture.waitForMockStateRemoval("log-follower-active")
        let firstTicket = try fixture.ticket()
        #expect(firstTicket.range(of: "^[0-9a-f]{48}$", options: .regularExpression) != nil)
        #expect(try fixture.ticketPermissions() == 0o600)
        #expect(!fixture.evidenceOrArgumentsContain(firstTicket))

        let firstStop = try fixture.run("remote/stop.sh", ssMode: "both")
        #expect(firstStop.status == 0)
        #expect(!fixture.stateFileExists("log-follower-active"))
        #expect(!fixture.stateFileExists("ticket"))
        #expect(!fixture.evidenceOrArgumentsContain(firstTicket))

        let secondStart = try fixture.run("remote/start.sh", ssMode: "both")
        #expect(secondStart.status == 0)
        try fixture.waitForMockStateRemoval("log-follower-active")
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

    private func runGuestMarkerSelfTest(_ lines: [String]) throws -> ScriptResult {
        let state = FileManager.default.temporaryDirectory.appending(
            path: "guest-marker-state-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repositoryRoot.appending(path: "Integration/RemoteRocky/guest/input-marker-agent.sh").path,
            "--self-test-jsonl",
        ]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["PERF_MARKER_STATE_DIR"] = state.path
        environment["PERF_MARKER_TEST_MODE"] = "1"
        process.environment = environment

        try process.run()
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ScriptResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private func runGuestScript(
        _ name: String,
        arguments: [String] = [],
        standardInput: String? = nil,
        environment overrides: [String: String] = [:]
    ) throws -> ScriptResult {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            repositoryRoot.appending(path: "Integration/RemoteRocky/guest/\(name)").path,
        ] + arguments
        if standardInput != nil {
            process.standardInput = input
        }
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in overrides {
            environment[key] = value
        }
        process.environment = environment

        try process.run()
        if let standardInput {
            input.fileHandleForWriting.write(Data(standardInput.utf8))
            try input.fileHandleForWriting.close()
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return ScriptResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self)
        )
    }

    private func runGuestMarkerCommand(
        _ arguments: [String],
        state: URL,
        additionalEnvironment: [String: String] = [:]
    ) throws -> ScriptResult {
        try launchGuestMarkerCommand(
            arguments,
            state: state,
            additionalEnvironment: additionalEnvironment
        ).finish()
    }

    private func runGuestMarkerFIFOHandshake(
        acknowledgedRevision: String?
    ) throws -> (input: ScriptResult, request: String, rearm: ScriptResult) {
        let state = FileManager.default.temporaryDirectory.appending(
            path: "guest-marker-fifo-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: state) }

        let requestFIFO = state.appending(path: "request")
        let acknowledgmentFIFO = state.appending(path: "ack")
        try makeFIFOs(requestFIFO, acknowledgmentFIFO)

        let firstArm = try runGuestMarkerCommand(
            ["arm", "click", "0000000000000001"],
            state: state
        )
        try #require(firstArm.status == 0)

        let responder = try launchMarkerAcknowledgmentStub(
            requestFIFO: requestFIFO,
            acknowledgmentFIFO: acknowledgmentFIFO,
            acknowledgedRevision: acknowledgedRevision
        )
        defer {
            if responder.process.isRunning {
                responder.terminate()
                responder.process.waitUntilExit()
            }
        }

        let input = try launchGuestMarkerCommand(
            ["input", "click", "100", "101"],
            state: state,
            additionalEnvironment: [
                "PERF_MARKER_TEST_MODE": "0",
                "PERF_MARKER_REQUEST_FIFO": requestFIFO.path,
                "PERF_MARKER_ACK_FIFO": acknowledgmentFIFO.path,
                "PERF_MARKER_ACK_TIMEOUT_SECONDS": "1",
            ]
        ).finish(within: .seconds(3))
        let request = try responder.finish(within: .seconds(3)).output

        #expect(!FileManager.default.fileExists(atPath: state.appending(path: "lock").path))
        let rearm = try runGuestMarkerCommand(
            ["arm", "key", "0000000000000002"],
            state: state
        )
        return (input, request, rearm)
    }

    private func launchMarkerAcknowledgmentStub(
        requestFIFO: URL,
        acknowledgmentFIFO: URL,
        acknowledgedRevision: String?
    ) throws -> RunningScript {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            IFS= read -r request < "$1"
            if test "$2" != none; then
                printf '%s\\n' "$2" > "$3"
            fi
            printf '%s\\n' "$request"
            """,
            "marker-ack-stub",
            requestFIFO.path,
            acknowledgedRevision ?? "none",
            acknowledgmentFIFO.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return RunningScript(process: process, output: output)
    }

    private func launchStaleMarkerAcknowledgmentStub(
        requestFIFO: URL,
        acknowledgmentFIFO: URL,
        releaseStale: URL,
        staleWritten: URL
    ) throws -> RunningScript {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            """
            exec 4<> "$2"
            IFS= read -r first < "$1"
            while ! test -e "$3"; do
                sleep 0.01
            done
            printf '1\\n' >&4
            : > "$4"
            IFS= read -r second < "$1"
            printf '2\\n' >&4
            printf '%s\\n%s\\n' "$first" "$second"
            """,
            "marker-stale-ack-stub",
            requestFIFO.path,
            acknowledgmentFIFO.path,
            releaseStale.path,
            staleWritten.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return RunningScript(process: process, output: output)
    }

    private func makeFIFOs(_ URLs: URL...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mkfifo")
        process.arguments = URLs.map(\.path)
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }

    private func launchFIFORecordWriter(
        _ record: String,
        FIFO: URL,
        completion: URL
    ) throws -> RunningScript {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "printf '%s\\n' \"$1\" > \"$2\"; : > \"$3\"",
            "marker-request-writer",
            record,
            FIFO.path,
            completion.path,
        ]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return RunningScript(process: process, output: output)
    }

    private func launchGuestMarkerCommand(
        _ arguments: [String],
        state: URL,
        additionalEnvironment: [String: String] = [:]
    ) throws -> RunningScript {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            repositoryRoot.appending(path: "Integration/RemoteRocky/guest/input-marker-agent.sh").path,
        ] + arguments
        process.standardOutput = output
        process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment["PERF_MARKER_STATE_DIR"] = state.path
        environment["PERF_MARKER_TEST_MODE"] = "1"
        for (key, value) in additionalEnvironment {
            environment[key] = value
        }
        process.environment = environment
        try process.run()
        return RunningScript(process: process, output: output)
    }

    private func waitForPath(_ path: URL) throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: path.path) {
            guard ContinuousClock().now < deadline else {
                throw RemoteRockyFixtureError.timedOutWaitingForMockState(path.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func waitForPathRemoval(_ path: URL) throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while FileManager.default.fileExists(atPath: path.path) {
            guard ContinuousClock().now < deadline else {
                throw RemoteRockyFixtureError.timedOutWaitingForMockState(path.lastPathComponent)
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func waitForExit(_ process: Process, within timeout: Duration) throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while process.isRunning, ContinuousClock().now < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard !process.isRunning else {
            process.terminate()
            process.waitUntilExit()
            throw RemoteRockyFixtureError.timedOutWaitingForScript
        }
        process.waitUntilExit()
    }

    private func waitForText(_ text: String, count: Int, in file: URL) throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while ContinuousClock().now < deadline {
            let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if contents.components(separatedBy: text).count - 1 >= count {
                return
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw RemoteRockyFixtureError.timedOutWaitingForMockState(text)
    }

    private func writeExecutable(_ URL: URL, contents: String) throws {
        try Data(contents.utf8).write(to: URL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: URL.path
        )
    }

    private func perfRecords(prefix: String, in output: String) -> [[String: String]] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.first == Substring(prefix) else { return nil }
            return Dictionary(uniqueKeysWithValues: fields.dropFirst().compactMap { field in
                let pair = field.split(separator: "=", maxSplits: 1)
                guard pair.count == 2 else { return nil }
                return (String(pair[0]), String(pair[1]))
            })
        }
    }
}

private struct RemoteRockyFixture {
    static let requiredManifestKeys = [
        "manifest_version",
        "guest_kernel",
        "guest_alpine_base",
        "guest_coreutils",
        "guest_dbus",
        "guest_eudev",
        "guest_font_dejavu",
        "guest_linux_virt",
        "guest_marker_clock",
        "guest_openbox",
        "guest_spice_vdagent",
        "guest_spice_webdavd",
        "guest_xclip",
        "guest_xinput",
        "guest_xf86_input_libinput",
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
            "guest_kernel": "linux-virt-6.12.107-r0",
            "guest_alpine_base": "3.22.5-r0",
            "guest_coreutils": "9.7-r1",
            "guest_dbus": "1.16.2-r1",
            "guest_eudev": "3.2.14-r5",
            "guest_font_dejavu": "2.37-r6",
            "guest_linux_virt": "6.12.107-r0",
            "guest_marker_clock": "clock_gettime-monotonic-v1",
            "guest_openbox": "3.6.1-r8",
            "guest_spice_vdagent": "0.22.1-r2",
            "guest_spice_webdavd": "3.0-r4",
            "guest_xclip": "0.13-r3",
            "guest_xinput": "1.6.4-r2",
            "guest_xf86_input_libinput": "1.5.0-r0",
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
        arguments: [String] = [],
        ssMode: String,
        additionalEnvironment: [String: String] = [:]
    ) throws -> ScriptResult {
        try launch(
            relativePath,
            arguments: arguments,
            ssMode: ssMode,
            additionalEnvironment: additionalEnvironment
        ).finish()
    }

    func launch(
        _ relativePath: String,
        arguments: [String] = [],
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
            .appending(path: "Integration/RemoteRocky/\(relativePath)").path] + arguments
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

    func waitForMockStateRemoval(_ name: String) throws {
        let deadline = ContinuousClock().now.advanced(by: .seconds(5))
        let path = mockState.appending(path: name).path
        while fileManager.fileExists(atPath: path) {
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

    func lastControlInvocation() throws -> String {
        try String(contentsOf: mockState.appending(path: "control-command"), encoding: .utf8)
    }

    private func writeMocks() throws {
        try writeExecutable(name: "flock", contents: #"""
        #!/bin/bash
        set -euo pipefail
        [[ "${1:-}" == --exclusive ]]
        [[ "${2:-}" =~ ^[3-9]$ ]]
        [[ $# == 2 ]]
        exec /usr/bin/python3 -c \
            'import fcntl, sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX)' "${2}"
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
            exec)
                [[ "${1:-}" == swiftspice-perf-ab-qemu ]]
                [[ "${2:-}" == bash ]]
                [[ "${3:-}" == -c ]]
                [[ $# == 4 ]]
                printf '%s\n' "${4:-}" > "$state/control-command"
                if [[ "${4:-}" =~ sync\ invocation=([0-9a-f]{32}) ]]; then
                    invocation="${BASH_REMATCH[1]}"
                    run_id="$(<"${SWIFTSPICE_PERF_BASE:?}/state/current-run")"
                    server_log="${SWIFTSPICE_PERF_BASE}/logs/${run_id}/server.log"
                    if [[ "${MOCK_ARM_RETRY_RACE:-}" == 1 \
                        && -f "$state/delayed-arm-result" ]]; then
                        /bin/cat "$state/delayed-arm-result" >> "$server_log"
                        rm -f "$state/delayed-arm-result"
                    fi
                    printf 'PERF_CONTROL_SYNC invocation=%s\r\n' "$invocation" >> "$server_log"
                    printf 'control-sync\n' >> "$state/events"
                    exit 0
                fi
                printf 'control-exec\n' >> "$state/events"
                if [[ "${4:-}" == *"diagnose-input"* ]]; then
                    run_id="$(<"${SWIFTSPICE_PERF_BASE:?}/state/current-run")"
                    server_log="${SWIFTSPICE_PERF_BASE}/logs/${run_id}/server.log"
                    if [[ -n "${MOCK_CONTAINER_LOG_FILE:-}" ]]; then
                        /bin/cat "${MOCK_CONTAINER_LOG_FILE}" >> "$server_log"
                    else
                        printf '%s\n' \
                            'PERF_INPUT_DIAGNOSTIC_BEGIN' \
                            'PERF_INPUT_DIAGNOSTIC_END' \
                            >> "$server_log"
                    fi
                fi
                if [[ "${4:-}" =~ arm\ action_class=([a-z]+)\ token=([0-9a-f]{16}) ]]; then
                    action_class="${BASH_REMATCH[1]}"
                    token="${BASH_REMATCH[2]}"
                    run_id="$(<"${SWIFTSPICE_PERF_BASE:?}/state/current-run")"
                    server_log="${SWIFTSPICE_PERF_BASE}/logs/${run_id}/server.log"
                    arm_result="${MOCK_ARM_RESULT:-accepted}"
                    if [[ "${MOCK_ARM_RETRY_RACE:-}" == 1 ]]; then
                        attempt_file="$state/arm-attempts"
                        attempt=0
                        if [[ -f "$attempt_file" ]]; then
                            attempt="$(<"$attempt_file")"
                        fi
                        attempt=$((attempt + 1))
                        printf '%s\n' "$attempt" > "$attempt_file"
                        if [[ "$attempt" == 1 ]]; then
                            printf 'PERF_ARMED action_class=%s token=%s\r\n' \
                                "$action_class" "$token" > "$state/delayed-arm-result"
                            arm_result=timeout
                        else
                            if [[ -f "$state/delayed-arm-result" ]]; then
                                /bin/cat "$state/delayed-arm-result" >> "$server_log"
                                rm -f "$state/delayed-arm-result"
                            fi
                            arm_result=duplicate_token
                        fi
                    fi
                    if [[ "${MOCK_ARM_STATEFUL:-}" == 1 ]]; then
                        arm_lock="$state/guest-arm.lock"
                        until mkdir "$arm_lock" 2>/dev/null; do /bin/sleep 0.01; done
                        if [[ -f "$state/guest-arm-pending" ]]; then
                            arm_result=arm_outstanding
                        else
                            : > "$state/guest-arm-pending"
                            arm_result=accepted
                        fi
                    fi
                    if [[ "${MOCK_ARM_CRLF_NOISE:-}" == 1 ]]; then
                        for index in $(seq 1 14); do
                            printf 'PERF_ARM_NOISE index=%s\r\n' "$index" >> "$server_log"
                        done
                    fi
                    case "$arm_result" in
                        accepted)
                            printf 'PERF_ARMED action_class=%s token=%s\r\n' \
                                "$action_class" "$token" >> "$server_log"
                            ;;
                        arm_outstanding|duplicate_token)
                            printf 'PERF_ARM_REJECTED action_class=%s token=%s reason=%s\r\n' \
                                "$action_class" "$token" "$arm_result" >> "$server_log"
                            ;;
                        timeout) ;;
                        *) exit 64 ;;
                    esac
                    if [[ "${MOCK_ARM_STATEFUL:-}" == 1 ]]; then
                        rmdir "$arm_lock"
                    fi
                fi
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
                    : > "$state/log-follower-active"
                    trap 'rm -f "$state/log-follower-active"' EXIT
                elif [[ "${1:-}" == --tail ]]; then
                    [[ "${2:-}" == 12 ]]
                    [[ "${3:-}" == swiftspice-perf-ab-qemu ]]
                    [[ $# == 3 ]]
                    if [[ -n "${MOCK_CONTAINER_LOG_FILE:-}" ]]; then
                        /usr/bin/tail -n "${2}" "${MOCK_CONTAINER_LOG_FILE}"
                    else
                        printf 'PERF_READY resolution=1280x720\n'
                    fi
                else
                    [[ "${1:-}" == swiftspice-perf-ab-qemu ]]
                    [[ $# == 1 ]]
                    if [[ -n "${MOCK_CONTAINER_LOG_FILE:-}" ]]; then
                        /bin/cat "${MOCK_CONTAINER_LOG_FILE}"
                    else
                        printf 'PERF_READY resolution=1280x720\n'
                    fi
                fi
                if [[ "${1:-}" == --follow ]]; then
                    printf 'PERF_READY resolution=1280x720\n'
                fi
                if [[ "${1:-}" == --follow && -n "${MOCK_REUSED_FOLLOWER_PID:-}" ]]; then
                    follower_pid_file="${SWIFTSPICE_PERF_BASE:?}/state/log-follower.pid"
                    for _ in $(seq 1 100); do
                        [[ -s "$follower_pid_file" ]] && break
                        /bin/sleep 0.01
                    done
                    [[ -s "$follower_pid_file" ]]
                    printf '%s\n' "$MOCK_REUSED_FOLLOWER_PID" > "$follower_pid_file"
                    : > "$state/follower-pid-reused"
                fi
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
