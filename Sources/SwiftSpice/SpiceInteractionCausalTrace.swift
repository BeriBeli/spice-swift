import Foundation
import SpiceChannels
import Synchronization

package enum SpiceInteractionActionClass: String, Codable, Sendable, Equatable {
    case click
    case key
    case motion
}

/// A schema-2 causal observation. Guest timestamps are compared only with
/// guest timestamps because the guest and host monotonic clocks are unrelated.
package struct SpiceInteractionTraceRecord: Codable, Sendable, Equatable {
    package static let currentSchemaVersion: UInt64 = 2

    package let schemaVersion: UInt64
    package let pairId: String
    package let version: String
    package let runId: String
    package let order: UInt64
    package let actionClass: SpiceInteractionActionClass
    package let token: String
    package let scheduledNs: UInt64?
    package let hostInputNs: UInt64?
    package let sendStartedNs: UInt64?
    package let sendCompletedNs: UInt64?
    package let motionAckNs: UInt64?
    package let guestReceivedNs: UInt64?
    package let guestMarkerDrawnNs: UInt64?
    package let displayReceiveNs: UInt64?
    package let surfaceReadyNs: UInt64?
    package let selectedRevisionReadyNs: UInt64?
    package let selectionNs: UInt64?
    package let metalCommitNs: UInt64?
    package let presentedNs: UInt64?
    package let displayChannelID: UInt8?
    package let surfaceID: UInt32?
    package let surfaceGeneration: UInt64?
    package let desktopGeneration: UInt64?
    package let frameRevision: UInt64?
    package let deliverySequence: UInt64?
    package let markerRevision: UInt64?
    package let markerChecksum: String?
    package let valid: Bool
    package let invalidReason: String?

    package var sendToDisplayNanoseconds: UInt64? {
        guard let sendCompletedNs, let displayReceiveNs else { return nil }
        return displayReceiveNs - min(sendCompletedNs, displayReceiveNs)
    }

    package init(
        pairId: String,
        version: String,
        runId: String,
        order: UInt64,
        actionClass: SpiceInteractionActionClass,
        token: String,
        scheduledNs: UInt64? = nil,
        hostInputNs: UInt64? = nil,
        sendStartedNs: UInt64? = nil,
        sendCompletedNs: UInt64? = nil,
        motionAckNs: UInt64? = nil,
        guestReceivedNs: UInt64? = nil,
        guestMarkerDrawnNs: UInt64? = nil,
        displayReceiveNs: UInt64? = nil,
        surfaceReadyNs: UInt64? = nil,
        selectedRevisionReadyNs: UInt64? = nil,
        selectionNs: UInt64? = nil,
        metalCommitNs: UInt64? = nil,
        presentedNs: UInt64? = nil,
        displayChannelID: UInt8? = nil,
        surfaceID: UInt32? = nil,
        surfaceGeneration: UInt64? = nil,
        desktopGeneration: UInt64? = nil,
        frameRevision: UInt64? = nil,
        deliverySequence: UInt64? = nil,
        markerRevision: UInt64? = nil,
        markerChecksum: String? = nil,
        invalidReason externalInvalidReason: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.pairId = pairId
        self.version = version
        self.runId = runId
        self.order = order
        self.actionClass = actionClass
        self.token = token
        self.scheduledNs = scheduledNs
        self.hostInputNs = hostInputNs
        self.sendStartedNs = sendStartedNs
        self.sendCompletedNs = sendCompletedNs
        self.motionAckNs = motionAckNs
        self.guestReceivedNs = guestReceivedNs
        self.guestMarkerDrawnNs = guestMarkerDrawnNs
        self.displayReceiveNs = displayReceiveNs
        self.surfaceReadyNs = surfaceReadyNs
        self.selectedRevisionReadyNs = selectedRevisionReadyNs
        self.selectionNs = selectionNs
        self.metalCommitNs = metalCommitNs
        self.presentedNs = presentedNs
        self.displayChannelID = displayChannelID
        self.surfaceID = surfaceID
        self.surfaceGeneration = surfaceGeneration
        self.desktopGeneration = desktopGeneration
        self.frameRevision = frameRevision
        self.deliverySequence = deliverySequence
        self.markerRevision = markerRevision
        self.markerChecksum = markerChecksum
        invalidReason = Self.validationFailure(
            pairId: pairId,
            version: version,
            runId: runId,
            token: token,
            scheduledNs: scheduledNs,
            hostInputNs: hostInputNs,
            sendStartedNs: sendStartedNs,
            sendCompletedNs: sendCompletedNs,
            motionAckNs: motionAckNs,
            guestReceivedNs: guestReceivedNs,
            guestMarkerDrawnNs: guestMarkerDrawnNs,
            displayReceiveNs: displayReceiveNs,
            surfaceReadyNs: surfaceReadyNs,
            selectedRevisionReadyNs: selectedRevisionReadyNs,
            selectionNs: selectionNs,
            metalCommitNs: metalCommitNs,
            presentedNs: presentedNs,
            displayChannelID: displayChannelID,
            surfaceID: surfaceID,
            surfaceGeneration: surfaceGeneration,
            desktopGeneration: desktopGeneration,
            frameRevision: frameRevision,
            deliverySequence: deliverySequence,
            markerRevision: markerRevision,
            markerChecksum: markerChecksum,
            externalInvalidReason: externalInvalidReason
        )
        valid = invalidReason == nil
    }

    package init(from decoder: any Decoder) throws {
        let wire = try Wire(from: decoder)
        guard wire.schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unsupported interaction trace schema")
            )
        }
        let evidenceOnly = Self(
            pairId: wire.pairId,
            version: wire.version,
            runId: wire.runId,
            order: wire.order,
            actionClass: wire.actionClass,
            token: wire.token,
            scheduledNs: wire.scheduledNs,
            hostInputNs: wire.hostInputNs,
            sendStartedNs: wire.sendStartedNs,
            sendCompletedNs: wire.sendCompletedNs,
            motionAckNs: wire.motionAckNs,
            guestReceivedNs: wire.guestReceivedNs,
            guestMarkerDrawnNs: wire.guestMarkerDrawnNs,
            displayReceiveNs: wire.displayReceiveNs,
            surfaceReadyNs: wire.surfaceReadyNs,
            selectedRevisionReadyNs: wire.selectedRevisionReadyNs,
            selectionNs: wire.selectionNs,
            metalCommitNs: wire.metalCommitNs,
            presentedNs: wire.presentedNs,
            displayChannelID: wire.displayChannelID,
            surfaceID: wire.surfaceID,
            surfaceGeneration: wire.surfaceGeneration,
            desktopGeneration: wire.desktopGeneration,
            frameRevision: wire.frameRevision,
            deliverySequence: wire.deliverySequence,
            markerRevision: wire.markerRevision,
            markerChecksum: wire.markerChecksum
        )
        let derived = Self(
            pairId: wire.pairId,
            version: wire.version,
            runId: wire.runId,
            order: wire.order,
            actionClass: wire.actionClass,
            token: wire.token,
            scheduledNs: wire.scheduledNs,
            hostInputNs: wire.hostInputNs,
            sendStartedNs: wire.sendStartedNs,
            sendCompletedNs: wire.sendCompletedNs,
            motionAckNs: wire.motionAckNs,
            guestReceivedNs: wire.guestReceivedNs,
            guestMarkerDrawnNs: wire.guestMarkerDrawnNs,
            displayReceiveNs: wire.displayReceiveNs,
            surfaceReadyNs: wire.surfaceReadyNs,
            selectedRevisionReadyNs: wire.selectedRevisionReadyNs,
            selectionNs: wire.selectionNs,
            metalCommitNs: wire.metalCommitNs,
            presentedNs: wire.presentedNs,
            displayChannelID: wire.displayChannelID,
            surfaceID: wire.surfaceID,
            surfaceGeneration: wire.surfaceGeneration,
            desktopGeneration: wire.desktopGeneration,
            frameRevision: wire.frameRevision,
            deliverySequence: wire.deliverySequence,
            markerRevision: wire.markerRevision,
            markerChecksum: wire.markerChecksum,
            invalidReason: wire.invalidReason
        )
        guard wire.valid == derived.valid,
              wire.invalidReason == derived.invalidReason,
              !(evidenceOnly.valid
                  && wire.invalidReason.map(Self.isEvidenceFailure) == true) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "interaction trace validation fields are inconsistent")
            )
        }
        self = derived
    }

    package func encode(to encoder: any Encoder) throws {
        try Wire(self).encode(to: encoder)
    }

    private static func validationFailure(
        pairId: String,
        version: String,
        runId: String,
        token: String,
        scheduledNs: UInt64?,
        hostInputNs: UInt64?,
        sendStartedNs: UInt64?,
        sendCompletedNs: UInt64?,
        motionAckNs: UInt64?,
        guestReceivedNs: UInt64?,
        guestMarkerDrawnNs: UInt64?,
        displayReceiveNs: UInt64?,
        surfaceReadyNs: UInt64?,
        selectedRevisionReadyNs: UInt64?,
        selectionNs: UInt64?,
        metalCommitNs: UInt64?,
        presentedNs: UInt64?,
        displayChannelID: UInt8?,
        surfaceID: UInt32?,
        surfaceGeneration: UInt64?,
        desktopGeneration: UInt64?,
        frameRevision: UInt64?,
        deliverySequence: UInt64?,
        markerRevision: UInt64?,
        markerChecksum: String?,
        externalInvalidReason: String?
    ) -> String? {
        if let externalInvalidReason {
            return externalInvalidReason.isEmpty ? "invalid_reason_empty" : externalInvalidReason
        }
        guard !pairId.isEmpty else { return "invalid_pair_id" }
        guard !version.isEmpty else { return "invalid_version" }
        guard !runId.isEmpty else { return "invalid_run_id" }
        guard token.utf8.count == 16,
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return "invalid_token" }
        guard let scheduledNs else { return "missing_scheduled" }
        guard let hostInputNs else { return "missing_host_input" }
        guard let sendStartedNs else { return "missing_send_started" }
        guard let sendCompletedNs else { return "missing_send_completed" }
        guard let guestReceivedNs else { return "missing_guest_received" }
        guard let guestMarkerDrawnNs else { return "missing_guest_marker_drawn" }
        guard markerRevision != nil else { return "missing_marker_revision" }
        guard let markerChecksum else { return "missing_marker_checksum" }
        guard markerChecksum.utf8.count == 8,
              markerChecksum.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return "invalid_marker_checksum" }
        guard let displayReceiveNs else { return "missing_display_receive" }
        guard let surfaceReadyNs else { return "missing_surface_ready" }
        guard let selectedRevisionReadyNs else { return "missing_selected_revision_ready" }
        guard let selectionNs else { return "missing_selection" }
        guard let metalCommitNs else { return "missing_metal_commit" }
        guard let presentedNs else { return "missing_presented" }
        guard displayChannelID != nil else { return "missing_display_channel_id" }
        guard surfaceID != nil else { return "missing_surface_id" }
        guard surfaceGeneration != nil else { return "missing_surface_generation" }
        guard desktopGeneration != nil else { return "missing_desktop_generation" }
        guard frameRevision != nil else { return "missing_frame_revision" }
        guard deliverySequence != nil else { return "missing_delivery_sequence" }
        guard scheduledNs <= hostInputNs,
              hostInputNs <= sendStartedNs,
              sendStartedNs <= sendCompletedNs,
              sendStartedNs <= displayReceiveNs,
              displayReceiveNs <= surfaceReadyNs,
              surfaceReadyNs <= selectedRevisionReadyNs,
              selectedRevisionReadyNs <= selectionNs,
              selectionNs <= metalCommitNs,
              metalCommitNs <= presentedNs,
              guestReceivedNs <= guestMarkerDrawnNs
        else { return "non_monotonic_timestamps" }
        if let motionAckNs,
           !(sendStartedNs <= motionAckNs && motionAckNs <= presentedNs) {
            return "non_monotonic_timestamps"
        }
        return nil
    }

    private static func isEvidenceFailure(_ reason: String) -> Bool {
        switch reason {
        case "invalid_pair_id", "invalid_version", "invalid_run_id", "invalid_token",
             "missing_scheduled", "missing_host_input", "missing_send_started",
             "missing_send_completed", "missing_guest_received",
             "missing_guest_marker_drawn", "missing_marker_revision",
             "missing_marker_checksum", "invalid_marker_checksum",
             "missing_display_receive", "missing_surface_ready",
             "missing_selected_revision_ready", "missing_selection",
             "missing_metal_commit", "missing_presented",
             "missing_display_channel_id", "missing_surface_id",
             "missing_surface_generation", "missing_desktop_generation",
             "missing_frame_revision", "missing_delivery_sequence",
             "non_monotonic_timestamps":
            true
        default:
            false
        }
    }

    private struct Wire: Codable {
        let schemaVersion: UInt64
        let pairId: String
        let version: String
        let runId: String
        let order: UInt64
        let actionClass: SpiceInteractionActionClass
        let token: String
        let scheduledNs: UInt64?
        let hostInputNs: UInt64?
        let sendStartedNs: UInt64?
        let sendCompletedNs: UInt64?
        let motionAckNs: UInt64?
        let guestReceivedNs: UInt64?
        let guestMarkerDrawnNs: UInt64?
        let displayReceiveNs: UInt64?
        let surfaceReadyNs: UInt64?
        let selectedRevisionReadyNs: UInt64?
        let selectionNs: UInt64?
        let metalCommitNs: UInt64?
        let presentedNs: UInt64?
        let displayChannelID: UInt8?
        let surfaceID: UInt32?
        let surfaceGeneration: UInt64?
        let desktopGeneration: UInt64?
        let frameRevision: UInt64?
        let deliverySequence: UInt64?
        let markerRevision: UInt64?
        let markerChecksum: String?
        let valid: Bool
        let invalidReason: String?

        init(_ record: SpiceInteractionTraceRecord) {
            schemaVersion = record.schemaVersion
            pairId = record.pairId
            version = record.version
            runId = record.runId
            order = record.order
            actionClass = record.actionClass
            token = record.token
            scheduledNs = record.scheduledNs
            hostInputNs = record.hostInputNs
            sendStartedNs = record.sendStartedNs
            sendCompletedNs = record.sendCompletedNs
            motionAckNs = record.motionAckNs
            guestReceivedNs = record.guestReceivedNs
            guestMarkerDrawnNs = record.guestMarkerDrawnNs
            displayReceiveNs = record.displayReceiveNs
            surfaceReadyNs = record.surfaceReadyNs
            selectedRevisionReadyNs = record.selectedRevisionReadyNs
            selectionNs = record.selectionNs
            metalCommitNs = record.metalCommitNs
            presentedNs = record.presentedNs
            displayChannelID = record.displayChannelID
            surfaceID = record.surfaceID
            surfaceGeneration = record.surfaceGeneration
            desktopGeneration = record.desktopGeneration
            frameRevision = record.frameRevision
            deliverySequence = record.deliverySequence
            markerRevision = record.markerRevision
            markerChecksum = record.markerChecksum
            valid = record.valid
            invalidReason = record.invalidReason
        }

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case pairId = "pair_id"
            case version
            case runId = "run_id"
            case order
            case actionClass = "action_class"
            case token
            case scheduledNs = "scheduled_ns"
            case hostInputNs = "host_input_ns"
            case sendStartedNs = "send_started_ns"
            case sendCompletedNs = "send_completed_ns"
            case motionAckNs = "motion_ack_ns"
            case guestReceivedNs = "guest_received_ns"
            case guestMarkerDrawnNs = "guest_marker_drawn_ns"
            case displayReceiveNs = "display_receive_ns"
            case surfaceReadyNs = "surface_ready_ns"
            case selectedRevisionReadyNs = "selected_revision_ready_ns"
            case selectionNs = "selection_ns"
            case metalCommitNs = "metal_commit_ns"
            case presentedNs = "presented_ns"
            case displayChannelID = "display_channel_id"
            case surfaceID = "surface_id"
            case surfaceGeneration = "surface_generation"
            case desktopGeneration = "desktop_generation"
            case frameRevision = "frame_revision"
            case deliverySequence = "delivery_sequence"
            case markerRevision = "marker_revision"
            case markerChecksum = "marker_checksum"
            case valid
            case invalidReason = "invalid_reason"
        }
    }
}

