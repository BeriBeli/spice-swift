import SpiceProtocol

/// Matches spice-gtk's arrival-time feedback, not decoder/presenter statistics.
/// A negative margin means late arrival even if a codec later retains the frame.
package struct DisplayStreamReportWindow: Sendable {
    package let activation: SpiceMsgDisplayStreamActivateReport
    private var startedAt: ContinuousClock.Instant?
    private var startFrameTime: UInt32 = 0
    private var frames: UInt32 = 0
    private var drops: UInt32 = 0
    private var consecutiveDrops: UInt32 = 0

    package init(activation: SpiceMsgDisplayStreamActivateReport) {
        self.activation = activation
    }

    package mutating func record(
        multimediaTime: UInt32,
        margin: Int32,
        audioDelay: UInt32,
        now: ContinuousClock.Instant
    ) -> SpiceMsgcDisplayStreamReport? {
        if frames == 0 {
            startedAt = now
            startFrameTime = multimediaTime
        }
        frames += 1
        if margin < 0 {
            drops += 1
            consecutiveDrops += 1
        } else {
            consecutiveDrops = 0
        }
        let elapsed = startedAt.map { $0.duration(to: now) } ?? .zero
        // Like spice-gtk, timeout is checked when a frame arrives, in local
        // monotonic time. An idle stream does not generate empty reports.
        guard frames >= activation.maximumWindowSize
            || elapsed >= .milliseconds(Int64(activation.timeoutMilliseconds))
            || consecutiveDrops >= 3
        else { return nil }

        let report = SpiceMsgcDisplayStreamReport(
            streamID: activation.streamID,
            uniqueID: activation.uniqueID,
            startFrameMultimediaTime: startFrameTime,
            endFrameMultimediaTime: multimediaTime,
            frameCount: frames,
            dropCount: drops,
            lastFrameDelay: margin,
            audioDelay: audioDelay
        )
        startedAt = nil
        frames = 0
        drops = 0
        consecutiveDrops = 0
        return report
    }
}
