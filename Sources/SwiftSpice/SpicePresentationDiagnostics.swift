import Synchronization
import SpiceChannels

/// A content-free reason why a desktop frame used AppKit CPU presentation.
public enum SpiceCPUPresentationFallbackReason: String, Sendable, Equatable {
    case metalUnavailable = "metal_unavailable"
    case missingIOSurface = "missing_iosurface"
    case ioSurfaceDimensionMismatch = "iosurface_dimension_mismatch"
    case pixelFormatMismatch = "pixel_format_mismatch"
    case textureCreationFailed = "texture_creation_failed"
    case metalCommandFailure = "metal_command_failure"
}

/// Best-effort aggregate evidence about desktop frame presentation.
public struct SpicePresentationMetrics: Sendable, Equatable {
    public internal(set) var metalPresentedFrames: UInt64 = 0
    public internal(set) var advancedVideoPresentedFrames: UInt64 = 0
    public internal(set) var metalPresentationErrors: UInt64 = 0
    public internal(set) var cpuFallbackFrames: UInt64 = 0
    public internal(set) var metalUnavailableFallbackFrames: UInt64 = 0
    public internal(set) var missingIOSurfaceFallbackFrames: UInt64 = 0
    public internal(set) var ioSurfaceDimensionMismatchFallbackFrames: UInt64 = 0
    public internal(set) var pixelFormatMismatchFallbackFrames: UInt64 = 0
    public internal(set) var textureCreationFailedFallbackFrames: UInt64 = 0
    public internal(set) var metalCommandFailureFallbackFrames: UInt64 = 0
    public internal(set) var lastCPUFallbackReason: SpiceCPUPresentationFallbackReason?
    public internal(set) var metalFramesSupersededBeforeDraw: UInt64 = 0
    public internal(set) var metalDrawableMisses: UInt64 = 0
    public internal(set) var metalCommandCreationFailures: UInt64 = 0
    public internal(set) var metalCommandBuffersCommitted: UInt64 = 0
    public internal(set) var metalTextureCacheHits: UInt64 = 0
    public internal(set) var metalTextureCacheMisses: UInt64 = 0
    public internal(set) var metalTextureCacheEvictions: UInt64 = 0
    public internal(set) var metalGPUBusySkips: UInt64 = 0
    public internal(set) var desktopDisplayLinkWakeups: UInt64 = 0
    public internal(set) var desktopDisplayLinkTicks: UInt64 = 0
    public internal(set) var desktopDisplayLinkIdlePauses: UInt64 = 0
    public internal(set) var desktopImmediateSelections: UInt64 = 0
    package var desktopReadyToDisplayLinkHistogram = SpiceTimingHistogram()
    package var viewUpdateToMetalCommitHistogram = SpiceTimingHistogram()
    package var metalCommitToCompletionHistogram = SpiceTimingHistogram()
    package var metalRequestToPresentedHistogram = SpiceTimingHistogram()

    public var viewUpdateToMetalCommit: SpiceTimingSummary {
        viewUpdateToMetalCommitHistogram.summary
    }

    /// Time from the selected latest desktop revision becoming ready until the
    /// AppKit presentation scheduler selects that revision. The property name
    /// remains source-compatible with SwiftSpice 0.2.5.
    public var desktopReadyToDisplayLink: SpiceTimingSummary {
        desktopReadyToDisplayLinkHistogram.summary
    }

    public var metalCommitToCompletion: SpiceTimingSummary {
        metalCommitToCompletionHistogram.summary
    }

    /// Time from selecting a desktop revision until CAMetalDrawable confirms
    /// that the drawable was actually presented by the display compositor.
    public var metalRequestToPresented: SpiceTimingSummary {
        metalRequestToPresentedHistogram.summary
    }

    public static let empty = Self()
}

/// Thread-safe presentation counters shared by a session and its desktop view.
///
/// `SpiceSession.desktop` carries this recorder package-internally into
/// `SpiceDesktopView`, so SwiftUI never observes or forwards it. The recorder
/// retains aggregate counters, bounded histograms, and fixed categories only.
public final class SpicePresentationDiagnostics: Sendable {
    private struct State {
        var metrics = SpicePresentationMetrics()
        var epoch: UInt64 = 0
        var interactionTraceAssembler: SpiceInteractionTraceAssembler?
    }

