import AppKit
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
            let info = try await session.connect(
                endpoint: configuration.endpoint,
                credentials: credentials
            )

            print("SPICE session \(info.sessionID) connected")
            print("mouse modes: supported=\(info.supportedMouseModes) current=\(info.currentMouseMode)")
            print("agent connected: \(info.agentConnected)")
            for channel in info.channels {
                print("channel type=\(channel.type) id=\(channel.id)")
            }
            if configuration.requireAgent, !info.agentConnected {
                throw ProbeError.missingObservation("VDAgent connection")
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
            if let seconds = configuration.observeSeconds {
                try await observe(
                    session: session,
                    seconds: seconds,
                    exerciseInput: configuration.exerciseInput
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
        return Configuration(
            endpoint: SpiceEndpoint(host: arguments[0], port: port, tlsPolicy: tlsPolicy),
            observeSeconds: try optionalUInt64(after: "--observe-seconds", in: arguments),
            exerciseInput: arguments.contains("--exercise-input"),
            requireAgent: arguments.contains("--require-agent")
                || arguments.contains("--exercise-file-transfer")
                || arguments.contains("--exercise-clipboard")
                || arguments.contains("--exercise-monitor-config"),
            exerciseFileTransfer: arguments.contains("--exercise-file-transfer"),
            exerciseClipboard: arguments.contains("--exercise-clipboard"),
            exerciseMonitorConfiguration: arguments.contains("--exercise-monitor-config")
        )
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
        exerciseInput: Bool
    ) async throws {
        let observations = ProbeObservations()
        let eventTask = Task {
            for await event in session.events {
                await observations.record(event)
                print(description(of: event))
            }
        }
        defer { eventTask.cancel() }

        if exerciseInput {
            try await session.send(.keyDown(scanCode: 0x1e))
            try await session.send(.keyUp(scanCode: 0x1e))
            for _ in 0..<8 {
                try await session.send(.mouseMotion(dx: 1, dy: 1))
            }
        }

        try await Task.sleep(for: .seconds(seconds))
        let summary = await observations.summary()
        print(
            "observed: frames=\(summary.frames) cursors=\(summary.cursors) "
                + "keyboard=\(summary.keyboardEvents) motion-acks=\(summary.motionAcknowledgements)"
        )
        guard summary.frames > 0 else {
            throw ProbeError.missingObservation("Display frame")
        }
        if exerciseInput, summary.motionAcknowledgements == 0 {
            throw ProbeError.missingObservation("Inputs mouse-motion acknowledgement")
        }
    }

    private static func description(of event: SpiceSessionEvent) -> String {
        switch event {
        case let .frame(frame):
            "frame surface=\(frame.surfaceID) size=\(frame.width)x\(frame.height) "
                + "bytes=\(frame.pixels.count)"
        case let .surfaceDestroyed(surfaceID):
            "surface destroyed id=\(surfaceID)"
        case let .displayConfiguration(configuration):
            "display configuration channel=\(configuration.channelID) "
                + "monitors=\(configuration.monitors.count)"
        case let .cursor(cursor):
            "cursor position=\(cursor.x),\(cursor.y) visible=\(cursor.isVisible)"
        case let .keyboardModifiers(modifiers):
            "keyboard modifiers=\(modifiers)"
        case .mouseMotionAcknowledged:
            "mouse motion acknowledged"
        case let .mouseMode(supported, current):
            "mouse mode supported=\(supported) current=\(current)"
        case let .migration(event):
            "migration event=\(event)"
        case let .failed(error):
            "session failed: \(error)"
        case .disconnected:
            "session disconnected"
        }
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
    let requireAgent: Bool
    let exerciseFileTransfer: Bool
    let exerciseClipboard: Bool
    let exerciseMonitorConfiguration: Bool
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
    private var frames = 0
    private var cursors = 0
    private var keyboardEvents = 0
    private var motionAcknowledgements = 0

    func record(_ event: SpiceSessionEvent) {
        switch event {
        case .frame:
            frames += 1
        case .cursor:
            cursors += 1
        case .keyboardModifiers:
            keyboardEvents += 1
        case .mouseMotionAcknowledged:
            motionAcknowledgements += 1
        default:
            break
        }
    }

    func summary() -> ProbeObservationSummary {
        ProbeObservationSummary(
            frames: frames,
            cursors: cursors,
            keyboardEvents: keyboardEvents,
            motionAcknowledgements: motionAcknowledgements
        )
    }
}

private struct ProbeObservationSummary {
    let frames: Int
    let cursors: Int
    let keyboardEvents: Int
    let motionAcknowledgements: Int
}

private enum ProbeError: Error, CustomStringConvertible {
    case usage
    case missingObservation(String)
    case fileTransferFailed(String)
    case clipboardFailed(String)
    case monitorConfigurationFailed(String)

    var description: String {
        switch self {
        case .usage:
            "usage: spice-probe HOST PORT [--tls|--tls-insecure-for-testing-only] "
                + "[--observe-seconds N] [--exercise-input] [--require-agent] "
                + "[--exercise-file-transfer] [--exercise-clipboard] "
                + "[--exercise-monitor-config]; "
                + "password is read from SPICE_PASSWORD"
        case let .missingObservation(name):
            "missing required live observation: \(name)"
        case let .fileTransferFailed(reason):
            "Agent file transfer failed: \(reason)"
        case let .clipboardFailed(reason):
            "Agent clipboard failed: \(reason)"
        case let .monitorConfigurationFailed(reason):
            "Agent monitor configuration failed: \(reason)"
        }
    }
}
