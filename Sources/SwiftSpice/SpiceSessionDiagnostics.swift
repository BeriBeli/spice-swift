import Foundation
import SpiceChannels

/// Best-effort, aggregate-only evidence about the display pipeline.
///
/// Counters accumulate from the most recent `SpiceSession.connect` attempt and
/// include active and retired display channels. Channel-state samples combine
/// current values from active channels with the last values observed when
/// retired channels closed. Depending on the field, those samples are summed,
/// ORed, or retained as a session maximum; they must not be interpreted as
/// strictly live gauges. The snapshot is assembled across actors and is not
/// atomic.
///
/// This type intentionally contains no per-frame log or timestamp, pixel data,
/// or native buffer handles. It does not measure server or transport latency
/// before `ChannelConnection.receive()` returns a complete framed message.
/// Bounded histograms summarize receive-to-surface-apply, publisher, and
/// GPU-presentation timing without retaining individual samples.
/// Presentation counters are populated when a desktop view subscribes to this
/// session's desktop source. Advanced-video counters cover H.264/H.265 decoding
/// and do not describe the MJPEG path. `advancedVideoPresentedFrames` is the
/// subset of Metal presentation events whose immutable canonical revision was
/// committed by native H.264/H.265 composition.
///
/// `totalIOSurfaceAllocatedBytes` is process-wide live state.
/// `surfaceAllocatedBytes` is live session-budget usage, and
/// `maximumSurfaceBytes` is its configured limit rather than a peak value.
public struct SpiceSessionDiagnostics: Sendable, Equatable {
    public internal(set) var displayChannelCount: Int = 0
    public internal(set) var damageOperations: UInt64 = 0
    public internal(set) var damageBytes: UInt64 = 0
    public internal(set) var snapshots: UInt64 = 0
    public internal(set) var fullFrameCopyBytes: UInt64 = 0
    public internal(set) var partialFrameCopyBytes: UInt64 = 0
    public internal(set) var cpuMaterializations: UInt64 = 0
    public internal(set) var cpuMaterializationBytes: UInt64 = 0
    public internal(set) var poolExhaustions: UInt64 = 0
    public internal(set) var inFlightLeases: Int = 0
    public internal(set) var revisionedBackingEnabled = false
    public internal(set) var revisionedAllocatedFrames: Int = 0
    public internal(set) var revisionedAllocatedBytes: Int = 0
    public internal(set) var totalIOSurfaceAllocatedBytes: Int = 0
    public internal(set) var gpuCopyBytes: UInt64 = 0
    public internal(set) var gpuErrors: UInt64 = 0
    public internal(set) var nativeVideoFrames: UInt64 = 0
    public internal(set) var nativeVideoFallbacks: UInt64 = 0
    public internal(set) var recommendedMaximumWorkingSetSize: UInt64 = 0
    public internal(set) var currentMetalAllocatedSize: UInt64 = 0
    public internal(set) var publisherSubmissions: UInt64 = 0
    public internal(set) var publisherSnapshotAttempts: UInt64 = 0
    public internal(set) var publisherEmittedFrames: UInt64 = 0
    public internal(set) var publisherEmittedIOSurfaceFrames: UInt64 = 0
    public internal(set) var publisherEmittedCPUOnlyFrames: UInt64 = 0
    public internal(set) var publisherStaleSnapshots: UInt64 = 0
    public internal(set) var publisherPendingEvictions: UInt64 = 0
    public internal(set) var publisherPendingSurfaces: Int = 0
    public internal(set) var publisherFlushes: UInt64 = 0
    public internal(set) var publisherFlushesWithoutEmission: UInt64 = 0
    public internal(set) var publisherDemandSuppressedSubmissions: UInt64 = 0
    public internal(set) var publisherPendingRevisionCoalesces: UInt64 = 0
    public internal(set) var publisherPreparedFrameCoalesces: UInt64 = 0
    public internal(set) var publisherDemandedSurfaces: Int = 0
    public internal(set) var publisherPreparedFrames: Int = 0
    package var publisherBatchStartGapHistogram = SpiceTimingHistogram()
    package var publisherFramedReceiveBatchStartGapHistogram = SpiceTimingHistogram()
    package var publisherMessageReceiveToSurfaceReadyHistogram = SpiceTimingHistogram()
    package var publisherSurfaceReadyToSubmitHistogram = SpiceTimingHistogram()
    package var publisherFlushStartGapHistogram = SpiceTimingHistogram()
    package var publisherFlushSchedulingDelayHistogram = SpiceTimingHistogram()
    package var publisherSnapshotDurationHistogram = SpiceTimingHistogram()
    package var publisherEmitDurationHistogram = SpiceTimingHistogram()
    public internal(set) var desktopDeliveredSnapshots: UInt64 = 0
    public internal(set) var desktopStreamCoalesces: UInt64 = 0
    public internal(set) var desktopHandlerDeliveries: UInt64 = 0
    public internal(set) var desktopSubscriptions: Int = 0
    public internal(set) var desktopVisibleSubscriptions: Int = 0
    public internal(set) var videoDecoderSessionCreations: UInt64 = 0
    public internal(set) var videoHardwareSessions: UInt64 = 0
    public internal(set) var videoSoftwareSessions: UInt64 = 0
    public internal(set) var videoHardwareQueryFailures: UInt64 = 0
    public internal(set) var videoDecodedFrames: UInt64 = 0
    public internal(set) var videoDroppedFrames: UInt64 = 0
    public internal(set) var videoCPUMaterializations: UInt64 = 0
    public internal(set) var mjpegDecoderHandleCreations: UInt64 = 0
    public internal(set) var mjpegDecodedFrames: UInt64 = 0
    public internal(set) var mjpegIOSurfaceFrames: UInt64 = 0
    public internal(set) var mjpegDataFallbacks: UInt64 = 0
    public internal(set) var mjpegIOSurfaceAllocations: UInt64 = 0
    public internal(set) var mjpegPeakBuffersInUse: Int = 0
    public internal(set) var mjpegPeakConcurrentDecodes: Int = 0
    public internal(set) var advancedCPUFallbackFrames: UInt64 = 0
    public internal(set) var metalGenerationDisableCount: UInt64 = 0
    public internal(set) var firstMetalGenerationDisableReason: String?
    public internal(set) var surfaceAllocatedBytes: Int = 0
    public internal(set) var maximumSurfaceBytes: Int = 0
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
    package var viewUpdateToMetalCommitHistogram = SpiceTimingHistogram()
    package var metalCommitToCompletionHistogram = SpiceTimingHistogram()
    package var metalRequestToPresentedHistogram = SpiceTimingHistogram()

