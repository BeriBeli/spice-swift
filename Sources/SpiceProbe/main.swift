import AppKit
import Darwin
import Foundation
import SwiftSpice

@main
struct SpiceProbe {
    static func main() async {
        do {
            let configuration = try parseArguments()
            let password = ProcessInfo.processInfo.environment["SPICE_PASSWORD"] ?? ""
            let credentials = SpiceCredentials(password: password)
            let session = SpiceSession()
            var webDAVRoot: URL?
            var webDAVEventTask: Task<Void, Never>?
            defer {
                webDAVEventTask?.cancel()
                if let webDAVRoot {
                    try? FileManager.default.removeItem(at: webDAVRoot)
                }
            }
            let connectStart = ContinuousClock().now
            let info = try await session.connect(
                endpoint: configuration.endpoint,
                credentials: credentials
            )
            let connectMilliseconds = milliseconds(
                from: connectStart.duration(to: ContinuousClock().now)
            )

            if !configuration.benchmarkJSON {
                print("SPICE session \(info.sessionID) connected")
                print("mouse modes: supported=\(info.supportedMouseModes) current=\(info.currentMouseMode)")
                print("agent connected: \(info.agentConnected)")
                for channel in info.channels {
                    print("channel type=\(channel.type) id=\(channel.id)")
                }
            }
            if configuration.requireAgent, !info.agentConnected {
                throw ProbeError.missingObservation("VDAgent connection")
            }
            if configuration.exerciseWebDAV {
                webDAVEventTask = Task {
                    for await event in session.events {
                        print(description(of: event))
                    }
                }
                let root = FileManager.default.temporaryDirectory.appending(
                    path: "swiftspice-webdav-live-\(UUID().uuidString)",
                    directoryHint: .isDirectory
                )
                try FileManager.default.createDirectory(
                    at: root,
                    withIntermediateDirectories: false
                )
                try Data("SwiftSpice WebDAV live fixture\n".utf8).write(
                    to: root.appending(path: "swiftspice-webdav-live.txt"),
                    options: .atomic
                )
                webDAVRoot = root
                try await attachWebDAVServer(
                    try SpiceWebDAVServer(root: root),
                    to: session
                )
                print("WebDAV live fixture attached read-only")
                try await Task.sleep(for: .seconds(15))
                print("WebDAV live fixture observation window complete")
            }
            if configuration.exerciseFileTransfer
                || configuration.exerciseClipboard
                || configuration.exerciseMonitorConfiguration {
                try await exerciseAgent(
                    session: session,
                    exerciseFileTransfer: configuration.exerciseFileTransfer,
                    exerciseClipboard: configuration.exerciseClipboard,
                    exerciseMonitorConfiguration: configuration.exerciseMonitorConfiguration
                )
            }
            if configuration.exercisePlayback {
                try await exercisePlayback(session: session)
            }
            if configuration.exerciseSyntheticRecord {
                try await exerciseSyntheticRecord(session: session)
            }
            if let seconds = configuration.observeSeconds {
                try await observe(
                    session: session,
                    seconds: seconds,
                    exerciseInput: configuration.exerciseInput,
                    requireNativeVideo: configuration.requireNativeVideo,
                    benchmarkJSON: configuration.benchmarkJSON,
                    connectMilliseconds: connectMilliseconds
                )
            }
            await session.disconnect()
        } catch {
            FileHandle.standardError.write(Data("spice-probe: \(error)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func parseArguments() throws -> Configuration {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2, let port = UInt16(arguments[1]) else {
            throw ProbeError.usage
        }
        let tlsPolicy: TLSTrustPolicy?
        if arguments.contains("--tls-insecure-for-testing-only") {
            tlsPolicy = .insecureForTestingOnly
        } else if arguments.contains("--tls") {
            tlsPolicy = .system
        } else {
            tlsPolicy = nil
        }
        let enablesH264 = arguments.contains("--enable-h264")
        let enablesH265 = arguments.contains("--enable-h265")
        guard !(enablesH264 && enablesH265) else {
            throw ProbeError.usage
        }
        let requireNativeVideo = arguments.contains("--require-native-video")
        guard !requireNativeVideo || enablesH264 || enablesH265 else {
            throw ProbeError.usage
        }
        let videoCodecPolicy: SpiceVideoCodecPolicy = enablesH264
            ? .h264AndMJPEG
            : enablesH265 ? .h265AndMJPEG : .mjpegOnly
        let exercisesPlayback = arguments.contains("--exercise-playback")
        let exercisesSyntheticRecord = arguments.contains("--exercise-record-synthetic")
        guard !(exercisesPlayback && exercisesSyntheticRecord) else {
            throw ProbeError.usage
        }
        return Configuration(
            endpoint: SpiceEndpoint(
                host: arguments[0],
                port: port,
                tlsPolicy: tlsPolicy,
                videoCodecPolicy: videoCodecPolicy
            ),
            observeSeconds: try optionalUInt64(after: "--observe-seconds", in: arguments),
            exerciseInput: arguments.contains("--exercise-input"),
            requireNativeVideo: requireNativeVideo,
            requireAgent: arguments.contains("--require-agent")
                || arguments.contains("--exercise-file-transfer")
                || arguments.contains("--exercise-clipboard")
                || arguments.contains("--exercise-monitor-config"),
            exerciseFileTransfer: arguments.contains("--exercise-file-transfer"),
            exerciseClipboard: arguments.contains("--exercise-clipboard"),
            exerciseMonitorConfiguration: arguments.contains("--exercise-monitor-config"),
            exerciseWebDAV: arguments.contains("--exercise-webdav"),
            exercisePlayback: exercisesPlayback,
            exerciseSyntheticRecord: exercisesSyntheticRecord,
            benchmarkJSON: arguments.contains("--benchmark-json")
        )
    }

    private static func exercisePlayback(session: SpiceSession) async throws {
        let sink = SpiceAudioPlaybackSink()
        let observations = PlaybackSinkObservations()
        let eventTask = Task {
            for await event in sink.events {
                await observations.record(event)
                print(description(of: event))
            }
        }
        defer { eventTask.cancel() }
        try await sink.start(session: session)
        do {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(20))
            while clock.now < deadline {
                let statistics = await sink.statistics()
                switch await observations.outcome(hasPCM: statistics.scheduledPackets > 0) {
                case .pending:
                    try await clock.sleep(for: .milliseconds(100))
                case let .completed(configuration, underruns):
                    await sink.stop()
                    print(
                        "playback sink verified rate=\(configuration.sampleRate) "
                            + "channels=\(configuration.channels) "
                            + "packets=\(statistics.scheduledPackets) "
                            + "frames=\(statistics.scheduledFrames) underruns=\(underruns)"
                    )
                    return
                case let .failed(reason):
                    throw ProbeError.audioFailed(reason)
                }
            }
            throw ProbeError.missingObservation("Playback START plus PCM drain/STOP")
        } catch {
            await sink.stop()
            throw error
        }
    }

    private static func exerciseSyntheticRecord(session: SpiceSession) async throws {
        let observations = RecordObservations()
        let eventTask = Task {
            for await event in session.recordEvents {
                await observations.record(event)
                print(description(of: event))
            }
        }
        defer { eventTask.cancel() }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        var configuration: SpiceRecordConfiguration?
        while clock.now < deadline {
            configuration = await observations.configuration()
            if configuration != nil {
                break
            }
            try await clock.sleep(for: .milliseconds(100))
        }
        guard let configuration else {
            throw ProbeError.missingObservation("Record START")
        }

        let packetMilliseconds = 10
        let framesPerPacket = max(1, configuration.sampleRate / (1_000 / packetMilliseconds))
        let packetCount = 3_000 / packetMilliseconds
        var timestamp = monotonicMilliseconds()
        try await session.beginRecording(timestamp: timestamp)
        var frameIndex = 0
        for _ in 0..<packetCount {
            if await observations.isStopped() {
                throw ProbeError.audioFailed("Record stream stopped before synthetic PCM completed")
            }
            let pcm = syntheticPCM(
                frames: framesPerPacket,
                channels: configuration.channels,
                startingAt: frameIndex
            )
            try await session.sendRecordedAudio(timestamp: timestamp, pcm: pcm)
            frameIndex += framesPerPacket
            timestamp &+= UInt32(packetMilliseconds)
            try await clock.sleep(for: .milliseconds(packetMilliseconds))
        }
        print(
            "synthetic record PCM sent rate=\(configuration.sampleRate) "
                + "channels=\(configuration.channels) frames=\(frameIndex)"
        )
    }

    private static func syntheticPCM(frames: Int, channels: Int, startingAt: Int) -> Data {
        var samples = [Int16]()
        samples.reserveCapacity(frames * channels)
        for frame in startingAt..<(startingAt + frames) {
            let value = Int16(truncatingIfNeeded: frame &* 97)
            for channel in 0..<channels {
                samples.append(channel.isMultiple(of: 2) ? value : Int16(0) &- value)
            }
        }
        return samples.withUnsafeBytes { Data($0) }
    }

    private static func monotonicMilliseconds() -> UInt32 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_MONOTONIC, &time) == 0)
        let milliseconds = UInt64(time.tv_sec) * 1_000 + UInt64(time.tv_nsec) / 1_000_000
        return UInt32(truncatingIfNeeded: milliseconds)
    }

    private static func exerciseAgent(
        session: SpiceSession,
        exerciseFileTransfer: Bool,
        exerciseClipboard: Bool,
        exerciseMonitorConfiguration: Bool
    ) async throws {
        let pasteboardSnapshot = exerciseClipboard
            ? await MainActor.run { snapshotPasteboard() }
            : nil
        let manager = SpiceAgentManager(
            automaticallySynchronizesPasteboard: false,
            pasteboardSynchronizationEnabled: exerciseClipboard
        )
        try await manager.start(session: session)
        do {
            let fileObservations = FileTransferObservations()
            let fileEventTask = Task {
                for await event in manager.fileTransferEvents {
                    await fileObservations.record(event)
                    print(description(of: event))
                }
            }
            let clipboardObservations = ClipboardObservations()
            let clipboardEventTask = Task {
                for await event in manager.events {
                    await clipboardObservations.record(event)
                    print(description(of: event))
                }
            }
            let displayObservations = DisplayConfigurationObservations()
            let displayEventTask = Task {
                for await event in manager.displayConfigurationEvents {
                    await displayObservations.record(event)
                    print(description(of: event))
                }
            }
            let displaySupportObservations = DisplaySupportObservations()
            let displaySupportTask = Task {
                for await support in manager.displayConfigurationSupportEvents {
                    await displaySupportObservations.record(support)
                    print(
                        "monitor support explicit=\(support.hasExplicitPeerCapabilities) "
                            + "configuration=\(support.supportsMonitorConfiguration) "
                            + "sparse=\(support.supportsSparseMonitors) "
                            + "positions=\(support.supportsMonitorPositions)"
                    )
                }
            }
            defer {
                fileEventTask.cancel()
                clipboardEventTask.cancel()
                displayEventTask.cancel()
                displaySupportTask.cancel()
            }

            if exerciseFileTransfer {
                let fixture = FileManager.default.temporaryDirectory.appending(
                    path: "swiftspice-live-\(UUID().uuidString).txt"
                )
                defer { try? FileManager.default.removeItem(at: fixture) }
                try Data("SwiftSpice live file transfer\n".utf8).write(
                    to: fixture,
                    options: .atomic
                )
                let id = try await manager.sendFile(at: fixture, name: "swiftspice-live.txt")
                try await waitForFileTransfer(id, observations: fileObservations)
                print("file transfer verified by host id=\(id.rawValue)")
            }

            if exerciseClipboard {
                await manager.publish("SwiftSpice host clipboard\n")
                try await waitForGuestClipboard(
                    "SwiftSpice guest clipboard\n",
                    observations: clipboardObservations
                )
                print("clipboard round trip verified by host")
            }
            if exerciseMonitorConfiguration {
                try await waitForExplicitMonitorSupport(displaySupportObservations)
                let configuration = SpiceDisplayConfiguration(monitors: [
                    .init(id: 0, x: 0, y: 0, width: 800, height: 600),
                    .init(id: 1, x: 0, y: 0, width: 640, height: 480),
                ])
                try await manager.requestDisplayConfiguration(configuration)
                try await waitForDisplayConfiguration(
                    configuration,
                    observations: displayObservations
                )
                print("monitor configuration accepted by live transport")
            }
            await manager.stop()
            if let pasteboardSnapshot {
                await MainActor.run { restorePasteboard(pasteboardSnapshot) }
            }
        } catch {
            await manager.stop()
            if let pasteboardSnapshot {
                await MainActor.run { restorePasteboard(pasteboardSnapshot) }
            }
            throw error
        }
    }

    private static func waitForFileTransfer(
        _ id: SpiceFileTransferID,
        observations: FileTransferObservations
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            switch await observations.outcome(for: id) {
            case .pending:
                try await clock.sleep(for: .milliseconds(100))
            case .completed:
                return
            case let .failed(error):
                throw ProbeError.fileTransferFailed(error.description)
            }
        }
        throw ProbeError.missingObservation("completed Agent file transfer")
    }

    private static func attachWebDAVServer(
        _ server: SpiceWebDAVServer,
        to session: SpiceSession
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        var lastError: (any Error)?
        while clock.now < deadline {
            do {
                try await session.attachWebDAVServer(server)
                return
            } catch {
                lastError = error
                try await clock.sleep(for: .milliseconds(100))
            }
        }
        if let lastError {
            throw lastError
        }
        throw ProbeError.missingObservation("connected WebDAV Channel")
    }

    private static func waitForGuestClipboard(
        _ expectedText: String,
        observations: ClipboardObservations
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            switch await observations.outcome(expectedText: expectedText) {
            case .pending:
                try await clock.sleep(for: .milliseconds(100))
            case .completed:
                return
            case let .failed(error):
                throw ProbeError.clipboardFailed(error.description)
            }
        }
        throw ProbeError.missingObservation("guest-to-host Agent clipboard text")
    }

    private static func waitForDisplayConfiguration(
        _ configuration: SpiceDisplayConfiguration,
        observations: DisplayConfigurationObservations
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            switch await observations.outcome(for: configuration) {
            case .pending:
                try await clock.sleep(for: .milliseconds(100))
            case .acknowledged:
                return
            case let .failed(reason):
                throw ProbeError.monitorConfigurationFailed(reason)
            }
        }
        throw ProbeError.missingObservation("sent Agent monitor configuration")
    }

    private static func waitForExplicitMonitorSupport(
        _ observations: DisplaySupportObservations
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            if let support = await observations.latestExplicitSupport() {
                guard support.supportsMonitorConfiguration else {
                    throw ProbeError.monitorConfigurationFailed(
                        "guest capability announcement disables monitor configuration"
                    )
                }
                return
            }
            try await clock.sleep(for: .milliseconds(100))
        }
        throw ProbeError.missingObservation("explicit Agent monitor capabilities")
    }

    private static func optionalUInt64(
        after flag: String,
        in arguments: [String]
    ) throws -> UInt64? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }
        guard arguments.indices.contains(index + 1),
              let value = UInt64(arguments[index + 1]),
              value > 0 else {
            throw ProbeError.usage
        }
        return value
    }

    private static func observe(
        session: SpiceSession,
        seconds: UInt64,
        exerciseInput: Bool,
        requireNativeVideo: Bool,
        benchmarkJSON: Bool,
        connectMilliseconds: Double
    ) async throws {
        let observations = ProbeObservations()
        let observationCPUStart = processCPUSeconds()
        let desktopSubscription = session.desktop.subscribe()
        desktopSubscription.setDemand(.visible)
        let eventTask = Task {
            for await event in session.events {
                await observations.record(event)
                if !benchmarkJSON {
                    print(description(of: event))
                }
            }
        }
        let desktopTask = Task {
            for await snapshot in desktopSubscription.updates {
                await observations.record(snapshot)
                if !benchmarkJSON {
                    print(description(of: snapshot))
                }
            }
        }
        defer {
            desktopSubscription.setDemand(.none)
            desktopSubscription.cancel()
            desktopTask.cancel()
            eventTask.cancel()
        }

        var exercisedPointerMode: SpicePointerMode?
        if exerciseInput {
            let pointerMode = try await waitForInputExerciseReadiness(observations)
            exercisedPointerMode = pointerMode
            for input in SpiceInputExercisePlan.inputs(for: pointerMode) {
                try await session.send(input)
            }
        }

        try await Task.sleep(for: .seconds(seconds))
        let observationCPUSeconds = processCPUSeconds() - observationCPUStart
        let summary = await observations.summary()
        let diagnostics = await session.diagnosticsSnapshot()
        if let sessionFailure = summary.sessionFailure {
            throw ProbeError.sessionFailed(sessionFailure)
        }
        if benchmarkJSON {
            let report = ProbeBenchmarkReport(
                client: "swiftspice",
                connectMilliseconds: connectMilliseconds,
                observeSeconds: seconds,
                frames: summary.frames,
                framesPerSecond: Double(summary.frames) / Double(seconds),
                firstFrameMilliseconds: summary.firstFrameMilliseconds,
                readyFrameMilliseconds: summary.firstFrameMilliseconds.map {
                    connectMilliseconds + $0
                },
                p95InterframeMilliseconds: summary.p95InterframeMilliseconds,
                observationCPUSeconds: observationCPUSeconds,
                frameBytes: summary.frameBytes,
                cursors: summary.cursors,
                keyboardEvents: summary.keyboardEvents,
                motionAcknowledgements: summary.motionAcknowledgements,
                diagnostics: diagnostics
            )
            let data = try JSONEncoder().encode(report)
            print(String(decoding: data, as: UTF8.self))
        } else {
            print(
                "observed: frames=\(summary.frames) cursors=\(summary.cursors) "
                    + "keyboard=\(summary.keyboardEvents) "
                    + "motion-acks=\(summary.motionAcknowledgements)"
            )
            print(
                "display diagnostics: native-video=\(diagnostics.nativeVideoFrames) "
                    + "advanced-cpu-fallback=\(diagnostics.advancedCPUFallbackFrames) "
                    + "cpu-materialization=\(diagnostics.cpuMaterializations) "
                    + "direct-iosurface-bytes=\(diagnostics.directIOSurfaceWriteBytes) "
                    + "vt-hardware/software=\(diagnostics.videoHardwareSessions)/"
                    + "\(diagnostics.videoSoftwareSessions) gpu-errors=\(diagnostics.gpuErrors) "
                    + "iosurface-bytes=\(diagnostics.totalIOSurfaceAllocatedBytes)"
            )
        }
        guard summary.frames > 0 else {
            throw ProbeError.missingObservation("Display frame")
        }
        if exerciseInput, summary.motionAcknowledgements == 0 {
            let pointerInput = exercisedPointerMode == .absolute
                ? "mouse-position"
                : "mouse-motion"
            throw ProbeError.missingObservation(
                "Inputs \(pointerInput) flow-control acknowledgement"
            )
        }
        if requireNativeVideo {
            guard diagnostics.videoDecodedFrames > 0,
                  diagnostics.nativeVideoFrames > 0
            else {
                throw ProbeError.nativeVideoFailed("no decoded native frame reached Metal")
            }
            guard diagnostics.videoCPUMaterializations == 0,
                  diagnostics.advancedCPUFallbackFrames == 0
            else {
                throw ProbeError.nativeVideoFailed(
                    "BGRA materializations=\(diagnostics.videoCPUMaterializations), "
                        + "CPU fallback frames=\(diagnostics.advancedCPUFallbackFrames)"
                )
            }
            guard diagnostics.gpuErrors == 0,
                  diagnostics.metalGenerationDisableCount == 0
            else {
                throw ProbeError.nativeVideoFailed(
                    "GPU errors=\(diagnostics.gpuErrors), generation disables="
                        + "\(diagnostics.metalGenerationDisableCount)"
                )
            }
        }
    }

    private static func waitForInputExerciseReadiness(
        _ observations: ProbeObservations
    ) async throws -> SpicePointerMode {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(20))
        while clock.now < deadline {
            switch await observations.inputExerciseReadiness() {
            case .pending:
                try await clock.sleep(for: .milliseconds(100))
            case let .ready(pointerMode):
                return pointerMode
            case let .failed(reason):
                throw ProbeError.sessionFailed(reason)
            }
        }
        throw ProbeError.missingObservation(
            "desktop snapshot and pointer mode before input exercise"
        )
    }

    private static func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func processCPUSeconds() -> Double {
        var time = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private static func description(of event: SpiceSessionEvent) -> String {
        switch event {
        case let .displayConfiguration(configuration):
            "display configuration channel=\(configuration.channelID) "
                + "monitors=\(configuration.monitors.count)"
        case let .keyboardModifiers(modifiers):
            "keyboard modifiers=\(modifiers)"
        case .mouseMotionAcknowledged:
            "mouse motion acknowledged"
        case let .migration(event):
            "migration event=\(event)"
        case let .failed(error):
            "session failed: \(error)"
        case .disconnected:
            "session disconnected"
        }
    }

    private static func description(of snapshot: SpiceDesktopSnapshot) -> String {
        guard let update = snapshot.frame else {
            return "desktop generation=\(snapshot.generation) frame=none "
                + "pointer=\(snapshot.pointerMode)"
        }
        return "desktop generation=\(snapshot.generation) "
            + "surface=\(update.revision.surface.surfaceID) "
            + "revision=\(update.revision.value) "
            + "size=\(update.frame.width)x\(update.frame.height) "
            + "bytes=\(update.frame.bytesPerRow * update.frame.height)"
    }

    private static func description(of event: SpiceFileTransferEvent) -> String {
        switch event {
        case let .queued(id, name, totalBytes):
            "file transfer queued id=\(id.rawValue) name=\(name) bytes=\(totalBytes)"
        case let .awaitingGuestApproval(id):
            "file transfer awaiting guest id=\(id.rawValue)"
        case let .progress(id, sentBytes, totalBytes):
            "file transfer progress id=\(id.rawValue) bytes=\(sentBytes)/\(totalBytes)"
        case let .completed(id):
            "file transfer completed id=\(id.rawValue)"
        case let .cancelled(id):
            "file transfer cancelled id=\(id.rawValue)"
        case let .failed(id, error):
            "file transfer failed id=\(id?.rawValue.description ?? "none") error=\(error)"
        }
    }

    private static func description(of event: SpiceAudioPlaybackSinkEvent) -> String {
        switch event {
        case let .started(configuration):
            "playback started rate=\(configuration.sampleRate) channels=\(configuration.channels)"
        case .stopped:
            "playback stopped"
        case let .muteChanged(muted):
            "playback mute=\(muted)"
        case let .overflowResynchronized(milliseconds):
            "playback overflow dropped_ms=\(milliseconds)"
        case let .oversizedPacketDropped(milliseconds):
            "playback oversized dropped_ms=\(milliseconds)"
        case .underrun:
            "playback underrun"
        case let .failed(error):
            "playback failed error=\(error)"
        }
    }

    private static func description(of event: SpiceRecordEvent) -> String {
        switch event {
        case let .started(configuration):
            "record started rate=\(configuration.sampleRate) channels=\(configuration.channels)"
        case .stopped:
            "record stopped"
        case let .volumeChanged(volume):
            "record volume channels=\(volume.count)"
        case let .muteChanged(muted):
            "record mute=\(muted)"
        }
    }

    private static func description(of event: SpiceClipboardEvent) -> String {
        switch event {
        case .ready:
            "clipboard ready"
        case .unavailable:
            "clipboard unavailable"
        case let .guestText(text):
            "clipboard guest text bytes=\(text.utf8.count)"
        case let .localTextOffered(byteCount):
            "clipboard host text offered bytes=\(byteCount)"
        case let .oversizedLocalText(byteCount, maximum):
            "clipboard host text oversized bytes=\(byteCount) maximum=\(maximum)"
        case let .failed(error):
            "clipboard failed error=\(error)"
        }
    }

    private static func description(of event: SpiceDisplayConfigurationEvent) -> String {
        switch event {
        case let .queued(configuration):
            "monitor configuration queued count=\(configuration.monitors.count)"
        case let .sent(configuration):
            "monitor configuration sent count=\(configuration.monitors.count)"
        case let .acknowledged(configuration):
            "monitor configuration acknowledged count=\(configuration.monitors.count)"
        case let .rejected(configuration):
            "monitor configuration rejected count=\(configuration.monitors.count)"
        case let .unsupported(configuration):
            "monitor configuration unsupported count=\(configuration.monitors.count)"
        case let .failed(configuration, error):
            "monitor configuration failed count=\(configuration.monitors.count) error=\(error)"
        case let .protocolFailure(error):
            "monitor configuration protocol failure error=\(error)"
        }
    }

    @MainActor
    private static func snapshotPasteboard() -> PasteboardSnapshot {
        let items = NSPasteboard.general.pasteboardItems ?? []
        return PasteboardSnapshot(items: items.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type.rawValue, $0) }
            })
        })
    }

    @MainActor
    private static func restorePasteboard(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: .init(type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}

private struct Configuration {
    let endpoint: SpiceEndpoint
    let observeSeconds: UInt64?
    let exerciseInput: Bool
    let requireNativeVideo: Bool
    let requireAgent: Bool
    let exerciseFileTransfer: Bool
    let exerciseClipboard: Bool
    let exerciseMonitorConfiguration: Bool
    let exerciseWebDAV: Bool
    let exercisePlayback: Bool
    let exerciseSyntheticRecord: Bool
    let benchmarkJSON: Bool
}

private actor PlaybackSinkObservations {
    private var configuration: SpicePlaybackConfiguration?
    private var stopped = false
    private var underruns = 0
    private var failure: String?

    func record(_ event: SpiceAudioPlaybackSinkEvent) {
        switch event {
        case let .started(configuration):
            self.configuration = configuration
            stopped = false
        case .stopped:
            stopped = true
        case .underrun:
            underruns += 1
        case let .failed(error):
            failure = error.description
        default:
            break
        }
    }

    func outcome(hasPCM: Bool) -> PlaybackSinkOutcome {
        if let failure {
            return .failed(failure)
        }
        if let configuration, hasPCM || stopped || underruns > 0 {
            return .completed(configuration, underruns: underruns)
        }
        return .pending
    }
}

private enum PlaybackSinkOutcome: Sendable {
    case pending
    case completed(SpicePlaybackConfiguration, underruns: Int)
    case failed(String)
}

private actor RecordObservations {
    private var activeConfiguration: SpiceRecordConfiguration?
    private var stopped = false

    func record(_ event: SpiceRecordEvent) {
        switch event {
        case let .started(configuration):
            activeConfiguration = configuration
            stopped = false
        case .stopped:
            stopped = true
        default:
            break
        }
    }

    func configuration() -> SpiceRecordConfiguration? {
        activeConfiguration
    }

    func isStopped() -> Bool {
        stopped
    }
}

private struct PasteboardSnapshot: Sendable {
    let items: [[String: Data]]
}

private actor FileTransferObservations {
    private var completed: Set<SpiceFileTransferID> = []
    private var failures: [SpiceFileTransferID?: SpiceFileTransferError] = [:]

    func record(_ event: SpiceFileTransferEvent) {
        switch event {
        case let .completed(id):
            completed.insert(id)
        case let .failed(id, error):
            failures[id] = error
        default:
            break
        }
    }

    func outcome(for id: SpiceFileTransferID) -> FileTransferOutcome {
        if completed.contains(id) {
            return .completed
        }
        if let error = failures[id] ?? failures[nil] {
            return .failed(error)
        }
        return .pending
    }
}

private enum FileTransferOutcome: Sendable {
    case pending
    case completed
    case failed(SpiceFileTransferError)
}

private actor ClipboardObservations {
    private var guestTexts: Set<String> = []
    private var failure: SpiceClipboardError?

    func record(_ event: SpiceClipboardEvent) {
        switch event {
        case let .guestText(text):
            guestTexts.insert(text)
        case let .failed(error):
            failure = error
        default:
            break
        }
    }

    func outcome(expectedText: String) -> ClipboardOutcome {
        if guestTexts.contains(expectedText) {
            return .completed
        }
        if let failure {
            return .failed(failure)
        }
        return .pending
    }
}

private enum ClipboardOutcome: Sendable {
    case pending
    case completed
    case failed(SpiceClipboardError)
}

private actor DisplayConfigurationObservations {
    private var sent: Set<DisplayConfigurationKey> = []
    private var acknowledged: Set<DisplayConfigurationKey> = []
    private var failures: [DisplayConfigurationKey: String] = [:]
    private var protocolFailure: String?

    func record(_ event: SpiceDisplayConfigurationEvent) {
        switch event {
        case let .sent(configuration):
            sent.insert(.init(configuration))
        case let .acknowledged(configuration):
            acknowledged.insert(.init(configuration))
        case let .rejected(configuration):
            failures[.init(configuration)] = "guest rejected the monitor configuration"
        case let .unsupported(configuration):
            failures[.init(configuration)] = "guest does not support the monitor configuration"
        case let .failed(configuration, error):
            failures[.init(configuration)] = error.description
        case let .protocolFailure(error):
            protocolFailure = error.description
        default:
            break
        }
    }

    func outcome(for configuration: SpiceDisplayConfiguration) -> DisplayConfigurationOutcome {
        let key = DisplayConfigurationKey(configuration)
        if acknowledged.contains(key) {
            return .acknowledged
        }
        // spice-server may intercept MONITORS_CONFIG and hand it directly to
        // QEMU's client_monitors_config callback. That path deliberately does
        // not forward the packet to vdagent, so no VD_AGENT_REPLY exists.
        if sent.contains(key) {
            return .acknowledged
        }
        if let reason = failures[key] ?? protocolFailure {
            return .failed(reason)
        }
        return .pending
    }
}

private struct DisplayConfigurationKey: Hashable, Sendable {
    let monitors: [MonitorKey]

    init(_ configuration: SpiceDisplayConfiguration) {
        monitors = configuration.monitors.map(MonitorKey.init)
    }
}

private struct MonitorKey: Hashable, Sendable {
    let id: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    init(_ monitor: SpiceMonitorConfiguration) {
        id = monitor.id
        x = monitor.x
        y = monitor.y
        width = monitor.width
        height = monitor.height
    }
}

private enum DisplayConfigurationOutcome: Sendable {
    case pending
    case acknowledged
    case failed(String)
}

private actor DisplaySupportObservations {
    private var latest: SpiceDisplayConfigurationSupport?

    func record(_ support: SpiceDisplayConfigurationSupport) {
        latest = support
    }

    func latestExplicitSupport() -> SpiceDisplayConfigurationSupport? {
        guard latest?.hasExplicitPeerCapabilities == true else {
            return nil
        }
        return latest
    }
}

private actor ProbeObservations {
    private let start = ContinuousClock().now
    private var frames = 0
    private var frameBytes = 0
    private var firstFrameMilliseconds: Double?
    private var previousFrameInstant: ContinuousClock.Instant?
    private var interframeMilliseconds: [Double] = []
    private var cursors = 0
    private var keyboardEvents = 0
    private var motionAcknowledgements = 0
    private var sessionFailure: String?
    private var latestPointerMode: SpicePointerMode?
    private var lastFrameRevision: SpiceFrameRevision?
    private var lastCursor: SpiceCursorState?

    func record(_ event: SpiceSessionEvent) {
        switch event {
        case .keyboardModifiers:
            keyboardEvents += 1
        case .mouseMotionAcknowledged:
            motionAcknowledgements += 1
        case let .failed(error):
            sessionFailure = error.description
        default:
            break
        }
    }

    func record(_ snapshot: SpiceDesktopSnapshot) {
        latestPointerMode = snapshot.pointerMode
        if let update = snapshot.frame, update.revision != lastFrameRevision {
            let now = ContinuousClock().now
            frames += 1
            frameBytes += update.frame.bytesPerRow * update.frame.height
            if firstFrameMilliseconds == nil {
                firstFrameMilliseconds = Self.milliseconds(from: start.duration(to: now))
            }
            if let previousFrameInstant {
                interframeMilliseconds.append(
                    Self.milliseconds(from: previousFrameInstant.duration(to: now))
                )
            }
            previousFrameInstant = now
            lastFrameRevision = update.revision
        } else if snapshot.frame == nil {
            lastFrameRevision = nil
        }
        if snapshot.cursor != lastCursor {
            if snapshot.cursor != nil {
                cursors += 1
            }
            lastCursor = snapshot.cursor
        }
    }

    func inputExerciseReadiness() -> ProbeInputExerciseReadiness {
        if let sessionFailure {
            return .failed(sessionFailure)
        }
        if let latestPointerMode {
            return .ready(latestPointerMode)
        }
        return .pending
    }

    func summary() -> ProbeObservationSummary {
        ProbeObservationSummary(
            frames: frames,
            frameBytes: frameBytes,
            firstFrameMilliseconds: firstFrameMilliseconds,
            p95InterframeMilliseconds: Self.percentile95(interframeMilliseconds),
            cursors: cursors,
            keyboardEvents: keyboardEvents,
            motionAcknowledgements: motionAcknowledgements,
            sessionFailure: sessionFailure
        )
    }

    private static func milliseconds(from duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func percentile95(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * 0.95).rounded(.up))
        return sorted[index]
    }
}

