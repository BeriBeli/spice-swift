import CoreVideo
import Foundation
import IOSurface
import Testing
@testable import SpiceIOSurface
@testable import SpiceRenderer
@testable import SwiftSpice

@Suite("Interaction marker ROI detector")
struct SpiceInteractionMarkerROIDetectorTests {
    @Test func cEncoderBytesDecodeAsTheExactSwiftFrameIdentity() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory.appending(
            path: "binary-grid-marker-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repositoryRoot.appending(
            path: "Tests/Fixtures/binary-grid-marker-encode-only.c"
        )
        let executable = temporaryDirectory.appending(path: "binary-grid-marker")
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        compiler.arguments = [
            "-std=c11", "-Wall", "-Wextra", "-Werror",
            "-DBINARY_GRID_MARKER_ENCODE_ONLY",
            source.path, "-o", executable.path,
        ]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)

        let output = Pipe()
        let encoder = Process()
        encoder.executableURL = executable
        encoder.arguments = [
            "--encode-bgra", token, "77", String(format: "%08x", checksum),
        ]
        encoder.standardOutput = output
        try encoder.run()
        // Drain before waiting: 11,264 bytes can exceed a small pipe's capacity.
        let encodedMarker = output.fileHandleForReading.readDataToEndOfFile()
        encoder.waitUntilExit()
        try #require(encoder.terminationStatus == 0)

        let markerWidth = SpiceInteractionMarkerROIDetector.columns
            * SpiceInteractionMarkerROIDetector.cellSize
        let markerHeight = SpiceInteractionMarkerROIDetector.rows
            * SpiceInteractionMarkerROIDetector.cellSize
        #expect(encodedMarker.count == markerWidth * markerHeight * 4)
        var pixels = blankPixels
        for row in 0..<markerHeight {
            let sourceStart = row * markerWidth * 4
            let destinationStart = (8 + row) * bytesPerRow + 8 * 4
            pixels.replaceSubrange(
                destinationStart..<(destinationStart + markerWidth * 4),
                with: encodedMarker[sourceStart..<(sourceStart + markerWidth * 4)]
            )
        }
        let expectedIdentity = identity(deliverySequence: 40)

        #expect(detect(
            snapshot(identity: expectedIdentity, pixels: pixels)
        ) == .exact(payload: payload, identity: expectedIdentity))
    }

    @Test(arguments: [8, 20, 32])
    func scansEveryCanonicalBoundaryOriginWithPaddedRows(_ origin: Int) {
        let expectedIdentity = identity(deliverySequence: UInt64(origin))
        let pixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: [SpiceInteractionMarkerPlacement(
                payload: payload,
                originX: origin,
                originY: origin
            )],
            frameWidth: width,
            frameHeight: height,
            bytesPerRow: bytesPerRow
        )

        #expect(detect(
            snapshot(identity: expectedIdentity, pixels: pixels)
        ) == .exact(payload: payload, identity: expectedIdentity))
    }

    @Test(arguments: [
        "0123456789ABCDEF",
        "0123456789abcde",
        "0123456789abcdef0",
        "0123456789abcde\n",
    ])
    func rejectsNoncanonicalExpectedTokens(_ expectedToken: String) {
        let marked = markerSnapshot(identity: identity(deliverySequence: 41))
        #expect(SpiceInteractionMarkerROIDetector.detect(
            in: marked,
            expectedToken: expectedToken,
            expectedChecksum: checksum
        ) == .none)
    }

    @Test func malformedPixelsAndFrameBoundsFailClosed() {
        let expectedIdentity = identity(deliverySequence: 42)
        let markedPixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: [SpiceInteractionMarkerPlacement(
                payload: payload,
                originX: 8,
                originY: 8
            )],
            frameWidth: width,
            frameHeight: height,
            bytesPerRow: bytesPerRow
        )
        let marked = snapshot(identity: expectedIdentity, pixels: markedPixels)
        #expect(SpiceInteractionMarkerROIDetector.detect(
            in: marked,
            expectedToken: token,
            expectedChecksum: checksum ^ 0xffff_ffff
        ) == .none)

        var badMagic = markedPixels
        let firstMagicSample = (8 + 2) * bytesPerRow + (8 + 2) * 4
        badMagic.replaceSubrange(
            firstMagicSample..<(firstMagicSample + 4),
            with: [255, 255, 255, 255]
        )
        #expect(detect(snapshot(
            identity: expectedIdentity,
            pixels: badMagic
        )) == .none)
        #expect(detect(snapshot(
            identity: expectedIdentity,
            pixels: blankPixels
        )) == .none)

        #expect(detect(snapshot(
            identity: expectedIdentity,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: Data(repeating: 0x7f, count: 1)
        )) == .none)
        #expect(detect(snapshot(
            identity: expectedIdentity,
            width: width,
            height: height,
            bytesPerRow: width * 4 - 1,
            pixels: Data(repeating: 0x7f, count: (width * 4 - 1) * height)
        )) == .none)
        #expect(detect(snapshot(
            identity: expectedIdentity,
            width: width,
            height: height,
            bytesPerRow: Int.max,
            pixels: Data(repeating: 0x7f, count: 1)
        )) == .none)
        #expect(detect(snapshot(
            identity: expectedIdentity,
            width: Int.max,
            height: height,
            bytesPerRow: Int.max,
            pixels: Data(repeating: 0x7f, count: 1)
        )) == .none)
    }

    @Test func twoExactMarkersAreAmbiguous() {
        let pixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: [
                SpiceInteractionMarkerPlacement(
                    payload: payload,
                    originX: 8,
                    originY: 8
                ),
                SpiceInteractionMarkerPlacement(
                    payload: payload,
                    originX: 8,
                    originY: 20
                ),
            ],
            frameWidth: width,
            frameHeight: height,
            bytesPerRow: bytesPerRow
        )

        #expect(detect(snapshot(
            identity: identity(deliverySequence: 43),
            pixels: pixels
        )) == .ambiguous(matchCount: 2))
    }

    @Test func iosurfaceBorrowNeverMaterializesAndReadFailureIsRecoverable() throws {
        let frameWidth = 1_279
        let frameHeight = 720
        let sourceBytesPerRow = frameWidth * 4 + 16
        let sourcePixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: [SpiceInteractionMarkerPlacement(
                payload: payload,
                originX: 32,
                originY: 32
            )],
            frameWidth: frameWidth,
            frameHeight: frameHeight,
            bytesPerRow: sourceBytesPerRow
        )
        let pool = IOSurfaceFramePool(limits: .init(
            maximumFrames: 1,
            maximumBytes: 8 * 1_024 * 1_024
        ))
        let metrics = FrameMaterializationMetrics()
        let expectedIdentity = identity(deliverySequence: 44)

        func exercise() throws -> (
            SpiceInteractionMarkerDetection,
            SpiceInteractionMarkerDetection,
            SpiceInteractionMarkerDetection
        ) {
            let ioSurfaceFrame = try #require(pool.makeFrame(
                width: frameWidth,
                height: frameHeight,
                sourceBytesPerRow: sourceBytesPerRow,
                pixels: sourcePixels
            ))
            try #require(ioSurfaceFrame.bytesPerRow > frameWidth * 4)
            let storage = FramePixelStorage(
                pixels: nil,
                ioSurfaceFrame: ioSurfaceFrame,
                expectedPixelBytes: frameWidth * frameHeight * 4,
                materializationMetrics: metrics
            )
            let desktop = snapshot(
                identity: expectedIdentity,
                rendererSnapshot: FrameSnapshot(
                    surfaceID: expectedIdentity.surfaceID,
                    width: frameWidth,
                    height: frameHeight,
                    bytesPerRow: ioSurfaceFrame.bytesPerRow,
                    lifecycleGeneration: expectedIdentity.surfaceGeneration,
                    revision: expectedIdentity.frameRevision,
                    pixelStorage: storage,
                    ioSurfaceFrame: ioSurfaceFrame
                )
            )
            let exact = detect(desktop)
            storage.failNextReadForTesting()
            let failedRead = detect(desktop)
            let recovered = detect(desktop)
            return (exact, failedRead, recovered)
        }

        let (exact, failedRead, recovered) = try exercise()
        #expect(exact == .exact(payload: payload, identity: expectedIdentity))
        #expect(failedRead == .none)
        #expect(recovered == exact)
        #expect(metrics.snapshot().count == 0)
        #expect(metrics.snapshot().bytes == 0)
        #expect(pool.metrics().inUseFrames == 0)
    }

    @Test func unsupportedFormatAndShortIOSurfaceAllocationFailClosed() throws {
        let expectedIdentity = identity(deliverySequence: 45)
        let fullSurface = try makeIOSurface(width: width, height: height)
        let fullStride = IOSurfaceGetBytesPerRow(fullSurface)
        let wrongFormat = IOSurfaceFrame(
            surface: fullSurface,
            width: width,
            height: height,
            bytesPerRow: fullStride,
            pixelFormat: kCVPixelFormatType_32ARGB,
            release: {}
        )
        #expect(detect(snapshot(
            identity: expectedIdentity,
            rendererSnapshot: rendererSnapshot(
                identity: expectedIdentity,
                frame: wrongFormat,
                bytesPerRow: fullStride
            )
        )) == .none)

        let shortSurface = try makeIOSurface(width: 1, height: 1)
        let shortAllocation = IOSurfaceFrame(
            surface: shortSurface,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelFormat: kCVPixelFormatType_32BGRA,
            release: {}
        )
        #expect(detect(snapshot(
            identity: expectedIdentity,
            rendererSnapshot: rendererSnapshot(
                identity: expectedIdentity,
                frame: shortAllocation,
                bytesPerRow: bytesPerRow
            )
        )) == .none)
    }
}

