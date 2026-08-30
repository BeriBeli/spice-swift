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

    @Test func readyLatchMeasuresFromLatestAcceptedSnapshotReadyTime() throws {
        let first = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: 20
        )
        let latest = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .relative,
            deliverySequence: 21
        )
        let latch = SpiceDesktopReadyLatch()
        let firstReadyAt = ContinuousClock().now
        let latestReadyAt = firstReadyAt.advanced(by: .milliseconds(10))
        let selectedAt = firstReadyAt.advanced(by: .milliseconds(15))

        #expect(latch.offer(first, at: firstReadyAt))
        #expect(!latch.offer(latest, at: latestReadyAt))
        let ready = try #require(latch.takeReady(at: selectedAt))
        #expect(ready.snapshot.deliverySequence == 21)
        #expect(ready.snapshot.pointerMode == .relative)
        #expect(ready.waitingDuration == .milliseconds(5))
        #expect(latch.isEmpty)
    }

    @Test func rejectedOlderOfferDoesNotReplaceSelectedReadyTime() throws {
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
        let latch = SpiceDesktopReadyLatch()
        let newestReadyAt = ContinuousClock().now
        let olderArrivedAt = newestReadyAt.advanced(by: .milliseconds(12))
        let selectedAt = newestReadyAt.advanced(by: .milliseconds(15))

        #expect(latch.offer(newest, at: newestReadyAt))
        #expect(!latch.offer(lateOlder, at: olderArrivedAt))
        let ready = try #require(latch.takeReady(at: selectedAt))
        #expect(ready.snapshot.deliverySequence == 22)
        #expect(ready.snapshot.pointerMode == .relative)
        #expect(ready.waitingDuration == .milliseconds(15))
    }

    @Test func duplicateDeliveryDoesNotReplaceReadyTimeOrReawakenLatch() throws {
        let snapshot = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .relative,
            deliverySequence: 24
        )
        let latch = SpiceDesktopReadyLatch()
        let readyAt = ContinuousClock().now

        #expect(latch.offer(snapshot, at: readyAt))
        #expect(!latch.offer(
            snapshot,
            at: readyAt.advanced(by: .milliseconds(10))
        ))
        let selected = try #require(latch.takeReady(
            at: readyAt.advanced(by: .milliseconds(15))
        ))
        #expect(selected.snapshot.deliverySequence == 24)
        #expect(selected.waitingDuration == .milliseconds(15))

        #expect(!latch.offer(
            snapshot,
            at: readyAt.advanced(by: .milliseconds(20))
        ))
        #expect(latch.isEmpty)
        #expect(latch.takeReady(at: readyAt.advanced(by: .milliseconds(25))) == nil)
    }

    @Test func selectionBeforeReadyTimeReportsZeroWaitingDuration() throws {
        let snapshot = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: 25
        )
        let latch = SpiceDesktopReadyLatch()
        let selectedAt = ContinuousClock().now
        let futureReadyAt = selectedAt.advanced(by: .milliseconds(5))

        #expect(latch.offer(snapshot, at: futureReadyAt))
        let selected = try #require(latch.takeReady(at: selectedAt))
        #expect(selected.snapshot.deliverySequence == 25)
        #expect(selected.waitingDuration == .zero)
    }

    @Test func restoreIfEmptyUsesRestoreTimeAndPreservesNewerPendingUpdate() throws {
        let failed = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: 30
        )
        let newer = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .relative,
            deliverySequence: 31
        )
        let firstReadyAt = ContinuousClock().now

        let restoredLatch = SpiceDesktopReadyLatch()
        #expect(restoredLatch.offer(failed, at: firstReadyAt))
        let failedReady = try #require(restoredLatch.takeReady(
            at: firstReadyAt.advanced(by: .milliseconds(1))
        ))
        let restoredAt = firstReadyAt.advanced(by: .milliseconds(10))
        restoredLatch.restoreIfEmpty(failedReady.snapshot, at: restoredAt)
        let restored = try #require(restoredLatch.takeReady(
            at: firstReadyAt.advanced(by: .milliseconds(15))
        ))
        #expect(restored.snapshot.deliverySequence == 30)
        #expect(restored.waitingDuration == .milliseconds(5))

        let newerLatch = SpiceDesktopReadyLatch()
        #expect(newerLatch.offer(failed, at: firstReadyAt))
        let selectedFailed = try #require(newerLatch.takeReady(
            at: firstReadyAt.advanced(by: .milliseconds(1))
        ))
        let newerReadyAt = firstReadyAt.advanced(by: .milliseconds(10))
        #expect(newerLatch.offer(newer, at: newerReadyAt))
        newerLatch.restoreIfEmpty(
            selectedFailed.snapshot,
            at: firstReadyAt.advanced(by: .milliseconds(12))
        )
        let selectedNewer = try #require(newerLatch.takeReady(
            at: firstReadyAt.advanced(by: .milliseconds(15))
        ))
        #expect(selectedNewer.snapshot.deliverySequence == 31)
        #expect(selectedNewer.snapshot.pointerMode == .relative)
        #expect(selectedNewer.waitingDuration == .milliseconds(5))
    }

    @Test func retryRestorationPreservesTheOriginalReadyTimestamp() throws {
        let snapshot = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: 35
        )
        let latch = SpiceDesktopReadyLatch()
        let firstReadyAt = ContinuousClock().now
        let firstReadyNanoseconds: UInt64 = 123_456
        #expect(latch.offer(
            snapshot,
            at: firstReadyAt,
            readyNanoseconds: firstReadyNanoseconds
        ))
        let failed = try #require(latch.takeReady(
            at: firstReadyAt.advanced(by: .milliseconds(1))
        ))

        latch.restoreIfEmpty(
            failed.snapshot,
            at: failed.readyAt,
            readyNanoseconds: failed.readyNanoseconds
        )
        let retry = try #require(latch.takeReady(
            at: firstReadyAt.advanced(by: .milliseconds(10))
        ))
        #expect(retry.readyAt == firstReadyAt)
        #expect(retry.readyNanoseconds == firstReadyNanoseconds)
        #expect(retry.waitingDuration == .milliseconds(10))
    }

    @Test func restoreIfEmptyRejectsStaleSnapshotAfterNewerSelection() throws {
        let stale = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: 40
        )
        let newest = SpiceDesktopSnapshot(
            generation: 4,
            frame: nil,
            cursor: nil,
            pointerMode: .relative,
            deliverySequence: 41
        )
        let latch = SpiceDesktopReadyLatch()
        let staleReadyAt = ContinuousClock().now
        let newestReadyAt = staleReadyAt.advanced(by: .milliseconds(5))

        #expect(latch.offer(stale, at: staleReadyAt))
        _ = try #require(latch.takeReady(at: staleReadyAt))
        #expect(latch.offer(newest, at: newestReadyAt))
        _ = try #require(latch.takeReady(at: newestReadyAt))
        #expect(latch.isEmpty)

        latch.restoreIfEmpty(
            stale,
            at: newestReadyAt.advanced(by: .milliseconds(5))
        )
        #expect(latch.isEmpty)
        #expect(latch.takeReady(
            at: newestReadyAt.advanced(by: .milliseconds(10))
        ) == nil)
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
        var pacing = SpiceDesktopPresentationPacingPolicy()
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
                    switch pacing.readyBecameAvailable() {
                    case .selectImmediately:
                        let selected = try #require(latch.take())
                        presentations += 1
                        lastGeneration = selected.generation
                    case .waitForDisplayLink:
                        break
                    case .selectOnDisplayLink, .pauseDisplayLink:
                        Issue.record("Unexpected ready-update pacing action")
                    }
                }
            }
            switch pacing.displayLinkFired(hasReadySnapshot: !latch.isEmpty) {
            case .selectOnDisplayLink:
                let selected = try #require(latch.take())
                presentations += 1
                lastGeneration = selected.generation
            case .pauseDisplayLink:
                break
            case .selectImmediately, .waitForDisplayLink:
                Issue.record("Unexpected display-link pacing action")
            }
        }

        // One idle fast-path selection followed by at most one selection for
        // each display tick. The steady-state rate remains display-limited.
        #expect(presentations == 61)
        #expect(lastGeneration == 120)
        #expect(latch.isEmpty)
    }

    @Test func sparseUpdatesUseImmediateSelectionAfterIdleTick() {
        var pacing = SpiceDesktopPresentationPacingPolicy()

        #expect(pacing.readyBecameAvailable() == .selectImmediately)
        #expect(pacing.displayLinkFired(hasReadySnapshot: false) == .pauseDisplayLink)
        #expect(pacing.readyBecameAvailable() == .selectImmediately)
    }

    @Test func activeDisplayLinkSelectsReadyWorkOnFirstEligibleTick() throws {
        let latch = SpiceDesktopReadyLatch()
        var pacing = SpiceDesktopPresentationPacingPolicy()
        let idleReadyAt = ContinuousClock().now
        let idle = SpiceDesktopSnapshot(
            generation: 1,
            frame: nil,
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: 1
        )
        let steady = SpiceDesktopSnapshot(
            generation: 1,
            frame: nil,
            cursor: nil,
            pointerMode: .relative,
            deliverySequence: 2
        )

        #expect(latch.offer(idle, at: idleReadyAt))
        #expect(pacing.readyBecameAvailable() == .selectImmediately)
        let idleSelection = try #require(latch.takeReady(at: idleReadyAt))
        #expect(idleSelection.snapshot.deliverySequence == 1)
        #expect(idleSelection.waitingDuration == .zero)

        let steadyReadyAt = idleReadyAt.advanced(by: .milliseconds(4))
        #expect(latch.offer(steady, at: steadyReadyAt))
        #expect(pacing.readyBecameAvailable() == .waitForDisplayLink)
        #expect(
            pacing.displayLinkFired(hasReadySnapshot: !latch.isEmpty)
                == .selectOnDisplayLink
        )
        let firstEligibleTick = steadyReadyAt.advanced(by: .milliseconds(8))
        let steadySelection = try #require(latch.takeReady(at: firstEligibleTick))
        #expect(steadySelection.snapshot.deliverySequence == 2)
        #expect(steadySelection.snapshot.pointerMode == .relative)
        #expect(steadySelection.waitingDuration == .milliseconds(8))
        #expect(latch.isEmpty)
        #expect(
            pacing.displayLinkFired(hasReadySnapshot: !latch.isEmpty)
                == .pauseDisplayLink
        )
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

    @Test func droppedDrawableRequestsOneVisibleCurrentRevisionRecovery() {
        let current = Self.revision(43)
        let stale = Self.revision(42)
        var recovery = SpiceDrawablePresentationDropRecoveryPolicy()

        // A callback cannot implicitly create tracked presentation state. The
        // view must first select the exact revision through its normal apply
        // path, even if an external selected-revision value happens to match.
        #expect(recovery.presentationDropped(
            revision: current,
            selectedRevision: current,
            isVisibleDemand: true
        ) == .none)
        // An empty view, a hidden view, and a stale callback cannot create work
        // or consume the one recovery opportunity for the selected frame.
        #expect(recovery.presentationDropped(
            revision: current,
            selectedRevision: nil,
            isVisibleDemand: true
        ) == .none)
        recovery.revisionSelected(current)
        #expect(recovery.presentationDropped(
            revision: current,
            selectedRevision: current,
            isVisibleDemand: false
        ) == .none)
        #expect(recovery.presentationDropped(
            revision: stale,
            selectedRevision: current,
            isVisibleDemand: true
        ) == .none)

        #expect(recovery.presentationDropped(
            revision: current,
            selectedRevision: current,
            isVisibleDemand: true
        ) == .requestAuthoritativeRedraw)
        #expect(recovery.presentationDropped(
            revision: current,
            selectedRevision: current,
            isVisibleDemand: true
        ) == .none)

        // A stale success cannot reset the current revision's budget. A real
        // presentation of that revision does, so a later independent drop is
        // eligible for one new bounded recovery.
        recovery.presentationSucceeded(revision: stale)
        #expect(recovery.presentationDropped(
            revision: current,
            selectedRevision: current,
            isVisibleDemand: true
        ) == .none)
        recovery.presentationSucceeded(revision: current)
        #expect(recovery.presentationDropped(
            revision: current,
            selectedRevision: current,
            isVisibleDemand: true
        ) == .requestAuthoritativeRedraw)
        #expect(recovery.presentationDropped(
            revision: current,
            selectedRevision: current,
            isVisibleDemand: true
        ) == .none)
    }

    @Test func newerRevisionStartsAnIndependentDropRecoveryBudget() {
        let original = Self.revision(43)
        let newer = Self.revision(44)
        var recovery = SpiceDrawablePresentationDropRecoveryPolicy()

        recovery.revisionSelected(original)
        #expect(recovery.presentationDropped(
            revision: original,
            selectedRevision: original,
            isVisibleDemand: true
        ) == .requestAuthoritativeRedraw)

        recovery.revisionSelected(newer)
        #expect(recovery.presentationDropped(
            revision: original,
            selectedRevision: newer,
            isVisibleDemand: true
        ) == .none)
        #expect(recovery.presentationDropped(
            revision: newer,
            selectedRevision: newer,
            isVisibleDemand: true
        ) == .requestAuthoritativeRedraw)

        recovery.reset()
        #expect(recovery.presentationDropped(
            revision: newer,
            selectedRevision: newer,
            isVisibleDemand: true
        ) == .none)
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

    @Test func cursorCacheIdentityIncludesPixelContents() {
        let original = SpiceCursorImage(
            id: 42,
            format: .alpha,
            width: 2,
            height: 2,
            hotSpotX: 1,
            hotSpotY: 1,
            data: Data(repeating: 0x00, count: 16)
        )
        let replacement = SpiceCursorImage(
            id: 42,
            format: .alpha,
            width: 2,
            height: 2,
            hotSpotX: 1,
            hotSpotY: 1,
            data: Data(repeating: 0xff, count: 16)
        )

        #expect(
            SpiceCursorImageCacheKey(original)
                != SpiceCursorImageCacheKey(replacement)
        )

        let first = SpiceDesktopPresentationPolicy.systemCursorDescriptor(
            for: .absolute,
            cursorState: SpiceCursorState(
                x: 10,
                y: 20,
                isVisible: true,
                image: original
            ),
            frameSize: CGSize(width: 640, height: 480),
            destinationSize: CGSize(width: 320, height: 240)
        )
        let replaced = SpiceDesktopPresentationPolicy.systemCursorDescriptor(
            for: .absolute,
            cursorState: SpiceCursorState(
                x: 10,
                y: 20,
                isVisible: true,
                image: replacement
            ),
            frameSize: CGSize(width: 640, height: 480),
            destinationSize: CGSize(width: 320, height: 240)
        )

        #expect(first != replaced)
    }

    private static func revision(_ value: UInt64) -> SpiceFrameRevision {
        SpiceFrameRevision(
            surface: SpiceSurfaceIdentity(
                displayChannelID: 0,
                surfaceID: 0,
                generation: 1
            ),
            value: value
        )
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
