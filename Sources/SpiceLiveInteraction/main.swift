import AppKit
import CryptoKit
import Darwin
import QuartzCore
import SpiceLiveInteractionSupport
import SwiftSpice
import SwiftUI

private struct SpiceLiveOutcome: Sendable {
    let succeeded: Bool
    let stage: SpiceLiveInteractionStage
    let recordPath: String?
    let diagnostics: String?
}

@MainActor
private final class SpiceLiveInteractionHarness {
    private let environment: [String: String]
    private let runner: SpiceLiveProcessRunner
    private var window: NSWindow?
    private var hostingView: NSHostingView<SpiceDesktopView>?
    private var readinessDiagnostics: String?

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        runner: SpiceLiveProcessRunner = .ssh
    ) {
        self.environment = environment
        self.runner = runner
    }

    func run() async -> SpiceLiveOutcome {
        var stage = SpiceLiveInteractionStage.configuration
        var configuration: SpiceRemoteLiveConfiguration?
        var runDirectory: String?
        var traceProcess: SpiceLiveChildProcess?
        var orchestrator: SpiceLiveTraceOrchestrator?
        let session = SpiceSession()
        let outputURL = makeOutputURL()

        do {
            let parsed = try SpiceRemoteLiveConfiguration(environment: environment)
            configuration = parsed

            stage = .remoteStatus
            let status = try await parsed.runRemoteScript("status.sh", runner: runner)
            guard status.status == 0,
                  status.outputLines.contains("container=\(parsed.container)"),
                  status.outputLines.contains("spice_listener=ready"),
                  status.outputLines.contains("control_listener=ready") else {
                throw SpiceLiveInteractionSupportError.childFailed
            }
            let evidenceDirectory = try parsed.runDirectory(from: status)
            runDirectory = evidenceDirectory

            stage = .ticket
            let ticketResult = try await parsed.runRemoteScript("ticket.sh", runner: runner)
            let ticket = try parsed.ticket(from: ticketResult)

            stage = .connection
            _ = try await session.connect(
                endpoint: SpiceEndpoint(host: parsed.endpointHost, port: parsed.endpointPort),
                credentials: SpiceCredentials(password: ticket)
            )

            stage = .foregroundWindow
            let initialMetrics = session.presentationDiagnostics.snapshot()
            installWindow(desktop: session.desktop)

            stage = .initialPresentation
            try await waitForInitialPresentation(
                desktop: session.desktop,
                diagnostics: session.presentationDiagnostics,
                baseline: initialMetrics,
                timeout: .seconds(20)
            )

            let token = String(format: "%016llx", UInt64.random(in: 1...UInt64.max))
            let checksum = markerChecksum(token: token)
            let writer = SpiceInteractionTraceJSONLWriter(outputURL: outputURL)
            let activeCapture = try SpiceInteractionTraceCapture(
                session: session,
                writer: writer,
                pairId: "live-\(token)",
                version: "v0.3.1",
                runId: URL(fileURLWithPath: evidenceDirectory).lastPathComponent,
                order: 1,
                actionClass: .click,
                token: token,
                checksum: checksum
            )
            let activeOrchestrator = SpiceLiveTraceOrchestrator(
                capture: activeCapture,
                outputURL: outputURL
            )
            orchestrator = activeOrchestrator

            stage = .arm
            let trace = try parsed.launchControlTrace(
                actionClass: "click",
                token: token,
                runner: runner
            )
            traceProcess = trace
            let armed = try await trace.readOutputLine(within: .seconds(15))
            guard armed == "PERF_ARMED action_class=click token=\(token)" else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }

            stage = .inputSend
            let scheduled = SpiceInteractionHostClock.nowNanoseconds()
            let hostInput = SpiceInteractionHostClock.nowNanoseconds()
            let sendStarted = SpiceInteractionHostClock.nowNanoseconds()
            try activeCapture.recordHostInput(
                scheduledNs: scheduled,
                hostInputNs: hostInput,
                sendStartedNs: sendStarted
            )
            try await session.send(.mousePress(.left))
            try activeCapture.recordSendCompleted(
                at: SpiceInteractionHostClock.nowNanoseconds()
            )
            try await session.send(.mouseRelease(.left))

            stage = .guestEvidence
            let traceResult = try await trace.finish(within: .seconds(15))
            guard traceResult.status == 0 else {
                throw SpiceLiveInteractionSupportError.childFailed
            }
            let guest = try SpiceRemoteGuestTrace(
                lines: [armed] + traceResult.outputLines,
                actionClass: "click",
                token: token
            )
            try activeCapture.recordGuestEvidence(
                receivedNs: guest.receivedNanoseconds,
                drawnNs: guest.drawnNanoseconds,
                markerRevision: guest.markerRevision
            )

            stage = .exactPresentation
            let finalized = try await activeOrchestrator.completeAfterExactPresentation(
                timeout: .seconds(15)
            )

            stage = .remoteCollector
            try await parsed.appendRecord(
                finalized.encodedJSONL,
                runDirectory: evidenceDirectory,
                runner: runner
            )
            await trace.terminateAndWait()
            traceProcess = nil
            await tearDownWindow(diagnostics: session.presentationDiagnostics)
            await session.disconnect()
            return SpiceLiveOutcome(
                succeeded: true,
                stage: .remoteCollector,
                recordPath: outputURL.path,
                diagnostics: nil
            )
        } catch {
            let finalized = try? orchestrator?.finishDerivedInvalid()
            if let configuration,
               let runDirectory,
               let encoded = finalized?.encodedJSONL {
                try? await configuration.appendRecord(
                    encoded,
                    runDirectory: runDirectory,
                    runner: runner
                )
            }
            await traceProcess?.terminateAndWait()
            await tearDownWindow(diagnostics: session.presentationDiagnostics)
            await session.disconnect()
            return SpiceLiveOutcome(
                succeeded: false,
                stage: stage,
                recordPath: FileManager.default.fileExists(atPath: outputURL.path)
                    ? outputURL.path
                    : nil,
                diagnostics: readinessDiagnostics
            )
        }
    }

    private func installWindow(desktop: SpiceDesktopSource) {
        let desktopView = SpiceDesktopView(desktop: desktop) { _ in }
        let hostingView = NSHostingView(rootView: desktopView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        hostingView.autoresizingMask = [.width, .height]

        let window = NSWindow(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.title = "SwiftSpice Live Interaction"
        window.contentView = hostingView
        window.center()
        self.hostingView = hostingView
        self.window = window
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    private func waitForInitialPresentation(
        desktop: SpiceDesktopSource,
        diagnostics: SpicePresentationDiagnostics,
        baseline: SpicePresentationMetrics,
        timeout: Duration
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            hostingView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            let metrics = diagnostics.snapshot()
            if let window,
               let hostingView,
               window.isVisible,
               window.occlusionState.contains(.visible),
               hostingView.bounds.width > 0,
               hostingView.bounds.height > 0,
               hostingView.visibleRect.width > 0,
               hostingView.visibleRect.height > 0,
               desktop.metrics().visibleSubscriptions == 1,
               metrics.metalCommandBuffersCommitted > baseline.metalCommandBuffersCommitted,
               metrics.metalPresentedFrames > baseline.metalPresentedFrames {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let metrics = diagnostics.snapshot()
        let sourceMetrics = desktop.metrics()
        readinessDiagnostics = [
            "window_visible=\(window?.isVisible == true)",
            "window_occluded=\(window?.occlusionState.contains(.visible) != true)",
            "hosting_hidden=\(hostingView?.isHiddenOrHasHiddenAncestor != false)",
            "bounds=\(Int(hostingView?.bounds.width ?? 0))x\(Int(hostingView?.bounds.height ?? 0))",
            "visible_rect=\(Int(hostingView?.visibleRect.width ?? 0))x\(Int(hostingView?.visibleRect.height ?? 0))",
            "subscriptions=\(sourceMetrics.subscriptions)",
            "visible_subscriptions=\(sourceMetrics.visibleSubscriptions)",
            "commit_delta=\(metrics.metalCommandBuffersCommitted - baseline.metalCommandBuffersCommitted)",
            "presented_delta=\(metrics.metalPresentedFrames - baseline.metalPresentedFrames)",
        ].joined(separator: ",")
        throw SpiceLiveInteractionSupportError.operationTimedOut
    }

    private func tearDownWindow(
        diagnostics: SpicePresentationDiagnostics
    ) async {
        let committedBeforeDismantle = diagnostics.snapshot().metalCommandBuffersCommitted
        findFramebuffer(in: hostingView)?.prepareForDismantle()
        window?.orderOut(nil)
        window?.contentView = nil
        hostingView = nil
        CATransaction.flush()

        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while diagnostics.snapshot().metalCommitToCompletion.sampleCount
            < committedBeforeDismantle,
            ContinuousClock().now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await Task.yield()
        CATransaction.flush()
        window?.close()
        window = nil
        await Task.yield()
    }

    private func findFramebuffer(in view: NSView?) -> SpiceFramebufferView? {
        guard let view else { return nil }
        if let framebuffer = view as? SpiceFramebufferView { return framebuffer }
        for child in view.subviews {
            if let framebuffer = findFramebuffer(in: child) { return framebuffer }
        }
        return nil
    }

    private func makeOutputURL() -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "swiftspice-live-interaction-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        return directory.appending(path: "input-events.jsonl")
    }

    private func markerChecksum(token: String) -> UInt32 {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

@MainActor
private final class SpiceLiveApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var exitStatus: Int32 = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let outcome = await SpiceLiveInteractionHarness().run()
            if outcome.succeeded {
                print(
                    "PERF_LIVE_INTERACTION_SUCCESS schema=2 exact_presented=true record_path=\(outcome.recordPath ?? "unavailable")"
                )
                exitStatus = 0
            } else {
                let diagnostics = outcome.diagnostics.map { " diagnostics=\($0)" } ?? ""
                fputs(
                    "PERF_LIVE_INTERACTION_FAILED stage=\(outcome.stage.rawValue) record_path=\(outcome.recordPath ?? "unavailable")\(diagnostics)\n",
                    stderr
                )
                exitStatus = outcome.stage == .configuration ? 2 : 1
            }
            NSApp.stop(nil)
            if let wakeEvent = NSEvent.otherEvent(
                with: .applicationDefined,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 0,
                data1: 0,
                data2: 0
            ) {
                NSApp.postEvent(wakeEvent, atStart: false)
            }
        }
    }
}

@main
private enum SpiceLiveInteractionMain {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("Usage: spice-live-interaction")
            print("Requires the complete isolated SWIFTSPICE_LIVE_* and SWIFTSPICE_PERF_* environment.")
            return
        }
        guard arguments.isEmpty else {
            fputs("Usage: spice-live-interaction\n", stderr)
            Darwin.exit(2)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = SpiceLiveApplicationDelegate()
        application.delegate = delegate
        application.run()
        withExtendedLifetime(delegate) {}
        Darwin.exit(delegate.exitStatus)
    }
}
