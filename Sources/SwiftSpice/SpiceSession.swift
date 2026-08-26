import Foundation
import SpiceChannels
import SpiceCodecs
import SpiceCore
import SpiceCryptoSecurity
import SpiceIOSurface
import SpiceProtocol
import SpiceRenderer
import SpiceTransport
import SpiceTransportNetwork
import Synchronization

public struct SpiceEndpoint: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var tlsPolicy: TLSTrustPolicy?
    public var videoCodecPolicy: SpiceVideoCodecPolicy

    public init(
        host: String,
        port: UInt16,
        tlsPolicy: TLSTrustPolicy? = nil,
        videoCodecPolicy: SpiceVideoCodecPolicy = .mjpegOnly
    ) {
        self.host = host
        self.port = port
        self.tlsPolicy = tlsPolicy
        self.videoCodecPolicy = videoCodecPolicy
    }
}

/// Controls codecs advertised to the SPICE Display peer. H.264 is opt-in
/// because some host encoders emit 4:4:4 profiles unsupported by VideoToolbox.
public enum SpiceVideoCodecPolicy: Sendable, Equatable {
    case mjpegOnly
    case h264AndMJPEG
    case h265AndMJPEG
}

public enum SpiceVideoCodec: Sendable, Equatable {
    case h264
    case h265
}

public enum SpiceVideoCodecFailureReason: Sendable, Equatable {
    case hardwareUnavailable(status: Int32?)
    case unsupportedFormat(status: Int32)
}

public struct SpiceVideoCodecFailure: Sendable, Equatable {
    public let codec: SpiceVideoCodec
    public let reason: SpiceVideoCodecFailureReason

    public init(codec: SpiceVideoCodec, reason: SpiceVideoCodecFailureReason) {
        self.codec = codec
        self.reason = reason
    }
}

public enum TLSTrustPolicy: Sendable, Equatable {
    case system
    /// Trust only the supplied CA certificates. Values may be DER or PEM data;
    /// escaped PEM from a virt-viewer `ca=` field is accepted directly.
    /// `serverName` overrides hostname verification when the connection address
    /// differs from the name in the server certificate.
    case customCertificateAuthority(certificates: [Data], serverName: String? = nil)
    /// Trust only the supplied CA certificates and require the complete leaf
    /// subject to match a virt-viewer `host-subject` value. Use this explicit
    /// compatibility policy for legacy SPICE certificates without SAN or a
    /// Server Authentication EKU; modern hostname validation remains available
    /// through `customCertificateAuthority`.
    case virtViewerCertificateAuthority(certificates: [Data], expectedSubject: String)
    case insecureForTestingOnly
}

public struct SpiceCredentials: ~Copyable, Sendable {
    private let storage: SpiceCredentialStorage

    public init(password: String = "") {
        storage = SpiceCredentialStorage(password: Data(password.utf8))
    }

    consuming package func transferStorage() -> SpiceCredentialStorage {
        storage
    }
}

package final class SpiceCredentialStorage: Sendable {
    private let passwordBytes: Mutex<Data>

    fileprivate init(password: consuming Data) {
        passwordBytes = Mutex(password)
    }

    package func copyPassword() -> Data {
        passwordBytes.withLock { value in
            var copy = Data(capacity: value.count)
            copy.append(contentsOf: value)
            return copy
        }
    }

    deinit {
        passwordBytes.withLock { value in
            value.resetBytes(in: value.indices)
        }
    }
}

public struct SpiceChannelDescriptor: Sendable, Hashable {
    public let type: UInt8
    public let id: UInt8
}

public struct SpiceSessionInfo: Sendable, Equatable {
    public let sessionID: UInt32
    public let supportedMouseModes: UInt32
    public let currentMouseMode: UInt32
    public let agentConnected: Bool
    public let channels: [SpiceChannelDescriptor]
}

public enum SpiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case alreadyConnected
    case connectionFailed(String)
    case authenticationFailed(String)
    case protocolError(String)
    case videoCodecUnavailable(SpiceVideoCodecFailure)
    case cancelled

    public var description: String {
        switch self {
        case .alreadyConnected:
            "session is already connected"
        case let .connectionFailed(reason):
            "connection failed: \(reason)"
        case let .authenticationFailed(reason):
            "authentication failed: \(reason)"
        case let .protocolError(reason):
            "protocol error: \(reason)"
        case let .videoCodecUnavailable(failure):
            "video codec unavailable: \(failure.codec) (\(failure.reason))"
        case .cancelled:
            "connection cancelled"
        }
    }
}

