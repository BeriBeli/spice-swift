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
    private var connection: ChannelConnection
    private let multimediaClock: (any MultimediaClockScheduling)?
    private let agentLimits: VDAgentWireLimits
    private let serverTokenWindow: UInt32
    private var ackController = AckController()
    private var agentDecoder: VDAgentStreamDecoder
    private var isAgentConnected = false
    private var clientAgentTokens: UInt64 = 0
    private var serverAgentTokens: UInt32 = 0
    private var pendingEvents: [MainEvent] = []
    private var pendingAgentBytes = 0

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
        let first = try await receiveDecoded()
        guard case let .mainInit(mainInit) = first else {
            throw .protocolViolation("Main Init must be the first Main Channel message")
        }
        await multimediaClock?.reset(to: mainInit.multimediaTime)
        var bootstrapMultimediaTime = mainInit.multimediaTime

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
                    supportedMouseModes: mainInit.supportedMouseModes,
                    currentMouseMode: mainInit.currentMouseMode,
                    agentConnected: isAgentConnected,
                    channels: list.channels.map { ChannelDescriptor(type: $0.type, id: $0.id) }
                )
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
        resetAgent()
        await connection.close()
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Main Channel")
        }
        let previous = connection
        connection = replacement
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
        guard UInt64(fragments.count) <= clientAgentTokens else {
            return false
        }
        for fragment in fragments {
            try await connection.send(
                messageType: SpiceMainAgentWire.clientData,
                body: fragment
            )
            clientAgentTokens -= 1
        }
        return true
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
            return .mouseMode(supported: mode.supportedModes, current: mode.currentMode)
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
