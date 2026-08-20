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
        _ = diagnostics.publisherEmittedIOSurfaceFrames
        _ = diagnostics.publisherEmittedCPUOnlyFrames
        _ = diagnostics.publisherStaleSnapshots
        _ = diagnostics.publisherPendingEvictions
        _ = diagnostics.publisherPendingSurfaces
        _ = diagnostics.publisherFlushes
        _ = diagnostics.publisherFlushesWithoutEmission
        _ = diagnostics.publisherBatchStartGap
        _ = diagnostics.publisherFlushStartGap
        _ = diagnostics.publisherFlushSchedulingDelay
        _ = diagnostics.publisherSnapshotDuration
        _ = diagnostics.publisherEmitDuration
        _ = diagnostics.mailboxFramesSent
        _ = diagnostics.mailboxFramesDelivered
        _ = diagnostics.mailboxFramesCoalesced
        _ = diagnostics.mailboxFramesEvicted
        _ = diagnostics.mailboxFrameQueueDelay
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
        _ = diagnostics.metalPresentedFrames
        _ = diagnostics.metalPresentationErrors
        _ = diagnostics.cpuFallbackFrames
        _ = diagnostics.metalUnavailableFallbackFrames
        _ = diagnostics.missingIOSurfaceFallbackFrames
        _ = diagnostics.ioSurfaceDimensionMismatchFallbackFrames
        _ = diagnostics.pixelFormatMismatchFallbackFrames
        _ = diagnostics.textureCreationFailedFallbackFrames
        _ = diagnostics.lastCPUFallbackReason
        _ = diagnostics.metalFramesSupersededBeforeDraw
        _ = diagnostics.metalDrawableMisses
        _ = diagnostics.metalCommandCreationFailures
        let timing: SpiceTimingSummary = diagnostics.viewUpdateToMetalCommit
        requireSendable(timing)
        _ = timing.sampleCount
        _ = timing.p95Milliseconds
        _ = timing.maximumMilliseconds
        _ = diagnostics.metalCommitToCompletion

        let presentation: SpicePresentationMetrics =
            session.presentationDiagnostics.snapshot()
        requireSendable(presentation)
        let _: Bool = presentation == .empty
        _ = presentation.metalFramesSupersededBeforeDraw
        _ = presentation.metalDrawableMisses
        _ = presentation.metalCommandCreationFailures
        _ = presentation.viewUpdateToMetalCommit
        _ = presentation.metalCommitToCompletion

        let agentManager = SpiceAgentManager()
        let agentDiagnostics: SpiceAgentWireDiagnostics =
            await agentManager.diagnosticsSnapshot()
        requireSendable(agentDiagnostics)
        let _: Bool = agentDiagnostics == .empty
        _ = agentDiagnostics.capabilityAnnouncementsAttempted
        _ = agentDiagnostics.capabilityAnnouncementsSent
        _ = agentDiagnostics.capabilityAnnouncementFailures
        _ = agentDiagnostics.inboundMessages
        _ = agentDiagnostics.inboundCurrentProtocolMessages
        _ = agentDiagnostics.inboundUnexpectedProtocolMessages
        _ = agentDiagnostics.inboundCapabilityAnnouncements
        _ = agentDiagnostics.inboundClipboardMessages
        _ = agentDiagnostics.inboundClipboardDataMessages
        _ = agentDiagnostics.inboundClipboardGrabMessages
        _ = agentDiagnostics.inboundClipboardRequestMessages
        _ = agentDiagnostics.inboundClipboardReleaseMessages
        _ = agentDiagnostics.inboundMonitorReplies
        _ = agentDiagnostics.inboundFileTransferMessages
        _ = agentDiagnostics.inboundOtherMessages
        _ = agentDiagnostics.inboundDecodeFailures
        _ = agentDiagnostics.peerLegacyClipboardCapability
        _ = agentDiagnostics.peerClipboardByDemandCapability
        _ = agentDiagnostics.clipboardFailures
        _ = agentDiagnostics.lastClipboardFailureCategory
        _ = agentDiagnostics.lastInboundProtocolID
        _ = agentDiagnostics.lastInboundMessageType
    }
}

private func requireSendable<T: Sendable>(_ value: T) {
    _ = value
}
