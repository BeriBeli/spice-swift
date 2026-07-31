import Foundation

package actor FrameCoalescer {
    private let interval: Duration
    private let maximumPendingSurfaces: Int
    private let emit: @Sendable (SpiceFrame) async -> Void
    private var pending: [UInt32: SpiceFrame] = [:]
    private var order: [UInt32] = []
    private var flushTask: Task<Void, Never>?

    package init(
        interval: Duration = .milliseconds(16),
        maximumPendingSurfaces: Int = 16,
        emit: @escaping @Sendable (SpiceFrame) async -> Void
    ) {
        self.interval = interval
        self.maximumPendingSurfaces = max(1, maximumPendingSurfaces)
        self.emit = emit
    }

    package func submit(_ frame: SpiceFrame) {
        if pending[frame.surfaceID] == nil {
            if pending.count == maximumPendingSurfaces, let oldest = order.first {
                pending[oldest] = nil
                order.removeFirst()
            }
            order.append(frame.surfaceID)
        }
        pending[frame.surfaceID] = frame

        guard flushTask == nil else {
            return
        }
        flushTask = Task { [weak self, interval] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else {
                return
            }
            await self?.flush()
        }
    }

    package func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }

    package func flushNow() async {
        flushTask?.cancel()
        flushTask = nil
        await flush()
    }

    private func flush() async {
        let frames = order.compactMap { pending[$0] }
        pending.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        flushTask = nil
        for frame in frames {
            await emit(frame)
        }
    }
}
