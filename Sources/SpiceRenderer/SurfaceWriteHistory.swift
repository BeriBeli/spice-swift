/// Bounded write coverage used to validate an asynchronous video frame.
/// Once coverage is evicted, older observations are conservatively stale.
package struct SurfaceWriteHistory: Sendable {
    private static let maximumRectangles = 256

    private struct Write: Sendable {
        let version: UInt64
        let rectangle: PixelRect
    }

    private var oldestObservation: UInt64 = 0
    private var writes: [Write] = []

    /// Rectangles have already passed SurfaceStore's geometry validation.
    package func permits(after version: UInt64, rectangles: [PixelRect]) -> Bool {
        guard version >= oldestObservation else { return false }
        return !writes.contains { write in
            write.version > version && rectangles.contains { rectangle in
                rectangle.x < write.rectangle.x + write.rectangle.width
                    && write.rectangle.x < rectangle.x + rectangle.width
                    && rectangle.y < write.rectangle.y + write.rectangle.height
                    && write.rectangle.y < rectangle.y + rectangle.height
            }
        }
    }

    package mutating func record(version: UInt64, rectangles: [PixelRect]) {
        guard !rectangles.isEmpty else { return }
        guard rectangles.count <= Self.maximumRectangles else {
            oldestObservation = max(oldestObservation, version)
            writes.removeAll { $0.version <= oldestObservation }
            return
        }
        for rectangle in rectangles {
            // A newer covering write protects every older observation itself.
            // Stable video strips therefore retain one entry per strip.
            writes.removeAll { write in
                write.version <= version
                    && rectangle.x <= write.rectangle.x
                    && rectangle.y <= write.rectangle.y
                    && rectangle.x + rectangle.width >= write.rectangle.x + write.rectangle.width
                    && rectangle.y + rectangle.height >= write.rectangle.y + write.rectangle.height
            }
            writes.append(Write(version: version, rectangle: rectangle))
        }
        while writes.count > Self.maximumRectangles {
            oldestObservation = max(oldestObservation, writes.removeFirst().version)
        }
        writes.removeAll { $0.version <= oldestObservation }
    }
}
