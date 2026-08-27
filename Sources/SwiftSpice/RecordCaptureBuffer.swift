import Foundation
import Synchronization

package struct RecordedAudioPacket: Sendable, Equatable {
    package let timestamp: UInt32
    package let data: Data
}

package struct RecordCaptureDrain: Sendable, Equatable {
    package let packets: [RecordedAudioPacket]
    package let droppedBytes: Int
    package let failure: String?
}

/// Thread-safe bounded handoff from the Core Audio tap to the async sender.
package final class RecordCaptureBuffer: Sendable {
    private struct ReportingState: Sendable {
        var reportedDroppedBytes: UInt64 = 0
        var failure: String?
    }

    private let ring: PreallocatedAudioPacketRing
    private let reporting = Mutex(ReportingState())

    package init(maximumBytes: Int, maximumPackets: Int = 256) {
        precondition(maximumBytes > 0)
        precondition(maximumPackets > 0)
        ring = PreallocatedAudioPacketRing(
            capacityBytes: maximumBytes,
            capacitySlots: maximumPackets
        )
    }

    package func push(_ packet: RecordedAudioPacket) {
        _ = ring.enqueue(packet)
    }

    package func push(
        timestamp: UInt32,
        bytes: UnsafeRawBufferPointer
    ) -> AudioPacketRingEnqueueResult {
        ring.enqueue(timestamp: timestamp, bytes: bytes)
    }

    package func fail(_ reason: String) {
        reporting.withLock { state in
            if state.failure == nil {
                state.failure = reason
            }
        }
    }

    /// Packet `Data` is materialized on the async sender, never in the tap
    /// callback. Queue storage itself remains fixed for the buffer lifetime.
    package func drain() -> RecordCaptureDrain {
        var packets: [RecordedAudioPacket] = []
        while let packet = ring.dequeue() {
            packets.append(packet)
        }
        let currentDroppedBytes = ring.diagnostics().droppedBytes
        return reporting.withLock { state in
            let delta = currentDroppedBytes >= state.reportedDroppedBytes
                ? currentDroppedBytes - state.reportedDroppedBytes
                : 0
            state.reportedDroppedBytes = currentDroppedBytes
            let failure = state.failure
            state.failure = nil
            return RecordCaptureDrain(
                packets: packets,
                droppedBytes: Int(clamping: delta),
                failure: failure
            )
        }
    }

    package func reset() {
        ring.reset()
        let droppedBytes = ring.diagnostics().droppedBytes
        reporting.withLock { state in
            state.reportedDroppedBytes = droppedBytes
            state.failure = nil
        }
    }

    package func close() {
        ring.close()
        reporting.withLock { state in
            state.failure = nil
        }
    }

    package func diagnostics() -> AudioPacketRingDiagnostics {
        ring.diagnostics()
    }
}
