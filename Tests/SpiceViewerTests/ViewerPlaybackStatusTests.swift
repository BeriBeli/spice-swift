import SwiftSpice
import Testing
@testable import SpiceViewer

@Suite("Viewer playback status")
struct ViewerPlaybackStatusTests {
    @Test("reduces bounded sink events into user-facing state")
    func reducesEvents() {
        let configuration = SpicePlaybackConfiguration(
            channels: 2,
            format: .signed16LittleEndian,
            sampleRate: 48_000
        )
        var status = ViewerPlaybackStatus.waiting
        #expect(status.label == "Audio Waiting")

        status.consume(.started(configuration))
        status.consume(.muteChanged(true))
        status.consume(.overflowResynchronized(droppedMilliseconds: 40))
        status.consume(.oversizedPacketDropped(milliseconds: 510))
        status.consume(.underrun)
        #expect(status.phase == .active(configuration))
        #expect(status.label == "Muted · 48 kHz · 2 ch")
        #expect(status.isMuted)
        #expect(status.resynchronizations == 1)
        #expect(status.oversizedDrops == 1)
        #expect(status.underruns == 1)
        #expect(status.droppedMilliseconds == 550)

        status.consume(.stopped)
        #expect(status.phase == .stopped)
        status.consume(.failed(.audioEngine("test")))
        #expect(status.phase == .failed("audio engine failed: test"))
        #expect(status.label == "Audio Error")
    }
}
