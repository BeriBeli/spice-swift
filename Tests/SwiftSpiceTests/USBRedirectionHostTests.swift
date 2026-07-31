import Foundation
import Testing
@testable import SwiftSpice

@Suite("libusbredirhost exact backend")
struct USBRedirectionHostTests {
    @Test func emitsBoundedExactBackendHelloWithoutSelectingADevice() async throws {
        let host = try SpiceUSBRedirectionHost(
            maximumBufferedBytes: 4_096,
            maximumSpicePacketBytes: 8
        )
        let packets = await host.initialPackets()
        #expect(!packets.isEmpty)
        #expect(packets.allSatisfy { !$0.isEmpty && $0.count <= 8 })
        #expect(try await host.pumpEvents().isEmpty)
    }

    @Test func requiresExplicitValidDeviceAndBoundedPumpIntervals() async throws {
        let host = try SpiceUSBRedirectionHost()
        _ = await host.initialPackets()
        await #expect(throws: SpiceUSBRedirectionHostError.deviceNotFound) {
            try await host.attachDevice(busNumber: .max, deviceAddress: .max)
        }
        await #expect(throws: SpiceUSBRedirectionHostError.invalidArgument) {
            try await host.pumpEvents(timeoutMilliseconds: 101)
        }
        await #expect(throws: SpiceUSBRedirectionHostError.invalidArgument) {
            try await host.receiveFromGuest(Data())
        }
    }

    @Test func rejectsUnboundedConfigurationBeforeCreatingNativeState() {
        #expect(throws: SpiceUSBRedirectionHostError.invalidArgument) {
            try SpiceUSBRedirectionHost(
                maximumBufferedBytes: 1_024,
                maximumSpicePacketBytes: 2_048
            )
        }
        #expect(throws: SpiceUSBRedirectionHostError.invalidArgument) {
            try SpiceUSBRedirectionHost(maximumBufferedBytes: 65 * 1_024 * 1_024)
        }
    }
}
