import Foundation
import SpiceCore
import SpiceProtocol

package struct CursorSnapshot: Sendable, Equatable {
    package let position: SpiceCursorPosition
    package let visible: Bool
    package let cursor: SpiceCursorPayload?
    package let trailLength: UInt16
    package let trailFrequency: UInt16
}

package enum CursorEvent: Sendable, Equatable {
    case initialized(CursorSnapshot)
    case updated(CursorSnapshot)
    case reset(CursorSnapshot)
    case cacheInvalidated
    case ignored(UInt16)
}

package actor CursorChannel: SpiceManagedChannel {
    private var connection: ChannelConnection
    private let maximumCacheEntries: Int
    private var cache: [UInt64: SpiceCursorPayload] = [:]
    private var isInitialized = false
    private var state = CursorSnapshot(
        position: SpiceCursorPosition(x: 0, y: 0),
        visible: false,
        cursor: nil,
        trailLength: 0,
        trailFrequency: 0
    )

    package init(connection: ChannelConnection, maximumCacheEntries: Int = 256) {
        self.connection = connection
        self.maximumCacheEntries = maximumCacheEntries
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        let runConnection = connection
        while !Task.isCancelled {
            let event = try await processNext()
            if case .ignored = event {
                continue
            }
            await emit(.cursor(event))
        }
        if connection === runConnection {
            await runConnection.fail(.transport(.cancelled))
        }
    }

    package func processNext() async throws(ChannelError) -> CursorEvent {
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

    private func processNextImpl() async throws(ChannelError) -> CursorEvent {
        let framed = try await connection.receive()
        let message: SpiceServerMessage
        do {
            message = try SpiceServerMessageDecoder.decode(
                id: framed.type,
                body: framed.bodySlice,
                channel: .cursor
            )
        } catch let error {
            throw .wire(error)
        }

        switch message {
        case let .cursor(command):
            let event = try apply(command)
            try await acknowledgeIfNeeded()
            return event
        case let .setAck(setAck):
            await connection.configureAcknowledgments(
                generation: setAck.generation,
                window: setAck.window
            )
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .ping(ping):
            try await connection.send(SpiceMsgcPong(id: ping.id, time: ping.time))
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case .disconnecting:
            throw .transport(.connectionClosed)
        case .unknown:
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        default:
            throw .protocolViolation("message received on wrong Cursor Channel")
        }
    }

    package func snapshot() -> CursorSnapshot {
        state
    }

    package func close() async {
        await connection.close()
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) async throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Cursor Channel")
        }
        let previous = connection
        try await replacement.activate()
        await previous.supersede(
            preservingSerialBarrier: previous.sharesSerialBarrier(with: replacement)
        )
        connection = replacement
        return previous
    }

    private func apply(_ command: SpiceCursorCommand) throws(ChannelError) -> CursorEvent {
        switch command {
        case let .initialize(position, trailLength, trailFrequency, visible, cursor):
            // spice-server can re-emit Cursor Init after a display topology
            // change without reconnecting the Cursor Channel. Treat it as an
            // authoritative state/cache reset.
            cache.removeAll(keepingCapacity: false)
            let resolved = try resolve(cursor)
            isInitialized = true
            state = CursorSnapshot(
                position: position,
                visible: visible && resolved != nil,
                cursor: resolved,
                trailLength: trailLength,
                trailFrequency: trailFrequency
            )
            return .initialized(state)
        case .reset:
            cache.removeAll(keepingCapacity: false)
            state = CursorSnapshot(
                position: state.position,
                visible: false,
                cursor: nil,
                trailLength: 0,
                trailFrequency: 0
            )
            return .reset(state)
        case let .set(position, visible, cursor):
            try requireInitialized()
            let resolved = try resolve(cursor)
            state = CursorSnapshot(
                position: position,
                visible: visible && resolved != nil,
                cursor: resolved,
                trailLength: state.trailLength,
                trailFrequency: state.trailFrequency
            )
            return .updated(state)
        case let .move(position):
            try requireInitialized()
            state = CursorSnapshot(
                position: position,
                visible: state.visible,
                cursor: state.cursor,
                trailLength: state.trailLength,
                trailFrequency: state.trailFrequency
            )
            return .updated(state)
        case .hide:
            try requireInitialized()
            state = CursorSnapshot(
                position: state.position,
                visible: false,
                cursor: state.cursor,
                trailLength: state.trailLength,
                trailFrequency: state.trailFrequency
            )
            return .updated(state)
        case let .trail(length, frequency):
            try requireInitialized()
            state = CursorSnapshot(
                position: state.position,
                visible: state.visible,
                cursor: state.cursor,
                trailLength: length,
                trailFrequency: frequency
            )
            return .updated(state)
        case let .invalidateOne(id):
            cache[id] = nil
            return .cacheInvalidated
        case .invalidateAll:
            cache.removeAll(keepingCapacity: false)
            return .cacheInvalidated
        }
    }

    private func resolve(_ payload: SpiceCursorPayload) throws(ChannelError) -> SpiceCursorPayload? {
        if payload.isNone {
            return nil
        }
        guard let header = payload.header else {
            throw .protocolViolation("Cursor header is missing")
        }
        if payload.isFromCache {
            guard let cached = cache[header.unique] else {
                throw .protocolViolation("unknown cached Cursor \(header.unique)")
            }
            return cached
        }
        if payload.shouldCache {
            guard cache[header.unique] != nil || cache.count < maximumCacheEntries else {
                throw .protocolViolation("Cursor cache limit exceeded")
            }
            cache[header.unique] = payload
        }
        return payload
    }

    private func requireInitialized() throws(ChannelError) {
        guard isInitialized else {
            throw .protocolViolation("Cursor Init must be first")
        }
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        try await connection.acknowledgeLastDelivered()
    }
}
