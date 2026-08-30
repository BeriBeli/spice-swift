import Foundation
import Synchronization
import Testing
@testable import SpiceChannels
@testable import SpiceRenderer

@Suite("Display frame publisher")
struct DisplayFramePublisherTests {
    @Test func registrationSnapshotCannotOvertakeConcurrentDemandRemoval() async {
        let initialHandlerEntered = DispatchSemaphore(value: 0)
        let releaseInitialHandler = DispatchSemaphore(value: 0)
        let removalPrepared = DispatchSemaphore(value: 0)
        let removalHandlerEntered = DispatchSemaphore(value: 0)
        let deliveredDemand = Mutex<[Bool]>([])
        let key = DisplaySurfaceKey(channelID: 3, surfaceID: 9)
        let coordinator = DisplayFrameDemandCoordinator(
            afterDemandMutation: { _, _, isDemanded in
                if !isDemanded {
                    removalPrepared.signal()
                }
            }
        )
        coordinator.setDemand(for: key, subscriberID: 41, isDemanded: true)

        let registrationTask = Task.detached {
            coordinator.register(channelID: key.channelID) { event in
                guard case let .demandChanged(_, isDemanded) = event else { return }
                if isDemanded {
                    initialHandlerEntered.signal()
                    releaseInitialHandler.wait()
                } else {
                    removalHandlerEntered.signal()
                }
                deliveredDemand.withLock { $0.append(isDemanded) }
            }
        }
        let initialEntered = await waitForDemandSemaphore(
            initialHandlerEntered,
            timeout: .seconds(1)
        )
        #expect(initialEntered == .success)

        let removalTask = Task.detached {
            coordinator.setDemand(for: key, subscriberID: 41, isDemanded: false)
        }
        #expect(await waitForDemandSemaphore(
            removalPrepared,
            timeout: .seconds(1)
        ) == .success)
        #expect(
            await waitForDemandSemaphore(
                removalHandlerEntered,
                timeout: .milliseconds(50)
            ) == .timedOut
        )

        releaseInitialHandler.signal()
        let registration = await registrationTask.value
        await removalTask.value
        #expect(await waitForDemandSemaphore(
            removalHandlerEntered,
            timeout: .seconds(1)
        ) == .success)
        #expect(deliveredDemand.withLock { $0 } == [true, false])
        registration.cancel()
    }

    @Test func timingHistogramMergesWithoutRetainingIndividualSamples() {
        var first = SpiceTimingHistogram()
        first.record(.milliseconds(1))
        first.record(.milliseconds(4))
        var second = SpiceTimingHistogram()
        second.record(.milliseconds(33))

        first.accumulate(second)

        #expect(first.summary.sampleCount == 3)
        #expect(first.summary.p95Milliseconds == 33)
        #expect(first.summary.maximumMilliseconds == 33)
    }

    @Test func recordsBoundedSourcePipelineTiming() async {
        let observations = FramePublisherObservations()
        let publisher = makePublisher(observations: observations)
        let clock = ContinuousClock()
        let secondReceivedAt = clock.now.advanced(by: .milliseconds(-8))
        let firstReceivedAt = secondReceivedAt.advanced(by: .milliseconds(-33))

        await publisher.submit(
            surfaceRevision(surfaceID: 1, revision: 1),
            sourceTiming: DisplayFrameSourceTiming(
                messageReceivedAt: firstReceivedAt,
                surfaceReadyAt: firstReceivedAt.advanced(by: .milliseconds(4))
            )
        )
        await publisher.flushNow()
        await publisher.submit(
            surfaceRevision(surfaceID: 1, revision: 2),
            sourceTiming: DisplayFrameSourceTiming(
                messageReceivedAt: secondReceivedAt,
                surfaceReadyAt: secondReceivedAt.advanced(by: .milliseconds(4))
            )
        )

        let metrics = await publisher.metrics()
        #expect(metrics.framedReceiveBatchStartGap.summary.sampleCount == 1)
        #expect(metrics.framedReceiveBatchStartGap.summary.p95Milliseconds == 33)
        #expect(metrics.messageReceiveToSurfaceReady.summary.sampleCount == 2)
        #expect(metrics.messageReceiveToSurfaceReady.summary.p95Milliseconds == 4)
        #expect(metrics.surfaceReadyToSubmit.summary.sampleCount == 2)
    }

    @Test func snapshotsOnlyOnceAfterRepeatedChangesToOneSurface() async {
        let observations = FramePublisherObservations()
        let publisher = makePublisher(observations: observations)
        let revision = surfaceRevision(surfaceID: 1, revision: 1)

        for _ in 0..<1_000 {
            await publisher.submit(revision)
        }
        #expect(await observations.snapshotCount == 0)

        await publisher.flushNow()

        #expect(await observations.snapshotCount == 1)
        #expect(await observations.emittedRevisions == [revision])
        let metrics = await publisher.metrics()
        #expect(metrics.submissions == 1_000)
        #expect(metrics.snapshotAttempts == 1)
        #expect(metrics.emittedFrames == 1)
        #expect(metrics.emittedIOSurfaceFrames == 0)
        #expect(metrics.emittedCPUOnlyFrames == 1)
        #expect(metrics.flushes == 1)
        #expect(metrics.flushesWithoutEmission == 0)
        #expect(metrics.snapshotDuration.summary.sampleCount == 1)
        #expect(metrics.emitDuration.summary.sampleCount == 1)
    }

    @Test func preservesSurfaceOrderAndPublishesLatestRevisionAtFlush() async {
        let observations = FramePublisherObservations()
        let publisher = makePublisher(observations: observations)
        let latest = surfaceRevision(surfaceID: 1, revision: 9)
        let second = surfaceRevision(surfaceID: 2, revision: 2)

        await publisher.submit(surfaceRevision(surfaceID: 1, revision: 1))
        await publisher.submit(second)
        await publisher.submit(latest)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [latest, second])
    }

    @Test func destroyDuringSnapshotSuppressesOldFrame() async {
        let observations = FramePublisherObservations(blockNextSnapshot: true)
        let publisher = makePublisher(observations: observations)
        await publisher.submit(surfaceRevision(surfaceID: 1, lifecycle: 1, revision: 1))

        let flush = Task { await publisher.flushNow() }
        await waitForSnapshotStart(observations)
        await publisher.remove(surfaceID: 1)
        await observations.resumeSnapshot()
        await flush.value

        #expect(await observations.emittedRevisions.isEmpty)
        #expect(await publisher.metrics().staleSnapshots == 1)
    }

    @Test func sameIDRecreationCannotPublishPreviousLifecycle() async {
        let observations = FramePublisherObservations(blockNextSnapshot: true)
        let publisher = makePublisher(observations: observations)
        let old = surfaceRevision(surfaceID: 1, lifecycle: 1, revision: 4)
        let recreated = surfaceRevision(surfaceID: 1, lifecycle: 3, revision: 0)
        await publisher.submit(old)

        let firstFlush = Task { await publisher.flushNow() }
        await waitForSnapshotStart(observations)
        await publisher.remove(surfaceID: 1)
        await publisher.submit(recreated)
        await observations.resumeSnapshot()
        await firstFlush.value
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [recreated])
    }

    @Test func explicitDemandSurvivesSameIDSurfaceRecreation() async {
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            requiresExplicitDemand: true,
            waitsForConsumption: true,
            snapshot: { revision in
                await observations.snapshot(revision: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        let original = surfaceRevision(surfaceID: 1, lifecycle: 1, revision: 4)
        let recreated = surfaceRevision(surfaceID: 1, lifecycle: 2, revision: 0)

        await publisher.setDemand(surfaceID: 1, isDemanded: true)
        await publisher.submit(original)
        await publisher.flushNow()
        await publisher.acknowledge(original)
        await publisher.remove(surfaceID: 1)
        await publisher.submit(recreated)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [original, recreated])
        #expect(await publisher.metrics().demandedSurfaces == 1)
    }

    @Test func updateDuringSnapshotEmitsCapturedRevisionThenLatestRevision() async {
        let observations = FramePublisherObservations(blockNextSnapshot: true)
        let publisher = makePublisher(observations: observations)
        let first = surfaceRevision(surfaceID: 1, revision: 1)
        let latest = surfaceRevision(surfaceID: 1, revision: 2)
        await publisher.submit(first)

        let firstFlush = Task { await publisher.flushNow() }
        await waitForSnapshotStart(observations)
        await publisher.submit(latest)
        await observations.resumeSnapshot()
        await firstFlush.value

        #expect(await observations.emittedRevisions == [first])
        var metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 1)
        #expect(metrics.emittedFrames == 1)
        #expect(metrics.staleSnapshots == 0)
        #expect(metrics.pendingSurfaces == 1)

        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [first, latest])
        metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 2)
        #expect(metrics.emittedFrames == 2)
        #expect(metrics.staleSnapshots == 0)
        #expect(metrics.pendingSurfaces == 0)
    }

    @Test func newerSnapshotConsumesCoveredReplacementAndFutureDuplicate() async {
        let first = surfaceRevision(surfaceID: 1, revision: 1)
        let latest = surfaceRevision(surfaceID: 1, revision: 2)
        let observations = FramePublisherObservations(
            blockNextSnapshot: true,
            nextSnapshotRevision: latest
        )
        let publisher = makePublisher(observations: observations)
        await publisher.submit(first)

        let flush = Task { await publisher.flushNow() }
        await waitForSnapshotStart(observations)
        await publisher.submit(latest)
        await observations.resumeSnapshot()
        await flush.value

        #expect(await observations.emittedRevisions == [latest])
        var metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 1)
        #expect(metrics.emittedFrames == 1)
        #expect(metrics.staleSnapshots == 0)
        #expect(metrics.pendingSurfaces == 0)

        await publisher.submit(latest)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [latest])
        metrics = await publisher.metrics()
        #expect(metrics.submissions == 3)
        #expect(metrics.snapshotAttempts == 1)
        #expect(metrics.pendingSurfaces == 0)
    }

    @Test func coveredReplacementUsesOnlyItsOwnExactSourceTiming() async {
        let first = surfaceRevision(surfaceID: 1, revision: 1)
        let replacement = surfaceRevision(surfaceID: 1, revision: 2)
        let clock = ContinuousClock()
        let firstTiming = DisplayFrameSourceTiming(
            messageReceivedAt: clock.now.advanced(by: .milliseconds(-20)),
            surfaceReadyAt: clock.now.advanced(by: .milliseconds(-15))
        )
        let replacementTiming = DisplayFrameSourceTiming(
            messageReceivedAt: clock.now.advanced(by: .milliseconds(-10)),
            surfaceReadyAt: clock.now.advanced(by: .milliseconds(-5))
        )
        let observations = FramePublisherObservations(
            blockNextSnapshot: true,
            nextSnapshotRevision: replacement
        )
        let publisher = makePublisher(observations: observations)
        await publisher.submit(first, sourceTiming: firstTiming)

        let flush = Task { await publisher.flushNow() }
        await waitForSnapshotStart(observations)
        await publisher.submit(replacement, sourceTiming: replacementTiming)
        await observations.resumeSnapshot()
        await flush.value

        #expect(await observations.emittedRevisions == [replacement])
        #expect(await observations.emittedSourceTimings == [replacementTiming])
    }

    @Test func originalSnapshotPreservesItsOwnExactSourceTiming() async {
        let original = surfaceRevision(surfaceID: 1, revision: 1)
        let clock = ContinuousClock()
        let timing = DisplayFrameSourceTiming(
            messageReceivedAt: clock.now.advanced(by: .milliseconds(-10)),
            surfaceReadyAt: clock.now.advanced(by: .milliseconds(-5))
        )
        let observations = FramePublisherObservations()
        let publisher = makePublisher(observations: observations)

        await publisher.submit(original, sourceTiming: timing)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [original])
        #expect(await observations.emittedSourceTimings == [timing])
    }

    @Test func authoritativeRedrawDoesNotReuseOldSourceTiming() async {
        let revision = surfaceRevision(surfaceID: 1, revision: 1)
        let clock = ContinuousClock()
        let timing = DisplayFrameSourceTiming(
            messageReceivedAt: clock.now.advanced(by: .milliseconds(-10)),
            surfaceReadyAt: clock.now.advanced(by: .milliseconds(-5))
        )
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            requiresExplicitDemand: true,
            waitsForConsumption: true,
            snapshot: { requested in
                await observations.snapshot(revision: requested)
            },
            emit: { published in
                await observations.emit(published)
            }
        )

        await publisher.setDemand(surfaceID: 1, isDemanded: true)
        await publisher.submit(revision, sourceTiming: timing)
        await publisher.flushNow()
        await publisher.acknowledge(revision)

        await publisher.setDemand(surfaceID: 1, isDemanded: false)
        await publisher.setDemand(surfaceID: 1, isDemanded: true)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [revision, revision])
        #expect(await observations.emittedSourceTimings == [timing, nil])
        #expect(await observations.emittedFullDamage == [true, true])
    }

    @Test func surfaceStorePublicationWaitsUntilNewerRevisionIsSubmitted() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 7, width: 1, height: 1, format: 32)
        let requested = try await store.descriptor(surfaceID: 7).surfaceRevision
        try await store.fill(
            surfaceID: 7,
            rectangle: PixelRect(x: 0, y: 0, width: 1, height: 1),
            colorARGB: 0x0011_2233
        )
        let latest = try await store.descriptor(surfaceID: 7).surfaceRevision
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            snapshot: { revision in
                await store.snapshot(atLeast: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )

        await publisher.submit(requested)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions.isEmpty)
        var metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 1)
        #expect(metrics.emittedFrames == 0)
        #expect(metrics.staleSnapshots == 0)
        #expect(metrics.pendingSurfaces == 0)

        await publisher.submit(latest)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [latest])
        metrics = await publisher.metrics()
        #expect(metrics.submissions == 2)
        #expect(metrics.snapshotAttempts == 2)
        #expect(metrics.emittedFrames == 1)
        #expect(metrics.emittedIOSurfaceFrames == 1)
        #expect(metrics.emittedCPUOnlyFrames == 0)
        #expect(metrics.staleSnapshots == 0)
        #expect(metrics.pendingSurfaces == 0)
        #expect(metrics.flushes == 2)
        #expect(metrics.flushesWithoutEmission == 1)
    }

    @Test func unpublishedIntermediateRevisionIsDeferredUntilFinalRevisionArrives() async {
        let requested = surfaceRevision(surfaceID: 1, revision: 1)
        let intermediate = surfaceRevision(surfaceID: 1, revision: 2)
        let final = surfaceRevision(surfaceID: 1, revision: 3)
        let observations = FramePublisherObservations(nextSnapshotRevision: intermediate)
        let publisher = makePublisher(observations: observations)

        await publisher.submit(requested)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions.isEmpty)
        var metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 1)
        #expect(metrics.emittedFrames == 0)
        #expect(metrics.staleSnapshots == 0)
        #expect(metrics.pendingSurfaces == 0)

        await publisher.submit(final)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [final])
        metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 2)
        #expect(metrics.emittedFrames == 1)
        #expect(metrics.staleSnapshots == 0)
        #expect(metrics.pendingSurfaces == 0)
    }

    @Test func duplicateSubmittedDuringEmitDoesNotScheduleAnotherSnapshot() async {
        let revision = surfaceRevision(surfaceID: 1, revision: 1)
        let observations = FramePublisherObservations(blockNextEmit: true)
        let publisher = makePublisher(observations: observations)
        await publisher.submit(revision)

        let flush = Task { await publisher.flushNow() }
        await waitForEmitStart(observations)
        await publisher.submit(revision)
        await observations.resumeEmit()
        await flush.value
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [revision])
        let metrics = await publisher.metrics()
        #expect(metrics.submissions == 2)
        #expect(metrics.snapshotAttempts == 1)
        #expect(metrics.emittedFrames == 1)
        #expect(metrics.pendingSurfaces == 0)
    }

    @Test func cancellationDuringSnapshotClearsPendingWork() async {
        let observations = FramePublisherObservations(blockNextSnapshot: true)
        let publisher = makePublisher(observations: observations)
        await publisher.submit(surfaceRevision(surfaceID: 1, revision: 1))

        let flush = Task { await publisher.flushNow() }
        await waitForSnapshotStart(observations)
        await publisher.cancel()
        await observations.resumeSnapshot()
        await flush.value

        #expect(await observations.emittedRevisions.isEmpty)
        #expect(await publisher.metrics().pendingSurfaces == 0)
    }

    @Test func submissionsAfterCancellationAreIgnored() async {
        let observations = FramePublisherObservations()
        let publisher = makePublisher(observations: observations)
        await publisher.cancel()

        await publisher.submit(surfaceRevision(surfaceID: 1, revision: 1))
        await publisher.flushNow()

        #expect(await observations.snapshotCount == 0)
        #expect(await observations.emittedRevisions.isEmpty)
        let metrics = await publisher.metrics()
        #expect(metrics.submissions == 1)
        #expect(metrics.snapshotAttempts == 0)
        #expect(metrics.pendingSurfaces == 0)
    }

    @Test func evictsOldestPendingSurfaceWithoutDisturbingOrder() async {
        let observations = FramePublisherObservations()
        let publisher = makePublisher(
            observations: observations,
            maximumPendingSurfaces: 2
        )
        let second = surfaceRevision(surfaceID: 2, revision: 1)
        let third = surfaceRevision(surfaceID: 3, revision: 1)

        await publisher.submit(surfaceRevision(surfaceID: 1, revision: 1))
        await publisher.submit(second)
        await publisher.submit(third)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [second, third])
        #expect(await publisher.metrics().pendingEvictions == 1)
    }

    @Test func hiddenMutationsDoNotSnapshotAndResumePublishesOnlyLatestFullFrame() async {
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            requiresExplicitDemand: true,
            waitsForConsumption: true,
            snapshot: { revision in
                await observations.snapshot(revision: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        let first = surfaceRevision(surfaceID: 1, revision: 1)
        await publisher.setDemand(surfaceID: 1, isDemanded: true)
        await publisher.submit(first)
        await publisher.flushNow()
        #expect(await observations.emittedRevisions == [first])
        await publisher.acknowledge(first)

        await publisher.setDemand(surfaceID: 1, isDemanded: false)
        for revision in 2...1_001 {
            await publisher.submit(surfaceRevision(surfaceID: 1, revision: UInt64(revision)))
        }
        await publisher.flushNow()

        #expect(await observations.snapshotCount == 1)
        var metrics = await publisher.metrics()
        #expect(metrics.demandSuppressedSubmissions == 1_000)
        #expect(metrics.pendingSurfaces == 1)
        #expect(metrics.preparedFrames == 0)

        await publisher.setDemand(surfaceID: 1, isDemanded: true)
        await publisher.flushNow()
        let latest = surfaceRevision(surfaceID: 1, revision: 1_001)
        #expect(await observations.emittedRevisions == [first, latest])
        #expect(await observations.emittedFullDamage == [true, true])
        #expect(await observations.snapshotCount == 2)
        metrics = await publisher.metrics()
        #expect(metrics.pendingSurfaces == 0)
        #expect(metrics.preparedFrames == 1)
        #expect(metrics.pendingRevisionCoalesces >= 999)
    }

    private func makePublisher(
        observations: FramePublisherObservations,
        maximumPendingSurfaces: Int = 16
    ) -> DisplayFramePublisher {
        DisplayFramePublisher(
            interval: .seconds(10),
            maximumPendingSurfaces: maximumPendingSurfaces,
            snapshot: { revision in
                await observations.snapshot(revision: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
    }

    private func surfaceRevision(
        surfaceID: UInt32,
        lifecycle: UInt64 = 1,
        revision: UInt64
    ) -> SurfaceRevision {
        SurfaceRevision(
            surfaceID: surfaceID,
            lifecycleGeneration: lifecycle,
            revision: revision
        )
    }

    private func waitForSnapshotStart(_ observations: FramePublisherObservations) async {
        while await observations.snapshotCount == 0 {
            await Task.yield()
        }
    }

    private func waitForEmitStart(_ observations: FramePublisherObservations) async {
        while await observations.emitCount == 0 {
            await Task.yield()
        }
    }
}

private func waitForDemandSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval
) async -> DispatchTimeoutResult {
    await Task.detached {
        blockingWaitForDemandSemaphore(semaphore, timeout: timeout)
    }.value
}

private func blockingWaitForDemandSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval
) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + timeout)
}

