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
            "schema_version", "pair_id", "version", "run_id", "order",
            "action_class", "token",
            "scheduled_ns", "host_input_ns", "send_started_ns", "send_completed_ns",
            "motion_ack_ns", "guest_received_ns", "guest_marker_drawn_ns",
            "display_receive_ns", "surface_ready_ns", "selected_revision_ready_ns",
            "selection_ns", "metal_commit_ns", "presented_ns", "display_channel_id",
            "surface_id", "surface_generation",
            "desktop_generation", "frame_revision", "delivery_sequence",
            "marker_revision", "marker_checksum", "valid",
        ]
        #expect(Set(object.keys).isSuperset(of: requiredKeys))
        #expect((object["schema_version"] as? NSNumber)?.uint64Value == 2)
        #expect(record.schemaVersion == SpiceInteractionTraceRecord.currentSchemaVersion)
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

    @Test func decodingRejectsMissingOrUnsupportedSchemaTwo() throws {
        let encoded = try JSONEncoder().encode(trace())
        let canonical = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        for schemaMutation in [nil, 1, 3] as [Int?] {
            var object = canonical
            object["schema_version"] = schemaMutation
            let data = try JSONSerialization.data(withJSONObject: object)
            do {
                _ = try JSONDecoder().decode(SpiceInteractionTraceRecord.self, from: data)
                Issue.record("decoded unsupported schema mutation \(String(describing: schemaMutation))")
            } catch {
                switch (schemaMutation, error) {
                case (nil, DecodingError.keyNotFound(_, _)):
                    // Expected: schema_version is required.
                    break
                case (.some, DecodingError.dataCorrupted(_)):
                    // Expected: only normalized schema 2 is accepted.
                    break
                default:
                    Issue.record("unexpected schema decode error: \(error)")
                }
            }
        }
    }

    @Test func jsonlWriterPublishesCanonicalValidAndInvalidRecordsAtomically() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "interaction-jsonl-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "input-events.jsonl")
        let writer = SpiceInteractionTraceJSONLWriter(outputURL: output)
        let valid = trace()
        let invalid = trace(presentedNs: nil)

        try writer.append(valid)
        try writer.append(invalid)

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        let data = try Data(contentsOf: output)
        #expect(data.last == 0x0A)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        let records = try lines.map {
            try JSONDecoder().decode(SpiceInteractionTraceRecord.self, from: Data($0))
        }
        #expect(records == [valid, invalid])
        #expect(records[0].schemaVersion == 2)
        #expect(records[0].desktopGeneration == 9)
        #expect(records[0].displayChannelID == 0)
        #expect(records[0].surfaceID == 1)
        #expect(records[0].markerChecksum == "9f9f5111")
        #expect(records[0].valid)
        #expect(!records[1].valid)
        #expect(records[1].invalidReason == "missing_presented")
    }

    @Test func jsonlWriterFailuresCannotModifyExistingEvidence() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "interaction-jsonl-failure-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appending(path: "input-events.jsonl")
        let writer = SpiceInteractionTraceJSONLWriter(outputURL: output)
        try writer.append(trace())
        let original = try Data(contentsOf: output)

        let oversized = SpiceInteractionTraceRecord(
            pairId: String(repeating: "p", count: SpiceInteractionTraceJSONLWriter.maximumRecordBytes),
            version: "v0.3.1",
            runId: "run-0001",
            order: 2,
            actionClass: .click,
            token: "0123456789abcdef",
            invalidReason: "oversized_fixture"
        )
        do {
            try writer.append(oversized)
            Issue.record("oversized record was appended")
        } catch let error as SpiceInteractionTraceCollectionError {
            guard case .recordTooLarge = error else {
                Issue.record("unexpected oversized-record error: \(error)")
                return
            }
        }
        #expect(try Data(contentsOf: output) == original)

        let canonical = try JSONEncoder().encode(trace())
        var schemaOneObject = try #require(
            try JSONSerialization.jsonObject(with: canonical) as? [String: Any]
        )
        schemaOneObject["schema_version"] = 1
        var schemaOne = try JSONSerialization.data(withJSONObject: schemaOneObject)
        schemaOne.append(0x0A)
        for invalidExisting in [Data("{}\n".utf8), schemaOne] {
            try invalidExisting.write(to: output)
            do {
                try writer.append(trace())
                Issue.record("writer accepted malformed existing JSONL")
            } catch let error as SpiceInteractionTraceCollectionError {
                #expect(error == .invalidExistingJSONL)
            }
            #expect(try Data(contentsOf: output) == invalidExisting)
        }

        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let baseBoundaryPayload = try canonicalEncoder.encode(trace(pairId: "x"))
        let addedBytes = SpiceInteractionTraceJSONLWriter.maximumRecordBytes
            - baseBoundaryPayload.count
        try #require(addedBytes > 0)
        var boundaryPayload = try canonicalEncoder.encode(trace(
            pairId: String(repeating: "x", count: addedBytes + 1)
        ))
        try #require(
            boundaryPayload.count == SpiceInteractionTraceJSONLWriter.maximumRecordBytes
        )
        boundaryPayload.append(0x0A)
        try boundaryPayload.write(to: output)
        do {
            try writer.append(trace())
            Issue.record("writer accepted a 64 KiB payload plus its newline")
        } catch let error as SpiceInteractionTraceCollectionError {
            #expect(error == .invalidExistingJSONL)
        }
        #expect(try Data(contentsOf: output) == boundaryPayload)

        let symlinkTarget = directory.appending(path: "symlink-target")
        let symlinkOutput = directory.appending(path: "symlink-output.jsonl")
        try Data("sentinel".utf8).write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(
            atPath: symlinkOutput.path,
            withDestinationPath: symlinkTarget.path
        )
        let symlinkWriter = SpiceInteractionTraceJSONLWriter(outputURL: symlinkOutput)
        do {
            try symlinkWriter.append(trace())
            Issue.record("writer followed an output symlink")
        } catch let error as SpiceInteractionTraceCollectionError {
            #expect(error == .outputIsSymbolicLink)
        }
        #expect(try Data(contentsOf: symlinkTarget) == Data("sentinel".utf8))

        let lockOutput = directory.appending(path: "locked-output.jsonl")
        let lockSymlink = directory.appending(path: ".locked-output.jsonl.lock")
        try FileManager.default.createSymbolicLink(
            atPath: lockSymlink.path,
            withDestinationPath: symlinkTarget.path
        )
        let lockWriter = SpiceInteractionTraceJSONLWriter(outputURL: lockOutput)
        do {
            try lockWriter.append(trace())
            Issue.record("writer followed a lock-file symlink")
        } catch let error as SpiceInteractionTraceCollectionError {
            #expect(error == .outputIsSymbolicLink)
        }
        #expect(!FileManager.default.fileExists(atPath: lockOutput.path))
        #expect(try Data(contentsOf: symlinkTarget) == Data("sentinel".utf8))
    }

    @Test func captureRetriesTheSameRecordAfterAnAppendFailure() throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "interaction-capture-retry-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingDirectory = root.appending(path: "not-created", directoryHint: .isDirectory)
        let output = missingDirectory.appending(path: "input-events.jsonl")
        let writer = SpiceInteractionTraceJSONLWriter(outputURL: output)
        let diagnostics = SpicePresentationDiagnostics()
        let capture = try SpiceInteractionTraceCapture(
            presentationDiagnostics: diagnostics,
            writer: writer,
            pairId: "pair-retry",
            version: "v0.3.1",
            runId: "run-retry",
            order: 9,
            actionClass: .click,
            token: "0123456789abcdef",
            checksum: 0x9f9f_5111
        )
        try capture.recordHostEvidence(
            scheduledNs: 10,
            hostInputNs: 20,
            sendStartedNs: 30,
            sendCompletedNs: 40
        )
        try capture.recordGuestEvidence(receivedNs: 1, drawnNs: 2, markerRevision: 77)

        do {
            _ = try capture.finish(invalidReason: "missing_presented_fixture")
            Issue.record("capture unexpectedly wrote into a missing directory")
        } catch let error as SpiceInteractionTraceCollectionError {
            #expect(error == .outputDirectoryUnavailable)
        }
        try FileManager.default.createDirectory(
            at: missingDirectory,
            withIntermediateDirectories: true
        )

        let retried = try capture.finish(invalidReason: "ignored_on_cached_retry")
        #expect(!retried.valid)
        #expect(retried.invalidReason == "missing_presented_fixture")
        let lines = try Data(contentsOf: output).split(separator: 0x0A)
        #expect(lines.count == 1)
        let stored = try JSONDecoder().decode(
            SpiceInteractionTraceRecord.self,
            from: Data(try #require(lines.first))
        )
        #expect(stored == retried)

        do {
            try capture.recordGuestEvidence(receivedNs: 3, drawnNs: 4, markerRevision: 78)
            Issue.record("late evidence mutated a finished capture")
        } catch let error as SpiceInteractionTraceCollectionError {
            #expect(error == .captureAlreadyFinished)
        }
        do {
            _ = try capture.finish()
            Issue.record("finished capture appended a duplicate line")
        } catch let error as SpiceInteractionTraceCollectionError {
            #expect(error == .captureAlreadyFinished)
        }
        #expect(try Data(contentsOf: output).split(separator: 0x0A).count == 1)
    }

    private func trace(
        pairId: String = "pair-0001",
        sendStartedNs: UInt64? = 30,
        sendCompletedNs: UInt64? = 40,
        motionAckNs: UInt64? = 45,
        guestReceivedNs: UInt64? = 50,
        guestMarkerDrawnNs: UInt64? = 60,
        displayReceiveNs: UInt64? = 70,
        markerRevision: UInt64? = 77,
        presentedNs: UInt64? = 120,
        invalidReason: String? = nil
    ) -> SpiceInteractionTraceRecord {
        SpiceInteractionTraceRecord(
            pairId: pairId,
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
            presentedNs: presentedNs,
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
