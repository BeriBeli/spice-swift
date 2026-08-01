import AppKit
import Testing
@testable import SwiftSpice

@Suite("Desktop presentation policy")
struct SpiceDesktopPresentationPolicyTests {
    @Test func absolutePointerUsesOnlyTheNativeCursor() {
        #expect(SpiceDesktopPresentationPolicy.cursorLayer(for: .absolute) == .native)
    }

    @Test func relativePointerUsesOnlyTheServerCursorOverlay() {
        #expect(SpiceDesktopPresentationPolicy.cursorLayer(for: .relative) == .overlay)
    }

    @Test func drawableTracksBackingPixelsInsteadOfGuestPixels() {
        #expect(
            SpiceDesktopPresentationPolicy.drawableSize(
                for: CGSize(width: 640, height: 360),
                backingScaleFactor: 2
            ) == CGSize(width: 1280, height: 720)
        )
    }
}