package enum SpiceInteractionTraceCollectionError: Error, Sendable, Equatable {
    case captureAlreadyActive
    case captureAlreadyFinished
    case presentationWaitAlreadyRegistered
}

/// A single cancellation-safe, non-polling wait for the exact presentation
/// accepted by an active capture. Continuations are always resumed lock-free.
package final class SpiceInteractionPresentationWaiter: @unchecked Sendable {
    private enum Waiting: @unchecked Sendable {
        case reserved(id: UUID, cancelled: Bool)
        case registered(id: UUID, CheckedContinuation<SpiceInteractionFrameIdentity, any Error>)
    }

    package struct Resumption: @unchecked Sendable {
        fileprivate let continuation: CheckedContinuation<SpiceInteractionFrameIdentity, any Error>
        fileprivate let result: Result<SpiceInteractionFrameIdentity, any Error>

        package func resume() { continuation.resume(with: result) }
    }

    private enum Phase: @unchecked Sendable {
        case active(Waiting?)
        case completed(SpiceInteractionFrameIdentity)
        case finished
    }

    private let phase = Mutex<Phase>(.active(nil))

    package func wait(
        waiterRegistered: (@Sendable () -> Void)? = nil
    ) async throws -> SpiceInteractionFrameIdentity {
        let id = UUID()
        if let immediate = try reserve(id) { return immediate }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let (registered, resumption) = register(
                    id,
                    continuation: continuation,
                    taskIsCancelled: Task.isCancelled
                )
                if registered { waiterRegistered?() }
                resumption?.resume()
            }
        } onCancel: {
            self.cancel(id)?.resume()
        }
    }

    package func prepareCompletion(
        _ identity: SpiceInteractionFrameIdentity
    ) -> Resumption? {
        phase.withLock { phase in
            guard case let .active(waiting) = phase else { return nil }
            phase = .completed(identity)
            guard case let .registered(_, continuation) = waiting else { return nil }
            return Resumption(continuation: continuation, result: .success(identity))
        }
    }

    package func prepareFinish() -> Resumption? {
        phase.withLock { phase in
            guard case let .active(waiting) = phase else { return nil }
            phase = .finished
            guard case let .registered(_, continuation) = waiting else { return nil }
            return Resumption(
                continuation: continuation,
                result: .failure(SpiceInteractionTraceCollectionError.captureAlreadyFinished)
            )
        }
    }

    private func reserve(_ id: UUID) throws -> SpiceInteractionFrameIdentity? {
        try phase.withLock { phase in
            switch phase {
            case let .completed(identity):
                return identity
            case .finished:
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            case let .active(waiting):
                guard waiting == nil else {
                    throw SpiceInteractionTraceCollectionError.presentationWaitAlreadyRegistered
                }
                phase = .active(.reserved(id: id, cancelled: false))
                return nil
            }
        }
    }

    private func register(
        _ id: UUID,
        continuation: CheckedContinuation<SpiceInteractionFrameIdentity, any Error>,
        taskIsCancelled: Bool
    ) -> (Bool, Resumption?) {
        phase.withLock { phase in
            switch phase {
            case let .completed(identity):
                return (false, Resumption(continuation: continuation, result: .success(identity)))
            case .finished:
                return (
                    false,
                    Resumption(
                        continuation: continuation,
                        result: .failure(SpiceInteractionTraceCollectionError.captureAlreadyFinished)
                    )
                )
            case let .active(waiting):
                guard case let .reserved(reservedID, wasCancelled) = waiting,
                      reservedID == id else {
                    return (
                        false,
                        Resumption(
                            continuation: continuation,
                            result: .failure(SpiceInteractionTraceCollectionError.captureAlreadyFinished)
                        )
                    )
                }
                if wasCancelled || taskIsCancelled {
                    phase = .active(nil)
                    return (
                        false,
                        Resumption(continuation: continuation, result: .failure(CancellationError()))
                    )
                }
                phase = .active(.registered(id: id, continuation))
                return (true, nil)
            }
        }
    }

    private func cancel(_ id: UUID) -> Resumption? {
        phase.withLock { phase in
            guard case let .active(waiting) = phase else { return nil }
            switch waiting {
            case let .reserved(reservedID, _) where reservedID == id:
                phase = .active(.reserved(id: id, cancelled: true))
                return nil
            case let .registered(registeredID, continuation) where registeredID == id:
                phase = .active(nil)
                return Resumption(continuation: continuation, result: .failure(CancellationError()))
            default:
                return nil
            }
        }
    }
}

