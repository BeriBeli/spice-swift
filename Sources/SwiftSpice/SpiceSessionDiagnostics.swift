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
/// This type intentionally contains no per-frame log, pixel data, or native
/// buffer handles. It also does not measure transport or server latency,
/// mailbox queueing, application consumption, or GPU presentation. Publisher
/// emission occurs before those downstream stages. Advanced-video counters
/// cover H.264/H.265 decoding and do not describe the MJPEG path.
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
    public internal(set) var publisherStaleSnapshots: UInt64 = 0
    public internal(set) var publisherPendingEvictions: UInt64 = 0
    public internal(set) var publisherPendingSurfaces: Int = 0
    public internal(set) var videoDecoderSessionCreations: UInt64 = 0
    public internal(set) var videoHardwareSessions: UInt64 = 0
    public internal(set) var videoSoftwareSessions: UInt64 = 0
    public internal(set) var videoHardwareQueryFailures: UInt64 = 0
    public internal(set) var videoDecodedFrames: UInt64 = 0
    public internal(set) var videoDroppedFrames: UInt64 = 0
    public internal(set) var videoCPUMaterializations: UInt64 = 0
    public internal(set) var advancedCPUFallbackFrames: UInt64 = 0
    public internal(set) var metalGenerationDisableCount: UInt64 = 0
    public internal(set) var firstMetalGenerationDisableReason: String?
    public internal(set) var surfaceAllocatedBytes: Int = 0
    public internal(set) var maximumSurfaceBytes: Int = 0

    public static let empty = Self()

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
        publisherStaleSnapshots &+= publisher.staleSnapshots
        publisherPendingEvictions &+= publisher.pendingEvictions
        publisherPendingSurfaces += publisher.pendingSurfaces

        videoDecoderSessionCreations &+= video.sessionCreationCount
        videoHardwareSessions &+= video.hardwareSessionCount
        videoSoftwareSessions &+= video.softwareSessionCount
        videoHardwareQueryFailures &+= video.hardwareQueryFailureCount
        videoDecodedFrames &+= video.decodedFrameCount
        videoDroppedFrames &+= video.droppedFrameCount
        videoCPUMaterializations &+= video.cpuMaterializationCount
        advancedCPUFallbackFrames &+= diagnostics.advancedCPUFallbackFrames
        metalGenerationDisableCount &+= diagnostics.metalGenerationDisableCount
        if firstMetalGenerationDisableReason == nil {
            firstMetalGenerationDisableReason = diagnostics.firstMetalGenerationDisableReason
        }
    }
}
