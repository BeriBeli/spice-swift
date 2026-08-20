import Foundation

/// A bounded, content-free latency summary used by display diagnostics.
public struct SpiceTimingSummary: Sendable, Equatable {
    public let sampleCount: UInt64
    public let p95Milliseconds: Double?
    public let maximumMilliseconds: Double?

    public init(
        sampleCount: UInt64,
        p95Milliseconds: Double?,
        maximumMilliseconds: Double?
    ) {
        self.sampleCount = sampleCount
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }

    public static let empty = SpiceTimingSummary(
        sampleCount: 0,
        p95Milliseconds: nil,
        maximumMilliseconds: nil
    )
}

package struct SpiceTimingHistogram: Sendable, Equatable {
    private static let upperBoundsMilliseconds: [Double] = [
        0.25, 0.5, 1, 2, 4, 8, 12, 16, 20, 24, 33, 50, 67, 100,
        150, 250, 500, 1_000, 2_000, 5_000,
    ]

    private var buckets = Array(
        repeating: UInt64(0),
        count: Self.upperBoundsMilliseconds.count + 1
    )
    private var sampleCount: UInt64 = 0
    private var maximumMilliseconds: Double?

    package init() {}

    package mutating func record(_ duration: Duration) {
        let milliseconds = Self.milliseconds(duration)
        let index = Self.upperBoundsMilliseconds.firstIndex { milliseconds <= $0 }
            ?? Self.upperBoundsMilliseconds.count
        buckets[index] &+= 1
        sampleCount &+= 1
        maximumMilliseconds = max(maximumMilliseconds ?? milliseconds, milliseconds)
    }

    package mutating func accumulate(_ other: Self) {
        for index in buckets.indices {
            buckets[index] &+= other.buckets[index]
        }
        sampleCount &+= other.sampleCount
        if let otherMaximum = other.maximumMilliseconds {
            maximumMilliseconds = max(maximumMilliseconds ?? otherMaximum, otherMaximum)
        }
    }

    package var summary: SpiceTimingSummary {
        guard sampleCount > 0, let maximumMilliseconds else { return .empty }
        let rank = UInt64((Double(sampleCount) * 0.95).rounded(.up))
        var accumulated: UInt64 = 0
        for (index, count) in buckets.enumerated() {
            accumulated &+= count
            guard accumulated >= rank else { continue }
            let p95 = index < Self.upperBoundsMilliseconds.count
                ? min(Self.upperBoundsMilliseconds[index], maximumMilliseconds)
                : maximumMilliseconds
            return SpiceTimingSummary(
                sampleCount: sampleCount,
                p95Milliseconds: p95,
                maximumMilliseconds: maximumMilliseconds
            )
        }
        return SpiceTimingSummary(
            sampleCount: sampleCount,
            p95Milliseconds: maximumMilliseconds,
            maximumMilliseconds: maximumMilliseconds
        )
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        let value = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        return max(0, value.isFinite ? value : 0)
    }
}
