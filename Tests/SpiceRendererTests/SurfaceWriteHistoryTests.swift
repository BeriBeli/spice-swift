import Testing
@testable import SpiceRenderer

@Suite("Surface write coverage")
struct SurfaceWriteHistoryTests {
    @Test func repeatedStripsKeepDisjointObservationsUsable() {
        var history = SurfaceWriteHistory()
        let left = PixelRect(x: 0, y: 0, width: 2, height: 2)
        let right = PixelRect(x: 2, y: 0, width: 2, height: 2)
        for version in 1...1_000 {
            history.record(version: UInt64(version), rectangles: [right])
        }
        #expect(history.permits(after: 0, rectangles: [left]))
        #expect(!history.permits(after: 0, rectangles: [right]))
        history.record(version: 1, rectangles: [left])
        #expect(!history.permits(after: 0, rectangles: [left]))
        #expect(!history.permits(after: 1, rectangles: [right]))
        #expect(history.permits(after: 1_000, rectangles: [left, right]))
    }

    @Test func evictedCoverageConservativelyRejectsOldObservations() {
        var history = SurfaceWriteHistory()
        for version in 1...1_000 {
            history.record(
                version: UInt64(version),
                rectangles: [PixelRect(x: version, y: 0, width: 1, height: 1)]
            )
        }
        let untouched = PixelRect(x: 0, y: 2, width: 1, height: 1)
        #expect(!history.permits(after: 0, rectangles: [untouched]))
        #expect(history.permits(after: 1_000, rectangles: [untouched]))
        let oversized = (0..<1_000).map { PixelRect(x: $0, y: 0, width: 1, height: 1) }
        history.record(version: 1_001, rectangles: oversized)
        #expect(!history.permits(after: 1_000, rectangles: [untouched]))
        #expect(history.permits(after: 1_001, rectangles: [untouched]))
    }
}
