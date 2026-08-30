import Foundation
import Synchronization
import Testing
@testable import SpiceChannels
@testable import SpiceRenderer
@testable import SwiftSpice

@Suite("Interaction frame correlation")
struct SpiceInteractionFrameCorrelationTests {
    @Test func exactMarkerRequiresItsOwnCompletePresentationChain() {
        let assembler = Stage3InteractionFixture.assembler()
        Stage3InteractionFixture.recordPrelude(on: assembler)
        let marker = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
        assembler.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: marker, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        assembler.observeSelected(identity: marker, readyNs: Stage3InteractionFixture.ns(50), selectionNs: Stage3InteractionFixture.ns(60))
        assembler.observeCommitted(identity: marker, at: Stage3InteractionFixture.ns(70))
        _ = assembler.observePresented(identity: marker, at: Stage3InteractionFixture.ns(80))

        let record = assembler.finish()
        #expect(record.valid)
        #expect(record.invalidReason == nil)
        #expect(record.schemaVersion == 2)
        #expect(record.pairId == "pair-click")
        #expect(record.version == "v0.2.7")
        #expect(record.runId == "run-1")
        #expect(record.order == 1)
        #expect(record.actionClass == .click)
        #expect(record.token == Stage3InteractionFixture.token)
        #expect(record.scheduledNs == Stage3InteractionFixture.ns(0))
        #expect(record.hostInputNs == Stage3InteractionFixture.ns(10))
        #expect(record.sendStartedNs == Stage3InteractionFixture.ns(20))
        #expect(record.sendCompletedNs == Stage3InteractionFixture.ns(25))
        #expect(record.guestReceivedNs == 1)
        #expect(record.guestMarkerDrawnNs == 2)
        #expect(record.displayReceiveNs == Stage3InteractionFixture.ns(30))
        #expect(record.surfaceReadyNs == Stage3InteractionFixture.ns(40))
        #expect(record.selectedRevisionReadyNs == Stage3InteractionFixture.ns(50))
        #expect(record.selectionNs == Stage3InteractionFixture.ns(60))
        #expect(record.metalCommitNs == Stage3InteractionFixture.ns(70))
        #expect(record.presentedNs == Stage3InteractionFixture.ns(80))
        #expect(record.desktopGeneration == marker.desktopGeneration)
        #expect(record.displayChannelID == marker.displayChannelID)
        #expect(record.surfaceID == marker.surfaceID)
        #expect(record.surfaceGeneration == marker.surfaceGeneration)
        #expect(record.deliverySequence == marker.deliverySequence)
        #expect(record.frameRevision == marker.frameRevision)
        #expect(record.markerRevision == Stage3InteractionFixture.payload.markerRevision)
        #expect(record.markerChecksum == "9f9f5111")
    }

