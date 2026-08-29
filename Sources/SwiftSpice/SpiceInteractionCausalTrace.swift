import Foundation
import QuartzCore
import SpiceChannels
import Synchronization

package struct SpiceInteractionFrameIdentity: Sendable, Hashable, Codable {
    package let desktopGeneration: UInt64
    package let displayChannelID: UInt8
    package let surfaceID: UInt32
    package let surfaceGeneration: UInt64
    package let frameRevision: UInt64
    package let deliverySequence: UInt64

    package init(
        desktopGeneration: UInt64,
        displayChannelID: UInt8,
        surfaceID: UInt32,
        surfaceGeneration: UInt64,
        frameRevision: UInt64,
        deliverySequence: UInt64
    ) {
        self.desktopGeneration = desktopGeneration
        self.displayChannelID = displayChannelID
        self.surfaceID = surfaceID
        self.surfaceGeneration = surfaceGeneration
        self.frameRevision = frameRevision
        self.deliverySequence = deliverySequence
    }
}

package struct SpiceInteractionPresentationContext: Sendable, Equatable {
    package let identity: SpiceInteractionFrameIdentity
    package let readyNanoseconds: UInt64
    package let selectionNanoseconds: UInt64

    package init(
        identity: SpiceInteractionFrameIdentity,
        readyNanoseconds: UInt64,
        selectionNanoseconds: UInt64
    ) {
        self.identity = identity
        self.readyNanoseconds = readyNanoseconds
        self.selectionNanoseconds = selectionNanoseconds
    }
}

package struct SpiceInteractionMarkerPayload: Sendable, Equatable {
    package let token: String
    package let markerRevision: UInt64
    package let checksum: UInt32

    package init(token: String, markerRevision: UInt64, checksum: UInt32) {
        self.token = token
        self.markerRevision = markerRevision
        self.checksum = checksum
    }
}

package enum SpiceInteractionMarkerDetection: Sendable, Equatable {
    case none
    case exact(payload: SpiceInteractionMarkerPayload, identity: SpiceInteractionFrameIdentity)
    case ambiguous(matchCount: Int)
}

package struct SpiceInteractionMarkerPlacement: Sendable, Equatable {
    package let payload: SpiceInteractionMarkerPayload
    package let originX: Int
    package let originY: Int

    package init(
        payload: SpiceInteractionMarkerPayload,
        originX: Int,
        originY: Int
    ) {
        self.payload = payload
        self.originX = originX
        self.originY = originY
    }
}

