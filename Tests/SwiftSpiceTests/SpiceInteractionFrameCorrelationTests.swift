import Foundation
import QuartzCore
import Synchronization
@testable import SpiceChannels
@testable import SpiceIOSurface
@testable import SpiceRenderer
import Testing
@testable import SwiftSpice

@Suite("Interaction frame correlation")
struct SpiceInteractionFrameCorrelationTests {
    @Test func guestBinaryGridEncoderMatchesTheSwiftDetector() throws {
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
            path: "Integration/RemoteRocky/guest/binary-grid-marker.c"
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
        let encodedMarker = output.fileHandleForReading.readDataToEndOfFile()
        encoder.waitUntilExit()
        try #require(encoder.terminationStatus == 0)

        let markerWidth = 88 * 4
        let markerHeight = 2 * 4
        #expect(encodedMarker.count == markerWidth * markerHeight * 4)
        var pixels = blankPixels
        let originX = 8
        let originY = 8
        for row in 0..<markerHeight {
            let sourceStart = row * markerWidth * 4
            let destinationStart = (originY + row) * bytesPerRow + originX * 4
            pixels.replaceSubrange(
                destinationStart..<(destinationStart + markerWidth * 4),
                with: encodedMarker[sourceStart..<(sourceStart + markerWidth * 4)]
            )
        }
        let markedSnapshot = snapshot(
            identity: identity(deliverySequence: 40),
            pixels: pixels
        )

        guard case let .exact(payload, detectedIdentity) =
            SpiceInteractionMarkerROIDetector.detect(
                in: markedSnapshot,
                expectedToken: token,
                expectedChecksum: checksum
            )
        else {
            Issue.record("guest binary-grid-v1 pixels were not decoded exactly")
            return
        }
        #expect(payload.token == token)
        #expect(payload.markerRevision == 77)
        #expect(payload.checksum == checksum)
        #expect(detectedIdentity == identity(deliverySequence: 40))
    }

