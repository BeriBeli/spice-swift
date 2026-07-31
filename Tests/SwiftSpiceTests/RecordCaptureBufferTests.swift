import Foundation
import Testing
@testable import SwiftSpice

@Suite("Record capture buffer")
struct RecordCaptureBufferTests {
    @Test func dropsOldestPacketsToKeepLatencyBounded() {
        let buffer = RecordCaptureBuffer(maximumBytes: 8)
        buffer.push(RecordedAudioPacket(timestamp: 1, data: Data(repeating: 1, count: 4)))
        buffer.push(RecordedAudioPacket(timestamp: 2, data: Data(repeating: 2, count: 6)))

        let drain = buffer.drain()
        #expect(drain.droppedBytes == 4)
        #expect(drain.packets == [RecordedAudioPacket(
            timestamp: 2,
            data: Data(repeating: 2, count: 6)
        )])
        #expect(buffer.drain() == RecordCaptureDrain(
            packets: [],
            droppedBytes: 0,
            failure: nil
        ))
    }

    @Test func dropsOversizedPacketAndTransfersFailureOnce() {
        let buffer = RecordCaptureBuffer(maximumBytes: 4)
        buffer.push(RecordedAudioPacket(timestamp: 1, data: Data(repeating: 1, count: 6)))
        buffer.fail("conversion")

        #expect(buffer.drain() == RecordCaptureDrain(
            packets: [],
            droppedBytes: 6,
            failure: "conversion"
        ))
        #expect(buffer.drain().failure == nil)
    }
}
