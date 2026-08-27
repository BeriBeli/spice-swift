import Foundation
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
