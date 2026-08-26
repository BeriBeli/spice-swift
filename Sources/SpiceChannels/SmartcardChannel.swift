import Foundation
import SpiceCore
import SpiceProtocol
import SpiceWire

package enum SmartcardEvent: Sendable, Equatable {
    case initialized(SpiceSmartcardInitialization)
    case operationCompleted(
        request: SpiceSmartcardMessageType,
        readerID: UInt32,
        errorCode: UInt32
    )
    case apdu(readerID: UInt32, data: Data)
    case flushRequested(readerID: UInt32)
    case ignored(UInt16)
}

package actor SmartcardChannel: SpiceManagedChannel {
    private var connection: ChannelConnection
    private let codec: SpiceSmartcardWireCodec
    private let maximumQueuedControlMessages: Int
    private var pendingControlMessages: [SpiceSmartcardMessage] = []
    private var inFlightControlType: SpiceSmartcardMessageType?

    package init(
        connection: ChannelConnection,
        wireLimits: SpiceSmartcardWireLimits = .init(),
        maximumQueuedControlMessages: Int = 64
    ) {
        self.connection = connection
        codec = SpiceSmartcardWireCodec(limits: wireLimits)
        self.maximumQueuedControlMessages = max(1, maximumQueuedControlMessages)
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        while !Task.isCancelled {
            let event = try await processNext()
            if case .ignored = event { continue }
            await emit(.smartcard(event))
        }
    }

    package func processNext() async throws(ChannelError) -> SmartcardEvent {
        let framed = try await connection.receive()
        let decoded: SpiceServerMessage
        do {
            decoded = try SpiceServerMessageDecoder.decode(
                id: framed.type,
                body: framed.body,
                channel: .smartcard
            )
        } catch let error {
            throw .wire(error)
        }

        switch decoded {
        case let .smartcard(message):
            let event = try await handle(message)
            try await acknowledgeIfNeeded()
            return event
        case let .setAck(setAck):
            await connection.configureAcknowledgments(
                generation: setAck.generation,
                window: setAck.window
            )
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
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
            throw .protocolViolation("message received on wrong Smartcard Channel")
        }
    }

    package func addReader(name: String) async throws(ChannelError) {
        try await enqueueControl(SpiceSmartcardMessage(
            type: .readerAdd,
            readerID: SpiceSmartcardWire.undefinedReaderID,
            payload: Data(name.utf8)
        ))
    }

    package func removeReader(id: UInt32) async throws(ChannelError) {
        try await enqueueControl(SpiceSmartcardMessage(type: .readerRemove, readerID: id))
    }

    package func insertCard(readerID: UInt32, atr: Data) async throws(ChannelError) {
        try await enqueueControl(SpiceSmartcardMessage(
            type: .atr,
            readerID: readerID,
            payload: atr
        ))
    }

    package func removeCard(readerID: UInt32) async throws(ChannelError) {
        try await enqueueControl(SpiceSmartcardMessage(type: .cardRemove, readerID: readerID))
    }

    package func respondToAPDU(readerID: UInt32, data: Data) async throws(ChannelError) {
        try await sendImmediately(SpiceSmartcardMessage(
            type: .apdu,
            readerID: readerID,
            payload: data
        ))
    }

    package func sendError(readerID: UInt32, code: UInt32) async throws(ChannelError) {
        var payload = ByteWriter(capacity: 4)
        payload.writeUInt32LE(code)
        try await sendImmediately(SpiceSmartcardMessage(
            type: .error,
            readerID: readerID,
            payload: payload.data
        ))
    }

    package func completeFlush(readerID: UInt32) async throws(ChannelError) {
        try await sendImmediately(SpiceSmartcardMessage(
            type: .flushComplete,
            readerID: readerID
        ))
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Smartcard Channel")
        }
        let previous = connection
        connection = replacement
        return previous
    }

    package func close() async {
        pendingControlMessages.removeAll(keepingCapacity: false)
        inFlightControlType = nil
        await connection.close()
    }

    private func handle(
        _ message: SpiceSmartcardMessage
    ) async throws(ChannelError) -> SmartcardEvent {
        switch message.type {
        case .initialize:
            let initialization: SpiceSmartcardInitialization
            do {
                initialization = try codec.decodeInitialization(message)
            } catch let error {
                throw .wire(error)
            }
            guard initialization.version == SpiceSmartcardWire.version else {
                throw .protocolViolation(
                    "unsupported Smartcard protocol version \(initialization.version)"
                )
            }
            return .initialized(initialization)
        case .error:
            guard let completedType = inFlightControlType else {
                throw .protocolViolation("unsolicited Smartcard operation result")
            }
            let code: UInt32
            do {
                code = try codec.decodeErrorCode(message)
            } catch let error {
                throw .wire(error)
            }
            inFlightControlType = nil
            try await drainControlQueue()
            return .operationCompleted(
                request: completedType,
                readerID: message.readerID,
                errorCode: code
            )
        case .apdu:
            try requireDefinedReader(message.readerID)
            return .apdu(readerID: message.readerID, data: message.payload)
        case .flush:
            try requireDefinedReader(message.readerID)
            return .flushRequested(readerID: message.readerID)
        case .readerAdd, .readerRemove, .atr, .cardRemove, .flushComplete:
            throw .protocolViolation(
                "client-only Smartcard message \(message.type.rawValue) received from server"
            )
        }
    }

    private func enqueueControl(_ message: SpiceSmartcardMessage) async throws(ChannelError) {
        let queuedCount = pendingControlMessages.count + (inFlightControlType == nil ? 0 : 1)
        guard queuedCount < maximumQueuedControlMessages else {
            throw .protocolViolation("Smartcard control queue is full")
        }
        pendingControlMessages.append(message)
        try await drainControlQueue()
    }

    private func drainControlQueue() async throws(ChannelError) {
        guard inFlightControlType == nil, !pendingControlMessages.isEmpty else { return }
        let message = pendingControlMessages.removeFirst()
        inFlightControlType = message.type
        try await sendImmediately(message)
    }

    private func sendImmediately(_ message: SpiceSmartcardMessage) async throws(ChannelError) {
        let body: Data
        do {
            body = try codec.encode(message)
        } catch let error {
            throw .wire(error)
        }
        try await connection.send(messageType: SpiceSmartcardWire.dataMessageID, body: body)
    }

    private func requireDefinedReader(_ readerID: UInt32) throws(ChannelError) {
        guard readerID != SpiceSmartcardWire.undefinedReaderID else {
            throw .protocolViolation("Smartcard message requires an allocated reader ID")
        }
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        try await connection.acknowledgeLastDelivered()
    }
}
