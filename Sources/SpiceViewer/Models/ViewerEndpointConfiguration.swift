import Foundation
import SwiftSpice

package enum ViewerTLSMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case plainTCP
    case systemTLS
    case insecureTLS

    package var id: Self { self }

    package var title: String {
        switch self {
        case .plainTCP:
            "TCP"
        case .systemTLS:
            "TLS (System Trust)"
        case .insecureTLS:
            "TLS (Insecure Testing)"
        }
    }
}

package struct ViewerEndpointConfiguration: Sendable, Equatable {
    package var host: String
    package var portText: String
    package var tlsMode: ViewerTLSMode

    package init(
        host: String = "127.0.0.1",
        portText: String = "5900",
        tlsMode: ViewerTLSMode = .plainTCP
    ) {
        self.host = host
        self.portText = portText
        self.tlsMode = tlsMode
    }

    package func endpoint() throws(ViewerConfigurationError) -> SpiceEndpoint {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            throw .missingHost
        }
        guard let port = UInt16(portText), port > 0 else {
            throw .invalidPort
        }
        let tlsPolicy: TLSTrustPolicy? = switch tlsMode {
        case .plainTCP:
            nil
        case .systemTLS:
            .system
        case .insecureTLS:
            .insecureForTestingOnly
        }
        return SpiceEndpoint(host: normalizedHost, port: port, tlsPolicy: tlsPolicy)
    }
}

package enum ViewerConfigurationError: Error, LocalizedError, Equatable {
    case missingHost
    case invalidPort

    package var errorDescription: String? {
        switch self {
        case .missingHost:
            "Enter a SPICE host."
        case .invalidPort:
            "Port must be between 1 and 65535."
        }
    }
}
