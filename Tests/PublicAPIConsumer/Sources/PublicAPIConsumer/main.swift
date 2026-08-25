import SwiftSpice

@main
struct PublicAPIConsumer {
    static func main() async {
        let session = SpiceSession()
        let desktop: SpiceDesktopSource = session.desktop
        requireSendable(desktop)
        let subscription: SpiceDesktopSubscription = desktop.subscribe(surface: .primary)
        let updates: AsyncStream<SpiceDesktopSnapshot> = subscription.updates
        requireSendable(updates)
        subscription.setDemand(.none)
        subscription.cancel()

        let diagnostics: SpiceSessionDiagnostics = await session.diagnosticsSnapshot()
        requireSendable(diagnostics)
        let _: Bool = diagnostics == .empty

        _ = diagnostics.displayChannelCount
        _ = diagnostics.damageOperations
        _ = diagnostics.damageBytes
        _ = diagnostics.snapshots
        _ = diagnostics.fullFrameCopyBytes
        _ = diagnostics.partialFrameCopyBytes
        _ = diagnostics.directIOSurfaceWriteBytes
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
        _ = diagnostics.publisherDemandSuppressedSubmissions
        _ = diagnostics.publisherPendingRevisionCoalesces
        _ = diagnostics.publisherPreparedFrameCoalesces
        _ = diagnostics.publisherDemandedSurfaces
        _ = diagnostics.publisherPreparedFrames
        _ = diagnostics.publisherBatchStartGap
        _ = diagnostics.publisherFramedReceiveBatchStartGap
        _ = diagnostics.publisherMessageReceiveToSurfaceReady
        _ = diagnostics.publisherSurfaceReadyToSubmit
        _ = diagnostics.publisherFlushStartGap
        _ = diagnostics.publisherFlushSchedulingDelay
        _ = diagnostics.publisherSnapshotDuration
        _ = diagnostics.publisherEmitDuration
        _ = diagnostics.desktopDeliveredSnapshots
        _ = diagnostics.desktopStreamCoalesces
        _ = diagnostics.desktopHandlerDeliveries
        _ = diagnostics.desktopSubscriptions
        _ = diagnostics.desktopVisibleSubscriptions
        _ = diagnostics.videoDecoderSessionCreations
        _ = diagnostics.videoHardwareSessions
        _ = diagnostics.videoSoftwareSessions
        _ = diagnostics.videoHardwareQueryFailures
        _ = diagnostics.videoDecodedFrames
        _ = diagnostics.videoDroppedFrames
        _ = diagnostics.videoCPUMaterializations
        _ = diagnostics.mjpegDecoderHandleCreations
        _ = diagnostics.mjpegDecodedFrames
        _ = diagnostics.mjpegIOSurfaceFrames
        _ = diagnostics.mjpegDataFallbacks
        _ = diagnostics.mjpegIOSurfaceAllocations
        _ = diagnostics.mjpegPeakBuffersInUse
        _ = diagnostics.mjpegPeakConcurrentDecodes
        _ = diagnostics.mjpegFramesSupersededBeforeDecode
        _ = diagnostics.advancedCPUFallbackFrames
        _ = diagnostics.metalGenerationDisableCount
        _ = diagnostics.firstMetalGenerationDisableReason
        _ = diagnostics.surfaceAllocatedBytes
        _ = diagnostics.maximumSurfaceBytes
        _ = diagnostics.metalPresentedFrames
        _ = diagnostics.advancedVideoPresentedFrames
        _ = diagnostics.metalPresentationErrors
        _ = diagnostics.cpuFallbackFrames
        _ = diagnostics.metalUnavailableFallbackFrames
        _ = diagnostics.missingIOSurfaceFallbackFrames
        _ = diagnostics.ioSurfaceDimensionMismatchFallbackFrames
        _ = diagnostics.pixelFormatMismatchFallbackFrames
        _ = diagnostics.textureCreationFailedFallbackFrames
        _ = diagnostics.metalCommandFailureFallbackFrames
        _ = diagnostics.lastCPUFallbackReason
        _ = diagnostics.metalFramesSupersededBeforeDraw
        _ = diagnostics.metalDrawableMisses
        _ = diagnostics.metalCommandCreationFailures
        _ = diagnostics.metalCommandBuffersCommitted
        _ = diagnostics.metalTextureCacheHits
        _ = diagnostics.metalTextureCacheMisses
        _ = diagnostics.metalTextureCacheEvictions
        _ = diagnostics.metalGPUBusySkips
        _ = diagnostics.desktopDisplayLinkWakeups
        _ = diagnostics.desktopDisplayLinkTicks
        _ = diagnostics.desktopDisplayLinkIdlePauses
        _ = diagnostics.desktopReadyToDisplayLink
        let timing: SpiceTimingSummary = diagnostics.viewUpdateToMetalCommit
        requireSendable(timing)
        _ = timing.sampleCount
        _ = timing.p95Milliseconds
        _ = timing.maximumMilliseconds
        _ = diagnostics.metalCommitToCompletion
        _ = diagnostics.metalRequestToPresented

        let agentManager = SpiceAgentManager()
        await agentManager.waitForSessionReconnectBoundary()
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
