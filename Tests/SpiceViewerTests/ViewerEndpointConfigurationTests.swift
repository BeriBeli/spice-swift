import SwiftSpice
import Testing
@testable import SpiceViewer

@Suite("Viewer endpoint configuration")
struct ViewerEndpointConfigurationTests {
    @Test("normalizes host and maps transport policy")
    func mapsEndpoint() throws {
        let plain = try ViewerEndpointConfiguration(
            host: "  spice.example.test  ",
            portText: "5900",
            tlsMode: .plainTCP
        ).endpoint()
        #expect(plain == SpiceEndpoint(host: "spice.example.test", port: 5900))

        let secure = try ViewerEndpointConfiguration(
            host: "spice.example.test",
            portText: "5901",
            tlsMode: .systemTLS
        ).endpoint()
        #expect(secure.tlsPolicy == .system)

        let insecure = try ViewerEndpointConfiguration(
            host: "spice.example.test",
            portText: "5902",
            tlsMode: .insecureTLS
        ).endpoint()
        #expect(insecure.tlsPolicy == .insecureForTestingOnly)
    }

    @Test("rejects missing hosts and invalid ports")
    func rejectsInvalidValues() {
        #expect(throws: ViewerConfigurationError.missingHost) {
            try ViewerEndpointConfiguration(host: "  ", portText: "5900").endpoint()
        }
        #expect(throws: ViewerConfigurationError.invalidPort) {
            try ViewerEndpointConfiguration(host: "localhost", portText: "0").endpoint()
        }
        #expect(throws: ViewerConfigurationError.invalidPort) {
            try ViewerEndpointConfiguration(host: "localhost", portText: "65536").endpoint()
        }
    }
}