/// Decodes the fixture's fixed two-row binary marker from actual BGRA frame
/// storage. The guest marker revision is payload, never a host revision alias.
package enum SpiceInteractionMarkerROIDetector {
    package static let magic: UInt16 = 0xA5C3
    package static let cellSize = 4
    package static let columns = 88
    package static let rows = 2
    package static let foregroundBGRA: UInt32 = 0xFF00_0000
    package static let backgroundBGRA: UInt32 = 0xFFFF_FFFF

    private static let bitCount = 176
    private static let maximumOrigin = 32

    package static func renderForTesting(
        placements: [SpiceInteractionMarkerPlacement],
        frameWidth: Int,
        frameHeight: Int,
        bytesPerRow: Int
    ) -> Data {
        precondition(frameWidth > 0 && frameHeight > 0)
        precondition(bytesPerRow >= frameWidth * 4)
        var pixels = Data(
            repeating: 0x7F,
            count: bytesPerRow * frameHeight
        )
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            for placement in placements {
                let bits = encodedBits(placement.payload)
                precondition(placement.originX >= 0 && placement.originY >= 0)
                precondition(placement.originX + columns * cellSize <= frameWidth)
                precondition(placement.originY + rows * cellSize <= frameHeight)
                for (bitIndex, bit) in bits.enumerated() {
                    let cellX = placement.originX + (bitIndex % columns) * cellSize
                    let cellY = placement.originY + (bitIndex / columns) * cellSize
                    let component: UInt8 = bit ? 0 : 255
                    for y in cellY..<(cellY + cellSize) {
                        for x in cellX..<(cellX + cellSize) {
                            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
                            pixel[0] = component
                            pixel[1] = component
                            pixel[2] = component
                            pixel[3] = 255
                        }
                    }
                }
            }
        }
        return pixels
    }

    package static func detect(
        in snapshot: SpiceDesktopSnapshot,
        expectedToken: String,
        expectedChecksum: UInt32
    ) -> SpiceInteractionMarkerDetection {
        guard let update = snapshot.frame,
              let identity = snapshot.interactionFrameIdentity,
              let expectedTokenValue = UInt64(expectedToken, radix: 16),
              expectedToken.utf8.count == 16
        else {
            return .none
        }
        let frame = update.frame
        let markerWidth = columns * cellSize
        let markerHeight = rows * cellSize
        let (minimumRowBytes, rowBytesOverflow) = frame.width
            .multipliedReportingOverflow(by: 4)
        let (coveredBytes, coveredBytesOverflow) = frame.bytesPerRow
            .multipliedReportingOverflow(by: frame.height)
        guard frame.width >= 0,
              frame.height >= 0,
              frame.bytesPerRow >= 0,
              !rowBytesOverflow,
              !coveredBytesOverflow,
              frame.width >= markerWidth,
              frame.height >= markerHeight,
              frame.bytesPerRow >= minimumRowBytes
        else {
            return .none
        }
        let pixels = frame.pixels
        guard pixels.count >= coveredBytes else { return .none }

        var matches: [SpiceInteractionMarkerPayload] = []
        let maximumX = min(maximumOrigin, frame.width - markerWidth)
        let maximumY = min(maximumOrigin, frame.height - markerHeight)
        pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            for originY in stride(from: 0, through: maximumY, by: cellSize) {
                for originX in stride(from: 0, through: maximumX, by: cellSize) {
                    guard let payload = decode(
                        base: base,
                        bytesPerRow: frame.bytesPerRow,
                        originX: originX,
                        originY: originY
                    ), payload.token == expectedToken,
                       UInt64(payload.token, radix: 16) == expectedTokenValue,
                       payload.checksum == expectedChecksum
                    else {
                        continue
                    }
                    matches.append(payload)
                }
            }
        }
        switch matches.count {
        case 0:
            return .none
        case 1:
            return .exact(payload: matches[0], identity: identity)
        default:
            return .ambiguous(matchCount: matches.count)
        }
    }

    private static func decode(
        base: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        originX: Int,
        originY: Int
    ) -> SpiceInteractionMarkerPayload? {
        var bits = [Bool]()
        bits.reserveCapacity(bitCount)
        for bitIndex in 0..<bitCount {
            let column = bitIndex % columns
            let row = bitIndex / columns
            let x = originX + column * cellSize + cellSize / 2
            let y = originY + row * cellSize + cellSize / 2
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
            let blue = pixel[0]
            let green = pixel[1]
            let red = pixel[2]
            if red <= 8, green <= 8, blue <= 8 {
                bits.append(true)
            } else if red >= 247, green >= 247, blue >= 247 {
                bits.append(false)
            } else {
                return nil
            }
        }

        var cursor = 0
        guard read(bits, cursor: &cursor, count: 16) == UInt64(magic) else {
            return nil
        }
        let token = read(bits, cursor: &cursor, count: 64)
        let markerRevision = read(bits, cursor: &cursor, count: 64)
        let checksum = UInt32(read(bits, cursor: &cursor, count: 32))
        return SpiceInteractionMarkerPayload(
            token: String(format: "%016llx", token),
            markerRevision: markerRevision,
            checksum: checksum
        )
    }

    private static func read(
        _ bits: [Bool],
        cursor: inout Int,
        count: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count {
            value = (value << 1) | (bits[cursor] ? 1 : 0)
            cursor += 1
        }
        return value
    }

    private static func encodedBits(_ payload: SpiceInteractionMarkerPayload) -> [Bool] {
        guard let token = UInt64(payload.token, radix: 16),
              payload.token.utf8.count == 16 else {
            return []
        }
        var bits: [Bool] = []
        bits.reserveCapacity(bitCount)
        append(UInt64(magic), count: 16, to: &bits)
        append(token, count: 64, to: &bits)
        append(payload.markerRevision, count: 64, to: &bits)
        append(UInt64(payload.checksum), count: 32, to: &bits)
        return bits
    }

    private static func append(_ value: UInt64, count: Int, to bits: inout [Bool]) {
        for shift in (0..<count).reversed() {
            bits.append((value & (UInt64(1) << UInt64(shift))) != 0)
        }
    }
}

