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
    private struct MouseModeState: Equatable {
        let supported: UInt32
        let current: UInt32
    }

    private struct AgentSendTicket: Equatable {
        let sequence: UInt64
        let generation: UInt64
    }

    private enum AgentSendTurn: Sendable {
        case acquired
        case invalidated
        case cancelled
    }

    private struct AgentSendWaiter {
        let ticket: AgentSendTicket
        let continuation: CheckedContinuation<AgentSendTurn, Never>
    }

    private var connection: ChannelConnection
    private let multimediaClock: (any MultimediaClockScheduling)?
    private let agentLimits: VDAgentWireLimits
    private let serverTokenWindow: UInt32
    private var agentDecoder: VDAgentStreamDecoder
    private var isAgentConnected = false
    private var agentGeneration: UInt64 = 0
    private var clientAgentTokens: UInt64 = 0
    private var serverAgentTokens: UInt32 = 0
    private var nextAgentSendSequence: UInt64 = 0
    private var activeAgentSendTicket: AgentSendTicket?
    private var pendingAgentSendWaiters: [AgentSendWaiter] = []
    private var pendingEvents: [MainEvent] = []
    private var pendingAgentBytes = 0
    private var lastClientMouseModeRequest: MouseModeState?

    package init(
        connection: ChannelConnection,
        multimediaClock: (any MultimediaClockScheduling)? = nil,
        agentLimits: VDAgentWireLimits = .init(),
        serverTokenWindow: UInt32 = 8
    ) {
        self.connection = connection
        self.multimediaClock = multimediaClock
        self.agentLimits = agentLimits
        self.serverTokenWindow = max(1, serverTokenWindow)
        agentDecoder = VDAgentStreamDecoder(limits: agentLimits)
    }

    package func bootstrap() async throws(ChannelError) -> MainBootstrap {
        let activeConnection = connection
        do {
            return try await bootstrapImpl()
        } catch let error {
            if connection === activeConnection {
                await activeConnection.fail(error)
            }
            throw error
        }
    }

    private func bootstrapImpl() async throws(ChannelError) -> MainBootstrap {
        let first = try await receiveDecoded()
        guard case let .mainInit(mainInit) = first else {
            throw .protocolViolation("Main Init must be the first Main Channel message")
        }
        await multimediaClock?.reset(to: mainInit.multimediaTime)
        var bootstrapMultimediaTime = mainInit.multimediaTime
        var bootstrapSupportedMouseModes = mainInit.supportedMouseModes
        var bootstrapCurrentMouseMode = mainInit.currentMouseMode

        try await requestClientMouseModeIfNeeded(
            supported: mainInit.supportedMouseModes,
            current: mainInit.currentMouseMode
        )

        if mainInit.agentConnected != 0 {
            try await startAgent(clientTokens: mainInit.agentTokens)
        }
        try await connection.send(SpiceMsgcMainAttachChannels())
        try await acknowledgeIfNeeded()

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
                try await requestClientMouseModeIfNeeded(
                    supported: bootstrapSupportedMouseModes,
                    current: bootstrapCurrentMouseMode
                )
                try await acknowledgeIfNeeded()
            case let .setAck(setAck):
                await connection.configureAcknowledgments(
                    generation: setAck.generation,
                    window: setAck.window
                )
                try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
                try await acknowledgeIfNeeded()
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
        let runConnection = connection
        while !Task.isCancelled {
            if let event = try await processNext() {
                await emit(.main(event))
            }
        }
        if connection === runConnection {
            await runConnection.fail(.transport(.cancelled))
        }
    }

    package func close() async {
        resetAgent()
        await connection.close()
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) async throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Main Channel")
        }
        let previous = connection
        try await replacement.activate()
        await previous.supersede(
            preservingSerialBarrier: previous.sharesSerialBarrier(with: replacement)
        )
        connection = replacement
        lastClientMouseModeRequest = nil
        return previous
    }

    package func sendAgentMessage(_ message: VDAgentMessage) async throws(ChannelError) {
        guard try await sendAgentMessageIfTokensAvailable(message) else {
            let fragments: [Data]
            do {
                fragments = try VDAgentWireEncoder.fragments(for: message, limits: agentLimits)
            } catch let error {
                throw .wire(error)
            }
            throw .protocolViolation(
                "agent message needs \(fragments.count) tokens but only \(clientAgentTokens) are available"
            )
        }
    }

    package func sendAgentMessageIfTokensAvailable(
        _ message: VDAgentMessage
    ) async throws(ChannelError) -> Bool {
        guard isAgentConnected else {
            throw .protocolViolation("agent message sent while agent is disconnected")
        }
        let fragments: [Data]
        do {
            fragments = try VDAgentWireEncoder.fragments(for: message, limits: agentLimits)
        } catch let error {
            throw .wire(error)
        }
        let requiredTokens = UInt64(fragments.count)
        guard requiredTokens <= clientAgentTokens else {
            return false
        }
        // Reserve the complete message before the first suspension point.
        // MainChannel is reentrant while ChannelConnection sends, so checking
        // and decrementing one fragment at a time can overcommit the same token
        // window when two Agent producers run concurrently.
        let messageAgentGeneration = agentGeneration
        clientAgentTokens -= requiredTokens
        var unsentReservedTokens = requiredTokens
        var sentFragmentCount: UInt64 = 0
        let ticket = AgentSendTicket(
            sequence: nextAgentSendSequence,
            generation: messageAgentGeneration
        )
        nextAgentSendSequence &+= 1
        do {
            switch await acquireAgentSendTurn(for: ticket) {
            case .acquired:
                break
            case .invalidated:
                throw ChannelError.protocolViolation(
                    "agent lifecycle changed during message send"
                )
            case .cancelled:
                throw ChannelError.transport(.cancelled)
            }
            defer { releaseAgentSendTurn(for: ticket) }

            guard !Task.isCancelled else {
                throw ChannelError.transport(.cancelled)
            }
            guard agentGeneration == messageAgentGeneration else {
                throw ChannelError.protocolViolation(
                    "agent lifecycle changed during message send"
                )
            }
            // A seamless rebind may happen while this message is queued. Capture
            // the connection only after obtaining the turn, then keep every
            // fragment of this message on that same connection.
            let messageConnection = connection
            for fragment in fragments {
                guard agentGeneration == messageAgentGeneration else {
                    throw ChannelError.protocolViolation(
                        "agent lifecycle changed during message send"
                    )
                }
                try await messageConnection.send(
                    messageType: SpiceMainAgentWire.clientData,
                    body: fragment,
                    // The complete message reserved its tokens and captured
                    // this connection before rebind. Its suffix must remain on
                    // the same byte stream even after that connection becomes
                    // superseded; new sends retain the default rejection.
                    allowSupersededSend: true
                )
                unsentReservedTokens -= 1
                sentFragmentCount += 1
                guard agentGeneration == messageAgentGeneration else {
                    throw ChannelError.protocolViolation(
                        "agent lifecycle changed during message send"
                    )
                }
            }
        } catch {
            let channelError = error as? ChannelError ?? .invalidState
            if sentFragmentCount > 0,
               unsentReservedTokens > 0,
               agentGeneration == messageAgentGeneration {
                // VDAgent messages form one byte stream across clientData
                // packets. Once a prefix is on the wire, another message may
                // not follow the missing suffix without corrupting the peer's
                // decoder. Invalidate this Agent epoch before suspending so a
                // resumed FIFO waiter cannot write, then make the Main
                // connection fail closed and let session supervision recover.
                let connectionToClose = connection
                resetAgent()
                await connectionToClose.close()
            } else if sentFragmentCount == 0,
                      agentGeneration == messageAgentGeneration {
                let (restoredTokens, overflow) = clientAgentTokens.addingReportingOverflow(
                    unsentReservedTokens
                )
                guard !overflow else {
                    throw .protocolViolation("agent token accounting overflow after send failure")
                }
                clientAgentTokens = restoredTokens
            }
            throw channelError
        }
        return true
    }

    func pendingAgentSendCountForTesting() -> Int {
        pendingAgentSendWaiters.count
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
        let activeConnection = connection
        do {
            return try await negotiateDestinationSeamlessImpl(sourceVersion: sourceVersion)
        } catch let error {
            if connection === activeConnection {
                await activeConnection.fail(error)
            }
            throw error
        }
    }

    private func negotiateDestinationSeamlessImpl(
        sourceVersion: UInt32
    ) async throws(ChannelError) -> Bool {
        try await sendMigrationReply(.destinationDoSeamless(sourceVersion: sourceVersion))
        let reply = try await receiveDecoded()
        switch reply {
        case .mainMigration(.destinationSeamlessAccepted):
            try await acknowledgeIfNeeded()
            return true
        case .mainMigration(.destinationSeamlessRejected):
            try await acknowledgeIfNeeded()
            return false
        default:
            throw .protocolViolation(
                "destination seamless negotiation expected ACK or NACK"
            )
        }
    }

    private func processNext() async throws(ChannelError) -> MainEvent? {
        let activeConnection = connection
        do {
            return try await processNextImpl()
        } catch let error {
            if connection === activeConnection {
                await activeConnection.fail(error)
            }
            throw error
        }
    }

    private func processNextImpl() async throws(ChannelError) -> MainEvent? {
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
            let supported = UInt32(mode.supportedModes)
            let current = UInt32(mode.currentMode)
            try await requestClientMouseModeIfNeeded(
                supported: supported,
                current: current
            )
            try await acknowledgeIfNeeded()
            return .mouseMode(
                supported: supported,
                current: current
            )
        case let .mainMultimediaTime(update):
            await multimediaClock?.reset(to: update.multimediaTime)
            try await acknowledgeIfNeeded()
            return nil
        case let .setAck(setAck):
            await connection.configureAcknowledgments(
                generation: setAck.generation,
                window: setAck.window
            )
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
            try await acknowledgeIfNeeded()
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

    private func requestClientMouseModeIfNeeded(
        supported: UInt32,
        current: UInt32
    ) async throws(ChannelError) {
        let clientMode = UInt32(Self.clientMouseMode)
        guard current != clientMode, supported & clientMode != 0 else {
            lastClientMouseModeRequest = nil
            return
        }

        let state = MouseModeState(supported: supported, current: current)
        guard lastClientMouseModeRequest != state else {
            return
        }

        try await connection.send(SpiceMsgcMainMouseModeRequest(
            mode: Self.clientMouseMode
        ))
        lastClientMouseModeRequest = state
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
            resetAgent()
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
        var writer = ByteWriter(capacity: MemoryLayout<UInt32>.size)
        writer.writeUInt32LE(serverTokenWindow)
        try await connection.send(
            messageType: SpiceMainAgentWire.clientStart,
            body: writer.data
        )
        advanceAgentGeneration()
        isAgentConnected = true
        clientAgentTokens = UInt64(clientTokens)
        serverAgentTokens = serverTokenWindow
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

    private func resetAgent() {
        isAgentConnected = false
        advanceAgentGeneration()
        clientAgentTokens = 0
        serverAgentTokens = 0
        agentDecoder.reset()
    }

    private func acquireAgentSendTurn(for ticket: AgentSendTicket) async -> AgentSendTurn {
        guard !Task.isCancelled else { return .cancelled }
        guard isAgentConnected, ticket.generation == agentGeneration else {
            return .invalidated
        }
        guard activeAgentSendTicket != nil else {
            activeAgentSendTicket = ticket
            return .acquired
        }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: .cancelled)
                } else if !isAgentConnected || ticket.generation != agentGeneration {
                    continuation.resume(returning: .invalidated)
                } else if activeAgentSendTicket == nil {
                    activeAgentSendTicket = ticket
                    continuation.resume(returning: .acquired)
                } else {
                    pendingAgentSendWaiters.append(AgentSendWaiter(
                        ticket: ticket,
                        continuation: continuation
                    ))
                }
            }
        } onCancel: {
            Task { await self.cancelAgentSendWait(for: ticket) }
        }
    }

    private func cancelAgentSendWait(for ticket: AgentSendTicket) {
        guard let index = pendingAgentSendWaiters.firstIndex(where: {
            $0.ticket == ticket
        }) else {
            return
        }
        pendingAgentSendWaiters.remove(at: index).continuation.resume(
            returning: .cancelled
        )
    }

    private func releaseAgentSendTurn(for ticket: AgentSendTicket) {
        guard activeAgentSendTicket == ticket else { return }
        activeAgentSendTicket = nil

        while !pendingAgentSendWaiters.isEmpty {
            let waiter = pendingAgentSendWaiters.removeFirst()
            guard isAgentConnected, waiter.ticket.generation == agentGeneration else {
                waiter.continuation.resume(returning: .invalidated)
                continue
            }
            activeAgentSendTicket = waiter.ticket
            waiter.continuation.resume(returning: .acquired)
            return
        }
    }

    private func advanceAgentGeneration() {
        agentGeneration &+= 1
        activeAgentSendTicket = nil
        let waiters = pendingAgentSendWaiters
        pendingAgentSendWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(returning: .invalidated)
        }
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
        try await connection.acknowledgeLastDelivered()
    }
}