private enum ProbeInputExerciseReadiness: Sendable {
    case pending
    case ready(SpicePointerMode)
    case failed(String)
}

private struct ProbeObservationSummary {
    let frames: Int
    let frameBytes: Int
    let firstFrameMilliseconds: Double?
    let p95InterframeMilliseconds: Double?
    let cursors: Int
    let keyboardEvents: Int
    let motionAcknowledgements: Int
    let sessionFailure: String?
}

private struct ProbeBenchmarkReport: Codable {
    let client: String
    let connectMilliseconds: Double
    let observeSeconds: UInt64
    let frames: Int
    let framesPerSecond: Double
    let firstFrameMilliseconds: Double?
    let readyFrameMilliseconds: Double?
    let p95InterframeMilliseconds: Double?
    let observationCPUSeconds: Double
    let frameBytes: Int
    let cursors: Int
    let keyboardEvents: Int
    let motionAcknowledgements: Int
    let displayChannelCount: Int
    let damageOperations: UInt64
    let damageBytes: UInt64
    let snapshots: UInt64
    let fullFrameCopyBytes: UInt64
    let partialFrameCopyBytes: UInt64
    let directIOSurfaceWriteBytes: UInt64
    let cpuMaterializations: UInt64
    let cpuMaterializationBytes: UInt64
    let poolExhaustions: UInt64
    let inFlightLeases: Int
    let revisionedBackingEnabled: Bool
    let revisionedAllocatedFrames: Int
    let revisionedAllocatedBytes: Int
    let totalIOSurfaceAllocatedBytes: Int
    let gpuCopyBytes: UInt64
    let gpuErrors: UInt64
    let nativeVideoFrames: UInt64
    let nativeVideoFallbacks: UInt64
    let recommendedMaximumWorkingSetSize: UInt64
    let currentMetalAllocatedSize: UInt64
    let publisherSubmissions: UInt64
    let publisherSnapshotAttempts: UInt64
    let publisherEmittedFrames: UInt64
    let publisherEmittedIOSurfaceFrames: UInt64
    let publisherEmittedCPUOnlyFrames: UInt64
    let publisherStaleSnapshots: UInt64
    let publisherPendingEvictions: UInt64
    let publisherPendingSurfaces: Int
    let videoDecoderSessionCreations: UInt64
    let videoHardwareSessions: UInt64
    let videoSoftwareSessions: UInt64
    let videoHardwareQueryFailures: UInt64
    let videoDecodedFrames: UInt64
    let videoDroppedFrames: UInt64
    let videoCPUMaterializations: UInt64
    let advancedCPUFallbackFrames: UInt64
    let metalGenerationDisableCount: UInt64
    let firstMetalGenerationDisableReason: String?
    let surfaceAllocatedBytes: Int
    let maximumSurfaceBytes: Int

