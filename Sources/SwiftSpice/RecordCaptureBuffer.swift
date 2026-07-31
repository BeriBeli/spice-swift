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
    private struct State: Sendable {
        var packets: [RecordedAudioPacket] = []
        var queuedBytes = 0
        var droppedBytes = 0
        var failure: String?
    }

    private let maximumBytes: Int
    private let state = Mutex(State())

    package init(maximumBytes: Int) {
        precondition(maximumBytes > 0)
        self.maximumBytes = maximumBytes
    }

    package func push(_ packet: RecordedAudioPacket) {
        state.withLock { state in
            guard packet.data.count <= maximumBytes else {
                state.droppedBytes += packet.data.count
                return
            }
            while packet.data.count > maximumBytes - state.queuedBytes,
                  let oldest = state.packets.first {
                state.packets.removeFirst()
                state.queuedBytes -= oldest.data.count
                state.droppedBytes += oldest.data.count
            }
            state.packets.append(packet)
            state.queuedBytes += packet.data.count
        }
    }

    package func fail(_ reason: String) {
        state.withLock { state in
            if state.failure == nil {
                state.failure = reason
            }
        }
    }

    package func drain() -> RecordCaptureDrain {
        state.withLock { state in
            let result = RecordCaptureDrain(
                packets: state.packets,
                droppedBytes: state.droppedBytes,
                failure: state.failure
            )
            state.packets.removeAll(keepingCapacity: true)
            state.queuedBytes = 0
            state.droppedBytes = 0
            state.failure = nil
            return result
        }
    }
}