    public static let empty = Self()

    public var publisherBatchStartGap: SpiceTimingSummary {
        publisherBatchStartGapHistogram.summary
    }

    /// Gap between the receive-completion timestamps of successive publisher
    /// batches. This begins after transport framing, not at the server.
    public var publisherFramedReceiveBatchStartGap: SpiceTimingSummary {
        publisherFramedReceiveBatchStartGapHistogram.summary
    }

    /// Time from receiving a complete display message through image decode and
    /// applying its resulting pixels to the surface, before protocol ACK work.
    public var publisherMessageReceiveToSurfaceReady: SpiceTimingSummary {
        publisherMessageReceiveToSurfaceReadyHistogram.summary
    }

    /// Actor handoff time from the completed surface apply to publisher entry.
    public var publisherSurfaceReadyToSubmit: SpiceTimingSummary {
        publisherSurfaceReadyToSubmitHistogram.summary
    }

    public var publisherFlushStartGap: SpiceTimingSummary {
        publisherFlushStartGapHistogram.summary
    }

    public var publisherFlushSchedulingDelay: SpiceTimingSummary {
        publisherFlushSchedulingDelayHistogram.summary
    }

    public var publisherSnapshotDuration: SpiceTimingSummary {
        publisherSnapshotDurationHistogram.summary
    }

    public var publisherEmitDuration: SpiceTimingSummary {
        publisherEmitDurationHistogram.summary
    }

    public var viewUpdateToMetalCommit: SpiceTimingSummary {
        viewUpdateToMetalCommitHistogram.summary
    }

    public var metalCommitToCompletion: SpiceTimingSummary {
        metalCommitToCompletionHistogram.summary
    }

    public var metalRequestToPresented: SpiceTimingSummary {
        metalRequestToPresentedHistogram.summary
    }

