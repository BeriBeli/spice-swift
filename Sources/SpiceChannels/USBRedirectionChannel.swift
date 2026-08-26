import Foundation
import SpiceCore
import SpiceProtocol
import SpiceWire

package enum USBRedirectionEvent: Sendable, Equatable {
    case data(channelID: UInt8, Data)
    case ignored(UInt16)
}

package actor USBRedirectionChannel: SpiceManagedChannel {
    private var connection: ChannelConnection
    private let codec: SpiceVMCWireCodec

    package init(
        connection: ChannelConnection,
        wireLimits: SpiceVMCWireLimits = .init()
    ) {
        self.connection = connection
        codec = SpiceVMCWireCodec(limits: wireLimits)
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        while !Task.isCancelled {
            let event = try await processNext()
            if case .ignored = event { continue }
            await emit(.usbRedirection(event))
        }
        await connection.fail(.transport(.cancelled))
    }

    package func processNext() async throws(ChannelError) -> USBRedirectionEvent {
        do {
            return try await processNextImpl()
        } catch let error {
            await connection.fail(error)
            throw error
        }
    }

    private func processNextImpl() async throws(ChannelError) -> USBRedirectionEvent {
        let framed = try await connection.receive()
        switch framed.type {
        case SpiceVMCWire.serverData, SpiceVMCWire.serverCompressedData:
            let data: Data
            do {
                data = try codec.decodeServer(id: framed.type, body: framed.body)
            } catch let error {
                throw .wire(error)
            }
            try await acknowledgeIfNeeded()
            return .data(channelID: connection.key.id, data)
        case 3:
            let setAck: SpiceMsgSetAck
            do {
                var reader = try ByteReader(framed.body)
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
                var reader = try ByteReader(framed.body)
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
            throw .protocolViolation("unsupported USB redirection message \(framed.type)")
        }
    }

    package func send(_ data: Data) async throws(ChannelError) {
        let body: Data
        do {
            body = try codec.encodeClientData(data)
        } catch let error {
            throw .wire(error)
        }
        try await connection.send(messageType: SpiceVMCWire.clientData, body: body)
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match USB redirection Channel")
        }
        let previous = connection
        connection = replacement
        return previous
    }

    package func close() async {
        await connection.close()
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        try await connection.acknowledgeLastDelivered()
    }
}