    init(
        client: String,
        connectMilliseconds: Double,
        observeSeconds: UInt64,
        frames: Int,
        framesPerSecond: Double,
        firstFrameMilliseconds: Double?,
        readyFrameMilliseconds: Double?,
        p95InterframeMilliseconds: Double?,
        observationCPUSeconds: Double,
        frameBytes: Int,
        cursors: Int,
        keyboardEvents: Int,
        motionAcknowledgements: Int,
        diagnostics: SpiceSessionDiagnostics
    ) {
        self.client = client
        self.connectMilliseconds = connectMilliseconds
        self.observeSeconds = observeSeconds
        self.frames = frames
        self.framesPerSecond = framesPerSecond
        self.firstFrameMilliseconds = firstFrameMilliseconds
        self.readyFrameMilliseconds = readyFrameMilliseconds
        self.p95InterframeMilliseconds = p95InterframeMilliseconds
        self.observationCPUSeconds = observationCPUSeconds
        self.frameBytes = frameBytes
        self.cursors = cursors
        self.keyboardEvents = keyboardEvents
        self.motionAcknowledgements = motionAcknowledgements
        displayChannelCount = diagnostics.displayChannelCount
        damageOperations = diagnostics.damageOperations
        damageBytes = diagnostics.damageBytes
        snapshots = diagnostics.snapshots
        fullFrameCopyBytes = diagnostics.fullFrameCopyBytes
        partialFrameCopyBytes = diagnostics.partialFrameCopyBytes
        directIOSurfaceWriteBytes = diagnostics.directIOSurfaceWriteBytes
        cpuMaterializations = diagnostics.cpuMaterializations
        cpuMaterializationBytes = diagnostics.cpuMaterializationBytes
        poolExhaustions = diagnostics.poolExhaustions
        inFlightLeases = diagnostics.inFlightLeases
        revisionedBackingEnabled = diagnostics.revisionedBackingEnabled
        revisionedAllocatedFrames = diagnostics.revisionedAllocatedFrames
        revisionedAllocatedBytes = diagnostics.revisionedAllocatedBytes
        totalIOSurfaceAllocatedBytes = diagnostics.totalIOSurfaceAllocatedBytes
        gpuCopyBytes = diagnostics.gpuCopyBytes
        gpuErrors = diagnostics.gpuErrors
        nativeVideoFrames = diagnostics.nativeVideoFrames
        nativeVideoFallbacks = diagnostics.nativeVideoFallbacks
        recommendedMaximumWorkingSetSize = diagnostics.recommendedMaximumWorkingSetSize
        currentMetalAllocatedSize = diagnostics.currentMetalAllocatedSize
        publisherSubmissions = diagnostics.publisherSubmissions
        publisherSnapshotAttempts = diagnostics.publisherSnapshotAttempts
        publisherEmittedFrames = diagnostics.publisherEmittedFrames
        publisherEmittedIOSurfaceFrames = diagnostics.publisherEmittedIOSurfaceFrames
        publisherEmittedCPUOnlyFrames = diagnostics.publisherEmittedCPUOnlyFrames
        publisherStaleSnapshots = diagnostics.publisherStaleSnapshots
        publisherPendingEvictions = diagnostics.publisherPendingEvictions
        publisherPendingSurfaces = diagnostics.publisherPendingSurfaces
        videoDecoderSessionCreations = diagnostics.videoDecoderSessionCreations
        videoHardwareSessions = diagnostics.videoHardwareSessions
        videoSoftwareSessions = diagnostics.videoSoftwareSessions
        videoHardwareQueryFailures = diagnostics.videoHardwareQueryFailures
        videoDecodedFrames = diagnostics.videoDecodedFrames
        videoDroppedFrames = diagnostics.videoDroppedFrames
        videoCPUMaterializations = diagnostics.videoCPUMaterializations
        advancedCPUFallbackFrames = diagnostics.advancedCPUFallbackFrames
        metalGenerationDisableCount = diagnostics.metalGenerationDisableCount
        firstMetalGenerationDisableReason = diagnostics.firstMetalGenerationDisableReason
        surfaceAllocatedBytes = diagnostics.surfaceAllocatedBytes
        maximumSurfaceBytes = diagnostics.maximumSurfaceBytes
    }

