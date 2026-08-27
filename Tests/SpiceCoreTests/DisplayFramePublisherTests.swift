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

    @Test(arguments: [
        SnapshotConcurrencyCase(
            expectedMaximumConcurrency: 2,
            configuredMaximumConcurrency: 2,
            surfaceCount: 3
        ),
        SnapshotConcurrencyCase(
            expectedMaximumConcurrency: 4,
            configuredMaximumConcurrency: 4,
            surfaceCount: 5
        ),
        SnapshotConcurrencyCase(
            expectedMaximumConcurrency: 3,
            configuredMaximumConcurrency: nil,
            surfaceCount: 5
        ),
    ])
    fileprivate func snapshotsUseBoundedConcurrencyAndEmitInSubmissionOrder(
        _ testCase: SnapshotConcurrencyCase
    ) async {
        let probe = ControlledSnapshotProbe()
        let observations = FramePublisherObservations()
        let publisher: DisplayFramePublisher
        if let configuredMaximumConcurrency = testCase.configuredMaximumConcurrency {
            publisher = DisplayFramePublisher(
                interval: .seconds(10),
                maximumPendingSurfaces: testCase.surfaceCount,
                maximumConcurrentSnapshots: configuredMaximumConcurrency,
                snapshot: { revision in
                    await probe.snapshot(revision: revision)
                },
                emit: { frame in
                    await observations.emit(frame)
                }
            )
        } else {
            publisher = DisplayFramePublisher(
                interval: .seconds(10),
                maximumPendingSurfaces: testCase.surfaceCount,
                snapshot: { revision in
                    await probe.snapshot(revision: revision)
                },
                emit: { frame in
                    await observations.emit(frame)
                }
            )
        }
        let revisions = (1...testCase.surfaceCount).map {
            surfaceRevision(surfaceID: UInt32($0), revision: 1)
        }
        for revision in revisions {
            await publisher.submit(revision)
        }

        let flush = Task { await publisher.flushNow() }
        await probe.waitUntilStarted(testCase.expectedMaximumConcurrency)
        var state = await probe.state()
        #expect(state.startedSurfaceIDs.count == testCase.expectedMaximumConcurrency)
        #expect(
            Set(state.startedSurfaceIDs)
                == Set(revisions.prefix(testCase.expectedMaximumConcurrency).map(\.surfaceID))
        )
        #expect(state.activeSurfaceIDs.count == testCase.expectedMaximumConcurrency)
        #expect(state.peakActiveCount == testCase.expectedMaximumConcurrency)

        let initiallyStarted = state.startedSurfaceIDs.sorted(by: >)
        for (finishedCount, surfaceID) in initiallyStarted.enumerated() {
            await probe.succeed(surfaceID: surfaceID)
            await probe.waitUntilFinished(finishedCount + 1)
        }

        await probe.waitUntilStarted(testCase.surfaceCount)
        state = await probe.state()
        #expect(state.startedSurfaceIDs.count == testCase.surfaceCount)
        #expect(state.peakActiveCount == testCase.expectedMaximumConcurrency)
        for surfaceID in state.activeSurfaceIDs.sorted(by: >) {
            let finishedCount = await probe.state().finishedSurfaceIDs.count
            await probe.succeed(surfaceID: surfaceID)
            await probe.waitUntilFinished(finishedCount + 1)
        }
        await flush.value

        state = await probe.state()
        #expect(state.activeSurfaceIDs.isEmpty)
        #expect(state.finishedSurfaceIDs.count == testCase.surfaceCount)
        #expect(state.peakActiveCount == testCase.expectedMaximumConcurrency)
        #expect(state.completionOrder != revisions.map(\.surfaceID))
        #expect(await observations.emittedRevisions == revisions)
    }

    @Test func removingSurfaceWhileSnapshotsAreConcurrentSuppressesItsLateFrame() async {
        let probe = ControlledSnapshotProbe()
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 2,
            snapshot: { revision in
                await probe.snapshot(revision: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        let removed = surfaceRevision(surfaceID: 1, revision: 1)
        let retained = surfaceRevision(surfaceID: 2, revision: 1)
        await publisher.submit(removed)
        await publisher.submit(retained)

        let flush = Task { await publisher.flushNow() }
        await probe.waitUntilStarted(2)
        await publisher.remove(surfaceID: removed.surfaceID)
        await probe.succeed(surfaceID: retained.surfaceID)
        await probe.waitUntilFinished(1)
        await probe.succeed(surfaceID: removed.surfaceID)
        await probe.waitUntilFinished(2)
        await flush.value

        #expect(await observations.emittedRevisions == [retained])
        #expect(await probe.state().activeSurfaceIDs.isEmpty)
        let metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 2)
        #expect(metrics.staleSnapshots == 1)
        #expect(metrics.emittedFrames == 1)
    }

    @Test func publisherCancellationDoesNotAdmitQueuedSnapshotOrPublishLateFrames() async {
        let probe = ControlledSnapshotProbe()
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 2,
            snapshot: { revision in
                await probe.snapshot(revision: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        for surfaceID in 1...3 {
            await publisher.submit(surfaceRevision(surfaceID: UInt32(surfaceID), revision: 1))
        }

        let flush = Task { await publisher.flushNow() }
        await probe.waitUntilStarted(2)
        await publisher.cancel()
        let releasedSurfaceID = try! #require(await probe.state().activeSurfaceIDs.min())
        await probe.succeed(surfaceID: releasedSurfaceID)
        await probe.waitUntilFinished(2)
        await flush.value

        let state = await probe.state()
        #expect(state.startedSurfaceIDs.count == 2)
        #expect(state.finishedSurfaceIDs.count == 2)
        #expect(state.activeSurfaceIDs.isEmpty)
        #expect(await observations.emittedRevisions.isEmpty)
        #expect(await publisher.metrics().pendingSurfaces == 0)
    }

    @Test func cancellingFlushTaskCancelsActiveSnapshotsAndDoesNotAdmitQueuedWork() async {
        let probe = ControlledSnapshotProbe()
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 2,
            snapshot: { revision in
                await probe.snapshot(revision: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        for surfaceID in 1...3 {
            await publisher.submit(surfaceRevision(surfaceID: UInt32(surfaceID), revision: 1))
        }

        let flush = Task { await publisher.flushNow() }
        await probe.waitUntilStarted(2)
        flush.cancel()
        await flush.value

        let state = await probe.state()
        #expect(state.startedSurfaceIDs.count == 2)
        #expect(state.finishedSurfaceIDs.count == 2)
        #expect(state.activeSurfaceIDs.isEmpty)
        #expect(await observations.emittedRevisions.isEmpty)
        #expect(await publisher.metrics().pendingSurfaces == 1)
    }

    @Test(arguments: [3, 4])
    func completedSnapshotsHoldAWindowUntilOrderedPrefixEmits(
        maximumConcurrency: Int
    ) async {
        let surfaceCount = maximumConcurrency * 2
        let snapshots = ControlledSnapshotProbe()
        let emissions = ControlledEmissionProbe()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumPendingSurfaces: surfaceCount,
            maximumConcurrentSnapshots: maximumConcurrency,
            snapshot: { revision in
                await snapshots.snapshot(revision: revision)
            },
            emit: { frame in
                await emissions.emit(frame)
            }
        )
        let revisions = (1...surfaceCount).map {
            surfaceRevision(surfaceID: UInt32($0), revision: 1)
        }
        for revision in revisions {
            await publisher.submit(revision)
        }

        let flush = Task { await publisher.flushNow() }
        await snapshots.waitUntilStarted(maximumConcurrency)
        for surfaceID in UInt32(2)...UInt32(maximumConcurrency) {
            let finishedCount = await snapshots.state().finishedSurfaceIDs.count
            await snapshots.succeed(surfaceID: surfaceID)
            await snapshots.waitUntilFinished(finishedCount + 1)
        }
        #expect(await emissions.revisions().isEmpty)

        await snapshots.succeed(surfaceID: 1)
        await snapshots.waitUntilFinished(maximumConcurrency)
        for expectedEmissionCount in 1...maximumConcurrency {
            await emissions.waitUntilEmitted(expectedEmissionCount)
            await snapshots.waitUntilStarted(
                maximumConcurrency + expectedEmissionCount - 1
            )
            let snapshotState = await snapshots.state()
            #expect(
                snapshotState.startedSurfaceIDs.count
                    == maximumConcurrency + expectedEmissionCount - 1
            )
            #expect(
                snapshotState.startedSurfaceIDs.count - (expectedEmissionCount - 1)
                    == maximumConcurrency
            )
            #expect(snapshotState.activeSurfaceIDs.count <= maximumConcurrency)
            #expect(
                await emissions.revisions()
                    == Array(revisions.prefix(expectedEmissionCount))
            )
            await emissions.release(surfaceID: UInt32(expectedEmissionCount))
        }

        await snapshots.waitUntilStarted(surfaceCount)
        var snapshotState = await snapshots.state()
        #expect(snapshotState.peakActiveCount == maximumConcurrency)
        #expect(snapshotState.startedSurfaceIDs.count == surfaceCount)
        for surfaceID in snapshotState.activeSurfaceIDs.sorted(by: >) {
            let finishedCount = await snapshots.state().finishedSurfaceIDs.count
            await snapshots.succeed(surfaceID: surfaceID)
            await snapshots.waitUntilFinished(finishedCount + 1)
        }
        for expectedEmissionCount in (maximumConcurrency + 1)...surfaceCount {
            await emissions.waitUntilEmitted(expectedEmissionCount)
            #expect(
                await emissions.revisions()
                    == Array(revisions.prefix(expectedEmissionCount))
            )
            await emissions.release(surfaceID: UInt32(expectedEmissionCount))
        }
        await flush.value

        snapshotState = await snapshots.state()
        #expect(snapshotState.activeSurfaceIDs.isEmpty)
        #expect(snapshotState.finishedSurfaceIDs.count == surfaceCount)
        #expect(snapshotState.peakActiveCount == maximumConcurrency)
        #expect(await emissions.revisions() == revisions)
    }

    @Test func cancellationDrainsBufferedAndActiveSnapshotWindowWithoutRefill() async {
        let snapshots = ControlledSnapshotProbe()
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 3,
            snapshot: { revision in
                await snapshots.snapshot(revision: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        for surfaceID in 1...6 {
            await publisher.submit(surfaceRevision(surfaceID: UInt32(surfaceID), revision: 1))
        }

        let flush = Task { await publisher.flushNow() }
        await snapshots.waitUntilStarted(3)
        await snapshots.succeed(surfaceID: 2)
        await snapshots.waitUntilFinished(1)
        await publisher.cancel()
        await snapshots.succeed(surfaceID: 1)
        await snapshots.waitUntilFinished(3)
        await flush.value

        let state = await snapshots.state()
        #expect(state.startedSurfaceIDs.count == 3)
        #expect(state.finishedSurfaceIDs.count == 3)
        #expect(state.activeSurfaceIDs.isEmpty)
        #expect(await observations.emittedRevisions.isEmpty)
        #expect(await publisher.metrics().pendingSurfaces == 0)
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

private struct SnapshotConcurrencyCase: Sendable {
    let expectedMaximumConcurrency: Int
    let configuredMaximumConcurrency: Int?
    let surfaceCount: Int
}

private actor ControlledSnapshotProbe {
    struct State: Sendable {
        let startedSurfaceIDs: [UInt32]
        let activeSurfaceIDs: Set<UInt32>
        let finishedSurfaceIDs: Set<UInt32>
        let completionOrder: [UInt32]
        let peakActiveCount: Int
    }

    private enum Resolution {
        case success
        case cancelled
    }

    private var startedSurfaceIDs: [UInt32] = []
    private var activeSurfaceIDs: Set<UInt32> = []
    private var finishedSurfaceIDs: Set<UInt32> = []
    private var completionOrder: [UInt32] = []
    private var peakActiveCount = 0
    private var continuations: [UInt32: CheckedContinuation<Resolution, Never>] = [:]
    private var earlyResolutions: [UInt32: Resolution] = [:]
    private var startedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func snapshot(revision: SurfaceRevision) async -> FrameSnapshot? {
        let surfaceID = revision.surfaceID
        startedSurfaceIDs.append(surfaceID)
        activeSurfaceIDs.insert(surfaceID)
        peakActiveCount = max(peakActiveCount, activeSurfaceIDs.count)
        resumeSatisfiedWaiters()

        let resolution = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let early = earlyResolutions.removeValue(forKey: surfaceID) {
                    continuation.resume(returning: early)
                } else {
                    continuations[surfaceID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(surfaceID: surfaceID) }
        }

        activeSurfaceIDs.remove(surfaceID)
        finishedSurfaceIDs.insert(surfaceID)
        completionOrder.append(surfaceID)
        resumeSatisfiedWaiters()
        guard case .success = resolution else { return nil }
        let pixel = UInt8(truncatingIfNeeded: revision.revision)
        return FrameSnapshot(
            surfaceID: surfaceID,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            lifecycleGeneration: revision.lifecycleGeneration,
            revision: revision.revision,
            pixels: Data([pixel, pixel, pixel, 255]),
            ioSurfaceFrame: nil
        )
    }

    func succeed(surfaceID: UInt32) {
        resolve(surfaceID: surfaceID, as: .success)
    }

    func waitUntilStarted(_ count: Int) async {
        guard startedSurfaceIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append((count, continuation))
        }
    }

    func waitUntilFinished(_ count: Int) async {
        guard finishedSurfaceIDs.count < count else { return }
        await withCheckedContinuation { continuation in
            finishedWaiters.append((count, continuation))
        }
    }

    func state() -> State {
        State(
            startedSurfaceIDs: startedSurfaceIDs,
            activeSurfaceIDs: activeSurfaceIDs,
            finishedSurfaceIDs: finishedSurfaceIDs,
            completionOrder: completionOrder,
            peakActiveCount: peakActiveCount
        )
    }

    private func cancel(surfaceID: UInt32) {
        resolve(surfaceID: surfaceID, as: .cancelled)
    }

    private func resolve(surfaceID: UInt32, as resolution: Resolution) {
        guard !finishedSurfaceIDs.contains(surfaceID) else { return }
        if let continuation = continuations.removeValue(forKey: surfaceID) {
            continuation.resume(returning: resolution)
        } else {
            earlyResolutions[surfaceID] = resolution
        }
    }

    private func resumeSatisfiedWaiters() {
        var remainingStarted: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in startedWaiters {
            if startedSurfaceIDs.count >= count {
                continuation.resume()
            } else {
                remainingStarted.append((count, continuation))
            }
        }
        startedWaiters = remainingStarted

        var remainingFinished: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in finishedWaiters {
            if finishedSurfaceIDs.count >= count {
                continuation.resume()
            } else {
                remainingFinished.append((count, continuation))
            }
        }
        finishedWaiters = remainingFinished
    }
}

private actor ControlledEmissionProbe {
    private var emittedRevisions: [SurfaceRevision] = []
    private var continuations: [UInt32: CheckedContinuation<Void, Never>] = [:]
    private var earlyReleases: Set<UInt32> = []
    private var emittedWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func emit(_ frame: FrameSnapshot) async {
        emittedRevisions.append(frame.surfaceRevision)
        resumeSatisfiedWaiters()
        await withCheckedContinuation { continuation in
            if earlyReleases.remove(frame.surfaceID) != nil {
                continuation.resume()
            } else {
                continuations[frame.surfaceID] = continuation
            }
        }
    }

    func release(surfaceID: UInt32) {
        if let continuation = continuations.removeValue(forKey: surfaceID) {
            continuation.resume()
        } else {
            earlyReleases.insert(surfaceID)
        }
    }

    func waitUntilEmitted(_ count: Int) async {
        guard emittedRevisions.count < count else { return }
        await withCheckedContinuation { continuation in
            emittedWaiters.append((count, continuation))
        }
    }

    func revisions() -> [SurfaceRevision] {
        emittedRevisions
    }

    private func resumeSatisfiedWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in emittedWaiters {
            if emittedRevisions.count >= count {
                continuation.resume()
            } else {
                remaining.append((count, continuation))
            }
        }
        emittedWaiters = remaining
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

    func emit(_ frame: FrameSnapshot) async {
        emitCount += 1
        if shouldBlockNextEmit {
            shouldBlockNextEmit = false
            await withCheckedContinuation { continuation in
                emitContinuation = continuation
            }
        }
        emittedRevisions.append(frame.surfaceRevision)
        emittedFullDamage.append(frame.publicationDamage.isFullFrame)
    }

    func resumeEmit() {
        emitContinuation?.resume()
        emitContinuation = nil
    }
}
