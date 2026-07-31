import SwiftSpice
import Testing
@testable import SpiceViewer

@Suite("Viewer monitor status")
struct ViewerMonitorStatusTests {
    @Test("Display inventory remains authoritative after Agent acknowledgement")
    func keepsAuthoritativeInventory() {
        let actual = SpiceGuestDisplayConfiguration(
            channelID: 3,
            maximumAllowed: 4,
            monitors: [SpiceGuestMonitor(
                id: 0,
                surfaceID: 9,
                x: 0,
                y: 0,
                width: 1_280,
                height: 720,
                flags: 0
            )]
        )
        let requested = SpiceDisplayConfiguration(width: 1_920, height: 1_080)
        var status = ViewerMonitorStatus()
        status.consumeAuthoritative(actual)
        status.consumeRequest(.queued(requested))
        status.consumeRequest(.sent(requested))
        status.consumeRequest(.acknowledged(requested))

        #expect(status.configurations == [actual])
        #expect(status.monitorCount == 1)
        #expect(status.requestSummary.contains("waiting for authoritative Display update"))

        status.consumeAuthoritative(SpiceGuestDisplayConfiguration(
            channelID: 3,
            maximumAllowed: 4,
            monitors: [SpiceGuestMonitor(
                id: 0,
                surfaceID: 9,
                x: 0,
                y: 0,
                width: 1_920,
                height: 1_080,
                flags: 0
            )]
        ))
        #expect(status.requestPhase == .applied(requested))
        #expect(status.requestSummary == "Display confirmed 1920×1080")
    }

    @Test("empty notifications do not erase the last useful inventory")
    func ignoresEmptyInventory() {
        let actual = SpiceGuestDisplayConfiguration(
            channelID: 1,
            maximumAllowed: nil,
            monitors: [SpiceGuestMonitor(
                id: 0,
                surfaceID: 1,
                x: 0,
                y: 0,
                width: 800,
                height: 600,
                flags: 0
            )]
        )
        var status = ViewerMonitorStatus()
        status.consumeAuthoritative(actual)
        status.consumeAuthoritative(SpiceGuestDisplayConfiguration(
            channelID: 1,
            maximumAllowed: 2,
            monitors: []
        ))
        #expect(status.configurations == [actual])
    }

    @Test("Agent acknowledgement cannot confirm an already matching inventory")
    func requiresDisplayNotificationAfterAcknowledgement() {
        let requested = SpiceDisplayConfiguration(width: 1_920, height: 1_080)
        let matching = SpiceGuestDisplayConfiguration(
            channelID: 0,
            maximumAllowed: 1,
            monitors: [SpiceGuestMonitor(
                id: 0,
                surfaceID: 0,
                x: 0,
                y: 0,
                width: 1_920,
                height: 1_080,
                flags: 0
            )]
        )
        var status = ViewerMonitorStatus()
        status.consumeAuthoritative(matching)
        status.consumeRequest(.acknowledged(requested))

        #expect(status.requestPhase == .acknowledged(requested))

        status.consumeAuthoritative(matching)
        #expect(status.requestPhase == .applied(requested))
    }

    @Test("multi-monitor requests require a matching authoritative layout")
    func confirmsMultiMonitorLayout() {
        let requested = SpiceDisplayConfiguration(monitors: [
            .init(id: 0, x: 0, y: 0, width: 1_920, height: 1_080),
            .init(id: 2, x: 1_920, y: 0, width: 1_280, height: 1_024),
        ])
        var status = ViewerMonitorStatus()
        status.consumeRequest(.acknowledged(requested))
        status.consumeAuthoritative(SpiceGuestDisplayConfiguration(
            channelID: 0,
            maximumAllowed: 4,
            monitors: [
                SpiceGuestMonitor(
                    id: 0, surfaceID: 0, x: 0, y: 0,
                    width: 1_920, height: 1_080, flags: 0
                ),
                SpiceGuestMonitor(
                    id: 2, surfaceID: 2, x: 1_920, y: 0,
                    width: 1_280, height: 1_024, flags: 0
                ),
            ]
        ))

        #expect(status.requestPhase == .applied(requested))
    }
}
