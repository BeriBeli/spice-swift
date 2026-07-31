import SwiftSpice
import Testing
@testable import SpiceViewer

@Suite("Viewer Record status")
struct ViewerRecordStatusTests {
    @Test("reduces bounded capture events into user-facing state")
    func reducesEvents() {
        let configuration = SpiceRecordConfiguration(
            channels: 1,
            format: .signed16LittleEndian,
            sampleRate: 48_000
        )
        var status = ViewerRecordStatus.disabled
        #expect(status.label == "Mic Off")
        #expect(status.canEnable)

        status = .waiting
        status.consume(.started(configuration))
        status.consume(.muteChanged(true))
        status.consume(.overflowDropped(milliseconds: 25))
        status.consume(.overflowDropped(milliseconds: 15))
        status.consume(.volumeChanged([32_768]))
        #expect(status.phase == .active(configuration))
        #expect(status.label == "Mic Muted · 48 kHz · 1 ch")
        #expect(status.canDisable)
        #expect(status.isMuted)
        #expect(status.overflows == 2)
        #expect(status.droppedMilliseconds == 40)

        status.consume(.stopped)
        #expect(status.phase == .stopped)
        status.consume(.failed(.audioEngine("test")))
        #expect(status.phase == .failed("audio capture engine failed: test"))
        #expect(status.label == "Mic Error")
    }

    @Test("permission states expose safe retry boundaries")
    func permissionStates() {
        #expect(ViewerRecordStatus.denied.canEnable)
        #expect(!ViewerRecordStatus.restricted.canEnable)
        #expect(ViewerRecordStatus.denied.diagnosticSummary.contains("System Settings"))
    }
}
