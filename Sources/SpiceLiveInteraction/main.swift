import AppKit
import Darwin
import QuartzCore
import SpiceLiveInteractionSupport
import SwiftSpice
import SwiftUI

private enum LiveStage: String, Sendable {
    case configuration
    case remoteStatus = "remote_status"
    case ticket
    case foregroundWindow = "foreground_window"
    case connection
    case initialPresentation = "initial_presentation"
    case arm
    case inputSend = "input_send"
    case guestEvidence = "guest_evidence"
    case exactPresentation = "exact_presentation"
    case localAppend = "local_append"
    case remoteCollector = "remote_collector"
}

private struct LiveOutcome: Sendable {
    let succeeded: Bool
    let stage: LiveStage
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

    func run() async -> LiveOutcome {
        var stage = LiveStage.configuration
        var configuration: SpiceRemoteLiveConfiguration?
        var remoteStatus: SpiceRemoteRunStatus?
        var traceProcess: SpiceLiveChildProcess?
        var activeCapture: SpiceInteractionTraceCapture?
        var pendingRemoteRecord: Data?
        var remoteAppendAttempted = false
        var runExecution: SpiceLiveSingleRunExecution?
        var sessionEventTask: Task<Void, Never>?
        var outputURL: URL?
        let session = SpiceSession()
        let motionAcknowledgements = SpiceLiveMotionAcknowledgementMonitor()

        do {
            let parsed = try SpiceRemoteLiveConfiguration(environment: environment)
            configuration = parsed
            let plan = try SpiceLiveInteractionClusterPlan(clusterID: parsed.clusterID)
            runExecution = try SpiceLiveSingleRunExecution(steps: plan.steps)
            let output = try SpiceLiveLocalOutput.create(
                baseDirectory: FileManager.default.temporaryDirectory,
                runID: parsed.runID
            )
            outputURL = output

            sessionEventTask = Task {
                for await event in session.events {
                    guard !Task.isCancelled else { return }
                    if case .mouseMotionAcknowledged = event {
                        await motionAcknowledgements.recordAcknowledgement(
                            at: SpiceInteractionHostClock.nowNanoseconds()
                        )
                    }
                }
            }

            stage = .remoteStatus
            let statusCommand = try parsed.command(forRemoteScript: "status.sh")
            let statusChild = try runner.launch(arguments: statusCommand.arguments)
            let statusResult = try await statusChild.finish(within: .seconds(20))
            let status = try SpiceRemoteRunStatus(
                result: statusResult,
                configuration: parsed
            )
            remoteStatus = status

            stage = .ticket
            let ticketCommand = try parsed.command(forRemoteScript: "ticket.sh")
            let ticketChild = try runner.launch(arguments: ticketCommand.arguments)
            let ticketResult = try await ticketChild.finish(within: .seconds(20))
            let ticket = try parsed.ticket(from: ticketResult)

            stage = .foregroundWindow
            installWindow(desktop: session.desktop)
            try await waitForVisibleDemand(desktop: session.desktop, timeout: .seconds(20))
            let initialMetrics = session.presentationDiagnostics.snapshot()

            stage = .connection
            _ = try await session.connect(
                endpoint: SpiceEndpoint(
                    host: parsed.endpointHost,
                    port: parsed.endpointPort
                ),
                credentials: SpiceCredentials(password: ticket)
            )

            stage = .initialPresentation
            let readiness = try await waitForInitialPresentation(
                desktop: session.desktop,
                diagnostics: session.presentationDiagnostics,
                baseline: initialMetrics,
                timeout: .seconds(20)
            )

            let writer = SpiceInteractionTraceJSONLWriter(outputURL: output)
            for stepIndex in plan.steps.indices {
                guard var execution = runExecution else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
                let step = try execution.beginNextStep(
                    readiness: stepIndex == plan.steps.startIndex ? readiness : nil
                )
                runExecution = execution

                let capture = try SpiceInteractionTraceCapture(
                    session: session,
                    pairId: step.pairID,
                    version: parsed.version,
                    runId: status.evidenceRunID,
                    order: step.order,
                    actionClass: step.actionClass,
                    token: step.token,
                    checksum: step.checksum
                )
                activeCapture = capture

                stage = .arm
                let trace = try parsed.launchControlTrace(
                    actionClass: step.actionClass.rawValue,
                    token: step.token,
                    runner: runner
                )
                traceProcess = trace
                let armed = try await trace.readOutputLine(within: .seconds(15))
                guard armed == "PERF_ARMED action_class=\(step.actionClass.rawValue) token=\(step.token)" else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }

                stage = .inputSend
                let dispatch = SpiceLiveInputDispatchMetadata.directSessionAPI
                guard !dispatch.reportsAppKitReceipt else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
                let pointerMode = session.currentPointerMode
                let motionEpoch = step.requiresMotionAcknowledgement(for: pointerMode)
                    ? try await motionAcknowledgements.beginCleanEpoch()
                    : nil
                let scheduled = SpiceInteractionHostClock.nowNanoseconds()
                let hostInput = SpiceInteractionHostClock.nowNanoseconds()
                let sendStarted = SpiceInteractionHostClock.nowNanoseconds()
                try capture.recordHostInput(
                    scheduledNs: scheduled,
                    hostInputNs: hostInput,
                    sendStartedNs: sendStarted
                )
                let inputs = step.inputs(for: pointerMode)
                guard !inputs.isEmpty else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
                for input in inputs {
                    try await session.send(input)
                }
                try capture.recordSendCompleted(
                    at: SpiceInteractionHostClock.nowNanoseconds()
                )
                if let motionEpoch {
                    let acknowledgedAt = try await withSpiceLiveTimeout(.seconds(15)) {
                        try await motionAcknowledgements.waitForAcknowledgement(
                            after: motionEpoch,
                            notBefore: sendStarted
                        )
                    }
                    try capture.recordMotionAcknowledged(at: acknowledgedAt)
                }

                stage = .guestEvidence
                let traceResult = try await trace.finish(within: .seconds(15))
                guard traceResult.status == 0 else {
                    throw SpiceLiveInteractionSupportError.childFailed
                }
                let guest = try SpiceRemoteGuestTrace(
                    lines: [armed] + traceResult.outputLines,
                    actionClass: step.actionClass.rawValue,
                    token: step.token
                )
                try capture.recordGuestEvidence(
                    receivedNs: guest.receivedNanoseconds,
                    drawnNs: guest.drawnNanoseconds,
                    markerRevision: guest.markerRevision
                )

                stage = .exactPresentation
                _ = try await withSpiceLiveTimeout(.seconds(15)) {
                    try await capture.waitForExactPresentation()
                }
                guard var presentedExecution = runExecution else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
                try presentedExecution.recordExactPresentation(order: step.order)
                runExecution = presentedExecution

                stage = .localAppend
                let record = try capture.append(to: writer)
                activeCapture = nil
                let encoded = try SpiceLiveCanonicalRecord.encode(record)
                pendingRemoteRecord = encoded
                guard var localExecution = runExecution else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
                try localExecution.recordLocalAppend(order: step.order)
                runExecution = localExecution

                stage = .remoteCollector
                remoteAppendAttempted = true
                try await parsed.appendRecord(
                    encoded,
                    runDirectory: status.runDirectory,
                    runner: runner
                )
                pendingRemoteRecord = nil
                remoteAppendAttempted = false
                guard var remoteExecution = runExecution else {
                    throw SpiceLiveInteractionSupportError.invalidTraceProtocol
                }
                try remoteExecution.recordRemoteAppend(order: step.order)
                runExecution = remoteExecution
                _ = await trace.terminateAndWait()
                traceProcess = nil
            }

            guard runExecution?.completed == true else {
                throw SpiceLiveInteractionSupportError.invalidTraceProtocol
            }
            sessionEventTask?.cancel()
            await tearDownWindow(diagnostics: session.presentationDiagnostics)
            await session.disconnect()
            return LiveOutcome(
                succeeded: true,
                stage: .remoteCollector,
                recordPath: output.path,
                diagnostics: nil
            )
        } catch {
            runExecution?.fail()
            if let capture = activeCapture,
               let outputURL {
                let writer = SpiceInteractionTraceJSONLWriter(outputURL: outputURL)
                if let record = try? capture.append(to: writer),
                   let encoded = try? SpiceLiveCanonicalRecord.encode(record) {
                    pendingRemoteRecord = encoded
                }
            }
            if let configuration,
               let remoteStatus,
               let pendingRemoteRecord,
               !remoteAppendAttempted {
                try? await configuration.appendRecord(
                    pendingRemoteRecord,
                    runDirectory: remoteStatus.runDirectory,
                    runner: runner
                )
            }
            _ = await traceProcess?.terminateAndWait()
            sessionEventTask?.cancel()
            await tearDownWindow(diagnostics: session.presentationDiagnostics)
            await session.disconnect()
            return LiveOutcome(
                succeeded: false,
                stage: stage,
                recordPath: outputURL.flatMap {
                    FileManager.default.fileExists(atPath: $0.path) ? $0.path : nil
                },
                diagnostics: readinessDiagnostics
            )
        }
    }

    private func installWindow(desktop: SpiceDesktopSource) {
        let hostingView = NSHostingView(
            rootView: SpiceDesktopView(desktop: desktop) { _ in }
        )
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

    private func readinessState(desktop: SpiceDesktopSource) -> SpiceLiveReadinessState {
        SpiceLiveReadinessState(
            windowVisible: window?.isVisible == true,
            windowOccluded: window?.occlusionState.contains(.visible) != true,
            hostingVisible: hostingView?.isHiddenOrHasHiddenAncestor == false
                && (hostingView?.bounds.width ?? 0) > 0
                && (hostingView?.bounds.height ?? 0) > 0
                && (hostingView?.visibleRect.width ?? 0) > 0
                && (hostingView?.visibleRect.height ?? 0) > 0,
            visibleSubscriptions: desktop.metrics().visibleSubscriptions,
            metalPresentedFrames: desktop.presentationDiagnostics.snapshot().metalPresentedFrames
        )
    }

    private func waitForVisibleDemand(
        desktop: SpiceDesktopSource,
        timeout: Duration
    ) async throws {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            hostingView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            if readinessState(desktop: desktop).visibleDemandReady { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        recordReadinessDiagnostics(desktop: desktop, baseline: nil)
        throw SpiceLiveInteractionSupportError.operationTimedOut
    }

    private func waitForInitialPresentation(
        desktop: SpiceDesktopSource,
        diagnostics: SpicePresentationDiagnostics,
        baseline: SpicePresentationMetrics,
        timeout: Duration
    ) async throws -> SpiceLiveReadinessPermit {
        let deadline = ContinuousClock().now.advanced(by: timeout)
        while ContinuousClock().now < deadline {
            hostingView?.layoutSubtreeIfNeeded()
            window?.displayIfNeeded()
            let metrics = diagnostics.snapshot()
            if metrics.metalCommandBuffersCommitted > baseline.metalCommandBuffersCommitted,
               let permit = readinessState(desktop: desktop).permit(
                   since: baseline.metalPresentedFrames
               ) {
                return permit
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        recordReadinessDiagnostics(desktop: desktop, baseline: baseline)
        throw SpiceLiveInteractionSupportError.operationTimedOut
    }

    private func recordReadinessDiagnostics(
        desktop: SpiceDesktopSource,
        baseline: SpicePresentationMetrics?
    ) {
        let state = readinessState(desktop: desktop)
        let metrics = desktop.presentationDiagnostics.snapshot()
        readinessDiagnostics = [
            "window_visible=\(state.windowVisible)",
            "window_occluded=\(state.windowOccluded)",
            "hosting_visible=\(state.hostingVisible)",
            "visible_subscriptions=\(state.visibleSubscriptions)",
            "commit_delta=\(delta(metrics.metalCommandBuffersCommitted, baseline?.metalCommandBuffersCommitted))",
            "presented_delta=\(delta(metrics.metalPresentedFrames, baseline?.metalPresentedFrames))",
            "cpu_fallback=\(metrics.cpuFallbackFrames)",
            "drawable_miss=\(metrics.metalDrawableMisses)",
            "gpu_busy=\(metrics.metalGPUBusySkips)",
            "metal_error=\(metrics.metalPresentationErrors)",
        ].joined(separator: ",")
    }

    private func delta(_ value: UInt64, _ baseline: UInt64?) -> UInt64 {
        guard let baseline, value >= baseline else { return value }
        return value - baseline
    }

    private func tearDownWindow(diagnostics: SpicePresentationDiagnostics) async {
        let committed = diagnostics.snapshot().metalCommandBuffersCommitted
        findFramebuffer(in: hostingView)?.prepareForDismantle()
        window?.orderOut(nil)
        window?.contentView = nil
        hostingView = nil
        CATransaction.flush()
        let deadline = ContinuousClock().now.advanced(by: .seconds(2))
        while diagnostics.snapshot().metalCommitToCompletion.sampleCount < committed,
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
            if let event = NSEvent.otherEvent(
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
                NSApp.postEvent(event, atStart: false)
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
