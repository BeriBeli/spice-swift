import Foundation
import Synchronization
import Testing
@testable import SwiftSpice

@Suite("Preallocated realtime audio packet ring")
struct PreallocatedAudioPacketRingTests {
    @Test("initialization performs all storage allocation up front")
    func storageIsFixedAtInitialization() {
        let ring = PreallocatedAudioPacketRing(capacityBytes: 64, capacitySlots: 8)
        let diagnostics = ring.diagnostics()

        #expect(diagnostics.capacityBytes == 64)
        #expect(diagnostics.capacitySlots == 8)
        #expect(diagnostics.preallocatedBytes == 64)
        #expect(diagnostics.preallocatedSlots == 8)
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.queuedSlots == 0)
        #expect(diagnostics.retainedSlots == 0)
        #expect(diagnostics.linearMovementBytes == 0)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        #expect(diagnostics.perPacketStorageAllocations == 0)
        #expect(!diagnostics.isClosed)
    }

    @Test("FIFO survives byte-storage and slot-index wraparound")
    func fifoAndWraparoundRemainBitExact() {
        let ring = PreallocatedAudioPacketRing(capacityBytes: 8, capacitySlots: 3)
        #expect(Self.enqueue([1, 2, 3], timestamp: 1, into: ring) == .enqueued(
            droppedPackets: 0,
            droppedBytes: 0
        ))
        #expect(Self.enqueue([4, 5, 6], timestamp: 2, into: ring) == .enqueued(
            droppedPackets: 0,
            droppedBytes: 0
        ))
        #expect(ring.dequeue() == RecordedAudioPacket(
            timestamp: 1,
            data: Data([1, 2, 3])
        ))
        #expect(Self.enqueue([7, 8, 9, 10], timestamp: 3, into: ring) == .enqueued(
            droppedPackets: 0,
            droppedBytes: 0
        ))

        #expect(ring.dequeue() == RecordedAudioPacket(
            timestamp: 2,
            data: Data([4, 5, 6])
        ))
        #expect(ring.dequeue() == RecordedAudioPacket(
            timestamp: 3,
            data: Data([7, 8, 9, 10])
        ))
        #expect(ring.dequeue() == nil)

        let diagnostics = ring.diagnostics()
        #expect(diagnostics.wraparoundCopies > 0)
        #expect(diagnostics.enqueuedPackets == 3)
        #expect(diagnostics.enqueuedBytes == 10)
        #expect(diagnostics.dequeuedPackets == 3)
        #expect(diagnostics.dequeuedBytes == 10)
        Self.expectRealtimeCountersRemainZero(diagnostics)
    }

    @Test("render reads cross packet boundaries and zero-fill underflow")
    func readSpansPacketsPartialPacketsAndFrames() {
        let ring = PreallocatedAudioPacketRing(capacityBytes: 16, capacitySlots: 4)
        _ = Self.enqueue([1, 2, 3], timestamp: 1, into: ring)
        _ = Self.enqueue([4, 5], timestamp: 2, into: ring)
        _ = Self.enqueue([6, 7, 8, 9], timestamp: 3, into: ring)

        var stereoFrame = [UInt8](repeating: 0xff, count: 4)
        let firstRead = stereoFrame.withUnsafeMutableBytes {
            (bytes: UnsafeMutableRawBufferPointer) in ring.read(into: bytes)
        }
        #expect(firstRead == 4)
        #expect(stereoFrame == [1, 2, 3, 4])

        var tailAndSilence = [UInt8](repeating: 0xff, count: 7)
        let secondRead = tailAndSilence.withUnsafeMutableBytes {
            (bytes: UnsafeMutableRawBufferPointer) in ring.read(into: bytes)
        }
        #expect(secondRead == 5)
        #expect(tailAndSilence == [5, 6, 7, 8, 9, 0, 0])

        let diagnostics = ring.diagnostics()
        #expect(diagnostics.readCalls == 2)
        #expect(diagnostics.underflows == 1)
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.queuedSlots == 0)
        #expect(diagnostics.retainedSlots == 0)
        Self.expectRealtimeCountersRemainZero(diagnostics)
    }

    @Test("overrun flushes old packets in O(1) and oversized input is dropped")
    func overrunAndOversizedPoliciesAreDeterministic() {
        let byteBounded = PreallocatedAudioPacketRing(capacityBytes: 8, capacitySlots: 3)
        _ = Self.enqueue([1, 1, 1, 1], timestamp: 1, into: byteBounded)
        _ = Self.enqueue([2, 2, 2, 2], timestamp: 2, into: byteBounded)
        #expect(Self.enqueue([3, 3, 3], timestamp: 3, into: byteBounded) == .enqueued(
            droppedPackets: 2,
            droppedBytes: 8
        ))
        #expect(byteBounded.dequeue() == RecordedAudioPacket(
            timestamp: 3,
            data: Data([3, 3, 3])
        ))
        #expect(Self.enqueue(Array(repeating: 9, count: 9), timestamp: 4, into: byteBounded)
            == .droppedOversized(byteCount: 9))

        let byteDiagnostics = byteBounded.diagnostics()
        #expect(byteDiagnostics.overruns == 1)
        #expect(byteDiagnostics.droppedPackets == 3)
        #expect(byteDiagnostics.droppedBytes == 17)
        Self.expectRealtimeCountersRemainZero(byteDiagnostics)

        let slotBounded = PreallocatedAudioPacketRing(capacityBytes: 32, capacitySlots: 2)
        _ = Self.enqueue([1], timestamp: 1, into: slotBounded)
        _ = Self.enqueue([2], timestamp: 2, into: slotBounded)
        #expect(Self.enqueue([3], timestamp: 3, into: slotBounded) == .enqueued(
            droppedPackets: 2,
            droppedBytes: 2
        ))
        #expect(slotBounded.dequeue()?.timestamp == 3)
        #expect(slotBounded.diagnostics().linearMovementBytes == 0)
    }

    @Test("empty packets consume no slot and close releases all retained slots")
    func resetAndCloseReleaseCapacityExactlyOnce() {
        let ring = PreallocatedAudioPacketRing(capacityBytes: 8, capacitySlots: 2)
        #expect(Self.enqueue([], timestamp: 0, into: ring) == .enqueued(
            droppedPackets: 0,
            droppedBytes: 0
        ))
        #expect(ring.diagnostics().queuedSlots == 0)

        _ = Self.enqueue([1, 2, 3], timestamp: 1, into: ring)
        #expect(ring.diagnostics().retainedSlots == 1)
        ring.reset()
        #expect(ring.diagnostics().retainedSlots == 0)

        _ = Self.enqueue([4, 5], timestamp: 2, into: ring)
        ring.close()
        ring.close()
        #expect(Self.enqueue([6], timestamp: 3, into: ring) == .rejectedClosed(byteCount: 1))
        #expect(ring.dequeue() == nil)
        var silence = [UInt8](repeating: 0xff, count: 4)
        #expect(silence.withUnsafeMutableBytes {
            (bytes: UnsafeMutableRawBufferPointer) in ring.read(into: bytes)
        } == 0)
        #expect(silence == [0, 0, 0, 0])

        let diagnostics = ring.diagnostics()
        #expect(diagnostics.resetCount == 1)
        #expect(diagnostics.closeCount == 1)
        #expect(diagnostics.isClosed)
        #expect(diagnostics.queuedBytes == 0)
        #expect(diagnostics.queuedSlots == 0)
        #expect(diagnostics.retainedSlots == 0)
        Self.expectRealtimeCountersRemainZero(diagnostics)
    }

    @Test("Sendable producer and consumer preserve FIFO under interleaving")
    func concurrentProducerConsumerPreserveFIFO() async {
        let packetCount = 256
        let ring = PreallocatedAudioPacketRing(
            capacityBytes: packetCount * 2,
            capacitySlots: packetCount
        )

        async let producer = Self.produce(packetCount: packetCount, into: ring)
        async let consumer = Self.consume(packetCount: packetCount, from: ring)
        let (allEnqueued, packets) = await (producer, consumer)

        #expect(allEnqueued)
        #expect(packets.count == packetCount)
        #expect(packets.map(\.timestamp) == (0 ..< UInt32(packetCount)).map { $0 })
        for (index, packet) in packets.enumerated() {
            #expect(packet.data == Data([
                UInt8(truncatingIfNeeded: index),
                UInt8(truncatingIfNeeded: index >> 8),
            ]))
        }
        let diagnostics = ring.diagnostics()
        #expect(diagnostics.overruns == 0)
        #expect(diagnostics.retainedSlots == 0)
        Self.expectRealtimeCountersRemainZero(diagnostics)
    }

    @Test("reset rebases a late staged commit without reviving stale PCM")
    func resetDuringStagedEnqueuePublishesOnlyTheReservedPacket() {
        let ring = PreallocatedAudioPacketRing(
            capacityBytes: 16,
            capacitySlots: 4,
            supportsStagedEnqueue: true
        )
        #expect(Self.enqueue([1, 2, 3, 4], timestamp: 1, into: ring)
            == .enqueued(droppedPackets: 0, droppedBytes: 0))

        let barrier = StagedEnqueueBarrier()
        let stagedResult = LockedValue<AudioPacketRingEnqueueResult?>(nil)
        let stagedFinished = DispatchSemaphore(value: 0)
        let stagedBytes: [UInt8] = [9, 10, 11, 12]
        DispatchQueue.global(qos: .userInitiated).async {
            let result = stagedBytes.withUnsafeBytes {
                (bytes: UnsafeRawBufferPointer) in
                ring.enqueueStaged(
                    timestamp: 2,
                    bytes: bytes,
                    copyWillBegin: barrier.block
                ) { commit in
                    commit()
                }
            }
            stagedResult.store(result)
            stagedFinished.signal()
        }
        #expect(barrier.waitUntilEntered())
        #expect(ring.diagnostics().queuedBytes == 4)

        ring.reset()
        let afterReset = ring.diagnostics()
        #expect(afterReset.resetCount == 1)
        #expect(afterReset.queuedBytes == 0)
        #expect(afterReset.queuedSlots == 0)
        #expect(afterReset.retainedSlots == 0)

        barrier.release()
        #expect(stagedFinished.wait(timeout: .now() + 10) == .success)
        #expect(stagedResult.load() == .enqueued(droppedPackets: 0, droppedBytes: 0))
        #expect(Self.enqueue([13, 14], timestamp: 3, into: ring)
            == .enqueued(droppedPackets: 0, droppedBytes: 0))
        #expect(ring.dequeue() == RecordedAudioPacket(
            timestamp: 2,
            data: Data(stagedBytes)
        ))
        #expect(ring.dequeue() == RecordedAudioPacket(
            timestamp: 3,
            data: Data([13, 14])
        ))
        #expect(ring.dequeue() == nil)
        let finished = ring.diagnostics()
        #expect(finished.queuedBytes == 0)
        #expect(finished.queuedSlots == 0)
        #expect(finished.retainedSlots == 0)
        Self.expectRealtimeCountersRemainZero(finished)
    }

    @Test("dequeue materialization releases the producer mutex and preserves its lease")
    func dequeueMaterializationDoesNotBlockConcurrentEnqueue() {
        let ring = PreallocatedAudioPacketRing(capacityBytes: 12, capacitySlots: 3)
        _ = Self.enqueue([1, 2, 3, 4], timestamp: 1, into: ring)
        _ = Self.enqueue([5, 6, 7, 8], timestamp: 2, into: ring)
        let dequeue = Self.startBlockedDequeue(from: ring)

        #expect(dequeue.barrier.waitUntilEntered())
        let enqueueResult = LockedValue<AudioPacketRingEnqueueResult?>(nil)
        let enqueueFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            enqueueResult.store(Self.enqueue([9, 10, 11, 12], timestamp: 3, into: ring))
            enqueueFinished.signal()
        }

        #expect(enqueueFinished.wait(timeout: .now() + 10) == .success)
        #expect(enqueueResult.load() == .enqueued(droppedPackets: 0, droppedBytes: 0))
        let whileBlocked = ring.diagnostics()
        #expect(whileBlocked.activeDequeueLeases == 1)
        #expect(whileBlocked.dequeueLeaseStarts == 1)
        #expect(whileBlocked.dequeueLeaseFinishes == 0)
        #expect(whileBlocked.dequeueMaterializations == 0)
        #expect(whileBlocked.queuedBytes == 12)
        #expect(whileBlocked.queuedSlots == 3)

        dequeue.barrier.release()
        #expect(dequeue.finished.wait(timeout: .now() + 10) == .success)
        #expect(dequeue.packet.load() == RecordedAudioPacket(
            timestamp: 1,
            data: Data([1, 2, 3, 4])
        ))
        let afterFirst = ring.diagnostics()
        #expect(afterFirst.activeDequeueLeases == 0)
        #expect(afterFirst.dequeueLeaseFinishes == 1)
        #expect(afterFirst.dequeueMaterializations == 1)
        #expect(afterFirst.dequeueMaterializedBytes == 4)
        #expect(afterFirst.queuedBytes == 8)
        #expect(afterFirst.queuedSlots == 2)
        #expect(ring.dequeue() == RecordedAudioPacket(
            timestamp: 2,
            data: Data([5, 6, 7, 8])
        ))
        #expect(ring.dequeue() == RecordedAudioPacket(
            timestamp: 3,
            data: Data([9, 10, 11, 12])
        ))
        #expect(ring.diagnostics().retainedSlots == 0)
    }

    @Test("an active dequeue lease rejects only writes that could overwrite it")
    func activeLeaseMakesOverrunReadAndSecondDequeueDeterministic() {
        let ring = PreallocatedAudioPacketRing(capacityBytes: 8, capacitySlots: 2)
        _ = Self.enqueue([1, 2, 3, 4], timestamp: 1, into: ring)
        _ = Self.enqueue([5, 6, 7, 8], timestamp: 2, into: ring)
        let dequeue = Self.startBlockedDequeue(from: ring)
        #expect(dequeue.barrier.waitUntilEntered())

        #expect(Self.enqueue([9, 10, 11, 12], timestamp: 3, into: ring)
            == .droppedLeaseConflict(byteCount: 4))
        var playbackBytes = [UInt8](repeating: 0xff, count: 4)
        #expect(playbackBytes.withUnsafeMutableBytes {
            (bytes: UnsafeMutableRawBufferPointer) in ring.read(into: bytes)
        } == 0)
        #expect(playbackBytes == [0, 0, 0, 0])
        #expect(ring.dequeue() == nil)

        let whileBlocked = ring.diagnostics()
        #expect(whileBlocked.activeDequeueLeases == 1)
        #expect(whileBlocked.dequeueLeaseConflictDrops == 1)
        #expect(whileBlocked.dequeueBlockedReads == 1)
        #expect(whileBlocked.dequeueBlockedDequeues == 1)
        #expect(whileBlocked.queuedBytes == 8)
        #expect(whileBlocked.queuedSlots == 2)

        dequeue.barrier.release()
        #expect(dequeue.finished.wait(timeout: .now() + 10) == .success)
        #expect(dequeue.packet.load() == RecordedAudioPacket(
            timestamp: 1,
            data: Data([1, 2, 3, 4])
        ))
        #expect(ring.dequeue() == RecordedAudioPacket(
            timestamp: 2,
            data: Data([5, 6, 7, 8])
        ))
        #expect(ring.dequeue() == nil)
        let finished = ring.diagnostics()
        #expect(finished.activeDequeueLeases == 0)
        #expect(finished.retainedSlots == 0)
    }

    @Test("reset and close defer storage reclamation until an active lease finishes")
    func resetAndCloseDuringActiveLeaseReleaseEverythingExactlyOnce() {
        let resetRing = PreallocatedAudioPacketRing(capacityBytes: 12, capacitySlots: 3)
        _ = Self.enqueue([1, 2, 3, 4], timestamp: 1, into: resetRing)
        _ = Self.enqueue([5, 6, 7, 8], timestamp: 2, into: resetRing)
        let resetDequeue = Self.startBlockedDequeue(from: resetRing)
        #expect(resetDequeue.barrier.waitUntilEntered())

        resetRing.reset()
        let duringReset = resetRing.diagnostics()
        #expect(duringReset.resetCount == 1)
        #expect(duringReset.deferredResets == 1)
        #expect(duringReset.activeDequeueLeases == 1)
        #expect(duringReset.queuedBytes == 8)
        #expect(duringReset.retainedSlots == 2)
        #expect(Self.enqueue([9, 10, 11, 12], timestamp: 3, into: resetRing)
            == .droppedLeaseConflict(byteCount: 4))

        resetDequeue.barrier.release()
        #expect(resetDequeue.finished.wait(timeout: .now() + 10) == .success)
        #expect(resetDequeue.packet.load() == RecordedAudioPacket(
            timestamp: 1,
            data: Data([1, 2, 3, 4])
        ))
        let afterReset = resetRing.diagnostics()
        #expect(afterReset.activeDequeueLeases == 0)
        #expect(afterReset.queuedBytes == 0)
        #expect(afterReset.queuedSlots == 0)
        #expect(afterReset.retainedSlots == 0)

        let closeRing = PreallocatedAudioPacketRing(capacityBytes: 12, capacitySlots: 3)
        _ = Self.enqueue([21, 22, 23, 24], timestamp: 21, into: closeRing)
        _ = Self.enqueue([25, 26, 27, 28], timestamp: 22, into: closeRing)
        let closeDequeue = Self.startBlockedDequeue(from: closeRing)
        #expect(closeDequeue.barrier.waitUntilEntered())

        closeRing.close()
        closeRing.close()
        let duringClose = closeRing.diagnostics()
        #expect(duringClose.isClosed)
        #expect(duringClose.closeCount == 1)
        #expect(duringClose.deferredCloses == 1)
        #expect(duringClose.activeDequeueLeases == 1)
        #expect(duringClose.queuedBytes == 8)
        #expect(duringClose.retainedSlots == 2)
        #expect(Self.enqueue([29], timestamp: 23, into: closeRing)
            == .rejectedClosed(byteCount: 1))

        closeDequeue.barrier.release()
        #expect(closeDequeue.finished.wait(timeout: .now() + 10) == .success)
        #expect(closeDequeue.packet.load() == RecordedAudioPacket(
            timestamp: 21,
            data: Data([21, 22, 23, 24])
        ))
        let afterClose = closeRing.diagnostics()
        #expect(afterClose.activeDequeueLeases == 0)
        #expect(afterClose.queuedBytes == 0)
        #expect(afterClose.queuedSlots == 0)
        #expect(afterClose.retainedSlots == 0)
    }

    private static func produce(
        packetCount: Int,
        into ring: PreallocatedAudioPacketRing
    ) async -> Bool {
        for index in 0 ..< packetCount {
            let bytes = [
                UInt8(truncatingIfNeeded: index),
                UInt8(truncatingIfNeeded: index >> 8),
            ]
            let result = enqueue(bytes, timestamp: UInt32(index), into: ring)
            guard result == .enqueued(droppedPackets: 0, droppedBytes: 0) else {
                return false
            }
            await Task.yield()
        }
        return true
    }

    private static func consume(
        packetCount: Int,
        from ring: PreallocatedAudioPacketRing
    ) async -> [RecordedAudioPacket] {
        var packets: [RecordedAudioPacket] = []
        packets.reserveCapacity(packetCount)
        var attempts = 0
        while packets.count < packetCount, attempts < packetCount * 1_000 {
            if let packet = ring.dequeue() {
                packets.append(packet)
            } else {
                attempts += 1
                await Task.yield()
            }
        }
        return packets
    }

    private static func startBlockedDequeue(
        from ring: PreallocatedAudioPacketRing
    ) -> (
        barrier: DequeueMaterializationBarrier,
        packet: LockedValue<RecordedAudioPacket?>,
        finished: DispatchSemaphore
    ) {
        let barrier = DequeueMaterializationBarrier()
        let packet = LockedValue<RecordedAudioPacket?>(nil)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            packet.store(ring.dequeue(materializationWillBegin: barrier.block))
            finished.signal()
        }
        return (barrier, packet, finished)
    }

    private static func enqueue(
        _ bytes: [UInt8],
        timestamp: UInt32,
        into ring: PreallocatedAudioPacketRing
    ) -> AudioPacketRingEnqueueResult {
        bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            ring.enqueue(timestamp: timestamp, bytes: buffer)
        }
    }

    private static func expectRealtimeCountersRemainZero(
        _ diagnostics: AudioPacketRingDiagnostics
    ) {
        #expect(diagnostics.linearMovementBytes == 0)
        #expect(diagnostics.callbackDynamicAllocations == 0)
        #expect(diagnostics.perPacketStorageAllocations == 0)
    }
}

private final class DequeueMaterializationBarrier: @unchecked Sendable {
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

private final class StagedEnqueueBarrier: @unchecked Sendable {
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

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
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
