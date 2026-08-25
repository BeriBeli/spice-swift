import Foundation
import SpiceProtocol
import SpiceWire
import Synchronization

/// Content-free observations for the VDAgent wire and clipboard state-machine
/// path owned by one manager.
///
/// Counters are cumulative for the lifetime of the manager. Capability flags
/// and last-value fields are the most recent observation in that lifetime.
/// Message payloads, clipboard text, file names, byte counts, endpoint details,
/// and error strings are never retained.
public struct SpiceAgentWireDiagnostics: Sendable, Equatable {
    public internal(set) var capabilityAnnouncementsAttempted: UInt64 = 0
    public internal(set) var capabilityAnnouncementsSent: UInt64 = 0
    public internal(set) var capabilityAnnouncementFailures: UInt64 = 0
    public internal(set) var inboundMessages: UInt64 = 0
    public internal(set) var inboundCurrentProtocolMessages: UInt64 = 0
    public internal(set) var inboundUnexpectedProtocolMessages: UInt64 = 0
    public internal(set) var inboundCapabilityAnnouncements: UInt64 = 0
    public internal(set) var inboundClipboardMessages: UInt64 = 0
    public internal(set) var inboundClipboardDataMessages: UInt64 = 0
    public internal(set) var inboundClipboardGrabMessages: UInt64 = 0
    public internal(set) var inboundClipboardRequestMessages: UInt64 = 0
    public internal(set) var inboundClipboardReleaseMessages: UInt64 = 0
    public internal(set) var inboundMonitorReplies: UInt64 = 0
    public internal(set) var inboundFileTransferMessages: UInt64 = 0
    public internal(set) var inboundOtherMessages: UInt64 = 0
    public internal(set) var inboundDecodeFailures: UInt64 = 0
    /// Latest values from an explicit peer capability announcement, if any.
    public internal(set) var peerLegacyClipboardCapability: Bool?
    public internal(set) var peerClipboardByDemandCapability: Bool?
    public internal(set) var clipboardFailures: UInt64 = 0
    public internal(set) var lastClipboardFailureCategory: SpiceClipboardFailureCategory?
    public internal(set) var lastInboundProtocolID: UInt32?
    public internal(set) var lastInboundMessageType: UInt32?

    public init() {}

    public static let empty = SpiceAgentWireDiagnostics()
}