    mutating func accumulate(_ diagnostics: DisplayChannelDiagnostics) {
        let surface = diagnostics.surfaces
        let publisher = diagnostics.publisher
        let video = diagnostics.advancedVideo

        displayChannelCount += 1
        damageOperations &+= surface.damageOperations
        damageBytes &+= surface.damageBytes
        snapshots &+= surface.snapshots
        fullFrameCopyBytes &+= surface.fullFrameCopyBytes
        partialFrameCopyBytes &+= surface.partialFrameCopyBytes
        cpuMaterializations &+= surface.cpuMaterializations
        cpuMaterializationBytes &+= surface.cpuMaterializationBytes
        poolExhaustions &+= surface.poolExhaustions
        inFlightLeases = max(inFlightLeases, surface.inFlightLeases)
        revisionedBackingEnabled = revisionedBackingEnabled || surface.revisionedBackingEnabled
        revisionedAllocatedFrames = max(
            revisionedAllocatedFrames,
            surface.revisionedAllocatedFrames
        )
        revisionedAllocatedBytes = max(
            revisionedAllocatedBytes,
            surface.revisionedAllocatedBytes
        )
        gpuCopyBytes &+= surface.gpuCopyBytes
        gpuErrors &+= surface.gpuErrors
        nativeVideoFrames &+= surface.nativeVideoFrames
        nativeVideoFallbacks &+= surface.nativeVideoFallbacks
        recommendedMaximumWorkingSetSize = max(
            recommendedMaximumWorkingSetSize,
            surface.recommendedMaximumWorkingSetSize
        )
        currentMetalAllocatedSize = max(
            currentMetalAllocatedSize,
            surface.currentMetalAllocatedSize
        )

        publisherSubmissions &+= publisher.submissions
        publisherSnapshotAttempts &+= publisher.snapshotAttempts
        publisherEmittedFrames &+= publisher.emittedFrames
        publisherEmittedIOSurfaceFrames &+= publisher.emittedIOSurfaceFrames
        publisherEmittedCPUOnlyFrames &+= publisher.emittedCPUOnlyFrames
        publisherStaleSnapshots &+= publisher.staleSnapshots
        publisherPendingEvictions &+= publisher.pendingEvictions
        publisherPendingSurfaces += publisher.pendingSurfaces
        publisherFlushes &+= publisher.flushes
        publisherFlushesWithoutEmission &+= publisher.flushesWithoutEmission
        publisherDemandSuppressedSubmissions &+= publisher.demandSuppressedSubmissions
        publisherPendingRevisionCoalesces &+= publisher.pendingRevisionCoalesces
        publisherPreparedFrameCoalesces &+= publisher.preparedFrameCoalesces
        publisherDemandedSurfaces += publisher.demandedSurfaces
        publisherPreparedFrames += publisher.preparedFrames
        publisherBatchStartGapHistogram.accumulate(publisher.batchStartGap)
        publisherFramedReceiveBatchStartGapHistogram.accumulate(
            publisher.framedReceiveBatchStartGap
        )
        publisherMessageReceiveToSurfaceReadyHistogram.accumulate(
            publisher.messageReceiveToSurfaceReady
        )
        publisherSurfaceReadyToSubmitHistogram.accumulate(
            publisher.surfaceReadyToSubmit
        )
        publisherFlushStartGapHistogram.accumulate(publisher.flushStartGap)
        publisherFlushSchedulingDelayHistogram.accumulate(publisher.flushSchedulingDelay)
        publisherSnapshotDurationHistogram.accumulate(publisher.snapshotDuration)
        publisherEmitDurationHistogram.accumulate(publisher.emitDuration)

        videoDecoderSessionCreations &+= video.sessionCreationCount
        videoHardwareSessions &+= video.hardwareSessionCount
        videoSoftwareSessions &+= video.softwareSessionCount
        videoHardwareQueryFailures &+= video.hardwareQueryFailureCount
        videoDecodedFrames &+= video.decodedFrameCount
        videoDroppedFrames &+= video.droppedFrameCount
        videoCPUMaterializations &+= video.cpuMaterializationCount
        mjpegDecoderHandleCreations &+= diagnostics.mjpeg.handleCreations
        mjpegDecodedFrames &+= diagnostics.mjpeg.decodedFrames
        mjpegIOSurfaceFrames &+= diagnostics.mjpeg.ioSurfaceFrames
        mjpegDataFallbacks &+= diagnostics.mjpeg.dataFallbacks
        mjpegIOSurfaceAllocations &+= diagnostics.mjpeg.ioSurfaceAllocations
        mjpegPeakBuffersInUse = max(
            mjpegPeakBuffersInUse,
            diagnostics.mjpeg.peakBuffersInUse
        )
        mjpegPeakConcurrentDecodes = max(
            mjpegPeakConcurrentDecodes,
            diagnostics.mjpeg.peakConcurrentDecodes
        )
        advancedCPUFallbackFrames &+= diagnostics.advancedCPUFallbackFrames
        metalGenerationDisableCount &+= diagnostics.metalGenerationDisableCount
        if firstMetalGenerationDisableReason == nil {
            firstMetalGenerationDisableReason = diagnostics.firstMetalGenerationDisableReason
        }
    }
}
