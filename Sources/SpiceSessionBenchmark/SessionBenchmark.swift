import AppKit
import Foundation
import SwiftSpice

func withBenchmarkTimeout<Value: Sendable>(
    seconds: Int,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw SessionBenchmarkError.timedOut
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

@MainActor
final class SessionBenchmark {
    let configuration: BenchmarkConfiguration
    private let session = SpiceSession()
    private let runID = UUID().uuidString.lowercased()
    private var latestSnapshot: SpiceDesktopSnapshot?
    private var lastFrameIdentity: SpiceInteractionFrameIdentity?
    private var measuredFrames = 0
    private var frameSizes: Set<String> = []
    private var records: [SpiceInteractionTraceRecord] = []
    private var measurementStart: ProcessMeasurement?
    private var window: NSWindow?
    private var framebuffer: SpiceFramebufferView?

    init(configuration: BenchmarkConfiguration) { self.configuration = configuration }

    func run() async -> Bool {
        let connectStart = SpiceInteractionHostClock.nowNanoseconds()
        var connectMilliseconds: Double?
        var failure: String?
        let subscription = session.desktop.subscribe()
        subscription.setDemand(.visible)
        // Owned by this run; cancellation and subscription teardown precede disconnect.
        let desktopTask = Task {
            for await snapshot in subscription.updates {
                latestSnapshot = snapshot
                guard let frame = snapshot.frame,
                    snapshot.interactionFrameIdentity != lastFrameIdentity
                else { continue }
                lastFrameIdentity = snapshot.interactionFrameIdentity
                if measurementStart != nil {
                    measuredFrames += 1
                    if frameSizes.count < 16 {
                        frameSizes.insert("\(frame.frame.width)x\(frame.frame.height)")
                    }
                }
            }
        }
        do {
            let session = session
            let configuration = configuration
            _ = try await withBenchmarkTimeout(seconds: configuration.timeoutSeconds) {
                try await session.connect(
                    endpoint: configuration.endpoint,
                    credentials: SpiceCredentials(password: configuration.password)
                )
            }
            connectMilliseconds =
                Double(SpiceInteractionHostClock.nowNanoseconds() - connectStart) / 1_000_000
            if !configuration.headless { showWindow() }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.measure() }
                group.addTask {
                    for await event in session.events {
                        switch event {
                        case .failed, .disconnected: throw SessionBenchmarkError.sessionEnded
                        default: break
                        }
                    }
                    try Task.checkCancellation()
                    throw SessionBenchmarkError.sessionEnded
                }
                defer { group.cancelAll() }
                try await group.next()
            }
        } catch {
            failure = Self.failureCategory(error)
        }
        let end = ProcessMeasurement()
        let start = measurementStart ?? end
        // Stop counting frames before the diagnostics actor hop so FPS and
        // resource measurements describe the same observation window.
        measurementStart = nil
        let diagnostics = await session.diagnosticsSnapshot()
        // Export outside the measured window and after the diagnostic snapshot:
        // this explicit CPU readback must not contaminate presentation metrics.
        if let destination = configuration.snapshotURL {
            do {
                try writeBenchmarkSnapshot(latestSnapshot?.frame?.frame, to: destination)
            } catch {
                failure = SessionBenchmarkError.outputFailed.rawValue
            }
        }
        desktopTask.cancel()
        subscription.setDemand(.none)
        subscription.cancel()
        await desktopTask.value
        framebuffer?.prepareForDismantle()
        let scale = window.map { Double($0.backingScaleFactor) }
        let refresh = window?.screen?.maximumFramesPerSecond
        window?.orderOut(nil)
        window = nil
        framebuffer = nil
        await session.disconnect()

        let seconds = Double(end.nanoseconds - start.nanoseconds) / 1_000_000_000
        let codecPolicy =
            switch configuration.endpoint.videoCodecPolicy {
            case .mjpegOnly: "mjpeg_only"
            case .h264AndMJPEG: "h264_and_mjpeg"
            case .h265AndMJPEG: "h265_and_mjpeg"
            }
        let presentationStatus: String
        if configuration.headless {
            presentationStatus = "headless"
        } else if diagnostics.metalPresentedFrames > 0 {
            presentationStatus = "metal_presented"
        } else if diagnostics.cpuFallbackFrames > 0 {
            presentationStatus = "cpu_fallback"
        } else {
            presentationStatus = "no_confirmed_presentation"
        }
        let report = SessionBenchmarkReport(
            runID: runID, label: configuration.label,
            mode: configuration.markerBase == nil ? "observe" : "interaction",
            status: failure == nil ? "completed" : "failed", failure: failure,
            codecPolicy: codecPolicy,
            tls: configuration.endpoint.tlsPolicy != nil, headless: configuration.headless,
            presentationStatus: presentationStatus,
            warmup: configuration.markerBase == nil ? 0 : configuration.warmup,
            requestedSamples: configuration.markerBase == nil ? 0 : configuration.samples,
            intervalMilliseconds: configuration.intervalMilliseconds,
            connectMilliseconds: connectMilliseconds,
            measuredSeconds: seconds, processCPUSeconds: end.cpuSeconds - start.cpuSeconds,
            processPeakResidentBytesAtStart: start.peakResidentBytes,
            processPeakResidentBytesAtEnd: end.peakResidentBytes,
            desktopFrames: measuredFrames,
            desktopFramesPerSecond: seconds > 0 ? Double(measuredFrames) / seconds : 0,
            frameSizes: frameSizes.sorted(), localBackingScale: scale,
            localMaximumFramesPerSecond: refresh,
            interaction: InteractionStatistics(records: records),
            diagnosticsSinceConnect: DiagnosticReport(diagnostics)
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(report)
            data.append(0x0A)
            try FileHandle.standardOutput.write(contentsOf: data)
        } catch {
            Self.progress(SessionBenchmarkError.outputFailed.rawValue)
            return false
        }
        if let failure { Self.progress(failure) }
        return failure == nil
    }

    private func showWindow() {
        let view = SpiceFramebufferView(desktop: session.desktop, surface: .primary) { _ in }
        // Match the layer-backed host supplied by SwiftUI in the bundled viewer.
        view.wantsLayer = true
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_024, height: 768),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "SwiftSpice session benchmark"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate()
        window.displayIfNeeded()
        self.window = window
        framebuffer = view
    }

    private func measure() async throws {
        guard let base = configuration.markerBase, let traceURL = configuration.traceURL else {
            measurementStart = ProcessMeasurement()
            if let frame = latestSnapshot?.frame {
                frameSizes.insert("\(frame.frame.width)x\(frame.frame.height)")
            }
            try await Task.sleep(for: .seconds(configuration.observeSeconds))
            guard latestSnapshot?.frame != nil else { throw SessionBenchmarkError.noFrames }
            return
        }
        Self.progress(
            "Waiting for initial guest marker \(SessionMarker.token(base)); fullscreen and reset the guest page."
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(configuration.readyTimeoutSeconds))
        var ready = false
        while clock.now < deadline {
            try Task.checkCancellation()
            if let snapshot = latestSnapshot,
                case .exact(let payload, _) = SpiceInteractionMarkerROIDetector.detect(
                    in: snapshot,
                    expectedToken: SessionMarker.token(base),
                    expectedChecksum: SessionMarker.checksum(base)
                ), payload.markerRevision == 0,
                payload.guestReceivedNs != nil, payload.guestMarkerDrawnNs != nil
            {
                ready = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready else { throw SessionBenchmarkError.markerNotReady }
        let writer = SpiceInteractionTraceJSONLWriter(outputURL: traceURL)
        for index in 1...(configuration.warmup + configuration.samples) {
            try Task.checkCancellation()
            if index == configuration.warmup + 1 { measurementStart = ProcessMeasurement() }
            let tokenValue = base + UInt64(index)
            let capture = try SpiceInteractionTraceCapture(
                session: session, writer: writer, pairId: configuration.label,
                version: "swiftspice-session-v1", runId: runID, order: UInt64(index),
                actionClass: .key, token: SessionMarker.token(tokenValue),
                checksum: SessionMarker.checksum(tokenValue)
            )
            let scheduled = SpiceInteractionHostClock.nowNanoseconds()
            // A synthetic input is created here, then sent through SpiceSession.
            // This does not measure NSEvent dispatch or another app's FIFO queue.
            let inputTime = SpiceInteractionHostClock.nowNanoseconds()
            let session = session
            do {
                try await withBenchmarkTimeout(seconds: configuration.timeoutSeconds) {
                    try capture.recordHostInput(
                        scheduledNs: scheduled, hostInputNs: inputTime,
                        sendStartedNs: SpiceInteractionHostClock.nowNanoseconds()
                    )
                    try await session.send(.keyDown(scanCode: 0x39))
                    try capture.recordSendCompleted(at: SpiceInteractionHostClock.nowNanoseconds())
                    try await session.send(.keyUp(scanCode: 0x39))
                    _ = try await capture.waitForExactPresentation()
                }
            } catch {
                let record = try capture.finish(invalidReason: Self.failureCategory(error))
                if index > configuration.warmup { records.append(record) }
                throw error
            }
            let record = try capture.finish()
            if index > configuration.warmup { records.append(record) }
            guard record.valid else { throw SessionBenchmarkError.invalidSample }
            Self.progress("Captured \(index)/\(configuration.warmup + configuration.samples)")
            if index < configuration.warmup + configuration.samples {
                try await Task.sleep(for: .milliseconds(configuration.intervalMilliseconds))
            }
        }
    }

    static func progress(_ message: String) {
        FileHandle.standardError.write(Data(("spice-session-benchmark: " + message + "\n").utf8))
    }

    private static func failureCategory(_ error: any Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? SessionBenchmarkError { return error.rawValue }
        if error is SpiceInteractionTraceCollectionError { return "trace_collection_failed" }
        if let error = error as? SpiceError {
            return switch error {
            case .authenticationFailed: "authentication_failed"
            case .protocolError: "protocol_failed"
            case .videoCodecUnavailable: "video_codec_unavailable"
            case .cancelled: "cancelled"
            default: SessionBenchmarkError.connectionFailed.rawValue
            }
        }
        return SessionBenchmarkError.connectionFailed.rawValue
    }
}
