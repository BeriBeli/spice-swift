import AppKit
import Testing
@testable import SwiftSpice

@Suite("Desktop presentation policy")
struct SpiceDesktopPresentationPolicyTests {
    @Test func readyLatchWakesOnceAndKeepsOnlyTheLatestSnapshot() throws {
        let first = SpiceDesktopSnapshot(
            generation: 1,
            frame: nil,
            cursor: nil,
            pointerMode: .absolute
        )
        let latest = SpiceDesktopSnapshot(
            generation: 2,
            frame: nil,
            cursor: nil,
            pointerMode: .relative
        )
        let latch = SpiceDesktopReadyLatch()

        #expect(latch.offer(first))
        #expect(!latch.offer(latest))
        let selected = try #require(latch.take())
        #expect(selected.generation == latest.generation)
        #expect(selected.frame == nil)
        #expect(selected.pointerMode == latest.pointerMode)
        #expect(latch.isEmpty)
    }

    @Test func readyLatchRejectsLateOfferFromOlderDeliverySequence() throws {
        let latch = SpiceDesktopReadyLatch()
        let newest = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .relative,
            deliverySequence: 22
        )
        let lateOlder = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: 21
        )

        #expect(latch.offer(newest))
        #expect(!latch.offer(lateOlder))
        let selected = try #require(latch.take())
        #expect(selected.deliverySequence == 22)
        #expect(selected.pointerMode == .relative)
    }

    @Test func readyLatchMergesFrameDamageIntoNewerCursorSnapshot() throws {
        let frame = SpiceFrame(
            surfaceID: 0,
            width: 4,
            height: 4,
            bytesPerRow: 16,
            pixels: Data(repeating: 7, count: 64)
        )
        let revision = SpiceFrameRevision(
            surface: SpiceSurfaceIdentity(
                displayChannelID: 0,
                surfaceID: 0,
                generation: 1
            ),
            value: 7
        )
        let damage = SpicePixelRect(x: 1, y: 1, width: 1, height: 1)
        let frameUpdate = SpiceDesktopSnapshot(
            generation: 2,
            frame: SpiceFrameUpdate(
                frame: frame,
                revision: revision,
                damage: .rectangles([damage])
            ),
            cursor: nil,
            pointerMode: .relative,
            deliverySequence: 30
        )
        let cursorUpdate = SpiceDesktopSnapshot(
            generation: 2,
            frame: SpiceFrameUpdate(
                frame: frame,
                revision: revision,
                damage: .rectangles([])
            ),
            cursor: SpiceCursorState(x: 3, y: 2, isVisible: true, image: nil),
            pointerMode: .relative,
            deliverySequence: 31
        )
        let latch = SpiceDesktopReadyLatch()

        #expect(latch.offer(frameUpdate))
        #expect(!latch.offer(cursorUpdate))
        let selected = try #require(latch.take())
        #expect(selected.deliverySequence == 31)
        #expect(selected.frame?.damage == .rectangles([damage]))
        #expect(selected.cursor?.x == 3)
    }

    @Test func oneHundredTwentyHzProducerPresentsAtMostOncePerSixtyHzTick() throws {
        let latch = SpiceDesktopReadyLatch()
        var wakeups = 0
        var presentations = 0
        var lastGeneration: UInt64 = 0

        for displayTick in 0..<60 {
            for sample in 0..<2 {
                let generation = UInt64(displayTick * 2 + sample + 1)
                if latch.offer(SpiceDesktopSnapshot(
                    generation: generation,
                    frame: nil,
                    cursor: nil,
                    pointerMode: .absolute
                )) {
                    wakeups += 1
                }
            }
            let selected = try #require(latch.take())
            presentations += 1
            lastGeneration = selected.generation
        }

        #expect(wakeups == 60)
        #expect(presentations == 60)
        #expect(lastGeneration == 120)
        #expect(latch.isEmpty)
    }

    @Test func cursorOnlySnapshotDoesNotInvokeFramebufferCommandSubmission() {
        let revision = SpiceFrameRevision(
            surface: SpiceSurfaceIdentity(
                displayChannelID: 0,
                surfaceID: 0,
                generation: 1
            ),
            value: 42
        )
        #expect(!SpiceDesktopPresentationPolicy.requiresFramebufferPresentation(
            selectedRevision: revision,
            updateRevision: revision,
            requiresRedraw: false
        ))
        #expect(SpiceDesktopPresentationPolicy.requiresFramebufferPresentation(
            selectedRevision: revision,
            updateRevision: revision,
            requiresRedraw: true
        ))

        var submittedCommandBuffers = 0
        let result: Int? = SpiceDesktopPresentationPolicy
            .withFramebufferPresentationIfNeeded(
                selectedRevision: revision,
                updateRevision: revision,
                requiresRedraw: false
            ) {
                submittedCommandBuffers += 1
                return submittedCommandBuffers
            }
        #expect(result == nil)
        #expect(submittedCommandBuffers == 0)
    }

    @Test func failedMetalCompletionRequestsOneRetryThenUsesCPUFallback() {
        let revision = SpiceFrameRevision(
            surface: SpiceSurfaceIdentity(
                displayChannelID: 0,
                surfaceID: 0,
                generation: 1
            ),
            value: 43
        )
        var recovery = SpiceMetalFailureRecoveryPolicy()
        var latestRequests = 0
        var cpuFallbacks = 0

        let firstAttempt = recovery.beginAttempt(for: revision)
        if recovery.commandCompleted(
            firstAttempt,
            completion: .failed,
            selectedRevision: revision
        ) == .requestLatest {
            latestRequests += 1
        }
        // Completion delivery is idempotent, so an injected duplicate cannot
        // request another authoritative snapshot.
        #expect(recovery.commandCompleted(
            firstAttempt,
            completion: .failed,
            selectedRevision: revision
        ) == .none)
        #expect(latestRequests == 1)

        var cursorOnlyFramebufferCommands = 0
        let cursorOnlyResult: Int? = SpiceDesktopPresentationPolicy
            .withFramebufferPresentationIfNeeded(
                selectedRevision: revision,
                updateRevision: revision,
                requiresRedraw: false
            ) {
                cursorOnlyFramebufferCommands += 1
                return cursorOnlyFramebufferCommands
            }
        #expect(cursorOnlyResult == nil)
        #expect(cursorOnlyFramebufferCommands == 0)

        let retryAttempt = recovery.beginAttempt(for: revision)
        if recovery.commandCompleted(
            retryAttempt,
            completion: .failed,
            selectedRevision: revision
        ) == .useCPUFallback {
            cpuFallbacks += 1
        }
        #expect(recovery.commandCompleted(
            retryAttempt,
            completion: .failed,
            selectedRevision: revision
        ) == .none)
        #expect(latestRequests == 1)
        #expect(cpuFallbacks == 1)
    }

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
