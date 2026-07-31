import SwiftSpice
import Testing
@testable import SpiceViewer

@Suite("Viewer display layout draft")
struct ViewerDisplayLayoutDraftTests {
    private let fullSupport = SpiceDisplayConfigurationSupport(
        agentConnected: true,
        hasExplicitPeerCapabilities: true,
        supportsMonitorConfiguration: true,
        supportsSparseMonitors: true,
        supportsMonitorPositions: true
    )

    @Test("single Display channel preserves sparse IDs and geometry")
    func loadsSingleChannel() throws {
        let inventory = SpiceGuestDisplayConfiguration(
            channelID: 4,
            maximumAllowed: 4,
            monitors: [
                guestMonitor(id: 0, x: 0, width: 1_920),
                guestMonitor(id: 2, x: 1_920, width: 1_280),
            ]
        )
        let draft = ViewerDisplayLayoutDraft(configurations: [inventory])
        let validation = draft.validation(support: fullSupport)
        let configuration = try #require(validation.configuration)

        #expect(configuration.monitors.map(\.id) == [0, 2])
        #expect(configuration.monitors.map(\.x) == [0, 1_920])
        #expect(validation.usesSparseIDs)
        #expect(validation.usesPositions)
    }

    @Test("multiple Display channels use deterministic request IDs")
    func remapsMultipleChannels() {
        let draft = ViewerDisplayLayoutDraft(configurations: [
            .init(channelID: 7, maximumAllowed: 1, monitors: [
                guestMonitor(id: 0, x: 1_920, width: 1_280),
            ]),
            .init(channelID: 3, maximumAllowed: 1, monitors: [
                guestMonitor(id: 0, x: 0, width: 1_920),
            ]),
        ])

        #expect(draft.monitors.map(\.monitorID) == ["0", "1"])
        #expect(draft.monitors.map(\.width) == ["1920", "1280"])
        #expect(draft.sourceNote.contains("remapped sequentially"))
    }

    @Test("advanced layouts wait for and obey explicit capabilities")
    func gatesAdvancedLayout() {
        var draft = ViewerDisplayLayoutDraft()
        draft.addMonitor()
        draft.monitors[1].monitorID = "2"
        draft.monitors[1].x = "-1280"

        let baseline = SpiceDisplayConfigurationSupport(
            agentConnected: true,
            hasExplicitPeerCapabilities: false,
            supportsMonitorConfiguration: true,
            supportsSparseMonitors: false,
            supportsMonitorPositions: false
        )
        #expect(draft.validation(support: baseline).message.contains("Waiting for explicit"))

        let restricted = SpiceDisplayConfigurationSupport(
            agentConnected: true,
            hasExplicitPeerCapabilities: true,
            supportsMonitorConfiguration: true,
            supportsSparseMonitors: false,
            supportsMonitorPositions: false
        )
        #expect(draft.validation(support: restricted).message.contains("sparse monitor IDs"))

        let accepted = draft.validation(support: fullSupport)
        #expect(accepted.canSubmit)
        #expect(accepted.configuration?.monitors[1].x == -1_280)
    }

    @Test("duplicate IDs and invalid wire values are rejected locally")
    func rejectsInvalidRows() {
        var draft = ViewerDisplayLayoutDraft()
        draft.addMonitor()
        draft.monitors[1].monitorID = draft.monitors[0].monitorID
        #expect(draft.validation(support: fullSupport).message == "Duplicate monitor ID 0")

        draft.monitors[1].monitorID = "1"
        draft.monitors[1].x = "2147483648"
        #expect(draft.validation(support: fullSupport).message.contains("signed Int32"))
    }

    private func guestMonitor(id: UInt32, x: UInt32, width: UInt32) -> SpiceGuestMonitor {
        SpiceGuestMonitor(
            id: id,
            surfaceID: id,
            x: x,
            y: 0,
            width: width,
            height: 1_080,
            flags: 0
        )
    }
}
