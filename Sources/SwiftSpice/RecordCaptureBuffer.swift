import Foundation
import Synchronization

package struct RecordedAudioPacket: Sendable, Equatable {
    package let timestamp: UInt32
    package let data: Data
}

package enum AudioCaptureProcessorFailure: Sendable, Equatable {
    case inputFormatChanged
    case invalidInputStorage
    case converter
    case invalidOutputStorage

    package func formattedDescription() -> String {
        switch self {
        case .inputFormatChanged:
            "capture input format changed while the tap was active"
        case .invalidInputStorage:
            "capture input buffer contains invalid PCM storage"
        case .converter:
            "audio converter failed"
        case .invalidOutputStorage:
            "converter produced invalid PCM storage"
        }
    }
}

package struct RecordCaptureDrain: Sendable, Equatable {
    package let packets: [RecordedAudioPacket]
    package let droppedBytes: Int
    package let failure: String?
    package let failureToken: AudioCaptureProcessorFailure?

    package init(
        packets: [RecordedAudioPacket],
        droppedBytes: Int,
        failure: String?,
        failureToken: AudioCaptureProcessorFailure? = nil
    ) {
        self.packets = packets
        self.droppedBytes = droppedBytes
        self.failure = failure
        self.failureToken = failureToken
    }
}

/// Thread-safe bounded handoff from the Core Audio tap to the async sender.
package final class RecordCaptureBuffer: Sendable {
    private struct ReportingState: Sendable {
        var reportedDroppedBytes: UInt64 = 0
        var failure: AudioCaptureProcessorFailure?
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

    package func fail(_ failure: AudioCaptureProcessorFailure) {
        reporting.withLock { state in
            if state.failure == nil {
                state.failure = failure
            }
        }
    }

    /// Packet `Data` is materialized on the async sender, never in the tap
    /// callback. Queue storage itself remains fixed for the buffer lifetime.
    package func drain(
        snapshotCaptured observer: (@Sendable (Int) -> Void)? = nil
    ) -> RecordCaptureDrain {
        let packetLimit = ring.diagnostics().queuedSlots
        observer?(packetLimit)
        var packets: [RecordedAudioPacket] = []
        packets.reserveCapacity(packetLimit)
        for _ in 0 ..< packetLimit {
            guard let packet = ring.dequeue() else { break }
            packets.append(packet)
        }
        let currentDroppedBytes = ring.diagnostics().droppedBytes
        let report = reporting.withLock { state in
            let delta = currentDroppedBytes >= state.reportedDroppedBytes
                ? currentDroppedBytes - state.reportedDroppedBytes
                : 0
            state.reportedDroppedBytes = currentDroppedBytes
            let failure = state.failure
            state.failure = nil
            return (droppedBytes: Int(clamping: delta), failure: failure)
        }
        return RecordCaptureDrain(
            packets: packets,
            droppedBytes: report.droppedBytes,
            failure: report.failure?.formattedDescription(),
            failureToken: report.failure
        )
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
