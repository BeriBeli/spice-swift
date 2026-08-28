import Testing
@testable import SpiceRenderer

@Suite("Surface publication damage")
struct SurfacePublicationDamageTests {
    @Test func publicationTransfersActualDamageAndClearsJournal() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 4, width: 16, height: 4, format: 32)
        let created = try await store.descriptor(surfaceID: 4).surfaceRevision
        let initial = try #require(await store.publicationSnapshot(atLeast: created))
        #expect(initial.publicationDamage.isFullFrame)

        _ = try await store.fill(
            surfaceID: 4,
            rectangle: PixelRect(x: 1, y: 1, width: 2, height: 1),
            colorARGB: 0x0011_2233
        )
        let latest = try await store.fill(
            surfaceID: 4,
            rectangle: PixelRect(x: 8, y: 2, width: 3, height: 1),
            colorARGB: 0x0044_5566
        )
        let publication = try #require(await store.publicationSnapshot(atLeast: latest))

        #expect(!publication.publicationDamage.isFullFrame)
        #expect(publication.publicationDamage.copyRectangles == [
            PixelRect(x: 1, y: 1, width: 2, height: 1),
            PixelRect(x: 8, y: 2, width: 3, height: 1),
        ])
    }

    @Test func historyGapBeyondRectangleBoundDegradesToFull() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 8, width: 200, height: 1, format: 32)
        let created = try await store.descriptor(surfaceID: 8).surfaceRevision
        _ = await store.publicationSnapshot(atLeast: created)

        var latest = created
        for x in 0..<65 {
            latest = try await store.fill(
                surfaceID: 8,
                rectangle: PixelRect(x: x * 2, y: 0, width: 1, height: 1),
                colorARGB: UInt32(x)
            )
        }
        let publication = try #require(await store.publicationSnapshot(atLeast: latest))
        #expect(publication.publicationDamage.isFullFrame)
        #expect(publication.publicationDamage.copyRectangles == [
            PixelRect(x: 0, y: 0, width: 200, height: 1),
        ])
    }

    @Test func matchingPublicationConsumesMergedDamageExactlyOnce() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
        try await store.create(id: 12, width: 8, height: 4, format: 32)
        let created = try await store.descriptor(surfaceID: 12).surfaceRevision
        _ = try #require(await store.publicationSnapshot(atLeast: created))

        _ = try await store.fill(
            surfaceID: 12,
            rectangle: PixelRect(x: 1, y: 1, width: 2, height: 1),
            colorARGB: 0x0011_2233
        )
        let latest = try await store.fill(
            surfaceID: 12,
            rectangle: PixelRect(x: 5, y: 2, width: 1, height: 2),
            colorARGB: 0x0044_5566
        )
        let future = SurfaceRevision(
            surfaceID: latest.surfaceID,
            lifecycleGeneration: latest.lifecycleGeneration,
            revision: latest.revision + 1
        )
        let wrongLifecycle = SurfaceRevision(
            surfaceID: latest.surfaceID,
            lifecycleGeneration: latest.lifecycleGeneration + 1,
            revision: latest.revision
        )

        #expect(await store.publicationSnapshot(atLeast: future) == nil)
        #expect(await store.publicationSnapshot(atLeast: wrongLifecycle) == nil)

        let publication = try #require(await store.publicationSnapshot(atLeast: latest))
        #expect(publication.publicationDamage.copyRectangles == [
            PixelRect(x: 1, y: 1, width: 2, height: 1),
            PixelRect(x: 5, y: 2, width: 1, height: 2),
        ])

        let duplicate = try #require(await store.publicationSnapshot(atLeast: latest))
        #expect(duplicate.surfaceRevision == publication.surfaceRevision)
        #expect(duplicate.publicationDamage.isEmpty)
        #expect(duplicate.publicationDamage.copyRectangles.isEmpty)
    }
}
