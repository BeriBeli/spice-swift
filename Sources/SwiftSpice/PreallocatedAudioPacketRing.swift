import Foundation
import Synchronization

package enum AudioPacketRingCapacityError: Error, Sendable, Equatable {
    case invalidCapacityBytes(Int)
    case invalidMinimumPacketBytes(Int)
    case minimumPacketExceedsCapacity(minimum: Int, capacity: Int)
}

package enum AudioPacketRingAllocationLimitError: Error, Sendable, Equatable {
    case invalidCapacityBytes(Int)
    case invalidCapacitySlots(Int)
    case payloadCapacityExceeded(actual: Int, maximum: Int)
    case slotCapacityExceeded(actual: Int, maximum: Int)
    case stagingCapacityExceeded(actual: Int, maximum: Int)
    case totalPreallocationExceeded(actual: Int, maximum: Int)
}

/// One resource policy is shared by playback and capture before either path
/// allocates payload storage or packet metadata. The logical queue is capped at
/// sixteen MiB. Playback may reserve one equally bounded unpublished staging
/// bank, making its explicit total payload preallocation cap thirty-two MiB;
/// capture keeps only the queue bank. The independent slot bound prevents
/// one-frame packets from amplifying metadata.
package enum AudioPacketRingAllocationLimits {
    package static let maximumPayloadBytes = 16 * 1_024 * 1_024
    package static let maximumStagingBytes = maximumPayloadBytes
    package static let maximumTotalPreallocatedBytes =
        maximumPayloadBytes + maximumStagingBytes
    package static let maximumSlotCount = 262_144

    package static func validate(
        capacityBytes: Int,
        capacitySlots: Int,
        stagingBytes: Int = 0
    ) throws(AudioPacketRingAllocationLimitError) -> AudioPacketRingCapacity {
        guard capacityBytes > 0 else {
            throw .invalidCapacityBytes(capacityBytes)
        }
        guard capacitySlots > 0 else {
            throw .invalidCapacitySlots(capacitySlots)
        }
        guard capacityBytes <= maximumPayloadBytes else {
            throw .payloadCapacityExceeded(
                actual: capacityBytes,
                maximum: maximumPayloadBytes
            )
        }
        guard capacitySlots <= maximumSlotCount else {
            throw .slotCapacityExceeded(
                actual: capacitySlots,
                maximum: maximumSlotCount
            )
        }
        guard stagingBytes >= 0,
              stagingBytes <= maximumStagingBytes else {
            throw .stagingCapacityExceeded(
                actual: stagingBytes,
                maximum: maximumStagingBytes
            )
        }
        let (totalPreallocatedBytes, totalOverflow) = capacityBytes
            .addingReportingOverflow(stagingBytes)
        guard !totalOverflow,
              totalPreallocatedBytes <= maximumTotalPreallocatedBytes else {
            throw .totalPreallocationExceeded(
                actual: totalOverflow ? .max : totalPreallocatedBytes,
                maximum: maximumTotalPreallocatedBytes
            )
        }
        return AudioPacketRingCapacity(
            capacityBytes: capacityBytes,
            capacitySlots: capacitySlots
        )
    }
}

package struct AudioPacketRingCapacity: Sendable, Equatable {
    package let capacityBytes: Int
    package let capacitySlots: Int

    package init(capacityBytes: Int, capacitySlots: Int) {
        self.capacityBytes = capacityBytes
        self.capacitySlots = capacitySlots
    }

    package static func slotCount(
        capacityBytes: Int,
        minimumPacketBytes: Int
    ) throws(AudioPacketRingCapacityError) -> Int {
        guard capacityBytes > 0 else {
            throw .invalidCapacityBytes(capacityBytes)
        }
        guard minimumPacketBytes > 0 else {
            throw .invalidMinimumPacketBytes(minimumPacketBytes)
        }
        guard minimumPacketBytes <= capacityBytes else {
            throw .minimumPacketExceedsCapacity(
                minimum: minimumPacketBytes,
                capacity: capacityBytes
            )
        }
        return capacityBytes / minimumPacketBytes
    }
}

package enum AudioPacketRingEnqueueResult: Sendable, Equatable {
    case enqueued(droppedPackets: Int, droppedBytes: Int)
    case droppedOversized(byteCount: Int)
    case droppedLeaseConflict(byteCount: Int)
    case rejectedClosed(byteCount: Int)
}