    private let state = Mutex(State())

    public init() {}

    public func snapshot() -> SpicePresentationMetrics {
        state.withLock { $0.metrics }
    }

    package func currentEpoch() -> UInt64 {
        state.withLock { $0.epoch }
    }

    package func setInteractionTraceAssembler(
        _ assembler: SpiceInteractionTraceAssembler?
    ) {
        state.withLock { $0.interactionTraceAssembler = assembler }
    }

    package func recordInteractionFrameReceived(
        _ snapshot: SpiceDesktopSnapshot,
        sourceTiming: DisplayFrameSourceTiming?
    ) {
        let assembler = state.withLock { $0.interactionTraceAssembler }
        assembler?.observeFrame(snapshot: snapshot, sourceTiming: sourceTiming)
    }

    package func recordInteractionSelected(
        identity: SpiceInteractionFrameIdentity,
        readyNs: UInt64,
        selectionNs: UInt64
    ) {
        let assembler = state.withLock { $0.interactionTraceAssembler }
        assembler?.observeSelected(
            identity: identity,
            readyNs: readyNs,
            selectionNs: selectionNs
        )
    }

    package func recordInteractionCommitted(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    ) {
        let assembler = state.withLock { $0.interactionTraceAssembler }
        assembler?.observeCommitted(identity: identity, at: nanoseconds)
    }

    package func recordInteractionPresented(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    ) {
        let assembler = state.withLock { $0.interactionTraceAssembler }
        assembler?.observePresented(identity: identity, at: nanoseconds)
    }

    package func retireInteractionDesktopGeneration(_ generation: UInt64) {
        let assembler = state.withLock { $0.interactionTraceAssembler }
        assembler?.retireDesktopGeneration(generation)
    }

    package func recordMetalPresentedFrame(
        isAdvancedVideo: Bool = false,
        epoch: UInt64? = nil
    ) {
        state.withLock { state in
            guard epoch == nil || epoch == state.epoch else { return }
            state.metrics.metalPresentedFrames &+= 1
            if isAdvancedVideo {
                state.metrics.advancedVideoPresentedFrames &+= 1
            }
        }
    }

    package func recordMetalPresentationError(epoch: UInt64? = nil) {
        state.withLock { state in
            guard epoch == nil || epoch == state.epoch else { return }
            state.metrics.metalPresentationErrors &+= 1
        }
    }

    package func recordMetalFramesSupersededBeforeDraw(_ count: UInt64) {
        guard count > 0 else { return }
        update { $0.metalFramesSupersededBeforeDraw &+= count }
    }

    package func recordMetalDrawableMiss() {
        update { $0.metalDrawableMisses &+= 1 }
    }

    package func recordMetalCommandCreationFailure() {
        update { $0.metalCommandCreationFailures &+= 1 }
    }

    package func recordMetalCommandBufferCommitted() {
        update { $0.metalCommandBuffersCommitted &+= 1 }
    }

    package func recordMetalTextureCacheHit() {
        update { $0.metalTextureCacheHits &+= 1 }
    }

    package func recordMetalTextureCacheMiss() {
        update { $0.metalTextureCacheMisses &+= 1 }
    }

    package func recordMetalTextureCacheEviction() {
        update { $0.metalTextureCacheEvictions &+= 1 }
    }

    package func recordMetalGPUBusySkip() {
        update { $0.metalGPUBusySkips &+= 1 }
    }

    package func recordDesktopDisplayLinkWakeup() {
        update { $0.desktopDisplayLinkWakeups &+= 1 }
    }

    package func recordDesktopDisplayLinkTick() {
        update { $0.desktopDisplayLinkTicks &+= 1 }
    }

    package func recordDesktopDisplayLinkIdlePause() {
        update { $0.desktopDisplayLinkIdlePauses &+= 1 }
    }

    package func recordDesktopImmediateSelection() {
        update { $0.desktopImmediateSelections &+= 1 }
    }

    package func recordDesktopReadyToDisplayLink(_ duration: Duration) {
        update { $0.desktopReadyToDisplayLinkHistogram.record(duration) }
    }

    package func recordViewUpdateToMetalCommit(_ duration: Duration) {
        update { $0.viewUpdateToMetalCommitHistogram.record(duration) }
    }

