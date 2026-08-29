import Foundation
import Synchronization
import Testing
@testable import SpiceChannels
@testable import SpiceRenderer
@testable import SwiftSpice

@Suite("Spice desktop source")
struct SpiceDesktopSourceTests {
    @Test func concurrentVisibleAndCancelCannotLeaveGhostDemandOrSnapshot() async {
        let visibleMutationEntered = DispatchSemaphore(value: 0)
        let releaseVisibleMutation = DispatchSemaphore(value: 0)
        let cancelStarted = DispatchSemaphore(value: 0)
        let key = DisplaySurfaceKey(channelID: 0, surfaceID: 0)
        let coordinator = DisplayFrameDemandCoordinator(
            beforeDemandMutation: { _, _, isDemanded in
                if isDemanded {
                    visibleMutationEntered.signal()
                    releaseVisibleMutation.wait()
                }
            }
        )
        let snapshotCount = Mutex(0)
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            requiresExplicitDemand: true,
            snapshot: { revision in
                snapshotCount.withLock { $0 += 1 }
                return Self.frame(revision: revision.revision)
            },
            emit: { _ in }
        )
        let demandPipe = AsyncStream.makeStream(
            of: DisplayFrameDemandEvent.self,
            bufferingPolicy: .unbounded
        )
        let demandWorker = Task {
            for await event in demandPipe.stream {
                guard case let .demandChanged(surfaceID, isDemanded) = event else {
                    continue
                }
                await publisher.setDemand(surfaceID: surfaceID, isDemanded: isDemanded)
            }
        }
        let registration = coordinator.register(channelID: 0) { event in
            _ = demandPipe.continuation.yield(event)
        }
        defer { registration.cancel() }
        let source = SpiceDesktopSource(frameDemandCoordinator: coordinator)
        source.beginSession(pointerMode: .absolute)
        let subscription = source.subscribe()

