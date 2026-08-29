import Foundation
@testable import SpiceChannels
import Testing
@testable import SwiftSpice

@Suite("Interaction frame correlation")
struct SpiceInteractionFrameCorrelationTests {
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
                    originX: 0,
                    originY: 0
                ),
                SpiceInteractionMarkerPlacement(
                    payload: ambiguousPayload,
                    originX: 0,
                    originY: 12
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
                SpiceInteractionMarkerPlacement(payload: payload, originX: 0, originY: 0),
                SpiceInteractionMarkerPlacement(payload: payload, originX: 0, originY: 12),
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
