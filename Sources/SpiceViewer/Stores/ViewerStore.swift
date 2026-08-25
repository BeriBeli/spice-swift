import AppKit
import Observation
import OSLog
import SpiceRenderer
import SwiftSpice

private let sessionLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.beribeli.SpiceViewer",
    category: "Session"
)

private let navigationLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.beribeli.SpiceViewer",
    category: "Navigation"
)

private let playbackLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.beribeli.SpiceViewer",
    category: "Playback"
)

private let recordLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.beribeli.SpiceViewer",
    category: "Record"
)

private let clipboardLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.beribeli.SpiceViewer",
    category: "Clipboard"
)

private let monitorLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.beribeli.SpiceViewer",
    category: "Monitors"
)

private enum ViewerSessionExit: Sendable {
    case failed(SpiceError)
    case disconnected
}

private enum ViewerLifecycleError: Error {
    case connectionTimedOut
}

@Observable
@MainActor
package final class ViewerStore {
    package private(set) var mode: ViewerMode = .offline
    package private(set) var connectionState: ViewerConnectionState = .disconnected
    package private(set) var desktop: SpiceDesktopSource
    package private(set) var submittedFPS = 0.0
    package private(set) var presentationPath = "Starting…"
    package private(set) var playbackStatus = ViewerPlaybackStatus()
    package private(set) var recordStatus = ViewerRecordStatus()
    package private(set) var clipboardStatus = ViewerClipboardStatus()
    package private(set) var fileTransferStatus = ViewerFileTransferStatus()
    package private(set) var monitorStatus = ViewerMonitorStatus()

    @ObservationIgnored private let surfaceStore = SurfaceStore()
    @ObservationIgnored private let offlineDesktop: SpiceDesktopSource
    @ObservationIgnored private let reconnectBackoff: ViewerReconnectBackoff
    @ObservationIgnored private var syntheticTask: Task<Void, Never>?
    @ObservationIgnored private var connectionTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var playbackTask: Task<Void, Never>?
    @ObservationIgnored private var playbackSink: SpiceAudioPlaybackSink?
    @ObservationIgnored private var recordAuthorizationTask: Task<Void, Never>?
    @ObservationIgnored private var recordTask: Task<Void, Never>?
    @ObservationIgnored private var recordSource: SpiceAudioCaptureSource?
    @ObservationIgnored private var recordChannelAvailable = false
    @ObservationIgnored private var recordRequestID: UInt64 = 0
    @ObservationIgnored private let microphoneAuthorizer: any ViewerMicrophoneAuthorizing
    @ObservationIgnored private var agentManagerTask: Task<Void, Never>?
    @ObservationIgnored private var clipboardTask: Task<Void, Never>?
    @ObservationIgnored private var fileTransferTask: Task<Void, Never>?
    @ObservationIgnored private var displayConfigurationTask: Task<Void, Never>?
    @ObservationIgnored private var displayConfigurationSupportTask: Task<Void, Never>?
    @ObservationIgnored private var clipboardPolicyTask: Task<Void, Never>?
    @ObservationIgnored private var fileSelectionTask: Task<Void, Never>?
    @ObservationIgnored private var agentManager: SpiceAgentManager?
    @ObservationIgnored private var clipboardEnabled = false
    @ObservationIgnored private let fileSelector: any ViewerFileSelecting
    @ObservationIgnored private var inputContinuation: AsyncStream<SpiceClientInput>.Continuation?
    @ObservationIgnored private var sessionExitContinuation: AsyncStream<ViewerSessionExit>.Continuation?
    @ObservationIgnored private var session: SpiceSession?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var isSurfaceInitialized = false

    package init(
        reconnectBackoff: ViewerReconnectBackoff = ViewerReconnectBackoff(),
        microphoneAuthorizer: any ViewerMicrophoneAuthorizing = SystemViewerMicrophoneAuthorizer(),
        fileSelector: any ViewerFileSelecting = SystemViewerFileSelector()
    ) {
        let offlineDesktop = SpiceDesktopSource()
        self.offlineDesktop = offlineDesktop
        desktop = offlineDesktop
        self.reconnectBackoff = reconnectBackoff
        self.microphoneAuthorizer = microphoneAuthorizer
        self.fileSelector = fileSelector
    }

    package var windowTitle: String {
        switch mode {
        case .offline:
            String(format: "SwiftSpice — %@ — %.1f fps", presentationPath, submittedFPS)
        case .remote:
            "SwiftSpice — \(connectionState.label)"
        }
    }

    package func start() {
        if mode == .offline { startSyntheticFrames() }
    }

    package func stop() {
        stopSyntheticFrames()
        releaseRemoteSession(setDisconnected: true, reason: "window closed")
    }

    package func selectMode(_ nextMode: ViewerMode) {
        guard mode != nextMode else { return }
        mode = nextMode
        navigationLogger.info("Selected viewer mode \(nextMode.rawValue, privacy: .public)")
        switch nextMode {
        case .offline:
            releaseRemoteSession(setDisconnected: true, reason: "offline mode selected")
            desktop = offlineDesktop
            startSyntheticFrames()
        case .remote:
            stopSyntheticFrames()
            desktop = SpiceDesktopSource()
            presentationPath = "Waiting for session"
        }
    }

    package func connect(
        configuration: ViewerEndpointConfiguration,
        password: String,
        automaticallyReconnect: Bool
    ) {
        let endpoint: SpiceEndpoint
        do {
            endpoint = try configuration.endpoint()
        } catch {
            connectionState = .failed(error.localizedDescription)
            sessionLogger.error("Rejected invalid endpoint configuration")
            return
        }

        releaseRemoteSession(setDisconnected: false, reason: "new connection requested")
        generation &+= 1
        let connectionGeneration = generation
        connectionState = .connecting
        desktop = SpiceDesktopSource()
        sessionLogger.info(
            "Connection lifecycle started; transport=\(configuration.tlsMode.rawValue, privacy: .public) autoReconnect=\(automaticallyReconnect, privacy: .public)"
        )
        connectionTask = Task { [weak self] in
            await self?.runConnectionLifecycle(
                endpoint: endpoint,
                password: password,
                automaticallyReconnect: automaticallyReconnect,
                generation: connectionGeneration
            )
        }
    }

    package func disconnect() {
        releaseRemoteSession(setDisconnected: true, reason: "user requested")
    }

    package func setMicrophoneEnabled(_ enabled: Bool) {
        guard enabled else {
            let oldSource = detachRecord(status: recordChannelAvailable ? .disabled : ViewerRecordStatus())
            if let oldSource {
                Task { await oldSource.stop() }
            }
            recordLogger.info("Microphone capture disabled by user")
            return
        }
        guard recordChannelAvailable,
              connectionState.isConnected,
              let session,
              recordStatus.canEnable else { return }

        recordStatus = .requestingPermission
        recordRequestID &+= 1
        let requestID = recordRequestID
        let authorizationGeneration = generation
        recordAuthorizationTask?.cancel()
        recordAuthorizationTask = Task { [weak self] in
            await self?.authorizeAndStartRecord(
                for: session,
                generation: authorizationGeneration,
                requestID: requestID
            )
        }
    }

    package func setClipboardEnabled(_ enabled: Bool) {
        guard connectionState.isConnected, agentManager != nil else { return }
        clipboardEnabled = enabled
        clipboardStatus = enabled ? .waiting : .disabled
        reconcileClipboardPolicy()
        clipboardLogger.info(
            "Clipboard synchronization requested; enabled=\(enabled, privacy: .public)"
        )
    }

    package func chooseAndSendFile() {
        guard connectionState.isConnected,
              agentManager != nil,
              fileSelectionTask == nil else { return }
        let selectionGeneration = generation
        fileSelectionTask = Task { [weak self] in
            guard let self else { return }
            let source = await fileSelector.selectFile()
            defer {
                if selectionGeneration == generation { fileSelectionTask = nil }
            }
            guard let source,
                  !Task.isCancelled,
                  selectionGeneration == generation,
                  let manager = agentManager else { return }
            let accessed = source.startAccessingSecurityScopedResource()
            defer {
                if accessed { source.stopAccessingSecurityScopedResource() }
            }
            do {
                let id = try await manager.sendFile(at: source)
                clipboardLogger.info(
                    "Host-to-guest file transfer submitted; id=\(id.rawValue, privacy: .public)"
                )
            } catch let error as SpiceFileTransferError {
                fileTransferStatus.recordSubmissionFailure(error)
                clipboardLogger.error(
                    "Host-to-guest file submission failed; cause=\(error.description, privacy: .private)"
                )
            } catch {
                let transferError = SpiceFileTransferError.invalidFile(String(describing: error))
                fileTransferStatus.recordSubmissionFailure(transferError)
                clipboardLogger.error("Host-to-guest file submission failed")
            }
        }
    }

    package func cancelFileTransfer(_ id: SpiceFileTransferID) {
        guard let agentManager else { return }
        Task { await agentManager.cancelFileTransfer(id) }
    }

    package func requestResolution(width: Int, height: Int) {
        guard connectionState.isConnected, let agentManager else { return }
        let requestGeneration = generation
        Task { [weak self] in
            do {
                try await agentManager.requestResolution(width: width, height: height)
                monitorLogger.info(
                    "Resolution requested; width=\(width, privacy: .public) height=\(height, privacy: .public)"
                )
            } catch let error as SpiceDisplayConfigurationError {
                guard requestGeneration == self?.generation else { return }
                self?.monitorStatus.recordSubmissionFailure(error)
                monitorLogger.error(
                    "Resolution request failed; cause=\(error.description, privacy: .private)"
                )
            } catch {
                guard requestGeneration == self?.generation else { return }
                let requestError = SpiceDisplayConfigurationError.invalidAgentReply(
                    String(describing: error)
                )
                self?.monitorStatus.recordSubmissionFailure(requestError)
                monitorLogger.error("Resolution request failed")
            }
        }
    }

    package func requestDisplayConfiguration(_ configuration: SpiceDisplayConfiguration) {
        guard connectionState.isConnected, let agentManager else { return }
        let requestGeneration = generation
        Task { [weak self] in
            do {
                try await agentManager.requestDisplayConfiguration(configuration)
                monitorLogger.info(
                    "Display layout requested; monitors=\(configuration.monitors.count, privacy: .public)"
                )
            } catch let error as SpiceDisplayConfigurationError {
                guard requestGeneration == self?.generation else { return }
                self?.monitorStatus.recordSubmissionFailure(error)
                monitorLogger.error(
                    "Display layout request failed; cause=\(error.description, privacy: .private)"
                )
            } catch {
                guard requestGeneration == self?.generation else { return }
                let requestError = SpiceDisplayConfigurationError.invalidAgentReply(
                    String(describing: error)
                )
                self?.monitorStatus.recordSubmissionFailure(requestError)
                monitorLogger.error("Display layout request failed")
            }
        }
    }

    package func submit(_ input: SpiceClientInput) {
        guard connectionState.isConnected, let inputContinuation else { return }
        switch inputContinuation.yield(input) {
        case .enqueued:
            break
        case .dropped:
            sessionExitContinuation?.yield(.failed(
                .protocolError("local input queue overflowed")
            ))
        case .terminated:
            break
        @unknown default:
            break
        }
    }

    private func runConnectionLifecycle(
        endpoint: SpiceEndpoint,
        password: String,
        automaticallyReconnect: Bool,
        generation: UInt64
    ) async {
        var retry = 0
        while !Task.isCancelled, generation == self.generation {
            let nextSession = SpiceSession()
            let exitPipe = AsyncStream.makeStream(
                of: ViewerSessionExit.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            session = nextSession
            desktop = nextSession.desktop
            sessionExitContinuation = exitPipe.continuation
            startEventSupervision(for: nextSession, generation: generation)
            sessionLogger.info("Connection attempt \(retry + 1, privacy: .public) started")

            let exit: ViewerSessionExit
            do {
                let info = try await connectWithTimeout(
                    session: nextSession,
                    endpoint: endpoint,
                    password: password
                )
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                didConnect(info, session: nextSession, generation: generation)
                retry = 0
                exit = await nextSessionExit(from: exitPipe.stream)
            } catch is CancellationError {
                await finishAttempt(nextSession)
                return
            } catch ViewerLifecycleError.connectionTimedOut {
                exit = .failed(.connectionFailed(
                    "attempt timed out after \(reconnectBackoff.attemptTimeoutSeconds) seconds"
                ))
            } catch let error as SpiceError {
                exit = .failed(error)
            } catch {
                exit = .failed(.protocolError(String(describing: error)))
            }

            await finishAttempt(nextSession)
            guard !Task.isCancelled, generation == self.generation else { return }

            let error = switch exit {
            case let .failed(error): error
            case .disconnected: SpiceError.connectionFailed("remote peer disconnected")
            }
            guard automaticallyReconnect else {
                finishLifecycle(with: error, generation: generation)
                return
            }
            retry += 1
            guard let delay = reconnectBackoff.delaySeconds(forRetry: retry) else {
                finishLifecycle(with: error, generation: generation)
                return
            }
            connectionState = .reconnecting(attempt: retry, delaySeconds: delay)
            sessionLogger.info(
                "Reconnect \(retry, privacy: .public) scheduled in \(delay, privacy: .public)s; cause=\(String(describing: error), privacy: .private)"
            )
            do {
                try await Task.sleep(for: .seconds(delay))
                try Task.checkCancellation()
                connectionState = .connecting
            } catch {
                return
            }
        }
    }

    private func connectWithTimeout(
        session: SpiceSession,
        endpoint: SpiceEndpoint,
        password: String
    ) async throws -> SpiceSessionInfo {
        let timeoutSeconds = reconnectBackoff.attemptTimeoutSeconds
        return try await withThrowingTaskGroup(of: SpiceSessionInfo.self) { group in
            group.addTask {
                try await session.connect(
                    endpoint: endpoint,
                    credentials: SpiceCredentials(password: password)
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw ViewerLifecycleError.connectionTimedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw SpiceError.cancelled
            }
            return result
        }
    }

    private func nextSessionExit(
        from stream: AsyncStream<ViewerSessionExit>
    ) async -> ViewerSessionExit {
        for await exit in stream { return exit }
        return .disconnected
    }

    private func finishAttempt(_ attemptedSession: SpiceSession) async {
        eventTask?.cancel()
        eventTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
        let oldPlaybackSink = detachPlayback()
        let oldRecordSource = detachRecord(status: ViewerRecordStatus())
        let oldAgentManager = detachAgentManager()
        recordChannelAvailable = false
        sessionExitContinuation?.finish()
        sessionExitContinuation = nil
        if session === attemptedSession { session = nil }
        if let oldPlaybackSink { await oldPlaybackSink.stop() }
        if let oldRecordSource { await oldRecordSource.stop() }
        if let oldAgentManager { await oldAgentManager.stop() }
        await attemptedSession.disconnect()
    }

    private func startEventSupervision(for session: SpiceSession, generation: UInt64) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in session.events {
                guard !Task.isCancelled else { return }
                self?.consume(event, generation: generation)
            }
        }
    }

    private func didConnect(
        _ info: SpiceSessionInfo,
        session: SpiceSession,
        generation: UInt64
    ) {
        guard generation == self.generation, self.session === session else { return }
        connectionState = .connected(sessionID: info.sessionID)
        presentationPath = "Demand-driven Metal IOSurface"
        startInputPump(for: session, generation: generation)
        if info.channels.contains(where: { $0.type == 5 && $0.id == 0 }) {
            startPlayback(for: session, generation: generation)
        } else {
            playbackStatus = ViewerPlaybackStatus()
            playbackLogger.info("Session has no Playback Channel")
        }
        recordChannelAvailable = info.channels.contains(where: { $0.type == 6 && $0.id == 0 })
        if recordChannelAvailable {
            recordStatus = .disabled
            recordLogger.info("Record Channel available; waiting for user opt-in")
        } else {
            recordStatus = ViewerRecordStatus()
            recordLogger.info("Session has no Record Channel")
        }
        startAgentManager(for: session, generation: generation)
        sessionLogger.info(
            "Connected session \(info.sessionID, privacy: .public) with \(info.channels.count, privacy: .public) channels"
        )
    }

    private func finishLifecycle(with error: SpiceError, generation: UInt64) {
        guard generation == self.generation else { return }
        connectionState = .failed(error.description)
        sessionLogger.error(
            "Connection lifecycle exhausted; cause=\(error.description, privacy: .private)"
        )
    }

    private func consume(_ event: SpiceSessionEvent, generation: UInt64) {
        guard generation == self.generation else { return }
        switch event {
        case let .failed(error):
            sessionExitContinuation?.yield(.failed(error))
        case .disconnected:
            sessionExitContinuation?.yield(.disconnected)
        case let .displayConfiguration(configuration):
            monitorStatus.consumeAuthoritative(configuration)
            monitorLogger.info(
                "Authoritative display inventory updated; channel=\(configuration.channelID, privacy: .public) monitors=\(configuration.monitors.count, privacy: .public)"
            )
        case let .migration(event):
            consumeMigration(event)
        case .keyboardModifiers, .mouseMotionAcknowledged:
            break
        }
    }

    private func consumeMigration(_ event: SpiceMigrationEvent) {
        switch event {
        case let .preparing(offer):
            sessionLogger.info("Migration target preparation started; id=\(offer.id, privacy: .public)")
        case let .ready(offer, seamless):
            sessionLogger.info(
                "Migration target ready; id=\(offer.id, privacy: .public) seamless=\(seamless, privacy: .public)"
            )
        case let .cancelled(offer):
            sessionLogger.info("Migration cancelled; id=\(offer.id, privacy: .public)")
        case let .committing(offer):
            sessionLogger.info("Migration handoff committing; id=\(offer.id, privacy: .public)")
        case let .switching(offer):
            sessionLogger.info("Migration switch-host started; id=\(offer.id, privacy: .public)")
        case let .completed(offer):
            sessionLogger.info("Migration handoff completed; id=\(offer.id, privacy: .public)")
        case let .failed(offer, reason):
            sessionLogger.error(
                "Migration handoff failed; id=\(offer?.id ?? 0, privacy: .public) cause=\(reason, privacy: .private)"
            )
        }
    }

    private func startInputPump(for session: SpiceSession, generation: UInt64) {
        inputContinuation?.finish()
        inputTask?.cancel()
        let pipe = AsyncStream.makeStream(
            of: SpiceClientInput.self,
            bufferingPolicy: .bufferingOldest(256)
        )
        inputContinuation = pipe.continuation
        inputTask = Task { [weak self] in
            for await input in pipe.stream {
                guard !Task.isCancelled else { return }
                do {
                    try await session.send(input)
                } catch let error as SpiceError {
                    self?.sessionExitContinuation?.yield(.failed(error))
                    return
                } catch {
                    self?.sessionExitContinuation?.yield(.failed(
                        .protocolError(String(describing: error))
                    ))
                    return
                }
            }
        }
    }

    private func startPlayback(for session: SpiceSession, generation: UInt64) {
        let sink = SpiceAudioPlaybackSink()
        playbackSink = sink
        playbackStatus = .waiting
        playbackTask = Task { [weak self] in
            do {
                try await sink.start(session: session)
                playbackLogger.info("Playback sink attached")
            } catch let error as SpiceAudioPlaybackSinkError {
                self?.consumePlayback(.failed(error), generation: generation)
                return
            } catch {
                self?.consumePlayback(
                    .failed(.audioEngine(String(describing: error))),
                    generation: generation
                )
                return
            }
            for await event in sink.events {
                guard !Task.isCancelled else { return }
                self?.consumePlayback(event, generation: generation)
            }
        }
    }

    private func consumePlayback(
        _ event: SpiceAudioPlaybackSinkEvent,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        playbackStatus.consume(event)
        switch event {
        case let .started(configuration):
            playbackLogger.info(
                "Playback started; rate=\(configuration.sampleRate, privacy: .public) channels=\(configuration.channels, privacy: .public)"
            )
        case .stopped:
            playbackLogger.info("Playback stopped")
        case let .muteChanged(muted):
            playbackLogger.info("Playback mute changed; muted=\(muted, privacy: .public)")
        case let .overflowResynchronized(milliseconds):
            playbackLogger.warning(
                "Playback resynchronized; droppedMs=\(milliseconds, privacy: .public)"
            )
        case let .oversizedPacketDropped(milliseconds):
            playbackLogger.warning(
                "Oversized playback packet dropped; durationMs=\(milliseconds, privacy: .public)"
            )
        case .underrun:
            playbackLogger.debug("Playback underrun")
        case let .failed(error):
            playbackLogger.error("Playback failed; cause=\(error.description, privacy: .private)")
        }
    }

    private func detachPlayback() -> SpiceAudioPlaybackSink? {
        playbackTask?.cancel()
        playbackTask = nil
        let oldSink = playbackSink
        playbackSink = nil
        playbackStatus = ViewerPlaybackStatus()
        return oldSink
    }

    private func authorizeAndStartRecord(
        for session: SpiceSession,
        generation: UInt64,
        requestID: UInt64
    ) async {
        let status = microphoneAuthorizer.authorizationStatus()
        let authorized: Bool
        switch status {
        case .authorized:
            authorized = true
        case .notDetermined:
            recordLogger.info("Requesting microphone permission after user opt-in")
            authorized = await microphoneAuthorizer.requestAccess()
        case .denied:
            guard generation == self.generation, requestID == recordRequestID else { return }
            recordAuthorizationTask = nil
            recordStatus = .denied
            recordLogger.info("Microphone permission denied")
            return
        case .restricted:
            guard generation == self.generation, requestID == recordRequestID else { return }
            recordAuthorizationTask = nil
            recordStatus = .restricted
            recordLogger.info("Microphone permission restricted")
            return
        }

        guard !Task.isCancelled,
              authorized,
              generation == self.generation,
              requestID == recordRequestID,
              self.session === session,
              recordChannelAvailable else {
            if !authorized,
               generation == self.generation,
               requestID == recordRequestID {
                recordStatus = .denied
                recordLogger.info("Microphone permission denied")
            }
            if requestID == recordRequestID {
                recordAuthorizationTask = nil
            }
            return
        }
        recordAuthorizationTask = nil
        startRecord(for: session, generation: generation)
    }

    private func startRecord(for session: SpiceSession, generation: UInt64) {
        let source = SpiceAudioCaptureSource()
        recordSource = source
        recordStatus = .waiting
        recordTask = Task { [weak self] in
            do {
                try await source.start(session: session)
                recordLogger.info("Record source attached after user opt-in")
            } catch let error as SpiceAudioCaptureSourceError {
                self?.consumeRecord(.failed(error), generation: generation)
                return
            } catch {
                self?.consumeRecord(
                    .failed(.audioEngine(String(describing: error))),
                    generation: generation
                )
                return
            }
            for await event in source.events {
                guard !Task.isCancelled else { return }
                self?.consumeRecord(event, generation: generation)
            }
        }
    }

    private func consumeRecord(
        _ event: SpiceAudioCaptureSourceEvent,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        recordStatus.consume(event)
        switch event {
        case let .started(configuration):
            recordLogger.info(
                "Record capture started; rate=\(configuration.sampleRate, privacy: .public) channels=\(configuration.channels, privacy: .public)"
            )
        case .stopped:
            recordLogger.info("Record capture stopped by server")
        case let .overflowDropped(milliseconds):
            recordLogger.warning(
                "Record queue overflow; droppedMs=\(milliseconds, privacy: .public)"
            )
        case .volumeChanged:
            recordLogger.debug("Record volume changed")
        case let .muteChanged(muted):
            recordLogger.info("Record mute changed; muted=\(muted, privacy: .public)")
        case let .failed(error):
            recordLogger.error("Record capture failed; cause=\(error.description, privacy: .private)")
        }
    }

    private func detachRecord(status: ViewerRecordStatus) -> SpiceAudioCaptureSource? {
        recordRequestID &+= 1
        recordAuthorizationTask?.cancel()
        recordAuthorizationTask = nil
        recordTask?.cancel()
        recordTask = nil
        let oldSource = recordSource
        recordSource = nil
        recordStatus = status
        return oldSource
    }

    private func startAgentManager(for session: SpiceSession, generation: UInt64) {
        let manager = SpiceAgentManager(
            automaticallySynchronizesPasteboard: true,
            pasteboardSynchronizationEnabled: false
        )
        agentManager = manager
        clipboardEnabled = false
        clipboardStatus = .disabled
        fileTransferStatus = ViewerFileTransferStatus()
        agentManagerTask = Task { [weak self] in
            do {
                try await manager.start(session: session)
                clipboardLogger.info("Shared Agent manager attached with pasteboard disabled")
            } catch let error as SpiceClipboardError {
                guard generation == self?.generation else { return }
                self?.clipboardStatus.consume(.failed(error))
                self?.fileTransferStatus.recordManagerFailure(error.description)
                clipboardLogger.error(
                    "Shared Agent manager failed; cause=\(error.description, privacy: .private)"
                )
            } catch {
                guard generation == self?.generation else { return }
                let managerError = SpiceClipboardError.invalidAgentMessage(
                    String(describing: error)
                )
                self?.clipboardStatus.consume(.failed(managerError))
                self?.fileTransferStatus.recordManagerFailure(managerError.description)
                clipboardLogger.error("Shared Agent manager failed")
            }
        }
        clipboardTask = Task { [weak self] in
            for await event in manager.events {
                guard !Task.isCancelled else { return }
                self?.consumeClipboard(event, generation: generation)
            }
        }
        fileTransferTask = Task { [weak self] in
            for await event in manager.fileTransferEvents {
                guard !Task.isCancelled else { return }
                self?.consumeFileTransfer(event, generation: generation)
            }
        }
        displayConfigurationTask = Task { [weak self] in
            for await event in manager.displayConfigurationEvents {
                guard !Task.isCancelled else { return }
                self?.consumeDisplayConfiguration(event, generation: generation)
            }
        }
        displayConfigurationSupportTask = Task { [weak self] in
            for await support in manager.displayConfigurationSupportEvents {
                guard !Task.isCancelled else { return }
                self?.consumeDisplayConfigurationSupport(support, generation: generation)
            }
        }
    }

    private func reconcileClipboardPolicy() {
        guard clipboardPolicyTask == nil, let manager = agentManager else { return }
        let policyGeneration = generation
        clipboardPolicyTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  policyGeneration == generation,
                  agentManager === manager {
                let desired = clipboardEnabled
                await manager.setPasteboardSynchronizationEnabled(desired)
                guard desired != clipboardEnabled else { break }
            }
            if policyGeneration == generation, agentManager === manager {
                clipboardPolicyTask = nil
            }
        }
    }

    private func consumeClipboard(_ event: SpiceClipboardEvent, generation: UInt64) {
        guard generation == self.generation, clipboardEnabled else { return }
        clipboardStatus.consume(event)
        switch event {
        case .ready:
            clipboardLogger.info("Agent clipboard ready")
        case .unavailable:
            clipboardLogger.info("Agent clipboard unavailable")
        case let .guestText(text):
            clipboardLogger.info(
                "Guest clipboard text received; bytes=\(text.utf8.count, privacy: .public)"
            )
        case let .localTextOffered(byteCount):
            clipboardLogger.info(
                "Host clipboard text offered; bytes=\(byteCount, privacy: .public)"
            )
        case let .oversizedLocalText(byteCount, maximum):
            clipboardLogger.warning(
                "Host clipboard text rejected; bytes=\(byteCount, privacy: .public) maximum=\(maximum, privacy: .public)"
            )
        case let .failed(error):
            clipboardLogger.error(
                "Agent clipboard failed; cause=\(error.description, privacy: .private)"
            )
        }
    }

    private func consumeFileTransfer(_ event: SpiceFileTransferEvent, generation: UInt64) {
        guard generation == self.generation else { return }
        fileTransferStatus.consume(event)
        switch event {
        case let .queued(id, _, totalBytes):
            clipboardLogger.info(
                "File transfer queued; id=\(id.rawValue, privacy: .public) bytes=\(totalBytes, privacy: .public)"
            )
        case let .awaitingGuestApproval(id):
            clipboardLogger.info(
                "File transfer awaiting guest; id=\(id.rawValue, privacy: .public)"
            )
        case let .progress(id, sentBytes, totalBytes):
            clipboardLogger.debug(
                "File transfer progress; id=\(id.rawValue, privacy: .public) sent=\(sentBytes, privacy: .public) total=\(totalBytes, privacy: .public)"
            )
        case let .completed(id):
            clipboardLogger.info("File transfer completed; id=\(id.rawValue, privacy: .public)")
        case let .cancelled(id):
            clipboardLogger.info("File transfer cancelled; id=\(id.rawValue, privacy: .public)")
        case let .failed(id, error):
            clipboardLogger.error(
                "File transfer failed; id=\(id?.rawValue ?? 0, privacy: .public) cause=\(error.description, privacy: .private)"
            )
        }
    }

    private func consumeDisplayConfiguration(
        _ event: SpiceDisplayConfigurationEvent,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        monitorStatus.consumeRequest(event)
        switch event {
        case .queued:
            monitorLogger.info("Display configuration queued")
        case .sent:
            monitorLogger.info("Display configuration sent; waiting for Agent reply")
        case .acknowledged:
            monitorLogger.info("Display configuration acknowledged; waiting for Display update")
        case .rejected:
            monitorLogger.warning("Display configuration rejected")
        case .unsupported:
            monitorLogger.warning("Display configuration unsupported")
        case let .failed(_, error), let .protocolFailure(error):
            monitorLogger.error(
                "Display configuration failed; cause=\(error.description, privacy: .private)"
            )
        }
    }

    private func consumeDisplayConfigurationSupport(
        _ support: SpiceDisplayConfigurationSupport,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        monitorStatus.consumeSupport(support)
        monitorLogger.info(
            "Display configuration support changed; connected=\(support.agentConnected, privacy: .public) explicit=\(support.hasExplicitPeerCapabilities, privacy: .public) sparse=\(support.supportsSparseMonitors, privacy: .public) positions=\(support.supportsMonitorPositions, privacy: .public)"
        )
    }

    private func detachAgentManager() -> SpiceAgentManager? {
        agentManagerTask?.cancel()
        agentManagerTask = nil
        clipboardTask?.cancel()
        clipboardTask = nil
        fileTransferTask?.cancel()
        fileTransferTask = nil
        displayConfigurationTask?.cancel()
        displayConfigurationTask = nil
        displayConfigurationSupportTask?.cancel()
        displayConfigurationSupportTask = nil
        clipboardPolicyTask?.cancel()
        clipboardPolicyTask = nil
        fileSelectionTask?.cancel()
        fileSelectionTask = nil
        let oldManager = agentManager
        agentManager = nil
        clipboardEnabled = false
        clipboardStatus = ViewerClipboardStatus()
        fileTransferStatus = ViewerFileTransferStatus()
        monitorStatus = ViewerMonitorStatus()
        return oldManager
    }

    private func releaseRemoteSession(setDisconnected: Bool, reason: String) {
        let hadLifecycle = connectionTask != nil || session != nil
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        eventTask?.cancel()
        eventTask = nil
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
        let oldPlaybackSink = detachPlayback()
        let oldRecordSource = detachRecord(status: ViewerRecordStatus())
        let oldAgentManager = detachAgentManager()
        recordChannelAvailable = false
        sessionExitContinuation?.finish()
        sessionExitContinuation = nil
        let oldSession = session
        session = nil
        desktop = mode == .offline ? offlineDesktop : SpiceDesktopSource()
        if setDisconnected { connectionState = .disconnected }
        if hadLifecycle {
            sessionLogger.info(
                "Connection lifecycle cancelled; reason=\(reason, privacy: .public)"
            )
        }
        if oldPlaybackSink != nil
            || oldRecordSource != nil
            || oldAgentManager != nil
            || oldSession != nil {
            Task {
                if let oldPlaybackSink { await oldPlaybackSink.stop() }
                if let oldRecordSource { await oldRecordSource.stop() }
                if let oldAgentManager { await oldAgentManager.stop() }
                if let oldSession { await oldSession.disconnect() }
            }
        }
    }

    private func startSyntheticFrames() {
        guard syntheticTask == nil else { return }
        desktop = offlineDesktop
        offlineDesktop.beginSyntheticDesktop()
        sessionLogger.info("Offline validation started")
        syntheticTask = Task { [weak self] in
            await self?.animateSyntheticFrames()
        }
    }

    private func stopSyntheticFrames() {
        syntheticTask?.cancel()
        syntheticTask = nil
    }

    private func animateSyntheticFrames() async {
        do {
            if !isSurfaceInitialized {
                try await surfaceStore.create(id: 0, width: 640, height: 360, format: 32)
                try await surfaceStore.fill(
                    surfaceID: 0,
                    rectangle: PixelRect(x: 0, y: 0, width: 640, height: 360),
                    colorARGB: 0x0010_1520
                )
                isSurfaceInitialized = true
            }

            var previousX = 0
            var frameNumber = 0
            var framesInWindow = 0
            var windowStart = Date()
            let clock = ContinuousClock()
            var nextFrameDeadline = clock.now
            while !Task.isCancelled {
                try await surfaceStore.fill(
                    surfaceID: 0,
                    rectangle: PixelRect(x: previousX, y: 130, width: 96, height: 96),
                    colorARGB: 0x0010_1520
                )
                let x = (frameNumber * 7) % (640 - 96)
                let red = UInt32((frameNumber * 5) & 0xff)
                let green = UInt32((frameNumber * 3 + 80) & 0xff)
                let blue = UInt32((frameNumber * 7 + 160) & 0xff)
                try await surfaceStore.fill(
                    surfaceID: 0,
                    rectangle: PixelRect(x: x, y: 130, width: 96, height: 96),
                    colorARGB: (red << 16) | (green << 8) | blue
                )
                let nextFrame = SpiceFrame(try await surfaceStore.snapshot(surfaceID: 0))
                guard mode == .offline else { return }
                offlineDesktop.publishSyntheticFrame(
                    nextFrame,
                    revision: UInt64(frameNumber + 1)
                )
                presentationPath = nextFrame.ioSurface == nil
                    ? "AppKit CPU fallback"
                    : "Metal IOSurface"

                previousX = x
                frameNumber &+= 1
                framesInWindow += 1
                let now = Date()
                let elapsed = now.timeIntervalSince(windowStart)
                if elapsed >= 1 {
                    submittedFPS = Double(framesInWindow) / elapsed
                    framesInWindow = 0
                    windowStart = now
                }
                nextFrameDeadline += .milliseconds(33)
                try await clock.sleep(until: nextFrameDeadline)
                if nextFrameDeadline < clock.now { nextFrameDeadline = clock.now }
            }
        } catch is CancellationError {
            return
        } catch {
            presentationPath = "Rendering error"
            sessionLogger.error(
                "Synthetic rendering stopped: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
