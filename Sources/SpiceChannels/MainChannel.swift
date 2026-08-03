import Foundation
import SpiceCore
import SpiceProtocol
import SpiceWire

package struct ChannelDescriptor: Sendable, Hashable {
    package let type: UInt8
    package let id: UInt8
}

package struct MainBootstrap: Sendable, Equatable {
    package let sessionID: UInt32
    package let multimediaTime: UInt32
    package let supportedMouseModes: UInt32
    package let currentMouseMode: UInt32
    package let agentConnected: Bool
    package let channels: [ChannelDescriptor]
}

package enum MainEvent: Sendable, Equatable {
    case mouseMode(supported: UInt32, current: UInt32)
    case migration(SpiceMainMigrationCommand)
    case agentConnected
    case agentDisconnected(errorCode: UInt32)
    case agentMessage(VDAgentMessage)
}

package actor MainChannel: SpiceManagedChannel {
    private static let clientMouseMode: UInt16 = 2

    private var connection: ChannelConnection
    private let multimediaClock: (any MultimediaClockScheduling)?
    private let agentLimits: VDAgentWireLimits
    private let serverTokenWindow: UInt32
    private let agentNoProgressTimeout: Duration
    private let agentMigrationTimeout: Duration
    private let agentClock: any AgentOutboundClock
    private var ackController = AckController()
    private var agentDecoder: VDAgentStreamDecoder
    private var isAgentConnected = false
    private var clientAgentTokens: UInt64 = 0
    private var serverAgentTokens: UInt32 = 0
    private var agentScheduler: AgentOutboundScheduler
    private var agentSchedulerGeneration: UInt64 = 1
    private var agentSchedulerPoisoned = false
    private var agentAdmissionPaused = false
    private var agentAdmissionFailure: ChannelError?
    private var isAgentDrainerRunning = false
    private var agentWriteInFlightID: UInt64?
    private var agentPhysicalWriteGeneration: UInt64?
    private var agentWatchdogEpoch: UInt64 = 0
    private var agentWatchdogTask: Task<Void, Never>?
    private var agentMigrationEpoch: UInt64 = 0
    private var agentMigrationTask: Task<Void, Never>?
    private var agentMigrationCompletion:
        (@Sendable (Result<Void, ChannelError>) -> Void)?
    private var pendingEvents: [MainEvent] = []
    private var pendingAgentBytes = 0

    package init(
        connection: ChannelConnection,
        multimediaClock: (any MultimediaClockScheduling)? = nil,
        agentLimits: VDAgentWireLimits = .init(),
        serverTokenWindow: UInt32 = 8,
        agentNoProgressTimeout: Duration = .seconds(15),
        agentMigrationTimeout: Duration = .seconds(3),
        agentClock: any AgentOutboundClock = ContinuousAgentOutboundClock()
    ) {
        self.connection = connection
        self.multimediaClock = multimediaClock
        self.agentLimits = agentLimits
        self.serverTokenWindow = max(1, serverTokenWindow)
        self.agentNoProgressTimeout = max(.milliseconds(1), agentNoProgressTimeout)
        self.agentMigrationTimeout = max(.milliseconds(1), agentMigrationTimeout)
        self.agentClock = agentClock
        agentDecoder = VDAgentStreamDecoder(limits: agentLimits)
        agentScheduler = AgentOutboundScheduler(limits: .init(
            maximumMessageDataBytes: agentLimits.maximumMessageDataBytes
        ))
    }

    package func bootstrap() async throws(ChannelError) -> MainBootstrap {
        let first = try await receiveDecoded()
        guard case let .mainInit(mainInit) = first else {
            throw .protocolViolation("Main Init must be the first Main Channel message")
        }
        await multimediaClock?.reset(to: mainInit.multimediaTime)
        var bootstrapMultimediaTime = mainInit.multimediaTime
        var bootstrapSupportedMouseModes = mainInit.supportedMouseModes
        var bootstrapCurrentMouseMode = mainInit.currentMouseMode

        if mainInit.currentMouseMode != UInt32(Self.clientMouseMode),
           mainInit.supportedMouseModes & UInt32(Self.clientMouseMode) != 0 {
            try await connection.send(SpiceMsgcMainMouseModeRequest(
                mode: Self.clientMouseMode
            ))
        }

        if mainInit.agentConnected != 0 {
            try await startAgent(clientTokens: mainInit.agentTokens)
        }
        try await connection.send(SpiceMsgcMainAttachChannels())

        while true {
            let message = try await receiveDecoded()
            if let agentEvents = try await handleAgent(message) {
                try bufferPending(agentEvents)
                try await acknowledgeIfNeeded()
                continue
            }
            switch message {
            case let .mainChannelsList(list):
                try await acknowledgeIfNeeded()
                return MainBootstrap(
                    sessionID: mainInit.sessionID,
                    multimediaTime: bootstrapMultimediaTime,
                    supportedMouseModes: bootstrapSupportedMouseModes,
                    currentMouseMode: bootstrapCurrentMouseMode,
                    agentConnected: isAgentConnected,
                    channels: list.channels.map { ChannelDescriptor(type: $0.type, id: $0.id) }
                )
            case let .mainMouseMode(mode):
                bootstrapSupportedMouseModes = UInt32(mode.supportedModes)
                bootstrapCurrentMouseMode = UInt32(mode.currentMode)
                try await acknowledgeIfNeeded()
            case let .setAck(setAck):
                ackController.configure(generation: setAck.generation, window: setAck.window)
                try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
            case let .ping(ping):
                try await connection.send(SpiceMsgcPong(id: ping.id, time: ping.time))
                try await acknowledgeIfNeeded()
            case let .mainMultimediaTime(update):
                bootstrapMultimediaTime = update.multimediaTime
                await multimediaClock?.reset(to: update.multimediaTime)
                try await acknowledgeIfNeeded()
            case .disconnecting:
                throw .transport(.connectionClosed)
            case .mainInit:
                throw .protocolViolation("Main Init may only appear once")
            case .mainMigration:
                throw .protocolViolation("migration control received before Main bootstrap completed")
            default:
                try await acknowledgeIfNeeded()
            }
        }
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        while !Task.isCancelled {
            if let event = try await processNext() {
                await emit(.main(event))
            }
        }
    }

    package func close() async {
        resetAgent(failure: .agentDisconnected)
        await connection.close()
    }

    package func prepareAgentForMigrationRebind() async throws(ChannelError) {
        guard isAgentConnected else { return }
        if let agentAdmissionFailure {
            throw agentAdmissionFailure
        }
        guard agentMigrationCompletion == nil else {
            throw .invalidState
        }

        agentAdmissionPaused = true
        let removed = agentScheduler.removeUnstartedForMigration(
            writeInFlightID: agentWriteInFlightID
        )
        complete(removed, with: { _ in .agentMigrationRebind(partial: false) })
        guard !agentScheduler.isIdle else {
            disarmAgentWatchdog()
            return
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                agentMigrationCompletion = { result in
                    continuation.resume(returning: result)
                }
                armAgentMigrationDeadline()
                startAgentDrainerIfNeeded()
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelAgentMigrationDrain()
            }
        }
        if case let .failure(error) = result {
            throw error
        }
    }

    @discardableResult
    package func abortAgentMigrationRebind() -> Bool {
        guard !agentSchedulerPoisoned, agentAdmissionFailure == nil else {
            return false
        }
        guard agentAdmissionPaused else { return true }
        guard agentMigrationCompletion == nil,
              agentScheduler.isIdle,
              agentWriteInFlightID == nil,
              agentPhysicalWriteGeneration == nil else {
            return false
        }
        disarmAgentMigrationDeadline()
        agentSchedulerGeneration &+= 1
        agentAdmissionPaused = false
        agentAdmissionFailure = nil
        return true
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Main Channel")
        }
        guard agentScheduler.isIdle,
              !isAgentDrainerRunning,
              agentPhysicalWriteGeneration == nil else {
            throw .invalidState
        }
        let previous = connection
        connection = replacement
        if agentAdmissionPaused {
            agentSchedulerGeneration &+= 1
            agentAdmissionPaused = false
            agentAdmissionFailure = nil
            disarmAgentMigrationDeadline()
        }
        return previous
    }

    package func sendAgentMessage(
        _ message: VDAgentMessage,
        priority: AgentOutboundPriority = .normal,
        requiredControl: Bool = false
    ) async throws(ChannelError) {
        let payload = try encodeAgentMessage(message)
        let result = await enqueueAgentMessage(
            payload,
            priority: priority,
            requiredControl: requiredControl
        )
        if case let .failure(error) = result {
            throw error
        }
    }

    package func sendAgentMessageIfTokensAvailable(
        _ message: VDAgentMessage,
        priority: AgentOutboundPriority = .low
    ) async throws(ChannelError) -> Bool {
        let payload = try encodeAgentMessage(message)
        guard agentScheduler.isIdle,
              UInt64(payload.fragmentCount) <= clientAgentTokens else {
            return false
        }
        let result = await enqueueAgentMessage(
            payload,
            priority: priority,
            requiredControl: false
        )
        if case let .failure(error) = result {
            throw error
        }
        return true
    }

    package func pendingAgentMessageCount() -> Int {
        agentScheduler.pendingCount
    }

    private func encodeAgentMessage(
        _ message: VDAgentMessage
    ) throws(ChannelError) -> VDAgentWireEncoder.EncodedMessage {
        guard isAgentConnected else {
            throw .agentDisconnected
        }
        if let agentAdmissionFailure {
            throw agentAdmissionFailure
        }
        guard !agentAdmissionPaused else {
            throw .agentMigrationRebind(partial: false)
        }
        do {
            return try VDAgentWireEncoder.encode(message, limits: agentLimits)
        } catch let error {
            throw .wire(error)
        }
    }

    private func enqueueAgentMessage(
        _ payload: VDAgentWireEncoder.EncodedMessage,
        priority: AgentOutboundPriority,
        requiredControl: Bool
    ) async -> Result<Void, ChannelError> {
        let requestID = agentScheduler.allocateID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let result = agentScheduler.enqueue(
                    id: requestID,
                    payload: payload,
                    priority: priority,
                    requiredControl: requiredControl,
                    completion: { result in
                        continuation.resume(returning: result)
                    }
                )
                switch result {
                case .accepted:
                    startAgentDrainerIfNeeded()
                case .queueFull:
                    continuation.resume(returning: .failure(.agentQueueFull))
                case .requiredControlCannotFit:
                    terminateAgentGeneration(
                        poison: true,
                        admissionFailure: .agentQueueFull,
                        writeInFlightCountsAsStarted: true,
                        error: { _ in .agentQueueFull }
                    )
                    isAgentConnected = false
                    continuation.resume(returning: .failure(.agentQueueFull))
                    Task { [connection] in
                        await connection.close()
                    }
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.cancelAgentRequest(id: requestID)
            }
        }
    }

    private func cancelAgentRequest(id: UInt64) {
        switch agentScheduler.cancel(id: id, writeInFlightID: agentWriteInFlightID) {
        case let .removed(completion):
            completion(.failure(.agentCancelled(partial: false)))
            if agentScheduler.isIdle {
                disarmAgentWatchdog()
            }
            startAgentDrainerIfNeeded()
            finishAgentMigrationDrainIfReady()
        case let .detached(completion):
            completion(.failure(.agentCancelled(partial: true)))
        case .notFound:
            break
        }
    }

    private func startAgentDrainerIfNeeded() {
        guard isAgentConnected,
              !agentSchedulerPoisoned,
              !agentScheduler.isIdle,
              agentPhysicalWriteGeneration == nil,
              !isAgentDrainerRunning else {
            return
        }
        isAgentDrainerRunning = true
        let generation = agentSchedulerGeneration
        Task { [weak self] in
            await self?.drainAgentMessages(generation: generation)
        }
    }

    private func drainAgentMessages(generation: UInt64) async {
        defer {
            if generation == agentSchedulerGeneration {
                isAgentDrainerRunning = false
            }
        }
        while generation == agentSchedulerGeneration,
              isAgentConnected,
              !agentSchedulerPoisoned {
            let previousActiveID = agentScheduler.activeID
            guard let activeID = agentScheduler.activateNextIfNeeded() else {
                disarmAgentWatchdog()
                return
            }
            if previousActiveID == nil {
                armAgentWatchdog(activeID: activeID)
            }
            guard clientAgentTokens > 0 else {
                return
            }
            guard let fragment = agentScheduler.activeFragment(),
                  fragment.id == activeID else {
                terminateAgentGeneration(
                    poison: true,
                    admissionFailure: .invalidState,
                    writeInFlightCountsAsStarted: true,
                    error: { _ in .invalidState }
                )
                isAgentConnected = false
                await connection.close()
                return
            }

            // Reserve before the suspension point. Actor reentrancy can no
            // longer let another caller observe and spend this token.
            clientAgentTokens -= 1
            agentWriteInFlightID = activeID
            agentPhysicalWriteGeneration = generation
            do {
                try await connection.send(
                    messageType: SpiceMainAgentWire.clientData,
                    body: fragment.data
                )
            } catch {
                if agentPhysicalWriteGeneration == generation {
                    agentPhysicalWriteGeneration = nil
                }
                guard generation == agentSchedulerGeneration else { return }
                agentWriteInFlightID = nil
                let partial = agentScheduler.activeHasWrittenFragment
                terminateAgentGeneration(
                    poison: true,
                    admissionFailure: .agentMessageFailed(partial: partial),
                    writeInFlightCountsAsStarted: false,
                    error: { .agentMessageFailed(partial: $0) }
                )
                isAgentConnected = false
                await connection.close()
                return
            }
            if agentPhysicalWriteGeneration == generation {
                agentPhysicalWriteGeneration = nil
            }
            guard generation == agentSchedulerGeneration,
                  agentScheduler.activeID == activeID else {
                return
            }
            agentWriteInFlightID = nil
            switch agentScheduler.didWriteFragment(id: activeID) {
            case let .completed(completion):
                disarmAgentWatchdog()
                completion?(.success(()))
                finishAgentMigrationDrainIfReady()
            case .inProgress:
                armAgentWatchdog(activeID: activeID)
            case .notActive:
                terminateAgentGeneration(
                    poison: true,
                    admissionFailure: .invalidState,
                    writeInFlightCountsAsStarted: true,
                    error: { _ in .invalidState }
                )
                isAgentConnected = false
                await connection.close()
                return
            }
        }
    }

    private func armAgentWatchdog(activeID: UInt64) {
        agentWatchdogTask?.cancel()
        agentWatchdogEpoch &+= 1
        let epoch = agentWatchdogEpoch
        let generation = agentSchedulerGeneration
        let timeout = agentNoProgressTimeout
        let clock = agentClock
        agentWatchdogTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.agentWatchdogExpired(
                generation: generation,
                activeID: activeID,
                epoch: epoch
            )
        }
    }

    private func disarmAgentWatchdog() {
        agentWatchdogTask?.cancel()
        agentWatchdogTask = nil
        agentWatchdogEpoch &+= 1
    }

    private func agentWatchdogExpired(
        generation: UInt64,
        activeID: UInt64,
        epoch: UInt64
    ) async {
        guard generation == agentSchedulerGeneration,
              epoch == agentWatchdogEpoch,
              agentScheduler.activeID == activeID else {
            return
        }
        let partial = agentScheduler.activeHasWrittenFragment
            || agentWriteInFlightID == activeID
        terminateAgentGeneration(
            poison: true,
            admissionFailure: .agentStalled(partial: partial),
            writeInFlightCountsAsStarted: true,
            error: { .agentStalled(partial: $0) }
        )
        isAgentConnected = false
        await connection.close()
    }

    private func terminateAgentGeneration(
        poison: Bool,
        admissionFailure: ChannelError?,
        writeInFlightCountsAsStarted: Bool,
        error: (Bool) -> ChannelError
    ) {
        let migrationCompletion = agentMigrationCompletion
        agentMigrationCompletion = nil
        agentSchedulerGeneration &+= 1
        agentSchedulerPoisoned = poison
        agentAdmissionFailure = poison ? admissionFailure : nil
        isAgentDrainerRunning = false
        let writeInFlightID = writeInFlightCountsAsStarted
            ? agentWriteInFlightID
            : nil
        agentWriteInFlightID = nil
        disarmAgentWatchdog()
        disarmAgentMigrationDeadline()
        let removed = agentScheduler.removeAll(writeInFlightID: writeInFlightID)
        complete(removed, with: error)
        if let migrationCompletion {
            migrationCompletion(.failure(admissionFailure ?? .agentDisconnected))
        }
    }

    private func complete(
        _ removed: [AgentOutboundScheduler.RemovedRequest],
        with error: (Bool) -> ChannelError
    ) {
        for request in removed {
            request.completion?(.failure(error(request.hasStarted)))
        }
    }

    private func finishAgentMigrationDrainIfReady() {
        guard agentAdmissionPaused,
              agentScheduler.isIdle,
              agentWriteInFlightID == nil,
              let completion = agentMigrationCompletion else {
            return
        }
        agentMigrationCompletion = nil
        disarmAgentMigrationDeadline()
        completion(.success(()))
    }

    private func armAgentMigrationDeadline() {
        agentMigrationTask?.cancel()
        agentMigrationEpoch &+= 1
        let epoch = agentMigrationEpoch
        let generation = agentSchedulerGeneration
        let timeout = agentMigrationTimeout
        let clock = agentClock
        agentMigrationTask = Task { [weak self] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            await self?.agentMigrationDeadlineExpired(
                generation: generation,
                epoch: epoch
            )
        }
    }

    private func disarmAgentMigrationDeadline() {
        agentMigrationTask?.cancel()
        agentMigrationTask = nil
        agentMigrationEpoch &+= 1
    }

    private func agentMigrationDeadlineExpired(
        generation: UInt64,
        epoch: UInt64
    ) async {
        guard generation == agentSchedulerGeneration,
              epoch == agentMigrationEpoch,
              agentMigrationCompletion != nil else {
            return
        }
        let partial = agentScheduler.activeHasWrittenFragment
            || agentScheduler.activeID.map { agentWriteInFlightID == $0 } == true
        terminateAgentGeneration(
            poison: true,
            admissionFailure: .agentMigrationRebind(partial: partial),
            writeInFlightCountsAsStarted: true,
            error: { .agentMigrationRebind(partial: $0) }
        )
        isAgentConnected = false
        await connection.close()
    }

    private func cancelAgentMigrationDrain() async {
        guard agentMigrationCompletion != nil else { return }
        let partial = agentScheduler.activeHasWrittenFragment
            || agentScheduler.activeID.map { agentWriteInFlightID == $0 } == true
        terminateAgentGeneration(
            poison: true,
            admissionFailure: .agentMigrationRebind(partial: partial),
            writeInFlightCountsAsStarted: true,
            error: { .agentMigrationRebind(partial: $0) }
        )
        isAgentConnected = false
        await connection.close()
    }

    package func sendMigrationReply(
        _ reply: SpiceMainMigrationReply
    ) async throws(ChannelError) {
        let encoded = SpiceMainMigrationCodec.encode(reply)
        try await connection.send(messageType: encoded.id, body: encoded.body)
    }

    package func negotiateDestinationSeamless(
        sourceVersion: UInt32
    ) async throws(ChannelError) -> Bool {
        try await sendMigrationReply(.destinationDoSeamless(sourceVersion: sourceVersion))
        let reply = try await receiveDecoded()
        switch reply {
        case .mainMigration(.destinationSeamlessAccepted):
            return true
        case .mainMigration(.destinationSeamlessRejected):
            return false
        default:
            throw .protocolViolation(
                "destination seamless negotiation expected ACK or NACK"
            )
        }
    }

    private func processNext() async throws(ChannelError) -> MainEvent? {
        if !pendingEvents.isEmpty {
            return removeFirstPendingEvent()
        }
        let message = try await receiveDecoded()
        if let agentEvents = try await handleAgent(message) {
            try bufferPending(agentEvents)
            try await acknowledgeIfNeeded()
            return pendingEvents.isEmpty ? nil : removeFirstPendingEvent()
        }
        switch message {
        case let .mainMouseMode(mode):
            try await acknowledgeIfNeeded()
            return .mouseMode(
                supported: UInt32(mode.supportedModes),
                current: UInt32(mode.currentMode)
            )
        case let .mainMultimediaTime(update):
            await multimediaClock?.reset(to: update.multimediaTime)
            try await acknowledgeIfNeeded()
            return nil
        case let .setAck(setAck):
            ackController.configure(generation: setAck.generation, window: setAck.window)
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
            return nil
        case let .ping(ping):
            try await connection.send(SpiceMsgcPong(id: ping.id, time: ping.time))
            try await acknowledgeIfNeeded()
            return nil
        case .disconnecting:
            throw .transport(.connectionClosed)
        case .mainInit:
            throw .protocolViolation("Main Init may only appear once")
        case let .mainMigration(command):
            try await acknowledgeIfNeeded()
            return .migration(command)
        default:
            try await acknowledgeIfNeeded()
            return nil
        }
    }

    private func handleAgent(
        _ message: SpiceServerMessage
    ) async throws(ChannelError) -> [MainEvent]? {
        switch message {
        case let .mainAgentConnected(tokens):
            guard !isAgentConnected else {
                throw .protocolViolation("duplicate agent connected message")
            }
            try await startAgent(clientTokens: tokens ?? 0)
            return [.agentConnected]
        case let .mainAgentDisconnected(errorCode):
            guard isAgentConnected else {
                throw .protocolViolation("agent disconnected message while already disconnected")
            }
            resetAgent(failure: .agentDisconnected)
            return [.agentDisconnected(errorCode: errorCode)]
        case let .mainAgentToken(tokens):
            guard isAgentConnected else {
                throw .protocolViolation("agent tokens received while agent is disconnected")
            }
            let (updated, overflow) = clientAgentTokens.addingReportingOverflow(UInt64(tokens))
            guard !overflow else {
                throw .protocolViolation("client agent token count overflow")
            }
            clientAgentTokens = updated
            if tokens > 0, let activeID = agentScheduler.activeID {
                armAgentWatchdog(activeID: activeID)
            }
            startAgentDrainerIfNeeded()
            return []
        case let .mainAgentData(packet):
            guard isAgentConnected else {
                throw .protocolViolation("agent data received while agent is disconnected")
            }
            guard serverAgentTokens > 0 else {
                throw .protocolViolation("server exceeded allocated agent tokens")
            }
            serverAgentTokens -= 1
            let messages: [VDAgentMessage]
            do {
                messages = try agentDecoder.append(packet: packet)
            } catch let error {
                throw .wire(error)
            }
            try await sendAgentTokens(1)
            return messages.map(MainEvent.agentMessage)
        default:
            return nil
        }
    }

    private func startAgent(clientTokens: UInt32) async throws(ChannelError) {
        guard agentPhysicalWriteGeneration == nil else {
            throw .protocolViolation(
                "agent reconnected while a previous generation write was still in flight"
            )
        }
        var writer = ByteWriter(capacity: MemoryLayout<UInt32>.size)
        writer.writeUInt32LE(serverTokenWindow)
        try await connection.send(
            messageType: SpiceMainAgentWire.clientStart,
            body: writer.data
        )
        isAgentConnected = true
        clientAgentTokens = UInt64(clientTokens)
        serverAgentTokens = serverTokenWindow
        agentSchedulerPoisoned = false
        agentAdmissionPaused = false
        agentAdmissionFailure = nil
        disarmAgentMigrationDeadline()
        agentSchedulerGeneration &+= 1
        agentDecoder.reset()
    }

    private func sendAgentTokens(_ count: UInt32) async throws(ChannelError) {
        let (updated, overflow) = serverAgentTokens.addingReportingOverflow(count)
        guard !overflow else {
            throw .protocolViolation("server agent token count overflow")
        }
        var writer = ByteWriter(capacity: MemoryLayout<UInt32>.size)
        writer.writeUInt32LE(count)
        try await connection.send(
            messageType: SpiceMainAgentWire.clientToken,
            body: writer.data
        )
        serverAgentTokens = updated
    }

    private func resetAgent(failure: ChannelError) {
        terminateAgentGeneration(
            poison: false,
            admissionFailure: nil,
            writeInFlightCountsAsStarted: true,
            error: { _ in failure }
        )
        agentAdmissionPaused = false
        isAgentConnected = false
        clientAgentTokens = 0
        serverAgentTokens = 0
        agentDecoder.reset()
    }

    private func bufferPending(_ events: [MainEvent]) throws(ChannelError) {
        guard events.count <= 64 - pendingEvents.count else {
            throw .protocolViolation("too many Agent events before delivery")
        }
        var additionalBytes = 0
        for event in events {
            if case let .agentMessage(message) = event {
                let (updated, overflow) = additionalBytes.addingReportingOverflow(
                    message.data.count
                )
                guard !overflow else {
                    throw .protocolViolation("pending Agent data size overflow")
                }
                additionalBytes = updated
            }
        }
        guard additionalBytes <= agentLimits.maximumMessageDataBytes - pendingAgentBytes else {
            throw .protocolViolation("pending Agent data exceeds configured limit")
        }
        pendingAgentBytes += additionalBytes
        pendingEvents.append(contentsOf: events)
    }

    private func removeFirstPendingEvent() -> MainEvent {
        let event = pendingEvents.removeFirst()
        if case let .agentMessage(message) = event {
            pendingAgentBytes -= message.data.count
        }
        return event
    }

    private func receiveDecoded() async throws(ChannelError) -> SpiceServerMessage {
        let framed = try await connection.receive()
        do {
            return try SpiceServerMessageDecoder.decode(
                id: framed.type,
                body: framed.body,
                channel: .main
            )
        } catch let error {
            throw .wire(error)
        }
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        if ackController.didProcessMessage() {
            try await connection.send(SpiceMsgcAck())
        }
    }
}
