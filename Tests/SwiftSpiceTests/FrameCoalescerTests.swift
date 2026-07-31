import Foundation
import Testing
@testable import SwiftSpice

@Suite("Frame coalescer")
struct FrameCoalescerTests {
    @Test func mapsMacPhysicalKeysToXTSetOne() {
        #expect(MacXTScanCode.map[0] == 0x1e) // A
        #expect(MacXTScanCode.map[36] == 0x1c) // Return
        #expect(MacXTScanCode.map[123] == 0x14b) // E0 Left Arrow
        #expect(SpicePointerMode(spiceMouseMode: 1) == .relative)
        #expect(SpicePointerMode(spiceMouseMode: 2) == .absolute)
    }

    @Test func keepsOnlyLatestFramePerSurface() async {
        let collector = FrameCollector()
        let coalescer = FrameCoalescer(interval: .seconds(10)) { frame in
            await collector.append(frame)
        }

        await coalescer.submit(frame(surfaceID: 1, pixel: 1))
        await coalescer.submit(frame(surfaceID: 1, pixel: 2))
        await coalescer.submit(frame(surfaceID: 2, pixel: 3))
        await coalescer.flushNow()

        #expect(await collector.frames == [
            frame(surfaceID: 1, pixel: 2),
            frame(surfaceID: 2, pixel: 3),
        ])
    }

    @Test func evictsOldestSurfaceWhenPendingSetIsFull() async {
        let collector = FrameCollector()
        let coalescer = FrameCoalescer(
            interval: .seconds(10),
            maximumPendingSurfaces: 2
        ) { frame in
            await collector.append(frame)
        }

        await coalescer.submit(frame(surfaceID: 1, pixel: 1))
        await coalescer.submit(frame(surfaceID: 2, pixel: 2))
        await coalescer.submit(frame(surfaceID: 3, pixel: 3))
        await coalescer.flushNow()

        #expect(await collector.frames.map(\.surfaceID) == [2, 3])
    }

    private func frame(surfaceID: UInt32, pixel: UInt8) -> SpiceFrame {
        SpiceFrame(
            surfaceID: surfaceID,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixels: Data([pixel, pixel, pixel, 255])
        )
    }
}

private actor FrameCollector {
    private(set) var frames: [SpiceFrame] = []

    func append(_ frame: SpiceFrame) {
        frames.append(frame)
    }
}
