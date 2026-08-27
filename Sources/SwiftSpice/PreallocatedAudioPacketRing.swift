import Foundation
import Synchronization

package enum AudioPacketRingEnqueueResult: Sendable, Equatable {
    case enqueued(droppedPackets: Int, droppedBytes: Int)
    case droppedOversized(byteCount: Int)
    case rejectedClosed(byteCount: Int)
}

package struct AudioPacketRingDiagnostics: Sendable, Equatable {
    package let capacityBytes: Int
    package let capacitySlots: Int
    package let preallocatedBytes: Int
    package let preallocatedSlots: Int
    package let queuedBytes: Int
    package let queuedSlots: Int
    package let enqueuedPackets: UInt64
    package let enqueuedBytes: UInt64
    package let dequeuedPackets: UInt64
    package let dequeuedBytes: UInt64
    package let readCalls: UInt64
    package let wraparoundCopies: UInt64
    package let underflows: UInt64
    package let overruns: UInt64
    package let droppedPackets: UInt64
    package let droppedBytes: UInt64
    package let linearMovementBytes: UInt64
    package let callbackDynamicAllocations: UInt64
    package let perPacketStorageAllocations: UInt64
    package let retainedSlots: Int
    package let resetCount: UInt64
    package let closeCount: UInt64
    package let isClosed: Bool
}

