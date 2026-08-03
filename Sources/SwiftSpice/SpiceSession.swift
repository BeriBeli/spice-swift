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
    case inputGenerationExpired
    case agentQueueFull
    case agentCancelled(partial: Bool)
    case agentDisconnected
    case agentMessageFailed(partial: Bool)
    case agentMigrationRebind(partial: Bool)
    case agentStalled(partial: Bool)
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
        case .inputGenerationExpired:
            "input generation expired"
        case .agentQueueFull:
            "guest Agent outbound queue is full"
        case let .agentCancelled(partial):
            partial
                ? "guest Agent caller cancelled after a partial write"
                : "guest Agent caller cancelled before its first write"
        case .agentDisconnected:
            "guest Agent is disconnected"
        case let .agentMessageFailed(partial):
            partial
                ? "guest Agent message failed after a partial write"
                : "guest Agent message failed before its first write"
        case let .agentMigrationRebind(partial):
            partial
                ? "guest Agent migration interrupted a partial message"
                : "guest Agent message was not started before migration"
        case let .agentStalled(partial):
            partial
                ? "guest Agent stalled after a partial message"
                : "guest Agent stalled before sending a message"
        case .cancelled:
            "connection cancelled"
        }
    }
}

public actor SpiceSession {
    package enum MigrationReplacementPhase: Sendable {
        case applying
        case rollingBack
    }

    package typealias TransportFactory = @Sendable (SpiceEndpoint) -> any SpiceTransport
    package typealias MigrationReplacementHook =
        @Sendable (MigrationReplacementPhase, ChannelKey) async throws -> Void
    package typealias MigrationTargetEndHook = @Sendable () async throws -> Void
    package typealias MigrationPreparationCompletionHook =
        @Sendable (_ offerID: UInt64, _ operationID: UInt64) async -> Void
    package typealias MigrationCompletionHook =
        @Sendable (_ offerID: UInt64, _ operationID: UInt64) async -> Void

    private let transportFactory: TransportFactory
    private let ticketEncryptor: any TicketEncrypting
    private let injectedMigrationExecutor: (any SpiceMigrationHandoffExecuting)?
    private let injectedMigrationReplacementHook: MigrationReplacementHook?
    private let injectedMigrationTargetEndHook: MigrationTargetEndHook?
    private let injectedMigrationPreparationCompletionHook: MigrationPreparationCompletionHook?
    private let injectedMigrationCompletionHook: MigrationCompletionHook?
    private let surfaceMemoryBudget = SurfaceMemoryBudget()
    public nonisolated let events: AsyncStream<SpiceSessionEvent>
    private let eventMailbox: SpiceSessionEventMailbox
    public nonisolated let playbackEvents: AsyncStream<SpicePlaybackEvent>
    private let playbackEventContinuation: AsyncStream<SpicePlaybackEvent>.Continuation
    public nonisolated let recordEvents: AsyncStream<SpiceRecordEvent>
    private let recordEventContinuation: AsyncStream<SpiceRecordEvent>.Continuation
    public nonisolated let agentEvents: AsyncStream<SpiceAgentEvent>
    private let agentEventContinuation: AsyncStream<SpiceAgentEvent>.Continuation
    public nonisolated let smartcardEvents: AsyncStream<SpiceSmartcardEvent>
    private let smartcardEventContinuation: AsyncStream<SpiceSmartcardEvent>.Continuation
    public nonisolated let usbRedirectionPackets: AsyncStream<SpiceUSBRedirectionPacket>
    private let usbRedirectionContinuation:
        AsyncStream<SpiceUSBRedirectionPacket>.Continuation
    public nonisolated let webDAVEvents: AsyncStream<SpiceWebDAVEvent>
    private let webDAVEventContinuation: AsyncStream<SpiceWebDAVEvent>.Continuation
    private var mainChannel: MainChannel?
    private var channels: [ChannelKey: any SpiceManagedChannel] = [:]
    private var connections: [ChannelKey: ChannelConnection] = [:]
    private var retiredDisplayDiagnostics = SpiceSessionDiagnostics()
    private var receiveTasks: [Task<Void, Never>] = []
    private var supervisionGeneration: UInt64 = 0
    private nonisolated let inputSessionIdentity = UUID()
    private var inputGenerationSequence: UInt64 = 0
    private var activeInputGeneration: SpiceInputGeneration?
    private var lifecycleGeneration: UInt64 = 0
    private var isTearingDown = false
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []
    private var migrationAdoptionLifecycleGeneration: UInt64?
    private var credentialStorage: SpiceCredentialStorage?
    private var currentEndpoint: SpiceEndpoint?
    private var currentBootstrap: MainBootstrap?
    private var isConnecting = false
    private var isAgentConnected = false
    private var usbRedirectionHosts: [UInt8: SpiceUSBRedirectionHost] = [:]
    private var usbRedirectionPumpTasks: [UInt8: Task<Void, Never>] = [:]
    private var webDAVServers: [UInt8: SpiceWebDAVServer] = [:]
    private var migrationCoordinator = MigrationHandoffCoordinator()
    private var migrationTask: Task<Void, Never>?
    private var migrationOperationSequence: UInt64 = 0
    private var activeMigrationOperation: MigrationOperationOwner?
    private var migrationCallbackAttemptSequence: UInt64 = 0
    private var migrationCallbackAttemptWaiters: [MigrationCallbackAttemptWaiter] = []
    private var migrationCancellationCompletionSequence: UInt64 = 0
    private var migrationCancellationCompletionWaiters: [MigrationCancellationCompletionWaiter] = []
    private var pendingMigrationSourceResumes: [UInt64: MigrationSourceResume] = [:]
    private var preparedMigrations: [UInt64: PreparedSession] = [:]
    private struct ChannelMigrationPayload: Sendable {
        let data: Data?
    }
    private var seamlessMigrationPayloads:
        [UInt64: [ChannelKey: ChannelMigrationPayload]] = [:]

    private struct PreparedSession: Sendable {
        let endpoint: SpiceEndpoint
        let mainChannel: MainChannel
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

    private struct MigrationAdoptionFailure: Error, Sendable {
        let cause: ChannelError
        let rollbackComplete: Bool
        let lifecycleGeneration: UInt64
        let supervisionGeneration: UInt64
    }

    private struct MigrationAdoptionCommit: Sendable {
        let lifecycleGeneration: UInt64
        let supervisionGeneration: UInt64
    }

    private struct MigrationOperationOwner: Sendable, Equatable {
        let offerID: UInt64
        let operationID: UInt64
    }

    private struct MigrationOperationContext: Sendable {
        let owner: MigrationOperationOwner
        let observesTaskCancellation: Bool
    }

    private struct MigrationCallbackAttemptWaiter {
        let observedSequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct MigrationCancellationCompletionWaiter {
        let observedSequence: UInt64
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct MigrationOfferCancellation {
        let offer: SpiceMigrationOffer
        let prepared: PreparedSession?
        let sourceResume: MigrationSourceResume?
    }

    private struct MigrationSourceResume {
        let lifecycleGeneration: UInt64
        let supervisionGeneration: UInt64
        let mainChannel: MainChannel
        let connections: [ChannelKey: ChannelConnection]
        let channels: [ChannelKey: any SpiceManagedChannel]
        let keys: [ChannelKey]
    }

    private enum MigrationAdoptionPolicy: Sendable {
        /// Every source receive loop stopped at a channel MIGRATE boundary and
        /// can be safely restarted after a complete reverse replacement.
        case sourceResumable
        /// The source has no proven restart boundary (for example after a
        /// non-seamless END); any adoption failure must close the full session.
        case failClosed
    }

    public init() {
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
        let agentPipe = AsyncStream.makeStream(
            of: SpiceAgentEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        agentEvents = agentPipe.stream
        agentEventContinuation = agentPipe.continuation
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
        injectedMigrationReplacementHook = nil
        injectedMigrationTargetEndHook = nil
        injectedMigrationPreparationCompletionHook = nil
        injectedMigrationCompletionHook = nil
    }

    package init(
        transportFactory: @escaping TransportFactory,
        ticketEncryptor: any TicketEncrypting,
        migrationExecutor: (any SpiceMigrationHandoffExecuting)? = nil,
        migrationReplacementHook: MigrationReplacementHook? = nil,
        migrationTargetEndHook: MigrationTargetEndHook? = nil,
        migrationPreparationCompletionHook: MigrationPreparationCompletionHook? = nil,
        migrationCompletionHook: MigrationCompletionHook? = nil
    ) {
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
        let agentPipe = AsyncStream.makeStream(
            of: SpiceAgentEvent.self,
            bufferingPolicy: .bufferingOldest(64)
        )
        agentEvents = agentPipe.stream
        agentEventContinuation = agentPipe.continuation
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
        injectedMigrationReplacementHook = migrationReplacementHook
        injectedMigrationTargetEndHook = migrationTargetEndHook
        injectedMigrationPreparationCompletionHook = migrationPreparationCompletionHook
        injectedMigrationCompletionHook = migrationCompletionHook
    }

    deinit {
        eventMailbox.finish()
    }

    public func connect(
        endpoint: SpiceEndpoint,
        credentials: consuming SpiceCredentials
    ) async throws(SpiceError) -> SpiceSessionInfo {
        guard !isTearingDown else {
            throw .cancelled
        }
        guard mainChannel == nil, !isConnecting else {
            throw .alreadyConnected
        }
        let admittedLifecycleGeneration = lifecycleGeneration
        retiredDisplayDiagnostics = SpiceSessionDiagnostics()
        isConnecting = true
        defer { isConnecting = false }

        let credentialStorage = credentials.transferStorage()
        let prepared = try await prepareConnection(
            endpoint: endpoint,
            credentials: credentialStorage
        )
        guard !isTearingDown,
              admittedLifecycleGeneration == lifecycleGeneration,
              mainChannel == nil else {
            await Self.closePrepared(prepared)
            throw .cancelled
        }
        do {
            try await adopt(
                prepared,
                credentials: credentialStorage,
                expectedLifecycleGeneration: admittedLifecycleGeneration
            )
        } catch let error {
            await Self.closePrepared(prepared)
            throw error
        }
        return prepared.info
    }

    private func prepareConnection(
        endpoint: SpiceEndpoint,
        credentials: SpiceCredentialStorage
    ) async throws(SpiceError) -> PreparedSession {
        let transport = transportFactory(endpoint)
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
                    multimediaClock: multimediaClock,
                    surfaceMemoryBudget: surfaceMemoryBudget
                )
            }
            try Task.checkCancellation()
            return PreparedSession(
                endpoint: endpoint,
                mainChannel: main,
                channels: preparedChannels,
                connections: preparedConnections,
                bootstrap: bootstrap
            )
        } catch is CancellationError {
            await Self.closePrepared(main: preparedMain, transport: transport, channels: preparedChannels)
            throw .cancelled
        } catch let error as ChannelError {
            await Self.closePrepared(main: preparedMain, transport: transport, channels: preparedChannels)
            throw Self.map(channelError: error)
        } catch let error as TransportError {
            await Self.closePrepared(main: preparedMain, transport: transport, channels: preparedChannels)
            throw Self.map(transportError: error)
        } catch let error as SpiceError {
            await Self.closePrepared(main: preparedMain, transport: transport, channels: preparedChannels)
            throw error
        } catch {
            await Self.closePrepared(main: preparedMain, transport: transport, channels: preparedChannels)
            throw .protocolError(String(describing: error))
        }
    }

    private func adopt(
        _ prepared: PreparedSession,
        credentials: SpiceCredentialStorage,
        expectedLifecycleGeneration: UInt64
    ) async throws(SpiceError) {
        let inputGeneration = try await prepareInputGeneration(
            in: prepared.channels,
            expectedLifecycleGeneration: expectedLifecycleGeneration
        )
        guard !isTearingDown,
              lifecycleGeneration == expectedLifecycleGeneration,
              mainChannel == nil else {
            if let inputs = prepared.channels[ChannelKey(type: 3, id: 0)] as? InputsChannel {
                await inputs.invalidateSendGeneration()
            }
            throw .cancelled
        }
        mainChannel = prepared.mainChannel
        channels = prepared.channels
        connections = prepared.connections
        currentEndpoint = prepared.endpoint
        currentBootstrap = prepared.bootstrap
        credentialStorage = credentials
        isAgentConnected = prepared.bootstrap.agentConnected
        startSupervision(mainChannel: prepared.mainChannel)
        activeInputGeneration = inputGeneration
        if prepared.bootstrap.agentConnected {
            agentEventContinuation.yield(.connected)
        }
    }

    public func disconnect() async {
        guard beginTeardown() else {
            await waitForTeardown()
            return
        }
        defer { finishTeardown() }
        supervisionGeneration &+= 1
        invalidateInputGeneration()
        await invalidateCurrentInputsSendGeneration()
        await cancelMigrationHandoff()
        await stopUSBRedirectionHosts()
        await stopWebDAVServers()
        let tasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in tasks {
            task.cancel()
        }
        let connectedMainChannel = mainChannel
        self.mainChannel = nil
        isAgentConnected = false
        if let connectedMainChannel {
            await connectedMainChannel.close()
        }
        await closeChannels()
        connections.removeAll(keepingCapacity: false)
        credentialStorage = nil
        currentEndpoint = nil
        currentBootstrap = nil
        eventMailbox.send(.disconnected)
    }

    package func currentAgentConnectionState() -> Bool {
        isAgentConnected
    }

    package func waitUntilInputSendIsQueuedForTesting() async {
        guard let inputs = channels[ChannelKey(type: 3, id: 0)] as? InputsChannel else {
            return
        }
        await inputs.waitUntilSendIsQueuedForTesting()
    }

    package func migrationCallbackAttemptSequenceForTesting() -> UInt64 {
        migrationCallbackAttemptSequence
    }

    package func waitUntilMigrationCallbackAttemptsForTesting(
        after observedSequence: UInt64
    ) async {
        guard migrationCallbackAttemptSequence == observedSequence else { return }
        await withCheckedContinuation { continuation in
            migrationCallbackAttemptWaiters.append(MigrationCallbackAttemptWaiter(
                observedSequence: observedSequence,
                continuation: continuation
            ))
        }
    }

    package func migrationCancellationCompletionSequenceForTesting() -> UInt64 {
        migrationCancellationCompletionSequence
    }

    package func waitUntilMigrationCancellationCompletesForTesting(
        after observedSequence: UInt64
    ) async {
        guard migrationCancellationCompletionSequence == observedSequence else { return }
        await withCheckedContinuation { continuation in
            migrationCancellationCompletionWaiters.append(
                MigrationCancellationCompletionWaiter(
                    observedSequence: observedSequence,
                    continuation: continuation
                )
            )
        }
    }

    package func supervisionTaskCountForTesting() -> Int {
        receiveTasks.count
    }

    package func isChannelMigrationFlushing() -> Bool {
        !seamlessMigrationPayloads.isEmpty
            || pendingMigrationSourceResumes.values.contains(where: {
                migrationSourceResumeIsCurrent($0)
            })
    }

    package func diagnosticsSnapshot() async -> SpiceSessionDiagnostics {
        var result = retiredDisplayDiagnostics

        let orderedKeys = channels.keys.sorted {
            ($0.type, $0.id) < ($1.type, $1.id)
        }
        for key in orderedKeys {
            guard let channel = channels[key] else { continue }
            guard let display = channel as? DisplayChannel else { continue }
            result.accumulate(await display.diagnosticsSnapshot())
        }

        result.totalIOSurfaceAllocatedBytes = IOSurfaceAllocationBudget.shared.allocatedBytes
        let surfaceBudget = surfaceMemoryBudget.metrics()
        result.surfaceAllocatedBytes = surfaceBudget.allocatedBytes
        result.maximumSurfaceBytes = surfaceBudget.maximumBytes
        return result
    }

    /// Returns a capability bound to the currently connected Inputs transport.
    /// The sender expires on disconnect, failure, or migration rebind.
    public func makeInputSender() throws(SpiceError) -> SpiceInputSender {
        try ensureClientSendsAllowed()
        guard let generation = activeInputGeneration,
              channels[ChannelKey(type: 3, id: 0)] is InputsChannel else {
            throw .protocolError("Inputs Channel is not connected")
        }
        return SpiceInputSender(session: self, generation: generation)
    }

    /// Sends on whichever Inputs generation is current when this actor begins
    /// the call. This convenience API does not preserve generation ownership
    /// for an external queue: queued input from an expired source lifecycle
    /// must be discarded. Recovery-aware queues should retain and validate a
    /// generation-bound ``SpiceInputSender`` instead.
    public func send(_ input: SpiceClientInput) async throws(SpiceError) {
        let sender = try makeInputSender()
        try await sender.send(input)
    }

    func validateInputGeneration(
        _ generation: SpiceInputGeneration
    ) throws(SpiceError) {
        guard activeInputGeneration == generation,
              mainChannel != nil,
              channels[ChannelKey(type: 3, id: 0)] is InputsChannel else {
            throw .inputGenerationExpired
        }
    }

    func send(
        _ input: SpiceClientInput,
        generation: SpiceInputGeneration
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        try validateInputGeneration(generation)
        guard !Task.isCancelled else {
            throw .cancelled
        }

        let key = ChannelKey(type: 3, id: 0)
        guard let inputs = channels[key] as? InputsChannel else {
            throw .protocolError("Inputs Channel is not connected")
        }
        let sessionGeneration = supervisionGeneration
        do {
            try await inputs.send(
                Self.channelInput(input),
                generation: generation.sequence
            )
        } catch let error {
            guard activeInputGeneration == generation else {
                throw .inputGenerationExpired
            }
            if case .transport = error {
                await inputTransportFailed(
                    error,
                    inputGeneration: generation,
                    sessionGeneration: sessionGeneration
                )
            }
            throw Self.map(channelError: error)
        }

        if Task.isCancelled {
            let error = ChannelError.transport(TransportError.cancelled)
            await inputTransportFailed(
                error,
                inputGeneration: generation,
                sessionGeneration: sessionGeneration
            )
            throw .cancelled
        }
        try validateInputGeneration(generation)
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

    package func sendAgentMessage(
        _ message: SpiceAgentMessage,
        priority: AgentOutboundPriority = .normal,
        requiredControl: Bool = false
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        guard let mainChannel else {
            throw .protocolError("Main Channel is not connected")
        }
        do {
            try await mainChannel.sendAgentMessage(
                VDAgentMessage(
                    protocolID: message.protocolID,
                    type: message.type,
                    opaque: message.opaque,
                    data: message.data
                ),
                priority: priority,
                requiredControl: requiredControl
            )
        } catch {
            throw Self.map(channelError: error)
        }
    }

    package func sendAgentMessageJoiningPhysicalTerminal(
        _ message: SpiceAgentMessage,
        priority: AgentOutboundPriority = .normal,
        requiredControl: Bool = false
    ) async throws(SpiceError) {
        try ensureClientSendsAllowed()
        guard let mainChannel else {
            throw .protocolError("Main Channel is not connected")
        }
        do {
            try await mainChannel.sendAgentMessageJoiningPhysicalTerminal(
                VDAgentMessage(
                    protocolID: message.protocolID,
                    type: message.type,
                    opaque: message.opaque,
                    data: message.data
                ),
                priority: priority,
                requiredControl: requiredControl
            )
        } catch {
            throw Self.map(channelError: error)
        }
    }

    package func sendAgentMessageIfTokensAvailable(
        _ message: SpiceAgentMessage
    ) async throws(SpiceError) -> Bool {
        try ensureClientSendsAllowed()
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

    private func beginTeardown() -> Bool {
        guard !isTearingDown else { return false }
        isTearingDown = true
        lifecycleGeneration &+= 1
        migrationAdoptionLifecycleGeneration = nil
        return true
    }

    private func waitForTeardown() async {
        guard isTearingDown else { return }
        await withCheckedContinuation { continuation in
            teardownWaiters.append(continuation)
        }
    }

    private func finishTeardown() {
        isTearingDown = false
        let waiters = teardownWaiters
        teardownWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
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
        channels: [ChannelKey: any SpiceManagedChannel]
    ) async {
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

    private func invalidateSupervisionTasks() {
        supervisionGeneration &+= 1
        let tasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
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
        guard !isTearingDown else {
            throw .cancelled
        }
        guard migrationAdoptionLifecycleGeneration == nil else {
            throw .agentMigrationRebind(partial: false)
        }
        guard seamlessMigrationPayloads.isEmpty else {
            throw .protocolError("channel migration is flushing client messages")
        }
        guard !pendingMigrationSourceResumes.values.contains(where: {
            migrationSourceResumeIsCurrent($0)
        }) else {
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
        guard case let .committing(committingOffer) = migrationCoordinator.state,
              committingOffer.id == offer.id else {
            return
        }
        invalidateMigrationOperation()
        let operationID = claimMigrationOperation(offerID: offer.id)
        await processMigrationActions(actions, generation: generation)
        guard generation == supervisionGeneration,
              ownsMigrationOperation(offerID: offer.id, operationID: operationID) else {
            return
        }

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
            guard let credentials = credentialStorage else {
                throw ChannelError.protocolViolation(
                    "seamless migration lost active credentials"
                )
            }
            // Every source channel has reached its migration boundary and the
            // target payloads have been forwarded.  From here the Main
            // admission pause is the authoritative semantic-send gate; keeping
            // this bookkeeping entry would mask a premature Main resume.
            seamlessMigrationPayloads.removeValue(forKey: offer.id)
            let commit = try await adoptMigrationTarget(
                prepared,
                credentials: credentials,
                policy: .sourceResumable,
                operationContext: MigrationOperationContext(
                    owner: MigrationOperationOwner(
                        offerID: offer.id,
                        operationID: operationID
                    ),
                    observesTaskCancellation: false
                )
            )
            await migrationHandoffCompleted(
                offerID: offer.id,
                operationID: operationID,
                commit: commit
            )
        } catch {
            seamlessMigrationPayloads.removeValue(forKey: offer.id)
            if removedForAdoption {
                await Self.closePrepared(prepared)
            } else if let owned = preparedMigrations.removeValue(forKey: offer.id) {
                await Self.closePrepared(owned)
            }
            if let failure = error as? MigrationAdoptionFailure {
                if !failure.rollbackComplete {
                    await failMigrationAdoption(failure)
                    return
                }
                await migrationOperationFailed(
                    offerID: offer.id,
                    operationID: operationID,
                    operation: .commit,
                    reason: Self.map(channelError: failure.cause).description,
                    generation: failure.supervisionGeneration,
                    expectedLifecycleGeneration: failure.lifecycleGeneration
                )
            } else {
                await receiveFailed(Self.channelError(error), generation: generation)
            }
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
            eventMailbox.send(.frame(SpiceFrame(snapshot)), displayChannelID: key.id)
        case let .surfaceDestroyed(surfaceID):
            eventMailbox.send(.surfaceDestroyed(surfaceID), displayChannelID: key.id)
        case let .cursor(cursorEvent):
            switch cursorEvent {
            case let .initialized(snapshot), let .updated(snapshot), let .reset(snapshot):
                eventMailbox.send(.cursor(SpiceCursorState(snapshot)))
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
                eventMailbox.send(.mouseMode(supported: supported, current: current))
            case let .migration(command):
                let actions = migrationCoordinator.receive(command)
                await processMigrationActions(actions, generation: generation)
            case .agentConnected:
                isAgentConnected = true
                await yieldAgentEvent(.connected, generation: generation)
            case let .agentDisconnected(errorCode):
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
        switch agentEventContinuation.yield(event) {
        case .enqueued:
            break
        case .dropped:
            await receiveFailed(
                .protocolViolation("Agent event buffer overflow"),
                generation: generation
            )
        case .terminated:
            break
        @unknown default:
            await receiveFailed(
                .protocolViolation("unknown Agent event buffer result"),
                generation: generation
            )
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
                invalidateMigrationOperation()
                let cancellation = takeMigrationOfferCancellation(
                    offer,
                    resumeSource: true
                )
                Task { [weak self] in
                    await self?.finishMigrationOfferCancellation(cancellation)
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

    @discardableResult
    private func claimMigrationOperation(offerID: UInt64) -> UInt64 {
        migrationOperationSequence &+= 1
        if migrationOperationSequence == 0 {
            migrationOperationSequence = 1
        }
        let operationID = migrationOperationSequence
        activeMigrationOperation = MigrationOperationOwner(
            offerID: offerID,
            operationID: operationID
        )
        return operationID
    }

    private func ownsMigrationOperation(
        offerID: UInt64,
        operationID: UInt64
    ) -> Bool {
        activeMigrationOperation == MigrationOperationOwner(
            offerID: offerID,
            operationID: operationID
        )
    }

    private func invalidateMigrationOperation() {
        activeMigrationOperation = nil
        migrationTask?.cancel()
        migrationTask = nil
    }

    @discardableResult
    private func finishMigrationOperation(
        offerID: UInt64,
        operationID: UInt64
    ) -> Bool {
        guard ownsMigrationOperation(offerID: offerID, operationID: operationID) else {
            return false
        }
        activeMigrationOperation = nil
        migrationTask = nil
        return true
    }

    private func startMigrationTask(
        offer: SpiceMigrationOffer,
        operation: MigrationOperation,
        generation: UInt64
    ) {
        invalidateMigrationOperation()
        let operationID = claimMigrationOperation(offerID: offer.id)
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
                    await self?.injectedMigrationPreparationCompletionHook?(
                        offer.id,
                        operationID
                    )
                    await self?.migrationPreparationCompleted(
                        offerID: offer.id,
                        operationID: operationID,
                        acceptedSeamless: acceptedSeamless,
                        generation: generation
                    )
                case .commit:
                    let commit: MigrationAdoptionCommit?
                    if let executor {
                        try await executor.commit(offer)
                        commit = nil
                    } else if let self {
                        commit = try await self.commitMigrationTarget(
                            offer,
                            operationID: operationID
                        )
                    } else {
                        return
                    }
                    await self?.migrationHandoffCompleted(
                        offerID: offer.id,
                        operationID: operationID,
                        commit: commit
                    )
                case .switchHost:
                    let commit: MigrationAdoptionCommit?
                    if let executor {
                        try await executor.switchHost(offer)
                        commit = nil
                    } else if let self {
                        commit = try await self.switchMigrationTarget(
                            offer,
                            operationID: operationID
                        )
                    } else {
                        return
                    }
                    await self?.migrationHandoffCompleted(
                        offerID: offer.id,
                        operationID: operationID,
                        commit: commit
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                if let failure = error as? MigrationAdoptionFailure,
                   !failure.rollbackComplete {
                    await self?.failMigrationAdoption(failure)
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.migrationOperationFailed(
                    offerID: offer.id,
                    operationID: operationID,
                    operation: operation,
                    reason: (error as? MigrationAdoptionFailure).map {
                        Self.map(channelError: $0.cause).description
                    } ?? String(describing: error),
                    generation: (error as? MigrationAdoptionFailure)?
                        .supervisionGeneration ?? generation,
                    expectedLifecycleGeneration: (error as? MigrationAdoptionFailure)?
                        .lifecycleGeneration
                )
            }
        }
    }

    private func migrationPreparationCompleted(
        offerID: UInt64,
        operationID: UInt64,
        acceptedSeamless: Bool,
        generation: UInt64
    ) async {
        defer { noteMigrationCallbackAttempt() }
        guard generation == supervisionGeneration,
              finishMigrationOperation(
                  offerID: offerID,
                  operationID: operationID
              ) else { return }
        let actions = migrationCoordinator.preparationCompleted(
            offerID: offerID,
            acceptedSeamless: acceptedSeamless
        )
        await processMigrationActions(actions, generation: generation)
    }

    private func migrationHandoffCompleted(
        offerID: UInt64,
        operationID: UInt64,
        commit: MigrationAdoptionCommit? = nil
    ) async {
        await injectedMigrationCompletionHook?(offerID, operationID)
        defer { noteMigrationCallbackAttempt() }
        guard ownsMigrationOperation(offerID: offerID, operationID: operationID) else {
            return
        }
        if let commit {
            guard commit.lifecycleGeneration == lifecycleGeneration,
                  commit.supervisionGeneration == supervisionGeneration,
                  !isTearingDown else {
                return
            }
        }
        guard finishMigrationOperation(
            offerID: offerID,
            operationID: operationID
        ) else { return }
        let actions = migrationCoordinator.handoffCompleted(offerID: offerID)
        await processMigrationActions(actions, generation: supervisionGeneration)
    }

    private func noteMigrationCallbackAttempt() {
        migrationCallbackAttemptSequence &+= 1
        var pendingWaiters: [MigrationCallbackAttemptWaiter] = []
        for waiter in migrationCallbackAttemptWaiters {
            if waiter.observedSequence == migrationCallbackAttemptSequence {
                pendingWaiters.append(waiter)
            } else {
                waiter.continuation.resume()
            }
        }
        migrationCallbackAttemptWaiters = pendingWaiters
    }

    private func migrationOperationFailed(
        offerID: UInt64,
        operationID: UInt64,
        operation: MigrationOperation,
        reason: String,
        generation: UInt64,
        expectedLifecycleGeneration: UInt64? = nil
    ) async {
        guard ownsMigrationOperation(offerID: offerID, operationID: operationID),
              generation == supervisionGeneration,
              !isTearingDown else { return }
        if let expectedLifecycleGeneration {
            guard expectedLifecycleGeneration == lifecycleGeneration else { return }
        }
        guard finishMigrationOperation(
            offerID: offerID,
            operationID: operationID
        ) else { return }
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

    private func failMigrationAdoption(_ failure: MigrationAdoptionFailure) async {
        guard failure.lifecycleGeneration == lifecycleGeneration else { return }
        // An incomplete rollback is session-fatal even if a newer offer has
        // since claimed normal coordinator ownership.
        invalidateMigrationOperation()
        await receiveFailed(
            failure.cause,
            generation: failure.supervisionGeneration
        )
    }

    private func cancelMigrationHandoff() async {
        invalidateMigrationOperation()
        let actions = migrationCoordinator.disconnect()
        for action in actions {
            if case let .cancel(offer) = action {
                let cancellation = takeMigrationOfferCancellation(
                    offer,
                    resumeSource: false
                )
                await finishMigrationOfferCancellation(cancellation)
            }
        }
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
                    multimediaClock: multimediaClock,
                    surfaceMemoryBudget: surfaceMemoryBudget
                )
            }
            try Task.checkCancellation()
            return (PreparedSession(
                endpoint: endpoint,
                mainChannel: main,
                channels: preparedChannels,
                connections: preparedConnections,
                bootstrap: sourceBootstrap
            ), acceptedSeamless)
        } catch is CancellationError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels
            )
            throw .cancelled
        } catch let error as ChannelError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels
            )
            throw Self.map(channelError: error)
        } catch let error as TransportError {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels
            )
            throw Self.map(transportError: error)
        } catch {
            await Self.closePrepared(
                main: preparedMain,
                transport: transport,
                channels: preparedChannels
            )
            throw .protocolError(String(describing: error))
        }
    }

    private func commitMigrationTarget(
        _ offer: SpiceMigrationOffer,
        operationID: UInt64
    ) async throws -> MigrationAdoptionCommit {
        guard let prepared = preparedMigrations[offer.id],
              let credentials = credentialStorage else {
            throw SpiceError.protocolError("migration target was not prepared")
        }
        try Task.checkCancellation()
        let operationContext = MigrationOperationContext(
            owner: MigrationOperationOwner(
                offerID: offer.id,
                operationID: operationID
            ),
            observesTaskCancellation: true
        )
        let adoptionLifecycleGeneration = try await beginMigrationAdoptionGate()
        var removedForAdoption = false
        do {
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
            // Non-seamless migration has no resumable source boundary.  Close
            // session-level admission before the target END write so source
            // Agent traffic cannot race this irreversible transition.
            try await injectedMigrationTargetEndHook?()
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
            try await prepared.mainChannel.sendMigrationReply(.end)
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
            guard preparedMigrations.removeValue(forKey: offer.id) != nil else {
                throw CancellationError()
            }
            removedForAdoption = true
            return try await adoptMigrationTarget(
                prepared,
                credentials: credentials,
                policy: .failClosed,
                heldGateGeneration: adoptionLifecycleGeneration,
                operationContext: operationContext
            )
        } catch {
            if removedForAdoption {
                await Self.closePrepared(prepared)
            } else if let owned = preparedMigrations.removeValue(forKey: offer.id) {
                await Self.closePrepared(owned)
            }
            if let failure = error as? MigrationAdoptionFailure {
                throw failure
            }
            // Once the non-seamless commit operation owns the gate, every
            // error (including task cancellation or END failure) is fail
            // closed.  Leaving the gate installed blocks writes until
            // failMigrationAdoption tears the session down.
            throw MigrationAdoptionFailure(
                cause: Self.migrationAdoptionChannelError(error),
                rollbackComplete: false,
                lifecycleGeneration: adoptionLifecycleGeneration,
                supervisionGeneration: supervisionGeneration
            )
        }
    }

    private func switchMigrationTarget(
        _ offer: SpiceMigrationOffer,
        operationID: UInt64
    ) async throws -> MigrationAdoptionCommit {
        guard let credentials = credentialStorage else {
            throw SpiceError.protocolError("migration started without active credentials")
        }
        let endpoint = try migrationEndpoint(for: offer)
        let prepared = try await prepareConnection(endpoint: endpoint, credentials: credentials)
        guard !Task.isCancelled else {
            await Self.closePrepared(prepared)
            throw CancellationError()
        }
        guard ownsMigrationOperation(offerID: offer.id, operationID: operationID) else {
            await Self.closePrepared(prepared)
            throw CancellationError()
        }
        do {
            return try await replaceSessionWithTarget(
                prepared,
                credentials: credentials,
                operationContext: MigrationOperationContext(
                    owner: MigrationOperationOwner(
                        offerID: offer.id,
                        operationID: operationID
                    ),
                    observesTaskCancellation: true
                )
            )
        } catch {
            await Self.closePrepared(prepared)
            throw error
        }
    }

    private func adoptMigrationTarget(
        _ prepared: PreparedSession,
        credentials: SpiceCredentialStorage,
        policy: MigrationAdoptionPolicy,
        heldGateGeneration: UInt64? = nil,
        operationContext: MigrationOperationContext
    ) async throws -> MigrationAdoptionCommit {
        try Task.checkCancellation()
        let adoptionLifecycleGeneration: UInt64
        if let heldGateGeneration {
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: heldGateGeneration
            )
            adoptionLifecycleGeneration = heldGateGeneration
        } else {
            adoptionLifecycleGeneration = try await beginMigrationAdoptionGate()
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
        }

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
        guard let mainChannel,
              let targetMainConnection = prepared.connections[mainKey] else {
            throw SpiceError.protocolError("migration lost active Main Channel")
        }

        let sourceConnections = connections
        let sourceEndpoint = currentEndpoint
        let sourceBootstrap = currentBootstrap
        let sourceCredentials = credentialStorage

        // Session-level admission remains closed across every actor hop. Main
        // admission may open only at the final commit await, after which this
        // actor synchronously installs supervision and clears this gate.
        invalidateInputGeneration()
        supervisionGeneration &+= 1
        let oldTasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in oldTasks { task.cancel() }

        var previousConnections: [ChannelKey: ChannelConnection] = [:]
        do {
            try await mainChannel.prepareAgentForMigrationRebind()
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
            try await injectedMigrationReplacementHook?(.applying, mainKey)
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
            previousConnections[mainKey] = try await mainChannel.replaceConnection(
                with: targetMainConnection
            )
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
            for key in channels.keys.sorted(by: Self.channelKeySort) {
                guard let channel = channels[key],
                      let replacement = prepared.connections[key] else {
                    throw ChannelError.protocolViolation(
                        "migration target is missing an active Channel connection"
                    )
                }
                try await injectedMigrationReplacementHook?(.applying, key)
                try ensureMigrationOperationOwnership(
                    operationContext,
                    lifecycleGeneration: adoptionLifecycleGeneration
                )
                previousConnections[key] = try await channel.replaceConnection(
                    with: replacement
                )
                try ensureMigrationOperationOwnership(
                    operationContext,
                    lifecycleGeneration: adoptionLifecycleGeneration
                )
            }

            connections = prepared.connections
            currentEndpoint = prepared.endpoint
            currentBootstrap = prepared.bootstrap
            credentialStorage = credentials
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
            if policy == .failClosed {
                try Task.checkCancellation()
            }
            try await mainChannel.commitAgentMigrationRebind()
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
        } catch {
            if let failure = error as? MigrationAdoptionFailure,
               !failure.rollbackComplete {
                throw failure
            }
            let adoptionError = Self.migrationAdoptionChannelError(error)
            let canResumeSource = policy == .sourceResumable
                && lifecycleGeneration == adoptionLifecycleGeneration
                && !isTearingDown
            guard canResumeSource else {
                invalidateInputGeneration()
                closeConnectionsInBackground(Array(previousConnections.values))
                throw MigrationAdoptionFailure(
                    cause: adoptionError,
                    rollbackComplete: false,
                    lifecycleGeneration: adoptionLifecycleGeneration,
                    supervisionGeneration: supervisionGeneration
                )
            }

            var rollbackError: ChannelError?
            let replacedChannelKeys = previousConnections.keys
                .filter { $0 != mainKey }
                .sorted(by: Self.channelKeySort)
                .reversed()
            for key in replacedChannelKeys {
                guard let previous = previousConnections[key],
                      let channel = channels[key] else {
                    continue
                }
                do {
                    try await injectedMigrationReplacementHook?(.rollingBack, key)
                    try ensureMigrationOperationOwnership(
                        operationContext,
                        lifecycleGeneration: adoptionLifecycleGeneration
                    )
                    _ = try await channel.replaceConnection(with: previous)
                    try ensureMigrationOperationOwnership(
                        operationContext,
                        lifecycleGeneration: adoptionLifecycleGeneration
                    )
                } catch {
                    rollbackError = rollbackError
                        ?? Self.migrationAdoptionChannelError(error)
                }
            }
            var mainRestored = previousConnections[mainKey] == nil
            if let previousMain = previousConnections[mainKey] {
                do {
                    try await injectedMigrationReplacementHook?(.rollingBack, mainKey)
                    try ensureMigrationOperationOwnership(
                        operationContext,
                        lifecycleGeneration: adoptionLifecycleGeneration
                    )
                    _ = try await mainChannel.replaceConnection(with: previousMain)
                    try ensureMigrationOperationOwnership(
                        operationContext,
                        lifecycleGeneration: adoptionLifecycleGeneration
                    )
                    mainRestored = true
                } catch {
                    rollbackError = rollbackError
                        ?? Self.migrationAdoptionChannelError(error)
                }
            }

            var rollbackComplete = rollbackError == nil
                && mainRestored
                && lifecycleGeneration == adoptionLifecycleGeneration
                && !isTearingDown
                && migrationOperationIsCurrent(operationContext)
            if rollbackComplete {
                connections = sourceConnections
                currentEndpoint = sourceEndpoint
                currentBootstrap = sourceBootstrap
                credentialStorage = sourceCredentials
            }

            if rollbackComplete {
                for sourceConnection in sourceConnections.values {
                    await sourceConnection.resumeAfterMigrationCancellation()
                    guard lifecycleGeneration == adoptionLifecycleGeneration,
                          !isTearingDown,
                          migrationOperationIsCurrent(operationContext) else {
                        rollbackComplete = false
                        break
                    }
                }
            }

            if rollbackComplete {
                rollbackComplete = await mainChannel.abortAgentMigrationRebind()
                    && lifecycleGeneration == adoptionLifecycleGeneration
                    && !isTearingDown
                    && migrationOperationIsCurrent(operationContext)
            }

            var restoredInputGeneration: SpiceInputGeneration?
            if rollbackComplete {
                do {
                    restoredInputGeneration = try await prepareInputGeneration(
                        in: channels,
                        expectedLifecycleGeneration: adoptionLifecycleGeneration
                    )
                    try ensureMigrationOperationOwnership(
                        operationContext,
                        lifecycleGeneration: adoptionLifecycleGeneration
                    )
                } catch {
                    rollbackError = rollbackError
                        ?? Self.migrationAdoptionChannelError(error)
                    rollbackComplete = false
                }
            }

            if rollbackComplete {
                startSupervision(mainChannel: mainChannel)
                activeInputGeneration = restoredInputGeneration
                if migrationAdoptionLifecycleGeneration == adoptionLifecycleGeneration {
                    migrationAdoptionLifecycleGeneration = nil
                }
            } else {
                invalidateInputGeneration()
                closeConnectionsInBackground(Array(previousConnections.values))
            }
            let cause: ChannelError
            if let rollbackError, !rollbackComplete {
                cause = .protocolViolation(
                    "migration adoption failed (\(adoptionError)); "
                        + "source rollback incomplete (\(rollbackError))"
                )
            } else {
                cause = adoptionError
            }
            throw MigrationAdoptionFailure(
                cause: cause,
                rollbackComplete: rollbackComplete,
                lifecycleGeneration: adoptionLifecycleGeneration,
                supervisionGeneration: supervisionGeneration
            )
        }

        let targetInputGeneration: SpiceInputGeneration?
        do {
            targetInputGeneration = try await prepareInputGeneration(
                in: channels,
                expectedLifecycleGeneration: adoptionLifecycleGeneration
            )
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
        } catch {
            closeConnectionsInBackground(Array(previousConnections.values))
            throw MigrationAdoptionFailure(
                cause: Self.migrationAdoptionChannelError(error),
                rollbackComplete: false,
                lifecycleGeneration: adoptionLifecycleGeneration,
                supervisionGeneration: supervisionGeneration
            )
        }
        guard lifecycleGeneration == adoptionLifecycleGeneration,
              !isTearingDown,
              migrationAdoptionLifecycleGeneration == adoptionLifecycleGeneration,
              migrationOperationIsCurrent(operationContext) else {
            closeConnectionsInBackground(Array(previousConnections.values))
            throw MigrationAdoptionFailure(
                cause: .transport(.cancelled),
                rollbackComplete: false,
                lifecycleGeneration: adoptionLifecycleGeneration,
                supervisionGeneration: supervisionGeneration
            )
        }
        // No suspension is permitted between publishing the prepared input
        // capability, installing supervision, and reopening the session gate.
        startSupervision(mainChannel: mainChannel)
        activeInputGeneration = targetInputGeneration
        migrationAdoptionLifecycleGeneration = nil
        let commit = MigrationAdoptionCommit(
            lifecycleGeneration: adoptionLifecycleGeneration,
            supervisionGeneration: supervisionGeneration
        )
        closeConnectionsInBackground(Array(previousConnections.values))
        return commit
    }

    private func replaceSessionWithTarget(
        _ prepared: PreparedSession,
        credentials: SpiceCredentialStorage,
        operationContext: MigrationOperationContext
    ) async throws -> MigrationAdoptionCommit {
        try Task.checkCancellation()
        let adoptionLifecycleGeneration = try await beginMigrationAdoptionGate()

        let targetInputGeneration: SpiceInputGeneration?
        do {
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
            let inputsKey = ChannelKey(type: 3, id: 0)
            if prepared.channels[inputsKey] is InputsChannel {
                try await injectedMigrationReplacementHook?(.applying, inputsKey)
                try ensureMigrationOperationOwnership(
                    operationContext,
                    lifecycleGeneration: adoptionLifecycleGeneration
                )
            }
            targetInputGeneration = try await prepareInputGeneration(
                in: prepared.channels,
                expectedLifecycleGeneration: adoptionLifecycleGeneration
            )
            try ensureMigrationOperationOwnership(
                operationContext,
                lifecycleGeneration: adoptionLifecycleGeneration
            )
        } catch let failure as MigrationAdoptionFailure {
            throw failure
        } catch let error {
            throw MigrationAdoptionFailure(
                cause: Self.migrationAdoptionChannelError(error),
                rollbackComplete: false,
                lifecycleGeneration: adoptionLifecycleGeneration,
                supervisionGeneration: supervisionGeneration
            )
        }

        invalidateInputGeneration()
        supervisionGeneration &+= 1
        let oldTasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in oldTasks { task.cancel() }

        let oldMain = mainChannel
        let oldChannels = channels
        let oldAgentConnected = isAgentConnected

        mainChannel = prepared.mainChannel
        channels = prepared.channels
        connections = prepared.connections
        currentEndpoint = prepared.endpoint
        currentBootstrap = prepared.bootstrap
        credentialStorage = credentials
        isAgentConnected = prepared.bootstrap.agentConnected
        // This switch contains no actor suspension after state publication.
        // Supervision, the fresh input capability, and send admission become
        // visible atomically to other session calls.
        startSupervision(mainChannel: prepared.mainChannel)
        activeInputGeneration = targetInputGeneration
        migrationAdoptionLifecycleGeneration = nil
        let commit = MigrationAdoptionCommit(
            lifecycleGeneration: adoptionLifecycleGeneration,
            supervisionGeneration: supervisionGeneration
        )

        if oldAgentConnected {
            agentEventContinuation.yield(.disconnected(errorCode: 0))
        }
        if prepared.bootstrap.agentConnected {
            agentEventContinuation.yield(.connected)
        }
        Self.closeChannelsInBackground(main: oldMain, channels: oldChannels)
        return commit
    }

    private func beginMigrationAdoptionGate() async throws -> UInt64 {
        guard !isTearingDown,
              migrationAdoptionLifecycleGeneration == nil else {
            throw CancellationError()
        }
        let generation = lifecycleGeneration
        migrationAdoptionLifecycleGeneration = generation
        invalidateInputGeneration()
        await invalidateCurrentInputsSendGeneration()
        try ensureMigrationLifecycle(generation)
        guard migrationAdoptionLifecycleGeneration == generation else {
            throw CancellationError()
        }
        return generation
    }

    private func closeConnectionsInBackground(_ values: [ChannelConnection]) {
        Task.detached {
            for connection in values {
                await connection.close()
            }
        }
    }

    private nonisolated static func closeChannelsInBackground(
        main: MainChannel?,
        channels: [ChannelKey: any SpiceManagedChannel]
    ) {
        Task {
            if let main {
                await main.close()
            }
            for key in channels.keys.sorted(by: Self.channelKeySort) {
                await channels[key]?.close()
            }
        }
    }

    private nonisolated static func channelKeySort(
        _ lhs: ChannelKey,
        _ rhs: ChannelKey
    ) -> Bool {
        lhs.type == rhs.type ? lhs.id < rhs.id : lhs.type < rhs.type
    }

    private func takeMigrationOfferCancellation(
        _ offer: SpiceMigrationOffer,
        resumeSource: Bool
    ) -> MigrationOfferCancellation {
        let prepared = preparedMigrations.removeValue(forKey: offer.id)
        let partialPayloads = seamlessMigrationPayloads.removeValue(forKey: offer.id)
        let sourceResume: MigrationSourceResume?
        if resumeSource,
           let partialPayloads,
           let mainChannel {
            let keys = partialPayloads.keys.sorted(by: Self.channelKeySort)
            var sourceConnections: [ChannelKey: ChannelConnection] = [:]
            var sourceChannels: [ChannelKey: any SpiceManagedChannel] = [:]
            for key in keys {
                sourceConnections[key] = connections[key]
                if let channel = channels[key] {
                    sourceChannels[key] = channel
                }
            }
            let resume = MigrationSourceResume(
                lifecycleGeneration: lifecycleGeneration,
                supervisionGeneration: supervisionGeneration,
                mainChannel: mainChannel,
                connections: sourceConnections,
                channels: sourceChannels,
                keys: keys
            )
            // A channel cannot cross another migration boundary until this
            // captured boundary has been resumed and its reader reinstalled.
            // Keep admission closed for the current source while slow target
            // cleanup runs; a published replacement fails the identity guard
            // and is therefore not held behind stale cleanup.
            pendingMigrationSourceResumes[offer.id] = resume
            sourceResume = resume
        } else {
            sourceResume = nil
        }
        return MigrationOfferCancellation(
            offer: offer,
            prepared: prepared,
            sourceResume: sourceResume
        )
    }

    private func finishMigrationOfferCancellation(
        _ cancellation: MigrationOfferCancellation
    ) async {
        defer {
            pendingMigrationSourceResumes.removeValue(forKey: cancellation.offer.id)
            noteMigrationCancellationCompletion()
        }
        if let executor = injectedMigrationExecutor {
            await executor.cancel(cancellation.offer)
        }
        if let prepared = cancellation.prepared {
            await Self.closePrepared(prepared)
        }
        guard let sourceResume = cancellation.sourceResume,
              migrationSourceResumeIsCurrent(sourceResume) else { return }
        let mainKey = ChannelKey(type: 1, id: 0)
        for key in sourceResume.keys {
            guard migrationSourceResumeIsCurrent(sourceResume),
                  let connection = sourceResume.connections[key] else {
                return
            }
            await connection.resumeAfterMigrationCancellation()
            guard migrationSourceResumeIsCurrent(sourceResume) else { return }
            if key == mainKey {
                appendSupervisionTask(
                    for: sourceResume.mainChannel,
                    key: key,
                    generation: sourceResume.supervisionGeneration
                )
            } else if let channel = sourceResume.channels[key] {
                appendSupervisionTask(
                    for: channel,
                    key: key,
                    generation: sourceResume.supervisionGeneration
                )
            }
        }
    }

    private func migrationSourceResumeIsCurrent(
        _ sourceResume: MigrationSourceResume
    ) -> Bool {
        guard lifecycleGeneration == sourceResume.lifecycleGeneration,
              supervisionGeneration == sourceResume.supervisionGeneration,
              mainChannel === sourceResume.mainChannel else {
            return false
        }
        for (key, connection) in sourceResume.connections {
            guard connections[key] === connection else { return false }
        }
        for (key, channel) in sourceResume.channels {
            guard let current = channels[key],
                  ObjectIdentifier(current) == ObjectIdentifier(channel) else {
                return false
            }
        }
        return true
    }

    private func noteMigrationCancellationCompletion() {
        migrationCancellationCompletionSequence &+= 1
        var pendingWaiters: [MigrationCancellationCompletionWaiter] = []
        for waiter in migrationCancellationCompletionWaiters {
            if waiter.observedSequence == migrationCancellationCompletionSequence {
                pendingWaiters.append(waiter)
            } else {
                waiter.continuation.resume()
            }
        }
        migrationCancellationCompletionWaiters = pendingWaiters
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

    private func prepareInputGeneration(
        in channelInventory: [ChannelKey: any SpiceManagedChannel],
        expectedLifecycleGeneration: UInt64
    ) async throws(SpiceError) -> SpiceInputGeneration? {
        inputGenerationSequence &+= 1
        guard let inputs = channelInventory[ChannelKey(type: 3, id: 0)]
            as? InputsChannel else {
            return nil
        }
        let generation = SpiceInputGeneration(
            sessionID: inputSessionIdentity,
            sequence: inputGenerationSequence
        )
        do {
            try await inputs.activateSendGeneration(generation.sequence)
        } catch {
            throw Self.map(channelError: error)
        }
        guard lifecycleGeneration == expectedLifecycleGeneration,
              !isTearingDown else {
            await inputs.invalidateSendGeneration()
            throw .cancelled
        }
        return generation
    }

    private func invalidateInputGeneration() {
        guard activeInputGeneration != nil else { return }
        inputGenerationSequence &+= 1
        activeInputGeneration = nil
    }

    private func invalidateCurrentInputsSendGeneration() async {
        guard let inputs = channels[ChannelKey(type: 3, id: 0)] as? InputsChannel else {
            return
        }
        await inputs.invalidateSendGeneration()
    }

    private func ensureMigrationLifecycle(_ expectedGeneration: UInt64) throws {
        guard lifecycleGeneration == expectedGeneration, !isTearingDown else {
            throw CancellationError()
        }
    }

    private func migrationOperationIsCurrent(
        _ context: MigrationOperationContext
    ) -> Bool {
        ownsMigrationOperation(
            offerID: context.owner.offerID,
            operationID: context.owner.operationID
        ) && (!context.observesTaskCancellation || !Task.isCancelled)
    }

    private func ensureMigrationOperationOwnership(
        _ context: MigrationOperationContext,
        lifecycleGeneration expectedLifecycleGeneration: UInt64
    ) throws {
        guard lifecycleGeneration == expectedLifecycleGeneration,
              !isTearingDown,
              migrationAdoptionLifecycleGeneration == expectedLifecycleGeneration,
              migrationOperationIsCurrent(context) else {
            throw MigrationAdoptionFailure(
                cause: .transport(.cancelled),
                rollbackComplete: false,
                lifecycleGeneration: expectedLifecycleGeneration,
                supervisionGeneration: supervisionGeneration
            )
        }
    }

    private nonisolated static func migrationAdoptionChannelError(
        _ error: any Error
    ) -> ChannelError {
        if let channelError = error as? ChannelError {
            return channelError
        }
        if error is CancellationError {
            return .transport(.cancelled)
        }
        return .protocolViolation(String(describing: error))
    }

    private func inputTransportFailed(
        _ error: ChannelError,
        inputGeneration: SpiceInputGeneration,
        sessionGeneration: UInt64
    ) async {
        guard activeInputGeneration == inputGeneration else { return }
        invalidateInputGeneration()
        await receiveFailed(error, generation: sessionGeneration)
    }

    private func receiveFailed(_ error: ChannelError, generation: UInt64) async {
        guard generation == supervisionGeneration, mainChannel != nil else {
            return
        }
        guard beginTeardown() else {
            await waitForTeardown()
            return
        }
        defer { finishTeardown() }
        supervisionGeneration &+= 1
        invalidateInputGeneration()
        await invalidateCurrentInputsSendGeneration()
        await cancelMigrationHandoff()
        await stopUSBRedirectionHosts()
        await stopWebDAVServers()
        let tasks = receiveTasks
        receiveTasks.removeAll(keepingCapacity: false)
        for task in tasks {
            task.cancel()
        }
        let connectedMainChannel = mainChannel
        mainChannel = nil
        isAgentConnected = false
        if let connectedMainChannel {
            await connectedMainChannel.close()
        }
        await closeChannels()
        connections.removeAll(keepingCapacity: false)
        credentialStorage = nil
        currentEndpoint = nil
        currentBootstrap = nil
        eventMailbox.send(.failed(Self.map(channelError: error)))
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
        multimediaClock: any MultimediaClockScheduling,
        surfaceMemoryBudget: SurfaceMemoryBudget
    ) -> any SpiceManagedChannel {
        switch SpiceChannelKind(rawValue: key.type) {
        case .display:
            DisplayChannel(
                connection: connection,
                surfaces: SurfaceStore(memoryBudget: surfaceMemoryBudget),
                glzDecoder: glzDecoder,
                multimediaClock: multimediaClock
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

    private nonisolated static func map(channelError: ChannelError) -> SpiceError {
        switch channelError {
        case let .transport(error):
            map(transportError: error)
        case let .authentication(error):
            .authenticationFailed(String(describing: error))
        case let .wire(error):
            .protocolError(String(describing: error))
        case let .linkRejected(code):
            .protocolError("link rejected with code \(code)")
        case let .migrationRequested(key, _):
            .protocolError(
                "unexpected migration request on channel type=\(key.type) id=\(key.id)"
            )
        case .cancelledBeforeWrite:
            .cancelled
        case .agentQueueFull:
            .agentQueueFull
        case let .agentCancelled(partial):
            .agentCancelled(partial: partial)
        case .agentDisconnected:
            .agentDisconnected
        case let .agentMessageFailed(partial):
            .agentMessageFailed(partial: partial)
        case let .agentMigrationRebind(partial):
            .agentMigrationRebind(partial: partial)
        case let .agentStalled(partial):
            .agentStalled(partial: partial)
        case .invalidState:
            .protocolError("invalid channel state")
        case .unsupportedCapability:
            .protocolError("unsupported server capability")
        case let .protocolViolation(reason):
            .protocolError(reason)
        }
    }
}