    package func recordMetalCommitToCompletion(
        _ duration: Duration,
        epoch: UInt64? = nil
    ) {
        state.withLock { state in
            guard epoch == nil || epoch == state.epoch else { return }
            state.metrics.metalCommitToCompletionHistogram.record(duration)
        }
    }

    package func recordMetalRequestToPresented(
        _ duration: Duration,
        epoch: UInt64? = nil
    ) {
        state.withLock { state in
            guard epoch == nil || epoch == state.epoch else { return }
            state.metrics.metalRequestToPresentedHistogram.record(duration)
        }
    }

    package func recordCPUFallback(_ reason: SpiceCPUPresentationFallbackReason) {
        update { metrics in
            metrics.cpuFallbackFrames &+= 1
            metrics.lastCPUFallbackReason = reason
            switch reason {
            case .metalUnavailable:
                metrics.metalUnavailableFallbackFrames &+= 1
            case .missingIOSurface:
                metrics.missingIOSurfaceFallbackFrames &+= 1
            case .ioSurfaceDimensionMismatch:
                metrics.ioSurfaceDimensionMismatchFallbackFrames &+= 1
            case .pixelFormatMismatch:
                metrics.pixelFormatMismatchFallbackFrames &+= 1
            case .textureCreationFailed:
                metrics.textureCreationFailedFallbackFrames &+= 1
            case .metalCommandFailure:
                metrics.metalCommandFailureFallbackFrames &+= 1
            }
        }
    }

    package func reset() {
        state.withLock { state in
            state.epoch &+= 1
            state.metrics = SpicePresentationMetrics()
        }
    }

    private func update(_ body: (inout SpicePresentationMetrics) -> Void) {
        state.withLock { body(&$0.metrics) }
    }
}

package enum SpiceInteractionActionClass: String, Codable, Sendable, Equatable {
    case click
    case key
    case motion
}

/// One causally correlated interaction observation. Guest monotonic timestamps
/// are validated only against other guest timestamps; they are never compared
/// with the host monotonic clock.
package struct SpiceInteractionTraceRecord: Codable, Sendable, Equatable {
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

    /// Send completion is recorded after the sending continuation resumes, so
    /// display receive may legitimately be observed first. That overlap has no
    /// post-send-to-display duration.
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
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "interaction trace validation fields are inconsistent"
                )
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
              token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return "invalid_token"
        }
        guard let scheduledNs else { return "missing_scheduled" }
        guard let hostInputNs else { return "missing_host_input" }
        guard let sendStartedNs else { return "missing_send_started" }
        guard let sendCompletedNs else { return "missing_send_completed" }
        guard let guestReceivedNs else { return "missing_guest_received" }
        guard let guestMarkerDrawnNs else { return "missing_guest_marker_drawn" }
        guard markerRevision != nil else { return "missing_marker_revision" }
        guard let markerChecksum else { return "missing_marker_checksum" }
        guard markerChecksum.utf8.count == 8,
              markerChecksum.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }) else {
            return "invalid_marker_checksum"
        }
        guard let displayReceiveNs else { return "missing_display_receive" }
        guard let surfaceReadyNs else { return "missing_surface_ready" }
        guard let selectedRevisionReadyNs else { return "missing_selected_revision_ready" }
        guard let selectionNs else { return "missing_selection" }
        guard let metalCommitNs else { return "missing_metal_commit" }
        guard let presentedNs else { return "missing_presented" }
        guard displayChannelID != nil else { return "missing_display_channel_id" }
        guard surfaceID != nil else { return "missing_surface_id" }
        guard frameRevision != nil else { return "missing_frame_revision" }
        guard surfaceGeneration != nil else { return "missing_surface_generation" }
        guard desktopGeneration != nil else { return "missing_desktop_generation" }
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
              guestReceivedNs <= guestMarkerDrawnNs else {
            return "non_monotonic_timestamps"
        }
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
             "missing_metal_commit", "missing_presented", "missing_frame_revision",
             "missing_display_channel_id", "missing_surface_id",
             "missing_surface_generation", "missing_desktop_generation",
             "missing_delivery_sequence",
             "non_monotonic_timestamps":
            true
        default:
            false
        }
    }

    private struct Wire: Codable {
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
