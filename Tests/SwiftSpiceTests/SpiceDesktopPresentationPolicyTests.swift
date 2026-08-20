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

    @Test func releasedRelativePointerUsesVisibleNativeCursorUntilRecaptured() {
        #expect(
            SpiceDesktopPresentationPolicy.cursorLayer(
                for: .relative,
                isPointerCaptured: false
            ) == .native
        )
        #expect(
            SpiceDesktopPresentationPolicy.systemCursorDescriptor(
                for: .relative,
                cursorState: nil,
                frameSize: nil,
                destinationSize: .zero,
                isPointerCaptured: false
            ) == .arrow
        )
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

@Suite("Pointer capture controller")
@MainActor
struct SpicePointerCaptureControllerTests {
    @Test func captureAndReleaseAreBalancedAndIdempotent() {
        var disconnectCount = 0
        var reconnectCount = 0
        var hiddenCount = 0
        var unhiddenCount = 0
        var warpedLocations: [CGPoint] = []
        let restoreLocation = CGPoint(x: 24, y: 42)
        let controller = SpicePointerCaptureController(
            disconnectCursor: {
                disconnectCount += 1
                return true
            },
            reconnectCursor: {
                reconnectCount += 1
            },
            currentCursorLocation: {
                restoreLocation
            },
            warpCursor: {
                warpedLocations.append($0)
            },
            hideCursor: {
                hiddenCount += 1
            },
            unhideCursor: {
                unhiddenCount += 1
            }
        )

        #expect(controller.capture())
        #expect(controller.capture())
        #expect(controller.isCaptured)
        #expect(disconnectCount == 1)
        #expect(hiddenCount == 1)

        controller.release()
        controller.release()

        #expect(!controller.isCaptured)
        #expect(reconnectCount == 1)
        #expect(unhiddenCount == 1)
        #expect(warpedLocations == [restoreLocation])
    }

    @Test func failedDisconnectDoesNotHideOrRequireRelease() {
        var reconnectCount = 0
        var hiddenCount = 0
        var unhiddenCount = 0
        let controller = SpicePointerCaptureController(
            disconnectCursor: { false },
            reconnectCursor: {
                reconnectCount += 1
            },
            currentCursorLocation: {
                CGPoint(x: 1, y: 2)
            },
            warpCursor: { _ in },
            hideCursor: {
                hiddenCount += 1
            },
            unhideCursor: {
                unhiddenCount += 1
            }
        )

        #expect(!controller.capture())
        #expect(!controller.isCaptured)
        controller.release()

        #expect(reconnectCount == 0)
        #expect(hiddenCount == 0)
        #expect(unhiddenCount == 0)
    }
}
