import Foundation
import Testing
@testable import SpiceRenderer
@testable import SwiftSpice

@Suite("SpiceFrame storage")
struct SpiceFrameTests {
    @Test func sharesAndCachesLazyPixelsAcrossValueCopiesAndEquality() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 42, width: 1, height: 1, format: 32)
        try await store.fill(
            surfaceID: 42,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        let snapshot = try await store.snapshot(surfaceID: 42)
        let frame = SpiceFrame(snapshot)
        let copiedFrame = frame

        #expect(await store.metrics().cpuMaterializations == 0)
        try await store.fill(
            surfaceID: 42,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x00aa_bbcc
        )
        #expect(frame.pixels == Data([0x33, 0x22, 0x11, 0xff]))
        #expect(copiedFrame.pixels == frame.pixels)
        #expect(copiedFrame == frame)
        #expect(await store.metrics().cpuMaterializations == 1)
    }
}
