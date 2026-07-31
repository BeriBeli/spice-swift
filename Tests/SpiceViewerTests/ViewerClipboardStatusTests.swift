import SwiftSpice
import Testing
@testable import SpiceViewer

@Suite("Viewer clipboard status")
struct ViewerClipboardStatusTests {
    @Test("reduces ownership without retaining clipboard text")
    func reducesEvents() {
        var status = ViewerClipboardStatus.disabled
        #expect(status.canEnable)
        #expect(status.label == "Clipboard Off")

        status = .waiting
        status.consume(.ready)
        status.consume(.localTextOffered(byteCount: 5))
        #expect(status.phase == .ready)
        #expect(status.ownership == .local(byteCount: 5))
        #expect(status.label == "Clipboard Host")

        status.consume(.guestText("客人"))
        #expect(status.ownership == .guest(byteCount: 6))
        #expect(status.guestUpdates == 1)
        #expect(status.label == "Clipboard Guest")

        status.consume(.oversizedLocalText(byteCount: 10, maximum: 4))
        #expect(status.ownership == .none)
        #expect(status.oversizedRejects == 1)

        status.consume(.unavailable)
        #expect(status.phase == .waiting)
        status.consume(.failed(.invalidUTF8))
        #expect(status.phase == .failed("guest clipboard is not valid UTF-8"))
        #expect(status.label == "Clipboard Error")
    }

    @Test("diagnostics state the keyboard and IME boundary")
    func documentsBoundary() {
        let summary = ViewerClipboardStatus.waiting.diagnosticSummary
        #expect(summary.contains("Not keyboard"))
        #expect(summary.contains("IME"))
    }
}
