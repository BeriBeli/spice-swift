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
    package var viewUpdateToMetalCommitHistogram = SpiceTimingHistogram()
    package var metalCommitToCompletionHistogram = SpiceTimingHistogram()
    package var metalRequestToPresentedHistogram = SpiceTimingHistogram()

    public var viewUpdateToMetalCommit: SpiceTimingSummary {
        viewUpdateToMetalCommitHistogram.summary
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
    private let state = Mutex(SpicePresentationMetrics())

    public init() {}

    public func snapshot() -> SpicePresentationMetrics {
        state.withLock { $0 }
    }

    package func recordMetalPresentedFrame() {
        state.withLock { $0.metalPresentedFrames &+= 1 }
    }

    package func recordMetalPresentationError() {
        state.withLock { $0.metalPresentationErrors &+= 1 }
    }

    package func recordMetalFramesSupersededBeforeDraw(_ count: UInt64) {
        guard count > 0 else { return }
        state.withLock { $0.metalFramesSupersededBeforeDraw &+= count }
    }

    package func recordMetalDrawableMiss() {
        state.withLock { $0.metalDrawableMisses &+= 1 }
    }

    package func recordMetalCommandCreationFailure() {
        state.withLock { $0.metalCommandCreationFailures &+= 1 }
    }

    package func recordMetalCommandBufferCommitted() {
        state.withLock { $0.metalCommandBuffersCommitted &+= 1 }
    }

    package func recordMetalTextureCacheHit() {
        state.withLock { $0.metalTextureCacheHits &+= 1 }
    }

    package func recordMetalTextureCacheMiss() {
        state.withLock { $0.metalTextureCacheMisses &+= 1 }
    }

    package func recordMetalTextureCacheEviction() {
        state.withLock { $0.metalTextureCacheEvictions &+= 1 }
    }

    package func recordMetalGPUBusySkip() {
        state.withLock { $0.metalGPUBusySkips &+= 1 }
    }

    package func recordDesktopDisplayLinkWakeup() {
        state.withLock { $0.desktopDisplayLinkWakeups &+= 1 }
    }

    package func recordDesktopDisplayLinkTick() {
        state.withLock { $0.desktopDisplayLinkTicks &+= 1 }
    }

    package func recordDesktopDisplayLinkIdlePause() {
        state.withLock { $0.desktopDisplayLinkIdlePauses &+= 1 }
    }

    package func recordViewUpdateToMetalCommit(_ duration: Duration) {
        state.withLock { $0.viewUpdateToMetalCommitHistogram.record(duration) }
    }

    package func recordMetalCommitToCompletion(_ duration: Duration) {
        state.withLock { $0.metalCommitToCompletionHistogram.record(duration) }
    }

    package func recordMetalRequestToPresented(_ duration: Duration) {
        state.withLock { $0.metalRequestToPresentedHistogram.record(duration) }
    }

    package func recordCPUFallback(_ reason: SpiceCPUPresentationFallbackReason) {
        state.withLock { metrics in
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
        state.withLock { $0 = SpicePresentationMetrics() }
    }
}