public actor SpiceSession {
    package typealias TransportFactory = @Sendable (SpiceEndpoint) -> any SpiceTransport

    private let transportFactory: TransportFactory
    private let ticketEncryptor: any TicketEncrypting
    private let injectedMigrationExecutor: (any SpiceMigrationHandoffExecuting)?
    private let displayImageCacheFactory: @Sendable () -> DisplayImageCache
    private let surfaceMemoryBudget = SurfaceMemoryBudget()
    private let mjpegDecodeLimiter = SpiceMJPEGDecodeLimiter(maximumConcurrent: 2)
    package nonisolated let presentationDiagnostics: SpicePresentationDiagnostics
    public nonisolated let desktop: SpiceDesktopSource
    public nonisolated let events: AsyncStream<SpiceSessionEvent>
    private let eventMailbox: SpiceSessionEventMailbox
    public nonisolated let playbackEvents: AsyncStream<SpicePlaybackEvent>
    private let playbackEventContinuation: AsyncStream<SpicePlaybackEvent>.Continuation
    public nonisolated let recordEvents: AsyncStream<SpiceRecordEvent>
    private let recordEventContinuation: AsyncStream<SpiceRecordEvent>.Continuation
    /// Returns an Agent event stream backed by the session's single-consumer
    /// mailbox. Access the property again when replacing a cancelled consumer.
    public nonisolated var agentEvents: AsyncStream<SpiceAgentEvent> {
        AsyncStream(unfolding: { await self.agentEventMailbox.next()?.event })
    }
    package nonisolated var agentEventEnvelopes: AsyncStream<SpiceAgentEventEnvelope> {
        AsyncStream(unfolding: { await self.agentEventMailbox.next() })
    }
    private nonisolated let agentEventMailbox: SpiceAgentEventMailbox
    public nonisolated let smartcardEvents: AsyncStream<SpiceSmartcardEvent>
    private let smartcardEventContinuation: AsyncStream<SpiceSmartcardEvent>.Continuation
    public nonisolated let usbRedirectionPackets: AsyncStream<SpiceUSBRedirectionPacket>
    private let usbRedirectionContinuation:
        AsyncStream<SpiceUSBRedirectionPacket>.Continuation
    public nonisolated let webDAVEvents: AsyncStream<SpiceWebDAVEvent>
    private let webDAVEventContinuation: AsyncStream<SpiceWebDAVEvent>.Continuation
    private var mainChannel: MainChannel?
    private var displayImageCache: DisplayImageCache?
    private var channels: [ChannelKey: any SpiceManagedChannel] = [:]
    private var connections: [ChannelKey: ChannelConnection] = [:]
    private var retiredDisplayDiagnostics = SpiceSessionDiagnostics()
    private var receiveTasks: [Task<Void, Never>] = []
    private var supervisionGeneration: UInt64 = 0
    private var credentialStorage: SpiceCredentialStorage?
    private var currentEndpoint: SpiceEndpoint?
    private var currentBootstrap: MainBootstrap?
    private var isConnecting = false
    private var isDisconnecting = false
    private var nextConnectionLifecycleID: UInt64 = 0
    private var currentConnectionLifecycleID: UInt64?
    private var connectionAttemptTask: Task<SpiceSessionInfo, any Error>?
    private var nextConnectionLifecycleWaiterToken: UInt64 = 0
    private var connectionLifecycleWaiters: [UInt64: ConnectionLifecycleWaiter] = [:]
    private var disconnectProcessingHook: (@Sendable () async -> Void)?
    private var isAgentConnected = false
    private var agentDisconnectRevision: UInt64 = 0
    private var agentConnectionGeneration: UInt64 = 0
    private var usbRedirectionHosts: [UInt8: SpiceUSBRedirectionHost] = [:]
    private var usbRedirectionPumpTasks: [UInt8: Task<Void, Never>] = [:]
    private var webDAVServers: [UInt8: SpiceWebDAVServer] = [:]
    private var migrationCoordinator = MigrationHandoffCoordinator()
    private var migrationTask: Task<Void, Never>?
    private var nextRetiringMainDrainID: UInt64 = 0
    private var retiringMainDrain: RetiringMainDrain?
    private var preparedMigrations: [UInt64: PreparedSession] = [:]
    private struct ChannelMigrationPayload: Sendable {
        let data: Data?
    }
    private var seamlessMigrationPayloads:
        [UInt64: [ChannelKey: ChannelMigrationPayload]] = [:]

    private struct ConnectionLifecycleWaiter {
        let lifecycleID: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct PreparedSession: Sendable {
        let endpoint: SpiceEndpoint
        let mainChannel: MainChannel
        let imageCache: DisplayImageCache
        let channels: [ChannelKey: any SpiceManagedChannel]
        let connections: [ChannelKey: ChannelConnection]
        let bootstrap: MainBootstrap

        var info: SpiceSessionInfo {
            SpiceSessionInfo(
                sessionID: bootstrap.sessionID,
                supportedMouseModes: bootstrap.supportedMouseModes,
                currentMouseMode: bootstrap.currentMouseMode,
                agentConnected: bootstrap.agentConnected,
                channels: bootstrap.channels.map {
                    SpiceChannelDescriptor(type: $0.type, id: $0.id)
                }
            )
        }
    }

    private struct RetiringMainDrain: Sendable {
        let id: UInt64
        let connection: ChannelConnection
        let task: Task<Result<Void, ChannelError>, Never>
    }

    public init() {
        let presentationDiagnostics = SpicePresentationDiagnostics()
        self.presentationDiagnostics = presentationDiagnostics
        desktop = SpiceDesktopSource(presentationDiagnostics: presentationDiagnostics)
        let eventMailbox = SpiceSessionEventMailbox()
        self.eventMailbox = eventMailbox
        events = AsyncStream(unfolding: { await eventMailbox.next() })
        let playbackPipe = AsyncStream.makeStream(
            of: SpicePlaybackEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        playbackEvents = playbackPipe.stream
        playbackEventContinuation = playbackPipe.continuation
        let recordPipe = AsyncStream.makeStream(
            of: SpiceRecordEvent.self,
            bufferingPolicy: .bufferingOldest(32)
        )
        recordEvents = recordPipe.stream
        recordEventContinuation = recordPipe.continuation
        let agentEventMailbox = SpiceAgentEventMailbox()
        self.agentEventMailbox = agentEventMailbox
        let smartcardPipe = AsyncStream.makeStream(
            of: SpiceSmartcardEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        smartcardEvents = smartcardPipe.stream
        smartcardEventContinuation = smartcardPipe.continuation
        let usbRedirectionPipe = AsyncStream.makeStream(
            of: SpiceUSBRedirectionPacket.self,
            bufferingPolicy: .bufferingOldest(16)
        )
        usbRedirectionPackets = usbRedirectionPipe.stream
        usbRedirectionContinuation = usbRedirectionPipe.continuation
        let webDAVPipe = AsyncStream.makeStream(
            of: SpiceWebDAVEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        webDAVEvents = webDAVPipe.stream
        webDAVEventContinuation = webDAVPipe.continuation
        transportFactory = Self.makeNetworkTransport
        ticketEncryptor = SecurityTicketEncryptor()
        injectedMigrationExecutor = nil
        displayImageCacheFactory = { DisplayImageCache() }
    }

    package init(
        transportFactory: @escaping TransportFactory,
        ticketEncryptor: any TicketEncrypting,
        migrationExecutor: (any SpiceMigrationHandoffExecuting)? = nil,
        imageCacheFactory: @escaping @Sendable () -> DisplayImageCache = {
            DisplayImageCache()
        }
    ) {
        let presentationDiagnostics = SpicePresentationDiagnostics()
        self.presentationDiagnostics = presentationDiagnostics
        desktop = SpiceDesktopSource(presentationDiagnostics: presentationDiagnostics)
        let eventMailbox = SpiceSessionEventMailbox()
        self.eventMailbox = eventMailbox
        events = AsyncStream(unfolding: { await eventMailbox.next() })
        let playbackPipe = AsyncStream.makeStream(
            of: SpicePlaybackEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        playbackEvents = playbackPipe.stream
        playbackEventContinuation = playbackPipe.continuation
        let recordPipe = AsyncStream.makeStream(
            of: SpiceRecordEvent.self,
            bufferingPolicy: .bufferingOldest(32)
        )
        recordEvents = recordPipe.stream
        recordEventContinuation = recordPipe.continuation
        let agentEventMailbox = SpiceAgentEventMailbox()
        self.agentEventMailbox = agentEventMailbox
        let smartcardPipe = AsyncStream.makeStream(
            of: SpiceSmartcardEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        smartcardEvents = smartcardPipe.stream
        smartcardEventContinuation = smartcardPipe.continuation
        let usbRedirectionPipe = AsyncStream.makeStream(
            of: SpiceUSBRedirectionPacket.self,
            bufferingPolicy: .bufferingOldest(16)
        )
        usbRedirectionPackets = usbRedirectionPipe.stream
        usbRedirectionContinuation = usbRedirectionPipe.continuation
        let webDAVPipe = AsyncStream.makeStream(
            of: SpiceWebDAVEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        webDAVEvents = webDAVPipe.stream
        webDAVEventContinuation = webDAVPipe.continuation
        self.transportFactory = transportFactory
        self.ticketEncryptor = ticketEncryptor
        injectedMigrationExecutor = migrationExecutor
        displayImageCacheFactory = imageCacheFactory
    }

    deinit {
        eventMailbox.finish()
        agentEventMailbox.finish()
        connectionAttemptTask?.cancel()
        for waiter in connectionLifecycleWaiters.values {
            waiter.continuation.resume()
        }
    }

    public func connect(
        endpoint: SpiceEndpoint,
        credentials: consuming SpiceCredentials
    ) async throws(SpiceError) -> SpiceSessionInfo {
        guard mainChannel == nil, !isConnecting, !isDisconnecting else {
            throw .alreadyConnected
        }
        retiredDisplayDiagnostics = SpiceSessionDiagnostics()
        presentationDiagnostics.reset()
        nextConnectionLifecycleID &+= 1
        let lifecycleID = nextConnectionLifecycleID
        currentConnectionLifecycleID = lifecycleID
        isConnecting = true
        let credentialStorage = credentials.transferStorage()
        let attempt = Task { [self] () throws -> SpiceSessionInfo in
            do {
                let prepared = try await prepareConnection(
                    endpoint: endpoint,
                    credentials: credentialStorage
                )
                guard !Task.isCancelled,
                      currentConnectionLifecycleID == lifecycleID,
                      !isDisconnecting else {
                    await Self.closePrepared(prepared)
                    throw SpiceError.cancelled
                }
                adopt(prepared, credentials: credentialStorage)
                connectionAttemptFinished(lifecycleID: lifecycleID, connected: true)
                return prepared.info
            } catch is CancellationError {
                connectionAttemptFinished(lifecycleID: lifecycleID, connected: false)
                throw SpiceError.cancelled
            } catch {
                connectionAttemptFinished(lifecycleID: lifecycleID, connected: false)
                throw error
            }
        }
        connectionAttemptTask = attempt

        let result = await withTaskCancellationHandler {
            await attempt.result
        } onCancel: {
            attempt.cancel()
        }
        switch result {
        case let .success(info):
            return info
        case let .failure(error as SpiceError):
            throw error
        case .failure(is CancellationError):
            throw .cancelled
        case let .failure(error):
            throw .protocolError(String(describing: error))
        }
    }

    private func prepareConnection(
        endpoint: SpiceEndpoint,
        credentials: SpiceCredentialStorage
    ) async throws(SpiceError) -> PreparedSession {
        let transport = transportFactory(endpoint)
        let imageCache = displayImageCacheFactory()
        var preparedMain: MainChannel?
        var preparedChannels: [ChannelKey: any SpiceManagedChannel] = [:]
        var preparedConnections: [ChannelKey: ChannelConnection] = [:]
        do {
            try await transport.connect()
            let serialBarrier = ChannelSerialBarrier()
            let glzDecoder = SpiceGLZDecoder()
            let multimediaClock = MultimediaClock()
            let handshake = try await LinkHandshake().perform(
                transport: transport,
                request: .main(),
                password: credentials.copyPassword(),
                ticketEncryptor: ticketEncryptor
            )
            let connection = ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: handshake.headerMode,
                serialBarrier: serialBarrier
            )
            let main = MainChannel(connection: connection, multimediaClock: multimediaClock)
            preparedMain = main
            preparedConnections[connection.key] = connection
            let bootstrap = try await main.bootstrap()
            let transportFactory = self.transportFactory
            let channelFactory = ChannelFactory(
                transportFactory: { _ in transportFactory(endpoint) },
                ticketEncryptor: ticketEncryptor,
                serialBarrier: serialBarrier,
                advertisesH264: endpoint.videoCodecPolicy == .h264AndMJPEG,
                advertisesH265: endpoint.videoCodecPolicy == .h265AndMJPEG
            )
            for descriptor in bootstrap.channels {
                try Task.checkCancellation()
                let key = ChannelKey(type: descriptor.type, id: descriptor.id)
                guard key != connection.key else { continue }
                guard preparedChannels[key] == nil else {
                    throw ChannelError.protocolViolation(
                        "duplicate channel type=\(key.type) id=\(key.id)"
                    )
                }
                let connected = try await channelFactory.connect(
                    key: key,
                    connectionID: bootstrap.sessionID,
                    password: credentials.copyPassword()
                )
                preparedConnections[key] = connected
                preparedChannels[key] = Self.makeChannel(
                    key: key,
                    connection: connected,
                    glzDecoder: glzDecoder,
                    imageCache: imageCache,
                    multimediaClock: multimediaClock,
                    surfaceMemoryBudget: surfaceMemoryBudget,
                    frameDemandCoordinator: desktop.frameDemandCoordinator,
                    mjpegDecodeLimiter: mjpegDecodeLimiter
                )
            }
            try Task.checkCancellation()
            return PreparedSession(
                endpoint: endpoint,
                mainChannel: main,
                imageCache: imageCache,
                channels: preparedChannels,
                connections: preparedConnections,
                bootstrap: bootstrap
            )
        } catch is CancellationError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw .cancelled
        } catch let error as ChannelError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw Self.map(channelError: error)
        } catch let error as TransportError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw Self.map(transportError: error)
        } catch let error as SpiceError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw error
        } catch {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw .protocolError(String(describing: error))
        }
    }

    private func adopt(
        _ prepared: PreparedSession,
        credentials: SpiceCredentialStorage
    ) {
        agentConnectionGeneration &+= 1
        mainChannel = prepared.mainChannel
        displayImageCache = prepared.imageCache
        channels = prepared.channels
        connections = prepared.connections
        currentEndpoint = prepared.endpoint
        currentBootstrap = prepared.bootstrap
        credentialStorage = credentials
        isAgentConnected = prepared.bootstrap.agentConnected
        desktop.beginSession(
            pointerMode: SpicePointerMode(spiceMouseMode: prepared.bootstrap.currentMouseMode)
        )
        startSupervision(mainChannel: prepared.mainChannel)
        if prepared.bootstrap.agentConnected {
            sendAgentLifecycle(.connected)
        }
    }

    public func disconnect() async {
        if isDisconnecting {
            if let lifecycleID = currentConnectionLifecycleID {
                await waitUntilConnectionInactiveForReconnect(
                    observedLifecycleID: lifecycleID
                )
            }
            return
        }
        if currentConnectionLifecycleID == nil {
            nextConnectionLifecycleID &+= 1
            currentConnectionLifecycleID = nextConnectionLifecycleID
        }
        let lifecycleID = currentConnectionLifecycleID
        isDisconnecting = true
        supervisionGeneration &+= 1
        agentConnectionGeneration &+= 1
        let attempt = connectionAttemptTask
        attempt?.cancel()
        if let attempt {
            _ = await attempt.result
        }
        if let disconnectProcessingHook {
            await disconnectProcessingHook()
        }
        await cancelMigrationHandoff()
        await cancelAndCloseRetiringMainDrain()
        await stopUSBRedirectionHosts()
        await stopWebDAVServers()
        let tasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in tasks {
            task.cancel()
        }
        let wasAgentConnected = isAgentConnected
        let hadPlaybackChannel = channels[ChannelKey(type: 5, id: 0)] != nil
        let connectedMainChannel = mainChannel
        let connectedImageCache = displayImageCache
        self.mainChannel = nil
        displayImageCache = nil
        isAgentConnected = false
        await connectedImageCache?.close()
        if let connectedMainChannel {
            await connectedMainChannel.close()
        }
        await closeChannels()
        connections.removeAll(keepingCapacity: false)
        credentialStorage = nil
        currentEndpoint = nil
        currentBootstrap = nil
        desktop.endSession()
        emitChannelLifecycleEnded(
            wasAgentConnected: wasAgentConnected,
            hadPlaybackChannel: hadPlaybackChannel
        )
        eventMailbox.send(.disconnected)
        finishConnectionLifecycle(lifecycleID)
    }

    package func currentAgentConnectionState() -> Bool {
        isAgentConnected
    }

    package func displayImageCacheDiagnosticsSnapshot() async -> DisplayImageCacheDiagnostics? {
        guard let displayImageCache else { return nil }
        return await displayImageCache.diagnosticsSnapshot()
    }

    package func currentAgentConnectionSnapshot() -> (
        isConnected: Bool,
        generation: UInt64,
        sessionLifecycleID: UInt64?
    ) {
        (
            isAgentConnected,
            agentConnectionGeneration,
            currentConnectionLifecycleID
        )
    }

    /// Waits until the exact connection lifecycle observed by the caller is
    /// inactive. A completed disconnect followed by a new connection has a
    /// different ID and therefore cannot be mistaken for the old lifecycle.
    package func waitUntilConnectionInactiveForReconnect(
        observedLifecycleID: UInt64
    ) async {
        guard currentConnectionLifecycleID == observedLifecycleID else { return }
        let token = nextConnectionLifecycleWaiterToken
        nextConnectionLifecycleWaiterToken &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled,
                      currentConnectionLifecycleID == observedLifecycleID else {
                    continuation.resume()
                    return
                }
                connectionLifecycleWaiters[token] = ConnectionLifecycleWaiter(
                    lifecycleID: observedLifecycleID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { await self.cancelConnectionLifecycleWaiter(token) }
        }
    }

    package func setDisconnectProcessingHookForTesting(
        _ hook: (@Sendable () async -> Void)?
    ) {
        disconnectProcessingHook = hook
    }

    package func isChannelMigrationFlushing() -> Bool {
        !seamlessMigrationPayloads.isEmpty
    }

    /// Returns a best-effort aggregate snapshot of the display pipeline.
    ///
    /// Cumulative counters start at the most recent `connect` attempt. The
    /// snapshot has no timing before a complete framed message returns from the
    /// transport and does not retain per-frame timestamps. It includes bounded
    /// receive-to-surface-apply, publisher, and GPU-presentation timing
    /// summaries. `SpiceDesktopView` receives the presentation recorder through
    /// this session's stable desktop source; callers do not forward it through
    /// SwiftUI. Advanced-video counters do not cover MJPEG.
    public func diagnosticsSnapshot() async -> SpiceSessionDiagnostics {
        var result = retiredDisplayDiagnostics

        let orderedKeys = channels.keys.sorted {
            ($0.type, $0.id) < ($1.type, $1.id)
        }
        for key in orderedKeys {
            guard let channel = channels[key] else { continue }
            guard let display = channel as? DisplayChannel else { continue }
            result.accumulate(await display.diagnosticsSnapshot())
        }

        let desktopMetrics = desktop.metrics()
        result.desktopDeliveredSnapshots = desktopMetrics.deliveredSnapshots
        result.desktopStreamCoalesces = desktopMetrics.streamCoalesces
        result.desktopHandlerDeliveries = desktopMetrics.handlerDeliveries
        result.desktopSubscriptions = desktopMetrics.subscriptions
        result.desktopVisibleSubscriptions = desktopMetrics.visibleSubscriptions

        result.totalIOSurfaceAllocatedBytes = IOSurfaceAllocationBudget.shared.allocatedBytes
        let surfaceBudget = surfaceMemoryBudget.metrics()
        result.surfaceAllocatedBytes = surfaceBudget.allocatedBytes
        result.maximumSurfaceBytes = surfaceBudget.maximumBytes
        let presentation = presentationDiagnostics.snapshot()
        result.metalPresentedFrames = presentation.metalPresentedFrames
        result.advancedVideoPresentedFrames = presentation.advancedVideoPresentedFrames
        result.metalPresentationErrors = presentation.metalPresentationErrors
        result.cpuFallbackFrames = presentation.cpuFallbackFrames
        result.metalUnavailableFallbackFrames = presentation.metalUnavailableFallbackFrames
        result.missingIOSurfaceFallbackFrames = presentation.missingIOSurfaceFallbackFrames
        result.ioSurfaceDimensionMismatchFallbackFrames =
            presentation.ioSurfaceDimensionMismatchFallbackFrames
        result.pixelFormatMismatchFallbackFrames = presentation.pixelFormatMismatchFallbackFrames
        result.textureCreationFailedFallbackFrames =
            presentation.textureCreationFailedFallbackFrames
        result.metalCommandFailureFallbackFrames =
            presentation.metalCommandFailureFallbackFrames
        result.lastCPUFallbackReason = presentation.lastCPUFallbackReason
        result.metalFramesSupersededBeforeDraw = presentation.metalFramesSupersededBeforeDraw
        result.metalDrawableMisses = presentation.metalDrawableMisses
        result.metalCommandCreationFailures = presentation.metalCommandCreationFailures
        result.metalCommandBuffersCommitted = presentation.metalCommandBuffersCommitted
        result.metalTextureCacheHits = presentation.metalTextureCacheHits
        result.metalTextureCacheMisses = presentation.metalTextureCacheMisses
        result.metalTextureCacheEvictions = presentation.metalTextureCacheEvictions
        result.metalGPUBusySkips = presentation.metalGPUBusySkips
        result.desktopDisplayLinkWakeups = presentation.desktopDisplayLinkWakeups
        result.desktopDisplayLinkTicks = presentation.desktopDisplayLinkTicks
        result.desktopDisplayLinkIdlePauses = presentation.desktopDisplayLinkIdlePauses
        result.desktopImmediateSelections = presentation.desktopImmediateSelections
        result.desktopReadyToDisplayLinkHistogram =
            presentation.desktopReadyToDisplayLinkHistogram
        result.viewUpdateToMetalCommitHistogram =
            presentation.viewUpdateToMetalCommitHistogram
        result.metalCommitToCompletionHistogram =
            presentation.metalCommitToCompletionHistogram
        result.metalRequestToPresentedHistogram =
            presentation.metalRequestToPresentedHistogram
        return result
    }

    public func send(_ input: SpiceClientInput) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let key = ChannelKey(type: 3, id: 0)
        guard let inputs = channels[key] as? InputsChannel else {
            throw .protocolError("Inputs Channel is not connected")
        }
        do {
            try await inputs.send(Self.channelInput(input))
        } catch {
            throw Self.map(channelError: error)
        }
    }

    /// Reports the host audio sink's current queued playback delay. This is
    /// distinct from the server's minimum-latency hint.
    public func reportPlaybackDelay(milliseconds: UInt32) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let key = ChannelKey(type: 5, id: 0)
        guard let playback = channels[key] as? PlaybackChannel else {
            throw .protocolError("Playback Channel is not connected")
        }
        do {
            try await playback.reportDelay(milliseconds: milliseconds)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    package func beginRecording(timestamp: UInt32) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let key = ChannelKey(type: 6, id: 0)
        guard let record = channels[key] as? RecordChannel else {
            throw .protocolError("Record Channel is not connected")
        }
        do {
            try await record.begin(timestamp: timestamp)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    package func sendRecordedAudio(
        timestamp: UInt32,
        pcm: Data
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let key = ChannelKey(type: 6, id: 0)
        guard let record = channels[key] as? RecordChannel else {
            throw .protocolError("Record Channel is not connected")
        }
        do {
            try await record.send(timestamp: timestamp, pcm: pcm)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    /// Explicitly announces one application-authorized smartcard reader.
    /// The library never enumerates host readers or accesses cards on its own.
    public func addSmartcardReader(named name: String) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let smartcard = try smartcardChannel()
        do {
            try await smartcard.addReader(name: name)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    public func removeSmartcardReader(id: UInt32) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let smartcard = try smartcardChannel()
        do {
            try await smartcard.removeReader(id: id)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    public func insertSmartcard(readerID: UInt32, atr: Data) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let smartcard = try smartcardChannel()
        do {
            try await smartcard.insertCard(readerID: readerID, atr: atr)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    public func removeSmartcard(readerID: UInt32) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let smartcard = try smartcardChannel()
        do {
            try await smartcard.removeCard(readerID: readerID)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    public func respondToSmartcardAPDU(
        readerID: UInt32,
        data: Data
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let smartcard = try smartcardChannel()
        do {
            try await smartcard.respondToAPDU(readerID: readerID, data: data)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    public func sendSmartcardError(
        readerID: UInt32,
        code: UInt32
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let smartcard = try smartcardChannel()
        do {
            try await smartcard.sendError(readerID: readerID, code: code)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    public func completeSmartcardFlush(readerID: UInt32) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let smartcard = try smartcardChannel()
        do {
            try await smartcard.completeFlush(readerID: readerID)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    private func smartcardChannel() throws(SpiceError) -> SmartcardChannel {
        let key = ChannelKey(type: 8, id: 0)
        guard let smartcard = channels[key] as? SmartcardChannel else {
            throw .protocolError("Smartcard Channel is not connected")
        }
        return smartcard
    }

    /// Sends bytes produced by an explicitly attached usbredir backend.
    /// Device discovery, selection, and permission remain application-owned.
    public func sendUSBRedirectionPacket(
        channelID: UInt8,
        data: Data
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let key = ChannelKey(type: 9, id: channelID)
        guard let channel = channels[key] as? USBRedirectionChannel else {
            throw .protocolError("USB redirection Channel \(channelID) is not connected")
        }
        do {
            try await channel.send(data)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    /// Attaches an exact usbredir backend to one already-discovered Channel.
    /// This does not select or open a physical device.
    public func attachUSBRedirectionHost(
        _ host: SpiceUSBRedirectionHost,
        channelID: UInt8
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let key = ChannelKey(type: 9, id: channelID)
        guard channels[key] is USBRedirectionChannel else {
            throw .protocolError("USB redirection Channel \(channelID) is not connected")
        }
        guard usbRedirectionHosts[channelID] == nil else {
            throw .protocolError("USB redirection Channel \(channelID) already has a backend")
        }
        usbRedirectionHosts[channelID] = host
        do {
            try await sendUSBBackendPackets(
                await host.initialPackets(),
                channelID: channelID,
                generation: supervisionGeneration
            )
        } catch {
            usbRedirectionHosts.removeValue(forKey: channelID)
            throw error
        }
        let generation = supervisionGeneration
        usbRedirectionPumpTasks[channelID] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(10))
                    let packets = try await host.pumpEvents()
                    try await self?.sendUSBBackendPackets(
                        packets,
                        channelID: channelID,
                        generation: generation
                    )
                } catch is CancellationError {
                    return
                } catch {
                    await self?.usbRedirectionBackendFailed(
                        error,
                        channelID: channelID,
                        generation: generation
                    )
                    return
                }
            }
        }
    }

    /// Explicitly opens the user-selected libusb bus/address through the
    /// attached exact backend and enforces the guest-provided filter.
    public func attachUSBDevice(
        channelID: UInt8,
        busNumber: UInt8,
        deviceAddress: UInt8
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        guard let host = usbRedirectionHosts[channelID] else {
            throw .protocolError("USB redirection Channel \(channelID) has no backend")
        }
        do {
            let packets = try await host.attachDevice(
                busNumber: busNumber,
                deviceAddress: deviceAddress
            )
            try await sendUSBBackendPackets(
                packets,
                channelID: channelID,
                generation: supervisionGeneration
            )
        } catch let error as SpiceError {
            throw error
        } catch {
            throw .protocolError("USB redirection backend: \(String(describing: error))")
        }
    }

    public func detachUSBDevice(channelID: UInt8) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        guard let host = usbRedirectionHosts[channelID] else {
            throw .protocolError("USB redirection Channel \(channelID) has no backend")
        }
        do {
            let packets = try await host.detachDevice()
            try await sendUSBBackendPackets(
                packets,
                channelID: channelID,
                generation: supervisionGeneration
            )
        } catch let error as SpiceError {
            throw error
        } catch {
            throw .protocolError("USB redirection backend: \(String(describing: error))")
        }
    }

    /// Sends one response chunk for a WebDAV mux client. Supplying empty data
    /// closes that client. Filesystem access remains application-owned.
    public func sendWebDAVResponse(
        clientID: Int64,
        data: Data,
        channelID: UInt8 = 0
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        let key = ChannelKey(type: 11, id: channelID)
        guard let channel = channels[key] as? WebDAVChannel else {
            throw .protocolError("WebDAV Channel \(channelID) is not connected")
        }
        do {
            try await channel.send(clientID: clientID, data: data)
        } catch {
            throw Self.map(channelError: error)
        }
    }

    /// Attaches a native WebDAV endpoint rooted at a directory explicitly
    /// authorized by the application. No directory is selected implicitly.
    public func attachWebDAVServer(
        _ server: SpiceWebDAVServer,
        channelID: UInt8 = 0
    ) throws(SpiceError) {
        try ensureClientSendsAllowed()
        let key = ChannelKey(type: 11, id: channelID)
        guard channels[key] is WebDAVChannel else {
            throw .protocolError("WebDAV Channel \(channelID) is not connected")
        }
        guard webDAVServers[channelID] == nil else {
            throw .protocolError("WebDAV Channel \(channelID) already has a backend")
        }
        webDAVServers[channelID] = server
    }

    package func sendAgentMessage(_ message: SpiceAgentMessage) async throws(SpiceError) {
        try await sendAgentMessage(message, expectedConnectionGeneration: nil)
    }

    package func sendAgentMessage(
        _ message: SpiceAgentMessage,
        expectedConnectionGeneration: UInt64?
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        if let expectedConnectionGeneration,
           expectedConnectionGeneration != agentConnectionGeneration {
            throw .protocolError("stale Agent connection generation")
        }
        guard let mainChannel else {
            throw .protocolError("Main Channel is not connected")
        }
        do {
            try await mainChannel.sendAgentMessage(VDAgentMessage(
                protocolID: message.protocolID,
                type: message.type,
                opaque: message.opaque,
                data: message.data
            ))
        } catch {
            throw Self.map(channelError: error)
        }
    }

    package func sendAgentMessageIfTokensAvailable(
        _ message: SpiceAgentMessage
    ) async throws(SpiceError) -> Bool {
        try await sendAgentMessageIfTokensAvailable(
            message,
            expectedConnectionGeneration: nil
        )
    }

    package func sendAgentMessageIfTokensAvailable(
        _ message: SpiceAgentMessage,
        expectedConnectionGeneration: UInt64?
    ) async throws(SpiceError) -> Bool {
        try ensureClientSendsAllowed()
        if let expectedConnectionGeneration,
           expectedConnectionGeneration != agentConnectionGeneration {
            throw .protocolError("stale Agent connection generation")
        }
        guard let mainChannel else {
            throw .protocolError("Main Channel is not connected")
        }
        do {
            return try await mainChannel.sendAgentMessageIfTokensAvailable(VDAgentMessage(
                protocolID: message.protocolID,
                type: message.type,
                opaque: message.opaque,
                data: message.data
            ))
        } catch {
            throw Self.map(channelError: error)
        }
    }

    private func closeChannels() async {
        let openChannels = channels.keys.sorted(by: Self.channelKeySort).compactMap { channels[$0] }
        channels.removeAll(keepingCapacity: false)
        for channel in openChannels {
            await closeAndArchive(channel)
        }
    }

    private func closeAndArchive(_ channel: any SpiceManagedChannel) async {
        await channel.close()
        if let display = channel as? DisplayChannel {
            retiredDisplayDiagnostics.accumulate(await display.diagnosticsSnapshot())
        }
    }

    private func sendUSBBackendPackets(
        _ packets: [Data],
        channelID: UInt8,
        generation: UInt64
    ) async throws(SpiceError) {
        guard generation == supervisionGeneration else {
            throw .cancelled
        }
        let key = ChannelKey(type: 9, id: channelID)
        guard let channel = channels[key] as? USBRedirectionChannel else {
            throw .protocolError("USB redirection Channel \(channelID) is not connected")
        }
        do {
            for packet in packets {
                try await channel.send(packet)
            }
        } catch {
            throw Self.map(channelError: error)
        }
    }

    private func usbRedirectionBackendFailed(
        _ error: any Error,
        channelID: UInt8,
        generation: UInt64
    ) async {
        guard generation == supervisionGeneration,
              usbRedirectionHosts[channelID] != nil else { return }
        await receiveFailed(
            .protocolViolation("USB redirection backend: \(String(describing: error))"),
            generation: generation
        )
    }

    private func stopUSBRedirectionHosts() async {
        let tasks = usbRedirectionPumpTasks.values
        usbRedirectionPumpTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
        let hosts = usbRedirectionHosts.values
        usbRedirectionHosts.removeAll(keepingCapacity: false)
        for host in hosts {
            _ = try? await host.detachDevice()
        }
    }

    private func stopWebDAVServers() async {
        let servers = webDAVServers.values
        webDAVServers.removeAll(keepingCapacity: false)
        for server in servers {
            await server.closeAll()
        }
    }

    private func sendWebDAVBackendResponses(
        _ responses: [Data],
        clientID: Int64,
        channelID: UInt8,
        generation: UInt64
    ) async throws(SpiceError) {
        guard generation == supervisionGeneration else { throw .cancelled }
        for response in responses {
            var offset = 0
            while offset < response.count {
                let end = min(offset + Int(UInt16.max), response.count)
                try await sendWebDAVResponse(
                    clientID: clientID,
                    data: Data(response[offset..<end]),
                    channelID: channelID
                )
                offset = end
            }
            if response.isEmpty {
                try await sendWebDAVResponse(
                    clientID: clientID,
                    data: Data(),
                    channelID: channelID
                )
            }
        }
    }

    private nonisolated static func closePrepared(
        main: MainChannel?,
        transport: any SpiceTransport,
        channels: [ChannelKey: any SpiceManagedChannel],
        imageCache: DisplayImageCache? = nil
    ) async {
        await imageCache?.close()
        if let main {
            await main.close()
        } else {
            await transport.close()
        }
        for channel in channels.values {
            await channel.close()
        }
    }

    private nonisolated static func closePrepared(_ prepared: PreparedSession) async {
        await prepared.imageCache.close()
        await prepared.mainChannel.close()
        for channel in prepared.channels.values {
            await channel.close()
        }
    }

    private func startSupervision(mainChannel: MainChannel) {
        supervisionGeneration &+= 1
        let generation = supervisionGeneration
        appendSupervisionTask(
            for: mainChannel,
            key: ChannelKey(type: 1, id: 0),
            generation: generation
        )
        for (key, channel) in channels {
            appendSupervisionTask(for: channel, key: key, generation: generation)
        }
    }

    private func appendSupervisionTask(
        for channel: any SpiceManagedChannel,
        key: ChannelKey,
        generation: UInt64
    ) {
        let emit: @Sendable (SpiceChannelEvent) async -> Void = { [weak self] event in
            await self?.received(event, from: key, generation: generation)
        }
        receiveTasks.append(Task { [weak self] in
            do {
                try await channel.run(emit: emit)
            } catch let error as ChannelError {
                if case let .migrationRequested(key, data) = error {
                    await self?.channelMigrationRequested(
                        key: key,
                        data: data,
                        generation: generation
                    )
                } else {
                    await self?.receiveFailed(error, generation: generation)
                }
            } catch {
                await self?.receiveFailed(
                    Self.channelError(error),
                    generation: generation
                )
            }
        })
    }

    private func ensureClientSendsAllowed() throws(SpiceError) {
        guard seamlessMigrationPayloads.isEmpty else {
            throw .protocolError("channel migration is flushing client messages")
        }
    }

    private func channelMigrationRequested(
        key: ChannelKey,
        data: Data?,
        generation: UInt64
    ) async {
        guard generation == supervisionGeneration else { return }
        guard case let .ready(offer, seamless) = migrationCoordinator.state,
              seamless,
              let prepared = preparedMigrations[offer.id] else {
            await receiveFailed(
                .protocolViolation(
                    "channel migration requested without a seamless prepared target"
                ),
                generation: generation
            )
            return
        }

        let mainKey = ChannelKey(type: 1, id: 0)
        let expectedKeys = Set(channels.keys).union([mainKey])
        guard expectedKeys.contains(key) else {
            await receiveFailed(
                .protocolViolation(
                    "unexpected migrating channel type=\(key.type) id=\(key.id)"
                ),
                generation: generation
            )
            return
        }
        var payloads = seamlessMigrationPayloads[offer.id] ?? [:]
        guard payloads[key] == nil else {
            await receiveFailed(
                .protocolViolation(
                    "duplicate migration boundary for channel type=\(key.type) id=\(key.id)"
                ),
                generation: generation
            )
            return
        }
        payloads[key] = ChannelMigrationPayload(data: data)
        seamlessMigrationPayloads[offer.id] = payloads
        guard Set(payloads.keys) == expectedKeys else { return }

        let actions = migrationCoordinator.beginSeamlessCommit(offerID: offer.id)
        await processMigrationActions(actions, generation: generation)
        guard generation == supervisionGeneration else { return }

        var removedForAdoption = false
        do {
            for key in expectedKeys.sorted(by: {
                ($0.type, $0.id) < ($1.type, $1.id)
            }) {
                guard let data = payloads[key]?.data else { continue }
                guard let targetConnection = prepared.connections[key] else {
                    throw ChannelError.protocolViolation(
                        "prepared target is missing channel type=\(key.type) id=\(key.id)"
                    )
                }
                try await targetConnection.sendMigrationData(data)
            }
            guard preparedMigrations.removeValue(forKey: offer.id) != nil else {
                throw ChannelError.protocolViolation("prepared seamless target was cancelled")
            }
            removedForAdoption = true
            seamlessMigrationPayloads.removeValue(forKey: offer.id)
            guard let credentials = credentialStorage else {
                throw ChannelError.protocolViolation(
                    "seamless migration lost active credentials"
                )
            }
            let adoptedGeneration = try await adoptMigrationTarget(
                prepared,
                credentials: credentials
            )
            guard adoptedGeneration == supervisionGeneration, !isDisconnecting else {
                return
            }
            await migrationHandoffCompleted(offerID: offer.id)
        } catch {
            seamlessMigrationPayloads.removeValue(forKey: offer.id)
            if removedForAdoption {
                await Self.closePrepared(prepared)
            } else if let owned = preparedMigrations.removeValue(forKey: offer.id) {
                await Self.closePrepared(owned)
            }
            await receiveFailed(Self.channelError(error), generation: generation)
        }
    }

    private func received(
        _ event: SpiceChannelEvent,
        from key: ChannelKey,
        generation: UInt64
    ) async {
        guard generation == supervisionGeneration else {
            return
        }
        switch event {
        case let .frame(snapshot):
            desktop.receiveFrame(snapshot, displayChannelID: key.id)
        case let .surfaceDestroyed(surfaceID):
            desktop.surfaceDestroyed(displayChannelID: key.id, surfaceID: surfaceID)
        case let .cursor(cursorEvent):
            switch cursorEvent {
            case let .initialized(snapshot), let .updated(snapshot), let .reset(snapshot):
                desktop.updateCursor(SpiceCursorState(snapshot))
            case .cacheInvalidated, .ignored:
                break
            }
        case let .inputs(inputsEvent):
            switch inputsEvent {
            case let .initialized(modifiers), let .keyboardModifiersChanged(modifiers):
                eventMailbox.send(.keyboardModifiers(modifiers))
            case .mouseMotionAcknowledged:
                eventMailbox.send(.mouseMotionAcknowledged)
            case .ignored:
                break
            }
        case let .main(mainEvent):
            switch mainEvent {
            case let .mouseMode(supported, current):
                _ = supported
                desktop.updatePointerMode(SpicePointerMode(spiceMouseMode: current))
            case let .migration(command):
                let actions = migrationCoordinator.receive(command)
                await processMigrationActions(actions, generation: generation)
            case .agentConnected:
                agentConnectionGeneration &+= 1
                isAgentConnected = true
                await yieldAgentEvent(.connected, generation: generation)
            case let .agentDisconnected(errorCode):
                agentConnectionGeneration &+= 1
                isAgentConnected = false
                await yieldAgentEvent(.disconnected(errorCode: errorCode), generation: generation)
            case let .agentMessage(message):
                await yieldAgentEvent(.message(SpiceAgentMessage(
                    protocolID: message.protocolID,
                    type: message.type,
                    opaque: message.opaque,
                    data: message.data
                )), generation: generation)
            }
        case let .playback(playbackEvent):
            if let event = Self.playbackEvent(playbackEvent) {
                playbackEventContinuation.yield(event)
            }
        case let .record(recordEvent):
            if let event = Self.recordEvent(recordEvent) {
                let result = recordEventContinuation.yield(event)
                if case .dropped = result {
                    await receiveFailed(
                        .protocolViolation("Record event queue overflow"),
                        generation: generation
                    )
                }
            }
        case let .smartcard(smartcardEvent):
            if let event = Self.smartcardEvent(smartcardEvent) {
                let result = smartcardEventContinuation.yield(event)
                if case .dropped = result {
                    await receiveFailed(
                        .protocolViolation("Smartcard event queue overflow"),
                        generation: generation
                    )
                }
            }
        case let .usbRedirection(usbEvent):
            switch usbEvent {
            case let .data(channelID, data):
                if let host = usbRedirectionHosts[channelID] {
                    do {
                        try await sendUSBBackendPackets(
                            try await host.receiveFromGuest(data),
                            channelID: channelID,
                            generation: generation
                        )
                    } catch {
                        await usbRedirectionBackendFailed(
                            error,
                            channelID: channelID,
                            generation: generation
                        )
                    }
                } else {
                    let result = usbRedirectionContinuation.yield(
                        SpiceUSBRedirectionPacket(channelID: channelID, data: data)
                    )
                    if case .dropped = result {
                        await receiveFailed(
                            .protocolViolation("USB redirection packet queue overflow"),
                            generation: generation
                        )
                    }
                }
            case .ignored:
                break
            }
        case let .webDAV(channelID, webDAVEvent):
            let publicEvent: SpiceWebDAVEvent?
            switch webDAVEvent {
            case let .initialized(initialization):
                publicEvent = .initialized(
                    name: initialization.name,
                    opened: initialization.opened
                )
            case let .port(event):
                publicEvent = SpiceWebDAVPortEvent(rawValue: event.rawValue).map {
                    .port($0)
                }
            case let .request(clientID, data):
                if let server = webDAVServers[channelID] {
                    do {
                        try await sendWebDAVBackendResponses(
                            try await server.receive(clientID: clientID, data: data),
                            clientID: clientID,
                            channelID: channelID,
                            generation: generation
                        )
                        publicEvent = nil
                    } catch {
                        await receiveFailed(
                            .protocolViolation(
                                "WebDAV backend: \(String(describing: error))"
                            ),
                            generation: generation
                        )
                        return
                    }
                } else {
                    publicEvent = .request(clientID: clientID, data: data)
                }
            case let .clientClosed(clientID):
                if let server = webDAVServers[channelID] {
                    await server.close(clientID: clientID)
                    publicEvent = nil
                } else {
                    publicEvent = .clientClosed(clientID)
                }
            case .ignored:
                publicEvent = nil
            }
            if let publicEvent {
                let result = webDAVEventContinuation.yield(publicEvent)
                if case .dropped = result {
                    await receiveFailed(
                        .protocolViolation("WebDAV event queue overflow"),
                        generation: generation
                    )
                }
            }
        case let .displayMonitors(channelID, configuration):
            eventMailbox.send(.displayConfiguration(.init(
                channelID: channelID,
                maximumAllowed: configuration.maximumAllowed == 0
                    ? nil
                    : configuration.maximumAllowed,
                monitors: configuration.monitors.map { monitor in
                    SpiceGuestMonitor(
                        id: monitor.id,
                        surfaceID: monitor.surfaceID,
                        x: monitor.x,
                        y: monitor.y,
                        width: monitor.width,
                        height: monitor.height,
                        flags: monitor.flags
                    )
                }
            )))
        case .surfaceCreated:
            break
        }
    }

    private func yieldAgentEvent(_ event: SpiceAgentEvent, generation: UInt64) async {
        switch event {
        case .connected, .disconnected:
            sendAgentLifecycle(event)
        case .message where agentEventMailbox.send(
            event,
            connectionGeneration: agentConnectionGeneration
        ) == .full:
            await receiveFailed(
                .protocolViolation("Agent event buffer overflow"),
                generation: generation
            )
        case .message:
            break
        }
    }

    private func processMigrationActions(
        _ actions: [MigrationHandoffCoordinator.Action],
        generation: UInt64
    ) async {
        guard generation == supervisionGeneration else { return }
        for action in actions {
            guard generation == supervisionGeneration else { return }
            switch action {
            case let .emit(event):
                eventMailbox.send(.migration(event))
            case let .send(reply):
                guard let mainChannel else { return }
                do {
                    try await mainChannel.sendMigrationReply(reply)
                } catch {
                    await receiveFailed(Self.channelError(error), generation: generation)
                    return
                }
            case let .cancel(offer):
                migrationTask?.cancel()
                migrationTask = nil
                Task { [weak self] in
                    await self?.cancelMigrationOffer(offer, resumeSource: true)
                }
            case let .prepare(offer):
                startMigrationTask(offer: offer, operation: .prepare, generation: generation)
            case let .commit(offer):
                startMigrationTask(offer: offer, operation: .commit, generation: generation)
            case let .switchHost(offer):
                startMigrationTask(offer: offer, operation: .switchHost, generation: generation)
            case let .protocolViolation(reason):
                await receiveFailed(.protocolViolation(reason), generation: generation)
                return
            }
        }
    }

    private enum MigrationOperation: Sendable {
        case prepare
        case commit
        case switchHost
    }

    private func startMigrationTask(
        offer: SpiceMigrationOffer,
        operation: MigrationOperation,
        generation: UInt64
    ) {
        migrationTask?.cancel()
        let executor = injectedMigrationExecutor
        migrationTask = Task { [weak self] in
            do {
                switch operation {
                case .prepare:
                    let acceptedSeamless: Bool
                    if let executor {
                        acceptedSeamless = try await executor.prepare(offer)
                    } else if let self {
                        acceptedSeamless = try await self.prepareMigrationTarget(offer)
                    } else {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.migrationPreparationCompleted(
                        offerID: offer.id,
                        acceptedSeamless: acceptedSeamless,
                        generation: generation
                    )
                case .commit:
                    if let executor {
                        try await executor.commit(offer)
                    } else if let self {
                        try await self.commitMigrationTarget(offer)
                    } else {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.migrationHandoffCompleted(offerID: offer.id)
                case .switchHost:
                    if let executor {
                        try await executor.switchHost(offer)
                    } else if let self {
                        try await self.switchMigrationTarget(offer)
                    } else {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await self?.migrationHandoffCompleted(offerID: offer.id)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                await self?.migrationOperationFailed(
                    offerID: offer.id,
                    operation: operation,
                    reason: String(describing: error),
                    generation: generation
                )
            }
        }
    }

    private func migrationPreparationCompleted(
        offerID: UInt64,
        acceptedSeamless: Bool,
        generation: UInt64
    ) async {
        guard generation == supervisionGeneration else { return }
        migrationTask = nil
        let actions = migrationCoordinator.preparationCompleted(
            offerID: offerID,
            acceptedSeamless: acceptedSeamless
        )
        await processMigrationActions(actions, generation: generation)
    }

    private func migrationHandoffCompleted(offerID: UInt64) async {
        migrationTask = nil
        let actions = migrationCoordinator.handoffCompleted(offerID: offerID)
        await processMigrationActions(actions, generation: supervisionGeneration)
    }

    private func migrationOperationFailed(
        offerID: UInt64,
        operation: MigrationOperation,
        reason: String,
        generation: UInt64
    ) async {
        guard generation == supervisionGeneration else { return }
        migrationTask = nil
        let actions: [MigrationHandoffCoordinator.Action]
        switch operation {
        case .prepare:
            actions = migrationCoordinator.preparationFailed(
                offerID: offerID,
                reason: reason
            )
        case .commit, .switchHost:
            actions = migrationCoordinator.handoffFailed(
                offerID: offerID,
                reason: reason
            )
        }
        await processMigrationActions(actions, generation: generation)
    }

    private func cancelMigrationHandoff() async {
        migrationTask?.cancel()
        migrationTask = nil
        let actions = migrationCoordinator.disconnect()
        for action in actions {
            if case let .cancel(offer) = action {
                await cancelMigrationOffer(offer, resumeSource: false)
            }
        }
        // Coordinator actions normally own the active offer. Drain any
        // prepared target left outside that state as a teardown backstop so a
        // failed or superseded preparation cannot retain its Session cache.
        let orphanedPreparedTargets = Array(preparedMigrations.values)
        preparedMigrations.removeAll(keepingCapacity: false)
        seamlessMigrationPayloads.removeAll(keepingCapacity: false)
        for prepared in orphanedPreparedTargets {
            await Self.closePrepared(prepared)
        }
    }

    private func cancelAndCloseRetiringMainDrain() async {
        guard let drain = retiringMainDrain else { return }
        retiringMainDrain = nil
        drain.task.cancel()
        await drain.connection.close()
        _ = await drain.task.value
    }

    private func prepareMigrationTarget(_ offer: SpiceMigrationOffer) async throws -> Bool {
        guard let credentials = credentialStorage,
              let sourceBootstrap = currentBootstrap else {
            throw SpiceError.protocolError("migration started without active credentials")
        }
        let endpoint = try migrationEndpoint(for: offer)
        let (prepared, acceptedSeamless) = try await prepareMigrationConnection(
            endpoint: endpoint,
            credentials: credentials,
            offer: offer,
            sourceBootstrap: sourceBootstrap
        )
        guard !Task.isCancelled else {
            await Self.closePrepared(prepared)
            throw CancellationError()
        }
        if let previous = preparedMigrations.updateValue(prepared, forKey: offer.id) {
            await Self.closePrepared(previous)
        }
        return acceptedSeamless
    }

    private func prepareMigrationConnection(
        endpoint: SpiceEndpoint,
        credentials: SpiceCredentialStorage,
        offer: SpiceMigrationOffer,
        sourceBootstrap: MainBootstrap
    ) async throws(SpiceError) -> (PreparedSession, Bool) {
        let transport = transportFactory(endpoint)
        let imageCache = displayImageCacheFactory()
        var preparedMain: MainChannel?
        var preparedChannels: [ChannelKey: any SpiceManagedChannel] = [:]
        var preparedConnections: [ChannelKey: ChannelConnection] = [:]
        do {
            try await transport.connect()
            let serialBarrier = ChannelSerialBarrier()
            let glzDecoder = SpiceGLZDecoder()
            let multimediaClock = MultimediaClock()
            let sourceVersion: UInt32?
            if case let .seamless(version) = offer.mode {
                sourceVersion = version
            } else {
                sourceVersion = nil
            }
            let handshake = try await LinkHandshake().perform(
                transport: transport,
                request: .migrationTargetMain(
                    requestsSeamless: sourceVersion != nil
                ),
                password: credentials.copyPassword(),
                ticketEncryptor: ticketEncryptor
            )
            let connection = ChannelConnection(
                key: ChannelKey(type: 1, id: 0),
                transport: transport,
                headerMode: handshake.headerMode,
                serialBarrier: serialBarrier
            )
            let main = MainChannel(connection: connection, multimediaClock: multimediaClock)
            preparedMain = main
            preparedConnections[connection.key] = connection

            let serverMainCapabilities = CapabilitySet<MainCapability>(
                words: handshake.channelCapabilityWords
            )
            let acceptedSeamless: Bool
            if let sourceVersion,
               serverMainCapabilities.contains(.seamlessMigrate) {
                acceptedSeamless = try await main.negotiateDestinationSeamless(
                    sourceVersion: sourceVersion
                )
            } else {
                acceptedSeamless = false
            }

            let transportFactory = self.transportFactory
            let channelFactory = ChannelFactory(
                transportFactory: { _ in transportFactory(endpoint) },
                ticketEncryptor: ticketEncryptor,
                serialBarrier: serialBarrier,
                advertisesH264: endpoint.videoCodecPolicy == .h264AndMJPEG,
                advertisesH265: endpoint.videoCodecPolicy == .h265AndMJPEG
            )
            for descriptor in sourceBootstrap.channels {
                try Task.checkCancellation()
                let key = ChannelKey(type: descriptor.type, id: descriptor.id)
                guard key != connection.key else { continue }
                guard preparedChannels[key] == nil else {
                    throw ChannelError.protocolViolation(
                        "duplicate migration channel type=\(key.type) id=\(key.id)"
                    )
                }
                let connected = try await channelFactory.connect(
                    key: key,
                    connectionID: sourceBootstrap.sessionID,
                    password: credentials.copyPassword()
                )
                preparedConnections[key] = connected
                preparedChannels[key] = Self.makeChannel(
                    key: key,
                    connection: connected,
                    glzDecoder: glzDecoder,
                    imageCache: imageCache,
                    multimediaClock: multimediaClock,
                    surfaceMemoryBudget: surfaceMemoryBudget,
                    frameDemandCoordinator: desktop.frameDemandCoordinator,
                    mjpegDecodeLimiter: mjpegDecodeLimiter
                )
            }
            try Task.checkCancellation()
            return (PreparedSession(
                endpoint: endpoint,
                mainChannel: main,
                imageCache: imageCache,
                channels: preparedChannels,
                connections: preparedConnections,
                bootstrap: sourceBootstrap
            ), acceptedSeamless)
        } catch is CancellationError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw .cancelled
        } catch let error as ChannelError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw Self.map(channelError: error)
        } catch let error as TransportError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw Self.map(transportError: error)
        } catch {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels,
                imageCache: imageCache
            )
            throw .protocolError(String(describing: error))
        }
    }

    private func commitMigrationTarget(_ offer: SpiceMigrationOffer) async throws {
        guard let prepared = preparedMigrations[offer.id],
              let credentials = credentialStorage else {
            throw SpiceError.protocolError("migration target was not prepared")
        }
        var removedForAdoption = false
        do {
            try await prepared.mainChannel.sendMigrationReply(.end)
            try Task.checkCancellation()
            guard preparedMigrations.removeValue(forKey: offer.id) != nil else {
                throw CancellationError()
            }
            removedForAdoption = true
            _ = try await adoptMigrationTarget(prepared, credentials: credentials)
        } catch {
            if removedForAdoption {
                await Self.closePrepared(prepared)
            } else if let owned = preparedMigrations.removeValue(forKey: offer.id) {
                await Self.closePrepared(owned)
            }
            throw error
        }
    }

    private func switchMigrationTarget(_ offer: SpiceMigrationOffer) async throws {
        guard let credentials = credentialStorage else {
            throw SpiceError.protocolError("migration started without active credentials")
        }
        let endpoint = try migrationEndpoint(for: offer)
        let prepared = try await prepareConnection(endpoint: endpoint, credentials: credentials)
        guard !Task.isCancelled else {
            await Self.closePrepared(prepared)
            throw CancellationError()
        }
        do {
            try await replaceSessionWithTarget(prepared, credentials: credentials)
        } catch {
            await Self.closePrepared(prepared)
            throw error
        }
    }

    private func adoptMigrationTarget(
        _ prepared: PreparedSession,
        credentials: SpiceCredentialStorage
    ) async throws -> UInt64 {
        try Task.checkCancellation()
        guard retiringMainDrain == nil else {
            throw SpiceError.protocolError("migration already has a retiring Main connection")
        }
        let drainID = nextRetiringMainDrainID
        let (nextDrainID, drainIDOverflow) = drainID.addingReportingOverflow(1)
        guard !drainIDOverflow else {
            throw SpiceError.protocolError("retiring Main drain ID overflow")
        }
        nextRetiringMainDrainID = nextDrainID

        let mainKey = ChannelKey(type: 1, id: 0)
        let activeKeys = Set(connections.keys)
        let preparedKeys = Set(prepared.connections.keys)
        guard activeKeys == preparedKeys,
              prepared.connections[mainKey] != nil,
              Set(channels.keys) == preparedKeys.subtracting([mainKey]) else {
            throw SpiceError.protocolError(
                "migration target channel inventory does not match active session"
            )
        }

        supervisionGeneration &+= 1
        let oldTasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in oldTasks { task.cancel() }

        guard let mainChannel,
              let targetMainConnection = prepared.connections[mainKey] else {
            throw SpiceError.protocolError("migration lost active Main Channel")
        }

        var previousConnections: [ChannelKey: ChannelConnection] = [:]
        do {
            previousConnections[mainKey] = try await mainChannel.replaceConnection(
                with: targetMainConnection
            )
            for key in channels.keys.sorted(by: Self.channelKeySort) {
                guard let channel = channels[key],
                      let replacement = prepared.connections[key] else {
                    throw ChannelError.protocolViolation(
                        "migration target is missing an active Channel connection"
                    )
                }
                previousConnections[key] = try await channel.replaceConnection(
                    with: replacement
                )
            }
        } catch {
            if let previousMain = previousConnections[mainKey] {
                _ = try? await mainChannel.replaceConnection(with: previousMain)
            }
            for key in channels.keys.sorted(by: Self.channelKeySort) {
                guard let previous = previousConnections[key], let channel = channels[key] else {
                    continue
                }
                _ = try? await channel.replaceConnection(with: previous)
            }
            throw Self.map(channelError: error as? ChannelError ?? .invalidState)
        }

        connections = prepared.connections
        currentEndpoint = prepared.endpoint
        currentBootstrap = prepared.bootstrap
        credentialStorage = credentials
        await prepared.imageCache.close()
        desktop.beginSeamlessMigration(
            pointerMode: SpicePointerMode(spiceMouseMode: prepared.bootstrap.currentMouseMode)
        )
        for key in previousConnections.keys.sorted(by: Self.channelKeySort)
        where key != mainKey {
            await previousConnections[key]?.close()
        }
        startSupervision(mainChannel: mainChannel)
        let adoptedGeneration = supervisionGeneration
        if let previousMainConnection = previousConnections[mainKey] {
            let drainTask = Task.detached {
                () -> Result<Void, ChannelError> in
                do {
                    try await mainChannel.waitForActiveAgentSends(
                        on: previousMainConnection
                    )
                    return .success(())
                } catch let error as ChannelError {
                    return .failure(error)
                } catch {
                    return .failure(.invalidState)
                }
            }
            retiringMainDrain = RetiringMainDrain(
                id: drainID,
                connection: previousMainConnection,
                task: drainTask
            )
            let drainResult = await drainTask.value
            let stillOwnsDrain = retiringMainDrain?.id == drainID
            if stillOwnsDrain {
                retiringMainDrain = nil
            }
            await previousMainConnection.close()
            guard stillOwnsDrain else {
                throw ChannelError.transport(.cancelled)
            }
            if case let .failure(error) = drainResult {
                throw error
            }
        }
        return adoptedGeneration
    }

    private func replaceSessionWithTarget(
        _ prepared: PreparedSession,
        credentials: SpiceCredentialStorage
    ) async throws {
        try Task.checkCancellation()

        supervisionGeneration &+= 1
        agentConnectionGeneration &+= 1
        let oldTasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in oldTasks { task.cancel() }

        let oldMain = mainChannel
        let oldImageCache = displayImageCache
        let oldChannels = channels
        let oldAgentConnected = isAgentConnected
        let oldHadPlaybackChannel = oldChannels[ChannelKey(type: 5, id: 0)] != nil

        mainChannel = prepared.mainChannel
        displayImageCache = prepared.imageCache
        channels = prepared.channels
        connections = prepared.connections
        currentEndpoint = prepared.endpoint
        currentBootstrap = prepared.bootstrap
        credentialStorage = credentials
        isAgentConnected = prepared.bootstrap.agentConnected
        desktop.beginSession(
            pointerMode: SpicePointerMode(spiceMouseMode: prepared.bootstrap.currentMouseMode)
        )
        emitChannelLifecycleEnded(
            wasAgentConnected: oldAgentConnected,
            hadPlaybackChannel: oldHadPlaybackChannel
        )
        if prepared.bootstrap.agentConnected {
            sendAgentLifecycle(.connected)
        }
        startSupervision(mainChannel: prepared.mainChannel)
        await oldImageCache?.close()
        if let oldMain { await oldMain.close() }
        for key in oldChannels.keys.sorted(by: Self.channelKeySort) {
            if let channel = oldChannels[key] {
                await closeAndArchive(channel)
            }
        }
    }

    private nonisolated static func channelKeySort(
        _ lhs: ChannelKey,
        _ rhs: ChannelKey
    ) -> Bool {
        lhs.type == rhs.type ? lhs.id < rhs.id : lhs.type < rhs.type
    }

    private func cancelMigrationOffer(
        _ offer: SpiceMigrationOffer,
        resumeSource: Bool
    ) async {
        if let executor = injectedMigrationExecutor {
            await executor.cancel(offer)
        }
        if let prepared = preparedMigrations.removeValue(forKey: offer.id) {
            await Self.closePrepared(prepared)
        }
        let partialPayloads = seamlessMigrationPayloads.removeValue(forKey: offer.id)
        guard resumeSource, let partialPayloads else { return }
        let generation = supervisionGeneration
        for key in partialPayloads.keys {
            await connections[key]?.resumeAfterMigrationCancellation()
            if key == ChannelKey(type: 1, id: 0), let mainChannel {
                appendSupervisionTask(for: mainChannel, key: key, generation: generation)
            } else if let channel = channels[key] {
                appendSupervisionTask(for: channel, key: key, generation: generation)
            }
        }
    }

    private func migrationEndpoint(for offer: SpiceMigrationOffer) throws -> SpiceEndpoint {
        try Self.selectMigrationEndpoint(
            destination: offer.destination,
            current: currentEndpoint
        )
    }

    package nonisolated static func selectMigrationEndpoint(
        destination: SpiceMigrationDestination,
        current: SpiceEndpoint?
    ) throws(SpiceError) -> SpiceEndpoint {
        guard destination.certificateSubject == nil else {
            throw SpiceError.protocolError(
                "migration certificate-subject verification is not implemented"
            )
        }
        if let tlsPolicy = current?.tlsPolicy {
            guard let securePort = destination.securePort else {
                throw SpiceError.protocolError("refusing to downgrade a TLS migration target")
            }
            return SpiceEndpoint(
                host: destination.host,
                port: securePort,
                tlsPolicy: tlsPolicy,
                videoCodecPolicy: current?.videoCodecPolicy ?? .mjpegOnly
            )
        }
        if let port = destination.port {
            return SpiceEndpoint(
                host: destination.host,
                port: port,
                videoCodecPolicy: current?.videoCodecPolicy ?? .mjpegOnly
            )
        }
        if let securePort = destination.securePort {
            return SpiceEndpoint(
                host: destination.host,
                port: securePort,
                tlsPolicy: .system,
                videoCodecPolicy: current?.videoCodecPolicy ?? .mjpegOnly
            )
        }
        throw SpiceError.protocolError("migration target has no usable port")
    }

    private func receiveFailed(_ error: ChannelError, generation: UInt64) async {
        guard generation == supervisionGeneration, mainChannel != nil else {
            return
        }
        isDisconnecting = true
        supervisionGeneration &+= 1
        agentConnectionGeneration &+= 1
        await cancelMigrationHandoff()
        await cancelAndCloseRetiringMainDrain()
        await stopUSBRedirectionHosts()
        await stopWebDAVServers()
        let tasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in tasks {
            task.cancel()
        }
        let wasAgentConnected = isAgentConnected
        let hadPlaybackChannel = channels[ChannelKey(type: 5, id: 0)] != nil
        let connectedMainChannel = mainChannel
        let connectedImageCache = displayImageCache
        mainChannel = nil
        displayImageCache = nil
        isAgentConnected = false
        await connectedImageCache?.close()
        if let connectedMainChannel {
            await connectedMainChannel.close()
        }
        await closeChannels()
        connections.removeAll(keepingCapacity: false)
        credentialStorage = nil
        currentEndpoint = nil
        currentBootstrap = nil
        desktop.endSession()
        emitChannelLifecycleEnded(
            wasAgentConnected: wasAgentConnected,
            hadPlaybackChannel: hadPlaybackChannel
        )
        eventMailbox.send(.failed(Self.map(channelError: error)))
        finishConnectionLifecycle(currentConnectionLifecycleID)
    }

    private func connectionAttemptFinished(
        lifecycleID: UInt64,
        connected: Bool
    ) {
        guard currentConnectionLifecycleID == lifecycleID else { return }
        isConnecting = false
        connectionAttemptTask = nil
        if !connected, !isDisconnecting {
            finishConnectionLifecycle(lifecycleID)
        }
    }

    private func cancelConnectionLifecycleWaiter(_ token: UInt64) {
        connectionLifecycleWaiters.removeValue(forKey: token)?.continuation.resume()
    }

    private func finishConnectionLifecycle(_ lifecycleID: UInt64?) {
        guard let lifecycleID else {
            isDisconnecting = false
            return
        }
        if currentConnectionLifecycleID == lifecycleID {
            currentConnectionLifecycleID = nil
        }
        isConnecting = false
        isDisconnecting = false
        let tokens = connectionLifecycleWaiters.compactMap { token, waiter in
            waiter.lifecycleID == lifecycleID ? token : nil
        }
        let continuations = tokens.compactMap {
            connectionLifecycleWaiters.removeValue(forKey: $0)?.continuation
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func emitChannelLifecycleEnded(
        wasAgentConnected: Bool,
        hadPlaybackChannel: Bool
    ) {
        if wasAgentConnected {
            sendAgentLifecycle(.disconnected(errorCode: 0))
        }
        if hadPlaybackChannel {
            playbackEventContinuation.yield(.stopped)
        }
    }

    package func currentAgentDisconnectRevision() -> UInt64 {
        agentDisconnectRevision
    }

    private func sendAgentLifecycle(_ event: SpiceAgentEvent) {
        let disconnectRevision: UInt64?
        if case .disconnected = event {
            agentDisconnectRevision &+= 1
            disconnectRevision = agentDisconnectRevision
        } else {
            disconnectRevision = nil
        }
        agentEventMailbox.sendLifecycle(
            event,
            disconnectRevision: disconnectRevision,
            connectionGeneration: agentConnectionGeneration,
            sessionLifecycleID: currentConnectionLifecycleID
        )
    }

    private nonisolated static func channelInput(_ input: SpiceClientInput) -> SpiceInputEvent {
        switch input {
        case let .keyDown(scanCode):
            .keyDown(scanCode: scanCode)
        case let .keyUp(scanCode):
            .keyUp(scanCode: scanCode)
        case let .lockModifiers(modifiers):
            .lockModifiers(modifiers)
        case let .mouseMotion(dx, dy):
            .mouseMotion(dx: dx, dy: dy)
        case let .mousePosition(x, y, displayID):
            .mousePosition(x: x, y: y, displayID: displayID)
        case let .mousePress(button):
            .mousePress(channelButton(button))
        case let .mouseRelease(button):
            .mouseRelease(channelButton(button))
        }
    }

    package nonisolated static func playbackEvent(
        _ event: SpiceChannels.PlaybackEvent
    ) -> SpicePlaybackEvent? {
        switch event {
        case let .modeChanged(multimediaTime, mode):
            .modeChanged(
                multimediaTime: multimediaTime,
                mode: SpicePlaybackDataMode(rawValue: UInt32(mode.rawValue)) ?? .raw
            )
        case let .started(start):
            .started(SpicePlaybackConfiguration(
                channels: Int(start.channels),
                format: .signed16LittleEndian,
                sampleRate: Int(start.frequency)
            ))
        case let .packet(packet):
            .packet(SpicePlaybackPacket(
                multimediaTime: packet.multimediaTime,
                data: packet.data
            ))
        case .stopped:
            .stopped
        case let .volumeChanged(volume):
            .volumeChanged(volume)
        case let .muteChanged(mute):
            .muteChanged(mute)
        case let .minimumLatencyChanged(milliseconds):
            .minimumLatencyChanged(milliseconds: milliseconds)
        case .ignored:
            nil
        }
    }

    package nonisolated static func recordEvent(
        _ event: RecordEvent
    ) -> SpiceRecordEvent? {
        switch event {
        case let .started(start):
            .started(SpiceRecordConfiguration(
                channels: Int(start.channels),
                format: .signed16LittleEndian,
                sampleRate: Int(start.frequency)
            ))
        case .stopped:
            .stopped
        case let .volumeChanged(volume):
            .volumeChanged(volume)
        case let .muteChanged(mute):
            .muteChanged(mute)
        case .ignored:
            nil
        }
    }

    package nonisolated static func smartcardEvent(
        _ event: SmartcardEvent
    ) -> SpiceSmartcardEvent? {
        switch event {
        case let .initialized(initialization):
            .initialized(SpiceSmartcardInitializationInfo(
                version: initialization.version,
                capabilities: initialization.capabilities
            ))
        case let .operationCompleted(request, readerID, errorCode):
            SpiceSmartcardRequestType(rawValue: request.rawValue).map {
                .operationCompleted(
                    request: $0,
                    readerID: readerID,
                    errorCode: errorCode
                )
            }
        case let .apdu(readerID, data):
            .apdu(readerID: readerID, data: data)
        case let .flushRequested(readerID):
            .flushRequested(readerID: readerID)
        case .ignored:
            nil
        }
    }

    private nonisolated static func channelButton(
        _ button: SpiceMouseButton
    ) -> SpiceChannels.SpiceMouseButton {
        switch button {
        case .left: .left
        case .middle: .middle
        case .right: .right
        case .scrollUp: .scrollUp
        case .scrollDown: .scrollDown
        case .side: .side
        case .extra: .extra
        }
    }

    private nonisolated static func channelError(_ error: any Error) -> ChannelError {
        if let channelError = error as? ChannelError {
            return channelError
        }
        return .protocolViolation(String(describing: error))
    }

    private nonisolated static func makeChannel(
        key: ChannelKey,
        connection: ChannelConnection,
        glzDecoder: SpiceGLZDecoder,
        imageCache: DisplayImageCache,
        multimediaClock: any MultimediaClockScheduling,
        surfaceMemoryBudget: SurfaceMemoryBudget,
        frameDemandCoordinator: DisplayFrameDemandCoordinator,
        mjpegDecodeLimiter: SpiceMJPEGDecodeLimiter
    ) -> any SpiceManagedChannel {
        switch SpiceChannelKind(rawValue: key.type) {
        case .display:
            DisplayChannel(
                connection: connection,
                surfaces: SurfaceStore(memoryBudget: surfaceMemoryBudget),
                imageCache: imageCache,
                glzDecoder: glzDecoder,
                multimediaClock: multimediaClock,
                frameDemandCoordinator: frameDemandCoordinator,
                mjpegDecodeLimiter: mjpegDecodeLimiter
            )
        case .inputs:
            InputsChannel(connection: connection)
        case .cursor:
            CursorChannel(connection: connection)
        case .playback:
            PlaybackChannel(connection: connection, multimediaClock: multimediaClock)
        case .record:
            RecordChannel(connection: connection)
        case .smartcard:
            SmartcardChannel(connection: connection)
        case .usbRedirection:
            USBRedirectionChannel(connection: connection)
        case .webDAV:
            WebDAVChannel(connection: connection)
        case .main, .unknown:
            PassiveChannel(connection: connection)
        }
    }

    private nonisolated static func makeNetworkTransport(
        endpoint: SpiceEndpoint
    ) -> any SpiceTransport {
        switch endpoint.tlsPolicy {
        case nil:
            NetworkSpiceTransport(host: endpoint.host, port: endpoint.port)
        case .system:
            NetworkSpiceTransport(
                host: endpoint.host,
                port: endpoint.port,
                tlsPolicy: .system
            )
        case let .customCertificateAuthority(certificates, serverName):
            NetworkSpiceTransport(
                host: endpoint.host,
                port: endpoint.port,
                tlsPolicy: .customCertificateAuthority(
                    certificates: certificates,
                    serverName: serverName
                )
            )
        case let .virtViewerCertificateAuthority(certificates, expectedSubject):
            NetworkSpiceTransport(
                host: endpoint.host,
                port: endpoint.port,
                tlsPolicy: .virtViewerCertificateAuthority(
                    certificates: certificates,
                    expectedSubject: expectedSubject
                )
            )
        case .insecureForTestingOnly:
            NetworkSpiceTransport(
                host: endpoint.host,
                port: endpoint.port,
                tlsPolicy: .insecureForTestingOnly
            )
        }
    }

    private nonisolated static func map(transportError: TransportError) -> SpiceError {
        switch transportError {
        case .cancelled:
            .cancelled
        default:
            .connectionFailed(String(describing: transportError))
        }
    }

    package nonisolated static func map(channelError: ChannelError) -> SpiceError {
        switch channelError {
        case let .transport(error):
            return map(transportError: error)
        case let .authentication(error):
            return .authenticationFailed(String(describing: error))
        case let .wire(error):
            return .protocolError(String(describing: error))
        case let .linkRejected(code):
            return .protocolError("link rejected with code \(code)")
        case let .migrationRequested(key, _):
            return .protocolError(
                "unexpected migration request on channel type=\(key.type) id=\(key.id)"
            )
        case .invalidState:
            return .protocolError("invalid channel state")
        case .unsupportedCapability:
            return .protocolError("unsupported server capability")
        case let .videoCodecFailure(codec, reason):
            let publicCodec: SpiceVideoCodec = switch codec {
            case .h264: .h264
            case .h265: .h265
            }
            let publicReason: SpiceVideoCodecFailureReason = switch reason {
            case let .hardwareUnavailable(status):
                .hardwareUnavailable(status: status)
            case let .unsupportedFormat(status):
                .unsupportedFormat(status: status)
            }
            return .videoCodecUnavailable(SpiceVideoCodecFailure(
                codec: publicCodec,
                reason: publicReason
            ))
        case let .protocolViolation(reason):
            return .protocolError(reason)
        }
    }
}