    @Test func unrelatedAndReplacementFramesCannotDonateEvidence() {
        let assembler = Stage3InteractionFixture.assembler()
        Stage3InteractionFixture.recordPrelude(on: assembler)
        let target = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
        let unrelated = Stage3InteractionFixture.identity(revision: 10, sequence: 41)
        assembler.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: target, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        assembler.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: unrelated, marker: false),
            sourceTiming: Stage3InteractionFixture.timing(receive: 31, ready: 41)
        )
        assembler.observeSelected(identity: unrelated, readyNs: Stage3InteractionFixture.ns(51), selectionNs: Stage3InteractionFixture.ns(61))
        assembler.observeCommitted(identity: unrelated, at: Stage3InteractionFixture.ns(71))
        _ = assembler.observePresented(identity: unrelated, at: Stage3InteractionFixture.ns(81))

        let record = assembler.finish()
        #expect(!record.valid)
        #expect(record.invalidReason == "marker_replaced_before_presented")
        #expect(record.deliverySequence == unrelated.deliverySequence)
        #expect(record.displayReceiveNs == Stage3InteractionFixture.ns(31))
        #expect(record.markerChecksum == nil)
        #expect(record.presentedNs == nil)
    }

    @Test func malformedAndIncompleteEvidenceFailsClosed() {
        do {
            let assembler = Stage3InteractionFixture.assembler()
            Stage3InteractionFixture.recordPrelude(on: assembler)
            let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
            assembler.observeFrame(
                snapshot: Stage3InteractionFixture.snapshot(
                    identity: identity,
                    placements: [
                        Stage3InteractionFixture.placement(x: 8, y: 8),
                        Stage3InteractionFixture.placement(x: 8, y: 20),
                    ]
                ),
                sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
            )
            #expect(assembler.finish().invalidReason == "ambiguous_marker_roi_2")
        }
        do {
            let assembler = Stage3InteractionFixture.assembler()
            Stage3InteractionFixture.recordPrelude(on: assembler)
            let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
            let snapshot = Stage3InteractionFixture.snapshot(identity: identity, marker: true)
            assembler.observeFrame(snapshot: snapshot, sourceTiming: nil)
            assembler.observeFrame(snapshot: snapshot, sourceTiming: nil)
            #expect(assembler.finish().invalidReason == "duplicate_frame_identity")
        }
        do {
            let assembler = Stage3InteractionFixture.assembler()
            Stage3InteractionFixture.recordPrelude(on: assembler)
            let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
            assembler.observeFrame(
                snapshot: Stage3InteractionFixture.snapshot(identity: identity, marker: true),
                sourceTiming: nil
            )
            assembler.observeSelected(identity: identity, readyNs: Stage3InteractionFixture.ns(50), selectionNs: Stage3InteractionFixture.ns(60))
            assembler.observeCommitted(identity: identity, at: Stage3InteractionFixture.ns(70))
            _ = assembler.observePresented(identity: identity, at: Stage3InteractionFixture.ns(80))
            let missingTiming = assembler.finish()
            #expect(!missingTiming.valid)
            #expect(missingTiming.invalidReason == "missing_display_receive")
            #expect(missingTiming.displayReceiveNs == nil)
        }
        do {
            let assembler = Stage3InteractionFixture.assembler()
            Stage3InteractionFixture.recordPrelude(on: assembler)
            let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
            assembler.observeFrame(
                snapshot: Stage3InteractionFixture.snapshot(identity: identity, marker: true),
                sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
            )
            assembler.observeSelected(identity: identity, readyNs: Stage3InteractionFixture.ns(50), selectionNs: Stage3InteractionFixture.ns(60))
            assembler.observeCommitted(identity: identity, at: Stage3InteractionFixture.ns(70))
            assembler.observePresentationDropped(identity: identity)
            let dropped = assembler.finish()
            #expect(!dropped.valid)
            #expect(dropped.invalidReason == "missing_presented")
            #expect(dropped.displayReceiveNs == Stage3InteractionFixture.ns(30))
            #expect(dropped.presentedNs == nil)
        }
        do {
            let assembler = Stage3InteractionFixture.assembler()
            Stage3InteractionFixture.recordPrelude(on: assembler)
            let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
            assembler.observeFrame(
                snapshot: Stage3InteractionFixture.snapshot(identity: identity, marker: true),
                sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
            )
            assembler.observeSelected(identity: identity, readyNs: Stage3InteractionFixture.ns(50), selectionNs: Stage3InteractionFixture.ns(60))
            assembler.observeCommitted(identity: identity, at: Stage3InteractionFixture.ns(70))
            #expect(assembler.finish().invalidReason == "missing_presented")
        }
    }

    @Test func observationBudgetAcceptsSixteenAndRejectsTheSeventeenth() {
        let withinBudget = Stage3InteractionFixture.assembler()
        Stage3InteractionFixture.recordPrelude(on: withinBudget)
        for sequence in 1...15 {
            let identity = Stage3InteractionFixture.identity(
                revision: UInt64(sequence),
                sequence: UInt64(sequence)
            )
            withinBudget.observeFrame(
                snapshot: Stage3InteractionFixture.snapshot(identity: identity, marker: false),
                sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
            )
        }
        let target = Stage3InteractionFixture.identity(revision: 16, sequence: 16)
        withinBudget.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: target, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        Stage3InteractionFixture.present(target, on: withinBudget)
        #expect(withinBudget.finish().valid)

        let assembler = Stage3InteractionFixture.assembler()
        Stage3InteractionFixture.recordPrelude(on: assembler)
        for sequence in 1...17 {
            let identity = Stage3InteractionFixture.identity(
                revision: UInt64(sequence),
                sequence: UInt64(sequence)
            )
            assembler.observeFrame(
                snapshot: Stage3InteractionFixture.snapshot(identity: identity, marker: false),
                sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
            )
        }
        #expect(assembler.finish().invalidReason == "too_many_observed_frames")
    }

    @Test func earlyDisplayAfterSendStartClampsSendCompletionDelta() {
        let assembler = Stage3InteractionFixture.assembler()
        assembler.recordHostInput(
            scheduledNs: Stage3InteractionFixture.ns(0),
            hostInputNs: Stage3InteractionFixture.ns(10),
            sendStartedNs: Stage3InteractionFixture.ns(20)
        )
        assembler.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
        let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
        assembler.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: identity, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        assembler.recordSendCompleted(at: Stage3InteractionFixture.ns(35))
        Stage3InteractionFixture.present(identity, on: assembler)
        let record = assembler.finish()
        #expect(record.valid)
        #expect(record.sendToDisplayNanoseconds == 0)

        let beforeSend = Stage3InteractionFixture.assembler()
        Stage3InteractionFixture.recordPrelude(on: beforeSend)
        beforeSend.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: identity, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 19, ready: 40)
        )
        Stage3InteractionFixture.present(identity, on: beforeSend)
        let ignored = beforeSend.finish()
        #expect(ignored.invalidReason == "missing_marker_checksum")
        #expect(ignored.displayReceiveNs == nil)
        #expect(ignored.markerChecksum == nil)
    }

    @Test func retiredLifecycleRejectsLateEvidenceButNewLifecycleCanComplete() {
        let assembler = Stage3InteractionFixture.assembler()
        Stage3InteractionFixture.recordPrelude(on: assembler)
        let old = Stage3InteractionFixture.identity(lifecycle: 4, revision: 9, sequence: 40)
        assembler.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: old, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        assembler.retireSurfaceLifecycle(displayChannelID: 2, surfaceID: 7, generation: 4)
        Stage3InteractionFixture.present(old, on: assembler)
        #expect(assembler.finish().invalidReason == "surface_lifecycle_retired")

        let current = Stage3InteractionFixture.assembler()
        Stage3InteractionFixture.recordPrelude(on: current)
        let next = Stage3InteractionFixture.identity(lifecycle: 5, revision: 1, sequence: 41)
        current.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: next, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        Stage3InteractionFixture.present(next, on: current)
        #expect(current.finish().valid)
    }

    @Test func duplicatePresentationEvidenceFailsClosed() {
        let assembler = Stage3InteractionFixture.assembler()
        Stage3InteractionFixture.recordPrelude(on: assembler)
        let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
        assembler.observeFrame(
            snapshot: Stage3InteractionFixture.snapshot(identity: identity, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        Stage3InteractionFixture.present(identity, on: assembler)
        _ = assembler.observePresented(identity: identity, at: Stage3InteractionFixture.ns(81))
        #expect(assembler.finish().invalidReason == "duplicate_presented")
    }

    @Test func presentedCallbackPublishesItsCapturedIdentityBeforeReturning() async throws {
        let diagnostics = SpicePresentationDiagnostics()
        let capture = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        try Stage3InteractionFixture.recordPrelude(on: capture)
        let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
        let presenter = SpiceInteractionPresenterID()
        diagnostics.recordInteractionFrameReceived(
            Stage3InteractionFixture.snapshot(identity: identity, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        diagnostics.recordInteractionSelected(.init(
            identity: identity,
            readyNanoseconds: Stage3InteractionFixture.ns(50),
            selectionNanoseconds: Stage3InteractionFixture.ns(60),
            presenterID: presenter
        ))
        diagnostics.recordInteractionCommitted(
            identity: identity,
            presenterID: presenter,
            at: Stage3InteractionFixture.ns(70)
        )

        let callbackReturned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            diagnostics.recordInteractionPresented(
                identity: identity,
                presenterID: presenter,
                at: Stage3InteractionFixture.ns(80)
            )
            callbackReturned.signal()
        }
        #expect(await waitForCorrelationSemaphore(callbackReturned) == .success)

        let record = try capture.finish()
        #expect(record.valid)
        #expect(record.presentedNs == Stage3InteractionFixture.ns(80))
        #expect(record.frameRevision == identity.frameRevision)
        #expect(record.deliverySequence == identity.deliverySequence)
    }

    @Test func onePresenterOwnsCaptureEvidenceWhileSiblingIsIgnored() async throws {
        let diagnostics = SpicePresentationDiagnostics()
        let capture = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        try Stage3InteractionFixture.recordPrelude(on: capture)
        let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
        let owner = SpiceInteractionPresenterID()
        let sibling = SpiceInteractionPresenterID()
        diagnostics.recordInteractionFrameReceived(
            Stage3InteractionFixture.snapshot(identity: identity, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        let ownerContext = SpiceInteractionPresentationContext(
            identity: identity,
            readyNanoseconds: Stage3InteractionFixture.ns(50),
            selectionNanoseconds: Stage3InteractionFixture.ns(60),
            presenterID: owner
        )
        diagnostics.recordInteractionSelected(ownerContext)
        diagnostics.recordInteractionCommitted(
            identity: identity,
            presenterID: owner,
            at: Stage3InteractionFixture.ns(70)
        )

        diagnostics.recordInteractionSelected(.init(
            identity: identity,
            readyNanoseconds: Stage3InteractionFixture.ns(51),
            selectionNanoseconds: Stage3InteractionFixture.ns(61),
            presenterID: sibling
        ))
        diagnostics.recordInteractionCommitted(
            identity: identity,
            presenterID: sibling,
            at: Stage3InteractionFixture.ns(71)
        )
        diagnostics.recordInteractionPresented(
            identity: identity,
            presenterID: sibling,
            at: Stage3InteractionFixture.ns(79)
        )
        diagnostics.recordInteractionPresented(
            identity: identity,
            presenterID: owner,
            at: Stage3InteractionFixture.ns(80)
        )
        #expect(try capture.finish().valid)

        let duplicateDiagnostics = SpicePresentationDiagnostics()
        let duplicate = try Stage3InteractionFixture.capture(
            diagnostics: duplicateDiagnostics,
            runID: "same-owner-duplicate"
        )
        try Stage3InteractionFixture.recordPrelude(on: duplicate)
        duplicateDiagnostics.recordInteractionFrameReceived(
            Stage3InteractionFixture.snapshot(identity: identity, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        duplicateDiagnostics.recordInteractionSelected(ownerContext)
        duplicateDiagnostics.recordInteractionCommitted(
            identity: identity,
            presenterID: owner,
            at: Stage3InteractionFixture.ns(70)
        )
        duplicateDiagnostics.recordInteractionSelected(ownerContext)
        duplicateDiagnostics.recordInteractionPresented(
            identity: identity,
            presenterID: owner,
            at: Stage3InteractionFixture.ns(80)
        )
        #expect(try duplicate.finish().invalidReason == "duplicate_selection_after_commit")
    }

    @Test func exactPresentationWaiterHandlesEarlyLateUnrelatedAndCancellation() async throws {
        let diagnostics = SpicePresentationDiagnostics()
        let early = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        try Stage3InteractionFixture.recordPrelude(on: early)
        let target = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
        diagnostics.recordInteractionFrameReceived(
            Stage3InteractionFixture.snapshot(identity: target, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        Stage3InteractionFixture.present(target, using: diagnostics)
        #expect(try await early.waitForExactPresentation() == target)
        _ = try early.finish()

        let late = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        try Stage3InteractionFixture.recordPrelude(on: late)
        let registered = DispatchSemaphore(value: 0)
        let wait = Task {
            try await late.waitForExactPresentation { registered.signal() }
        }
        #expect(await waitForCorrelationSemaphore(registered) == .success)
        let unrelated = Stage3InteractionFixture.identity(revision: 10, sequence: 41)
        diagnostics.recordInteractionFrameReceived(
            Stage3InteractionFixture.snapshot(identity: unrelated, marker: false),
            sourceTiming: Stage3InteractionFixture.timing(receive: 31, ready: 41)
        )
        diagnostics.recordInteractionSelected(.init(identity: unrelated, readyNanoseconds: Stage3InteractionFixture.ns(50), selectionNanoseconds: Stage3InteractionFixture.ns(60)))
        diagnostics.recordInteractionCommitted(identity: unrelated, at: Stage3InteractionFixture.ns(70))
        diagnostics.recordInteractionPresented(identity: unrelated, at: Stage3InteractionFixture.ns(80))
        await #expect(throws: SpiceInteractionTraceCollectionError.presentationWaitAlreadyRegistered) {
            try await late.waitForExactPresentation()
        }
        diagnostics.recordInteractionFrameReceived(
            Stage3InteractionFixture.snapshot(identity: target, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        Stage3InteractionFixture.present(target, using: diagnostics)
        #expect(try await wait.value == target)
        _ = try late.finish()

        let cancelled = try Stage3InteractionFixture.capture(diagnostics: diagnostics)
        let cancellationRegistered = DispatchSemaphore(value: 0)
        let cancelledWait = Task {
            try await cancelled.waitForExactPresentation {
                cancellationRegistered.signal()
            }
        }
        #expect(await waitForCorrelationSemaphore(cancellationRegistered) == .success)
        cancelledWait.cancel()
        await #expect(throws: CancellationError.self) { try await cancelledWait.value }
        let replacementRegistered = DispatchSemaphore(value: 0)
        let replacementWait = Task {
            try await cancelled.waitForExactPresentation {
                replacementRegistered.signal()
            }
        }
        #expect(await waitForCorrelationSemaphore(replacementRegistered) == .success)
        try Stage3InteractionFixture.recordPrelude(on: cancelled)
        diagnostics.recordInteractionFrameReceived(
            Stage3InteractionFixture.snapshot(identity: target, marker: true),
            sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
        )
        Stage3InteractionFixture.present(target, using: diagnostics)
        #expect(try await replacementWait.value == target)
        #expect(try cancelled.finish().valid)
    }

    @Test func finishAndPresentedCallbackAreLinearizedWithoutLateMutation() async throws {
        for iteration in 0..<64 {
            let diagnostics = SpicePresentationDiagnostics()
            let capture = try Stage3InteractionFixture.capture(
                diagnostics: diagnostics,
                runID: "race-\(iteration)"
            )
            try Stage3InteractionFixture.recordPrelude(on: capture)
            let identity = Stage3InteractionFixture.identity(revision: 9, sequence: 40)
            diagnostics.recordInteractionFrameReceived(
                Stage3InteractionFixture.snapshot(identity: identity, marker: true),
                sourceTiming: Stage3InteractionFixture.timing(receive: 30, ready: 40)
            )
            diagnostics.recordInteractionSelected(.init(identity: identity, readyNanoseconds: Stage3InteractionFixture.ns(50), selectionNanoseconds: Stage3InteractionFixture.ns(60)))
            diagnostics.recordInteractionCommitted(identity: identity, at: Stage3InteractionFixture.ns(70))
            let start = DispatchSemaphore(value: 0)
            let record = Mutex<SpiceInteractionTraceRecord?>(nil)
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                diagnostics.recordInteractionPresented(identity: identity, at: Stage3InteractionFixture.ns(80))
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                record.withLock { $0 = try? capture.finish() }
                group.leave()
            }
            start.signal()
            start.signal()
            #expect(await waitForCorrelationGroup(group) == .success)
            let finished = try #require(record.withLock { $0 })
            #expect(
                (finished.valid && finished.presentedNs == Stage3InteractionFixture.ns(80))
                    || (!finished.valid && finished.invalidReason == "missing_presented" && finished.presentedNs == nil)
            )
            diagnostics.recordInteractionPresented(identity: identity, at: Stage3InteractionFixture.ns(81))
            #expect(throws: SpiceInteractionTraceCollectionError.captureAlreadyFinished) {
                try capture.finish()
            }
        }
    }
}

enum Stage3InteractionFixture {
    static let token = "0123456789abcdef"
    static let checksum: UInt32 = 0x9f9f_5111
    static let payload = SpiceInteractionMarkerPayload(
        token: token,
        markerRevision: 77,
        checksum: checksum
    )
    static let width = 384
    static let height = 48
    static let bytesPerRow = width * 4 + 16
    private static let anchor = ContinuousClock().now
    private static let anchorNs: UInt64 = {
        guard let value = SpiceInteractionHostClock.nanoseconds(for: anchor) else {
            preconditionFailure("continuous clock instant must map to host nanoseconds")
        }
        return value
    }()

    static func ns(_ milliseconds: UInt64) -> UInt64 {
        anchorNs + milliseconds * 1_000_000
    }

    static func timing(receive: Int64, ready: Int64) -> DisplayFrameSourceTiming {
        DisplayFrameSourceTiming(
            messageReceivedAt: anchor.advanced(by: .milliseconds(receive)),
            surfaceReadyAt: anchor.advanced(by: .milliseconds(ready))
        )
    }

    static func identity(
        lifecycle: UInt64 = 4,
        revision: UInt64,
        sequence: UInt64
    ) -> SpiceInteractionFrameIdentity {
        SpiceInteractionFrameIdentity(
            desktopGeneration: 3,
            displayChannelID: 2,
            surfaceID: 7,
            surfaceGeneration: lifecycle,
            frameRevision: revision,
            deliverySequence: sequence
        )
    }

    static func placement(x: Int, y: Int) -> SpiceInteractionMarkerPlacement {
        SpiceInteractionMarkerPlacement(payload: payload, originX: x, originY: y)
    }

    static func snapshot(
        identity: SpiceInteractionFrameIdentity,
        marker: Bool
    ) -> SpiceDesktopSnapshot {
        snapshot(
            identity: identity,
            placements: marker ? [placement(x: 8, y: 8)] : []
        )
    }

    static func snapshot(
        identity: SpiceInteractionFrameIdentity,
        placements: [SpiceInteractionMarkerPlacement]
    ) -> SpiceDesktopSnapshot {
        let pixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: placements,
            frameWidth: width,
            frameHeight: height,
            bytesPerRow: bytesPerRow
        )
        let frame = SpiceFrame(
            surfaceID: identity.surfaceID,
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
                    surface: .init(
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
            pointerMode: .absolute,
            deliverySequence: identity.deliverySequence
        )
    }

    static func rendererFrame(
        lifecycle: UInt64,
        revision: UInt64,
        marker: Bool = true
    ) -> FrameSnapshot {
        let identity = self.identity(
            lifecycle: lifecycle,
            revision: revision,
            sequence: 0
        )
        let pixels = SpiceInteractionMarkerROIDetector.renderForTesting(
            placements: marker ? [placement(x: 8, y: 8)] : [],
            frameWidth: width,
            frameHeight: height,
            bytesPerRow: bytesPerRow
        )
        return FrameSnapshot(
            surfaceID: identity.surfaceID,
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            lifecycleGeneration: lifecycle,
            revision: revision,
            pixels: pixels,
            ioSurfaceFrame: nil
        )
    }

    static func assembler() -> SpiceInteractionTraceAssembler {
        SpiceInteractionTraceAssembler(
            pairId: "pair-click",
            version: "v0.2.7",
            runId: "run-1",
            order: 1,
            actionClass: .click,
            token: token,
            checksum: checksum
        )
    }

    static func capture(
        diagnostics: SpicePresentationDiagnostics,
        runID: String = "run-1"
    ) throws -> SpiceInteractionTraceCapture {
        try SpiceInteractionTraceCapture(
            presentationDiagnostics: diagnostics,
            pairId: "pair-click",
            version: "v0.2.7",
            runId: runID,
            order: 1,
            actionClass: .click,
            token: token,
            checksum: checksum
        )
    }

    static func recordPrelude(on assembler: SpiceInteractionTraceAssembler) {
        assembler.recordHostEvidence(
            scheduledNs: ns(0),
            hostInputNs: ns(10),
            sendStartedNs: ns(20),
            sendCompletedNs: ns(25)
        )
        assembler.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
    }

    static func recordPrelude(on capture: SpiceInteractionTraceCapture) throws {
        try capture.recordHostEvidence(
            scheduledNs: ns(0),
            hostInputNs: ns(10),
            sendStartedNs: ns(20),
            sendCompletedNs: ns(25)
        )
        try capture.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)
    }

    static func present(
        _ identity: SpiceInteractionFrameIdentity,
        on assembler: SpiceInteractionTraceAssembler
    ) {
        assembler.observeSelected(identity: identity, readyNs: ns(50), selectionNs: ns(60))
        assembler.observeCommitted(identity: identity, at: ns(70))
        _ = assembler.observePresented(identity: identity, at: ns(80))
    }

    static func present(
        _ identity: SpiceInteractionFrameIdentity,
        using diagnostics: SpicePresentationDiagnostics
    ) {
        diagnostics.recordInteractionSelected(.init(
            identity: identity,
            readyNanoseconds: ns(50),
            selectionNanoseconds: ns(60)
        ))
        diagnostics.recordInteractionCommitted(identity: identity, at: ns(70))
        diagnostics.recordInteractionPresented(identity: identity, at: ns(80))
    }
}

private func waitForCorrelationSemaphore(
    _ semaphore: DispatchSemaphore
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 1))
        }
    }
}

private func waitForCorrelationGroup(
    _ group: DispatchGroup
) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: group.wait(timeout: .now() + 2))
        }
    }
}
