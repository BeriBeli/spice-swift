import Foundation
import SpiceTransport
import SpiceWire

package struct ChannelFactory: Sendable {
    package typealias TransportFactory = @Sendable (ChannelKey) -> any SpiceTransport

    private let transportFactory: TransportFactory
    private let ticketEncryptor: any TicketEncrypting
    private let serialBarrier: ChannelSerialBarrier

    package init(
        transportFactory: @escaping TransportFactory,
        ticketEncryptor: any TicketEncrypting,
        serialBarrier: ChannelSerialBarrier = ChannelSerialBarrier()
    ) {
        self.transportFactory = transportFactory
        self.ticketEncryptor = ticketEncryptor
        self.serialBarrier = serialBarrier
    }

    package func connect(
        key: ChannelKey,
        connectionID: UInt32,
        password: consuming Data
    ) async throws(ChannelError) -> ChannelConnection {
        let transport = transportFactory(key)
        do {
            try await transport.connect()
            let handshake = try await LinkHandshake().perform(
                transport: transport,
                request: .channel(connectionID: connectionID, key: key),
                password: password,
                ticketEncryptor: ticketEncryptor
            )
            return ChannelConnection(
                key: key,
                transport: transport,
                headerMode: handshake.headerMode,
                serialBarrier: serialBarrier
            )
        } catch let error as ChannelError {
            await transport.close()
            throw error
        } catch let error as TransportError {
            await transport.close()
            throw .transport(error)
        } catch is CancellationError {
            await transport.close()
            throw .transport(.cancelled)
        } catch {
            await transport.close()
            throw .protocolViolation(String(describing: error))
        }
    }
}
