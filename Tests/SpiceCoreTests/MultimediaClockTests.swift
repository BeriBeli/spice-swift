import Testing
@testable import SpiceChannels

@Suite("SPICE multimedia clock")
struct MultimediaClockTests {
    @Test func feedbackUsesMeasuredAudioDelayUntilPlaybackStops() async {
        let clock = MultimediaClock()
        #expect(await clock.playbackDelayMilliseconds() == nil)
        await clock.synchronize(playbackTime: 100, delayMilliseconds: 40)
        #expect(await clock.playbackDelayMilliseconds() == 40)
        await clock.stopPlayback()
        #expect(await clock.playbackDelayMilliseconds() == nil)
    }

    @Test func classifiesDueEarlyLateAndUInt32Wraparound() {
        #expect(MultimediaTimestamp.timing(current: 100, target: 100) == .due)
        #expect(MultimediaTimestamp.timing(current: 100, target: 125) == .early(
            milliseconds: 25
        ))
        #expect(MultimediaTimestamp.timing(current: 125, target: 100) == .late(
            milliseconds: 25
        ))
        #expect(MultimediaTimestamp.timing(
            current: UInt32.max - 5,
            target: 3
        ) == .early(milliseconds: 9))
        #expect(MultimediaTimestamp.timing(
            current: 3,
            target: UInt32.max - 5
        ) == .late(milliseconds: 9))
    }
}
