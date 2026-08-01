import Foundation
import SpiceChannels

/// Package-only evidence used by the live probe and acceptance tooling. This is
/// intentionally aggregate-only: no frame logging and no native buffer handles
/// cross the public API boundary.
package struct SpiceSessionDiagnostics: Sendable, Equatable {
    package var displayChannelCount: Int = 0
    package var damageOperations: UInt64 = 0
    package var damageBytes: UInt64 = 0
    package var snapshots: UInt64 = 0
    package var fullFrameCopyBytes: UInt64 = 0
    package var partialFrameCopyBytes: UInt64 = 0
    package var cpuMaterializations: UInt64 = 0
    package var cpuMaterializationBytes: UInt64 = 0
    package var poolExhaustions: UInt64 = 0
    package var inFlightLeases: Int = 0
    package var revisionedBackingEnabled = false
    package var revisionedAllocatedFrames: Int = 0
    package var revisionedAllocatedBytes: Int = 0
    package var totalIOSurfaceAllocatedBytes: Int = 0
    package var gpuCopyBytes: UInt64 = 0
    package var gpuErrors: UInt64 = 0
    package var nativeVideoFrames: UInt64 = 0
    package var nativeVideoFallbacks: UInt64 = 0
    package var recommendedMaximumWorkingSetSize: UInt64 = 0
    package var currentMetalAllocatedSize: UInt64 = 0
    package var publisherSubmissions: UInt64 = 0
    package var publisherSnapshotAttempts: UInt64 = 0
    package var publisherEmittedFrames: UInt64 = 0
    package var publisherStaleSnapshots: UInt64 = 0
    package var publisherPendingEvictions: UInt64 = 0
    package var publisherPendingSurfaces: Int = 0
    package var videoDecoderSessionCreations: UInt64 = 0
    package var videoHardwareSessions: UInt64 = 0
    package var videoSoftwareSessions: UInt64 = 0
    package var videoHardwareQueryFailures: UInt64 = 0
    package var videoDecodedFrames: UInt64 = 0
    package var videoDroppedFrames: UInt64 = 0
    package var videoCPUMaterializations: UInt64 = 0
    package var advancedCPUFallbackFrames: UInt64 = 0
    package var metalGenerationDisableCount: UInt64 = 0
    package var firstMetalGenerationDisableReason: String?
    package var surfaceAllocatedBytes: Int = 0
    package var maximumSurfaceBytes: Int = 0

    package mutating func accumulate(_ diagnostics: DisplayChannelDiagnostics) {
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
