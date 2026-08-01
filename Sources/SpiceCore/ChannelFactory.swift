import Foundation
import SpiceTransport
import SpiceWire

package struct ChannelFactory: Sendable {
    package typealias TransportFactory = @Sendable (ChannelKey) -> any SpiceTransport

    private let transportFactory: TransportFactory
    private let ticketEncryptor: any TicketEncrypting
    private let serialBarrier: ChannelSerialBarrier
    private let advertisesH264: Bool
    private let advertisesH265: Bool

    package init(
        transportFactory: @escaping TransportFactory,
        ticketEncryptor: any TicketEncrypting,
        serialBarrier: ChannelSerialBarrier = ChannelSerialBarrier(),
        advertisesH264: Bool = false,
        advertisesH265: Bool = false
    ) {
        self.transportFactory = transportFactory
        self.ticketEncryptor = ticketEncryptor
        self.serialBarrier = serialBarrier
        self.advertisesH264 = advertisesH264
        self.advertisesH265 = advertisesH265
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
                request: .channel(
                    connectionID: connectionID,
                    key: key,
                    advertisesH264: advertisesH264,
                    advertisesH265: advertisesH265
                ),
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
