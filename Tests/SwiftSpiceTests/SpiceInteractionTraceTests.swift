import Foundation
import Testing
@testable import SwiftSpice

@Suite("Interaction causal trace")
struct SpiceInteractionTraceTests {
    @Test func completeMarkerAndPresentedRevisionProduceCanonicalJSON() throws {
        let record = trace()

        #expect(record.valid)
        #expect(record.invalidReason == nil)

        let encoded = try JSONEncoder().encode(record)
        guard let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("trace encoding was not a JSON object")
            return
        }
        let requiredKeys: Set<String> = [
            "pair_id", "version", "run_id", "order", "action_class", "token",
            "scheduled_ns", "host_input_ns", "send_started_ns", "send_completed_ns",
            "motion_ack_ns", "guest_received_ns", "guest_marker_drawn_ns",
            "display_receive_ns", "surface_ready_ns", "selected_revision_ready_ns",
            "selection_ns", "metal_commit_ns", "presented_ns", "display_channel_id",
            "surface_id", "surface_generation",
            "desktop_generation", "frame_revision", "delivery_sequence",
            "marker_revision", "marker_checksum", "valid",
        ]
        #expect(Set(object.keys).isSuperset(of: requiredKeys))
        #expect(object["pair_id"] as? String == "pair-0001")
        #expect(object["action_class"] as? String == "motion")
        #expect(object["token"] as? String == "0123456789abcdef")
        #expect(object["valid"] as? Bool == true)
        #expect((object["display_channel_id"] as? NSNumber)?.uint8Value == 0)
        #expect((object["surface_id"] as? NSNumber)?.uint32Value == 1)
        #expect((object["marker_revision"] as? NSNumber)?.uint64Value == 77)

        let decoded = try JSONDecoder().decode(SpiceInteractionTraceRecord.self, from: encoded)
        #expect(decoded == record)
    }

    @Test func missingOrAmbiguousMarkerCanNeverBecomeValid() {
        let missingDraw = trace(guestMarkerDrawnNs: nil)
        #expect(!missingDraw.valid)
        #expect(missingDraw.invalidReason == "missing_guest_marker_drawn")

        let missingRevision = trace(markerRevision: nil)
        #expect(!missingRevision.valid)
        #expect(missingRevision.invalidReason == "missing_marker_revision")

        let ambiguous = trace(invalidReason: "ambiguous_marker")
        #expect(!ambiguous.valid)
        #expect(ambiguous.invalidReason == "ambiguous_marker")
    }

    @Test func validationKeepsGuestAndHostClockDomainsIndependent() {
        let record = trace(
            guestReceivedNs: 1,
            guestMarkerDrawnNs: 2
        )
        #expect(record.valid)

        let hostOrderViolation = trace(
            sendStartedNs: 31,
            sendCompletedNs: 30
        )
        #expect(!hostOrderViolation.valid)
        #expect(hostOrderViolation.invalidReason == "non_monotonic_timestamps")

        let guestOrderViolation = trace(
            guestReceivedNs: 2,
            guestMarkerDrawnNs: 1
        )
        #expect(!guestOrderViolation.valid)
        #expect(guestOrderViolation.invalidReason == "non_monotonic_timestamps")
    }

    @Test func earlyMotionAcknowledgmentIsBufferedAtSendCompletionLinearization() {
        let earlyButArmed = trace(
            sendStartedNs: 30,
            sendCompletedNs: 40,
            motionAckNs: 35
        )
        #expect(earlyButArmed.valid)
        #expect(earlyButArmed.invalidReason == nil)

        let beforeSend = trace(
            sendStartedNs: 30,
            sendCompletedNs: 40,
            motionAckNs: 29
        )
        #expect(!beforeSend.valid)
        #expect(beforeSend.invalidReason == "non_monotonic_timestamps")

        let afterPresentation = trace(
            sendStartedNs: 30,
            sendCompletedNs: 40,
            motionAckNs: 121
        )
        #expect(!afterPresentation.valid)
        #expect(afterPresentation.invalidReason == "non_monotonic_timestamps")
    }

    @Test func displayReceiveMayPrecedeSendCompletionRecording() {
        let receiveDuringSendContinuation = trace(
            sendStartedNs: 30,
            sendCompletedNs: 40,
            motionAckNs: 35,
            displayReceiveNs: 35
        )

        #expect(receiveDuringSendContinuation.valid)
        #expect(receiveDuringSendContinuation.invalidReason == nil)
        #expect(receiveDuringSendContinuation.sendToDisplayNanoseconds == 0)

        let receiveAfterSendCompletion = trace(
            sendStartedNs: 30,
            sendCompletedNs: 40,
            displayReceiveNs: 70
        )
        #expect(receiveAfterSendCompletion.valid)
        #expect(receiveAfterSendCompletion.sendToDisplayNanoseconds == 30)

        let receiveBeforeSendStarted = trace(
            sendStartedNs: 30,
            sendCompletedNs: 40,
            displayReceiveNs: 29
        )
        #expect(!receiveBeforeSendStarted.valid)
        #expect(receiveBeforeSendStarted.invalidReason == "non_monotonic_timestamps")
    }

    @Test func decodingCannotForgeDerivedValidity() throws {
        let encoded = try JSONEncoder().encode(trace())
        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            Issue.record("trace encoding was not a JSON object")
            return
        }
        object["valid"] = false
        object["invalid_reason"] = "missing_presented"
        let forged = try JSONSerialization.data(withJSONObject: object)

        do {
            _ = try JSONDecoder().decode(SpiceInteractionTraceRecord.self, from: forged)
            Issue.record("decoded JSON whose supplied validity contradicted its evidence")
        } catch DecodingError.dataCorrupted(_) {
            // Expected: decoded validity is checked against the evidence-derived value.
        } catch {
            Issue.record("unexpected decode error: \(error)")
        }
    }

    private func trace(
        sendStartedNs: UInt64? = 30,
        sendCompletedNs: UInt64? = 40,
        motionAckNs: UInt64? = 45,
        guestReceivedNs: UInt64? = 50,
        guestMarkerDrawnNs: UInt64? = 60,
        displayReceiveNs: UInt64? = 70,
        markerRevision: UInt64? = 77,
        invalidReason: String? = nil
    ) -> SpiceInteractionTraceRecord {
        SpiceInteractionTraceRecord(
            pairId: "pair-0001",
            version: "v0.3.0",
            runId: "run-0001",
            order: 1,
            actionClass: .motion,
            token: "0123456789abcdef",
            scheduledNs: 10,
            hostInputNs: 20,
            sendStartedNs: sendStartedNs,
            sendCompletedNs: sendCompletedNs,
            motionAckNs: motionAckNs,
            guestReceivedNs: guestReceivedNs,
            guestMarkerDrawnNs: guestMarkerDrawnNs,
            displayReceiveNs: displayReceiveNs,
            surfaceReadyNs: 80,
            selectedRevisionReadyNs: 90,
            selectionNs: 100,
            metalCommitNs: 110,
            presentedNs: 120,
            displayChannelID: 0,
            surfaceID: 1,
            surfaceGeneration: 7,
            desktopGeneration: 9,
            frameRevision: 76,
            deliverySequence: 1001,
            markerRevision: markerRevision,
            markerChecksum: "9f9f5111",
            invalidReason: invalidReason
        )
    }
}
