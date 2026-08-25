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
    package var desktopReadyToDisplayLinkHistogram = SpiceTimingHistogram()
    package var viewUpdateToMetalCommitHistogram = SpiceTimingHistogram()
    package var metalCommitToCompletionHistogram = SpiceTimingHistogram()
    package var metalRequestToPresentedHistogram = SpiceTimingHistogram()

    public var viewUpdateToMetalCommit: SpiceTimingSummary {
        viewUpdateToMetalCommitHistogram.summary
    }

    /// Time from the first coalesced desktop update becoming ready until the
    /// AppKit display link selects the latest revision for presentation.
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
    }

    private let state = Mutex(State())

    public init() {}

    public func snapshot() -> SpicePresentationMetrics {
        state.withLock { $0.metrics }
    }

    package func currentEpoch() -> UInt64 {
        state.withLock { $0.epoch }
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
