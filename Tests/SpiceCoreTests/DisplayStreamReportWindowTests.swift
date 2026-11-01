import Testing
@testable import SpiceChannels
@testable import SpiceProtocol

@Suite("Display stream feedback windows")
struct DisplayStreamReportWindowTests {
    private func window(size: UInt32 = 5, timeout: UInt32 = 1_000) -> DisplayStreamReportWindow {
        .init(activation: .init(
            streamID: 7, uniqueID: 42,
            maximumWindowSize: size, timeoutMilliseconds: timeout
        ))
    }

    @Test func reportsArrivalMarginsAndResetsWindow() throws {
        var state = window(size: 2)
        let now = ContinuousClock.now
        #expect(state.record(multimediaTime: UInt32.max, margin: -1,
                             audioDelay: .max, now: now) == nil)
        let reportValue = state.record(
            multimediaTime: 3, margin: 5, audioDelay: 60, now: now
        )
        let report = try #require(reportValue)
        #expect(report == SpiceMsgcDisplayStreamReport(
            streamID: 7, uniqueID: 42, startFrameMultimediaTime: .max,
            endFrameMultimediaTime: 3, frameCount: 2, dropCount: 1,
            lastFrameDelay: 5, audioDelay: 60
        ))
        #expect(state.record(multimediaTime: 4, margin: 0,
                             audioDelay: .max, now: now) == nil)
        let nextValue = state.record(
            multimediaTime: 5, margin: 0, audioDelay: .max, now: now
        )
        let next = try #require(nextValue)
        #expect(next.startFrameMultimediaTime == 4)
        #expect(next.dropCount == 0)
        #expect(next.audioDelay == .max)
    }

    @Test func timeoutUsesMonotonicMillisecondsAndStartsWithFirstFrame() throws {
        var state = window(size: .max, timeout: 100)
        let now = ContinuousClock.now
        #expect(state.record(multimediaTime: 100, margin: 5,
                             audioDelay: .max, now: now) == nil)
        #expect(state.record(multimediaTime: 1_000_000, margin: 5,
                             audioDelay: .max, now: now.advanced(by: .milliseconds(99))) == nil)
        let reportValue = state.record(
            multimediaTime: 2, margin: 5, audioDelay: .max,
            now: now.advanced(by: .milliseconds(100))
        )
        let report = try #require(reportValue)
        #expect(report.frameCount == 3)
        #expect(report.startFrameMultimediaTime == 100)
        #expect(report.endFrameMultimediaTime == 2)
        // Time with no frames is not part of the next reporting window.
        #expect(state.record(multimediaTime: 3, margin: 5, audioDelay: .max,
                             now: now.advanced(by: .seconds(10))) == nil)
    }

    @Test func threeConsecutiveLateArrivalsTriggerEarlyReport() throws {
        var state = window(size: .max, timeout: .max)
        let now = ContinuousClock.now
        for margin: Int32 in [-1, -2, 0, -3, -4] {
            #expect(state.record(multimediaTime: 1, margin: margin,
                                 audioDelay: .max, now: now) == nil)
        }
        let reportValue = state.record(
            multimediaTime: 2, margin: -5, audioDelay: .max, now: now
        )
        let report = try #require(reportValue)
        #expect(report.frameCount == 6)
        #expect(report.dropCount == 5)
        #expect(report.lastFrameDelay == -5)
        #expect(state.record(multimediaTime: 3, margin: -1,
                             audioDelay: .max, now: now) == nil)
    }

    @Test(arguments: [(UInt32(0), UInt32.max), (.max, 0)])
    func zeroThresholdReportsOnFirstFrame(size: UInt32, timeout: UInt32) {
        var state = window(size: size, timeout: timeout)
        #expect(state.record(multimediaTime: 1, margin: 0,
                             audioDelay: .max, now: .now)?.frameCount == 1)
    }

    @Test func signedMarginsPreserveWraparoundAndExtremeLateValue() {
        #expect(MultimediaTimestamp.timing(current: .max, target: 1).streamReportMargin == 2)
        #expect(MultimediaTimestamp.timing(current: 1, target: .max).streamReportMargin == -2)
        #expect(MultimediaTimestamp.timing(current: 0, target: 0x8000_0000)
            .streamReportMargin == Int32.min)
    }
}
