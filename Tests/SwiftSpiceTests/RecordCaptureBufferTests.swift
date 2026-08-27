import Foundation
import Testing
@testable import SwiftSpice

@Suite("Record capture buffer")
struct RecordCaptureBufferTests {
    @Test func realtimeRawPushUsesPreallocatedRingAndCloseReleasesIt() {
        let buffer = RecordCaptureBuffer(maximumBytes: 16, maximumPackets: 2)
        let bytes: [UInt8] = [1, 2, 3, 4, 5, 6]
        let result = bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            buffer.push(timestamp: 42, bytes: raw)
        }

        #expect(result == .enqueued(droppedPackets: 0, droppedBytes: 0))
        let queued = buffer.diagnostics()
        #expect(queued.queuedBytes == bytes.count)
        #expect(queued.queuedSlots == 1)
        #expect(queued.retainedSlots == 1)
        #expect(queued.linearMovementBytes == 0)
        #expect(queued.callbackDynamicAllocations == 0)
        #expect(queued.perPacketStorageAllocations == 0)

        buffer.close()
        let closed = buffer.diagnostics()
        #expect(closed.isClosed)
        #expect(closed.queuedBytes == 0)
        #expect(closed.queuedSlots == 0)
        #expect(closed.retainedSlots == 0)
        #expect(closed.closeCount == 1)
    }

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
        let diagnostics = buffer.diagnostics()
        #expect(diagnostics.preallocatedBytes == 8)
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.queuedSlots == 0)
        #expect(diagnostics.retainedSlots == 0)
        #expect(diagnostics.linearMovementBytes == 0)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        #expect(diagnostics.perPacketStorageAllocations == 0)
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
        let diagnostics = buffer.diagnostics()
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.retainedSlots == 0)
        #expect(diagnostics.linearMovementBytes == 0)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        #expect(diagnostics.perPacketStorageAllocations == 0)
    }
}