package final class SpiceInteractionTraceAssembler: Sendable {
    private struct SurfaceLifecycleKey: Sendable, Hashable {
        let displayChannelID: UInt8
        let surfaceID: UInt32
    }

    private struct FrameObservation: Sendable {
        let payload: SpiceInteractionMarkerPayload?
        let displayReceiveNs: UInt64?
        let surfaceReadyNs: UInt64?
    }

    private struct State: Sendable {
        var scheduledNs: UInt64?
        var hostInputNs: UInt64?
        var sendStartedNs: UInt64?
        var sendCompletedNs: UInt64?
        var motionAckNs: UInt64?
        var guestReceivedNs: UInt64?
        var guestMarkerDrawnNs: UInt64?
        var guestMarkerRevision: UInt64?
        var frames: [SpiceInteractionFrameIdentity: FrameObservation] = [:]
        var selectedIdentity: SpiceInteractionFrameIdentity?
        var selectedFrame: FrameObservation?
        var selectedRevisionReadyNs: UInt64?
        var selectionNs: UInt64?
        var committedIdentity: SpiceInteractionFrameIdentity?
        var metalCommitNs: UInt64?
        var droppedPresentationIdentity: SpiceInteractionFrameIdentity?
        var presentedNs: UInt64?
        var markerReplacementObserved = false
        var invalidReason: String?
        var retiredDesktopGeneration: UInt64?
        var retiredSurfaceGenerations: [SurfaceLifecycleKey: UInt64] = [:]
    }

    private let pairId: String
    private let version: String
    private let runId: String
    private let order: UInt64
    private let actionClass: SpiceInteractionActionClass
    private let token: String
    private let checksum: UInt32
    private let presentationWaiter: SpiceInteractionPresentationWaiter?
    private let state = Mutex(State())

    package init(
        pairId: String,
        version: String,
        runId: String,
        order: UInt64,
        actionClass: SpiceInteractionActionClass,
        token: String,
        checksum: UInt32,
        presentationWaiter: SpiceInteractionPresentationWaiter? = nil
    ) {
        self.pairId = pairId
        self.version = version
        self.runId = runId
        self.order = order
        self.actionClass = actionClass
        self.token = token
        self.checksum = checksum
        self.presentationWaiter = presentationWaiter
    }

    package func recordHostEvidence(
        scheduledNs: UInt64,
        hostInputNs: UInt64,
        sendStartedNs: UInt64,
        sendCompletedNs: UInt64,
        motionAckNs: UInt64? = nil
    ) {
        recordHostInput(
            scheduledNs: scheduledNs,
            hostInputNs: hostInputNs,
            sendStartedNs: sendStartedNs
        )
        recordSendCompleted(at: sendCompletedNs, motionAckNs: motionAckNs)
    }

    package func recordHostInput(
        scheduledNs: UInt64,
        hostInputNs: UInt64,
        sendStartedNs: UInt64
    ) {
        state.withLock { state in
            guard state.hostInputNs == nil else {
                state.invalidReason = state.invalidReason ?? "duplicate_host_evidence"
                return
            }
            state.scheduledNs = scheduledNs
            state.hostInputNs = hostInputNs
            state.sendStartedNs = sendStartedNs
        }
    }

    package func recordSendCompleted(at nanoseconds: UInt64, motionAckNs: UInt64? = nil) {
        state.withLock { state in
            guard state.hostInputNs != nil, state.sendStartedNs != nil else {
                state.invalidReason = state.invalidReason ?? "send_completion_before_host_evidence"
                return
            }
            guard state.sendCompletedNs == nil else {
                state.invalidReason = state.invalidReason ?? "duplicate_send_completion"
                return
            }
            state.sendCompletedNs = nanoseconds
            if let motionAckNs {
                if let existing = state.motionAckNs, existing != motionAckNs {
                    state.invalidReason = state.invalidReason ?? "duplicate_motion_ack"
                } else {
                    state.motionAckNs = motionAckNs
                }
            }
        }
    }

    package func recordMotionAcknowledged(at nanoseconds: UInt64) {
        state.withLock { state in
            guard state.motionAckNs == nil else {
                state.invalidReason = state.invalidReason ?? "duplicate_motion_ack"
                return
            }
            state.motionAckNs = nanoseconds
        }
    }

    package func recordGuestEvidence(
        receivedNs: UInt64,
        drawnNs: UInt64,
        markerRevision: UInt64
    ) {
        state.withLock { state in
            guard state.guestReceivedNs == nil else {
                state.invalidReason = state.invalidReason ?? "duplicate_guest_evidence"
                return
            }
            state.guestReceivedNs = receivedNs
            state.guestMarkerDrawnNs = drawnNs
            state.guestMarkerRevision = markerRevision
        }
    }

    package func observeFrame(
        snapshot: SpiceDesktopSnapshot,
        sourceTiming: DisplayFrameSourceTiming?
    ) {
        guard let identity = snapshot.interactionFrameIdentity else { return }
        let displayReceiveNs = sourceTiming.flatMap {
            SpiceInteractionHostClock.nanoseconds(for: $0.messageReceivedAt)
        }
        let surfaceReadyNs = sourceTiming.flatMap {
            SpiceInteractionHostClock.nanoseconds(for: $0.surfaceReadyAt)
        }
        guard let sendStartedNs = state.withLock({ state -> UInt64? in
            guard state.hostInputNs != nil, state.presentedNs == nil else { return nil }
            return state.sendStartedNs
        }), displayReceiveNs.map({ $0 >= sendStartedNs }) ?? true else {
            return
        }
        let detection = SpiceInteractionMarkerROIDetector.detect(
            in: snapshot,
            expectedToken: token,
            expectedChecksum: checksum
        )
        state.withLock { state in
            guard state.hostInputNs != nil,
                  state.presentedNs == nil,
                  let currentSendStartedNs = state.sendStartedNs,
                  displayReceiveNs.map({ $0 >= currentSendStartedNs }) ?? true
            else { return }
            if let retired = state.retiredDesktopGeneration,
               identity.desktopGeneration <= retired {
                state.invalidReason = state.invalidReason ?? "retired_generation_frame"
                return
            }
            if Self.isRetiredSurface(identity, state: state) {
                state.invalidReason = state.invalidReason ?? "surface_lifecycle_retired"
                return
            }
            guard state.frames[identity] == nil else {
                state.invalidReason = state.invalidReason ?? "duplicate_frame_identity"
                return
            }
            guard state.frames.count < 16 else {
                state.invalidReason = state.invalidReason ?? "too_many_observed_frames"
                return
            }
            switch detection {
            case .none:
                state.frames[identity] = FrameObservation(
                    payload: nil,
                    displayReceiveNs: displayReceiveNs,
                    surfaceReadyNs: surfaceReadyNs
                )
            case let .ambiguous(matchCount):
                state.frames[identity] = FrameObservation(
                    payload: nil,
                    displayReceiveNs: displayReceiveNs,
                    surfaceReadyNs: surfaceReadyNs
                )
                state.invalidReason = state.invalidReason ?? "ambiguous_marker_roi_\(matchCount)"
            case let .exact(payload, _):
                state.frames[identity] = FrameObservation(
                    payload: payload,
                    displayReceiveNs: displayReceiveNs,
                    surfaceReadyNs: surfaceReadyNs
                )
            }
        }
    }

    package func observeSelected(
        identity: SpiceInteractionFrameIdentity,
        readyNs: UInt64,
        selectionNs: UInt64
    ) {
        state.withLock { state in
            let previousIdentity = state.selectedIdentity
            let previousMarker = state.selectedFrame?.payload
            if state.presentedNs != nil {
                if previousIdentity == identity {
                    state.invalidReason = state.invalidReason ?? "duplicate_selection_after_presented"
                }
                return
            }
            if state.metalCommitNs != nil, previousIdentity == identity {
                if state.droppedPresentationIdentity == identity || previousMarker == nil {
                    state.committedIdentity = nil
                    state.metalCommitNs = nil
                    state.droppedPresentationIdentity = nil
                } else {
                    state.invalidReason = state.invalidReason ?? "duplicate_selection_after_commit"
                    return
                }
            }
            if previousIdentity != nil, previousIdentity != identity {
                state.committedIdentity = nil
                state.metalCommitNs = nil
                state.droppedPresentationIdentity = nil
            }
            state.selectedIdentity = identity
            state.selectedRevisionReadyNs = readyNs
            state.selectionNs = selectionNs
            if let retired = state.retiredDesktopGeneration,
               identity.desktopGeneration <= retired {
                state.selectedFrame = nil
                state.invalidReason = state.invalidReason ?? "retired_generation_selection"
                return
            }
            if Self.isRetiredSurface(identity, state: state) {
                state.selectedFrame = nil
                state.invalidReason = state.invalidReason ?? "surface_lifecycle_retired"
                return
            }
            guard let selectedFrame = state.frames[identity] else {
                state.selectedFrame = nil
                if previousMarker != nil
                    || state.frames.values.contains(where: { $0.payload != nil }) {
                    state.markerReplacementObserved = true
                }
                return
            }
            state.selectedFrame = selectedFrame
            if previousMarker != nil,
               selectedFrame.payload == nil,
               previousIdentity != identity {
                state.markerReplacementObserved = true
                return
            }
            if selectedFrame.payload == nil,
               state.frames.values.contains(where: { $0.payload != nil }) {
                state.markerReplacementObserved = true
            }
        }
    }

    package func canBindPresentationOwner(
        identity: SpiceInteractionFrameIdentity
    ) -> Bool {
        state.withLock { state in
            state.hostInputNs != nil
                && state.presentedNs == nil
                && state.frames[identity] != nil
        }
    }

    package func observeCommitted(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    ) {
        state.withLock { state in
            guard state.selectedIdentity == identity else { return }
            if state.committedIdentity == identity {
                state.invalidReason = state.invalidReason ?? "duplicate_metal_commit"
                return
            }
            if let retired = state.retiredDesktopGeneration,
               identity.desktopGeneration <= retired {
                state.invalidReason = state.invalidReason ?? "commit_after_generation_retired"
                return
            }
            if Self.isRetiredSurface(identity, state: state) {
                state.invalidReason = state.invalidReason ?? "surface_lifecycle_retired"
                return
            }
            state.committedIdentity = identity
            state.metalCommitNs = nanoseconds
        }
    }

    package func observePresented(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    ) -> SpiceInteractionPresentationWaiter.Resumption? {
        let accepted = state.withLock { state -> Bool in
            guard state.selectedIdentity == identity else { return false }
            guard let marker = state.selectedFrame?.payload,
                  marker.token == token,
                  marker.checksum == checksum else { return false }
            if state.presentedNs != nil {
                state.invalidReason = state.invalidReason ?? "duplicate_presented"
                return false
            }
            guard state.committedIdentity == identity,
                  state.metalCommitNs != nil else {
                state.invalidReason = state.invalidReason ?? "presented_before_commit"
                return false
            }
            if let retired = state.retiredDesktopGeneration,
               identity.desktopGeneration <= retired {
                state.invalidReason = state.invalidReason ?? "presented_after_generation_retired"
                return false
            }
            if Self.isRetiredSurface(identity, state: state) {
                state.invalidReason = state.invalidReason ?? "surface_lifecycle_retired"
                return false
            }
            state.presentedNs = nanoseconds
            state.droppedPresentationIdentity = nil
            state.markerReplacementObserved = false
            return true
        }
        guard accepted else { return nil }
        return presentationWaiter?.prepareCompletion(identity)
    }

    package func observePresentationDropped(identity: SpiceInteractionFrameIdentity) {
        state.withLock { state in
            guard state.presentedNs == nil,
                  state.selectedIdentity == identity,
                  state.committedIdentity == identity,
                  state.metalCommitNs != nil else { return }
            state.droppedPresentationIdentity = identity
        }
    }

    package func retireSurfaceLifecycle(
        displayChannelID: UInt8,
        surfaceID: UInt32,
        generation: UInt64
    ) {
        state.withLock { state in
            let key = SurfaceLifecycleKey(
                displayChannelID: displayChannelID,
                surfaceID: surfaceID
            )
            state.retiredSurfaceGenerations[key] = max(
                state.retiredSurfaceGenerations[key] ?? 0,
                generation
            )
            let selectedWasRetired = state.selectedIdentity.map {
                $0.displayChannelID == displayChannelID
                    && $0.surfaceID == surfaceID
                    && $0.surfaceGeneration <= generation
            } ?? false
            let markerWasRetired = state.frames.contains {
                $0.value.payload != nil
                    && $0.key.displayChannelID == displayChannelID
                    && $0.key.surfaceID == surfaceID
                    && $0.key.surfaceGeneration <= generation
            }
            if state.presentedNs == nil, selectedWasRetired || markerWasRetired {
                state.invalidReason = state.invalidReason ?? "surface_lifecycle_retired"
            }
            state.frames = state.frames.filter {
                $0.key.displayChannelID != displayChannelID
                    || $0.key.surfaceID != surfaceID
                    || $0.key.surfaceGeneration > generation
            }
        }
    }

    package func retireDesktopGeneration(_ generation: UInt64) {
        state.withLock { state in
            state.retiredDesktopGeneration = max(
                state.retiredDesktopGeneration ?? 0,
                generation
            )
            let hasRetiredMarker = state.frames.contains {
                $0.value.payload != nil && $0.key.desktopGeneration <= generation
            }
            if hasRetiredMarker, state.presentedNs == nil {
                state.invalidReason = state.invalidReason ?? "desktop_generation_retired"
            }
            state.frames = state.frames.filter { $0.key.desktopGeneration > generation }
        }
    }

    private static func isRetiredSurface(
        _ identity: SpiceInteractionFrameIdentity,
        state: State
    ) -> Bool {
        let key = SurfaceLifecycleKey(
            displayChannelID: identity.displayChannelID,
            surfaceID: identity.surfaceID
        )
        guard let retired = state.retiredSurfaceGenerations[key] else { return false }
        return identity.surfaceGeneration <= retired
    }

    package func finish(invalidReason: String? = nil) -> SpiceInteractionTraceRecord {
        state.withLock { state in
            let identity = state.selectedIdentity
            let selectedFrame = state.selectedFrame
            let candidatePayload = selectedFrame?.payload
            let markerRevision: UInt64?
            if let guestRevision = state.guestMarkerRevision,
               let candidatePayload,
               guestRevision != candidatePayload.markerRevision {
                markerRevision = candidatePayload.markerRevision
                state.invalidReason = state.invalidReason ?? "guest_marker_revision_mismatch"
            } else {
                markerRevision = candidatePayload?.markerRevision ?? state.guestMarkerRevision
            }
            return SpiceInteractionTraceRecord(
                pairId: pairId,
                version: version,
                runId: runId,
                order: order,
                actionClass: actionClass,
                token: token,
                scheduledNs: state.scheduledNs,
                hostInputNs: state.hostInputNs,
                sendStartedNs: state.sendStartedNs,
                sendCompletedNs: state.sendCompletedNs,
                motionAckNs: state.motionAckNs,
                guestReceivedNs: state.guestReceivedNs,
                guestMarkerDrawnNs: state.guestMarkerDrawnNs,
                displayReceiveNs: selectedFrame?.displayReceiveNs,
                surfaceReadyNs: selectedFrame?.surfaceReadyNs,
                selectedRevisionReadyNs: state.selectedRevisionReadyNs,
                selectionNs: state.selectionNs,
                metalCommitNs: state.metalCommitNs,
                presentedNs: state.presentedNs,
                displayChannelID: identity?.displayChannelID,
                surfaceID: identity?.surfaceID,
                surfaceGeneration: identity?.surfaceGeneration,
                desktopGeneration: identity?.desktopGeneration,
                frameRevision: identity?.frameRevision,
                deliverySequence: identity?.deliverySequence,
                markerRevision: markerRevision,
                markerChecksum: candidatePayload.map { String(format: "%08x", $0.checksum) },
                invalidReason: invalidReason
                    ?? state.invalidReason
                    ?? (state.markerReplacementObserved ? "marker_replaced_before_presented" : nil)
                    ?? (state.hostInputNs == nil ? "missing_input_event" : nil)
            )
        }
    }
}