package enum SpiceInteractionHostClock {
    private struct CoreAnimationAnchor: Sendable {
        let mediaTime: TimeInterval
        let monotonicNanoseconds: UInt64
    }

    private static let anchor: (instant: ContinuousClock.Instant, nanoseconds: UInt64) = {
        let nanoseconds = monotonicNanoseconds()
        return (ContinuousClock().now, nanoseconds)
    }()

    /// Maps Core Animation's media-time domain into the interaction trace's
    /// CLOCK_MONOTONIC domain. Bracketing the media-time sample bounds the
    /// one-time anchor error without substituting callback execution time for
    /// a drawable's actual `presentedTime`.
    private static let coreAnimationAnchor: CoreAnimationAnchor = {
        let before = monotonicNanoseconds()
        let mediaTime = CACurrentMediaTime()
        let after = monotonicNanoseconds()
        let midpoint = before + ((after - before) / 2)
        return CoreAnimationAnchor(
            mediaTime: mediaTime,
            monotonicNanoseconds: midpoint
        )
    }()

    private static func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_MONOTONIC, &time) == 0)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    package static func nowNanoseconds() -> UInt64 {
        nanoseconds(for: ContinuousClock().now) ?? anchor.nanoseconds
    }

    package static func nanoseconds(for instant: ContinuousClock.Instant) -> UInt64? {
        let components = anchor.instant.duration(to: instant).components
        let (secondsNanoseconds, secondsOverflow) = components.seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflow else { return nil }
        let fractionalNanoseconds = components.attoseconds / 1_000_000_000
        let (delta, deltaOverflow) = secondsNanoseconds
            .addingReportingOverflow(fractionalNanoseconds)
        guard !deltaOverflow else { return nil }
        if delta >= 0 {
            let (value, overflow) = anchor.nanoseconds.addingReportingOverflow(UInt64(delta))
            return overflow ? nil : value
        }
        guard delta != Int64.min else { return nil }
        let magnitude = UInt64(-delta)
        guard magnitude <= anchor.nanoseconds else { return nil }
        return anchor.nanoseconds - magnitude
    }

    package static func nanoseconds(
        forCoreAnimationTime mediaTime: TimeInterval
    ) -> UInt64? {
        guard mediaTime.isFinite else { return nil }
        let deltaSeconds = mediaTime - coreAnimationAnchor.mediaTime
        let deltaNanoseconds = (deltaSeconds * 1_000_000_000).rounded()
        guard deltaNanoseconds.isFinite,
              let delta = Int64(exactly: deltaNanoseconds)
        else {
            return nil
        }
        if delta >= 0 {
            let (value, overflow) = coreAnimationAnchor.monotonicNanoseconds
                .addingReportingOverflow(UInt64(delta))
            return overflow ? nil : value
        }
        guard delta != Int64.min else { return nil }
        let magnitude = UInt64(-delta)
        guard magnitude <= coreAnimationAnchor.monotonicNanoseconds else { return nil }
        return coreAnimationAnchor.monotonicNanoseconds - magnitude
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
        var metalCommitNs: UInt64?
        var presentedNs: UInt64?
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
    private let state = Mutex(State())

    package init(
        pairId: String,
        version: String,
        runId: String,
        order: UInt64,
        actionClass: SpiceInteractionActionClass,
        token: String,
        checksum: UInt32
    ) {
        self.pairId = pairId
        self.version = version
        self.runId = runId
        self.order = order
        self.actionClass = actionClass
        self.token = token
        self.checksum = checksum
    }

    package func recordHostEvidence(
        scheduledNs: UInt64,
        hostInputNs: UInt64,
        sendStartedNs: UInt64,
        sendCompletedNs: UInt64,
        motionAckNs: UInt64? = nil
    ) {
        state.withLock { state in
            if state.hostInputNs != nil {
                state.invalidReason = state.invalidReason ?? "duplicate_host_evidence"
                return
            }
            state.scheduledNs = scheduledNs
            state.hostInputNs = hostInputNs
            state.sendStartedNs = sendStartedNs
            state.sendCompletedNs = sendCompletedNs
            state.motionAckNs = motionAckNs
        }
    }

    package func recordMotionAcknowledged(at nanoseconds: UInt64) {
        state.withLock { state in
            if state.motionAckNs != nil {
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
            if state.guestReceivedNs != nil {
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
        // Frames received before this event's host-input linearization cannot
        // carry its marker. Once the target delivery is presented, unrelated
        // desktop traffic must not exhaust or mutate this event's fixed budget.
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
            // Recheck at the insertion linearization point: a presented
            // callback may have completed while the BGRA detector was reading.
            guard state.hostInputNs != nil,
                  state.presentedNs == nil,
                  let currentSendStartedNs = state.sendStartedNs,
                  displayReceiveNs.map({ $0 >= currentSendStartedNs }) ?? true
            else {
                return
            }
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
            let previousSelectedIdentity = state.selectedIdentity
            let previousSelectedMarker = state.selectedFrame?.payload
            if state.presentedNs != nil {
                if previousSelectedIdentity == identity {
                    state.invalidReason = state.invalidReason
                        ?? "duplicate_selection_after_presented"
                }
                return
            }
            if state.metalCommitNs != nil,
               previousSelectedIdentity == identity {
                state.invalidReason = state.invalidReason
                    ?? "duplicate_selection_after_commit"
                return
            }
            state.selectedIdentity = identity
            state.selectedRevisionReadyNs = readyNs
            state.selectionNs = selectionNs
            if let retired = state.retiredDesktopGeneration,
               identity.desktopGeneration <= retired {
                state.selectedFrame = nil
                state.invalidReason = state.invalidReason
                    ?? "retired_generation_selection"
                return
            }
            if Self.isRetiredSurface(identity, state: state) {
                state.selectedFrame = nil
                state.invalidReason = state.invalidReason ?? "surface_lifecycle_retired"
                return
            }
            guard let selectedFrame = state.frames[identity] else {
                state.selectedFrame = nil
                if previousSelectedMarker != nil
                    || state.frames.values.contains(where: { $0.payload != nil }) {
                    state.invalidReason = state.invalidReason
                        ?? "marker_replaced_before_presented"
                }
                return
            }
            state.selectedFrame = selectedFrame
            if previousSelectedMarker != nil,
               selectedFrame.payload == nil,
               previousSelectedIdentity != identity {
                state.invalidReason = state.invalidReason ?? "marker_replaced_before_presented"
                return
            }
            if selectedFrame.payload == nil,
               state.frames.values.contains(where: { $0.payload != nil }) {
                state.invalidReason = state.invalidReason
                    ?? "marker_replaced_before_presented"
            }
        }
    }

    package func observeCommitted(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    ) {
        state.withLock { state in
            Self.recordCommit(identity: identity, at: nanoseconds, state: &state)
        }
    }

    package func observePresented(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    ) {
        state.withLock { state in
            guard state.selectedIdentity == identity else {
                // An older drawable may be presented while the target delivery
                // is already selected. It cannot complete this event.
                return
            }
            if state.presentedNs != nil {
                state.invalidReason = state.invalidReason ?? "duplicate_presented"
                return
            }
            guard state.metalCommitNs != nil else {
                state.invalidReason = state.invalidReason ?? "presented_before_commit"
                return
            }
            if let retired = state.retiredDesktopGeneration,
               identity.desktopGeneration <= retired {
                state.invalidReason = state.invalidReason
                    ?? "presented_after_generation_retired"
                return
            }
            if Self.isRetiredSurface(identity, state: state) {
                state.invalidReason = state.invalidReason ?? "surface_lifecycle_retired"
                return
            }
            state.presentedNs = nanoseconds
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
            if let retired = state.retiredDesktopGeneration {
                state.retiredDesktopGeneration = max(retired, generation)
            } else {
                state.retiredDesktopGeneration = generation
            }
            let hasRetiredCandidate = state.frames.contains {
                $0.value.payload != nil
                    && $0.key.desktopGeneration <= generation
            }
            if hasRetiredCandidate, state.presentedNs == nil {
                state.invalidReason = state.invalidReason ?? "desktop_generation_retired"
            }
            state.frames = state.frames.filter {
                $0.key.desktopGeneration > generation
            }
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

    private static func recordCommit(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64,
        state: inout State
    ) {
        guard state.selectedIdentity == identity else {
            // Up to two Metal commands may be in flight. A completion for
            // another delivery is unrelated to this event, not ambiguity.
            return
        }
        if state.metalCommitNs != nil {
            state.invalidReason = state.invalidReason ?? "duplicate_metal_commit"
            return
        }
        if let retired = state.retiredDesktopGeneration,
           identity.desktopGeneration <= retired {
            state.invalidReason = state.invalidReason ?? "commit_after_generation_retired"
            return
        }
        if isRetiredSurface(identity, state: state) {
            state.invalidReason = state.invalidReason ?? "surface_lifecycle_retired"
            return
        }
        state.metalCommitNs = nanoseconds
    }

    package func finish(invalidReason: String? = nil) -> SpiceInteractionTraceRecord {
        state.withLock { state in
            let identity = state.selectedIdentity
            let selectedFrame = state.selectedFrame
            let candidatePayload = selectedFrame?.payload
            let markerRevision: UInt64?
            if let guestMarkerRevision = state.guestMarkerRevision,
               let candidatePayload,
               guestMarkerRevision != candidatePayload.markerRevision {
                markerRevision = candidatePayload.markerRevision
                state.invalidReason = state.invalidReason ?? "guest_marker_revision_mismatch"
            } else {
                markerRevision = candidatePayload?.markerRevision ?? state.guestMarkerRevision
            }
            let missingInputReason = state.hostInputNs == nil ? "missing_input_event" : nil
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
                markerChecksum: candidatePayload.map {
                    String(format: "%08x", $0.checksum)
                },
                invalidReason: invalidReason ?? state.invalidReason ?? missingInputReason
            )
        }
    }
}

extension SpiceDesktopSnapshot {
    package var interactionFrameIdentity: SpiceInteractionFrameIdentity? {
        guard let revision = frame?.revision,
              let frameDeliverySequence
        else {
            return nil
        }
        return SpiceInteractionFrameIdentity(
            desktopGeneration: generation,
            displayChannelID: revision.surface.displayChannelID,
            surfaceID: revision.surface.surfaceID,
            surfaceGeneration: revision.surface.generation,
            frameRevision: revision.value,
            deliverySequence: frameDeliverySequence
        )
    }
}
