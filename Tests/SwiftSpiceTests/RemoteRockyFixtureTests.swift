import Darwin
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

    @Test func guestInputMonitorMatchesCommonRawAndDeliveredXI2Events() throws {
        let events = [
            "EVENT type 13 (RawKeyPress)",
            "EVENT type 2 (KeyPress)",
            "EVENT type 15 (RawButtonPress)",
            "EVENT type 4 (ButtonPress)",
            "EVENT type 17 (RawMotion)",
            "EVENT type 6 (Motion)",
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
            "PERF_INPUT_MATCH action_class=click",
            "PERF_INPUT_MATCH action_class=motion",
            "PERF_INPUT_MATCH action_class=motion",
        ])
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
        #expect(errors.count == 4)
        #expect(errors.contains("PERF_ERROR input_marker=arm_outstanding"))
        #expect(errors.contains("PERF_ERROR input_marker=duplicate_token"))
        #expect(errors.contains("PERF_ERROR input_marker=invalid_action_class"))
        #expect(errors.contains("PERF_ERROR input_marker=invalid_token"))

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
            "guest_kernel": "linux-virt-6.12.103-r0",
            "guest_alpine_base": "3.22.5-r0",
            "guest_coreutils": "9.7-r1",
            "guest_dbus": "1.16.2-r1",
            "guest_eudev": "3.2.14-r5",
            "guest_font_dejavu": "2.37-r6",
            "guest_linux_virt": "6.12.103-r0",
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
        [[ "${2:-}" == 8 || "${2:-}" == 9 ]]
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