/// An in-memory capture only. Stage3b deliberately does not perform file I/O;
/// a later overlay layer owns serialization and process orchestration.
package final class SpiceInteractionTraceCapture: Sendable {
    private enum Phase: Sendable {
        case active
        case finished
    }

    private let presentationDiagnostics: SpicePresentationDiagnostics
    private let assembler: SpiceInteractionTraceAssembler
    private let presentationWaiter: SpiceInteractionPresentationWaiter
    private let phase = Mutex<Phase>(.active)

    package convenience init(
        session: SpiceSession,
        pairId: String,
        version: String,
        runId: String,
        order: UInt64,
        actionClass: SpiceInteractionActionClass,
        token: String,
        checksum: UInt32
    ) throws {
        try self.init(
            presentationDiagnostics: session.presentationDiagnostics,
            pairId: pairId,
            version: version,
            runId: runId,
            order: order,
            actionClass: actionClass,
            token: token,
            checksum: checksum
        )
    }

    package init(
        presentationDiagnostics: SpicePresentationDiagnostics,
        pairId: String,
        version: String,
        runId: String,
        order: UInt64,
        actionClass: SpiceInteractionActionClass,
        token: String,
        checksum: UInt32
    ) throws {
        self.presentationDiagnostics = presentationDiagnostics
        let waiter = SpiceInteractionPresentationWaiter()
        presentationWaiter = waiter
        assembler = SpiceInteractionTraceAssembler(
            pairId: pairId,
            version: version,
            runId: runId,
            order: order,
            actionClass: actionClass,
            token: token,
            checksum: checksum,
            presentationWaiter: waiter
        )
        guard presentationDiagnostics.installInteractionTraceAssembler(assembler) else {
            throw SpiceInteractionTraceCollectionError.captureAlreadyActive
        }
    }

    deinit {
        presentationDiagnostics.removeInteractionTraceAssembler(assembler)
        presentationWaiter.prepareFinish()?.resume()
    }

    package func recordHostEvidence(
        scheduledNs: UInt64,
        hostInputNs: UInt64,
        sendStartedNs: UInt64,
        sendCompletedNs: UInt64,
        motionAckNs: UInt64? = nil
    ) throws {
        try withActiveCapture {
            assembler.recordHostEvidence(
                scheduledNs: scheduledNs,
                hostInputNs: hostInputNs,
                sendStartedNs: sendStartedNs,
                sendCompletedNs: sendCompletedNs,
                motionAckNs: motionAckNs
            )
        }
    }

    package func recordHostInput(
        scheduledNs: UInt64,
        hostInputNs: UInt64,
        sendStartedNs: UInt64
    ) throws {
        try withActiveCapture {
            assembler.recordHostInput(
                scheduledNs: scheduledNs,
                hostInputNs: hostInputNs,
                sendStartedNs: sendStartedNs
            )
        }
    }

    package func recordSendCompleted(
        at nanoseconds: UInt64,
        motionAckNs: UInt64? = nil
    ) throws {
        try withActiveCapture {
            assembler.recordSendCompleted(at: nanoseconds, motionAckNs: motionAckNs)
        }
    }

    package func recordMotionAcknowledged(at nanoseconds: UInt64) throws {
        try withActiveCapture { assembler.recordMotionAcknowledged(at: nanoseconds) }
    }

    package func recordGuestEvidence(
        receivedNs: UInt64,
        drawnNs: UInt64,
        markerRevision: UInt64
    ) throws {
        try withActiveCapture {
            assembler.recordGuestEvidence(
                receivedNs: receivedNs,
                drawnNs: drawnNs,
                markerRevision: markerRevision
            )
        }
    }

    package func waitForExactPresentation(
        waiterRegistered: (@Sendable () -> Void)? = nil
    ) async throws -> SpiceInteractionFrameIdentity {
        try phase.withLock { phase in
            guard case .active = phase else {
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            }
        }
        return try await presentationWaiter.wait(waiterRegistered: waiterRegistered)
    }

    package func finish(
        invalidReason: String? = nil
    ) throws -> SpiceInteractionTraceRecord {
        let (record, resumption) = try phase.withLock { phase in
            guard case .active = phase else {
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            }
            // Diagnostics serializes detach against every presentation/frame
            // callback; after this returns no callback can enter the assembler.
            presentationDiagnostics.removeInteractionTraceAssembler(assembler)
            let record = assembler.finish(invalidReason: invalidReason)
            phase = .finished
            return (record, presentationWaiter.prepareFinish())
        }
        resumption?.resume()
        return record
    }

    private func withActiveCapture(_ body: () -> Void) throws {
        try phase.withLock { phase in
            guard case .active = phase else {
                throw SpiceInteractionTraceCollectionError.captureAlreadyFinished
            }
            body()
        }
    }
}
