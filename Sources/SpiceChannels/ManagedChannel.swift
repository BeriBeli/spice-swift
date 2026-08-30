import SpiceCore
import SpiceProtocol
import SpiceRenderer

package enum SpiceChannelEvent: Sendable, Equatable {
    case main(MainEvent)
    case surfaceCreated(UInt32)
    case surfaceDestroyed(UInt32)
    case frame(PublishedDisplayFrame)
    case displayMonitors(channelID: UInt8, SpiceDisplayMonitorsConfiguration)
    case inputs(InputsServerEvent)
    case cursor(CursorEvent)
    case playback(PlaybackEvent)
    case record(RecordEvent)
    case smartcard(SmartcardEvent)
    case usbRedirection(USBRedirectionEvent)
    case webDAV(channelID: UInt8, WebDAVEvent)
}

package protocol SpiceManagedChannel: Actor {
    func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError)
    func replaceConnection(
        with connection: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection
    func close() async
}

package actor PassiveChannel: SpiceManagedChannel {
    private var connection: ChannelConnection

    package init(connection: ChannelConnection) {
        self.connection = connection
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        _ = emit
        while !Task.isCancelled {
            _ = try await connection.receive()
        }
    }

    package func close() async {
        await connection.close()
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match passive channel")
        }
        let previous = connection
        connection = replacement
        return previous
    }
}
