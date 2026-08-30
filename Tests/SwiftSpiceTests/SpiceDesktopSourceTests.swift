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

    @Test func controlStateEnvelopePreservesFramePublicationSequence() throws {
        let frame = SpiceFrame(
            surfaceID: 0,
            width: 4,
            height: 4,
            bytesPerRow: 16,
            pixels: Data(repeating: 12, count: 64)
        )
        let surface = SpiceSurfaceIdentity(
            displayChannelID: 0,
            surfaceID: 0,
            generation: 1
        )
        let publishedUpdate = SpiceFrameUpdate(
            frame: frame,
            revision: SpiceFrameRevision(surface: surface, value: 7),
            damage: .full,
            deliverySequence: 40
        )
        let published = SpiceDesktopSnapshot(
            generation: 3,
            frame: publishedUpdate,
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: 40
        )
        let controlOnly = SpiceDesktopSnapshot(
            generation: 3,
            frame: SpiceFrameUpdate(
                frame: frame,
                revision: publishedUpdate.revision,
                damage: .rectangles([]),
                deliverySequence: 40
            ),
            cursor: SpiceCursorState(x: 9, y: 8, isVisible: true, image: nil),
            pointerMode: .relative,
            deliverySequence: 41
        )

        let selected = SpiceDesktopSource.merging(published, controlOnly)

        #expect(selected.deliverySequence == 41)
        #expect(selected.frameDeliverySequence == 40)
        #expect(selected.interactionFrameIdentity == published.interactionFrameIdentity)
        #expect(selected.frame?.revision.value == 7)
        #expect(selected.cursor?.x == 9)
        #expect(selected.pointerMode == .relative)
    }

    @Test func interactionFrameIsObservedBeforeSynchronousDelivery() throws {
        let diagnostics = SpicePresentationDiagnostics()
        let capture = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        try Stage3InteractionFixture.recordPrelude(on: capture)
        let source = SpiceDesktopSource(presentationDiagnostics: diagnostics)
        source.beginSession(pointerMode: .absolute)
        let subscription = source.subscribe(surface: .surface(displayChannelID: 2, surfaceID: 7))
        subscription.setUpdateHandler { snapshot in
            guard let identity = snapshot.interactionFrameIdentity else { return }
            Stage3InteractionFixture.present(identity, using: diagnostics)
        }
        subscription.setDemand(.visible)

        source.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Stage3InteractionFixture.rendererFrame(lifecycle: 4, revision: 9),
                sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
            ),
            displayChannelID: 2
        )

        let record = try capture.finish()
        #expect(record.valid)
        #expect(record.displayChannelID == 2)
        #expect(record.surfaceID == 7)
        #expect(record.surfaceGeneration == 4)
        #expect(record.frameRevision == 9)
        subscription.cancel()
    }

    @Test func sourceReplacementRetiresOnlyTheOldSurfaceLifecycle() throws {
        let diagnostics = SpicePresentationDiagnostics()
        let source = SpiceDesktopSource(presentationDiagnostics: diagnostics)
        source.beginSession(pointerMode: .absolute)
        let subscription = source.subscribe(surface: .surface(displayChannelID: 2, surfaceID: 7))
        subscription.setDemand(.visible)

        let retired = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        try Stage3InteractionFixture.recordPrelude(on: retired)
        source.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Stage3InteractionFixture.rendererFrame(lifecycle: 4, revision: 9),
                sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
            ),
            displayChannelID: 2
        )
        source.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Stage3InteractionFixture.rendererFrame(lifecycle: 5, revision: 1, marker: false),
                sourceTiming: Stage3InteractionFixture.timing(receive: 31, ready: 41)
            ),
            displayChannelID: 2
        )
        #expect(try retired.finish().invalidReason == "surface_lifecycle_retired")

        let sameLifecycle = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        try Stage3InteractionFixture.recordPrelude(on: sameLifecycle)
        source.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Stage3InteractionFixture.rendererFrame(lifecycle: 5, revision: 2),
                sourceTiming: Stage3InteractionFixture.timing(receive: 32, ready: 42)
            ),
            displayChannelID: 2
        )
        source.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Stage3InteractionFixture.rendererFrame(lifecycle: 5, revision: 3),
                sourceTiming: Stage3InteractionFixture.timing(receive: 33, ready: 43)
            ),
            displayChannelID: 2
        )
        let identity = SpiceInteractionFrameIdentity(
            desktopGeneration: 1,
            displayChannelID: 2,
            surfaceID: 7,
            surfaceGeneration: 5,
            frameRevision: 3,
            deliverySequence: 5
        )
        Stage3InteractionFixture.present(identity, using: diagnostics)
        #expect(try sameLifecycle.finish().valid)

        let destroyed = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        try Stage3InteractionFixture.recordPrelude(on: destroyed)
        source.receiveFrame(
            PublishedDisplayFrame(
                snapshot: Stage3InteractionFixture.rendererFrame(lifecycle: 6, revision: 1),
                sourceTiming: Stage3InteractionFixture.timing(receive: 34, ready: 44)
            ),
            displayChannelID: 2
        )
        source.surfaceDestroyed(displayChannelID: 2, surfaceID: 7)
        #expect(try destroyed.finish().invalidReason == "surface_lifecycle_retired")
        subscription.cancel()
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