    @Test func markerROIDetectorDecodesPayloadFromTheExactFrameIdentity() throws {
        let markedSnapshot = markerSnapshot(
            identity: identity(deliverySequence: 41),
            markerRevision: 77
        )

        let detection = SpiceInteractionMarkerROIDetector.detect(
            in: markedSnapshot,
            expectedToken: token,
            expectedChecksum: checksum
        )

        guard case let .exact(detectedPayload, detectedIdentity) = detection else {
            Issue.record("expected one exact marker ROI, got \(detection)")
            return
        }
        #expect(detectedPayload == SpiceInteractionMarkerPayload(
            token: token,
            markerRevision: 77,
            checksum: checksum
        ))
        #expect(detectedIdentity == identity(deliverySequence: 41))

        let unmarked = snapshot(
            identity: identity(deliverySequence: 42),
            pixels: blankPixels
        )
        #expect(SpiceInteractionMarkerROIDetector.detect(
            in: unmarked,
            expectedToken: token,
            expectedChecksum: checksum
        ) == .none)

        #expect(SpiceInteractionMarkerROIDetector.detect(
            in: markedSnapshot,
            expectedToken: token,
            expectedChecksum: checksum ^ 0xffff_ffff
        ) == .none)

        let ambiguousPayload = SpiceInteractionMarkerPayload(
            token: token,
            markerRevision: 77,
            checksum: checksum
        )
        let ambiguousPixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: [
                SpiceInteractionMarkerPlacement(
                    payload: ambiguousPayload,
                    originX: 8,
                    originY: 8
                ),
                SpiceInteractionMarkerPlacement(
                    payload: ambiguousPayload,
                    originX: 8,
                    originY: 20
                ),
            ],
            frameWidth: width,
            frameHeight: height,
            bytesPerRow: bytesPerRow
        )
        let ambiguous = self.snapshot(
            identity: identity(deliverySequence: 43),
            pixels: ambiguousPixels
        )
        #expect(SpiceInteractionMarkerROIDetector.detect(
            in: ambiguous,
            expectedToken: token,
            expectedChecksum: checksum
        ) == .ambiguous(matchCount: 2))
    }

    @Test func iosurfaceMarkerDetectionBorrowsOnlyTheBoundedROIAndNeverMaterializesPixels() throws {
        // One pixel below 1280 forces the IOSurface's physical row stride to
        // differ from the compact frame width on the production pool.
        let frameWidth = 1_279
        let frameHeight = 720
        let sourceBytesPerRow = frameWidth * 4 + 16
        let markerPayload = SpiceInteractionMarkerPayload(
            token: token,
            markerRevision: 77,
            checksum: checksum
        )
        let sourcePixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: [SpiceInteractionMarkerPlacement(
                payload: markerPayload,
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
        let materializationMetrics = FrameMaterializationMetrics()
        let expectedIdentity = identity(deliverySequence: 43)

        func exerciseDetector() throws -> (
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
            let pixelStorage = FramePixelStorage(
                pixels: nil,
                ioSurfaceFrame: ioSurfaceFrame,
                expectedPixelBytes: frameWidth * frameHeight * 4,
                materializationMetrics: materializationMetrics
            )
            let rendererSnapshot = FrameSnapshot(
                surfaceID: expectedIdentity.surfaceID,
                width: frameWidth,
                height: frameHeight,
                bytesPerRow: ioSurfaceFrame.bytesPerRow,
                lifecycleGeneration: expectedIdentity.surfaceGeneration,
                revision: expectedIdentity.frameRevision,
                pixelStorage: pixelStorage,
                ioSurfaceFrame: ioSurfaceFrame
            )
            let desktopSnapshot = snapshot(
                identity: expectedIdentity,
                rendererSnapshot: rendererSnapshot
            )

            let exact = SpiceInteractionMarkerROIDetector.detect(
                in: desktopSnapshot,
                expectedToken: token,
                expectedChecksum: checksum
            )
            pixelStorage.failNextReadForTesting()
            let failedRead = SpiceInteractionMarkerROIDetector.detect(
                in: desktopSnapshot,
                expectedToken: token,
                expectedChecksum: checksum
            )
            let recovered = SpiceInteractionMarkerROIDetector.detect(
                in: desktopSnapshot,
                expectedToken: token,
                expectedChecksum: checksum
            )
            return (exact, failedRead, recovered)
        }

        let (exact, failedRead, recovered) = try exerciseDetector()
        #expect(exact == .exact(payload: markerPayload, identity: expectedIdentity))
        #expect(failedRead == .none)
        #expect(recovered == exact)
        #expect(materializationMetrics.snapshot().count == 0)
        #expect(materializationMetrics.snapshot().bytes == 0)
        #expect(pool.metrics().inUseFrames == 0)

        let maximumROIPixelBytes = (
            32 + SpiceInteractionMarkerROIDetector.columns
                * SpiceInteractionMarkerROIDetector.cellSize
        ) * (
            32 + SpiceInteractionMarkerROIDetector.rows
                * SpiceInteractionMarkerROIDetector.cellSize
        ) * 4
        let fullFramePixelBytes = 1_280 * frameHeight * 4
        #expect(maximumROIPixelBytes == 61_440)
        #expect(maximumROIPixelBytes < fullFramePixelBytes / 50)

        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/SwiftSpice/SpiceInteractionCausalTrace.swift")
        let detectorSource = try String(contentsOf: sourceURL, encoding: .utf8)
        let detectStart = try #require(detectorSource.range(
            of: "package static func detect("
        ))
        let decodeStart = try #require(detectorSource.range(
            of: "private static func decode(",
            range: detectStart.upperBound..<detectorSource.endIndex
        ))
        let detectBody = detectorSource[detectStart.lowerBound..<decodeStart.lowerBound]
        #expect(detectBody.contains("withReadOnlyPixelBytes"))
        #expect(!detectBody.contains("frame.pixels"))
        #expect(!detectBody.contains("copyPixels"))
    }

    @Test func guestMarkerAcknowledgmentAloneCannotBecomeVisibleEvidence() {
        let assembler = makeAssembler()
        recordInputAndGuest(
            on: assembler,
            beforeDisplayReceiveNs: SpiceInteractionHostClock.nowNanoseconds() + 100
        )

        let record = assembler.finish()

        #expect(!record.valid)
        #expect(record.presentedNs == nil)
        #expect(record.frameRevision == nil)
        #expect(record.deliverySequence == nil)
    }

    @Test func onlyTheMarkerCapturedDeliveryCanCompletePresentation() {
        let matchedIdentity = identity(deliverySequence: 51)
        let assembler = makeAssembler()
        let matchedTiming = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let matchedReceive = SpiceInteractionHostClock.nanoseconds(
            for: matchedTiming.messageReceivedAt
        )!
        let matchedReady = SpiceInteractionHostClock.nanoseconds(
            for: matchedTiming.surfaceReadyAt
        )!
        recordInputAndGuest(on: assembler, beforeDisplayReceiveNs: matchedReceive)
        assembler.observeFrame(
            snapshot: markerSnapshot(identity: matchedIdentity, markerRevision: 77),
            sourceTiming: matchedTiming
        )
        assembler.observeSelected(
            identity: matchedIdentity,
            readyNs: matchedReady,
            selectionNs: matchedReady + 10
        )
        assembler.observeCommitted(identity: matchedIdentity, at: matchedReady + 20)
        assembler.observePresented(identity: matchedIdentity, at: matchedReady + 30)

        let record = assembler.finish()

        #expect(record.valid)
        #expect(record.desktopGeneration == matchedIdentity.desktopGeneration)
        #expect(record.displayChannelID == matchedIdentity.displayChannelID)
        #expect(record.surfaceID == matchedIdentity.surfaceID)
        #expect(record.surfaceGeneration == matchedIdentity.surfaceGeneration)
        #expect(record.frameRevision == matchedIdentity.frameRevision)
        #expect(record.deliverySequence == matchedIdentity.deliverySequence)
        #expect(record.markerRevision == 77)
        #expect(record.markerChecksum == "9f9f5111")
        #expect(record.displayReceiveNs == SpiceInteractionHostClock.nanoseconds(
            for: matchedTiming.messageReceivedAt
        ))
        #expect(record.surfaceReadyNs == SpiceInteractionHostClock.nanoseconds(
            for: matchedTiming.surfaceReadyAt
        ))
        #expect(record.selectedRevisionReadyNs == matchedReady)
        #expect(record.selectionNs == matchedReady + 10)
        #expect(record.metalCommitNs == matchedReady + 20)
        #expect(record.presentedNs == matchedReady + 30)

        let mismatched = makeAssembler()
        recordInputAndGuest(on: mismatched, beforeDisplayReceiveNs: matchedReceive)
        mismatched.observeFrame(
            snapshot: markerSnapshot(identity: matchedIdentity, markerRevision: 77),
            sourceTiming: matchedTiming
        )
        let unrelated = identity(frameRevision: 12, deliverySequence: 52)
        mismatched.observeSelected(
            identity: unrelated,
            readyNs: matchedReady + 5,
            selectionNs: matchedReady + 10
        )
        mismatched.observeCommitted(identity: unrelated, at: matchedReady + 20)
        mismatched.observePresented(identity: unrelated, at: matchedReady + 30)
        let mismatchedRecord = mismatched.finish()
        #expect(!mismatchedRecord.valid)
        #expect(mismatchedRecord.invalidReason == "marker_replaced_before_presented")
    }

    @Test func latestReplacementCannotInheritTheMarkerFramesTimingOrCausality() {
        let markerIdentity = identity(frameRevision: 10, deliverySequence: 61)
        let replacementIdentity = identity(frameRevision: 11, deliverySequence: 62)
        let assembler = makeAssembler()
        let anchor = ContinuousClock().now
        let markerTiming = sourceTiming(
            anchor: anchor,
            receivedOffset: 50,
            readyOffset: 60
        )
        let replacementTiming = sourceTiming(
            anchor: anchor,
            receivedOffset: 65,
            readyOffset: 75
        )
        let markerReceive = SpiceInteractionHostClock.nanoseconds(
            for: markerTiming.messageReceivedAt
        )!
        let replacementReady = SpiceInteractionHostClock.nanoseconds(
            for: replacementTiming.surfaceReadyAt
        )!
        recordInputAndGuest(on: assembler, beforeDisplayReceiveNs: markerReceive)
        assembler.observeFrame(
            snapshot: markerSnapshot(identity: markerIdentity, markerRevision: 77),
            sourceTiming: markerTiming
        )
        assembler.observeFrame(
            snapshot: snapshot(identity: replacementIdentity, pixels: blankPixels),
            sourceTiming: replacementTiming
        )
        assembler.observeSelected(
            identity: replacementIdentity,
            readyNs: replacementReady,
            selectionNs: replacementReady + 5
        )
        assembler.observeCommitted(identity: replacementIdentity, at: replacementReady + 10)
        assembler.observePresented(identity: replacementIdentity, at: replacementReady + 15)

        let record = assembler.finish()

        #expect(!record.valid)
        #expect(record.invalidReason == "marker_replaced_before_presented")
        #expect(record.displayReceiveNs == SpiceInteractionHostClock.nanoseconds(
            for: replacementTiming.messageReceivedAt
        ))
        #expect(record.surfaceReadyNs == SpiceInteractionHostClock.nanoseconds(
            for: replacementTiming.surfaceReadyAt
        ))
        #expect(record.selectedRevisionReadyNs == replacementReady)
        #expect(record.frameRevision == replacementIdentity.frameRevision)
        #expect(record.deliverySequence == replacementIdentity.deliverySequence)
    }

    @Test func staleGenerationDuplicateAndMissingDrawablePresentationStayInvalid() {
        let frameIdentity = identity(deliverySequence: 71)
        let timing = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let receive = SpiceInteractionHostClock.nanoseconds(for: timing.messageReceivedAt)!
        let ready = SpiceInteractionHostClock.nanoseconds(for: timing.surfaceReadyAt)!

        let stale = makeAssembler()
        recordInputAndGuest(on: stale, beforeDisplayReceiveNs: receive)
        stale.retireDesktopGeneration(frameIdentity.desktopGeneration)
        stale.observeFrame(
            snapshot: markerSnapshot(identity: frameIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        stale.observeSelected(identity: frameIdentity, readyNs: ready, selectionNs: ready + 10)
        stale.observeCommitted(identity: frameIdentity, at: ready + 20)
        stale.observePresented(identity: frameIdentity, at: ready + 30)
        #expect(!stale.finish().valid)

        let duplicate = makeAssembler()
        recordInputAndGuest(on: duplicate, beforeDisplayReceiveNs: receive)
        let marked = markerSnapshot(identity: frameIdentity, markerRevision: 77)
        duplicate.observeFrame(snapshot: marked, sourceTiming: timing)
        duplicate.observeFrame(snapshot: marked, sourceTiming: timing)
        duplicate.observeSelected(identity: frameIdentity, readyNs: ready, selectionNs: ready + 10)
        duplicate.observeCommitted(identity: frameIdentity, at: ready + 20)
        duplicate.observePresented(identity: frameIdentity, at: ready + 30)
        let duplicateRecord = duplicate.finish()
        #expect(!duplicateRecord.valid)
        #expect(duplicateRecord.invalidReason == "duplicate_frame_identity")

        let cpuFallback = makeAssembler()
        recordInputAndGuest(on: cpuFallback, beforeDisplayReceiveNs: receive)
        cpuFallback.observeFrame(snapshot: marked, sourceTiming: timing)
        cpuFallback.observeSelected(identity: frameIdentity, readyNs: ready, selectionNs: ready + 10)
        cpuFallback.observeCommitted(identity: frameIdentity, at: ready + 20)
        let cpuFallbackRecord = cpuFallback.finish()
        #expect(!cpuFallbackRecord.valid)
        #expect(cpuFallbackRecord.invalidReason == "missing_presented")

        let missingTiming = makeAssembler()
        recordInputAndGuest(on: missingTiming, beforeDisplayReceiveNs: receive)
        missingTiming.observeFrame(snapshot: marked, sourceTiming: nil)
        missingTiming.observeSelected(
            identity: frameIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        missingTiming.observeCommitted(identity: frameIdentity, at: ready + 20)
        missingTiming.observePresented(identity: frameIdentity, at: ready + 30)
        let missingTimingRecord = missingTiming.finish()
        #expect(!missingTimingRecord.valid)
        #expect(missingTimingRecord.invalidReason == "missing_display_receive")

        let ambiguous = makeAssembler()
        recordInputAndGuest(on: ambiguous, beforeDisplayReceiveNs: receive)
        let payload = SpiceInteractionMarkerPayload(
            token: token,
            markerRevision: 77,
            checksum: checksum
        )
        let ambiguousPixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: [
                SpiceInteractionMarkerPlacement(payload: payload, originX: 8, originY: 8),
                SpiceInteractionMarkerPlacement(payload: payload, originX: 8, originY: 20),
            ],
            frameWidth: width,
            frameHeight: height,
            bytesPerRow: bytesPerRow
        )
        ambiguous.observeFrame(
            snapshot: snapshot(identity: frameIdentity, pixels: ambiguousPixels),
            sourceTiming: timing
        )
        ambiguous.observeSelected(identity: frameIdentity, readyNs: ready, selectionNs: ready + 10)
        ambiguous.observeCommitted(identity: frameIdentity, at: ready + 20)
        ambiguous.observePresented(identity: frameIdentity, at: ready + 30)
        let ambiguousRecord = ambiguous.finish()
        #expect(!ambiguousRecord.valid)
        #expect(ambiguousRecord.invalidReason == "ambiguous_marker_roi_2")

        let noInput = makeAssembler()
        noInput.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
        noInput.observeFrame(snapshot: marked, sourceTiming: timing)
        noInput.observeSelected(identity: frameIdentity, readyNs: ready, selectionNs: ready + 10)
        noInput.observeCommitted(identity: frameIdentity, at: ready + 20)
        noInput.observePresented(identity: frameIdentity, at: ready + 30)
        let noInputRecord = noInput.finish()
        #expect(!noInputRecord.valid)
        #expect(noInputRecord.invalidReason == "missing_input_event")
    }

    @Test func assemblerRetainsAtMostSixteenObservedFrameIdentities() {
        let timing = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let receive = SpiceInteractionHostClock.nanoseconds(for: timing.messageReceivedAt)!
        let ready = SpiceInteractionHostClock.nanoseconds(for: timing.surfaceReadyAt)!

        let exactLimit = makeAssembler()
        recordInputAndGuest(on: exactLimit, beforeDisplayReceiveNs: receive)
        var sixteenthIdentity = identity(frameRevision: 0, deliverySequence: 0)
        for index in 0..<16 {
            let observedIdentity = identity(
                frameRevision: UInt64(100 + index),
                deliverySequence: UInt64(200 + index)
            )
            sixteenthIdentity = observedIdentity
            let observed = index == 15
                ? markerSnapshot(identity: observedIdentity, markerRevision: 77)
                : snapshot(identity: observedIdentity, pixels: blankPixels)
            exactLimit.observeFrame(snapshot: observed, sourceTiming: timing)
        }
        exactLimit.observeSelected(
            identity: sixteenthIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        exactLimit.observeCommitted(identity: sixteenthIdentity, at: ready + 20)
        exactLimit.observePresented(identity: sixteenthIdentity, at: ready + 30)
        #expect(exactLimit.finish().valid)

        let overflow = makeAssembler()
        recordInputAndGuest(on: overflow, beforeDisplayReceiveNs: receive)
        for index in 0..<16 {
            let observedIdentity = identity(
                frameRevision: UInt64(300 + index),
                deliverySequence: UInt64(400 + index)
            )
            overflow.observeFrame(
                snapshot: snapshot(identity: observedIdentity, pixels: blankPixels),
                sourceTiming: timing
            )
        }
        let seventeenthIdentity = identity(frameRevision: 316, deliverySequence: 416)
        overflow.observeFrame(
            snapshot: markerSnapshot(identity: seventeenthIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        overflow.observeSelected(
            identity: seventeenthIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        overflow.observeCommitted(identity: seventeenthIdentity, at: ready + 20)
        overflow.observePresented(identity: seventeenthIdentity, at: ready + 30)
        let overflowRecord = overflow.finish()
        #expect(!overflowRecord.valid)
        #expect(overflowRecord.invalidReason == "too_many_observed_frames")
        #expect(overflowRecord.displayReceiveNs == nil)
        #expect(overflowRecord.surfaceReadyNs == nil)
        #expect(overflowRecord.markerChecksum == nil)
    }

    @Test func duplicateCommitAndPresentedEvidenceFailClosedWithoutRewritingFirstTiming() {
        let timing = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let receive = SpiceInteractionHostClock.nanoseconds(for: timing.messageReceivedAt)!
        let ready = SpiceInteractionHostClock.nanoseconds(for: timing.surfaceReadyAt)!
        let frameIdentity = identity(deliverySequence: 501)

        let duplicateCommit = makeAssembler()
        recordInputAndGuest(on: duplicateCommit, beforeDisplayReceiveNs: receive)
        duplicateCommit.observeFrame(
            snapshot: markerSnapshot(identity: frameIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        duplicateCommit.observeSelected(
            identity: frameIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        duplicateCommit.observeCommitted(identity: frameIdentity, at: ready + 20)
        duplicateCommit.observeCommitted(identity: frameIdentity, at: ready + 21)
        duplicateCommit.observePresented(identity: frameIdentity, at: ready + 30)
        let duplicateCommitRecord = duplicateCommit.finish()
        #expect(!duplicateCommitRecord.valid)
        #expect(duplicateCommitRecord.invalidReason == "duplicate_metal_commit")
        #expect(duplicateCommitRecord.metalCommitNs == ready + 20)

        let duplicatePresented = makeAssembler()
        recordInputAndGuest(on: duplicatePresented, beforeDisplayReceiveNs: receive)
        duplicatePresented.observeFrame(
            snapshot: markerSnapshot(identity: frameIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        duplicatePresented.observeSelected(
            identity: frameIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        duplicatePresented.observeCommitted(identity: frameIdentity, at: ready + 20)
        duplicatePresented.observePresented(identity: frameIdentity, at: ready + 30)
        duplicatePresented.observePresented(identity: frameIdentity, at: ready + 31)
        let duplicatePresentedRecord = duplicatePresented.finish()
        #expect(!duplicatePresentedRecord.valid)
        #expect(duplicatePresentedRecord.invalidReason == "duplicate_presented")
        #expect(duplicatePresentedRecord.presentedNs == ready + 30)
    }

    @Test func sameDeliveryRetryPreservesItsFirstReadyTimestamp() {
        let timing = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let receive = SpiceInteractionHostClock.nanoseconds(for: timing.messageReceivedAt)!
        let firstReady = SpiceInteractionHostClock.nanoseconds(for: timing.surfaceReadyAt)!
        let frameIdentity = identity(deliverySequence: 601)
        let assembler = makeAssembler()
        recordInputAndGuest(on: assembler, beforeDisplayReceiveNs: receive)
        assembler.observeFrame(
            snapshot: markerSnapshot(identity: frameIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        assembler.observeSelected(
            identity: frameIdentity,
            readyNs: firstReady,
            selectionNs: firstReady + 10
        )

        let retryReady = firstReady + 100
        assembler.observeSelected(
            identity: frameIdentity,
            readyNs: firstReady,
            selectionNs: retryReady + 10
        )
        assembler.observeCommitted(identity: frameIdentity, at: retryReady + 20)
        assembler.observePresented(identity: frameIdentity, at: retryReady + 30)
        let record = assembler.finish()

        #expect(record.valid)
        #expect(record.selectedRevisionReadyNs == firstReady)
        #expect(record.selectionNs == retryReady + 10)
    }

    @Test func presentationOrderingFailsClosedButOtherInFlightIdentityIsIgnored() {
        let timing = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let receive = SpiceInteractionHostClock.nanoseconds(for: timing.messageReceivedAt)!
        let ready = SpiceInteractionHostClock.nanoseconds(for: timing.surfaceReadyAt)!
        let selectedIdentity = identity(deliverySequence: 701)
        let otherIdentity = identity(frameRevision: 11, deliverySequence: 702)

        let presentedBeforeCommit = makeAssembler()
        recordInputAndGuest(on: presentedBeforeCommit, beforeDisplayReceiveNs: receive)
        presentedBeforeCommit.observeFrame(
            snapshot: markerSnapshot(identity: selectedIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        presentedBeforeCommit.observeSelected(
            identity: selectedIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        presentedBeforeCommit.observePresented(identity: selectedIdentity, at: ready + 20)
        presentedBeforeCommit.observeCommitted(identity: selectedIdentity, at: ready + 30)
        let outOfOrder = presentedBeforeCommit.finish()
        #expect(!outOfOrder.valid)
        #expect(outOfOrder.invalidReason == "presented_before_commit")
        #expect(outOfOrder.presentedNs == nil)

        let unrelatedCallbacks = makeAssembler()
        recordInputAndGuest(on: unrelatedCallbacks, beforeDisplayReceiveNs: receive)
        unrelatedCallbacks.observeFrame(
            snapshot: markerSnapshot(identity: selectedIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        unrelatedCallbacks.observeSelected(
            identity: selectedIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        unrelatedCallbacks.observeCommitted(identity: otherIdentity, at: ready + 15)
        unrelatedCallbacks.observePresented(identity: otherIdentity, at: ready + 16)
        unrelatedCallbacks.observeCommitted(identity: selectedIdentity, at: ready + 20)
        unrelatedCallbacks.observePresented(identity: selectedIdentity, at: ready + 30)
        let unrelatedRecord = unrelatedCallbacks.finish()
        #expect(unrelatedRecord.valid)
        #expect(unrelatedRecord.metalCommitNs == ready + 20)
        #expect(unrelatedRecord.presentedNs == ready + 30)

        let reversedTimestamps = makeAssembler()
        recordInputAndGuest(on: reversedTimestamps, beforeDisplayReceiveNs: receive)
        reversedTimestamps.observeFrame(
            snapshot: markerSnapshot(identity: selectedIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        reversedTimestamps.observeSelected(
            identity: selectedIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        reversedTimestamps.observeCommitted(identity: selectedIdentity, at: ready + 30)
        reversedTimestamps.observePresented(identity: selectedIdentity, at: ready + 20)
        #expect(!reversedTimestamps.finish().valid)
    }

    @Test func retiredSurfaceLifecycleCannotBeCompletedByLateCallbacks() {
        let timing = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let receive = SpiceInteractionHostClock.nanoseconds(for: timing.messageReceivedAt)!
        let ready = SpiceInteractionHostClock.nanoseconds(for: timing.surfaceReadyAt)!
        let retiredIdentity = identity(surfaceGeneration: 9, deliverySequence: 801)

        let retired = makeAssembler()
        recordInputAndGuest(on: retired, beforeDisplayReceiveNs: receive)
        retired.observeFrame(
            snapshot: markerSnapshot(identity: retiredIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        retired.observeSelected(
            identity: retiredIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        retired.retireSurfaceLifecycle(
            displayChannelID: retiredIdentity.displayChannelID,
            surfaceID: retiredIdentity.surfaceID,
            generation: retiredIdentity.surfaceGeneration
        )
        retired.observeCommitted(identity: retiredIdentity, at: ready + 20)
        retired.observePresented(identity: retiredIdentity, at: ready + 30)
        let retiredRecord = retired.finish()
        #expect(!retiredRecord.valid)
        #expect(retiredRecord.invalidReason == "surface_lifecycle_retired")
        #expect(retiredRecord.metalCommitNs == nil)
        #expect(retiredRecord.presentedNs == nil)

        let unrelatedRetirement = makeAssembler()
        recordInputAndGuest(on: unrelatedRetirement, beforeDisplayReceiveNs: receive)
        unrelatedRetirement.observeFrame(
            snapshot: markerSnapshot(identity: retiredIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        unrelatedRetirement.observeSelected(
            identity: retiredIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        unrelatedRetirement.retireSurfaceLifecycle(
            displayChannelID: retiredIdentity.displayChannelID,
            surfaceID: retiredIdentity.surfaceID + 1,
            generation: retiredIdentity.surfaceGeneration
        )
        unrelatedRetirement.observeCommitted(identity: retiredIdentity, at: ready + 20)
        unrelatedRetirement.observePresented(identity: retiredIdentity, at: ready + 30)
        #expect(unrelatedRetirement.finish().valid)

        let completedBeforeRetirement = makeAssembler()
        recordInputAndGuest(on: completedBeforeRetirement, beforeDisplayReceiveNs: receive)
        completedBeforeRetirement.observeFrame(
            snapshot: markerSnapshot(identity: retiredIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        completedBeforeRetirement.observeSelected(
            identity: retiredIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        completedBeforeRetirement.observeCommitted(
            identity: retiredIdentity,
            at: ready + 20
        )
        completedBeforeRetirement.observePresented(
            identity: retiredIdentity,
            at: ready + 30
        )
        completedBeforeRetirement.retireSurfaceLifecycle(
            displayChannelID: retiredIdentity.displayChannelID,
            surfaceID: retiredIdentity.surfaceID,
            generation: retiredIdentity.surfaceGeneration
        )
        #expect(completedBeforeRetirement.finish().valid)
    }

    @Test func presentedCallbackLinearizesBeforeCaptureFinishOrIsDetached() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "interaction-presented-race-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = SpicePresentationDiagnostics()
        let output = directory.appending(path: "input-events.jsonl")
        let capture = try SpiceInteractionTraceCapture(
            presentationDiagnostics: diagnostics,
            writer: SpiceInteractionTraceJSONLWriter(outputURL: output),
            pairId: "pair-presented-race",
            version: "v0.3.1",
            runId: "run-presented-race",
            order: 1,
            actionClass: .motion,
            token: token,
            checksum: checksum
        )
        let timing = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let receive = try #require(SpiceInteractionHostClock.nanoseconds(
            for: timing.messageReceivedAt
        ))
        let ready = try #require(SpiceInteractionHostClock.nanoseconds(
            for: timing.surfaceReadyAt
        ))
        let frameIdentity = identity(deliverySequence: 901)
        try capture.recordHostEvidence(
            scheduledNs: receive - 40,
            hostInputNs: receive - 30,
            sendStartedNs: receive - 20,
            sendCompletedNs: receive - 10,
            motionAckNs: receive - 15
        )
        try capture.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
        diagnostics.recordInteractionFrameReceived(
            markerSnapshot(identity: frameIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        diagnostics.recordInteractionSelected(
            identity: frameIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        diagnostics.recordInteractionCommitted(identity: frameIdentity, at: ready + 20)

        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let callbackCount = Mutex(0)
        diagnostics.setInteractionEvidenceWillCommitForTesting {
            callbackCount.withLock { $0 += 1 }
            callbackEntered.signal()
            releaseCallback.wait()
        }
        let presented = Task.detached {
            diagnostics.recordInteractionPresented(identity: frameIdentity, at: ready + 30)
        }
        try #require(await waitForInteractionTraceSemaphore(
            callbackEntered,
            timeout: .seconds(1)
        ) == .success)
        let finishing = Task.detached {
            try capture.finish()
        }
        releaseCallback.signal()

        await presented.value
        let record = try await finishing.value
        #expect(record.valid)
        #expect(record.presentedNs == ready + 30)
        #expect(callbackCount.withLock { $0 } == 1)

        // Finish detached the assembler. A subsequent callback neither enters
        // the commit hook nor mutates the cached record.
        diagnostics.recordInteractionPresented(identity: frameIdentity, at: ready + 40)
        #expect(callbackCount.withLock { $0 } == 1)
        do {
            _ = try capture.finish()
            Issue.record("finished capture rebuilt or appended its cached record")
        } catch let error as SpiceInteractionTraceCollectionError {
            #expect(error == .captureAlreadyFinished)
        }
        let lines = try Data(contentsOf: output).split(separator: 0x0A)
        #expect(lines.count == 1)
        #expect(try JSONDecoder().decode(
            SpiceInteractionTraceRecord.self,
            from: Data(try #require(lines.first))
        ) == record)
    }

    @Test func captureRetainsPresentedFrameUntilTheSendContinuationCompletes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "interaction-send-completion-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = SpicePresentationDiagnostics()
        let output = directory.appending(path: "input-events.jsonl")
        let capture = try SpiceInteractionTraceCapture(
            presentationDiagnostics: diagnostics,
            writer: SpiceInteractionTraceJSONLWriter(outputURL: output),
            pairId: "pair-send-completion",
            version: "v0.3.1",
            runId: "run-send-completion",
            order: 1,
            actionClass: .motion,
            token: token,
            checksum: checksum
        )
        let timing = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let receive = try #require(SpiceInteractionHostClock.nanoseconds(
            for: timing.messageReceivedAt
        ))
        let ready = try #require(SpiceInteractionHostClock.nanoseconds(
            for: timing.surfaceReadyAt
        ))
        let earlyMotionAcknowledgment = receive - 5
        let frameIdentity = identity(deliverySequence: 902)

        try capture.recordHostInput(
            scheduledNs: receive - 30,
            hostInputNs: receive - 20,
            sendStartedNs: receive - 10
        )
        try capture.recordMotionAcknowledged(at: earlyMotionAcknowledgment)
        try capture.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
        diagnostics.recordInteractionFrameReceived(
            markerSnapshot(identity: frameIdentity, markerRevision: 77),
            sourceTiming: timing
        )
        diagnostics.recordInteractionSelected(
            identity: frameIdentity,
            readyNs: ready,
            selectionNs: ready + 10
        )
        diagnostics.recordInteractionCommitted(identity: frameIdentity, at: ready + 20)
        diagnostics.recordInteractionPresented(identity: frameIdentity, at: ready + 30)

        // The transport continuation resumes last. Supplying the same ACK is
        // an idempotent linearization of evidence that arrived during send.
        try capture.recordSendCompleted(
            at: receive + 5,
            motionAckNs: earlyMotionAcknowledgment
        )
        let record = try capture.finish()

        #expect(record.valid)
        #expect(record.sendStartedNs == receive - 10)
        #expect(record.displayReceiveNs == receive)
        #expect(record.sendCompletedNs == receive + 5)
        #expect(record.motionAckNs == earlyMotionAcknowledgment)
        #expect(record.presentedNs == ready + 30)
        let lines = try Data(contentsOf: output).split(separator: 0x0A)
        #expect(lines.count == 1)
        #expect(try JSONDecoder().decode(
            SpiceInteractionTraceRecord.self,
            from: Data(try #require(lines.first))
        ) == record)
    }

    @Test func captureRejectsMissingDuplicateOrNonMonotonicSendCompletion() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "interaction-send-failures-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func makeCapture(
            _ name: String
        ) throws -> (SpiceInteractionTraceCapture, SpicePresentationDiagnostics) {
            let diagnostics = SpicePresentationDiagnostics()
            let capture = try SpiceInteractionTraceCapture(
                presentationDiagnostics: diagnostics,
                writer: SpiceInteractionTraceJSONLWriter(
                    outputURL: directory.appending(path: "\(name).jsonl")
                ),
                pairId: "pair-\(name)",
                version: "v0.3.1",
                runId: "run-send-failures",
                order: 1,
                actionClass: .motion,
                token: token,
                checksum: checksum
            )
            return (capture, diagnostics)
        }

        let (missingPrelude, _) = try makeCapture("missing-prelude")
        try missingPrelude.recordSendCompleted(at: 40)
        let missingPreludeRecord = try missingPrelude.finish()
        #expect(missingPreludeRecord.invalidReason == "send_completion_before_host_evidence")

        let (duplicate, _) = try makeCapture("duplicate")
        try duplicate.recordHostInput(scheduledNs: 10, hostInputNs: 20, sendStartedNs: 30)
        try duplicate.recordSendCompleted(at: 40)
        try duplicate.recordSendCompleted(at: 41)
        let duplicateRecord = try duplicate.finish()
        #expect(duplicateRecord.invalidReason == "duplicate_send_completion")

        let (nonMonotonic, nonMonotonicDiagnostics) = try makeCapture("non-monotonic")
        try nonMonotonic.recordHostInput(scheduledNs: 10, hostInputNs: 20, sendStartedNs: 30)
        try nonMonotonic.recordSendCompleted(at: 29)
        try nonMonotonic.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
        let nonMonotonicTiming = sourceTiming(receivedOffset: 50, readyOffset: 60)
        let nonMonotonicReady = try #require(SpiceInteractionHostClock.nanoseconds(
            for: nonMonotonicTiming.surfaceReadyAt
        ))
        let nonMonotonicIdentity = identity(deliverySequence: 903)
        nonMonotonicDiagnostics.recordInteractionFrameReceived(
            markerSnapshot(identity: nonMonotonicIdentity, markerRevision: 77),
            sourceTiming: nonMonotonicTiming
        )
        nonMonotonicDiagnostics.recordInteractionSelected(
            identity: nonMonotonicIdentity,
            readyNs: nonMonotonicReady,
            selectionNs: nonMonotonicReady + 10
        )
        nonMonotonicDiagnostics.recordInteractionCommitted(
            identity: nonMonotonicIdentity,
            at: nonMonotonicReady + 20
        )
        nonMonotonicDiagnostics.recordInteractionPresented(
            identity: nonMonotonicIdentity,
            at: nonMonotonicReady + 30
        )
        let nonMonotonicRecord = try nonMonotonic.finish()
        #expect(nonMonotonicRecord.invalidReason == "non_monotonic_timestamps")

        let (conflictingAcknowledgment, _) = try makeCapture("conflicting-ack")
        try conflictingAcknowledgment.recordHostInput(
            scheduledNs: 10,
            hostInputNs: 20,
            sendStartedNs: 30
        )
        try conflictingAcknowledgment.recordMotionAcknowledged(at: 35)
        try conflictingAcknowledgment.recordSendCompleted(at: 40, motionAckNs: 36)
        let conflictingAcknowledgmentRecord = try conflictingAcknowledgment.finish()
        #expect(conflictingAcknowledgmentRecord.invalidReason == "duplicate_motion_ack")
    }

    @Test func coreAnimationPresentedTimeMapsIntoTheHostMonotonicClock() throws {
        let before = SpiceInteractionHostClock.nowNanoseconds()
        let mediaTime = CACurrentMediaTime()
        let mapped = try #require(SpiceInteractionHostClock.nanoseconds(
            forCoreAnimationTime: mediaTime
        ))
        let after = SpiceInteractionHostClock.nowNanoseconds()
        #expect(mapped >= before)
        #expect(mapped <= after)

        let earlier = try #require(SpiceInteractionHostClock.nanoseconds(
            forCoreAnimationTime: mediaTime - 0.125
        ))
        let delta = mapped - earlier
        #expect((124_999_998...125_000_002).contains(delta))
        #expect(SpiceInteractionHostClock.nanoseconds(
            forCoreAnimationTime: .nan
        ) == nil)
        #expect(SpiceInteractionHostClock.nanoseconds(
            forCoreAnimationTime: .infinity
        ) == nil)
    }

    private let token = "0123456789abcdef"
    private let checksum: UInt32 = 0x9f9f_5111
    private let width = 384
    private let height = 48
    private let bytesPerRow = 384 * 4 + 16
    private let markerOriginX = 8
    private let markerOriginY = 8

    private var blankPixels: Data {
        Data(repeating: 0x7f, count: bytesPerRow * height)
    }

    private func makeAssembler() -> SpiceInteractionTraceAssembler {
        SpiceInteractionTraceAssembler(
            pairId: "pair-0001",
            version: "v0.3.1",
            runId: "run-0001",
            order: 1,
            actionClass: .motion,
            token: token,
            checksum: checksum
        )
    }

    private func recordInputAndGuest(
        on assembler: SpiceInteractionTraceAssembler,
        beforeDisplayReceiveNs displayReceiveNs: UInt64
    ) {
        assembler.recordHostEvidence(
            scheduledNs: displayReceiveNs - 40,
            hostInputNs: displayReceiveNs - 30,
            sendStartedNs: displayReceiveNs - 20,
            sendCompletedNs: displayReceiveNs - 10,
            motionAckNs: displayReceiveNs - 15
        )
        assembler.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
    }

    private func sourceTiming(
        anchor: ContinuousClock.Instant = ContinuousClock().now,
        receivedOffset: Int64,
        readyOffset: Int64
    ) -> DisplayFrameSourceTiming {
        return DisplayFrameSourceTiming(
            messageReceivedAt: anchor.advanced(by: .nanoseconds(receivedOffset)),
            surfaceReadyAt: anchor.advanced(by: .nanoseconds(readyOffset))
        )
    }

    private func identity(
        desktopGeneration: UInt64 = 7,
        surfaceGeneration: UInt64 = 9,
        frameRevision: UInt64 = 10,
        deliverySequence: UInt64
    ) -> SpiceInteractionFrameIdentity {
        SpiceInteractionFrameIdentity(
            desktopGeneration: desktopGeneration,
            displayChannelID: 0,
            surfaceID: 1,
            surfaceGeneration: surfaceGeneration,
            frameRevision: frameRevision,
            deliverySequence: deliverySequence
        )
    }

    private func markerSnapshot(
        identity: SpiceInteractionFrameIdentity,
        markerRevision: UInt64
    ) -> SpiceDesktopSnapshot {
        let pixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: [SpiceInteractionMarkerPlacement(
                payload: SpiceInteractionMarkerPayload(
                    token: token,
                    markerRevision: markerRevision,
                    checksum: checksum
                ),
                originX: markerOriginX,
                originY: markerOriginY
            )],
            frameWidth: width,
            frameHeight: height,
            bytesPerRow: bytesPerRow
        )
        return snapshot(identity: identity, pixels: pixels)
    }

    private func snapshot(
        identity: SpiceInteractionFrameIdentity,
        rendererSnapshot: FrameSnapshot
    ) -> SpiceDesktopSnapshot {
        let surface = SpiceSurfaceIdentity(
            displayChannelID: identity.displayChannelID,
            surfaceID: identity.surfaceID,
            generation: identity.surfaceGeneration
        )
        return SpiceDesktopSnapshot(
            generation: identity.desktopGeneration,
            frame: SpiceFrameUpdate(
                frame: SpiceFrame(rendererSnapshot),
                revision: SpiceFrameRevision(
                    surface: surface,
                    value: identity.frameRevision
                ),
                damage: .full
            ),
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: identity.deliverySequence
        )
    }

    private func snapshot(
        identity: SpiceInteractionFrameIdentity,
        pixels: Data
    ) -> SpiceDesktopSnapshot {
        let surface = SpiceSurfaceIdentity(
            displayChannelID: 0,
            surfaceID: 1,
            generation: identity.surfaceGeneration
        )
        let frame = SpiceFrame(
            surfaceID: surface.surfaceID,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: pixels
        )
        return SpiceDesktopSnapshot(
            generation: identity.desktopGeneration,
            frame: SpiceFrameUpdate(
                frame: frame,
                revision: SpiceFrameRevision(
                    surface: surface,
                    value: identity.frameRevision
                ),
                damage: .full
            ),
            cursor: nil,
            pointerMode: .absolute,
            deliverySequence: identity.deliverySequence
        )
    }
}

private func waitForInteractionTraceSemaphore(
    _ semaphore: DispatchSemaphore,
    timeout: DispatchTimeInterval
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + timeout))
        }
    }
}
