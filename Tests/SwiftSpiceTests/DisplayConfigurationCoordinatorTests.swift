import Testing
@testable import SwiftSpice

@Suite("Dynamic resolution request coalescing")
struct DisplayConfigurationCoordinatorTests {
    @Test func keepsOnlyLatestResizeWhileWaitingForReply() throws {
        var coordinator = DisplayConfigurationCoordinator()
        let first = SpiceDisplayConfiguration(width: 1_024, height: 768)
        let intermediate = SpiceDisplayConfiguration(width: 1_280, height: 800)
        let latest = SpiceDisplayConfiguration(width: 1_440, height: 900)

        coordinator.queue(first)
        #expect(coordinator.nextToSend == first)
        coordinator.didSend(first)
        coordinator.queue(intermediate)
        coordinator.queue(latest)

        #expect(coordinator.nextToSend == nil)
        #expect(coordinator.didReceiveReply() == first)
        #expect(coordinator.nextToSend == latest)
    }

    @Test func reconnectRequeuesInFlightRequestUnlessNewerRequestExists() {
        var firstCoordinator = DisplayConfigurationCoordinator()
        let first = SpiceDisplayConfiguration(width: 800, height: 600)
        firstCoordinator.queue(first)
        firstCoordinator.didSend(first)
        firstCoordinator.disconnected()
        #expect(firstCoordinator.nextToSend == first)

        var latestCoordinator = DisplayConfigurationCoordinator()
        let latest = SpiceDisplayConfiguration(width: 1_920, height: 1_080)
        latestCoordinator.queue(first)
        latestCoordinator.didSend(first)
        latestCoordinator.queue(latest)
        latestCoordinator.disconnected()
        #expect(latestCoordinator.nextToSend == latest)
    }

    @Test func publicManagerRejectsInvalidOrUnstartedRequests() async {
        let manager = SpiceAgentManager(automaticallySynchronizesPasteboard: false)

        await #expect(throws: SpiceDisplayConfigurationError.invalidDimensions(
            width: 0,
            height: 600
        )) {
            try await manager.requestResolution(width: 0, height: 600)
        }
        await #expect(throws: SpiceDisplayConfigurationError.agentManagerNotRunning) {
            try await manager.requestResolution(width: 800, height: 600)
        }
    }
}
