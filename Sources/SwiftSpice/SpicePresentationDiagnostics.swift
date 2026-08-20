import Synchronization

/// A content-free reason why a desktop frame used AppKit CPU presentation.
public enum SpiceCPUPresentationFallbackReason: String, Sendable, Equatable {
    case metalUnavailable = "metal_unavailable"
    case missingIOSurface = "missing_iosurface"
    case ioSurfaceDimensionMismatch = "iosurface_dimension_mismatch"
    case pixelFormatMismatch = "pixel_format_mismatch"
    case textureCreationFailed = "texture_creation_failed"
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
    public internal(set) var lastCPUFallbackReason: SpiceCPUPresentationFallbackReason?

    public static let empty = Self()
}

/// Thread-safe presentation counters shared by a session and its desktop view.
///
/// Pass `SpiceSession.presentationDiagnostics` to `SpiceDesktopView` so the
/// presentation fields in `SpiceSession.diagnosticsSnapshot()` cover the same
/// session. The recorder retains counters and fixed reason categories only.
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
            }
        }
    }

    package func reset() {
        state.withLock { $0 = SpicePresentationMetrics() }
    }
}