private extension SpiceInteractionMarkerROIDetectorTests {
    var token: String { "0123456789abcdef" }
    var checksum: UInt32 { 0x9f9f_5111 }
    var payload: SpiceInteractionMarkerPayload {
        SpiceInteractionMarkerPayload(
            token: token,
            markerRevision: 77,
            checksum: checksum
        )
    }
    var width: Int { 384 }
    var height: Int { 48 }
    var bytesPerRow: Int { width * 4 + 16 }
    var blankPixels: Data { Data(repeating: 0x7f, count: bytesPerRow * height) }

    func identity(deliverySequence: UInt64) -> SpiceInteractionFrameIdentity {
        SpiceInteractionFrameIdentity(
            desktopGeneration: 5,
            displayChannelID: 0,
            surfaceID: 1,
            surfaceGeneration: 7,
            frameRevision: 9,
            deliverySequence: deliverySequence
        )
    }

    func detect(
        _ snapshot: SpiceDesktopSnapshot
    ) -> SpiceInteractionMarkerDetection {
        SpiceInteractionMarkerROIDetector.detect(
            in: snapshot,
            expectedToken: token,
            expectedChecksum: checksum
        )
    }

    func markerSnapshot(
        identity: SpiceInteractionFrameIdentity
    ) -> SpiceDesktopSnapshot {
        snapshot(
            identity: identity,
            pixels: SpiceInteractionMarkerROIDetector.renderForTesting(
                placements: [SpiceInteractionMarkerPlacement(
                    payload: payload,
                    originX: 8,
                    originY: 8
                )],
                frameWidth: width,
                frameHeight: height,
                bytesPerRow: bytesPerRow
            )
        )
    }

