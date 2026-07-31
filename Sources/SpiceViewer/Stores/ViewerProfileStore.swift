import Foundation
import Observation
import OSLog

private let profileLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.beribeli.SpiceViewer",
    category: "Profiles"
)

@Observable
@MainActor
package final class ViewerProfileStore {
    package private(set) var profiles: [ViewerEndpointProfile] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let storageKey: String

    package init(
        defaults: UserDefaults = .standard,
        storageKey: String = "viewer.endpointProfiles"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    @discardableResult
    package func save(
        id: UUID?,
        name: String,
        configuration: ViewerEndpointConfiguration
    ) throws -> ViewerEndpointProfile {
        let endpoint = try configuration.endpoint()
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ViewerEndpointProfile(
            id: id ?? UUID(),
            name: normalizedName.isEmpty
                ? "\(endpoint.host):\(endpoint.port)"
                : normalizedName,
            host: endpoint.host,
            port: endpoint.port,
            tlsMode: configuration.tlsMode
        )
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
        profileLogger.info("Saved endpoint profile; total=\(self.profiles.count, privacy: .public)")
        return profile
    }

    package func delete(id: UUID) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles.remove(at: index)
        persist()
        profileLogger.info("Deleted endpoint profile; total=\(self.profiles.count, privacy: .public)")
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            profiles = try JSONDecoder().decode([ViewerEndpointProfile].self, from: data)
            profiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            profileLogger.info("Loaded \(self.profiles.count, privacy: .public) endpoint profiles")
        } catch {
            profiles = []
            profileLogger.error("Endpoint profile store is unreadable; ignoring persisted data")
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(profiles), forKey: storageKey)
        } catch {
            profileLogger.error("Could not encode endpoint profiles")
        }
    }
}