private actor FramePublisherObservations {
    private var shouldBlockNextSnapshot: Bool
    private var shouldBlockNextEmit: Bool
    private var nextSnapshotRevision: SurfaceRevision?
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private var emitContinuation: CheckedContinuation<Void, Never>?
    private(set) var snapshotCount = 0
    private(set) var emitCount = 0
    private(set) var emittedRevisions: [SurfaceRevision] = []
    private(set) var emittedFullDamage: [Bool] = []
    private(set) var emittedSourceTimings: [DisplayFrameSourceTiming?] = []

    init(
        blockNextSnapshot: Bool = false,
        blockNextEmit: Bool = false,
        nextSnapshotRevision: SurfaceRevision? = nil
    ) {
        shouldBlockNextSnapshot = blockNextSnapshot
        shouldBlockNextEmit = blockNextEmit
        self.nextSnapshotRevision = nextSnapshotRevision
    }

    func snapshot(revision: SurfaceRevision) async -> FrameSnapshot {
        snapshotCount += 1
        if shouldBlockNextSnapshot {
            shouldBlockNextSnapshot = false
            await withCheckedContinuation { continuation in
                snapshotContinuation = continuation
            }
        }
        let capturedRevision = nextSnapshotRevision ?? revision
        nextSnapshotRevision = nil
        let pixel = UInt8(truncatingIfNeeded: capturedRevision.revision)
        return FrameSnapshot(
            surfaceID: capturedRevision.surfaceID,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            lifecycleGeneration: capturedRevision.lifecycleGeneration,
            revision: capturedRevision.revision,
            pixels: Data([pixel, pixel, pixel, 255]),
            ioSurfaceFrame: nil
        )
    }

    func resumeSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }

    func emit(_ published: PublishedDisplayFrame) async {
        let frame = published.snapshot
        emitCount += 1
        if shouldBlockNextEmit {
            shouldBlockNextEmit = false
            await withCheckedContinuation { continuation in
                emitContinuation = continuation
            }
        }
        emittedRevisions.append(frame.surfaceRevision)
        emittedFullDamage.append(frame.publicationDamage.isFullFrame)
        emittedSourceTimings.append(published.sourceTiming)
    }

    func resumeEmit() {
        emitContinuation?.resume()
        emitContinuation = nil
    }
}
