import Foundation
import Testing
@testable import SpiceViewer

@Suite("Viewer lifecycle policy")
struct ViewerLifecycleTests {
    @Test("uses bounded exponential reconnect delays")
    func reconnectBackoff() {
        let policy = ViewerReconnectBackoff()
        #expect(policy.attemptTimeoutSeconds == 10)
        #expect((1 ... 6).map { policy.delaySeconds(forRetry: $0) } == [1, 2, 4, 8, 16, nil])

        let capped = ViewerReconnectBackoff(
            maximumRetries: 4,
            maximumDelaySeconds: 3,
            attemptTimeoutSeconds: 7
        )
        #expect(capped.attemptTimeoutSeconds == 7)
        #expect((1 ... 5).map { capped.delaySeconds(forRetry: $0) } == [1, 2, 3, 3, nil])
        #expect(capped.delaySeconds(forRetry: 0) == nil)
    }

    @Test("persists only normalized non-secret endpoint profiles")
    @MainActor
    func profilePersistence() throws {
        let suiteName = "ViewerProfileStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = ViewerProfileStore(defaults: defaults)
        let saved = try store.save(
            id: nil,
            name: "  Lab VM  ",
            configuration: ViewerEndpointConfiguration(
                host: "  192.0.2.10  ",
                portText: "5901",
                tlsMode: .systemTLS
            )
        )
        #expect(saved.name == "Lab VM")
        #expect(saved.host == "192.0.2.10")
        #expect(saved.port == 5901)
        #expect(saved.tlsMode == .systemTLS)

        let persisted = try #require(defaults.data(forKey: "viewer.endpointProfiles"))
        let text = try #require(String(data: persisted, encoding: .utf8))
        #expect(!text.localizedCaseInsensitiveContains("password"))
        #expect(!text.localizedCaseInsensitiveContains("credential"))

        let reloaded = ViewerProfileStore(defaults: defaults)
        #expect(reloaded.profiles == [saved])
        reloaded.delete(id: saved.id)
        #expect(reloaded.profiles.isEmpty)
    }
}
