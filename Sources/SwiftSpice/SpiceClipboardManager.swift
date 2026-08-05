import Foundation
import SpiceChannels
import SpiceProtocol
import SpiceWire
import Synchronization

/// Synchronizes the general macOS pasteboard with the VDAgent UTF-8 clipboard.
///
/// This is a data-transfer path. It does not synthesize keyboard scan codes or
/// expose guest IME composition and candidate state.
public actor SpiceAgentManager {
    public static let maximumWireTextBytes = 16 * 1_024 * 1_024 - 4

    public nonisolated let events: AsyncStream<SpiceClipboardEvent>
    public nonisolated let manualOfferEvents: AsyncStream<SpiceClipboardOfferEvent>
    public nonisolated let displayConfigurationEvents:
        AsyncStream<SpiceDisplayConfigurationEvent>
    public nonisolated let displayConfigurationSupportEvents:
        AsyncStream<SpiceDisplayConfigurationSupport>
    public nonisolated let fileTransferEvents: AsyncStream<SpiceFileTransferEvent>

    private let eventContinuation: AsyncStream<SpiceClipboardEvent>.Continuation
    private let manualOfferContinuation:
        AsyncStream<SpiceClipboardOfferEvent>.Continuation
    private let displayConfigurationContinuation:
        AsyncStream<SpiceDisplayConfigurationEvent>.Continuation
    private let displayConfigurationSupportContinuation:
        AsyncStream<SpiceDisplayConfigurationSupport>.Continuation
    private let fileTransferContinuation: AsyncStream<SpiceFileTransferEvent>.Continuation
    private let automaticallySynchronizesPasteboard: Bool
    private var pasteboardSynchronizationEnabled: Bool
    private var manualClipboardOffersEnabled = false
    private let pollInterval: Duration
    private var state: ClipboardStateMachine
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var session: SpiceSession?
    private var lifecycleGeneration: UInt64 = 1
    private var startingGeneration: UInt64?
    private var pendingActions: [ClipboardStateMachine.Action] = []
    private var clipboardDriverGeneration: UInt64?
    private var clipboardInFlight: ClipboardActionOwner?
    private var nextClipboardOwnerID: UInt64 = 1
    private var nextManualOfferID: UInt64 = 1
    private var manualGrabWaiters: [
        SpiceClipboardOfferID: CheckedContinuation<Result<Void, SpiceClipboardError>, Never>
    ] = [:]
    private var manualGrabResults: [
        SpiceClipboardOfferID: Result<Void, SpiceClipboardError>
    ] = [:]
    private var invalidatedManualGrabIDs: Set<SpiceClipboardOfferID> = []
    private var agentWorkGeneration: UInt64 = 1
    private var agentWorkInvalidationGeneration: UInt64?
    private var agentWorkInvalidationSequence: UInt64 = 0
    private var agentWorkInvalidationWaiters: [AgentWorkInvalidationWaiter] = []
    private var ownedAgentSends: [UInt64: OwnedAgentSend] = [:]
    private var nextOwnedAgentSendID: UInt64 = 1
    private var displayCoordinator = DisplayConfigurationCoordinator()
    private var lastDisplayConfigurationSupport: SpiceDisplayConfigurationSupport?
    private let maximumConcurrentFileTransfers: Int
    private let maximumFileBytes: UInt64
    private let fileTransferChunkBytes: Int
    private let fileTransferCodec: VDAgentFileTransferCodec
    private var fileTransfers: [SpiceFileTransferID: FileTransferJob] = [:]
    private var fileTransferReaders: [SpiceFileTransferID: FileTransferReader] = [:]
    private var deferredFileTransferStatuses:
        [SpiceFileTransferID: VDAgentFileTransferStatus] = [:]
    private var fileTransferDriverGeneration: UInt64?
    private var nextFileTransferID: UInt32 = 1
    private var completedFileTransferMessageCount: UInt64 = 0
    private var completedFileTransferPayloadByteCount: UInt64 = 0

    private struct ClipboardActionOwner: Sendable, Equatable {
        let id: UInt64
        let generation: UInt64
        let action: ClipboardStateMachine.Action
    }

    private struct AgentWorkEpoch: Sendable, Equatable {
        let lifecycleGeneration: UInt64
        let agentWorkGeneration: UInt64
        let sessionID: ObjectIdentifier
    }

    private struct OwnedAgentSend {
        let epoch: AgentWorkEpoch
        let task: Task<Result<Void, SpiceError>, Never>
    }

    private struct AgentWorkInvalidationWaiter {
        let observedSequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    public init(
        maximumTextBytes: Int = SpiceAgentManager.maximumWireTextBytes,
        automaticallySynchronizesPasteboard: Bool = true,
        pasteboardSynchronizationEnabled: Bool = true,
        pollInterval: Duration = .milliseconds(250),
        maximumConcurrentFileTransfers: Int = 4,
        maximumFileBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
        fileTransferChunkBytes: Int = 16_000
    ) {
        let pipe = AsyncStream.makeStream(
            of: SpiceClipboardEvent.self,
            bufferingPolicy: .bufferingOldest(32)
        )
        events = pipe.stream
        eventContinuation = pipe.continuation
        let manualOfferPipe = AsyncStream.makeStream(
            of: SpiceClipboardOfferEvent.self,
            bufferingPolicy: .bufferingOldest(32)
        )
        manualOfferEvents = manualOfferPipe.stream
        manualOfferContinuation = manualOfferPipe.continuation
        let displayPipe = AsyncStream.makeStream(
            of: SpiceDisplayConfigurationEvent.self,
            bufferingPolicy: .bufferingNewest(16)
        )
        displayConfigurationEvents = displayPipe.stream
        displayConfigurationContinuation = displayPipe.continuation
        let displaySupportPipe = AsyncStream.makeStream(
            of: SpiceDisplayConfigurationSupport.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        displayConfigurationSupportEvents = displaySupportPipe.stream
        displayConfigurationSupportContinuation = displaySupportPipe.continuation
        let filePipe = AsyncStream.makeStream(
            of: SpiceFileTransferEvent.self,
            bufferingPolicy: .bufferingNewest(64)
        )
        fileTransferEvents = filePipe.stream
        fileTransferContinuation = filePipe.continuation
        self.automaticallySynchronizesPasteboard = automaticallySynchronizesPasteboard
        self.pasteboardSynchronizationEnabled = pasteboardSynchronizationEnabled
        self.pollInterval = max(.milliseconds(10), pollInterval)
        self.maximumConcurrentFileTransfers = max(1, maximumConcurrentFileTransfers)
        self.maximumFileBytes = maximumFileBytes
        self.fileTransferChunkBytes = min(max(1, fileTransferChunkBytes), 16_000)
        fileTransferCodec = VDAgentFileTransferCodec(limits: .init(
            maximumChunkBytes: self.fileTransferChunkBytes
        ))
        state = ClipboardStateMachine(
            maximumTextBytes: min(maximumTextBytes, Self.maximumWireTextBytes),
            clipboardEnabled: pasteboardSynchronizationEnabled,
            negotiatesClipboardLimit: true
        )
    }

    deinit {
        eventTask?.cancel()
        pollTask?.cancel()
        for send in ownedAgentSends.values {
            send.task.cancel()
        }
        for waiter in agentWorkInvalidationWaiters {
            waiter.continuation.resume()
        }
        for waiter in manualGrabWaiters.values {
            waiter.resume(returning: .failure(.invalidAgentMessage(
                "manual clipboard offer manager deinitialized"
            )))
        }
        eventContinuation.finish()
        manualOfferContinuation.finish()
        displayConfigurationContinuation.finish()
        displayConfigurationSupportContinuation.finish()
        fileTransferContinuation.finish()
    }

    public func start(session: SpiceSession) async throws(SpiceClipboardError) {
        guard eventTask == nil,
              startingGeneration == nil,
              agentWorkInvalidationGeneration == nil,
              ownedAgentSends.isEmpty else {
            throw .alreadyRunning
        }
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        startingGeneration = generation
        self.session = session
        defer {
            if startingGeneration == generation {
                startingGeneration = nil
            }
        }
        if await session.currentAgentConnectionState() {
            guard ownsLifecycle(session: session, generation: generation) else {
                throw .transport(.cancelled)
            }
            await execute(state.connected(), using: session)
        }
        guard ownsLifecycle(session: session, generation: generation) else {
            throw .transport(.cancelled)
        }
        emitDisplayConfigurationSupportIfChanged()
        let newEventTask = Task { [weak self] in
            for await event in session.agentEvents {
                guard !Task.isCancelled else {
                    return
                }
                await self?.receive(
                    event,
                    from: session,
                    lifecycleGeneration: generation
                )
            }
        }
        let pollInterval = self.pollInterval
        let newPollTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: pollInterval)
                } catch {
                    return
                }
                await self?.performPeriodicWork(lifecycleGeneration: generation)
            }
        }
        guard ownsLifecycle(session: session, generation: generation) else {
            newEventTask.cancel()
            newPollTask.cancel()
            throw .transport(.cancelled)
        }
        eventTask = newEventTask
        pollTask = newPollTask
        startingGeneration = nil
    }

    public func stop() async {
        lifecycleGeneration &+= 1
        startingGeneration = nil
        eventTask?.cancel()
        eventTask = nil
        pollTask?.cancel()
        pollTask = nil
        session = nil
        let invalidation = beginAgentWorkInvalidation()
        displayCoordinator.reset()
        cancelAllFileTransfers()
        emitActions(state.disconnected())
        emitDisplayConfigurationSupportIfChanged()
        await finishAgentWorkInvalidation(invalidation)
    }

    /// Checks the current pasteboard immediately rather than waiting for the
    /// optional polling loop.
    public func synchronizePasteboard() async {
        guard pasteboardSynchronizationEnabled,
              let session,
              let epoch = currentAgentWorkEpoch(using: session) else {
            return
        }
        await execute(state.announcementIfNeeded(), using: session)
        guard ownsAgentWork(epoch, using: session) else { return }
        let snapshot = await SpicePasteboardBridge.snapshot()
        guard ownsAgentWork(epoch, using: session) else { return }
        await execute(state.localPasteboardChanged(
            changeCount: snapshot.changeCount,
            text: snapshot.text
        ), using: session)
        await sendPendingDisplayConfiguration(using: session)
        await driveFileTransfers(using: session)
    }

    /// Publishes text locally and offers it to the guest without polling delay.
    public func publish(_ text: String) async {
        guard pasteboardSynchronizationEnabled else { return }
        let admittedSession = session
        let admittedEpoch = admittedSession.flatMap { currentAgentWorkEpoch(using: $0) }
        let snapshot: SpicePasteboardSnapshot
        do {
            snapshot = try await SpicePasteboardBridge.write(text: text)
        } catch {
            emit(.failed(error))
            return
        }
        guard let session = admittedSession,
              let admittedEpoch,
              ownsAgentWork(admittedEpoch, using: session) else {
            return
        }
        await execute(state.localPasteboardChanged(
            changeCount: snapshot.changeCount,
            text: snapshot.text
        ), using: session)
    }

    // Package-scoped protocol harness used to verify logical-message ownership
    // independently of the macOS pasteboard bridge.
    package func sendClipboardCommandForTesting(
        _ command: VDAgentClipboardCommand
    ) async {
        guard let session else { return }
        await execute([.send(command)], using: session)
    }

    /// Changes whether this manager may advertise clipboard support or access
    /// the general pasteboard. Other Agent services remain active either way.
    public func setPasteboardSynchronizationEnabled(_ enabled: Bool) async {
        guard pasteboardSynchronizationEnabled != enabled else { return }
        pasteboardSynchronizationEnabled = enabled
        guard let session else {
            _ = state.setClipboardModes(
                generalPasteboardSynchronizationEnabled: enabled,
                manualClipboardOffersEnabled: manualClipboardOffersEnabled,
                negotiatesClipboardOwnership: manualClipboardOffersEnabled
            )
            return
        }
        await execute(state.setClipboardModes(
            generalPasteboardSynchronizationEnabled: enabled,
            manualClipboardOffersEnabled: manualClipboardOffersEnabled,
            negotiatesClipboardOwnership: manualClipboardOffersEnabled
        ), using: session)
        if enabled {
            await synchronizePasteboard()
        }
    }

    /// Controls the in-memory clipboard offer path independently from access
    /// to the macOS general pasteboard.
    public func setManualClipboardOffersEnabled(_ enabled: Bool) async {
        guard manualClipboardOffersEnabled != enabled else { return }
        manualClipboardOffersEnabled = enabled
        let actions = state.setClipboardModes(
            generalPasteboardSynchronizationEnabled: pasteboardSynchronizationEnabled,
            manualClipboardOffersEnabled: enabled,
            negotiatesClipboardOwnership: enabled
        )
        guard let session else {
            emitActions(actions)
            return
        }
        await execute(actions, using: session)
    }

    /// Creates a private in-memory UTF-8 offer and returns only after its GRAB
    /// message has reached the Agent scheduler's physical write terminal.
    /// This method never reads or writes the macOS general pasteboard.
    public func offerClipboardText(
        _ text: String,
        leaseGeneration: UInt64
    ) async throws -> SpiceClipboardOfferID {
        guard manualClipboardOffersEnabled else {
            throw SpiceClipboardError.invalidAgentMessage(
                "manual clipboard offers are disabled"
            )
        }
        guard state.isReady, let session else {
            throw SpiceClipboardError.invalidAgentMessage(
                "manual clipboard offer requires a negotiated Agent"
            )
        }
        let id = allocateManualOfferID()
        let actions = try state.offerManualText(
            text,
            id: id,
            leaseGeneration: leaseGeneration
        )
        return try await withTaskCancellationHandler {
            await execute(actions, using: session)
            try await waitForManualGrab(id: id)
            return id
        } onCancel: {
            Task {
                await self.cancelManualClipboardOffer(
                    id: id,
                    leaseGeneration: leaseGeneration
                )
            }
        }
    }

    /// Revokes the matching lease-owned offer. A stale ID or lease generation
    /// is a no-op and cannot revoke a replacement offer.
    public func revokeClipboardOffer(
        id: SpiceClipboardOfferID,
        leaseGeneration: UInt64
    ) async {
        let actions = state.revokeManualOffer(
            id: id,
            leaseGeneration: leaseGeneration
        )
        guard let session else {
            emitActions(actions)
            return
        }
        await execute(actions, using: session)
    }

    /// Coalesces resize requests while one Agent request is awaiting a reply.
    /// A reply acknowledges Agent processing; the Display Channel remains the
    /// authority for the guest's resulting surface geometry.
    public func requestResolution(
        width: Int,
        height: Int
    ) async throws(SpiceDisplayConfigurationError) {
        guard width > 0,
              height > 0,
              UInt32(exactly: width) != nil,
              UInt32(exactly: height) != nil else {
            throw .invalidDimensions(width: width, height: height)
        }
        let configuration = SpiceDisplayConfiguration(width: width, height: height)
        try await requestDisplayConfiguration(configuration)
    }

    /// Requests a complete guest monitor layout. Monitor IDs are encoded as
    /// array indexes; gaps therefore require peer sparse-monitor support.
    public func requestDisplayConfiguration(
        _ configuration: SpiceDisplayConfiguration
    ) async throws(SpiceDisplayConfigurationError) {
        guard let session else {
            throw .agentManagerNotRunning
        }
        if state.hasExplicitPeerCapabilities,
           !state.supportsMonitorConfiguration {
            throw .unsupportedByAgent
        }
        _ = try makeWireDisplayConfiguration(configuration)
        displayCoordinator.queue(configuration)
        emitDisplay(.queued(configuration))
        await sendPendingDisplayConfiguration(using: session)
    }

    /// Explicitly authorizes one host-to-guest transfer. No directory is
    /// scanned and no guest-originated path is ever written on the host.
    public func sendFile(
        at source: URL,
        name: String? = nil
    ) async throws(SpiceFileTransferError) -> SpiceFileTransferID {
        guard let session,
              let epoch = currentAgentWorkEpoch(using: session) else {
            throw .agentManagerNotRunning
        }
        guard state.isAgentConnected else {
            throw .agentUnavailable
        }
        if state.hasFileTransferCapabilityState, !state.supportsFileTransfer {
            throw .disabledByGuest
        }
        guard fileTransfers.count < maximumConcurrentFileTransfers else {
            throw .tooManyConcurrentTransfers(maximum: maximumConcurrentFileTransfers)
        }
        let info = try await Self.inspectFile(source, overrideName: name)
        guard ownsAgentWork(epoch, using: session), state.isAgentConnected else {
            info.reader.close()
            throw .agentUnavailable
        }
        guard info.size <= maximumFileBytes else {
            info.reader.close()
            throw .fileTooLarge(actual: info.size, maximum: maximumFileBytes)
        }
        let id = try allocateFileTransferID()
        do {
            _ = try fileTransferCodec.encodeStart(id: id.rawValue, name: info.name, size: info.size)
        } catch {
            info.reader.close()
            throw .invalidFile(String(describing: error))
        }
        fileTransfers[id] = FileTransferJob(
            id: id,
            source: source,
            name: info.name,
            totalBytes: info.size,
            sentBytes: 0,
            phase: .queuedStart
        )
        fileTransferReaders[id] = info.reader
        emitFileTransfer(.queued(id: id, name: info.name, totalBytes: info.size))
        await driveFileTransfers(using: session)
        guard ownsAgentWork(epoch, using: session), fileTransfers[id] != nil else {
            throw .agentUnavailable
        }
        return id
    }

    public func cancelFileTransfer(_ id: SpiceFileTransferID) async {
        guard var job = fileTransfers[id] else {
            return
        }
        switch job.phase {
        case .queuedStart:
            removeFileTransfer(id)
            emitFileTransfer(.cancelled(id: id))
            return
        case .queuedCancellation, .sendingCancellation, .awaitingCancellation:
            return
        case .sendingStart, .sendingData, .sendingFailure:
            job.cancellationRequested = true
            fileTransfers[id] = job
        case .awaitingGuestApproval,
             .readyToRead,
             .reading,
             .readyToSend,
             .awaitingCompletion,
             .queuedFailure:
            job.phase = .queuedCancellation
            fileTransfers[id] = job
        }
        if let session {
            await driveFileTransfers(using: session)
        }
    }

    /// Returns content-free counters suitable for proving that a bounded
    /// observation period completed without any host-to-guest file message.
    public func fileTransferWireMetrics() -> SpiceFileTransferWireMetrics {
        SpiceFileTransferWireMetrics(
            completedMessageCount: completedFileTransferMessageCount,
            payloadByteCount: completedFileTransferPayloadByteCount
        )
    }

    package func fileTransferSentByteCount(
        _ id: SpiceFileTransferID
    ) -> UInt64? {
        fileTransfers[id]?.sentBytes
    }

    package func receiveFileTransferCommandForTesting(
        _ command: VDAgentFileTransferCommand
    ) async {
        guard let session else { return }
        await receiveFileTransfer(command, using: session)
    }

    private func receive(
        _ event: SpiceAgentEvent,
        from session: SpiceSession,
        lifecycleGeneration: UInt64
    ) async {
        guard ownsLifecycle(
            session: session,
            generation: lifecycleGeneration
        ) else {
            return
        }
        switch event {
        case .connected:
            guard !state.isAgentConnected else {
                return
            }
            await invalidateAgentWork()
            guard ownsLifecycle(
                session: session,
                generation: lifecycleGeneration
            ) else {
                return
            }
            displayCoordinator.disconnected()
            await execute(state.connected(), using: session)
            emitDisplayConfigurationSupportIfChanged()
            if automaticallySynchronizesPasteboard, pasteboardSynchronizationEnabled {
                let snapshot = await SpicePasteboardBridge.snapshot()
                await execute(state.localPasteboardChanged(
                    changeCount: snapshot.changeCount,
                    text: snapshot.text
                ), using: session)
            }
            await sendPendingDisplayConfiguration(using: session)
            await driveFileTransfers(using: session)
        case .disconnected:
            await invalidateAgentWork()
            guard ownsLifecycle(
                session: session,
                generation: lifecycleGeneration
            ) else {
                return
            }
            displayCoordinator.disconnected()
            failAllFileTransfers(with: .agentUnavailable)
            emitActions(state.disconnected())
            emitDisplayConfigurationSupportIfChanged()
        case let .message(message):
            let wireMessage = VDAgentMessage(
                protocolID: message.protocolID,
                type: message.type,
                opaque: message.opaque,
                data: message.data
            )
            if message.type == VDAgentMessageType.reply.rawValue {
                do {
                    if let reply = try VDAgentMonitorCodec.decodeReply(wireMessage) {
                        await receiveMonitorReply(reply, using: session)
                    }
                } catch {
                    emitDisplay(.protocolFailure(.invalidAgentReply(
                        String(describing: error)
                    )))
                }
                return
            }
            if (VDAgentMessageType.fileTransferStart.rawValue
                ... VDAgentMessageType.fileTransferData.rawValue).contains(message.type) {
                do {
                    guard let command = try fileTransferCodec.decode(wireMessage) else {
                        return
                    }
                    await receiveFileTransfer(command, using: session)
                } catch {
                    emitFileTransfer(.failed(
                        id: nil,
                        .invalidAgentResponse(String(describing: error))
                    ))
                }
                return
            }
            do {
                guard let command = try VDAgentClipboardCodec.decode(
                    wireMessage,
                    grabHasSerial: state.expectsPeerGrabSerial
                ) else {
                    return
                }
                await execute(try state.receive(command), using: session)
                emitDisplayConfigurationSupportIfChanged()
                await sendPendingDisplayConfiguration(using: session)
                await driveFileTransfers(using: session)
            } catch let error as SpiceClipboardError {
                emit(.failed(error))
            } catch {
                emit(.failed(.invalidAgentMessage(String(describing: error))))
            }
        }
    }

    private func receiveMonitorReply(
        _ reply: VDAgentMonitorReply,
        using session: SpiceSession
    ) async {
        guard let configuration = displayCoordinator.didReceiveReply() else {
            emitDisplay(.protocolFailure(.invalidAgentReply(
                "reply received without an in-flight request"
            )))
            return
        }
        switch reply.status {
        case .success:
            emitDisplay(.acknowledged(configuration))
        case .error:
            emitDisplay(.rejected(configuration))
        }
        await sendPendingDisplayConfiguration(using: session)
    }

    private func sendPendingDisplayConfiguration(using session: SpiceSession) async {
        guard pendingActions.isEmpty,
              let configuration = displayCoordinator.nextToSend,
              state.isAgentConnected else {
            return
        }
        guard state.supportsMonitorConfiguration else {
            displayCoordinator.discardDesired()
            emitDisplay(.unsupported(configuration))
            return
        }
        do {
            let wireConfiguration = try makeWireDisplayConfiguration(configuration)
            if (wireConfiguration.allowsSparse || wireConfiguration.usesPositions),
               !state.hasExplicitPeerCapabilities {
                return
            }
            let message = try VDAgentMonitorCodec.encode(wireConfiguration)
            guard displayCoordinator.beginSend(configuration) else { return }
            let generation = agentWorkGeneration
            do {
                try await sendOwnedAgentMessage(
                    SpiceAgentMessage(
                        protocolID: message.protocolID,
                        type: message.type,
                        opaque: message.opaque,
                        data: message.data
                    ),
                    priority: .normal,
                    requiredControl: false,
                    using: session
                )
            } catch let error {
                guard generation == agentWorkGeneration,
                      displayCoordinator.inFlight == configuration else {
                    return
                }
                switch Self.agentSendDisposition(error) {
                case .retry:
                    displayCoordinator.didFailSend(configuration, requeue: true)
                    emitDisplay(.failed(configuration, .transport(error)))
                case .failed:
                    let cancelledBeforeWrite: Bool
                    if case .agentCancelled(partial: false) = error {
                        cancelledBeforeWrite = true
                    } else if case .cancelled = error {
                        cancelledBeforeWrite = true
                    } else {
                        cancelledBeforeWrite = false
                    }
                    displayCoordinator.didFailSend(
                        configuration,
                        requeue: !cancelledBeforeWrite
                    )
                    emitDisplay(.failed(configuration, .transport(error)))
                }
                return
            }
            guard generation == agentWorkGeneration,
                  displayCoordinator.inFlight == configuration else {
                return
            }
            emitDisplay(.sent(configuration))
        } catch let error as SpiceDisplayConfigurationError {
            displayCoordinator.discardDesired()
            if error == .unsupportedByAgent {
                emitDisplay(.unsupported(configuration))
            } else {
                emitDisplay(.failed(configuration, error))
            }
        } catch {
            displayCoordinator.discardDesired()
            emitDisplay(.failed(configuration, .invalidAgentReply(
                String(describing: error)
            )))
        }
    }

    private func retryPendingAgentWork() async {
        guard let session else {
            return
        }
        await execute(state.announcementIfNeeded(), using: session)
        await sendPendingDisplayConfiguration(using: session)
        await driveFileTransfers(using: session)
    }

    private func performPeriodicWork(lifecycleGeneration: UInt64) async {
        guard lifecycleGeneration == self.lifecycleGeneration,
              startingGeneration == nil,
              session != nil else {
            return
        }
        if automaticallySynchronizesPasteboard, pasteboardSynchronizationEnabled {
            await synchronizePasteboard()
        } else {
            await retryPendingAgentWork()
        }
    }

    private func ownsLifecycle(
        session: SpiceSession,
        generation: UInt64
    ) -> Bool {
        lifecycleGeneration == generation && self.session === session
    }

    private func makeWireDisplayConfiguration(
        _ configuration: SpiceDisplayConfiguration
    ) throws(SpiceDisplayConfigurationError) -> VDAgentMonitorsConfiguration {
        guard !configuration.monitors.isEmpty else {
            throw .invalidLayout("at least one monitor is required")
        }
        guard configuration.monitors.count
            <= VDAgentMonitorsConfiguration.maximumMonitorCount else {
            throw .invalidLayout("monitor count exceeds 256")
        }

        var monitorsByID: [Int: SpiceMonitorConfiguration] = [:]
        for monitor in configuration.monitors {
            guard (0..<VDAgentMonitorsConfiguration.maximumMonitorCount).contains(monitor.id) else {
                throw .invalidLayout("monitor id \(monitor.id) is outside 0...255")
            }
            guard monitorsByID.updateValue(monitor, forKey: monitor.id) == nil else {
                throw .invalidLayout("duplicate monitor id \(monitor.id)")
            }
            let enabled = monitor.width > 0 && monitor.height > 0
            let disabled = monitor.width == 0 && monitor.height == 0
            guard enabled || disabled else {
                throw .invalidDimensions(width: monitor.width, height: monitor.height)
            }
            guard UInt32(exactly: monitor.width) != nil,
                  UInt32(exactly: monitor.height) != nil,
                  Int32(exactly: monitor.x) != nil,
                  Int32(exactly: monitor.y) != nil else {
                throw .invalidLayout("monitor \(monitor.id) values exceed wire ranges")
            }
            if disabled, monitor.x != 0 || monitor.y != 0 {
                throw .invalidLayout("disabled monitor \(monitor.id) must have position 0,0")
            }
        }
        guard configuration.monitors.contains(where: \.isEnabled) else {
            throw .invalidLayout("at least one monitor must be enabled")
        }

        let maximumID = monitorsByID.keys.max() ?? 0
        let usesSparse = (0...maximumID).contains { id in
            monitorsByID[id]?.isEnabled != true
        }
        let usesPositions = configuration.monitors.contains { monitor in
            monitor.isEnabled && (monitor.x != 0 || monitor.y != 0)
        }
        if usesSparse,
           state.hasExplicitPeerCapabilities,
           !state.supportsSparseMonitorConfiguration {
            throw .unsupportedByAgent
        }
        if usesPositions,
           state.hasExplicitPeerCapabilities,
           !state.supportsMonitorPositions {
            throw .unsupportedByAgent
        }

        var wireMonitors: [VDAgentMonitorConfiguration] = []
        wireMonitors.reserveCapacity(maximumID + 1)
        for id in 0...maximumID {
            let monitor = monitorsByID[id] ?? .disabled(id: id)
            guard let width = UInt32(exactly: monitor.width),
                  let height = UInt32(exactly: monitor.height),
                  let x = Int32(exactly: monitor.x),
                  let y = Int32(exactly: monitor.y) else {
                throw SpiceDisplayConfigurationError.invalidLayout(
                    "monitor \(id) values exceed wire ranges"
                )
            }
            wireMonitors.append(VDAgentMonitorConfiguration(
                width: width,
                height: height,
                depth: 32,
                x: x,
                y: y
            ))
        }
        return VDAgentMonitorsConfiguration(
            usesPositions: usesPositions,
            allowsSparse: usesSparse,
            monitors: wireMonitors
        )
    }

    private func receiveFileTransfer(
        _ command: VDAgentFileTransferCommand,
        using session: SpiceSession
    ) async {
        switch command {
        case let .status(status):
            let id = SpiceFileTransferID(rawValue: status.id)
            guard var job = fileTransfers[id] else {
                emitFileTransfer(.failed(
                    id: nil,
                    .invalidAgentResponse("status for unknown transfer \(status.id)")
                ))
                return
            }
            if job.phase.isSending {
                guard deferredFileTransferStatuses[id] == nil else {
                    failFileTransfer(
                        id,
                        error: .invalidAgentResponse(
                            "multiple statuses arrived while a wire message was in flight"
                        )
                    )
                    return
                }
                deferredFileTransferStatuses[id] = status
                return
            }
            switch status.result {
            case .canSendData:
                if job.cancellationRequested || job.phase.isCancellationPending {
                    // A non-terminal approval racing with host cancellation is
                    // stale.  Keep the job alive so its sole cancellation wire
                    // owner can notify the guest.
                    return
                }
                guard job.phase == .awaitingGuestApproval else {
                    failFileTransfer(
                        id,
                        error: .invalidAgentResponse("CAN_SEND_DATA in phase \(job.phase)")
                    )
                    return
                }
                job.phase = .readyToRead
                fileTransfers[id] = job
                await driveFileTransfers(using: session)
            case .cancelled:
                removeFileTransfer(id)
                emitFileTransfer(.cancelled(id: id))
            case .success:
                guard job.phase == .awaitingCompletion
                    || (job.phase.isCancellationPending
                        && job.sentBytes == job.totalBytes) else {
                    failFileTransfer(
                        id,
                        error: .invalidAgentResponse("SUCCESS before all bytes were sent")
                    )
                    return
                }
                removeFileTransfer(id)
                emitFileTransfer(.completed(id: id))
            case .error:
                let description: String
                if case let .glibIO(errorCode) = status.detail {
                    description = "guest GLib I/O error \(errorCode)"
                } else {
                    description = "guest reported a generic error"
                }
                failFileTransfer(id, error: .invalidAgentResponse(description))
            case .notEnoughSpace:
                let description: String
                if case let .diskFreeSpace(bytes) = status.detail {
                    description = "guest has only \(bytes) free bytes"
                } else {
                    description = "guest has insufficient free space"
                }
                failFileTransfer(id, error: .invalidAgentResponse(description))
            case .sessionLocked:
                failFileTransfer(id, error: .invalidAgentResponse("guest session is locked"))
            case .agentNotConnected:
                failFileTransfer(id, error: .agentUnavailable)
            case .disabled:
                failFileTransfer(id, error: .disabledByGuest)
            }
        case let .start(id, _), let .data(id, _):
            emitFileTransfer(.failed(
                id: SpiceFileTransferID(rawValue: id),
                .invalidAgentResponse(
                    "unsolicited guest-to-host file payload is not supported"
                )
            ))
        }
    }

    private func driveFileTransfers(using session: SpiceSession) async {
        guard fileTransferDriverGeneration == nil,
              pendingActions.isEmpty,
              clipboardInFlight == nil,
              state.isAgentConnected else {
            return
        }
        let driverGeneration = agentWorkGeneration
        fileTransferDriverGeneration = driverGeneration
        defer {
            if fileTransferDriverGeneration == driverGeneration {
                fileTransferDriverGeneration = nil
            }
        }

        while fileTransferDriverGeneration == driverGeneration,
              agentWorkGeneration == driverGeneration {
            var progressed = false
            for id in fileTransfers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard var job = fileTransfers[id] else {
                    continue
                }
                switch job.phase {
                case .queuedStart:
                    guard state.hasFileTransferCapabilityState else {
                        continue
                    }
                    guard state.supportsFileTransfer else {
                        failFileTransfer(id, error: .disabledByGuest)
                        progressed = true
                        continue
                    }
                    let message: VDAgentMessage
                    do {
                        message = try fileTransferCodec.encodeStart(
                            id: id.rawValue,
                            name: job.name,
                            size: job.totalBytes
                        )
                    } catch {
                        failFileTransfer(id, error: .invalidFile(String(describing: error)))
                        progressed = true
                        continue
                    }
                    job.phase = .sendingStart
                    fileTransfers[id] = job
                    guard await sendFileTransferMessage(
                        message,
                        priority: .normal,
                        requiredControl: false,
                        id: id,
                        retryPhase: .queuedStart,
                        using: session
                    ) else {
                        return
                    }
                    guard var current = fileTransfers[id], current.phase == .sendingStart else {
                        progressed = true
                        continue
                    }
                    current.phase = current.cancellationRequested
                        ? .queuedCancellation
                        : .awaitingGuestApproval
                    fileTransfers[id] = current
                    if !current.cancellationRequested {
                        emitFileTransfer(.awaitingGuestApproval(id: id))
                    }
                    await processDeferredFileTransferStatus(id: id, using: session)
                    progressed = true
                case .readyToRead:
                    let remaining = job.totalBytes - job.sentBytes
                    let requested = Int(min(remaining, UInt64(fileTransferChunkBytes)))
                    job.phase = .reading
                    fileTransfers[id] = job
                    let data: Data
                    do {
                        guard let reader = fileTransferReaders[id] else {
                            throw SpiceFileTransferError.localReadFailed(
                                "source reader is unavailable"
                            )
                        }
                        data = try await Self.readFileChunk(
                            reader: reader,
                            offset: job.sentBytes,
                            count: requested
                        )
                    } catch {
                        guard var current = fileTransfers[id], current.phase == .reading else {
                            progressed = true
                            continue
                        }
                        current.phase = .queuedFailure(.localReadFailed(
                            String(describing: error)
                        ))
                        fileTransfers[id] = current
                        progressed = true
                        continue
                    }
                    guard var current = fileTransfers[id], current.phase == .reading else {
                        progressed = true
                        continue
                    }
                    current.phase = .readyToSend(data)
                    fileTransfers[id] = current
                    progressed = true
                case let .readyToSend(data):
                    let message: VDAgentMessage
                    do {
                        message = try fileTransferCodec.encodeData(id: id.rawValue, data: data)
                    } catch {
                        job.phase = .queuedFailure(.invalidFile(String(describing: error)))
                        fileTransfers[id] = job
                        progressed = true
                        continue
                    }
                    job.phase = .sendingData(data)
                    fileTransfers[id] = job
                    guard await sendFileTransferMessage(
                        message,
                        priority: .low,
                        requiredControl: false,
                        id: id,
                        retryPhase: .readyToSend(data),
                        using: session
                    ) else {
                        return
                    }
                    guard var current = fileTransfers[id],
                          current.phase == .sendingData(data) else {
                        progressed = true
                        continue
                    }
                    current.sentBytes += UInt64(data.count)
                    current.phase = current.cancellationRequested
                        ? .queuedCancellation
                        : current.sentBytes == current.totalBytes
                            ? .awaitingCompletion
                            : .readyToRead
                    fileTransfers[id] = current
                    emitFileTransfer(.progress(
                        id: id,
                        sentBytes: current.sentBytes,
                        totalBytes: current.totalBytes
                    ))
                    await processDeferredFileTransferStatus(id: id, using: session)
                    progressed = true
                case .queuedCancellation:
                    let message = fileTransferCodec.encodeStatus(
                        id: id.rawValue,
                        result: .cancelled
                    )
                    job.phase = .sendingCancellation
                    fileTransfers[id] = job
                    guard await sendFileTransferMessage(
                        message,
                        priority: .high,
                        requiredControl: true,
                        id: id,
                        retryPhase: .queuedCancellation,
                        using: session
                    ) else {
                        return
                    }
                    guard var current = fileTransfers[id],
                          current.phase == .sendingCancellation else {
                        progressed = true
                        continue
                    }
                    current.phase = .awaitingCancellation
                    fileTransfers[id] = current
                    await processDeferredFileTransferStatus(id: id, using: session)
                    progressed = true
                case let .queuedFailure(error):
                    let message = fileTransferCodec.encodeStatus(
                        id: id.rawValue,
                        result: .error
                    )
                    job.phase = .sendingFailure(error)
                    fileTransfers[id] = job
                    guard await sendFileTransferMessage(
                        message,
                        priority: .high,
                        requiredControl: true,
                        id: id,
                        retryPhase: .queuedFailure(error),
                        using: session
                    ) else {
                        return
                    }
                    guard fileTransfers[id]?.phase == .sendingFailure(error) else {
                        progressed = true
                        continue
                    }
                    removeFileTransfer(id)
                    emitFileTransfer(.failed(id: id, error))
                    progressed = true
                case .awaitingGuestApproval,
                     .reading,
                     .awaitingCompletion,
                     .awaitingCancellation,
                     .sendingStart,
                     .sendingData,
                     .sendingCancellation,
                     .sendingFailure:
                    break
                }
            }
            if !progressed {
                return
            }
        }
    }

    private func sendFileTransferMessage(
        _ message: VDAgentMessage,
        priority: AgentOutboundPriority,
        requiredControl: Bool,
        id: SpiceFileTransferID,
        retryPhase: FileTransferPhase,
        using session: SpiceSession
    ) async -> Bool {
        do {
            try await sendOwnedAgentMessage(
                SpiceAgentMessage(
                    protocolID: message.protocolID,
                    type: message.type,
                    opaque: message.opaque,
                    data: message.data
                ),
                priority: priority,
                requiredControl: requiredControl,
                using: session
            )
            completedFileTransferMessageCount = Self.addClamped(
                completedFileTransferMessageCount,
                1
            )
            completedFileTransferPayloadByteCount = Self.addClamped(
                completedFileTransferPayloadByteCount,
                UInt64(message.data.count)
            )
            return true
        } catch let error {
            guard var job = fileTransfers[id], job.phase.isSending else {
                return false
            }
            switch Self.agentSendDisposition(error) {
            case .retry:
                job.phase = retryPhase
                fileTransfers[id] = job
                return false
            case .failed:
                failAllFileTransfers(with: .transport(error))
                return false
            }
        }
    }

    private func processDeferredFileTransferStatus(
        id: SpiceFileTransferID,
        using session: SpiceSession
    ) async {
        guard let status = deferredFileTransferStatuses.removeValue(forKey: id) else {
            return
        }
        await receiveFileTransfer(.status(status), using: session)
    }

    private func failFileTransfer(
        _ id: SpiceFileTransferID,
        error: SpiceFileTransferError
    ) {
        removeFileTransfer(id)
        emitFileTransfer(.failed(id: id, error))
    }

    private func failAllFileTransfers(with error: SpiceFileTransferError) {
        let ids = fileTransfers.keys.sorted(by: { $0.rawValue < $1.rawValue })
        fileTransfers.removeAll(keepingCapacity: false)
        deferredFileTransferStatuses.removeAll(keepingCapacity: false)
        let readers = fileTransferReaders.values
        fileTransferReaders.removeAll(keepingCapacity: false)
        for reader in readers {
            reader.close()
        }
        for id in ids {
            emitFileTransfer(.failed(id: id, error))
        }
    }

    private func cancelAllFileTransfers() {
        let ids = fileTransfers.keys.sorted(by: { $0.rawValue < $1.rawValue })
        fileTransfers.removeAll(keepingCapacity: false)
        deferredFileTransferStatuses.removeAll(keepingCapacity: false)
        let readers = fileTransferReaders.values
        fileTransferReaders.removeAll(keepingCapacity: false)
        for reader in readers {
            reader.close()
        }
        for id in ids {
            emitFileTransfer(.cancelled(id: id))
        }
    }

    private func allocateFileTransferID() throws(SpiceFileTransferError) -> SpiceFileTransferID {
        for _ in 0...UInt32.max {
            let candidate = SpiceFileTransferID(rawValue: nextFileTransferID)
            nextFileTransferID = nextFileTransferID == UInt32.max
                ? 1
                : nextFileTransferID + 1
            if fileTransfers[candidate] == nil {
                return candidate
            }
        }
        throw .tooManyConcurrentTransfers(maximum: maximumConcurrentFileTransfers)
    }

    private nonisolated static func inspectFile(
        _ source: URL,
        overrideName: String?
    ) async throws(SpiceFileTransferError) -> (
        name: String,
        size: UInt64,
        reader: FileTransferReader
    ) {
        do {
            return try await Task.detached(priority: .utility) {
                guard source.isFileURL else {
                    throw SpiceFileTransferError.invalidFile("source must be a file URL")
                }
                let values = try source.resourceValues(forKeys: [
                    .isRegularFileKey,
                ])
                guard values.isRegularFile == true else {
                    throw SpiceFileTransferError.invalidFile(
                        "source must be a readable regular file"
                    )
                }
                let reader = try FileTransferReader(source: source)
                let byteCount = try reader.size()
                return (overrideName ?? source.lastPathComponent, byteCount, reader)
            }.value
        } catch let error as SpiceFileTransferError {
            throw error
        } catch {
            throw .invalidFile(String(describing: error))
        }
    }

    private nonisolated static func readFileChunk(
        reader: FileTransferReader,
        offset: UInt64,
        count: Int
    ) async throws -> Data {
        guard count > 0 else {
            return Data()
        }
        return try await Task.detached(priority: .utility) {
            let data = try reader.read(offset: offset, count: count)
            guard data.count == count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data
        }.value
    }

    private func removeFileTransfer(_ id: SpiceFileTransferID) {
        fileTransfers.removeValue(forKey: id)
        deferredFileTransferStatuses.removeValue(forKey: id)
        fileTransferReaders.removeValue(forKey: id)?.close()
    }

    private func execute(
        _ actions: [ClipboardStateMachine.Action],
        using session: SpiceSession
    ) async {
        preflightManualOfferActions(actions)
        for action in actions
        where clipboardInFlight?.action != action && !pendingActions.contains(action) {
            pendingActions.append(action)
        }
        guard clipboardDriverGeneration == nil else { return }
        let driverGeneration = agentWorkGeneration
        clipboardDriverGeneration = driverGeneration
        defer {
            if clipboardDriverGeneration == driverGeneration {
                clipboardDriverGeneration = nil
            }
        }

        while clipboardDriverGeneration == driverGeneration,
              agentWorkGeneration == driverGeneration,
              !pendingActions.isEmpty {
            let action = pendingActions.removeFirst()
            let owner = ClipboardActionOwner(
                id: allocateClipboardOwnerID(),
                generation: agentWorkGeneration,
                action: action
            )
            clipboardInFlight = owner
            switch action {
            case .send, .manualOffer(.sendGrab), .manualOffer(.sendData):
                let command: VDAgentClipboardCommand
                switch action {
                case let .send(value):
                    command = value
                case let .manualOffer(.sendData(value, _, _)):
                    command = value
                case let .manualOffer(.sendGrab(value, _, _)):
                    command = value
                case .manualOffer(.emit), .writeGuestText, .emit:
                    preconditionFailure("non-send clipboard action")
                }
                let message: VDAgentMessage
                do {
                    message = try VDAgentClipboardCodec.encode(command)
                } catch {
                    clearClipboardOwner(owner)
                    let clipboardError = SpiceClipboardError.invalidAgentMessage(
                        String(describing: error)
                    )
                    failManualGrabIfPresent(action, error: clipboardError)
                    emit(.failed(clipboardError))
                    continue
                }
                let policy = Self.clipboardSendPolicy(command)
                do {
                    try await sendOwnedAgentMessage(
                        SpiceAgentMessage(
                            protocolID: message.protocolID,
                            type: message.type,
                            opaque: message.opaque,
                            data: message.data
                        ),
                        priority: policy.priority,
                        requiredControl: policy.requiredControl,
                        using: session
                    )
                } catch let error {
                    guard ownsClipboardAction(owner) else { continue }
                    switch Self.agentSendDisposition(error) {
                    case .retry:
                        clearClipboardOwner(owner)
                        if let id = manualGrabID(for: action),
                           invalidatedManualGrabIDs.remove(id) != nil {
                            return
                        }
                        if !pendingActions.contains(action) {
                            pendingActions.insert(action, at: 0)
                        }
                        emit(.failed(.transport(error)))
                        return
                    case .failed:
                        clearClipboardOwner(owner)
                        let wasInvalidated: Bool
                        if let id = manualGrabID(for: action) {
                            wasInvalidated = invalidatedManualGrabIDs.remove(id) != nil
                        } else {
                            wasInvalidated = false
                        }
                        if !wasInvalidated {
                            failManualGrabIfPresent(action, error: .transport(error))
                        }
                        emit(.failed(.transport(error)))
                        return
                    }
                }
                guard ownsClipboardAction(owner) else { continue }
                state.didSend(command)
                clearClipboardOwner(owner)
                switch action {
                case let .manualOffer(.sendGrab(_, id, _)):
                    if invalidatedManualGrabIDs.remove(id) == nil {
                        finishManualGrab(id: id, result: .success(()))
                    }
                case let .manualOffer(.sendData(_, id, leaseGeneration)):
                    let followups = state.didSendManualOfferData(
                        id: id,
                        leaseGeneration: leaseGeneration
                    )
                    pendingActions.insert(contentsOf: followups, at: 0)
                case .send, .manualOffer(.emit), .writeGuestText, .emit:
                    break
                }
            case let .writeGuestText(text):
                do {
                    let snapshot = try await SpicePasteboardBridge.write(text: text)
                    guard ownsClipboardAction(owner) else { continue }
                    state.didWriteGuestText(changeCount: snapshot.changeCount)
                    clearClipboardOwner(owner)
                } catch {
                    guard ownsClipboardAction(owner) else { continue }
                    clearClipboardOwner(owner)
                    if !pendingActions.contains(action) {
                        pendingActions.insert(action, at: 0)
                    }
                    emit(.failed(error))
                    return
                }
            case let .emit(event):
                guard ownsClipboardAction(owner) else { continue }
                emit(event)
                clearClipboardOwner(owner)
            case let .manualOffer(.emit(event)):
                guard ownsClipboardAction(owner) else { continue }
                manualOfferContinuation.yield(event)
                clearClipboardOwner(owner)
            }
        }
    }

    package enum AgentSendDisposition: Sendable, Equatable {
        case retry
        case failed
    }

    package nonisolated static func agentSendDisposition(
        _ error: SpiceError
    ) -> AgentSendDisposition {
        switch error {
        case .agentQueueFull,
             .agentMigrationRebind(partial: false):
            .retry
        case .agentCancelled,
             .alreadyConnected,
             .agentDisconnected,
             .inputGenerationExpired,
             .agentMessageFailed,
             .agentMigrationRebind(partial: true),
             .agentStalled,
             .cancelled,
             .connectionFailed,
             .authenticationFailed,
             .protocolError:
            .failed
        }
    }

    /// Semantic managers own a logical Agent message until its scheduler
    /// request reaches a real terminal state.  Caller cancellation must not
    /// detach that ownership after a partial physical write and advance the
    /// clipboard/file state machine early.
    private func sendOwnedAgentMessage(
        _ message: SpiceAgentMessage,
        priority: AgentOutboundPriority,
        requiredControl: Bool,
        using session: SpiceSession
    ) async throws(SpiceError) {
        guard let epoch = currentAgentWorkEpoch(using: session) else {
            throw .cancelled
        }
        let ownerID = allocateOwnedAgentSendID()
        let owner: Task<Result<Void, SpiceError>, Never> = Task.detached {
            guard !Task.isCancelled else {
                return .failure(.cancelled)
            }
            do {
                try await session.sendAgentMessageJoiningPhysicalTerminal(
                    message,
                    priority: priority,
                    requiredControl: requiredControl
                )
                return Result<Void, SpiceError>.success(())
            } catch let error as SpiceError {
                return .failure(error)
            } catch {
                return .failure(.protocolError(String(describing: error)))
            }
        }
        ownedAgentSends[ownerID] = OwnedAgentSend(epoch: epoch, task: owner)
        let result = await owner.value
        ownedAgentSends.removeValue(forKey: ownerID)
        guard ownsAgentWork(epoch, using: session) else {
            throw .cancelled
        }
        switch result {
        case .success:
            return
        case let .failure(error):
            throw error
        }
    }

    private static func clipboardSendPolicy(
        _ command: VDAgentClipboardCommand
    ) -> (priority: AgentOutboundPriority, requiredControl: Bool) {
        switch command {
        case .announceCapabilities(requestReply: false, _),
             .data,
             .release:
            (.high, true)
        case .announceCapabilities(requestReply: true, _),
             .grab,
             .serialGrab,
             .maxClipboard,
             .request:
            (.normal, false)
        }
    }

    private func allocateClipboardOwnerID() -> UInt64 {
        let id = nextClipboardOwnerID
        nextClipboardOwnerID &+= 1
        if nextClipboardOwnerID == 0 { nextClipboardOwnerID = 1 }
        return id
    }

    private func allocateManualOfferID() -> SpiceClipboardOfferID {
        let id = SpiceClipboardOfferID(rawValue: nextManualOfferID)
        nextManualOfferID &+= 1
        if nextManualOfferID == 0 { nextManualOfferID = 1 }
        return id
    }

    private func waitForManualGrab(id: SpiceClipboardOfferID) async throws {
        if let result = manualGrabResults.removeValue(forKey: id) {
            return try result.get()
        }
        let result = await withCheckedContinuation { continuation in
            manualGrabWaiters[id] = continuation
        }
        try result.get()
    }

    private func cancelManualClipboardOffer(
        id: SpiceClipboardOfferID,
        leaseGeneration: UInt64
    ) async {
        finishManualGrab(id: id, result: .failure(.transport(.cancelled)))
        let actions = state.revokeManualOffer(
            id: id,
            leaseGeneration: leaseGeneration
        )
        guard let session else {
            emitActions(actions)
            return
        }
        await execute(actions, using: session)
    }

    private func finishManualGrab(
        id: SpiceClipboardOfferID,
        result: Result<Void, SpiceClipboardError>
    ) {
        guard manualGrabResults[id] == nil else { return }
        if let waiter = manualGrabWaiters.removeValue(forKey: id) {
            waiter.resume(returning: result)
        } else {
            manualGrabResults[id] = result
        }
    }

    private func failManualGrabIfPresent(
        _ action: ClipboardStateMachine.Action,
        error: SpiceClipboardError
    ) {
        guard case let .manualOffer(.sendGrab(_, id, _)) = action else { return }
        finishManualGrab(id: id, result: .failure(error))
    }

    private func manualGrabID(
        for action: ClipboardStateMachine.Action
    ) -> SpiceClipboardOfferID? {
        guard case let .manualOffer(.sendGrab(_, id, _)) = action else { return nil }
        return id
    }

    private func preflightManualOfferActions(
        _ actions: [ClipboardStateMachine.Action]
    ) {
        for action in actions {
            guard case let .manualOffer(.emit(event)) = action,
                  event.result == .superseded || event.result == .revoked else {
                continue
            }
            var removedPendingGrab = false
            pendingActions.removeAll { pending in
                switch pending {
                case let .manualOffer(.sendGrab(_, id, _)):
                    if id == event.id {
                        removedPendingGrab = true
                        return true
                    }
                    return false
                case let .manualOffer(.sendData(_, id, _)):
                    return id == event.id
                case .send, .manualOffer(.emit), .writeGuestText, .emit:
                    return false
                }
            }
            let invalidatesInFlight = clipboardInFlight.map {
                manualGrabID(for: $0.action) == event.id
            } ?? false
            if invalidatesInFlight {
                invalidatedManualGrabIDs.insert(event.id)
            }
            if removedPendingGrab || invalidatesInFlight {
                finishManualGrab(
                    id: event.id,
                    result: .failure(.invalidAgentMessage(
                        "manual clipboard offer ended before GRAB: \(event.result)"
                    ))
                )
            }
        }
    }

    private func allocateOwnedAgentSendID() -> UInt64 {
        let id = nextOwnedAgentSendID
        nextOwnedAgentSendID &+= 1
        if nextOwnedAgentSendID == 0 { nextOwnedAgentSendID = 1 }
        return id
    }

    private func currentAgentWorkEpoch(using session: SpiceSession) -> AgentWorkEpoch? {
        guard agentWorkInvalidationGeneration == nil,
              self.session === session else {
            return nil
        }
        return AgentWorkEpoch(
            lifecycleGeneration: lifecycleGeneration,
            agentWorkGeneration: agentWorkGeneration,
            sessionID: ObjectIdentifier(session)
        )
    }

    private func ownsAgentWork(
        _ epoch: AgentWorkEpoch,
        using session: SpiceSession
    ) -> Bool {
        agentWorkInvalidationGeneration == nil
            && self.session === session
            && epoch.lifecycleGeneration == lifecycleGeneration
            && epoch.agentWorkGeneration == agentWorkGeneration
            && epoch.sessionID == ObjectIdentifier(session)
    }

    private func ownsClipboardAction(_ owner: ClipboardActionOwner) -> Bool {
        clipboardInFlight == owner && owner.generation == agentWorkGeneration
    }

    private func clearClipboardOwner(_ owner: ClipboardActionOwner) {
        if clipboardInFlight == owner {
            clipboardInFlight = nil
        }
    }

    private struct AgentWorkInvalidation {
        let generation: UInt64
        let owners: [(id: UInt64, task: Task<Result<Void, SpiceError>, Never>)]
    }

    private func beginAgentWorkInvalidation() -> AgentWorkInvalidation {
        agentWorkGeneration &+= 1
        let generation = agentWorkGeneration
        agentWorkInvalidationGeneration = generation
        agentWorkInvalidationSequence &+= 1
        var pendingWaiters: [AgentWorkInvalidationWaiter] = []
        for waiter in agentWorkInvalidationWaiters {
            if waiter.observedSequence == agentWorkInvalidationSequence {
                pendingWaiters.append(waiter)
            } else {
                waiter.continuation.resume()
            }
        }
        agentWorkInvalidationWaiters = pendingWaiters
        var invalidatedGrabIDs = Set(pendingActions.compactMap(manualGrabID))
        if let clipboardInFlight,
           let id = manualGrabID(for: clipboardInFlight.action) {
            invalidatedGrabIDs.insert(id)
        }
        for id in invalidatedGrabIDs {
            finishManualGrab(id: id, result: .failure(.transport(.cancelled)))
        }
        invalidatedManualGrabIDs.subtract(invalidatedGrabIDs)
        pendingActions.removeAll(keepingCapacity: false)
        clipboardInFlight = nil
        clipboardDriverGeneration = nil
        fileTransferDriverGeneration = nil
        let owners = ownedAgentSends.map { (id: $0.key, task: $0.value.task) }
        for owner in owners {
            owner.task.cancel()
        }
        return AgentWorkInvalidation(generation: generation, owners: owners)
    }

    private func finishAgentWorkInvalidation(
        _ invalidation: AgentWorkInvalidation
    ) async {
        for owner in invalidation.owners {
            _ = await owner.task.value
            ownedAgentSends.removeValue(forKey: owner.id)
        }
        if agentWorkInvalidationGeneration == invalidation.generation {
            agentWorkInvalidationGeneration = nil
        }
    }

    private func invalidateAgentWork() async {
        let invalidation = beginAgentWorkInvalidation()
        await finishAgentWorkInvalidation(invalidation)
    }

    package func ownedAgentSendCountForTesting() -> Int {
        ownedAgentSends.count
    }

    package func agentWorkInvalidationSequenceForTesting() -> UInt64 {
        agentWorkInvalidationSequence
    }

    package func waitUntilAgentWorkInvalidatesForTesting(
        after observedSequence: UInt64
    ) async {
        guard agentWorkInvalidationSequence == observedSequence else { return }
        await withCheckedContinuation { continuation in
            agentWorkInvalidationWaiters.append(AgentWorkInvalidationWaiter(
                observedSequence: observedSequence,
                continuation: continuation
            ))
        }
    }

    private func emitActions(_ actions: [ClipboardStateMachine.Action]) {
        preflightManualOfferActions(actions)
        for action in actions {
            switch action {
            case let .emit(event):
                emit(event)
            case let .manualOffer(.emit(event)):
                manualOfferContinuation.yield(event)
            case .send, .manualOffer(.sendGrab), .manualOffer(.sendData), .writeGuestText:
                break
            }
        }
    }

    private func emit(_ event: SpiceClipboardEvent) {
        _ = eventContinuation.yield(event)
    }

    private func emitDisplay(_ event: SpiceDisplayConfigurationEvent) {
        _ = displayConfigurationContinuation.yield(event)
    }

    private func emitDisplayConfigurationSupportIfChanged() {
        let support = state.displayConfigurationSupport
        guard support != lastDisplayConfigurationSupport else { return }
        lastDisplayConfigurationSupport = support
        _ = displayConfigurationSupportContinuation.yield(support)
    }

    private func emitFileTransfer(_ event: SpiceFileTransferEvent) {
        _ = fileTransferContinuation.yield(event)
    }

    private static func addClamped(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

@available(*, deprecated, renamed: "SpiceAgentManager")
public typealias SpiceClipboardManager = SpiceAgentManager

private final class FileTransferReader: Sendable {
    private let handle: Mutex<FileHandle?>

    init(source: URL) throws {
        handle = Mutex(try FileHandle(forReadingFrom: source))
    }

    func size() throws -> UInt64 {
        try handle.withLock { handle in
            guard let handle else {
                throw CocoaError(.fileReadUnknown)
            }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            return size
        }
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        try handle.withLock { handle in
            guard let handle else {
                throw CocoaError(.fileReadUnknown)
            }
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
    }

    func close() {
        handle.withLock { handle in
            try? handle?.close()
            handle = nil
        }
    }

    deinit {
        close()
    }
}
