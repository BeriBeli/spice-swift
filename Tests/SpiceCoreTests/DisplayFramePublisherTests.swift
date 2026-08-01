import Foundation
import Testing
@testable import SpiceChannels
@testable import SpiceRenderer

@Suite("Display frame publisher")
struct DisplayFramePublisherTests {
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

    @Test func updateDuringSnapshotRequeuesOnlyLatestRevision() async {
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
        await publisher.flushNow()

        #expect(await observations.emittedRevisions == [latest])
        let metrics = await publisher.metrics()
        #expect(metrics.snapshotAttempts == 2)
        #expect(metrics.staleSnapshots == 1)
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
}

private actor FramePublisherObservations {
    private var shouldBlockNextSnapshot: Bool
    private var snapshotContinuation: CheckedContinuation<Void, Never>?
    private(set) var snapshotCount = 0
    private(set) var emittedRevisions: [SurfaceRevision] = []

    init(blockNextSnapshot: Bool = false) {
        shouldBlockNextSnapshot = blockNextSnapshot
    }

    func snapshot(revision: SurfaceRevision) async -> FrameSnapshot {
        snapshotCount += 1
        if shouldBlockNextSnapshot {
            shouldBlockNextSnapshot = false
            await withCheckedContinuation { continuation in
                snapshotContinuation = continuation
            }
        }
        let pixel = UInt8(truncatingIfNeeded: revision.revision)
        return FrameSnapshot(
            surfaceID: revision.surfaceID,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            lifecycleGeneration: revision.lifecycleGeneration,
            revision: revision.revision,
            pixels: Data([pixel, pixel, pixel, 255]),
            ioSurfaceFrame: nil
        )
    }

    func resumeSnapshot() {
        snapshotContinuation?.resume()
        snapshotContinuation = nil
    }

    func emit(_ frame: FrameSnapshot) {
        emittedRevisions.append(frame.surfaceRevision)
    }
}
