import Foundation

package struct ViewerEndpointProfile: Codable, Identifiable, Sendable, Equatable {
    package let id: UUID
    package var name: String
    package var host: String
    package var port: UInt16
    package var tlsMode: ViewerTLSMode

    package init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: UInt16,
        tlsMode: ViewerTLSMode
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.tlsMode = tlsMode
    }

    package var configuration: ViewerEndpointConfiguration {
        ViewerEndpointConfiguration(
            host: host,
            portText: String(port),
            tlsMode: tlsMode
        )
    }
}