    enum CodingKeys: String, CodingKey {
        case client
        case connectMilliseconds = "connect_ms"
        case observeSeconds = "observe_seconds"
        case frames
        case framesPerSecond = "fps"
        case firstFrameMilliseconds = "first_frame_ms"
        case readyFrameMilliseconds = "ready_frame_ms"
        case p95InterframeMilliseconds = "p95_interframe_ms"
        case observationCPUSeconds = "observe_cpu_seconds"
        case frameBytes = "frame_bytes"
        case cursors
        case keyboardEvents = "keyboard_events"
        case motionAcknowledgements = "motion_acknowledgements"
        case displayChannelCount = "display_channel_count"
        case damageOperations = "damage_operations"
        case damageBytes = "damage_bytes"
        case snapshots
        case fullFrameCopyBytes = "full_frame_copy_bytes"
        case partialFrameCopyBytes = "partial_frame_copy_bytes"
        case directIOSurfaceWriteBytes = "direct_iosurface_write_bytes"
        case cpuMaterializations = "cpu_materializations"
        case cpuMaterializationBytes = "cpu_materialization_bytes"
        case poolExhaustions = "pool_exhaustions"
        case inFlightLeases = "in_flight_leases"
        case revisionedBackingEnabled = "revisioned_backing_enabled"
        case revisionedAllocatedFrames = "revisioned_allocated_frames"
        case revisionedAllocatedBytes = "revisioned_allocated_bytes"
        case totalIOSurfaceAllocatedBytes = "iosurface_allocated_bytes"
        case gpuCopyBytes = "gpu_copy_bytes"
        case gpuErrors = "gpu_errors"
        case nativeVideoFrames = "native_video_frames"
        case nativeVideoFallbacks = "native_video_fallbacks"
        case recommendedMaximumWorkingSetSize = "metal_recommended_working_set_bytes"
        case currentMetalAllocatedSize = "metal_current_allocated_bytes"
        case publisherSubmissions = "publisher_submissions"
        case publisherSnapshotAttempts = "publisher_snapshot_attempts"
        case publisherEmittedFrames = "publisher_emitted_frames"
        case publisherEmittedIOSurfaceFrames = "publisher_emitted_iosurface_frames"
        case publisherEmittedCPUOnlyFrames = "publisher_emitted_cpu_only_frames"
        case publisherStaleSnapshots = "publisher_stale_snapshots"
        case publisherPendingEvictions = "publisher_pending_evictions"
        case publisherPendingSurfaces = "publisher_pending_surfaces"
        case videoDecoderSessionCreations = "vt_session_creations"
        case videoHardwareSessions = "vt_hardware_sessions"
        case videoSoftwareSessions = "vt_software_sessions"
        case videoHardwareQueryFailures = "vt_hardware_query_failures"
        case videoDecodedFrames = "vt_decoded_frames"
        case videoDroppedFrames = "vt_dropped_frames"
        case videoCPUMaterializations = "vt_cpu_materializations"
        case advancedCPUFallbackFrames = "advanced_cpu_fallback_frames"
        case metalGenerationDisableCount = "metal_generation_disables"
        case firstMetalGenerationDisableReason = "first_metal_generation_disable_reason"
        case surfaceAllocatedBytes = "surface_allocated_bytes"
        case maximumSurfaceBytes = "surface_maximum_bytes"
    }
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case missingObservation(String)
    case fileTransferFailed(String)
    case clipboardFailed(String)
    case monitorConfigurationFailed(String)
    case sessionFailed(String)
    case audioFailed(String)
    case nativeVideoFailed(String)

    var description: String {
        switch self {
        case .usage:
            "usage: spice-probe HOST PORT [--tls|--tls-insecure-for-testing-only] "
                + "[--observe-seconds N] [--exercise-input] [--require-agent] "
                + "[--exercise-file-transfer] [--exercise-clipboard] "
                + "[--exercise-monitor-config] [--exercise-webdav] "
                + "[--exercise-playback|--exercise-record-synthetic] "
                + "[--benchmark-json] [--enable-h264|--enable-h265] "
                + "[--require-native-video]; "
                + "password is read from SPICE_PASSWORD"
        case let .missingObservation(name):
            "missing required live observation: \(name)"
        case let .fileTransferFailed(reason):
            "Agent file transfer failed: \(reason)"
        case let .clipboardFailed(reason):
            "Agent clipboard failed: \(reason)"
        case let .monitorConfigurationFailed(reason):
            "Agent monitor configuration failed: \(reason)"
        case let .sessionFailed(reason):
            "SPICE session failed while observing: \(reason)"
        case let .audioFailed(reason):
            "SPICE audio live gate failed: \(reason)"
        case let .nativeVideoFailed(reason):
            "native video validation failed: \(reason)"
        }
    }
}