package struct AudioPacketRingDiagnostics: Sendable, Equatable {
    package let capacityBytes: Int
    package let capacitySlots: Int
    package let preallocatedBytes: Int
    package let preallocatedStagingBytes: Int
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
    package let activeDequeueLeases: Int
    package let dequeueLeaseStarts: UInt64
    package let dequeueLeaseFinishes: UInt64
    package let dequeueMaterializations: UInt64
    package let dequeueMaterializedBytes: UInt64
    package let dequeueLeaseConflictDrops: UInt64
    package let dequeueBlockedReads: UInt64
    package let dequeueBlockedDequeues: UInt64
    package let deferredResets: UInt64
    package let deferredCloses: UInt64
    package let isClosed: Bool
}

/// A fixed-storage packet FIFO shared by the network/async side and realtime
/// audio callbacks. Enqueue and whole-packet dequeue update indices in O(1);
/// stream reads may consume several packet boundaries without moving queued
/// storage. An overrun discards the complete queued prefix in O(1), preserving
/// FIFO order among every packet that remains observable.
package final class PreallocatedAudioPacketRing: @unchecked Sendable {
    package typealias DequeueObserver = @Sendable () -> Void
    package typealias EnqueueObserver = @Sendable () -> Void

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
        var nextDequeueLeaseToken: UInt64 = 0
        var activeDequeueLeaseToken: UInt64?
        var dequeueLeaseStarts: UInt64 = 0
        var dequeueLeaseFinishes: UInt64 = 0
        var dequeueMaterializations: UInt64 = 0
        var dequeueMaterializedBytes: UInt64 = 0
        var dequeueLeaseConflictDrops: UInt64 = 0
        var dequeueBlockedReads: UInt64 = 0
        var dequeueBlockedDequeues: UInt64 = 0
        var deferredResets: UInt64 = 0
        var deferredCloses: UInt64 = 0
        var pendingReset = false
        var pendingClose = false
        var isClosed = false
        var activeStorageIndex = 0
        var nextEnqueueReservationToken: UInt64 = 0
        var activeEnqueueReservationToken: UInt64?

        init(capacitySlots: Int) {
            slots = Array(repeating: Slot(), count: capacitySlots)
        }
    }

    private struct DequeueLease: Sendable {
        let token: UInt64
        let timestamp: UInt32
        let storageIndex: Int
        let byteOffset: Int
        let byteCount: Int
    }

    private struct EnqueueReservation: Sendable {
        let token: UInt64
        let timestamp: UInt32
        let storageIndex: Int
        let byteOffset: Int
        let byteCount: Int
        let replacesQueue: Bool
    }

    private enum EnqueuePreparation: Sendable {
        case immediate(AudioPacketRingEnqueueResult)
        case reserved(EnqueueReservation)
    }

    private let capacityBytes: Int
    private let capacitySlots: Int
    private let primaryStorage: UnsafeMutableRawBufferPointer
    private let stagingStorage: UnsafeMutableRawBufferPointer?
    private let enqueueProducer = Mutex(())
    private let state: Mutex<State>

    package init(
        capacityBytes: Int,
        capacitySlots: Int,
        supportsStagedEnqueue: Bool = false
    ) {
        precondition(capacityBytes > 0)
        precondition(capacitySlots > 0)
        let stagingByteCount = supportsStagedEnqueue ? capacityBytes : 0
        let (totalPreallocatedBytes, totalOverflow) = capacityBytes
            .addingReportingOverflow(stagingByteCount)
        precondition(
            !totalOverflow
                && totalPreallocatedBytes
                    <= AudioPacketRingAllocationLimits.maximumTotalPreallocatedBytes
        )
        self.capacityBytes = capacityBytes
        self.capacitySlots = capacitySlots
        primaryStorage = .allocate(byteCount: capacityBytes, alignment: 64)
        primaryStorage.initializeMemory(as: UInt8.self, repeating: 0)
        if supportsStagedEnqueue {
            let storage = UnsafeMutableRawBufferPointer.allocate(
                byteCount: capacityBytes,
                alignment: 64
            )
            storage.initializeMemory(as: UInt8.self, repeating: 0)
            stagingStorage = storage
        } else {
            stagingStorage = nil
        }
        state = Mutex(State(capacitySlots: capacitySlots))
    }

    deinit {
        primaryStorage.deallocate()
        stagingStorage?.deallocate()
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
        enqueueProducer.withLock { _ in
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
                if state.activeDequeueLeaseToken != nil,
                   mustDiscardQueuedPrefix || state.pendingReset {
                    Self.recordLeaseConflictDrop(byteCount: bytes.count, state: &state)
                    return .droppedLeaseConflict(byteCount: bytes.count)
                }
                let droppedPackets: Int
                let droppedBytes: Int
                if mustDiscardQueuedPrefix {
                    droppedPackets = state.queuedSlots
                    droppedBytes = state.queuedBytes
                    Self.recordQueueReplacement(
                        droppedPackets: droppedPackets,
                        droppedBytes: droppedBytes,
                        state: &state
                    )
                    clearQueue(&state)
                } else {
                    droppedPackets = 0
                    droppedBytes = 0
                }

                copyIntoStorage(
                    bytes,
                    storageIndex: state.activeStorageIndex,
                    at: state.writeByteOffset,
                    state: &state
                )
                publishSlot(
                    timestamp: timestamp,
                    byteOffset: state.writeByteOffset,
                    byteCount: bytes.count,
                    state: &state
                )
                return .enqueued(
                    droppedPackets: droppedPackets,
                    droppedBytes: droppedBytes
                )
            }
        }
    }

    /// Copies a packet into an unpublished, preallocated range while realtime
    /// reads continue consuming the visible queue. `publication` must invoke
    /// its commit closure synchronously inside the caller's short publication
    /// critical section. The commit itself only updates metadata or swaps the
    /// active backing bank; it never copies payload bytes.
    package func enqueueStaged(
        timestamp: UInt32,
        bytes: UnsafeRawBufferPointer,
        copyWillBegin observer: EnqueueObserver? = nil,
        publication: (_ commit: () -> AudioPacketRingEnqueueResult)
            -> AudioPacketRingEnqueueResult
    ) -> AudioPacketRingEnqueueResult {
        enqueueProducer.withLock { _ in
            let preparation = beginStagedEnqueue(
                timestamp: timestamp,
                byteCount: bytes.count
            )
            guard case let .reserved(reservation) = preparation else {
                if case let .immediate(result) = preparation {
                    return result
                }
                preconditionFailure("unreachable enqueue preparation")
            }

            var committedResult: AudioPacketRingEnqueueResult?
            defer {
                if committedResult == nil {
                    abortStagedEnqueue(reservation)
                }
            }
            observer?()
            let wrapped = copyIntoStorageOutsideLock(
                bytes,
                storageIndex: reservation.storageIndex,
                at: reservation.byteOffset
            )
            return publication {
                if let committedResult {
                    return committedResult
                }
                let result = commitStagedEnqueue(reservation, wrapped: wrapped)
                committedResult = result
                return result
            }
        }
    }

    private func beginStagedEnqueue(
        timestamp: UInt32,
        byteCount: Int
    ) -> EnqueuePreparation {
        precondition(stagingStorage != nil)
        return state.withLock { state in
            guard !state.isClosed else {
                return .immediate(.rejectedClosed(byteCount: byteCount))
            }
            guard byteCount > 0 else {
                return .immediate(.enqueued(droppedPackets: 0, droppedBytes: 0))
            }
            guard byteCount <= capacityBytes else {
                Self.add(&state.droppedPackets, 1)
                Self.add(&state.droppedBytes, byteCount)
                return .immediate(.droppedOversized(byteCount: byteCount))
            }
            precondition(state.activeEnqueueReservationToken == nil)

            let replacesQueue = state.queuedSlots == capacitySlots
                || byteCount > capacityBytes - state.queuedBytes
            if state.activeDequeueLeaseToken != nil,
               replacesQueue || state.pendingReset {
                Self.recordLeaseConflictDrop(byteCount: byteCount, state: &state)
                return .immediate(.droppedLeaseConflict(byteCount: byteCount))
            }

            state.nextEnqueueReservationToken &+= 1
            let token = state.nextEnqueueReservationToken
            state.activeEnqueueReservationToken = token
            return .reserved(EnqueueReservation(
                token: token,
                timestamp: timestamp,
                storageIndex: replacesQueue ? 1 - state.activeStorageIndex
                    : state.activeStorageIndex,
                byteOffset: replacesQueue ? 0 : state.writeByteOffset,
                byteCount: byteCount,
                replacesQueue: replacesQueue
            ))
        }
    }

    private func commitStagedEnqueue(
        _ reservation: EnqueueReservation,
        wrapped: Bool
    ) -> AudioPacketRingEnqueueResult {
        state.withLock { state in
            precondition(state.activeEnqueueReservationToken == reservation.token)
            state.activeEnqueueReservationToken = nil
            guard !state.isClosed else {
                return .rejectedClosed(byteCount: reservation.byteCount)
            }
            if state.activeDequeueLeaseToken != nil,
               reservation.replacesQueue || state.pendingReset {
                Self.recordLeaseConflictDrop(
                    byteCount: reservation.byteCount,
                    state: &state
                )
                return .droppedLeaseConflict(byteCount: reservation.byteCount)
            }

            let droppedPackets: Int
            let droppedBytes: Int
            if reservation.replacesQueue {
                droppedPackets = state.queuedSlots
                droppedBytes = state.queuedBytes
                if droppedPackets > 0 || droppedBytes > 0 {
                    Self.recordQueueReplacement(
                        droppedPackets: droppedPackets,
                        droppedBytes: droppedBytes,
                        state: &state
                    )
                }
                clearQueue(&state)
                state.activeStorageIndex = reservation.storageIndex
            } else {
                precondition(state.activeStorageIndex == reservation.storageIndex)
                if state.writeByteOffset != reservation.byteOffset {
                    // A concurrent reset may clear the visible queue while the
                    // producer copies. The enqueue linearizes after that reset,
                    // so the reserved range becomes the new queue origin.
                    precondition(state.queuedSlots == 0)
                    state.headSlot = 0
                    state.tailSlot = 0
                    state.readByteOffset = reservation.byteOffset
                    state.writeByteOffset = reservation.byteOffset
                }
                droppedPackets = 0
                droppedBytes = 0
            }

            if wrapped {
                Self.add(&state.wraparoundCopies, 1)
            }
            publishSlot(
                timestamp: reservation.timestamp,
                byteOffset: reservation.byteOffset,
                byteCount: reservation.byteCount,
                state: &state
            )
            return .enqueued(
                droppedPackets: droppedPackets,
                droppedBytes: droppedBytes
            )
        }
    }

    private func abortStagedEnqueue(_ reservation: EnqueueReservation) {
        state.withLock { state in
            if state.activeEnqueueReservationToken == reservation.token {
                state.activeEnqueueReservationToken = nil
            }
        }
    }

    /// Materializes one packet only on the non-realtime subsystem boundary.
    /// A short locked phase reserves the head range; allocation and payload
    /// copy happen while the producer mutex is released; a second short phase
    /// consumes the token. The optional observer is invoked after reservation
    /// and before allocation so deterministic tests can prove the lock is free.
    package func dequeue(
        materializationWillBegin observer: DequeueObserver? = nil
    ) -> RecordedAudioPacket? {
        guard let lease = beginDequeueLease() else {
            return nil
        }
        observer?()
        var data = Data(count: lease.byteCount)
        let wrapped = data.withUnsafeMutableBytes { destination in
            copyFromStorageOutsideLock(
                storageIndex: lease.storageIndex,
                at: lease.byteOffset,
                into: destination,
                count: lease.byteCount
            )
        }
        finishDequeueLease(lease, wrapped: wrapped)
        return RecordedAudioPacket(timestamp: lease.timestamp, data: data)
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
            guard state.activeDequeueLeaseToken == nil else {
                Self.add(&state.dequeueBlockedReads, 1)
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
                    storageIndex: state.activeStorageIndex,
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
            Self.add(&state.resetCount, 1)
            if state.activeDequeueLeaseToken != nil {
                state.pendingReset = true
                Self.add(&state.deferredResets, 1)
            } else {
                clearQueue(&state)
            }
        }
    }

    package func close() {
        state.withLock { state in
            guard !state.isClosed else {
                return
            }
            state.isClosed = true
            Self.add(&state.closeCount, 1)
            if state.activeDequeueLeaseToken != nil {
                state.pendingClose = true
                Self.add(&state.deferredCloses, 1)
            } else {
                clearQueue(&state)
            }
        }
    }

    package func diagnostics() -> AudioPacketRingDiagnostics {
        state.withLock { state in
            AudioPacketRingDiagnostics(
                capacityBytes: capacityBytes,
                capacitySlots: capacitySlots,
                preallocatedBytes: capacityBytes
                    + (stagingStorage == nil ? 0 : capacityBytes),
                preallocatedStagingBytes: stagingStorage == nil ? 0 : capacityBytes,
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
                activeDequeueLeases: state.activeDequeueLeaseToken == nil ? 0 : 1,
                dequeueLeaseStarts: state.dequeueLeaseStarts,
                dequeueLeaseFinishes: state.dequeueLeaseFinishes,
                dequeueMaterializations: state.dequeueMaterializations,
                dequeueMaterializedBytes: state.dequeueMaterializedBytes,
                dequeueLeaseConflictDrops: state.dequeueLeaseConflictDrops,
                dequeueBlockedReads: state.dequeueBlockedReads,
                dequeueBlockedDequeues: state.dequeueBlockedDequeues,
                deferredResets: state.deferredResets,
                deferredCloses: state.deferredCloses,
                isClosed: state.isClosed
            )
        }
    }

    private func beginDequeueLease() -> DequeueLease? {
        state.withLock { state in
            guard state.activeDequeueLeaseToken == nil else {
                Self.add(&state.dequeueBlockedDequeues, 1)
                return nil
            }
            guard !state.isClosed, state.queuedSlots > 0 else {
                return nil
            }
            let slot = state.slots[state.headSlot]
            let byteCount = slot.byteCount - slot.consumedBytes
            state.nextDequeueLeaseToken &+= 1
            let token = state.nextDequeueLeaseToken
            state.activeDequeueLeaseToken = token
            Self.add(&state.dequeueLeaseStarts, 1)
            return DequeueLease(
                token: token,
                timestamp: slot.timestamp,
                storageIndex: state.activeStorageIndex,
                byteOffset: state.readByteOffset,
                byteCount: byteCount
            )
        }
    }

    private func finishDequeueLease(_ lease: DequeueLease, wrapped: Bool) {
        state.withLock { state in
            precondition(state.activeDequeueLeaseToken == lease.token)
            precondition(state.queuedSlots > 0)
            state.activeDequeueLeaseToken = nil
            if wrapped {
                Self.add(&state.wraparoundCopies, 1)
            }
            Self.add(&state.dequeueLeaseFinishes, 1)
            Self.add(&state.dequeueMaterializations, 1)
            Self.add(&state.dequeueMaterializedBytes, lease.byteCount)
            consumeBytes(lease.byteCount, fromHeadSlot: &state)
            if state.pendingReset || state.pendingClose {
                clearQueue(&state)
                state.pendingReset = false
                state.pendingClose = false
            }
        }
    }

    /// The reserved range remains part of `queuedBytes`, so a producer can
    /// write only into the disjoint free suffix while this copy is in flight.
    private func copyFromStorageOutsideLock(
        storageIndex: Int,
        at offset: Int,
        into destination: UnsafeMutableRawBufferPointer,
        count: Int
    ) -> Bool {
        guard count > 0 else {
            return false
        }
        let storage = storage(at: storageIndex)
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
        }
        return secondCount > 0
    }

    private func copyIntoStorageOutsideLock(
        _ source: UnsafeRawBufferPointer,
        storageIndex: Int,
        at offset: Int
    ) -> Bool {
        let storage = storage(at: storageIndex)
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
        }
        return secondCount > 0
    }

    private func copyIntoStorage(
        _ source: UnsafeRawBufferPointer,
        storageIndex: Int,
        at offset: Int,
        state: inout State
    ) {
        let storage = storage(at: storageIndex)
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
        storageIndex: Int,
        at offset: Int,
        into destination: UnsafeMutableRawBufferPointer,
        count: Int,
        state: inout State
    ) {
        guard count > 0 else {
            return
        }
        let storage = storage(at: storageIndex)
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

    private func publishSlot(
        timestamp: UInt32,
        byteOffset: Int,
        byteCount: Int,
        state: inout State
    ) {
        if state.queuedSlots == 0 {
            state.readByteOffset = byteOffset
            state.writeByteOffset = byteOffset
        }
        precondition(state.writeByteOffset == byteOffset)
        var slot = state.slots[state.tailSlot]
        slot.timestamp = timestamp
        slot.byteCount = byteCount
        slot.consumedBytes = 0
        state.slots[state.tailSlot] = slot
        state.tailSlot = Self.advanced(state.tailSlot, capacity: capacitySlots)
        state.queuedSlots += 1
        state.queuedBytes += byteCount
        state.writeByteOffset = Self.advanced(
            byteOffset,
            by: byteCount,
            capacity: capacityBytes
        )
        Self.add(&state.enqueuedPackets, 1)
        Self.add(&state.enqueuedBytes, byteCount)
    }

    private static func recordQueueReplacement(
        droppedPackets: Int,
        droppedBytes: Int,
        state: inout State
    ) {
        add(&state.overruns, 1)
        add(&state.droppedPackets, droppedPackets)
        add(&state.droppedBytes, droppedBytes)
    }

    private static func recordLeaseConflictDrop(
        byteCount: Int,
        state: inout State
    ) {
        add(&state.overruns, 1)
        add(&state.droppedPackets, 1)
        add(&state.droppedBytes, byteCount)
        add(&state.dequeueLeaseConflictDrops, 1)
    }

    private func storage(at index: Int) -> UnsafeMutableRawBufferPointer {
        switch index {
        case 0:
            primaryStorage
        case 1:
            stagingStorage!
        default:
            preconditionFailure("invalid audio ring storage index")
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
