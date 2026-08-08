import Foundation
import SpiceProtocol
import SpiceWire
import Synchronization

/// Content-free counters for the VDAgent wire path owned by one manager.
///
/// Values are cumulative for the lifetime of the manager. Message payloads,
/// clipboard text, file names, and error strings are never retained.
public struct SpiceAgentWireDiagnostics: Sendable, Equatable {
    public internal(set) var capabilityAnnouncementsAttempted: UInt64 = 0
    public internal(set) var capabilityAnnouncementsSent: UInt64 = 0
    public internal(set) var capabilityAnnouncementFailures: UInt64 = 0
    public internal(set) var inboundMessages: UInt64 = 0
    public internal(set) var inboundCurrentProtocolMessages: UInt64 = 0
    public internal(set) var inboundUnexpectedProtocolMessages: UInt64 = 0
    public internal(set) var inboundCapabilityAnnouncements: UInt64 = 0
    public internal(set) var inboundClipboardMessages: UInt64 = 0
    public internal(set) var inboundMonitorReplies: UInt64 = 0
    public internal(set) var inboundFileTransferMessages: UInt64 = 0
    public internal(set) var inboundOtherMessages: UInt64 = 0
    public internal(set) var inboundDecodeFailures: UInt64 = 0
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
        eventContinuation.finish()
        displayConfigurationContinuation.finish()
        displayConfigurationSupportContinuation.finish()
        fileTransferContinuation.finish()
    }

    public func start(session: SpiceSession) async throws(SpiceClipboardError) {
        guard eventTask == nil else {
            throw .alreadyRunning
        }
        self.session = session
        if await session.currentAgentConnectionState() {
            await execute(state.connected(), using: session)
        }
        emitDisplayConfigurationSupportIfChanged()
        eventTask = Task { [weak self] in
            for await event in session.agentEvents {
                guard !Task.isCancelled else {
                    return
                }
                await self?.receive(event, from: session)
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

    public func stop() {
        eventTask?.cancel()
        eventTask = nil
        pollTask?.cancel()
        pollTask = nil
        session = nil
        pendingActions.removeAll(keepingCapacity: false)
        displayCoordinator.reset()
        cancelAllFileTransfers()
        emitActions(state.disconnected())
        emitDisplayConfigurationSupportIfChanged()
    }

    /// Returns content-free aggregate observations of the Agent wire path.
    public func diagnosticsSnapshot() -> SpiceAgentWireDiagnostics {
        wireDiagnostics
    }

    /// Checks the current pasteboard immediately rather than waiting for the
    /// optional polling loop.
    public func synchronizePasteboard() async {
        guard pasteboardSynchronizationEnabled, let session else {
            return
        }
        await execute(state.announcementIfNeeded(), using: session)
        let snapshot = await SpicePasteboardBridge.snapshot()
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
        let snapshot: SpicePasteboardSnapshot
        do {
            snapshot = try await SpicePasteboardBridge.write(text: text)
        } catch {
            emit(.failed(error))
            return
        }
        guard let session else {
            return
        }
        await execute(state.localPasteboardChanged(
            changeCount: snapshot.changeCount,
            text: snapshot.text
        ), using: session)
    }

    /// Changes whether this manager may advertise clipboard support or access
    /// the general pasteboard. Other Agent services remain active either way.
    public func setPasteboardSynchronizationEnabled(_ enabled: Bool) async {
        guard pasteboardSynchronizationEnabled != enabled else { return }
        pasteboardSynchronizationEnabled = enabled
        guard let session else {
            _ = state.setClipboardEnabled(enabled)
            return
        }
        await execute(state.setClipboardEnabled(enabled), using: session)
        if enabled {
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
        guard let session else {
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
        guard self.session != nil, state.isAgentConnected else {
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
        if let session {
            await driveFileTransfers(using: session)
        }
    }

    private func receive(_ event: SpiceAgentEvent, from session: SpiceSession) async {
        switch event {
        case .connected:
            guard !state.isAgentConnected else {
                return
            }
            pendingActions.removeAll(keepingCapacity: false)
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
            pendingActions.removeAll(keepingCapacity: false)
            displayCoordinator.disconnected()
            failAllFileTransfers(with: .agentUnavailable)
            emitActions(state.disconnected())
            emitDisplayConfigurationSupportIfChanged()
        case let .message(message):
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
                let command: VDAgentClipboardCommand?
                do {
                    command = try VDAgentClipboardCodec.decode(wireMessage)
                } catch {
                    wireDiagnostics.inboundDecodeFailures &+= 1
                    throw error
                }
                guard let command else {
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
            try await session.sendAgentMessage(SpiceAgentMessage(
                protocolID: message.protocolID,
                type: message.type,
                opaque: message.opaque,
                data: message.data
            ))
            displayCoordinator.didSend(configuration)
            emitDisplay(.sent(configuration))
        } catch let error as SpiceError {
            emitDisplay(.failed(configuration, .transport(error)))
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

    private func performPeriodicWork() async {
        if automaticallySynchronizesPasteboard, pasteboardSynchronizationEnabled {
            await synchronizePasteboard()
        } else {
            await retryPendingAgentWork()
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
                await driveFileTransfers(using: session)
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

    private func driveFileTransfers(using session: SpiceSession) async {
        guard pendingActions.isEmpty, state.isAgentConnected else {
            return
        }
        while true {
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
                    guard await sendFileTransferMessage(message, using: session) else {
                        return
                    }
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
                    guard await sendFileTransferMessage(message, using: session) else {
                        return
                    }
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
                    guard await sendFileTransferMessage(message, using: session) else {
                        return
                    }
                    job.phase = .awaitingCancellation
                    fileTransfers[id] = job
                    progressed = true
                case let .queuedFailure(error):
                    let message = fileTransferCodec.encodeStatus(
                        id: id.rawValue,
                        result: .error
                    )
                    guard await sendFileTransferMessage(message, using: session) else {
                        return
                    }
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
        using session: SpiceSession
    ) async -> Bool {
        do {
            return try await session.sendAgentMessageIfTokensAvailable(SpiceAgentMessage(
                protocolID: message.protocolID,
                type: message.type,
                opaque: message.opaque,
                data: message.data
            ))
        } catch let error {
            failAllFileTransfers(with: .transport(error))
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
        using session: SpiceSession
    ) async {
        var work = pendingActions
        pendingActions.removeAll(keepingCapacity: true)
        for action in actions where !work.contains(action) {
            work.append(action)
        }

        for (index, action) in work.enumerated() {
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
                    try await session.sendAgentMessage(SpiceAgentMessage(
                        protocolID: message.protocolID,
                        type: message.type,
                        opaque: message.opaque,
                        data: message.data
                    ))
                    state.didSend(command)
                    if isCapabilityAnnouncement {
                        wireDiagnostics.capabilityAnnouncementsSent &+= 1
                    }
                } catch let error as SpiceError {
                    if isCapabilityAnnouncement {
                        wireDiagnostics.capabilityAnnouncementFailures &+= 1
                    }
                    pendingActions = Array(work[index...])
                    emit(.failed(.transport(error)))
                    return
                } catch {
                    if isCapabilityAnnouncement {
                        wireDiagnostics.capabilityAnnouncementFailures &+= 1
                    }
                    emit(.failed(.invalidAgentMessage(String(describing: error))))
                    return
                }
            case let .writeGuestText(text):
                do {
                    let snapshot = try await SpicePasteboardBridge.write(text: text)
                    state.didWriteGuestText(changeCount: snapshot.changeCount)
                } catch {
                    pendingActions = Array(work[index...])
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
        case .clipboard, .clipboardGrab, .clipboardRequest, .clipboardRelease:
            wireDiagnostics.inboundClipboardMessages &+= 1
        case .reply:
            wireDiagnostics.inboundMonitorReplies &+= 1
        case .fileTransferStart, .fileTransferStatus, .fileTransferData:
            wireDiagnostics.inboundFileTransferMessages &+= 1
        case .monitorsConfig, .none:
            wireDiagnostics.inboundOtherMessages &+= 1
        }
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
