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

    /// Time from the first coalesced desktop update becoming ready until the
    /// AppKit presentation scheduler selects the latest revision. The property
    /// name remains source-compatible with SwiftSpice 0.2.5.
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

    private enum InteractionSink: Sendable {
        case observer(any SpiceInteractionPresentationObserver)
        case assembler(SpiceInteractionTraceAssembler)
    }

    private struct InstalledInteractionSink: Sendable {
        let sink: InteractionSink
        var presenterID: SpiceInteractionPresenterID? = nil
    }

    private let state = Mutex(State())
    private let interactionSink = Mutex<InstalledInteractionSink?>(nil)

    public init() {}

    public func snapshot() -> SpicePresentationMetrics {
        state.withLock { $0.metrics }
    }

    package func currentEpoch() -> UInt64 {
        state.withLock { $0.epoch }
    }

    package func installInteractionPresentationObserver(
        _ observer: any SpiceInteractionPresentationObserver
    ) -> Bool {
        interactionSink.withLock { current in
            guard current == nil else { return false }
            current = InstalledInteractionSink(sink: .observer(observer))
            return true
        }
    }

    package func removeInteractionPresentationObserver(
        _ observer: any SpiceInteractionPresentationObserver
    ) {
        interactionSink.withLock { installed in
            guard case let .observer(current) = installed?.sink,
                  ObjectIdentifier(current) == ObjectIdentifier(observer) else { return }
            installed = nil
        }
    }

    package func installInteractionTraceAssembler(
        _ assembler: SpiceInteractionTraceAssembler
    ) -> Bool {
        interactionSink.withLock { current in
            guard current == nil else { return false }
            current = InstalledInteractionSink(sink: .assembler(assembler))
            return true
        }
    }

    package func removeInteractionTraceAssembler(
        _ assembler: SpiceInteractionTraceAssembler
    ) {
        interactionSink.withLock { installed in
            guard case let .assembler(current) = installed?.sink,
                  current === assembler else { return }
            installed = nil
        }
    }

    package func recordInteractionFrameReceived(
        _ snapshot: SpiceDesktopSnapshot,
        sourceTiming: DisplayFrameSourceTiming?
    ) {
        interactionSink.withLock { sink in
            guard case let .assembler(assembler) = sink?.sink else { return }
            assembler.observeFrame(snapshot: snapshot, sourceTiming: sourceTiming)
        }
    }

    package func recordInteractionSelected(
        _ context: SpiceInteractionPresentationContext
    ) {
        let observer = interactionSink.withLock { installedState -> (
            any SpiceInteractionPresentationObserver
        )? in
            guard var installed = installedState else { return nil }
            switch installed.sink {
            case let .assembler(assembler):
                if let owner = installed.presenterID {
                    guard owner == context.presenterID else { return nil }
                } else {
                    guard assembler.canBindPresentationOwner(
                        identity: context.identity
                    ) else { return nil }
                    installed.presenterID = context.presenterID
                    installedState = installed
                }
                assembler.observeSelected(
                    identity: context.identity,
                    readyNs: context.readyNanoseconds,
                    selectionNs: context.selectionNanoseconds
                )
                return nil
            case let .observer(observer):
                return observer
            }
        }
        observer?.observeSelected(context)
    }

    package func recordInteractionCommitted(
        identity: SpiceInteractionFrameIdentity,
        presenterID: SpiceInteractionPresenterID = .unspecified,
        at nanoseconds: UInt64
    ) {
        let observer = interactionSink.withLock { installed -> (
            any SpiceInteractionPresentationObserver
        )? in
            guard let installed else { return nil }
            switch installed.sink {
            case let .assembler(assembler):
                guard installed.presenterID == presenterID else { return nil }
                assembler.observeCommitted(identity: identity, at: nanoseconds)
                return nil
            case let .observer(observer):
                return observer
            }
        }
        observer?.observeCommitted(identity: identity, at: nanoseconds)
    }

    package func recordInteractionPresented(
        identity: SpiceInteractionFrameIdentity,
        presenterID: SpiceInteractionPresenterID = .unspecified,
        at nanoseconds: UInt64
    ) {
        let result = interactionSink.withLock { installed -> (
            observer: (any SpiceInteractionPresentationObserver)?,
            resumption: SpiceInteractionPresentationWaiter.Resumption?
        ) in
            guard let installed else { return (nil, nil) }
            switch installed.sink {
            case let .assembler(assembler):
                guard installed.presenterID == presenterID else { return (nil, nil) }
                return (nil, assembler.observePresented(identity: identity, at: nanoseconds))
            case let .observer(observer):
                return (observer, nil)
            }
        }
        result.observer?.observePresented(identity: identity, at: nanoseconds)
        result.resumption?.resume()
    }

    package func recordInteractionPresentationDropped(
        identity: SpiceInteractionFrameIdentity,
        presenterID: SpiceInteractionPresenterID = .unspecified
    ) {
        let observer = interactionSink.withLock { installed -> (
            any SpiceInteractionPresentationObserver
        )? in
            guard let installed else { return nil }
            switch installed.sink {
            case let .assembler(assembler):
                guard installed.presenterID == presenterID else { return nil }
                assembler.observePresentationDropped(identity: identity)
                return nil
            case let .observer(observer):
                return observer
            }
        }
        observer?.observePresentationDropped(identity: identity)
    }

    package func retireInteractionDesktopGeneration(_ generation: UInt64) {
        interactionSink.withLock { sink in
            guard case let .assembler(assembler) = sink?.sink else { return }
            assembler.retireDesktopGeneration(generation)
        }
    }

    package func retireInteractionSurfaceLifecycle(
        displayChannelID: UInt8,
        surfaceID: UInt32,
        generation: UInt64
    ) {
        interactionSink.withLock { sink in
            guard case let .assembler(assembler) = sink?.sink else { return }
            assembler.retireSurfaceLifecycle(
                displayChannelID: displayChannelID,
                surfaceID: surfaceID,
                generation: generation
            )
        }
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