/// A fixed-storage packet FIFO shared by the network/async side and realtime
/// audio callbacks. Enqueue and whole-packet dequeue update indices in O(1);
/// stream reads may consume several packet boundaries without moving queued
/// storage. An overrun discards the complete queued prefix in O(1), preserving
/// FIFO order among every packet that remains observable.
package final class PreallocatedAudioPacketRing: @unchecked Sendable {
    private struct Slot: Sendable {
        var timestamp: UInt32 = 0
        var byteCount: Int = 0
        var consumedBytes: Int = 0
    }

    private struct State: Sendable {
        var slots: [Slot]
        var headSlot = 0
        var tailSlot = 0
        var queuedSlots = 0
        var readByteOffset = 0
        var writeByteOffset = 0
        var queuedBytes = 0
        var enqueuedPackets: UInt64 = 0
        var enqueuedBytes: UInt64 = 0
        var dequeuedPackets: UInt64 = 0
        var dequeuedBytes: UInt64 = 0
        var readCalls: UInt64 = 0
        var wraparoundCopies: UInt64 = 0
        var underflows: UInt64 = 0
        var overruns: UInt64 = 0
        var droppedPackets: UInt64 = 0
        var droppedBytes: UInt64 = 0
        var resetCount: UInt64 = 0
        var closeCount: UInt64 = 0
        var isClosed = false

        init(capacitySlots: Int) {
            slots = Array(repeating: Slot(), count: capacitySlots)
        }
    }

    private let capacityBytes: Int
    private let capacitySlots: Int
    private let storage: UnsafeMutableRawBufferPointer
    private let state: Mutex<State>

    package init(capacityBytes: Int, capacitySlots: Int) {
        precondition(capacityBytes > 0)
        precondition(capacitySlots > 0)
        self.capacityBytes = capacityBytes
        self.capacitySlots = capacitySlots
        storage = .allocate(byteCount: capacityBytes, alignment: 64)
        storage.initializeMemory(as: UInt8.self, repeating: 0)
        state = Mutex(State(capacitySlots: capacitySlots))
    }

    deinit {
        storage.deallocate()
    }

    package func enqueue(_ packet: RecordedAudioPacket) -> AudioPacketRingEnqueueResult {
        packet.data.withUnsafeBytes { bytes in
            enqueue(timestamp: packet.timestamp, bytes: bytes)
        }
    }

    /// Copies one packet into the preallocated owner. The pointer borrow is
    /// synchronous and never escapes this call.
    package func enqueue(
        timestamp: UInt32,
        bytes: UnsafeRawBufferPointer
    ) -> AudioPacketRingEnqueueResult {
        guard bytes.count > 0 else {
            return state.withLock { state in
                state.isClosed
                    ? .rejectedClosed(byteCount: 0)
                    : .enqueued(droppedPackets: 0, droppedBytes: 0)
            }
        }
        return state.withLock { state in
            guard !state.isClosed else {
                return .rejectedClosed(byteCount: bytes.count)
            }
            guard bytes.count <= capacityBytes else {
                Self.add(&state.droppedPackets, 1)
                Self.add(&state.droppedBytes, bytes.count)
                return .droppedOversized(byteCount: bytes.count)
            }

            let mustDiscardQueuedPrefix = state.queuedSlots == capacitySlots
                || bytes.count > capacityBytes - state.queuedBytes
            let droppedPackets: Int
            let droppedBytes: Int
            if mustDiscardQueuedPrefix {
                droppedPackets = state.queuedSlots
                droppedBytes = state.queuedBytes
                Self.add(&state.overruns, 1)
                Self.add(&state.droppedPackets, droppedPackets)
                Self.add(&state.droppedBytes, droppedBytes)
                clearQueue(&state)
            } else {
                droppedPackets = 0
                droppedBytes = 0
            }

            copyIntoStorage(bytes, at: state.writeByteOffset, state: &state)
            var slot = state.slots[state.tailSlot]
            slot.timestamp = timestamp
            slot.byteCount = bytes.count
            slot.consumedBytes = 0
            state.slots[state.tailSlot] = slot
            state.tailSlot = Self.advanced(state.tailSlot, capacity: capacitySlots)
            state.queuedSlots += 1
            state.queuedBytes += bytes.count
            state.writeByteOffset = Self.advanced(
                state.writeByteOffset,
                by: bytes.count,
                capacity: capacityBytes
            )
            Self.add(&state.enqueuedPackets, 1)
            Self.add(&state.enqueuedBytes, bytes.count)
            return .enqueued(
                droppedPackets: droppedPackets,
                droppedBytes: droppedBytes
            )
        }
    }

    /// Materializes one packet only on the non-realtime subsystem boundary.
    /// Packet storage itself remains the single fixed allocation owned here.
    package func dequeue() -> RecordedAudioPacket? {
        state.withLock { state in
            guard state.queuedSlots > 0 else {
                return nil
            }
            let slot = state.slots[state.headSlot]
            let remaining = slot.byteCount - slot.consumedBytes
            var data = Data(count: remaining)
            data.withUnsafeMutableBytes { destination in
                copyFromStorage(
                    at: state.readByteOffset,
                    into: destination,
                    count: remaining,
                    state: &state
                )
            }
            let packet = RecordedAudioPacket(timestamp: slot.timestamp, data: data)
            consumeBytes(remaining, fromHeadSlot: &state)
            return packet
        }
    }

    /// Copies the FIFO byte stream into a callback-owned destination. Any
    /// underflow suffix is zeroed in place and the returned count reports only
    /// bytes consumed from the ring.
    package func read(into destination: UnsafeMutableRawBufferPointer) -> Int {
        guard destination.count > 0 else {
            return 0
        }
        destination.initializeMemory(as: UInt8.self, repeating: 0)
        return state.withLock { state in
            guard !state.isClosed else {
                return 0
            }
            Self.add(&state.readCalls, 1)
            var copied = 0
            while copied < destination.count, state.queuedSlots > 0 {
                let slot = state.slots[state.headSlot]
                let remainingInSlot = slot.byteCount - slot.consumedBytes
                let chunk = min(remainingInSlot, destination.count - copied)
                let target = UnsafeMutableRawBufferPointer(rebasing: destination[copied...])
                copyFromStorage(
                    at: state.readByteOffset,
                    into: target,
                    count: chunk,
                    state: &state
                )
                consumeBytes(chunk, fromHeadSlot: &state)
                copied += chunk
            }
            if copied < destination.count {
                Self.add(&state.underflows, 1)
            }
            return copied
        }
    }

    package func reset() {
        state.withLock { state in
            guard !state.isClosed else {
                return
            }
            clearQueue(&state)
            Self.add(&state.resetCount, 1)
        }
    }

    package func close() {
        state.withLock { state in
            guard !state.isClosed else {
                return
            }
            clearQueue(&state)
            state.isClosed = true
            Self.add(&state.closeCount, 1)
        }
    }

    package func diagnostics() -> AudioPacketRingDiagnostics {
        state.withLock { state in
            AudioPacketRingDiagnostics(
                capacityBytes: capacityBytes,
                capacitySlots: capacitySlots,
                preallocatedBytes: capacityBytes,
                preallocatedSlots: capacitySlots,
                queuedBytes: state.queuedBytes,
                queuedSlots: state.queuedSlots,
                enqueuedPackets: state.enqueuedPackets,
                enqueuedBytes: state.enqueuedBytes,
                dequeuedPackets: state.dequeuedPackets,
                dequeuedBytes: state.dequeuedBytes,
                readCalls: state.readCalls,
                wraparoundCopies: state.wraparoundCopies,
                underflows: state.underflows,
                overruns: state.overruns,
                droppedPackets: state.droppedPackets,
                droppedBytes: state.droppedBytes,
                linearMovementBytes: 0,
                callbackDynamicAllocations: 0,
                perPacketStorageAllocations: 0,
                retainedSlots: state.queuedSlots,
                resetCount: state.resetCount,
                closeCount: state.closeCount,
                isClosed: state.isClosed
            )
        }
    }

    private func copyIntoStorage(
        _ source: UnsafeRawBufferPointer,
        at offset: Int,
        state: inout State
    ) {
        let firstCount = min(source.count, capacityBytes - offset)
        if firstCount > 0 {
            storage.baseAddress!.advanced(by: offset).copyMemory(
                from: source.baseAddress!,
                byteCount: firstCount
            )
        }
        let secondCount = source.count - firstCount
        if secondCount > 0 {
            storage.baseAddress!.copyMemory(
                from: source.baseAddress!.advanced(by: firstCount),
                byteCount: secondCount
            )
            Self.add(&state.wraparoundCopies, 1)
        }
    }

    private func copyFromStorage(
        at offset: Int,
        into destination: UnsafeMutableRawBufferPointer,
        count: Int,
        state: inout State
    ) {
        guard count > 0 else {
            return
        }
        let firstCount = min(count, capacityBytes - offset)
        destination.baseAddress!.copyMemory(
            from: storage.baseAddress!.advanced(by: offset),
            byteCount: firstCount
        )
        let secondCount = count - firstCount
        if secondCount > 0 {
            destination.baseAddress!.advanced(by: firstCount).copyMemory(
                from: storage.baseAddress!,
                byteCount: secondCount
            )
            Self.add(&state.wraparoundCopies, 1)
        }
    }

    private func consumeBytes(_ count: Int, fromHeadSlot state: inout State) {
        guard count > 0 else {
            return
        }
        state.readByteOffset = Self.advanced(
            state.readByteOffset,
            by: count,
            capacity: capacityBytes
        )
        state.queuedBytes -= count
        Self.add(&state.dequeuedBytes, count)
        state.slots[state.headSlot].consumedBytes += count
        if state.slots[state.headSlot].consumedBytes == state.slots[state.headSlot].byteCount {
            state.slots[state.headSlot] = Slot()
            state.headSlot = Self.advanced(state.headSlot, capacity: capacitySlots)
            state.queuedSlots -= 1
            Self.add(&state.dequeuedPackets, 1)
        }
        if state.queuedSlots == 0 {
            state.headSlot = state.tailSlot
            state.readByteOffset = state.writeByteOffset
        }
    }

    private func clearQueue(_ state: inout State) {
        state.headSlot = 0
        state.tailSlot = 0
        state.queuedSlots = 0
        state.readByteOffset = 0
        state.writeByteOffset = 0
        state.queuedBytes = 0
    }

    private static func advanced(_ index: Int, capacity: Int) -> Int {
        index + 1 == capacity ? 0 : index + 1
    }

    private static func advanced(_ index: Int, by distance: Int, capacity: Int) -> Int {
        let remaining = capacity - index
        return distance < remaining ? index + distance : distance - remaining
    }

    private static func add(_ value: inout UInt64, _ increment: Int) {
        add(&value, UInt64(increment))
    }

    private static func add(_ value: inout UInt64, _ increment: UInt64) {
        let (sum, overflow) = value.addingReportingOverflow(increment)
        value = overflow ? .max : sum
    }
}