/// Synchronizes the general macOS pasteboard with the VDAgent UTF-8 clipboard.
///
/// This is a data-transfer path. It does not synthesize keyboard scan codes or
/// expose guest IME composition and candidate state.
public actor SpiceAgentManager {
    private struct RunKey: Sendable, Equatable {
        let identifier: UInt64
        let sessionIdentifier: ObjectIdentifier
    }

    private struct ProcessedBoundary: Sendable {
        let runKey: RunKey
        var revision: UInt64
    }

    private struct ReconnectBoundaryWaiter {
        let runKey: RunKey
        let targetRevision: UInt64
        let operationToken: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct ReconnectBoundaryOperation {
        let runKey: RunKey
        let connectionGeneration: UInt64
        var sessionLifecycleID: UInt64?
        var sessionWaitTask: Task<Void, Never>?
        var superseded = false
    }

    private struct ActiveAgentOperation {
        let session: SpiceSession
        let runKey: RunKey
        let connectionGeneration: UInt64
    }

    public static let maximumWireTextBytes = 16 * 1_024 * 1_024 - 4

    public nonisolated let events: AsyncStream<SpiceClipboardEvent>
    public nonisolated let displayConfigurationEvents:
        AsyncStream<SpiceDisplayConfigurationEvent>
    public nonisolated let displayConfigurationSupportEvents:
        AsyncStream<SpiceDisplayConfigurationSupport>
    public nonisolated let fileTransferEvents: AsyncStream<SpiceFileTransferEvent>

    private let eventContinuation: AsyncStream<SpiceClipboardEvent>.Continuation
    private let displayConfigurationContinuation:
        AsyncStream<SpiceDisplayConfigurationEvent>.Continuation
    private let displayConfigurationSupportContinuation:
        AsyncStream<SpiceDisplayConfigurationSupport>.Continuation
    private let fileTransferContinuation: AsyncStream<SpiceFileTransferEvent>.Continuation
    private let automaticallySynchronizesPasteboard: Bool
    private var pasteboardSynchronizationEnabled: Bool
    private let pollInterval: Duration
    private var state: ClipboardStateMachine
    private var eventTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var session: SpiceSession?
    private var nextRunIdentifier: UInt64 = 0
    private var currentRunKey: RunKey?
    private var isStarting = false
    private var isStopping = false
    private var startCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var reconnectStartWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var stopCompletionWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeOperationCount = 0
    private var nextOperationDrainWaiterToken: UInt64 = 0
    private var operationDrainWaiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var pendingActions: [ClipboardStateMachine.Action] = []
    private var displayCoordinator = DisplayConfigurationCoordinator()
    private var lastDisplayConfigurationSupport: SpiceDisplayConfigurationSupport?
    private let maximumConcurrentFileTransfers: Int
    private let maximumFileBytes: UInt64
    private let fileTransferChunkBytes: Int
    private let fileTransferCodec: VDAgentFileTransferCodec
    private var fileTransfers: [SpiceFileTransferID: FileTransferJob] = [:]
    private var fileTransferReaders: [SpiceFileTransferID: FileTransferReader] = [:]
    private var nextFileTransferID: UInt32 = 1
    private var wireDiagnostics = SpiceAgentWireDiagnostics()
    private var currentAgentConnectionGeneration: UInt64 = 0
    private var currentSessionLifecycleID: UInt64?
    private var processedBoundary: ProcessedBoundary?
    private var reconnectQuiescingRunKey: RunKey?
    private var reconnectQuiescingConnectionGeneration: UInt64?
    private var nextReconnectBoundaryToken: UInt64 = 0
    private var activeReconnectBoundaries: [UInt64: ReconnectBoundaryOperation] = [:]
    private var committedReconnectQuiesceRunKey: RunKey?
    private var committedReconnectQuiesceGeneration: UInt64?
    private var committedReconnectQuiesceLifecycleID: UInt64?
    private var reconnectBoundaryWaiters: [ReconnectBoundaryWaiter] = []
    private var reconnectBoundarySnapshotHook: (@Sendable () async -> Void)?
    private var messageProcessingHook: (@Sendable () async -> Void)?
    private var eventProcessingHook: (@Sendable (SpiceAgentEvent) async -> Void)?
    private var startProcessingHook: (@Sendable () async -> Void)?
    private var fileInspectionHook: (@Sendable () async -> Void)?
    private var fileMessageCompletionHook: (@Sendable () async -> Void)?

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
            clipboardEnabled: pasteboardSynchronizationEnabled
        )
    }

    deinit {
        eventTask?.cancel()
        pollTask?.cancel()
        for operation in activeReconnectBoundaries.values {
            operation.sessionWaitTask?.cancel()
        }
        eventContinuation.finish()
        displayConfigurationContinuation.finish()
        displayConfigurationSupportContinuation.finish()
        fileTransferContinuation.finish()
        for waiter in reconnectBoundaryWaiters {
            waiter.continuation.resume()
        }
        for waiter in startCompletionWaiters {
            waiter.resume()
        }
        for waiter in reconnectStartWaiters.values {
            waiter.resume()
        }
        for waiter in stopCompletionWaiters {
            waiter.resume()
        }
        for waiter in operationDrainWaiters.values {
            waiter.resume()
        }
    }

    public func start(session: SpiceSession) async throws(SpiceClipboardError) {
        guard eventTask == nil, !isStarting, !isStopping else {
            throw .alreadyRunning
        }
        nextRunIdentifier &+= 1
        let runKey = RunKey(
            identifier: nextRunIdentifier,
            sessionIdentifier: ObjectIdentifier(session)
        )
        currentRunKey = runKey
        isStarting = true
        defer { finishStart() }
        self.session = session
        // The first await establishes this run's ownership boundary. A
        // disconnect ordered before it predates this consumer; one ordered
        // after it carries a strictly newer envelope revision that must be
        // processed before reconnect.
        let baselineRevision = await session.currentAgentDisconnectRevision()
        guard isCurrentStartingRun(runKey, session: session) else { return }
        processedBoundary = ProcessedBoundary(
            runKey: runKey,
            revision: baselineRevision
        )
        if let startProcessingHook {
            await startProcessingHook()
            guard isCurrentStartingRun(runKey, session: session) else { return }
        }
        let agentConnection = await session.currentAgentConnectionSnapshot()
        guard isCurrentStartingRun(runKey, session: session) else { return }
        currentAgentConnectionGeneration = agentConnection.generation
        currentSessionLifecycleID = agentConnection.sessionLifecycleID
        if agentConnection.isConnected {
            await execute(
                state.connected(),
                using: session,
                expectedConnectionGeneration: agentConnection.generation
            )
            guard isCurrentStartingRun(runKey, session: session) else { return }
        }
        guard isCurrentStartingRun(runKey, session: session) else { return }
        emitDisplayConfigurationSupportIfChanged()
        eventTask = Task { [weak self] in
            for await envelope in session.agentEventEnvelopes {
                // Once dequeued, an envelope belongs to this run. Finish it
                // even if stop() cancels the pump, then cancellation ends the
                // following next() while stop() drains this task.
                await self?.receive(envelope, from: session, runKey: runKey)
            }
        }
        let pollInterval = self.pollInterval
        pollTask = Task { [weak self] in
            let clock = ContinuousClock()
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: pollInterval)
                } catch {
                    return
                }
                await self?.performPeriodicWork()
            }
        }
    }

    public func stop() async {
        if isStopping {
            await withCheckedContinuation { continuation in
                stopCompletionWaiters.append(continuation)
            }
            return
        }
        isStopping = true
        for operation in activeReconnectBoundaries.values {
            operation.sessionWaitTask?.cancel()
        }
        let oldEventTask = eventTask
        eventTask = nil
        let oldPollTask = pollTask
        pollTask = nil
        oldEventTask?.cancel()
        oldPollTask?.cancel()

        if isStarting {
            await withCheckedContinuation { continuation in
                startCompletionWaiters.append(continuation)
            }
        }
        // A start suspended before task installation must not leave a late
        // pump behind. The normal generation guards prevent this; recapturing
        // here also makes stop's drain fence defensive against future awaits.
        let lateEventTask = eventTask
        eventTask = nil
        let latePollTask = pollTask
        pollTask = nil
        lateEventTask?.cancel()
        latePollTask?.cancel()
        await oldEventTask?.value
        await oldPollTask?.value
        await lateEventTask?.value
        await latePollTask?.value
        await waitForActiveOperationsToDrain()

        session = nil
        pendingActions.removeAll(keepingCapacity: false)
        displayCoordinator.reset()
        cancelAllFileTransfers()
        emitActions(state.disconnected())
        emitDisplayConfigurationSupportIfChanged()
        resumeReconnectBoundaryWaiters()
        currentRunKey = nil
        currentAgentConnectionGeneration = 0
        currentSessionLifecycleID = nil
        processedBoundary = nil
        reconnectQuiescingRunKey = nil
        reconnectQuiescingConnectionGeneration = nil
        activeReconnectBoundaries.removeAll(keepingCapacity: false)
        committedReconnectQuiesceRunKey = nil
        committedReconnectQuiesceGeneration = nil
        committedReconnectQuiesceLifecycleID = nil
        isStopping = false
        let stopWaiters = stopCompletionWaiters
        stopCompletionWaiters.removeAll(keepingCapacity: false)
        for waiter in stopWaiters {
            waiter.resume()
        }
    }

    /// Waits until the manager's single Agent event pump has processed the
    /// latest disconnect boundary emitted by its session. The session
    /// disconnect itself and every old-session message ordered before that
    /// revision have then finished, so the same `SpiceSession` may safely
    /// reconnect without carrying Agent work into the new connection.
    public func waitForSessionReconnectBoundary() async {
        guard !isStopping, let session, let runKey = currentRunKey else { return }
        nextReconnectBoundaryToken &+= 1
        let operationToken = nextReconnectBoundaryToken
        activeReconnectBoundaries[operationToken] = ReconnectBoundaryOperation(
            runKey: runKey,
            connectionGeneration: currentAgentConnectionGeneration,
            sessionLifecycleID: currentSessionLifecycleID
        )
        refreshReconnectQuiesce(for: runKey)
        defer { finishReconnectBoundaryOperation(operationToken, runKey: runKey) }

        if let reconnectBoundarySnapshotHook {
            await reconnectBoundarySnapshotHook()
            guard isCurrentReconnectBoundaryOperation(
                operationToken,
                runKey: runKey,
                session: session
            ) else { return }
        }
        let connection = await session.currentAgentConnectionSnapshot()
        guard isCurrentReconnectBoundaryOperation(
            operationToken,
            runKey: runKey,
            session: session
        ) else { return }
        let boundaryLifecycleID = activeReconnectBoundaries[operationToken]?.sessionLifecycleID
        let lifecycleToWait: UInt64?
        if let currentLifecycleID = connection.sessionLifecycleID {
            if let boundaryLifecycleID {
                // A different live lifecycle means disconnect/reconnect won
                // the actor hop. Never attach this old boundary to the new
                // session and wait for its next disconnect.
                lifecycleToWait = currentLifecycleID == boundaryLifecycleID
                    ? currentLifecycleID
                    : nil
            } else {
                activeReconnectBoundaries[operationToken]?.sessionLifecycleID = currentLifecycleID
                currentSessionLifecycleID = currentLifecycleID
                lifecycleToWait = currentLifecycleID
            }
        } else {
            lifecycleToWait = nil
        }
        refreshReconnectQuiesce(for: runKey)

        if let lifecycleID = lifecycleToWait {
            // Bind the wait to the exact lifecycle seen by the first snapshot.
            // A complete disconnect/reconnect between these actor hops then
            // returns immediately instead of waiting on the new connection.
            let sessionWaitTask = Task {
                await session.waitUntilConnectionInactiveForReconnect(
                    observedLifecycleID: lifecycleID
                )
            }
            activeReconnectBoundaries[operationToken]?.sessionWaitTask = sessionWaitTask
            await withTaskCancellationHandler {
                await sessionWaitTask.value
            } onCancel: {
                sessionWaitTask.cancel()
            }
            activeReconnectBoundaries[operationToken]?.sessionWaitTask = nil
            guard isCurrentReconnectBoundaryOperation(
                operationToken,
                runKey: runKey,
                session: session
            ) else { return }
        }
        if isStarting {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || !isStarting || self.session !== session
                        || currentRunKey != runKey || isStopping {
                        continuation.resume()
                    } else {
                        reconnectStartWaiters[operationToken] = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelReconnectStartWaiter(operationToken) }
            }
            guard isCurrentReconnectBoundaryOperation(
                operationToken,
                runKey: runKey,
                session: session
            ) else { return }
        }
        let targetRevision = await session.currentAgentDisconnectRevision()
        guard isCurrentReconnectBoundaryOperation(
            operationToken,
            runKey: runKey,
            session: session
        ) else { return }
        let processedRevision = processedBoundary?.runKey == runKey
            ? processedBoundary?.revision ?? 0
            : 0
        if processedRevision < targetRevision {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let currentProcessedRevision = processedBoundary?.runKey == runKey
                    ? processedBoundary?.revision ?? 0
                    : 0
                    if Task.isCancelled || self.session !== session
                        || currentRunKey != runKey || isStopping
                        || currentProcessedRevision >= targetRevision {
                        continuation.resume()
                    } else {
                        reconnectBoundaryWaiters.append(ReconnectBoundaryWaiter(
                            runKey: runKey,
                            targetRevision: targetRevision,
                            operationToken: operationToken,
                            continuation: continuation
                        ))
                    }
                }
            } onCancel: {
                Task { await self.cancelReconnectBoundaryWaiter(operationToken) }
            }
        }
        guard isCurrentReconnectBoundaryOperation(
            operationToken,
            runKey: runKey,
            session: session
        ) else { return }
        await waitForActiveOperationsToDrain(cancellable: true)
        guard isCurrentReconnectBoundaryOperation(
            operationToken,
            runKey: runKey,
            session: session
        ) else { return }
        guard let operation = activeReconnectBoundaries[operationToken] else { return }
        committedReconnectQuiesceRunKey = runKey
        committedReconnectQuiesceGeneration = connection.generation
        committedReconnectQuiesceLifecycleID = operation.sessionLifecycleID
        if currentSessionLifecycleID == operation.sessionLifecycleID {
            currentSessionLifecycleID = nil
        }
        refreshReconnectQuiesce(for: runKey)
    }

    package func setMessageProcessingHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        precondition(eventTask == nil)
        messageProcessingHook = hook
    }

    package func setEventProcessingHookForTesting(
        _ hook: (@Sendable (SpiceAgentEvent) async -> Void)?
    ) {
        precondition(eventTask == nil)
        eventProcessingHook = hook
    }

    package func setStartProcessingHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        precondition(eventTask == nil)
        startProcessingHook = hook
    }

    package func setFileInspectionHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        precondition(eventTask == nil)
        fileInspectionHook = hook
    }

    package func setFileMessageCompletionHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        precondition(eventTask == nil)
        fileMessageCompletionHook = hook
    }

    package func setReconnectBoundarySnapshotHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        precondition(eventTask == nil)
        reconnectBoundarySnapshotHook = hook
    }

    package func isReconnectBoundaryQuiescingForTesting() -> Bool {
        reconnectQuiescingRunKey == currentRunKey
    }

    package func isReconnectBoundaryWaitingForOperationsForTesting() -> Bool {
        !operationDrainWaiters.isEmpty
    }

    package func activeFileTransferCountForTesting() -> Int {
        fileTransfers.count
    }

    /// Returns content-free aggregate observations of the Agent wire and
    /// clipboard state-machine path.
    public func diagnosticsSnapshot() -> SpiceAgentWireDiagnostics {
        wireDiagnostics
    }

    /// Checks the current pasteboard immediately rather than waiting for the
    /// optional polling loop.
    public func synchronizePasteboard() async {
        guard pasteboardSynchronizationEnabled,
              let operation = beginActiveAgentOperation() else {
            return
        }
        defer { finishActiveAgentOperation() }
        await execute(
            state.announcementIfNeeded(),
            using: operation.session,
            expectedConnectionGeneration: operation.connectionGeneration
        )
        guard isCurrent(operation) else { return }
        let snapshot = await SpicePasteboardBridge.snapshot()
        guard isCurrent(operation) else { return }
        await execute(state.localPasteboardChanged(
            changeCount: snapshot.changeCount,
            text: snapshot.text
        ), using: operation.session, expectedConnectionGeneration: operation.connectionGeneration)
        await sendPendingDisplayConfiguration(
            using: operation.session,
            expectedConnectionGeneration: operation.connectionGeneration
        )
        await driveFileTransfers(
            using: operation.session,
            expectedConnectionGeneration: operation.connectionGeneration
        )
    }

    /// Publishes text locally and offers it to the guest without polling delay.
    public func publish(_ text: String) async {
        guard pasteboardSynchronizationEnabled else { return }
        let operation = beginActiveAgentOperation()
        defer {
            if operation != nil { finishActiveAgentOperation() }
        }
        let snapshot: SpicePasteboardSnapshot
        do {
            snapshot = try await SpicePasteboardBridge.write(text: text)
        } catch {
            emit(.failed(error))
            return
        }
        guard let operation, isCurrent(operation) else {
            return
        }
        await execute(state.localPasteboardChanged(
            changeCount: snapshot.changeCount,
            text: snapshot.text
        ), using: operation.session, expectedConnectionGeneration: operation.connectionGeneration)
    }

    /// Changes whether this manager may advertise clipboard support or access
    /// the general pasteboard. Other Agent services remain active either way.
    public func setPasteboardSynchronizationEnabled(_ enabled: Bool) async {
        guard pasteboardSynchronizationEnabled != enabled else { return }
        pasteboardSynchronizationEnabled = enabled
        guard let operation = beginActiveAgentOperation() else {
            _ = state.setClipboardEnabled(enabled)
            return
        }
        defer { finishActiveAgentOperation() }
        await execute(
            state.setClipboardEnabled(enabled),
            using: operation.session,
            expectedConnectionGeneration: operation.connectionGeneration
        )
        if enabled, isCurrent(operation) {
            await synchronizePasteboard()
        }
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
        guard let operation = beginActiveAgentOperation() else {
            throw .agentManagerNotRunning
        }
        defer { finishActiveAgentOperation() }
        if state.hasExplicitPeerCapabilities,
           !state.supportsMonitorConfiguration {
            throw .unsupportedByAgent
        }
        _ = try makeWireDisplayConfiguration(configuration)
        displayCoordinator.queue(configuration)
        emitDisplay(.queued(configuration))
        await sendPendingDisplayConfiguration(
            using: operation.session,
            expectedConnectionGeneration: operation.connectionGeneration
        )
    }

    /// Explicitly authorizes one host-to-guest transfer. No directory is
    /// scanned and no guest-originated path is ever written on the host.
    public func sendFile(
        at source: URL,
        name: String? = nil
    ) async throws(SpiceFileTransferError) -> SpiceFileTransferID {
        guard let operation = beginActiveAgentOperation() else {
            throw .agentManagerNotRunning
        }
        defer { finishActiveAgentOperation() }
        guard state.isAgentConnected else {
            throw .agentUnavailable
        }
        if state.hasFileTransferCapabilityState, !state.supportsFileTransfer {
            throw .disabledByGuest
        }
        guard fileTransfers.count < maximumConcurrentFileTransfers else {
            throw .tooManyConcurrentTransfers(maximum: maximumConcurrentFileTransfers)
        }
        if let fileInspectionHook {
            await fileInspectionHook()
        }
        let info = try await Self.inspectFile(source, overrideName: name)
        guard isCurrent(operation), state.isAgentConnected else {
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
        await driveFileTransfers(
            using: operation.session,
            expectedConnectionGeneration: operation.connectionGeneration
        )
        guard isCurrent(operation) else { throw .agentUnavailable }
        return id
    }

    public func cancelFileTransfer(_ id: SpiceFileTransferID) async {
        guard let operation = beginActiveAgentOperation() else { return }
        defer { finishActiveAgentOperation() }
        guard var job = fileTransfers[id] else {
            return
        }
        switch job.phase {
        case .queuedStart:
            removeFileTransfer(id)
            emitFileTransfer(.cancelled(id: id))
            return
        case .queuedCancellation, .awaitingCancellation:
            return
        case .awaitingGuestApproval,
             .readyToRead,
             .reading,
             .readyToSend,
             .awaitingCompletion,
             .queuedFailure:
            job.phase = .queuedCancellation
            fileTransfers[id] = job
        }
        await driveFileTransfers(
            using: operation.session,
            expectedConnectionGeneration: operation.connectionGeneration
        )
    }

    private func receive(
        _ envelope: SpiceAgentEventEnvelope,
        from session: SpiceSession,
        runKey: RunKey
    ) async {
        guard isCurrentRun(runKey, session: session) else { return }
        let event = envelope.event
        let expectedConnectionGeneration = envelope.connectionGeneration
        if let eventProcessingHook {
            await eventProcessingHook(event)
            guard isCurrentRun(runKey, session: session) else { return }
        }
        switch event {
        case .connected:
            currentAgentConnectionGeneration = expectedConnectionGeneration
            currentSessionLifecycleID = envelope.sessionLifecycleID
            // Retire old-session fences before capability, pasteboard, or
            // display work introduces an actor reentrancy window.
            reconnectDidConnect(
                generation: expectedConnectionGeneration,
                sessionLifecycleID: envelope.sessionLifecycleID,
                runKey: runKey
            )
            guard !state.isAgentConnected else {
                return
            }
            pendingActions.removeAll(keepingCapacity: false)
            displayCoordinator.disconnected()
            await execute(
                state.connected(),
                using: session,
                expectedConnectionGeneration: expectedConnectionGeneration
            )
            emitDisplayConfigurationSupportIfChanged()
            if automaticallySynchronizesPasteboard, pasteboardSynchronizationEnabled {
                let snapshot = await SpicePasteboardBridge.snapshot()
                await execute(state.localPasteboardChanged(
                    changeCount: snapshot.changeCount,
                    text: snapshot.text
                ), using: session, expectedConnectionGeneration: expectedConnectionGeneration)
            }
            await sendPendingDisplayConfiguration(
                using: session,
                expectedConnectionGeneration: expectedConnectionGeneration
            )
            await driveFileTransfers(
                using: session,
                expectedConnectionGeneration: expectedConnectionGeneration
            )
        case .disconnected:
            currentAgentConnectionGeneration = expectedConnectionGeneration
            if let sessionLifecycleID = envelope.sessionLifecycleID {
                currentSessionLifecycleID = sessionLifecycleID
            }
            transitionToDisconnected()
            if let revision = envelope.disconnectRevision {
                acknowledgeReconnectBoundary(revision: revision, runKey: runKey)
            }
        case let .message(message):
            if let messageProcessingHook {
                await messageProcessingHook()
                guard isCurrentRun(runKey, session: session) else { return }
            }
            recordInboundMessage(message)
            let wireMessage = VDAgentMessage(
                protocolID: message.protocolID,
                type: message.type,
                opaque: message.opaque,
                data: message.data
            )
            if message.type == VDAgentMessageType.reply.rawValue {
                do {
                    if let reply = try VDAgentMonitorCodec.decodeReply(wireMessage) {
                        await receiveMonitorReply(
                            reply,
                            using: session,
                            expectedConnectionGeneration: expectedConnectionGeneration
                        )
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
                    await receiveFileTransfer(
                        command,
                        using: session,
                        expectedConnectionGeneration: expectedConnectionGeneration
                    )
                } catch {
                    emitFileTransfer(.failed(
                        id: nil,
                        .invalidAgentResponse(String(describing: error))
                    ))
                }
                return
            }
            do {
                let command: VDAgentClipboardCommand?
                do {
                    command = try VDAgentClipboardCodec.decode(wireMessage)
                } catch {
                    wireDiagnostics.inboundDecodeFailures &+= 1
                    recordClipboardFailure(.decodeFailure)
                    emit(.failed(.invalidAgentMessage(String(describing: error))))
                    return
                }
                guard let command else {
                    return
                }
                recordPeerClipboardCapabilities(command)
                await execute(
                    try state.receive(command),
                    using: session,
                    expectedConnectionGeneration: expectedConnectionGeneration
                )
                emitDisplayConfigurationSupportIfChanged()
                await sendPendingDisplayConfiguration(
                    using: session,
                    expectedConnectionGeneration: expectedConnectionGeneration
                )
                await driveFileTransfers(
                    using: session,
                    expectedConnectionGeneration: expectedConnectionGeneration
                )
            } catch let failure {
                recordClipboardFailure(failure.category)
                emit(.failed(failure.error))
            }
        }
    }

    private func transitionToDisconnected() {
        pendingActions.removeAll(keepingCapacity: false)
        displayCoordinator.disconnected()
        failAllFileTransfers(with: .agentUnavailable)
        emitActions(state.disconnected())
        emitDisplayConfigurationSupportIfChanged()
    }

    private func resumeReconnectBoundaryWaiters() {
        let waiters = reconnectBoundaryWaiters
        reconnectBoundaryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume()
        }
    }

    private func acknowledgeReconnectBoundary(revision: UInt64, runKey: RunKey) {
        guard currentRunKey == runKey else { return }
        let processedRevision = processedBoundary?.runKey == runKey
            ? processedBoundary?.revision ?? 0
            : 0
        let updatedRevision = max(processedRevision, revision)
        processedBoundary = ProcessedBoundary(
            runKey: runKey,
            revision: updatedRevision
        )
        var remaining: [ReconnectBoundaryWaiter] = []
        for waiter in reconnectBoundaryWaiters {
            if waiter.runKey == runKey,
               waiter.targetRevision <= updatedRevision {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        reconnectBoundaryWaiters = remaining
    }

    private func isCurrentRun(
        _ runKey: RunKey,
        session: SpiceSession
    ) -> Bool {
        currentRunKey == runKey && self.session === session
    }

    private func isCurrentStartingRun(
        _ runKey: RunKey,
        session: SpiceSession
    ) -> Bool {
        isStarting && !isStopping && isCurrentRun(runKey, session: session)
    }

    private func finishStart() {
        isStarting = false
        let waiters = startCompletionWaiters
        startCompletionWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        let reconnectWaiters = Array(reconnectStartWaiters.values)
        reconnectStartWaiters.removeAll(keepingCapacity: false)
        for waiter in reconnectWaiters {
            waiter.resume()
        }
    }

    private func isCurrentReconnectBoundaryOperation(
        _ token: UInt64,
        runKey: RunKey,
        session: SpiceSession
    ) -> Bool {
        guard !Task.isCancelled, !isStopping,
              currentRunKey == runKey, self.session === session,
              let operation = activeReconnectBoundaries[token] else {
            return false
        }
        return operation.runKey == runKey && !operation.superseded
    }

    private func finishReconnectBoundaryOperation(
        _ token: UInt64,
        runKey: RunKey
    ) {
        activeReconnectBoundaries.removeValue(forKey: token)?.sessionWaitTask?.cancel()
        reconnectStartWaiters.removeValue(forKey: token)?.resume()
        cancelReconnectBoundaryWaiter(token)
        refreshReconnectQuiesce(for: runKey)
    }

    private func cancelReconnectStartWaiter(_ token: UInt64) {
        reconnectStartWaiters.removeValue(forKey: token)?.resume()
    }

    private func cancelReconnectBoundaryWaiter(_ operationToken: UInt64) {
        var remaining: [ReconnectBoundaryWaiter] = []
        for waiter in reconnectBoundaryWaiters {
            if waiter.operationToken == operationToken {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        reconnectBoundaryWaiters = remaining
    }

    private func refreshReconnectQuiesce(for runKey: RunKey) {
        guard !isStopping, currentRunKey == runKey else {
            if reconnectQuiescingRunKey == runKey {
                reconnectQuiescingRunKey = nil
                reconnectQuiescingConnectionGeneration = nil
            }
            return
        }
        var generations = activeReconnectBoundaries.values.compactMap { operation in
            operation.runKey == runKey && !operation.superseded
                ? operation.connectionGeneration
                : nil
        }
        if committedReconnectQuiesceRunKey == runKey,
           let generation = committedReconnectQuiesceGeneration {
            generations.append(generation)
        }
        guard let generation = generations.max() else {
            if reconnectQuiescingRunKey == runKey {
                reconnectQuiescingRunKey = nil
                reconnectQuiescingConnectionGeneration = nil
            }
            return
        }
        reconnectQuiescingRunKey = runKey
        reconnectQuiescingConnectionGeneration = generation
    }

    private func reconnectDidConnect(
        generation: UInt64,
        sessionLifecycleID: UInt64?,
        runKey: RunKey
    ) {
        guard reconnectQuiescingRunKey == runKey else { return }
        if committedReconnectQuiesceRunKey == runKey,
           let committedGeneration = committedReconnectQuiesceGeneration,
           isNewSessionConnection(
               generation: generation,
               sessionLifecycleID: sessionLifecycleID,
               relativeToGeneration: committedGeneration,
               relativeToLifecycleID: committedReconnectQuiesceLifecycleID
           ) {
            committedReconnectQuiesceRunKey = nil
            committedReconnectQuiesceGeneration = nil
            committedReconnectQuiesceLifecycleID = nil
        }
        for token in Array(activeReconnectBoundaries.keys) {
            guard var operation = activeReconnectBoundaries[token],
                  operation.runKey == runKey,
                  isNewSessionConnection(
                      generation: generation,
                      sessionLifecycleID: sessionLifecycleID,
                      relativeToGeneration: operation.connectionGeneration,
                      relativeToLifecycleID: operation.sessionLifecycleID
                  ) else { continue }
            operation.superseded = true
            operation.sessionWaitTask?.cancel()
            activeReconnectBoundaries[token] = operation
        }
        refreshReconnectQuiesce(for: runKey)
    }

    private func isNewSessionConnection(
        generation: UInt64,
        sessionLifecycleID: UInt64?,
        relativeToGeneration oldGeneration: UInt64,
        relativeToLifecycleID oldLifecycleID: UInt64?
    ) -> Bool {
        if let sessionLifecycleID {
            return sessionLifecycleID != oldLifecycleID
        }
        return generation > oldGeneration
    }

    private func beginActiveAgentOperation() -> ActiveAgentOperation? {
        guard !isStarting, !isStopping,
              let currentRunKey,
              reconnectQuiescingRunKey != currentRunKey,
              eventTask != nil,
              let session else {
            return nil
        }
        activeOperationCount += 1
        return ActiveAgentOperation(
            session: session,
            runKey: currentRunKey,
            connectionGeneration: currentAgentConnectionGeneration
        )
    }

    private func isCurrent(_ operation: ActiveAgentOperation) -> Bool {
        !isStopping
            && currentRunKey == operation.runKey
            && session === operation.session
            && currentAgentConnectionGeneration == operation.connectionGeneration
    }

    private func isAgentGenerationCurrent(_ expected: UInt64?) -> Bool {
        guard let expected else { return true }
        return currentAgentConnectionGeneration == expected
    }

    private func finishActiveAgentOperation() {
        precondition(activeOperationCount > 0)
        activeOperationCount -= 1
        guard activeOperationCount == 0 else { return }
        let waiters = Array(operationDrainWaiters.values)
        operationDrainWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func waitForActiveOperationsToDrain(cancellable: Bool = false) async {
        guard activeOperationCount > 0 else { return }
        let token = nextOperationDrainWaiterToken
        nextOperationDrainWaiterToken &+= 1
        guard cancellable else {
            await withCheckedContinuation { continuation in
                if activeOperationCount == 0 {
                    continuation.resume()
                } else {
                    operationDrainWaiters[token] = continuation
                }
            }
            return
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || activeOperationCount == 0 {
                    continuation.resume()
                } else {
                    operationDrainWaiters[token] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelOperationDrainWaiter(token) }
        }
    }

    private func cancelOperationDrainWaiter(_ token: UInt64) {
        operationDrainWaiters.removeValue(forKey: token)?.resume()
    }

    private func receiveMonitorReply(
        _ reply: VDAgentMonitorReply,
        using session: SpiceSession,
        expectedConnectionGeneration: UInt64? = nil
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
        await sendPendingDisplayConfiguration(
            using: session,
            expectedConnectionGeneration: expectedConnectionGeneration
        )
    }

    private func sendPendingDisplayConfiguration(
        using session: SpiceSession,
        expectedConnectionGeneration: UInt64? = nil
    ) async {
        guard isAgentGenerationCurrent(expectedConnectionGeneration),
              pendingActions.isEmpty,
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
            try await session.sendAgentMessage(
                SpiceAgentMessage(
                    protocolID: message.protocolID,
                    type: message.type,
                    opaque: message.opaque,
                    data: message.data
                ),
                expectedConnectionGeneration: expectedConnectionGeneration
            )
            guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
            displayCoordinator.didSend(configuration)
            emitDisplay(.sent(configuration))
        } catch let error as SpiceError {
            guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
            emitDisplay(.failed(configuration, .transport(error)))
        } catch let error as SpiceDisplayConfigurationError {
            guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
            displayCoordinator.discardDesired()
            if error == .unsupportedByAgent {
                emitDisplay(.unsupported(configuration))
            } else {
                emitDisplay(.failed(configuration, error))
            }
        } catch {
            guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
            displayCoordinator.discardDesired()
            emitDisplay(.failed(configuration, .invalidAgentReply(
                String(describing: error)
            )))
        }
    }

    private func retryPendingAgentWork(
        using session: SpiceSession,
        expectedConnectionGeneration: UInt64
    ) async {
        await execute(
            state.announcementIfNeeded(),
            using: session,
            expectedConnectionGeneration: expectedConnectionGeneration
        )
        await sendPendingDisplayConfiguration(
            using: session,
            expectedConnectionGeneration: expectedConnectionGeneration
        )
        await driveFileTransfers(
            using: session,
            expectedConnectionGeneration: expectedConnectionGeneration
        )
    }

    private func performPeriodicWork() async {
        guard let operation = beginActiveAgentOperation() else { return }
        defer { finishActiveAgentOperation() }
        if automaticallySynchronizesPasteboard, pasteboardSynchronizationEnabled {
            if isCurrent(operation) { await synchronizePasteboard() }
        } else {
            await retryPendingAgentWork(
                using: operation.session,
                expectedConnectionGeneration: operation.connectionGeneration
            )
        }
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
        using session: SpiceSession,
        expectedConnectionGeneration: UInt64? = nil
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
            switch status.result {
            case .canSendData:
                guard job.phase == .awaitingGuestApproval else {
                    failFileTransfer(
                        id,
                        error: .invalidAgentResponse("CAN_SEND_DATA in phase \(job.phase)")
                    )
                    return
                }
                job.phase = .readyToRead
                fileTransfers[id] = job
                await driveFileTransfers(
                    using: session,
                    expectedConnectionGeneration: expectedConnectionGeneration
                )
            case .cancelled:
                removeFileTransfer(id)
                emitFileTransfer(.cancelled(id: id))
            case .success:
                guard job.phase == .awaitingCompletion else {
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

    private func driveFileTransfers(
        using session: SpiceSession,
        expectedConnectionGeneration: UInt64? = nil
    ) async {
        guard isAgentGenerationCurrent(expectedConnectionGeneration),
              pendingActions.isEmpty,
              state.isAgentConnected else {
            return
        }
        while true {
            guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
            var progressed = false
            for id in fileTransfers.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
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
                    guard await sendFileTransferMessage(
                        message,
                        using: session,
                        expectedConnectionGeneration: expectedConnectionGeneration
                    ) else {
                        return
                    }
                    guard isAgentGenerationCurrent(expectedConnectionGeneration),
                          fileTransfers[id] == job else { return }
                    job.phase = .awaitingGuestApproval
                    fileTransfers[id] = job
                    emitFileTransfer(.awaitingGuestApproval(id: id))
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
                        guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
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
                    guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
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
                    guard await sendFileTransferMessage(
                        message,
                        using: session,
                        expectedConnectionGeneration: expectedConnectionGeneration
                    ) else {
                        return
                    }
                    guard isAgentGenerationCurrent(expectedConnectionGeneration),
                          fileTransfers[id] == job else { return }
                    job.sentBytes += UInt64(data.count)
                    job.phase = job.sentBytes == job.totalBytes
                        ? .awaitingCompletion
                        : .readyToRead
                    fileTransfers[id] = job
                    emitFileTransfer(.progress(
                        id: id,
                        sentBytes: job.sentBytes,
                        totalBytes: job.totalBytes
                    ))
                    progressed = true
                case .queuedCancellation:
                    let message = fileTransferCodec.encodeStatus(
                        id: id.rawValue,
                        result: .cancelled
                    )
                    guard await sendFileTransferMessage(
                        message,
                        using: session,
                        expectedConnectionGeneration: expectedConnectionGeneration
                    ) else {
                        return
                    }
                    guard isAgentGenerationCurrent(expectedConnectionGeneration),
                          fileTransfers[id] == job else { return }
                    job.phase = .awaitingCancellation
                    fileTransfers[id] = job
                    progressed = true
                case let .queuedFailure(error):
                    let message = fileTransferCodec.encodeStatus(
                        id: id.rawValue,
                        result: .error
                    )
                    guard await sendFileTransferMessage(
                        message,
                        using: session,
                        expectedConnectionGeneration: expectedConnectionGeneration
                    ) else {
                        return
                    }
                    guard isAgentGenerationCurrent(expectedConnectionGeneration),
                          fileTransfers[id] == job else { return }
                    removeFileTransfer(id)
                    emitFileTransfer(.failed(id: id, error))
                    progressed = true
                case .awaitingGuestApproval,
                     .reading,
                     .awaitingCompletion,
                     .awaitingCancellation:
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
        using session: SpiceSession,
        expectedConnectionGeneration: UInt64? = nil
    ) async -> Bool {
        do {
            let sent = try await session.sendAgentMessageIfTokensAvailable(
                SpiceAgentMessage(
                    protocolID: message.protocolID,
                    type: message.type,
                    opaque: message.opaque,
                    data: message.data
                ),
                expectedConnectionGeneration: expectedConnectionGeneration
            )
            if let fileMessageCompletionHook { await fileMessageCompletionHook() }
            return sent && isAgentGenerationCurrent(expectedConnectionGeneration)
        } catch let error {
            if isAgentGenerationCurrent(expectedConnectionGeneration) {
                failAllFileTransfers(with: .transport(error))
            }
            return false
        }
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
        fileTransferReaders.removeValue(forKey: id)?.close()
    }

    private func execute(
        _ actions: [ClipboardStateMachine.Action],
        using session: SpiceSession,
        expectedConnectionGeneration: UInt64? = nil
    ) async {
        guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
        var work = pendingActions
        pendingActions.removeAll(keepingCapacity: true)
        for action in actions where !work.contains(action) {
            work.append(action)
        }

        for (index, action) in work.enumerated() {
            guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
            switch action {
            case let .send(command):
                let isCapabilityAnnouncement: Bool
                if case .announceCapabilities = command {
                    isCapabilityAnnouncement = true
                    wireDiagnostics.capabilityAnnouncementsAttempted &+= 1
                } else {
                    isCapabilityAnnouncement = false
                }
                do {
                    let message = try VDAgentClipboardCodec.encode(command)
                    try await session.sendAgentMessage(
                        SpiceAgentMessage(
                            protocolID: message.protocolID,
                            type: message.type,
                            opaque: message.opaque,
                            data: message.data
                        ),
                        expectedConnectionGeneration: expectedConnectionGeneration
                    )
                    guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
                    state.didSend(command)
                    if isCapabilityAnnouncement {
                        wireDiagnostics.capabilityAnnouncementsSent &+= 1
                    }
                } catch let error as SpiceError {
                    guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
                    if isCapabilityAnnouncement {
                        wireDiagnostics.capabilityAnnouncementFailures &+= 1
                    }
                    pendingActions = Array(work[index...])
                    recordClipboardFailure(.transport)
                    emit(.failed(.transport(error)))
                    return
                } catch {
                    guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
                    if isCapabilityAnnouncement {
                        wireDiagnostics.capabilityAnnouncementFailures &+= 1
                    }
                    recordClipboardFailure(.encodeFailure)
                    emit(.failed(.invalidAgentMessage(String(describing: error))))
                    return
                }
            case let .writeGuestText(text):
                do {
                    let snapshot = try await SpicePasteboardBridge.write(text: text)
                    guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
                    state.didWriteGuestText(changeCount: snapshot.changeCount)
                } catch {
                    guard isAgentGenerationCurrent(expectedConnectionGeneration) else { return }
                    pendingActions = Array(work[index...])
                    recordClipboardFailure(.pasteboardWrite)
                    emit(.failed(error))
                    return
                }
            case let .emit(event):
                emit(event)
            }
        }
    }

    private func recordInboundMessage(_ message: SpiceAgentMessage) {
        wireDiagnostics.inboundMessages &+= 1
        wireDiagnostics.lastInboundProtocolID = message.protocolID
        wireDiagnostics.lastInboundMessageType = message.type
        if message.protocolID == VDAgentMessage.protocolVersion {
            wireDiagnostics.inboundCurrentProtocolMessages &+= 1
        } else {
            wireDiagnostics.inboundUnexpectedProtocolMessages &+= 1
        }

        switch VDAgentMessageType(rawValue: message.type) {
        case .announceCapabilities:
            wireDiagnostics.inboundCapabilityAnnouncements &+= 1
        case .clipboard:
            wireDiagnostics.inboundClipboardMessages &+= 1
            wireDiagnostics.inboundClipboardDataMessages &+= 1
        case .clipboardGrab:
            wireDiagnostics.inboundClipboardMessages &+= 1
            wireDiagnostics.inboundClipboardGrabMessages &+= 1
        case .clipboardRequest:
            wireDiagnostics.inboundClipboardMessages &+= 1
            wireDiagnostics.inboundClipboardRequestMessages &+= 1
        case .clipboardRelease:
            wireDiagnostics.inboundClipboardMessages &+= 1
            wireDiagnostics.inboundClipboardReleaseMessages &+= 1
        case .reply:
            wireDiagnostics.inboundMonitorReplies &+= 1
        case .fileTransferStart, .fileTransferStatus, .fileTransferData:
            wireDiagnostics.inboundFileTransferMessages &+= 1
        case .monitorsConfig, .none:
            wireDiagnostics.inboundOtherMessages &+= 1
        }
    }

    private func recordPeerClipboardCapabilities(_ command: VDAgentClipboardCommand) {
        guard case let .announceCapabilities(_, capabilities) = command else { return }
        wireDiagnostics.peerLegacyClipboardCapability = capabilities.contains(.clipboard)
        wireDiagnostics.peerClipboardByDemandCapability = capabilities.contains(
            .clipboardByDemand
        )
    }

    private func recordClipboardFailure(_ category: SpiceClipboardFailureCategory) {
        wireDiagnostics.clipboardFailures &+= 1
        wireDiagnostics.lastClipboardFailureCategory = category
    }

    private func emitActions(_ actions: [ClipboardStateMachine.Action]) {
        for action in actions {
            if case let .emit(event) = action {
                emit(event)
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