        let visibleTask = Task.detached {
            subscription.setDemand(.visible)
        }
        #expect(
            await waitForDesktopDemandSemaphore(
                visibleMutationEntered,
                timeout: .seconds(1)
            ) == .success
        )
        let cancelTask = Task.detached {
            cancelStarted.signal()
            subscription.cancel()
        }
        #expect(await waitForDesktopDemandSemaphore(
            cancelStarted,
            timeout: .seconds(1)
        ) == .success)
        releaseVisibleMutation.signal()
        await visibleTask.value
        await cancelTask.value

        demandPipe.continuation.finish()
        await demandWorker.value
        await publisher.submit(SurfaceRevision(
            surfaceID: key.surfaceID,
            lifecycleGeneration: 1,
            revision: 1
        ))
        await publisher.flushNow()

        let metrics = await publisher.metrics()
        #expect(metrics.demandedSurfaces == 0)
        #expect(metrics.demandSuppressedSubmissions == 1)
        #expect(snapshotCount.withLock { $0 } == 0)
        #expect(source.metrics().visibleSubscriptions == 0)
        await publisher.cancel()
    }

    @Test func streamOnlySubscriberAutoAcknowledgesEveryPublication() async throws {
        let coordinator = DisplayFrameDemandCoordinator()
        let source = SpiceDesktopSource(frameDemandCoordinator: coordinator)
        let consumed = Mutex<[SurfaceRevision]>([])
        let registration = coordinator.register(channelID: 0) { event in
            guard case let .frameConsumed(revision) = event else { return }
            consumed.withLock { $0.append(revision) }
        }
        defer { registration.cancel() }
        source.beginSession(pointerMode: .absolute)
        let subscription = source.subscribe()
        subscription.setDemand(.visible)
        var updates = subscription.updates.makeAsyncIterator()

        source.receiveFrame(Self.frame(revision: 1), displayChannelID: 0)
        #expect(try #require(await updates.next()).frame?.revision.value == 1)
        source.receiveFrame(Self.frame(revision: 2), displayChannelID: 0)
        #expect(try #require(await updates.next()).frame?.revision.value == 2)

        #expect(consumed.withLock { $0.map(\.revision) } == [1, 2])
        subscription.cancel()
    }

    @Test func packageHandlerIsExclusiveAndGatesPublisherUntilDisplayTick() throws {
        let coordinator = DisplayFrameDemandCoordinator()
        let source = SpiceDesktopSource(frameDemandCoordinator: coordinator)
        let consumed = Mutex<[SurfaceRevision]>([])
        let delivered = Mutex<[SpiceDesktopSnapshot]>([])
        let registration = coordinator.register(channelID: 0) { event in
            guard case let .frameConsumed(revision) = event else { return }
            consumed.withLock { $0.append(revision) }
        }
        defer { registration.cancel() }
        source.beginSession(pointerMode: .absolute)
        let subscription = source.subscribe()
        subscription.setUpdateHandler { snapshot in
            delivered.withLock { $0.append(snapshot) }
        }
        subscription.setDemand(.visible)
        let initialHandlerDeliveries = source.metrics().handlerDeliveries

        source.receiveFrame(Self.frame(revision: 7), displayChannelID: 0)
        let revision = try #require(delivered.withLock { $0.last?.frame?.revision })
        #expect(consumed.withLock { $0.isEmpty })
        #expect(source.metrics().handlerDeliveries == initialHandlerDeliveries + 1)

        subscription.acknowledgeFrame(revision)
        #expect(consumed.withLock { $0.map(\.revision) } == [7])
        subscription.cancel()
    }

    @Test func explicitLatestRequestRedeliversAuthoritativeFrameWithNewSequence() throws {
        let source = SpiceDesktopSource()
        source.beginSession(pointerMode: .absolute)
        let delivered = Mutex<[SpiceDesktopSnapshot]>([])
        let subscription = source.subscribe()
        subscription.setUpdateHandler { snapshot in
            delivered.withLock { $0.append(snapshot) }
        }
        subscription.setDemand(.visible)
        source.receiveFrame(Self.frame(revision: 7), displayChannelID: 0)

        let initial = try #require(delivered.withLock { snapshots in
            snapshots.last { $0.frame != nil }
        })
        let initialFrame = try #require(initial.frame)
        let latch = SpiceDesktopReadyLatch()

        #expect(latch.offer(initial))
        let selectedInitial = try #require(latch.take())
        #expect(selectedInitial.deliverySequence == initial.deliverySequence)

        // An unsolicited duplicate remains the same delivery identity and
        // cannot wake a latch that already selected it.
        #expect(!latch.offer(initial))
        #expect(latch.isEmpty)

        delivered.withLock { $0.removeAll(keepingCapacity: true) }
        subscription.requestLatest()
        let firstRedraw = try #require(delivered.withLock { $0.only })
        let firstRedrawFrame = try #require(firstRedraw.frame)
        #expect(firstRedrawFrame.revision == initialFrame.revision)
        #expect(firstRedrawFrame.frame == initialFrame.frame)
        #expect(firstRedrawFrame.damage == .full)
        #expect(firstRedraw.deliverySequence > initial.deliverySequence)
        #expect(latch.offer(firstRedraw))
        let selectedFirstRedraw = try #require(latch.take())
        #expect(selectedFirstRedraw.deliverySequence == firstRedraw.deliverySequence)

        delivered.withLock { $0.removeAll(keepingCapacity: true) }
        subscription.requestLatest()
        let secondRedraw = try #require(delivered.withLock { $0.only })
        let secondRedrawFrame = try #require(secondRedraw.frame)
        #expect(secondRedrawFrame.revision == initialFrame.revision)
        #expect(secondRedrawFrame.frame == initialFrame.frame)
        #expect(secondRedrawFrame.damage == .full)
        #expect(secondRedraw.deliverySequence > firstRedraw.deliverySequence)
        #expect(latch.offer(secondRedraw))
        let selectedSecondRedraw = try #require(latch.take())
        #expect(selectedSecondRedraw.deliverySequence == secondRedraw.deliverySequence)
        #expect(latch.isEmpty)
        subscription.cancel()
    }

    @Test func secondVisibleSubscriberImmediatelyReceivesRetainedLatestAsFull() async throws {
        let source = SpiceDesktopSource()
        source.beginSession(pointerMode: .absolute)
        let first = source.subscribe()
        first.setDemand(.visible)
        var firstUpdates = first.updates.makeAsyncIterator()
        source.receiveFrame(Self.frame(revision: 5), displayChannelID: 0)
        _ = await firstUpdates.next()

        let second = source.subscribe()
        var secondUpdates = second.updates.makeAsyncIterator()
        second.setDemand(.visible)

        let initial = try #require(await secondUpdates.next())
        #expect(initial.frame?.revision.value == 5)
        #expect(initial.frame?.damage == .full)
        first.cancel()
        second.cancel()
    }

    @Test func hiddenMutationsResumeWithExactlyOneFreshLatestFullSnapshot() throws {
        let source = SpiceDesktopSource()
        source.beginSession(pointerMode: .absolute)
        let delivered = Mutex<[SpiceDesktopSnapshot]>([])
        let subscription = source.subscribe()
        subscription.setUpdateHandler { snapshot in
            delivered.withLock { $0.append(snapshot) }
        }
        subscription.setDemand(.visible)
        source.receiveFrame(Self.frame(revision: 1), displayChannelID: 0)
        #expect(delivered.withLock { $0.compactMap(\.frame).count } == 1)

        subscription.setDemand(.none)
        for revision in 2...1_001 {
            source.receiveFrame(
                Self.frame(revision: UInt64(revision)),
                displayChannelID: 0
            )
        }
        delivered.withLock { $0.removeAll(keepingCapacity: true) }

        subscription.setDemand(.visible)
        #expect(delivered.withLock { $0.isEmpty })
        // The publisher makes a fresh authoritative snapshot of the canonical
        // latest revision when demand resumes.
        source.receiveFrame(Self.frame(revision: 1_001), displayChannelID: 0)

        let recovery = try #require(delivered.withLock { $0.only })
        #expect(recovery.frame?.revision.value == 1_001)
        #expect(recovery.frame?.damage == .full)
        subscription.cancel()
    }

    @Test func cursorOnlyUpdateRetainsFrameRevisionWithEmptyDamage() async throws {
        let source = SpiceDesktopSource()
        source.beginSession(pointerMode: .relative)
        let subscription = source.subscribe()
        subscription.setDemand(.visible)
        var updates = subscription.updates.makeAsyncIterator()

        source.receiveFrame(Self.frame(revision: 4), displayChannelID: 0)
        _ = await updates.next()
        source.updateCursor(SpiceCursorState(x: 10, y: 12, isVisible: false, image: nil))

        let cursorOnly = try #require(await updates.next())
        #expect(cursorOnly.frame?.revision.value == 4)
        #expect(cursorOnly.frame?.damage == .rectangles([]))
        #expect(cursorOnly.cursor?.x == 10)
        #expect(cursorOnly.pointerMode == .relative)
        subscription.cancel()
    }

    @Test func controlStateMergePreservesThePublishedFrameIdentity() throws {
        let anchor = ContinuousClock().now
        let timing = DisplayFrameSourceTiming(
            messageReceivedAt: anchor.advanced(by: .nanoseconds(50)),
            surfaceReadyAt: anchor.advanced(by: .nanoseconds(60))
        )
        let receive = try #require(SpiceInteractionHostClock.nanoseconds(
            for: timing.messageReceivedAt
        ))
        let ready = try #require(SpiceInteractionHostClock.nanoseconds(
            for: timing.surfaceReadyAt
        ))
        let diagnostics = SpicePresentationDiagnostics()
        let assembler = Self.interactionAssembler()
        diagnostics.setInteractionTraceAssembler(assembler)
        Self.recordInteractionEvidence(on: assembler, beforeDisplayReceiveNs: receive)

        let source = SpiceDesktopSource(presentationDiagnostics: diagnostics)
        source.beginSession(pointerMode: .absolute)
        let latch = SpiceDesktopReadyLatch()
        let deliveries = Mutex<[SpiceDesktopSnapshot]>([])
        let subscription = source.subscribe()
        defer { subscription.cancel() }
        subscription.setUpdateHandler { snapshot in
            deliveries.withLock { $0.append(snapshot) }
            if snapshot.frame != nil {
                _ = latch.offer(snapshot)
            }
        }
        subscription.setDemand(.visible)

        source.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Self.interactionFrame(
                    lifecycle: 1,
                    revision: 1,
                    containsMarker: true
                ),
                sourceTiming: timing
            ),
            displayChannelID: 0
        )
        let publishedFrame = try #require(deliveries.withLock { snapshots in
            snapshots.last { $0.frame?.revision.value == 1 }
        })
        let publishedIdentity = try #require(publishedFrame.interactionFrameIdentity)

        // These control-state publications are newer desktop snapshots, but
        // they still carry the exact frame publication already registered by
        // the interaction assembler.
        source.updateCursor(SpiceCursorState(
            x: 23,
            y: 17,
            isVisible: true,
            image: nil
        ))
        source.updatePointerMode(.relative)
        let selected = try #require(latch.take())
        let selectedIdentity = try #require(selected.interactionFrameIdentity)
        #expect(selected.deliverySequence > publishedFrame.deliverySequence)
        #expect(selected.cursor?.x == 23)
        #expect(selected.pointerMode == .relative)
        #expect(selectedIdentity == publishedIdentity)

        diagnostics.recordInteractionSelected(
            identity: selectedIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        diagnostics.recordInteractionCommitted(identity: selectedIdentity, at: ready + 20)
        diagnostics.recordInteractionPresented(identity: selectedIdentity, at: ready + 30)
        let record = assembler.finish()
        #expect(record.valid)
        #expect(record.deliverySequence == publishedIdentity.deliverySequence)

        // A real frame publication must advance the frame identity rather
        // than inheriting the preceding frame's sequence through the merge.
        source.receiveFrame(
            Self.interactionFrame(lifecycle: 1, revision: 2, containsMarker: false),
            displayChannelID: 0
        )
        let nextFrame = try #require(latch.take())
        let nextIdentity = try #require(nextFrame.interactionFrameIdentity)
        #expect(nextIdentity.frameRevision == 2)
        #expect(nextIdentity.deliverySequence == nextFrame.deliverySequence)
        #expect(nextIdentity.deliverySequence > publishedIdentity.deliverySequence)
    }

    @Test func destroyAndRecreateCannotLeakOldSurfaceLifecycle() async throws {
        let source = SpiceDesktopSource()
        source.beginSession(pointerMode: .absolute)
        let subscription = source.subscribe()
        subscription.setDemand(.visible)
        var updates = subscription.updates.makeAsyncIterator()

        source.receiveFrame(Self.frame(lifecycle: 1, revision: 9), displayChannelID: 0)
        let original = try #require(await updates.next())
        #expect(original.frame?.revision.surface.generation == 1)

        source.surfaceDestroyed(displayChannelID: 0, surfaceID: 0)
        #expect(try #require(await updates.next()).frame == nil)

        source.receiveFrame(Self.frame(lifecycle: 3, revision: 0), displayChannelID: 0)
        let recreated = try #require(await updates.next())
        #expect(recreated.frame?.revision.surface.generation == 3)
        #expect(recreated.frame?.damage == .full)
        subscription.cancel()
    }

    @Test func directLifecycleReplacementRetiresOldTraceWithoutRetiringRevisionUpdates() throws {
        let anchor = ContinuousClock().now
        let oldTiming = DisplayFrameSourceTiming(
            messageReceivedAt: anchor.advanced(by: .nanoseconds(50)),
            surfaceReadyAt: anchor.advanced(by: .nanoseconds(60))
        )
        let updatedTiming = DisplayFrameSourceTiming(
            messageReceivedAt: anchor.advanced(by: .nanoseconds(70)),
            surfaceReadyAt: anchor.advanced(by: .nanoseconds(80))
        )
        let receive = try #require(SpiceInteractionHostClock.nanoseconds(
            for: oldTiming.messageReceivedAt
        ))
        let ready = try #require(SpiceInteractionHostClock.nanoseconds(
            for: oldTiming.surfaceReadyAt
        ))

        let replacedDiagnostics = SpicePresentationDiagnostics()
        let replacedAssembler = Self.interactionAssembler()
        replacedDiagnostics.setInteractionTraceAssembler(replacedAssembler)
        Self.recordInteractionEvidence(
            on: replacedAssembler,
            beforeDisplayReceiveNs: receive
        )
        let replacedSource = SpiceDesktopSource(
            presentationDiagnostics: replacedDiagnostics
        )
        replacedSource.beginSession(pointerMode: .absolute)
        let replacedDeliveries = Mutex<[SpiceDesktopSnapshot]>([])
        let replacedSubscription = replacedSource.subscribe()
        defer { replacedSubscription.cancel() }
        replacedSubscription.setUpdateHandler { snapshot in
            replacedDeliveries.withLock { $0.append(snapshot) }
        }
        replacedSubscription.setDemand(.visible)

        replacedSource.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Self.interactionFrame(
                    lifecycle: 1,
                    revision: 1,
                    containsMarker: true
                ),
                sourceTiming: oldTiming
            ),
            displayChannelID: 0
        )
        let replacedOld = try #require(replacedDeliveries.withLock { snapshots in
            snapshots.last { $0.frame?.revision.surface.generation == 1 }
        })
        let replacedOldIdentity = try #require(replacedOld.interactionFrameIdentity)
        replacedDiagnostics.recordInteractionSelected(
            identity: replacedOldIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )

        replacedSource.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Self.interactionFrame(
                    lifecycle: 2,
                    revision: 0,
                    containsMarker: false
                ),
                sourceTiming: updatedTiming
            ),
            displayChannelID: 0
        )
        let replacement = try #require(replacedDeliveries.withLock { snapshots in
            snapshots.last { $0.frame?.revision.surface.generation == 2 }
        })
        #expect(replacement.generation == replacedOld.generation)
        replacedDiagnostics.recordInteractionCommitted(
            identity: replacedOldIdentity,
            at: ready + 20
        )
        replacedDiagnostics.recordInteractionPresented(
            identity: replacedOldIdentity,
            at: ready + 30
        )
        let replacedRecord = replacedAssembler.finish()
        #expect(!replacedRecord.valid)
        #expect(replacedRecord.invalidReason == "surface_lifecycle_retired")
        #expect(replacedRecord.metalCommitNs == nil)
        #expect(replacedRecord.presentedNs == nil)

        let revisionDiagnostics = SpicePresentationDiagnostics()
        let revisionAssembler = Self.interactionAssembler()
        revisionDiagnostics.setInteractionTraceAssembler(revisionAssembler)
        Self.recordInteractionEvidence(
            on: revisionAssembler,
            beforeDisplayReceiveNs: receive
        )
        let revisionSource = SpiceDesktopSource(
            presentationDiagnostics: revisionDiagnostics
        )
        revisionSource.beginSession(pointerMode: .absolute)
        let revisionDeliveries = Mutex<[SpiceDesktopSnapshot]>([])
        let revisionSubscription = revisionSource.subscribe()
        defer { revisionSubscription.cancel() }
        revisionSubscription.setUpdateHandler { snapshot in
            revisionDeliveries.withLock { $0.append(snapshot) }
        }
        revisionSubscription.setDemand(.visible)
        revisionSource.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Self.interactionFrame(
                    lifecycle: 4,
                    revision: 1,
                    containsMarker: true
                ),
                sourceTiming: oldTiming
            ),
            displayChannelID: 0
        )
        let revisionOld = try #require(revisionDeliveries.withLock { snapshots in
            snapshots.last { $0.frame?.revision.value == 1 }
        })
        let revisionOldIdentity = try #require(revisionOld.interactionFrameIdentity)
        revisionDiagnostics.recordInteractionSelected(
            identity: revisionOldIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        revisionSource.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Self.interactionFrame(
                    lifecycle: 4,
                    revision: 2,
                    containsMarker: false
                ),
                sourceTiming: updatedTiming
            ),
            displayChannelID: 0
        )
        revisionDiagnostics.recordInteractionCommitted(
            identity: revisionOldIdentity,
            at: ready + 20
        )
        revisionDiagnostics.recordInteractionPresented(
            identity: revisionOldIdentity,
            at: ready + 30
        )
        let revisionRecord = revisionAssembler.finish()
        #expect(revisionRecord.valid)
        #expect(revisionRecord.surfaceGeneration == 4)
        #expect(revisionRecord.frameRevision == 1)
    }

    @Test func reconnectAdvancesDesktopGenerationAndPublishesBootstrapPointerMode() async throws {
        let source = SpiceDesktopSource()
        let subscription = source.subscribe()
        subscription.setDemand(.visible)
        var updates = subscription.updates.makeAsyncIterator()

        source.beginSession(pointerMode: .relative)
        let first = try #require(await updates.next())
        source.endSession()
        let disconnected = try #require(await updates.next())
        source.beginSession(pointerMode: .absolute)
        let reconnected = try #require(await updates.next())

        #expect(first.pointerMode == .relative)
        #expect(disconnected.generation > first.generation)
        #expect(reconnected.generation > disconnected.generation)
        #expect(reconnected.pointerMode == .absolute)
        #expect(reconnected.frame == nil)
        subscription.cancel()
    }

    @Test func outOfOrderOffersSelectNewestSequenceAndMergeDamage() throws {
        let firstFrame = SpiceFrame(
            surfaceID: 0,
            width: 4,
            height: 4,
            bytesPerRow: 16,
            pixels: Data(repeating: 10, count: 64)
        )
        let latestFrame = SpiceFrame(
            surfaceID: 0,
            width: 4,
            height: 4,
            bytesPerRow: 16,
            pixels: Data(repeating: 11, count: 64)
        )
        let surface = SpiceSurfaceIdentity(
            displayChannelID: 0,
            surfaceID: 0,
            generation: 1
        )
        let older = SpiceDesktopSnapshot(
            generation: 3,
            frame: SpiceFrameUpdate(
                frame: firstFrame,
                revision: SpiceFrameRevision(surface: surface, value: 10),
                damage: .rectangles([
                    SpicePixelRect(x: 0, y: 0, width: 1, height: 1),
                ])
            ),
            cursor: SpiceCursorState(x: 1, y: 1, isVisible: true, image: nil),
            pointerMode: .absolute,
            deliverySequence: 40
        )
        let newest = SpiceDesktopSnapshot(
            generation: 3,
            frame: SpiceFrameUpdate(
                frame: latestFrame,
                revision: SpiceFrameRevision(surface: surface, value: 11),
                damage: .rectangles([
                    SpicePixelRect(x: 1, y: 1, width: 1, height: 1),
                ])
            ),
            cursor: SpiceCursorState(x: 9, y: 8, isVisible: false, image: nil),
            pointerMode: .relative,
            deliverySequence: 41
        )

        let selected = SpiceDesktopSource.merging(newest, older)

        #expect(selected.deliverySequence == 41)
        #expect(selected.frame?.revision.value == 11)
        #expect(selected.cursor?.x == 9)
        #expect(selected.pointerMode == .relative)
        guard case let .rectangles(rectangles) = selected.frame?.damage else {
            Issue.record("expected merged rectangular damage")
            return
        }
        #expect(Set(rectangles) == Set([
            SpicePixelRect(x: 0, y: 0, width: 1, height: 1),
            SpicePixelRect(x: 1, y: 1, width: 1, height: 1),
        ]))
    }

    private static func frame(
        lifecycle: UInt64 = 1,
        revision: UInt64
    ) -> FrameSnapshot {
        FrameSnapshot(
            surfaceID: 0,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            lifecycleGeneration: lifecycle,
            revision: revision,
            pixels: Data(repeating: UInt8(truncatingIfNeeded: revision), count: 16),
            ioSurfaceFrame: nil
        )
    }

    private static func interactionAssembler() -> SpiceInteractionTraceAssembler {
        SpiceInteractionTraceAssembler(
            pairId: "pair-lifecycle",
            version: "v0.3.1",
            runId: "run-lifecycle",
            order: 1,
            actionClass: .click,
            token: "0123456789abcdef",
            checksum: 0x9f9f_5111
        )
    }

    private static func recordInteractionEvidence(
        on assembler: SpiceInteractionTraceAssembler,
        beforeDisplayReceiveNs displayReceiveNs: UInt64
    ) {
        assembler.recordHostEvidence(
            scheduledNs: displayReceiveNs - 40,
            hostInputNs: displayReceiveNs - 30,
            sendStartedNs: displayReceiveNs - 20,
            sendCompletedNs: displayReceiveNs - 10
        )
        assembler.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
    }

    private static func interactionFrame(
        lifecycle: UInt64,
        revision: UInt64,
        containsMarker: Bool
    ) -> FrameSnapshot {
        let width = 384
        let height = 48
        let bytesPerRow = width * 4
        let pixels: Data
        if containsMarker {
            pixels = SpiceInteractionMarkerROIDetector.renderForTesting(
                placements: [SpiceInteractionMarkerPlacement(
                    payload: SpiceInteractionMarkerPayload(
                        token: "0123456789abcdef",
                        markerRevision: 77,
                        checksum: 0x9f9f_5111
                    ),
                    originX: 8,
                    originY: 8
                )],
                frameWidth: width,
                frameHeight: height,
                bytesPerRow: bytesPerRow
            )
        } else {
            pixels = Data(repeating: 0x7f, count: bytesPerRow * height)
        }
        return FrameSnapshot(
            surfaceID: 0,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            lifecycleGeneration: lifecycle,
            revision: revision,
            pixels: pixels,
            ioSurfaceFrame: nil
        )
    }
}

private func waitForDesktopDemandSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval
) async -> DispatchTimeoutResult {
    await Task.detached {
        blockingWaitForDesktopDemandSemaphore(semaphore, timeout: timeout)
    }.value
}

private func blockingWaitForDesktopDemandSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + timeout)
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
