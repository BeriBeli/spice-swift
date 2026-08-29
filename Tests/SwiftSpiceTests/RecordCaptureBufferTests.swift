import Foundation
import Synchronization
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
        #expect(queued.preallocatedBytes == 16)
        #expect(queued.preallocatedStagingBytes == 0)
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
        let expectedPackets = [RecordedAudioPacket(
            timestamp: 2,
            data: Data(repeating: 2, count: 6)
        )]
        #expect(drain.droppedBytes == 4)
        #expect(drain.packets == expectedPackets)
        let expectedEmptyDrain = RecordCaptureDrain(
            packets: [],
            droppedBytes: 0,
            failure: nil
        )
        let emptyDrain = buffer.drain()
        #expect(emptyDrain == expectedEmptyDrain)
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
        buffer.fail(.converter)

        let expectedDrain = RecordCaptureDrain(
            packets: [],
            droppedBytes: 6,
            failure: "audio converter failed",
            failureToken: .converter
        )
        let drain = buffer.drain()
        #expect(drain == expectedDrain)
        let secondDrain = buffer.drain()
        #expect(secondDrain.failure == nil)
        #expect(secondDrain.failureToken == nil)
        let diagnostics = buffer.diagnostics()
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.retainedSlots == 0)
        #expect(diagnostics.linearMovementBytes == 0)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        #expect(diagnostics.perPacketStorageAllocations == 0)
    }

    @Test func drainConsumesOnlyTheEntrySlotSnapshotWhileProducersContinue() {
        let buffer = RecordCaptureBuffer(maximumBytes: 64, maximumPackets: 8)
        buffer.push(RecordedAudioPacket(timestamp: 1, data: Data([1])))
        buffer.push(RecordedAudioPacket(timestamp: 2, data: Data([2])))

        let snapshotBarrier = RecordCaptureBarrier()
        let snapshotCount = RecordCaptureLockedValue<Int?>(nil)
        let firstDrain = RecordCaptureLockedValue<RecordCaptureDrain?>(nil)
        let drainFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = buffer.drain { count in
                snapshotCount.store(count)
                snapshotBarrier.block()
            }
            firstDrain.store(result)
            drainFinished.signal()
        }
        #expect(snapshotBarrier.waitUntilEntered())
        #expect(snapshotCount.load() == 2)

        let producerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            for timestamp in UInt32(3) ... 6 {
                buffer.push(RecordedAudioPacket(
                    timestamp: timestamp,
                    data: Data([UInt8(timestamp)])
                ))
            }
            producerFinished.signal()
        }
        #expect(producerFinished.wait(timeout: .now() + 10) == .success)
        #expect(buffer.diagnostics().queuedSlots == 6)

        snapshotBarrier.release()
        #expect(drainFinished.wait(timeout: .now() + 10) == .success)
        let expectedFirstPackets = [
            RecordedAudioPacket(timestamp: 1, data: Data([1])),
            RecordedAudioPacket(timestamp: 2, data: Data([2])),
        ]
        #expect(firstDrain.load()?.packets == expectedFirstPackets)

        let secondDrain = buffer.drain()
        let expectedSecondTimestamps: [UInt32] = [3, 4, 5, 6]
        let actualSecondTimestamps = secondDrain.packets.map(\.timestamp)
        #expect(actualSecondTimestamps == expectedSecondTimestamps)
        let expectedSecondBytes = [Data([3]), Data([4]), Data([5]), Data([6])]
        let actualSecondBytes = secondDrain.packets.map(\.data)
        #expect(actualSecondBytes == expectedSecondBytes)
        let diagnostics = buffer.diagnostics()
        #expect(diagnostics.queuedSlots == 0)
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.retainedSlots == 0)
        #expect(diagnostics.linearMovementBytes == 0)
    }
}

private final class RecordCaptureBarrier: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    func block() {
        entered.signal()
        released.wait()
    }

    func waitUntilEntered() -> Bool {
        entered.wait(timeout: .now() + 10) == .success
    }

    func release() {
        released.signal()
    }
}

private final class RecordCaptureLockedValue<Value: Sendable>: @unchecked Sendable {
    private let storage: Mutex<Value>

    init(_ value: Value) {
        storage = Mutex(value)
    }

    func store(_ value: Value) {
        storage.withLock { $0 = value }
    }

    func load() -> Value {
        storage.withLock { $0 }
    }
}
