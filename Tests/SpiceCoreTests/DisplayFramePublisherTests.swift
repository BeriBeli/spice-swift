import Foundation
import SpiceIOSurface
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

    @Test func blockedSnapshotDoesNotPreventIndependentSurfacePreparation() async {
        let gate = FramePublisherSnapshotGate()
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 2,
            snapshot: { revision in
                await gate.snapshot(revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        let first = surfaceRevision(surfaceID: 1, revision: 1)
        let second = surfaceRevision(surfaceID: 2, revision: 1)
        await publisher.submit(first)
        await publisher.submit(second)

        let flush = Task { await publisher.flushNow() }
        await gate.waitUntilStarted(count: 2)

        #expect(Set(await gate.startedRevisions) == Set([first, second]))
        #expect(await gate.activeCount == 2)
        #expect(await gate.peakActiveCount == 2)
        await gate.succeed(surfaceID: 2)
        #expect(await observations.emittedRevisions.isEmpty)
        await gate.succeed(surfaceID: 1)
        await flush.value

        #expect(await gate.activeCount == 0)
        #expect(await observations.emittedRevisions == [first, second])
    }

    @Test func defaultSnapshotWidthIsExactAndRefillsOneSlotPerCompletion() async {
        let gate = FramePublisherSnapshotGate()
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            snapshot: { revision in
                await gate.snapshot(revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        let revisions = (1...5).map {
            surfaceRevision(surfaceID: UInt32($0), revision: 1)
        }
        for revision in revisions {
            await publisher.submit(revision)
        }

        let flush = Task { await publisher.flushNow() }
        await gate.waitUntilStarted(count: 2)
        #expect(Set(await gate.startedRevisions) == Set(revisions.prefix(2)))
        #expect(await gate.activeCount == 2)
        #expect(await gate.peakActiveCount == 2)

        await gate.succeed(surfaceID: 2)
        await gate.waitUntilStarted(count: 3)
        #expect(Set(await gate.startedRevisions) == Set(revisions.prefix(3)))
        #expect(await gate.activeCount == 2)

        await gate.succeed(surfaceID: 3)
        await gate.waitUntilStarted(count: 4)
        #expect(Set(await gate.startedRevisions) == Set(revisions.prefix(4)))
        #expect(await gate.activeCount == 2)

        await gate.succeed(surfaceID: 4)
        await gate.waitUntilStarted(count: 5)
        #expect(Set(await gate.startedRevisions) == Set(revisions))
        #expect(await gate.activeCount == 2)
        #expect(await gate.peakActiveCount == 2)

        await gate.succeed(surfaceID: 5)
        await gate.succeed(surfaceID: 1)
        await flush.value

        #expect(await gate.activeCount == 0)
        #expect(await gate.peakActiveCount == 2)
        #expect(await observations.emittedRevisions == revisions)
    }

    @Test func unavailableSnapshotReleasesItsPermitAndPreservesSuccessfulOrder() async {
        let gate = FramePublisherSnapshotGate()
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 2,
            snapshot: { revision in
                await gate.snapshot(revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        let revisions = (1...4).map {
            surfaceRevision(surfaceID: UInt32($0), revision: 1)
        }
        for revision in revisions {
            await publisher.submit(revision)
        }

        let flush = Task { await publisher.flushNow() }
        await gate.waitUntilStarted(count: 2)
        await gate.fail(surfaceID: 1)
        await gate.waitUntilStarted(count: 3)
        #expect(await gate.activeCount == 2)
        await gate.succeed(surfaceID: 3)
        await gate.waitUntilStarted(count: 4)
        #expect(await gate.activeCount == 2)
        await gate.succeed(surfaceID: 4)
        await gate.succeed(surfaceID: 2)
        await flush.value

        #expect(await gate.activeCount == 0)
        #expect(await gate.peakActiveCount == 2)
        #expect(await observations.emittedRevisions == Array(revisions.dropFirst()))
        let metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 4)
        #expect(metrics.staleSnapshots == 1)
        #expect(metrics.emittedFrames == 3)
    }

    @Test func concurrentSurfaceStoreSnapshotsPreserveDamageAndPublicationOrder() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        for surfaceID: UInt32 in [1, 2] {
            try await store.create(id: surfaceID, width: 8, height: 1, format: 32)
            let created = try await store.descriptor(surfaceID: surfaceID).surfaceRevision
            let initial = try #require(await store.publicationSnapshot(atLeast: created))
            initial.commitPublicationDamage()
        }
        let firstDamage = PixelRect(x: 0, y: 0, width: 1, height: 1)
        let secondDamage = PixelRect(x: 2, y: 0, width: 2, height: 1)
        let first = try await store.fill(
            surfaceID: 1,
            rectangle: firstDamage,
            colorARGB: 0x0011_2233
        )
        let second = try await store.fill(
            surfaceID: 2,
            rectangle: secondDamage,
            colorARGB: 0x0044_5566
        )
        let gate = SurfacePublicationStartGate(blockedSurfaceID: 1)
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 2,
            snapshot: { revision in
                await gate.begin(revision)
                let frame = await store.publicationSnapshot(atLeast: revision)
                await gate.finish(surfaceID: revision.surfaceID)
                return frame
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        await publisher.submit(first)
        await publisher.submit(second)

        let flush = Task { await publisher.flushNow() }
        await gate.waitUntilStarted(count: 2)
        await gate.waitUntilFinished(surfaceID: 2)
        #expect(await observations.emittedRevisions.isEmpty)
        await gate.releaseBlockedSnapshot()
        await flush.value

        #expect(await observations.emittedRevisions == [first, second])
        #expect(await observations.emittedDamageRectangles == [
            [firstDamage],
            [secondDamage],
        ])
        let firstDuplicate = try #require(await store.publicationSnapshot(atLeast: first))
        let secondDuplicate = try #require(await store.publicationSnapshot(atLeast: second))
        #expect(firstDuplicate.publicationDamage.isEmpty)
        #expect(secondDuplicate.publicationDamage.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringOrderedEmitRestoresEveryUncommittedPublicationDamage() async throws {
        let framePool = IOSurfaceFramePool(limits: .init(maximumFrames: 4))
        let store = SurfaceStore(framePool: framePool, backingPolicy: .dataOnly)
        for surfaceID: UInt32 in [1, 2] {
            try await store.create(id: surfaceID, width: 16, height: 1, format: 32)
            let created = try await store.descriptor(surfaceID: surfaceID).surfaceRevision
            let initial = try #require(await store.publicationSnapshot(atLeast: created))
            initial.commitPublicationDamage()
        }
        let firstDamage = PixelRect(x: 1, y: 0, width: 2, height: 1)
        let secondOriginalDamage = PixelRect(x: 4, y: 0, width: 2, height: 1)
        let secondConcurrentDamage = PixelRect(x: 10, y: 0, width: 1, height: 1)
        let first = try await store.fill(
            surfaceID: 1,
            rectangle: firstDamage,
            colorARGB: 0x0011_2233
        )
        let second = try await store.fill(
            surfaceID: 2,
            rectangle: secondOriginalDamage,
            colorARGB: 0x0044_5566
        )
        let snapshotProbe = CompletedPublicationSnapshotProbe(store: store)
        let emitGate = OrderedEmitCancellationGate()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 2,
            snapshot: { revision in
                await snapshotProbe.snapshot(atLeast: revision)
            },
            emit: { frame in
                await emitGate.emit(frame)
            }
        )
        await publisher.submit(first)
        await publisher.submit(second)

        let flush = Task { await publisher.flushNow() }
        await snapshotProbe.waitUntilCompleted(count: 2)
        await emitGate.waitUntilFirstEmitEntered()
        #expect(Set(await snapshotProbe.completedRevisions) == Set([first, second]))

        let secondLatest = try await store.fill(
            surfaceID: 2,
            rectangle: secondConcurrentDamage,
            colorARGB: 0x0077_8899
        )
        // Cancellation must restore prepared damage without waiting for the
        // already-entered emitter hook to return.
        await publisher.cancel()
        #expect(await emitGate.attemptedRevisions == [first])
        #expect(await emitGate.deliveredRevisions.isEmpty)
        await emitGate.releaseFirstEmit(deliver: false)
        await flush.value

        #expect(await emitGate.attemptedRevisions == [first])
        #expect(await emitGate.deliveredRevisions.isEmpty)
        #expect(await publisher.metrics().emittedFrames == 0)

        let replacementObservations = FramePublisherObservations()
        let replacement = makeSurfaceStorePublisher(
            store: store,
            observations: replacementObservations
        )
        await replacement.submit(secondLatest)
        await replacement.flushNow()
        #expect(await replacementObservations.emittedRevisions == [secondLatest])
        #expect(await replacementObservations.emittedFullDamage == [false])
        let restoredSecondDamage = try #require(
            await replacementObservations.emittedDamageRectangles.first
        )
        #expect(restoredSecondDamage.sorted { $0.x < $1.x } == [
            secondOriginalDamage,
            secondConcurrentDamage,
        ])

        let firstRestored = try #require(await store.publicationSnapshot(atLeast: first))
        #expect(firstRestored.publicationDamage.copyRectangles == [firstDamage])
        firstRestored.commitPublicationDamage()
        let firstDuplicate = try #require(await store.publicationSnapshot(atLeast: first))
        let secondDuplicate = try #require(await store.publicationSnapshot(atLeast: secondLatest))
        #expect(firstDuplicate.publicationDamage.isEmpty)
        #expect(secondDuplicate.publicationDamage.isEmpty)
        let reservations = await store.surfaceOperationReservationDiagnostics()
        #expect(reservations.activeSurfaceCount == 0)
        #expect(reservations.waitingCount == 0)
        #expect(reservations.grantedWaiterCount == 0)
        #expect(reservations.reservedCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationRemovesRegisteredSurfaceReservationWithoutConsumingDamage() async throws {
        let waiterProbe = SurfaceOperationWaiterProbe()
        let fixture = try await makeDamagedSurfaceStore(
            waiterWillRegister: { surfaceID, reservationID in
                await waiterProbe.record(surfaceID: surfaceID, reservationID: reservationID)
            }
        )
        let blocker = HeldSurfaceOperationGate()
        let holder = Task {
            try await fixture.store.withSurfaceOperationForTesting(surfaceID: 1) {
                await blocker.hold()
            }
        }
        await blocker.waitUntilHeld()
        let observations = FramePublisherObservations()
        let publisher = makeSurfaceStorePublisher(
            store: fixture.store,
            observations: observations
        )
        await publisher.submit(fixture.revision)
        let baseline = await fixture.store.metrics()

        let flush = Task { await publisher.flushNow() }
        await waiterProbe.waitUntilRegistrationCount(1)
        #expect(await fixture.store.surfaceOperationReservationDiagnostics().waitingCount == 1)
        await publisher.cancel()
        await flush.value

        let cancelled = await fixture.store.surfaceOperationReservationDiagnostics()
        #expect(cancelled.activeSurfaceCount == 1)
        #expect(cancelled.waitingCount == 0)
        #expect(cancelled.grantedWaiterCount == 0)
        #expect(cancelled.reservedCount == 0)
        #expect(await observations.emittedRevisions.isEmpty)
        let afterCancellation = await fixture.store.metrics()
        #expect(afterCancellation.snapshots == baseline.snapshots)
        #expect(afterCancellation.cpuMaterializations == baseline.cpuMaterializations)
        #expect(afterCancellation.cpuMaterializationBytes == baseline.cpuMaterializationBytes)

        await blocker.release()
        try await holder.value
        let released = await fixture.store.surfaceOperationReservationDiagnostics()
        #expect(released.activeSurfaceCount == 0)
        #expect(released.waitingCount == 0)
        #expect(released.grantedWaiterCount == 0)
        #expect(released.reservedCount == 0)
        let publication = try #require(
            await fixture.store.publicationSnapshot(atLeast: fixture.revision)
        )
        #expect(publication.publicationDamage.copyRectangles == [fixture.damage])
        let duplicate = try #require(
            await fixture.store.publicationSnapshot(atLeast: fixture.revision)
        )
        #expect(duplicate.publicationDamage.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationBeforeSurfaceReservationRegistrationLeavesNoWaiter() async throws {
        let registrationGate = CancellableSurfaceReservationPhaseGate()
        let fixture = try await makeDamagedSurfaceStore(
            waiterWillRegister: { surfaceID, reservationID in
                await registrationGate.blockUntilCancelled(
                    surfaceID: surfaceID,
                    reservationID: reservationID
                )
            }
        )
        let blocker = HeldSurfaceOperationGate()
        let holder = Task {
            try await fixture.store.withSurfaceOperationForTesting(surfaceID: 1) {
                await blocker.hold()
            }
        }
        await blocker.waitUntilHeld()
        let observations = FramePublisherObservations()
        let publisher = makeSurfaceStorePublisher(
            store: fixture.store,
            observations: observations
        )
        await publisher.submit(fixture.revision)
        let baseline = await fixture.store.metrics()

        let flush = Task { await publisher.flushNow() }
        await registrationGate.waitUntilEntered()
        await publisher.cancel()
        await flush.value

        #expect(await registrationGate.observedCancellation)
        let cancelled = await fixture.store.surfaceOperationReservationDiagnostics()
        #expect(cancelled.activeSurfaceCount == 1)
        #expect(cancelled.waitingCount == 0)
        #expect(cancelled.grantedWaiterCount == 0)
        #expect(cancelled.reservedCount == 0)
        #expect(await fixture.store.metrics().snapshots == baseline.snapshots)
        #expect(await observations.emittedRevisions.isEmpty)

        await blocker.release()
        try await holder.value
        let publication = try #require(
            await fixture.store.publicationSnapshot(atLeast: fixture.revision)
        )
        #expect(publication.publicationDamage.copyRectangles == [fixture.damage])
    }

    @Test(.timeLimit(.minutes(1)))
    func grantRacingCancellationAdvancesTheNextSurfaceReservationExactlyOnce() async throws {
        let waiterProbe = SurfaceOperationWaiterProbe()
        let grantGate = FirstGrantedSurfaceReservationGate()
        let fixture = try await makeDamagedSurfaceStore(
            waiterWillRegister: { surfaceID, reservationID in
                await waiterProbe.record(surfaceID: surfaceID, reservationID: reservationID)
            },
            grantWillBeClaimed: { surfaceID, reservationID in
                await grantGate.blockFirstGrantUntilCancelled(
                    surfaceID: surfaceID,
                    reservationID: reservationID
                )
            }
        )
        let blocker = HeldSurfaceOperationGate()
        let holder = Task {
            try await fixture.store.withSurfaceOperationForTesting(surfaceID: 1) {
                await blocker.hold()
            }
        }
        await blocker.waitUntilHeld()
        let observations = FramePublisherObservations()
        let publisher = makeSurfaceStorePublisher(
            store: fixture.store,
            observations: observations
        )
        await publisher.submit(fixture.revision)

        let flush = Task { await publisher.flushNow() }
        await waiterProbe.waitUntilRegistrationCount(1)
        await blocker.release()
        await grantGate.waitUntilFirstGrant()

        let nextPublication = Task {
            await fixture.store.publicationSnapshot(atLeast: fixture.revision)
        }
        await waiterProbe.waitUntilRegistrationCount(2)
        await publisher.cancel()
        await flush.value
        try await holder.value

        #expect(await grantGate.firstGrantObservedCancellation)
        #expect(await observations.emittedRevisions.isEmpty)
        let publication = try #require(await nextPublication.value)
        #expect(publication.publicationDamage.copyRectangles == [fixture.damage])
        let drained = await fixture.store.surfaceOperationReservationDiagnostics()
        #expect(drained.activeSurfaceCount == 0)
        #expect(drained.waitingCount == 0)
        #expect(drained.grantedWaiterCount == 0)
        #expect(drained.reservedCount == 0)
        let duplicate = try #require(
            await fixture.store.publicationSnapshot(atLeast: fixture.revision)
        )
        #expect(duplicate.publicationDamage.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func waiterRegistersAfterCancelledGrantFreedSurfaceClaimsItAtomically() async throws {
        let registrationGate = SecondSurfaceReservationRegistrationGate()
        let grantGate = FirstGrantedSurfaceReservationGate()
        let fixture = try await makeDamagedSurfaceStore(
            waiterWillRegister: { surfaceID, reservationID in
                await registrationGate.pauseSecondRegistration(
                    surfaceID: surfaceID,
                    reservationID: reservationID
                )
            },
            grantWillBeClaimed: { surfaceID, reservationID in
                await grantGate.blockFirstGrantUntilCancelled(
                    surfaceID: surfaceID,
                    reservationID: reservationID
                )
            }
        )
        let blocker = HeldSurfaceOperationGate()
        let holder = Task {
            try await fixture.store.withSurfaceOperationForTesting(surfaceID: 1) {
                await blocker.hold()
            }
        }
        await blocker.waitUntilHeld()
        let observations = FramePublisherObservations()
        let publisher = makeSurfaceStorePublisher(
            store: fixture.store,
            observations: observations
        )
        await publisher.submit(fixture.revision)

        let flush = Task { await publisher.flushNow() }
        await registrationGate.waitUntilRegistrationCount(1)
        await blocker.release()
        await grantGate.waitUntilFirstGrant()
        try await holder.value

        let nextPublication = Task {
            await fixture.store.publicationSnapshot(atLeast: fixture.revision)
        }
        await registrationGate.waitUntilSecondRegistrationPaused()
        await publisher.cancel()
        await flush.value

        #expect(await grantGate.firstGrantObservedCancellation)
        #expect(await observations.emittedRevisions.isEmpty)
        let free = await fixture.store.surfaceOperationReservationDiagnostics()
        #expect(free.activeSurfaceCount == 0)
        #expect(free.waitingCount == 0)
        #expect(free.grantedWaiterCount == 0)
        #expect(free.reservedCount == 1)

        await registrationGate.releaseSecondRegistration()
        let publication = try #require(await nextPublication.value)
        #expect(publication.publicationDamage.copyRectangles == [fixture.damage])
        let drained = await fixture.store.surfaceOperationReservationDiagnostics()
        #expect(drained.activeSurfaceCount == 0)
        #expect(drained.waitingCount == 0)
        #expect(drained.grantedWaiterCount == 0)
        #expect(drained.reservedCount == 0)
        let duplicate = try #require(
            await fixture.store.publicationSnapshot(atLeast: fixture.revision)
        )
        #expect(duplicate.publicationDamage.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationDirectlyStopsAdmissionAndDrainsEveryStartedSnapshot() async {
        let gate = FramePublisherSnapshotGate()
        let observations = FramePublisherObservations()
        let publisher = DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 3,
            snapshot: { revision in
                await gate.snapshot(revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
        let revisions = (1...6).map {
            surfaceRevision(surfaceID: UInt32($0), revision: 1)
        }
        for revision in revisions {
            await publisher.submit(revision)
        }

        let flush = Task { await publisher.flushNow() }
        await gate.waitUntilStarted(count: 3)
        await publisher.cancel()

        // `cancel()` itself owns structured teardown. Capture its postcondition
        // before any fallback cleanup so the pre-fix implementation fails
        // deterministically instead of leaving the test process hung.
        let activeAfterPublisherCancellation = await gate.activeCount
        if activeAfterPublisherCancellation != 0 {
            flush.cancel()
        }
        await flush.value

        #expect(activeAfterPublisherCancellation == 0)
        #expect(Set(await gate.startedRevisions) == Set(revisions.prefix(3)))
        #expect(await gate.cancelledSurfaceIDs.sorted() == [1, 2, 3])
        #expect(await gate.activeCount == 0)
        #expect(await gate.peakActiveCount == 3)
        #expect(await observations.emittedRevisions.isEmpty)

        await publisher.submit(surfaceRevision(surfaceID: 7, revision: 1))
        await publisher.flushNow()
        #expect(Set(await gate.startedRevisions) == Set(revisions.prefix(3)))
        #expect(await observations.emittedRevisions.isEmpty)
        let metrics = await publisher.metrics()
        #expect(metrics.pendingSurfaces == 0)
        #expect(metrics.emittedFrames == 0)
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
        let originalTiming = DisplayFrameSourceTiming(
            messageReceivedAt: clock.now.advanced(by: .milliseconds(-10)),
            surfaceReadyAt: clock.now.advanced(by: .milliseconds(-5))
        )
        let observations = FramePublisherObservations()
        let publisher = makePublisher(observations: observations)

        await publisher.submit(original, sourceTiming: originalTiming)
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [original])
        #expect(await observations.emittedSourceTimings == [originalTiming])
    }

    @Test func surfaceStorePublicationWaitsUntilNewerRevisionIsSubmitted() async throws {
        let framePool = IOSurfaceFramePool(limits: .init(maximumFrames: 2))
        let store = SurfaceStore(framePool: framePool, backingPolicy: .dataOnly)
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

    @Test(.timeLimit(.minutes(1)))
    func cancellationDuringSnapshotClearsPendingWork() async {
        let observations = FramePublisherObservations(blockNextSnapshot: true)
        let publisher = makePublisher(observations: observations)
        await publisher.submit(surfaceRevision(surfaceID: 1, revision: 1))

        let flush = Task { await publisher.flushNow() }
        await waitForSnapshotStart(observations)
        await publisher.cancel()
        await flush.value

        #expect(await observations.snapshotCancellationCount == 1)
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

    private func makeSurfaceStorePublisher(
        store: SurfaceStore,
        observations: FramePublisherObservations
    ) -> DisplayFramePublisher {
        DisplayFramePublisher(
            interval: .seconds(10),
            maximumConcurrentSnapshots: 1,
            snapshot: { revision in
                await store.publicationSnapshot(atLeast: revision)
            },
            emit: { frame in
                await observations.emit(frame)
            }
        )
    }

    private func makeDamagedSurfaceStore(
        waiterWillRegister: SurfaceOperationWaiterObserver? = nil,
        grantWillBeClaimed: SurfaceOperationWaiterObserver? = nil
    ) async throws -> (store: SurfaceStore, revision: SurfaceRevision, damage: PixelRect) {
        let store = SurfaceStore(
            backingPolicy: .dataOnly,
            surfaceOperationWaiterWillRegister: waiterWillRegister,
            surfaceOperationGrantWillBeClaimed: grantWillBeClaimed
        )
        try await store.create(id: 1, width: 8, height: 1, format: 32)
        let created = try await store.descriptor(surfaceID: 1).surfaceRevision
        let initial = try #require(await store.publicationSnapshot(atLeast: created))
        initial.commitPublicationDamage()
        let damage = PixelRect(x: 2, y: 0, width: 2, height: 1)
        let revision = try await store.fill(
            surfaceID: 1,
            rectangle: damage,
            colorARGB: 0x0011_2233
        )
        return (store, revision, damage)
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
    private var snapshotCancellationPending = false
    private var emitContinuation: CheckedContinuation<Void, Never>?
    private(set) var snapshotCount = 0
    private(set) var snapshotCancellationCount = 0
    private(set) var emitCount = 0
    private(set) var emittedRevisions: [SurfaceRevision] = []
    private(set) var emittedFullDamage: [Bool] = []
    private(set) var emittedDamageRectangles: [[PixelRect]] = []
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
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if snapshotCancellationPending {
                        snapshotCancellationPending = false
                        continuation.resume()
                    } else {
                        snapshotContinuation = continuation
                    }
                }
            } onCancel: {
                Task { await self.cancelBlockedSnapshot() }
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

    private func cancelBlockedSnapshot() {
        snapshotCancellationCount += 1
        if let snapshotContinuation {
            self.snapshotContinuation = nil
            snapshotContinuation.resume()
        } else {
            snapshotCancellationPending = true
        }
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
        emittedDamageRectangles.append(frame.publicationDamage.copyRectangles)
        emittedSourceTimings.append(published.sourceTiming)
    }

    func resumeEmit() {
        emitContinuation?.resume()
        emitContinuation = nil
    }
}

private actor SurfacePublicationStartGate {
    private let blockedSurfaceID: UInt32
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var startedSurfaceIDs: Set<UInt32> = []
    private var finishedSurfaceIDs: Set<UInt32> = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(UInt32, CheckedContinuation<Void, Never>)] = []

    init(blockedSurfaceID: UInt32) {
        self.blockedSurfaceID = blockedSurfaceID
    }

    func begin(_ revision: SurfaceRevision) async {
        startedSurfaceIDs.insert(revision.surfaceID)
        let ready = startWaiters.filter { startedSurfaceIDs.count >= $0.0 }
        startWaiters.removeAll { startedSurfaceIDs.count >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
        if revision.surfaceID == blockedSurfaceID {
            await withCheckedContinuation { blockedContinuation = $0 }
        }
    }

    func finish(surfaceID: UInt32) {
        finishedSurfaceIDs.insert(surfaceID)
        let ready = finishWaiters.filter { finishedSurfaceIDs.contains($0.0) }
        finishWaiters.removeAll { finishedSurfaceIDs.contains($0.0) }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    func waitUntilStarted(count: Int) async {
        guard startedSurfaceIDs.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func waitUntilFinished(surfaceID: UInt32) async {
        guard !finishedSurfaceIDs.contains(surfaceID) else { return }
        await withCheckedContinuation { finishWaiters.append((surfaceID, $0)) }
    }

    func releaseBlockedSnapshot() {
        blockedContinuation?.resume()
        blockedContinuation = nil
    }
}

private actor CompletedPublicationSnapshotProbe {
    private let store: SurfaceStore
    private var completionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var completedRevisions: [SurfaceRevision] = []

    init(store: SurfaceStore) {
        self.store = store
    }

    func snapshot(atLeast revision: SurfaceRevision) async -> FrameSnapshot? {
        let frame = await store.publicationSnapshot(atLeast: revision)
        if let frame {
            completedRevisions.append(frame.surfaceRevision)
            let ready = completionWaiters.filter { completedRevisions.count >= $0.0 }
            completionWaiters.removeAll { completedRevisions.count >= $0.0 }
            for (_, continuation) in ready {
                continuation.resume()
            }
        }
        return frame
    }

    func waitUntilCompleted(count: Int) async {
        guard completedRevisions.count < count else { return }
        await withCheckedContinuation { completionWaiters.append((count, $0)) }
    }
}

private actor OrderedEmitCancellationGate {
    private var firstEmitEntered = false
    private var firstEmitWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstEmitContinuation: CheckedContinuation<Bool, Never>?
    private(set) var attemptedRevisions: [SurfaceRevision] = []
    private(set) var deliveredRevisions: [SurfaceRevision] = []

    func emit(_ published: PublishedDisplayFrame) async {
        let frame = published.snapshot
        attemptedRevisions.append(frame.surfaceRevision)
        let shouldDeliver: Bool
        if attemptedRevisions.count == 1 {
            firstEmitEntered = true
            let waiters = firstEmitWaiters
            firstEmitWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters {
                waiter.resume()
            }
            shouldDeliver = await withCheckedContinuation {
                firstEmitContinuation = $0
            }
        } else {
            shouldDeliver = true
        }
        if shouldDeliver {
            deliveredRevisions.append(frame.surfaceRevision)
        }
    }

    func waitUntilFirstEmitEntered() async {
        guard !firstEmitEntered else { return }
        await withCheckedContinuation { firstEmitWaiters.append($0) }
    }

    func releaseFirstEmit(deliver: Bool) {
        firstEmitContinuation?.resume(returning: deliver)
        firstEmitContinuation = nil
    }
}

private actor HeldSurfaceOperationGate {
    private var isHeld = false
    private var holdWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func hold() async {
        isHeld = true
        let waiters = holdWaiters
        holdWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilHeld() async {
        guard !isHeld else { return }
        await withCheckedContinuation { holdWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor SurfaceOperationWaiterProbe {
    private var registrations: [(surfaceID: UInt32, reservationID: UInt64)] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func record(surfaceID: UInt32, reservationID: UInt64) {
        registrations.append((surfaceID, reservationID))
        let ready = waiters.filter { registrations.count >= $0.0 }
        waiters.removeAll { registrations.count >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }

    func waitUntilRegistrationCount(_ count: Int) async {
        guard registrations.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private actor SecondSurfaceReservationRegistrationGate {
    private var registrationCount = 0
    private var countWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var secondRegistrationPaused = false
    private var secondPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var secondReleaseContinuation: CheckedContinuation<Void, Never>?

    func pauseSecondRegistration(
        surfaceID _: UInt32,
        reservationID _: UInt64
    ) async {
        registrationCount += 1
        let countReady = countWaiters.filter { registrationCount >= $0.0 }
        countWaiters.removeAll { registrationCount >= $0.0 }
        for (_, continuation) in countReady {
            continuation.resume()
        }
        guard registrationCount == 2 else { return }

        secondRegistrationPaused = true
        let pauseWaiters = secondPauseWaiters
        secondPauseWaiters.removeAll(keepingCapacity: false)
        for waiter in pauseWaiters {
            waiter.resume()
        }
        await withCheckedContinuation { secondReleaseContinuation = $0 }
    }

    func waitUntilRegistrationCount(_ count: Int) async {
        guard registrationCount < count else { return }
        await withCheckedContinuation { countWaiters.append((count, $0)) }
    }

    func waitUntilSecondRegistrationPaused() async {
        guard !secondRegistrationPaused else { return }
        await withCheckedContinuation { secondPauseWaiters.append($0) }
    }

    func releaseSecondRegistration() {
        secondReleaseContinuation?.resume()
        secondReleaseContinuation = nil
    }
}

private actor CancellableSurfaceReservationPhaseGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var cancellationArrivedEarly = false
    private(set) var observedCancellation = false

    func blockUntilCancelled(surfaceID _: UInt32, reservationID _: UInt64) async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancellationArrivedEarly {
                    cancellationArrivedEarly = false
                    continuation.resume()
                } else {
                    blockedContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    private func observeCancellation() {
        observedCancellation = true
        if let blockedContinuation {
            self.blockedContinuation = nil
            blockedContinuation.resume()
        } else {
            cancellationArrivedEarly = true
        }
    }
}

private actor FirstGrantedSurfaceReservationGate {
    private var didBlockFirstGrant = false
    private var firstGrantWaiters: [CheckedContinuation<Void, Never>] = []
    private var blockedContinuation: CheckedContinuation<Void, Never>?
    private var cancellationArrivedEarly = false
    private(set) var firstGrantObservedCancellation = false

    func blockFirstGrantUntilCancelled(
        surfaceID _: UInt32,
        reservationID _: UInt64
    ) async {
        guard !didBlockFirstGrant else { return }
        didBlockFirstGrant = true
        let waiters = firstGrantWaiters
        firstGrantWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if cancellationArrivedEarly {
                    cancellationArrivedEarly = false
                    continuation.resume()
                } else {
                    blockedContinuation = continuation
                }
            }
        } onCancel: {
            Task { await self.observeCancellation() }
        }
    }

    func waitUntilFirstGrant() async {
        guard didBlockFirstGrant else {
            await withCheckedContinuation { firstGrantWaiters.append($0) }
            return
        }
    }

    private func observeCancellation() {
        firstGrantObservedCancellation = true
        if let blockedContinuation {
            self.blockedContinuation = nil
            blockedContinuation.resume()
        } else {
            cancellationArrivedEarly = true
        }
    }
}

private actor FramePublisherSnapshotGate {
    private enum Outcome: Sendable {
        case frame(FrameSnapshot)
        case unavailable
    }

    private var activeSurfaceIDs: Set<UInt32> = []
    private var continuations: [UInt32: CheckedContinuation<Outcome, Never>] = [:]
    private var earlyOutcomes: [UInt32: Outcome] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var activeCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var requestedRevisions: [UInt32: SurfaceRevision] = [:]
    private(set) var startedRevisions: [SurfaceRevision] = []
    private(set) var cancelledSurfaceIDs: [UInt32] = []
    private(set) var peakActiveCount = 0

    var activeCount: Int { activeSurfaceIDs.count }

    func snapshot(_ revision: SurfaceRevision) async -> FrameSnapshot? {
        let surfaceID = revision.surfaceID
        requestedRevisions[surfaceID] = revision
        activeSurfaceIDs.insert(surfaceID)
        startedRevisions.append(revision)
        peakActiveCount = max(peakActiveCount, activeSurfaceIDs.count)
        let ready = startWaiters.filter { startedRevisions.count >= $0.0 }
        startWaiters.removeAll { startedRevisions.count >= $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
        resumeActiveCountWaiters()

        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let early = earlyOutcomes.removeValue(forKey: surfaceID) {
                    continuation.resume(returning: early)
                } else {
                    continuations[surfaceID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(surfaceID: surfaceID) }
        }
        switch outcome {
        case let .frame(frame):
            return frame
        case .unavailable:
            return nil
        }
    }

    func waitUntilStarted(count: Int) async {
        guard startedRevisions.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func waitUntilActiveCount(_ count: Int) async {
        guard activeSurfaceIDs.count != count else { return }
        await withCheckedContinuation { activeCountWaiters.append((count, $0)) }
    }

    func succeed(surfaceID: UInt32) {
        guard let revision = requestedRevisions[surfaceID] else { return }
        let pixel = UInt8(truncatingIfNeeded: revision.revision)
        finish(
            surfaceID: surfaceID,
            outcome: .frame(FrameSnapshot(
                surfaceID: revision.surfaceID,
                width: 1,
                height: 1,
                bytesPerRow: 4,
                lifecycleGeneration: revision.lifecycleGeneration,
                revision: revision.revision,
                pixels: Data([pixel, pixel, pixel, 255]),
                ioSurfaceFrame: nil
            ))
        )
    }

    func fail(surfaceID: UInt32) {
        finish(surfaceID: surfaceID, outcome: .unavailable)
    }

    private func cancel(surfaceID: UInt32) {
        guard activeSurfaceIDs.contains(surfaceID) else { return }
        cancelledSurfaceIDs.append(surfaceID)
        finish(surfaceID: surfaceID, outcome: .unavailable)
    }

    private func finish(surfaceID: UInt32, outcome: Outcome) {
        guard activeSurfaceIDs.remove(surfaceID) != nil else { return }
        requestedRevisions.removeValue(forKey: surfaceID)
        if let continuation = continuations.removeValue(forKey: surfaceID) {
            continuation.resume(returning: outcome)
        } else {
            earlyOutcomes[surfaceID] = outcome
        }
        resumeActiveCountWaiters()
    }

    private func resumeActiveCountWaiters() {
        let ready = activeCountWaiters.filter { activeSurfaceIDs.count == $0.0 }
        activeCountWaiters.removeAll { activeSurfaceIDs.count == $0.0 }
        for (_, continuation) in ready {
            continuation.resume()
        }
    }
}
