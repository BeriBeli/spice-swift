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

    @Test func nativeCursorDescriptorIgnoresGuestPositionWhenPresentationIsUnchanged() {
        let image = SpiceCursorImage(
            id: 42,
            format: .alpha,
            width: 2,
            height: 2,
            hotSpotX: 1,
            hotSpotY: 1,
            data: Data(repeating: 0xff, count: 16)
        )
        let first = SpiceDesktopPresentationPolicy.systemCursorDescriptor(
            for: .absolute,
            cursorState: SpiceCursorState(x: 10, y: 20, isVisible: true, image: image),
            frameSize: CGSize(width: 640, height: 480),
            destinationSize: CGSize(width: 320, height: 240)
        )
        let moved = SpiceDesktopPresentationPolicy.systemCursorDescriptor(
            for: .absolute,
            cursorState: SpiceCursorState(x: 300, y: 200, isVisible: true, image: image),
            frameSize: CGSize(width: 640, height: 480),
            destinationSize: CGSize(width: 320, height: 240)
        )
        let resized = SpiceDesktopPresentationPolicy.systemCursorDescriptor(
            for: .absolute,
            cursorState: SpiceCursorState(x: 300, y: 200, isVisible: true, image: image),
            frameSize: CGSize(width: 640, height: 480),
            destinationSize: CGSize(width: 640, height: 480)
        )

        #expect(first == moved)
        #expect(first != resized)
    }
}
