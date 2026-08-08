import SwiftSpice

@main
struct PublicAPIConsumer {
    static func main() async {
        let session = SpiceSession()
        let diagnostics: SpiceSessionDiagnostics = await session.diagnosticsSnapshot()
        requireSendable(diagnostics)
        let _: Bool = diagnostics == .empty

        _ = diagnostics.displayChannelCount
        _ = diagnostics.damageOperations
        _ = diagnostics.damageBytes
        _ = diagnostics.snapshots
        _ = diagnostics.fullFrameCopyBytes
        _ = diagnostics.partialFrameCopyBytes
        _ = diagnostics.cpuMaterializations
        _ = diagnostics.cpuMaterializationBytes
        _ = diagnostics.poolExhaustions
        _ = diagnostics.inFlightLeases
        _ = diagnostics.revisionedBackingEnabled
        _ = diagnostics.revisionedAllocatedFrames
        _ = diagnostics.revisionedAllocatedBytes
        _ = diagnostics.totalIOSurfaceAllocatedBytes
        _ = diagnostics.gpuCopyBytes
        _ = diagnostics.gpuErrors
        _ = diagnostics.nativeVideoFrames
        _ = diagnostics.nativeVideoFallbacks
        _ = diagnostics.recommendedMaximumWorkingSetSize
        _ = diagnostics.currentMetalAllocatedSize
        _ = diagnostics.publisherSubmissions
        _ = diagnostics.publisherSnapshotAttempts
        _ = diagnostics.publisherEmittedFrames
        _ = diagnostics.publisherStaleSnapshots
        _ = diagnostics.publisherPendingEvictions
        _ = diagnostics.publisherPendingSurfaces
        _ = diagnostics.videoDecoderSessionCreations
        _ = diagnostics.videoHardwareSessions
        _ = diagnostics.videoSoftwareSessions
        _ = diagnostics.videoHardwareQueryFailures
        _ = diagnostics.videoDecodedFrames
        _ = diagnostics.videoDroppedFrames
        _ = diagnostics.videoCPUMaterializations
        _ = diagnostics.advancedCPUFallbackFrames
        _ = diagnostics.metalGenerationDisableCount
        _ = diagnostics.firstMetalGenerationDisableReason
        _ = diagnostics.surfaceAllocatedBytes
        _ = diagnostics.maximumSurfaceBytes
    }
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}
