import Foundation
import SpiceCore
import SpiceProtocol
import SpiceWire

package enum WebDAVEvent: Sendable, Equatable {
    case initialized(SpicePortInitialization)
    case port(SpicePortEvent)
    case request(clientID: Int64, data: Data)
    case clientClosed(Int64)
    case ignored(UInt16)
}

package actor WebDAVChannel: SpiceManagedChannel {
    private var connection: ChannelConnection
    private let channelID: UInt8
    private let portCodec: SpicePortWireCodec
    private var muxDecoder: SpiceWebDAVMuxDecoder
    private let muxEncoder: SpiceWebDAVMuxEncoder
    private var initialization: SpicePortInitialization?
    private var isOpen = false
    private var pendingEvents: [WebDAVEvent] = []

    package init(
        connection: ChannelConnection,
        muxLimits: SpiceWebDAVMuxLimits = .init()
    ) {
        self.connection = connection
        channelID = connection.key.id
        portCodec = SpicePortWireCodec()
        muxDecoder = SpiceWebDAVMuxDecoder(limits: muxLimits)
        muxEncoder = SpiceWebDAVMuxEncoder(limits: muxLimits)
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        let runConnection = connection
        while !Task.isCancelled {
            let event = try await processNext()
            if case .ignored = event { continue }
            await emit(.webDAV(channelID: channelID, event))
        }
        if connection === runConnection {
            await runConnection.fail(.transport(.cancelled))
        }
    }

    package func processNext() async throws(ChannelError) -> WebDAVEvent {
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

    private func processNextImpl() async throws(ChannelError) -> WebDAVEvent {
        if !pendingEvents.isEmpty {
            return pendingEvents.removeFirst()
        }
        while true {
            let framed = try await connection.receive()
            switch framed.type {
            case SpiceVMCWire.serverData:
                guard initialization != nil, isOpen else {
                    throw .protocolViolation("WebDAV data received while port is closed")
                }
                let frames: [SpiceWebDAVFrame]
                do {
                    let data = try SpiceVMCWireCodec().decodeServer(
                        id: framed.type,
                        body: framed.bodySlice
                    )
                    frames = try muxDecoder.append(data)
                } catch let error {
                    throw .wire(error)
                }
                try await acknowledgeIfNeeded()
                pendingEvents.append(contentsOf: frames.map {
                    $0.closesClient
                        ? .clientClosed($0.clientID)
                        : .request(clientID: $0.clientID, data: $0.data)
                })
                if !pendingEvents.isEmpty {
                    return pendingEvents.removeFirst()
                }
            case SpiceVMCWire.serverCompressedData:
                throw .wire(.unsupportedFeature(
                    "compressed SpiceVMC data was not negotiated"
                ))
            case SpicePortWire.serverInit:
                guard initialization == nil else {
                    throw .protocolViolation("duplicate WebDAV port initialization")
                }
                do {
                    initialization = try portCodec.decodeInitialization(framed.bodySlice)
                } catch let error {
                    throw .wire(error)
                }
                isOpen = initialization?.opened == true
                try await acknowledgeIfNeeded()
                return .initialized(initialization!)
            case SpicePortWire.serverEvent:
                let event: SpicePortEvent
                do {
                    event = try portCodec.decodeEvent(framed.bodySlice)
                } catch let error {
                    throw .wire(error)
                }
                switch event {
                case .opened: isOpen = true
                case .closed: isOpen = false
                case .break: break
                }
                try await acknowledgeIfNeeded()
                return .port(event)
            case 3:
                let setAck: SpiceMsgSetAck
                do {
                    var reader = try ByteReader(framed.bodySlice)
                    setAck = try SpiceMsgSetAck.decode(from: &reader)
                    try reader.requireFullyConsumed()
                } catch let error {
                    throw .wire(error)
                }
                await connection.configureAcknowledgments(
                    generation: setAck.generation,
                    window: setAck.window
                )
                try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
                try await acknowledgeIfNeeded()
                return .ignored(framed.type)
            case 4:
                let ping: SpiceMsgPing
                do {
                    var reader = try ByteReader(framed.bodySlice)
                    ping = try SpiceMsgPing.decode(from: &reader)
                } catch let error {
                    throw .wire(error)
                }
                try await connection.send(SpiceMsgcPong(id: ping.id, time: ping.time))
                try await acknowledgeIfNeeded()
                return .ignored(framed.type)
            case 6:
                throw .transport(.connectionClosed)
            default:
                throw .protocolViolation("unsupported WebDAV message \(framed.type)")
            }
        }
    }

    package func send(clientID: Int64, data: Data) async throws(ChannelError) {
        guard initialization != nil, isOpen else {
            throw .protocolViolation("WebDAV response sent while port is closed")
        }
        let body: Data
        do {
            body = try muxEncoder.encode(clientID: clientID, data: data)
        } catch let error {
            throw .wire(error)
        }
        try await connection.send(messageType: SpiceVMCWire.clientData, body: body)
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) async throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match WebDAV Channel")
        }
        let previous = connection
        try await replacement.activate()
        await previous.supersede(
            preservingSerialBarrier: previous.sharesSerialBarrier(with: replacement)
        )
        connection = replacement
        return previous
    }

    package func close() async {
        pendingEvents.removeAll(keepingCapacity: false)
        initialization = nil
        isOpen = false
        await connection.close()
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        try await connection.acknowledgeLastDelivered()
    }
}