    func snapshot(
        identity: SpiceInteractionFrameIdentity,
        width: Int? = nil,
        height: Int? = nil,
        bytesPerRow: Int? = nil,
        pixels: Data
    ) -> SpiceDesktopSnapshot {
        let frameWidth = width ?? self.width
        let frameHeight = height ?? self.height
        let frameBytesPerRow = bytesPerRow ?? self.bytesPerRow
        return snapshot(
            identity: identity,
            frame: SpiceFrame(
                surfaceID: identity.surfaceID,
                width: frameWidth,
                height: frameHeight,
                bytesPerRow: frameBytesPerRow,
                pixels: pixels
            )
        )
    }

    func snapshot(
        identity: SpiceInteractionFrameIdentity,
        rendererSnapshot: FrameSnapshot
    ) -> SpiceDesktopSnapshot {
        snapshot(identity: identity, frame: SpiceFrame(rendererSnapshot))
    }

    func snapshot(
        identity: SpiceInteractionFrameIdentity,
        frame: SpiceFrame
    ) -> SpiceDesktopSnapshot {
        SpiceDesktopSnapshot(
            generation: identity.desktopGeneration,
            frame: SpiceFrameUpdate(
                frame: frame,
                revision: SpiceFrameRevision(
                    surface: SpiceSurfaceIdentity(
                        displayChannelID: identity.displayChannelID,
                        surfaceID: identity.surfaceID,
                        generation: identity.surfaceGeneration
                    ),
                    value: identity.frameRevision
                ),
                damage: .full,
                deliverySequence: identity.deliverySequence
            ),
            cursor: nil,
            pointerMode: .relative,
            deliverySequence: identity.deliverySequence
        )
    }

    func rendererSnapshot(
        identity: SpiceInteractionFrameIdentity,
        frame: IOSurfaceFrame,
        bytesPerRow: Int
    ) -> FrameSnapshot {
        let storage = FramePixelStorage(
            pixels: nil,
            ioSurfaceFrame: frame,
            expectedPixelBytes: width * height * 4
        )
        return FrameSnapshot(
            surfaceID: identity.surfaceID,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            lifecycleGeneration: identity.surfaceGeneration,
            revision: identity.frameRevision,
            pixelStorage: storage,
            ioSurfaceFrame: frame
        )
    }

    func makeIOSurface(width: Int, height: Int) throws -> IOSurfaceRef {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ]
        return try #require(IOSurfaceCreate(properties as CFDictionary))
    }
}
