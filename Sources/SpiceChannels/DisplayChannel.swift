import Foundation
import SpiceCodecs
import SpiceCore
import SpiceProtocol
import SpiceRenderer
import SpiceVideoToolbox
import SpiceWire

package enum DisplayEvent: Sendable, Equatable {
    case surfaceCreated(UInt32)
    case surfaceDestroyed(UInt32)
    case frameChanged(SurfaceRevision)
    case monitorsConfigured(SpiceDisplayMonitorsConfiguration)
    case ignored(UInt16)
}

package struct DisplayChannelDiagnostics: Sendable, Equatable {
    package let surfaces: SurfaceStoreMetrics
    package let publisher: DisplayFramePublisherMetrics
    package let advancedVideo: SpiceAdvancedVideoDecoderDiagnostics
    package let mjpeg: DisplayMJPEGDiagnostics
    package let advancedCPUFallbackFrames: UInt64
    package let metalGenerationDisableCount: UInt64
    package let firstMetalGenerationDisableReason: String?
    package let imageCacheCommittedMutations: UInt64
    package let imageCacheInvalidatedMutations: UInt64
    package let imageCacheDiscardedMutations: UInt64
}

package struct DisplayMJPEGDiagnostics: Sendable, Equatable {
    package var handleCreations: UInt64 = 0
    package var decodedFrames: UInt64 = 0
    package var ioSurfaceFrames: UInt64 = 0
    package var dataFallbacks: UInt64 = 0
    package var ioSurfaceAllocations: UInt64 = 0
    package var peakBuffersInUse: Int = 0
    package var peakConcurrentDecodes: Int = 0
    package var supersededBeforeDecode: UInt64 = 0

    package mutating func accumulate(_ diagnostics: SpiceMJPEGDecoderDiagnostics) {
        handleCreations &+= diagnostics.handleCreationCount
        decodedFrames &+= diagnostics.decodedFrameCount
        ioSurfaceFrames &+= diagnostics.ioSurfaceFrameCount
        dataFallbacks &+= diagnostics.dataFallbackCount
        ioSurfaceAllocations &+= diagnostics.ioSurfaceAllocationCount
        peakBuffersInUse = max(peakBuffersInUse, diagnostics.peakBuffersInUse)
        peakConcurrentDecodes = max(
            peakConcurrentDecodes,
            diagnostics.decodeLimiter.peakDecodeCount
        )
    }
}

package actor DisplayChannel: SpiceManagedChannel {
    private static let pixmapCachePixels: UInt64 = 16 * 1_024 * 1_024
    private static let glzDictionaryWindowPixels: Int32 = 8 * 1_024 * 1_024

    private enum ResolvedSource: Sendable {
        case bitmap(RawBitmap)
        case surface(UInt32)
    }

    private struct ImageCacheMutationIntent: Sendable {
        let id: UInt64
        let lossy: Bool
        let mode: DisplayImageCacheReservationMode
        let retainedByteCount: Int
    }

    private struct VideoStream: Sendable {
        let surfaceID: UInt32
        let surfaceLifecycleGeneration: UInt64
        let streamID: UInt32
        let generation: UInt64
        let topDown: Bool
        let streamWidth: Int
        let streamHeight: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let destination: SpiceRect
        let codec: SpiceVideoCodec
        var advancedDecoder: (any SpiceAdvancedVideoDecoder)?
        var mjpegDecoder: SpiceMJPEGStreamDecoder?
        var clip: SpiceClip
        var nextFrameSequence: UInt64
        var lastPresentedSequence: UInt64
        var lastMultimediaTime: UInt32?
        var metalCompositorDisabled: Bool
    }

    private struct PendingMJPEGFrame: Sendable {
        let streamID: UInt32
        let streamGeneration: UInt64
        let runGeneration: UInt64
        let originConnection: ChannelConnection
        let expectedMutationBarrier: SurfaceMutationBarrier
        let videoSequence: SurfaceVideoSequence
        let clip: SpiceClip
        let multimediaTime: UInt32
        let sizing: (width: UInt32, height: UInt32, destination: SpiceRect)?
        let data: Data
        let receivedAt: ContinuousClock.Instant
    }

    private var connection: ChannelConnection
    private let surfaces: SurfaceStore
    private let imageCache: DisplayImageCache
    private let ownsImageCache: Bool
    private let jpegDecoder: any SpiceImageDecoder
    private let lzDecoder: any SpiceImageDecoder
    private let codecTaskExecutor: SpiceCodecTaskExecutor
    private let glzDecoder: SpiceGLZDecoder
    private let zlibInflator: SpiceZlibInflator
    private let paletteLZDecoder: any SpicePaletteImageDecoder
    private let quicDecoder: any SpiceImageDecoder
    private let advancedVideoDecoderFactory: any SpiceAdvancedVideoDecoderFactory
    private let mjpegDecodeLimiter: SpiceMJPEGDecodeLimiter
    private let usesInjectedJPEGDecoder: Bool
    private let multimediaClock: (any MultimediaClockScheduling)?
    private let maximumCachedPalettes: Int
    private let maximumStreams: Int
    private let framePublicationInterval: Duration
    private let frameDemandCoordinator: DisplayFrameDemandCoordinator?
    private var palettes: [UInt64: SpiceLZPalette] = [:]
    private var streams: [UInt32: VideoStream] = [:]
    private var asynchronousMJPEGRunGeneration: UInt64?
    private var nextRunGeneration: UInt64 = 0
    private var asynchronousMJPEGRunConnections: [UInt64: ChannelConnection] = [:]
    private var pendingMJPEGFrames: [UInt32: PendingMJPEGFrame] = [:]
    private var mjpegFrameTasks: [UInt32: Task<Void, Never>] = [:]
    private var nextSurfaceVideoSequences: [UInt32: UInt64] = [:]
    private var asynchronousFailure: ChannelError?
    private var mjpegFramesSupersededBeforeDecode: UInt64 = 0
    private var nextStreamGeneration: UInt64 = 1
    private var framePublishers: [ObjectIdentifier: DisplayFramePublisher] = [:]
    private var completedPublisherMetrics = DisplayFramePublisherMetrics()
    private let diagnosticsClock = ContinuousClock()
    private var currentMessageReceivedAt: ContinuousClock.Instant?
    private var currentMessageRetainedByteCount: Int?
    private var completedFrameSourceTiming: DisplayFrameSourceTiming?
    private var retiredAdvancedVideoDiagnostics = SpiceAdvancedVideoDecoderDiagnostics()
    private var retiredMJPEGDiagnostics = DisplayMJPEGDiagnostics()
    private var advancedCPUFallbackFrames: UInt64 = 0
    private var metalGenerationDisableCount: UInt64 = 0
    private var firstMetalGenerationDisableReason: String?
    private var imageCacheCommittedMutations: UInt64 = 0
    private var imageCacheInvalidatedMutations: UInt64 = 0
    private var imageCacheDiscardedMutations: UInt64 = 0

    package init(
        connection: ChannelConnection,
        surfaces: SurfaceStore = SurfaceStore(),
        imageCache: DisplayImageCache? = nil,
        codecTaskExecutor: SpiceCodecTaskExecutor = SpiceCodecTaskExecutor(),
        jpegDecoder: any SpiceImageDecoder = SpiceJPEGDecoder(),
        lzDecoder: any SpiceImageDecoder = SpiceLZDecoder(),
        glzDecoder: SpiceGLZDecoder? = nil,
        zlibInflator: SpiceZlibInflator = SpiceZlibInflator(),
        paletteLZDecoder: any SpicePaletteImageDecoder = SpiceLZDecoder(),
        quicDecoder: any SpiceImageDecoder = SpiceQUICDecoder(),
        advancedVideoDecoderFactory: any SpiceAdvancedVideoDecoderFactory = SpiceVideoToolboxDecoderFactory(),
        multimediaClock: (any MultimediaClockScheduling)? = nil,
        maximumCachedPalettes: Int = 256,
        maximumCachedImages: Int = 256,
        maximumCachedImageBytes: Int = 256 * 1_024 * 1_024,
        maximumStreams: Int = 64,
        framePublicationInterval: Duration = .milliseconds(16),
        frameDemandCoordinator: DisplayFrameDemandCoordinator? = nil,
        mjpegDecodeLimiter: SpiceMJPEGDecodeLimiter = .init(maximumConcurrent: 2)
    ) {
        self.connection = connection
        self.surfaces = surfaces
        if let imageCache {
            self.imageCache = imageCache
            ownsImageCache = false
        } else {
            self.imageCache = DisplayImageCache(
                maximumEntries: maximumCachedImages,
                maximumBytes: maximumCachedImageBytes
            )
            ownsImageCache = true
        }
        self.jpegDecoder = jpegDecoder
        self.lzDecoder = lzDecoder
        self.codecTaskExecutor = codecTaskExecutor
        self.glzDecoder = glzDecoder ?? SpiceGLZDecoder(executor: codecTaskExecutor)
        self.zlibInflator = zlibInflator
        self.paletteLZDecoder = paletteLZDecoder
        self.quicDecoder = quicDecoder
        self.advancedVideoDecoderFactory = advancedVideoDecoderFactory
        usesInjectedJPEGDecoder = !(jpegDecoder is SpiceJPEGDecoder)
        self.multimediaClock = multimediaClock
        self.maximumCachedPalettes = max(1, maximumCachedPalettes)
        self.maximumStreams = min(64, max(1, maximumStreams))
        self.framePublicationInterval = framePublicationInterval
        self.frameDemandCoordinator = frameDemandCoordinator
        self.mjpegDecodeLimiter = mjpegDecodeLimiter
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        let runConnection = connection
        let runGeneration = beginAsynchronousMJPEGScheduling()
        defer { stopAsynchronousMJPEGScheduling(runGeneration: runGeneration) }
        try await connection.send(SpiceMsgcDisplayInit(
            pixmapCacheID: 1,
            pixmapCacheSize: Self.pixmapCachePixels,
            glzDictionaryID: 1,
            glzDictionaryWindowSize: Self.glzDictionaryWindowPixels
        ))
        let framePublisher = DisplayFramePublisher(
            interval: frameDemandCoordinator == nil ? framePublicationInterval : .zero,
            requiresExplicitDemand: frameDemandCoordinator != nil,
            waitsForConsumption: frameDemandCoordinator != nil,
            snapshot: { [surfaces] surfaceRevision in
                await surfaces.publicationSnapshot(atLeast: surfaceRevision)
            },
            emit: { frame in
                await emit(.frame(frame))
            }
        )
        framePublishers[ObjectIdentifier(framePublisher)] = framePublisher
        let demandPipe = AsyncStream.makeStream(
            of: DisplayFrameDemandEvent.self,
            bufferingPolicy: .unbounded
        )
        let demandTask = Task {
            for await event in demandPipe.stream {
                guard !Task.isCancelled else { return }
                switch event {
                case let .demandChanged(surfaceID, isDemanded):
                    await framePublisher.setDemand(
                        surfaceID: surfaceID,
                        isDemanded: isDemanded
                    )
                case let .frameConsumed(revision):
                    await framePublisher.acknowledge(revision)
                }
            }
        }
        let demandRegistration = frameDemandCoordinator?.register(
            channelID: connection.key.id
        ) { event in
            _ = demandPipe.continuation.yield(event)
        }
        defer {
            demandRegistration?.cancel()
            demandPipe.continuation.finish()
            demandTask.cancel()
        }
        do {
            while !Task.isCancelled {
                let event = try await processNext(runGeneration: runGeneration)
                switch event {
                case let .surfaceCreated(surfaceID):
                    await emit(.surfaceCreated(surfaceID))
                case let .surfaceDestroyed(surfaceID):
                    await framePublisher.remove(surfaceID: surfaceID)
                    await emit(.surfaceDestroyed(surfaceID))
                case let .frameChanged(surfaceRevision):
                    await framePublisher.submit(
                        surfaceRevision,
                        sourceTiming: completedFrameSourceTiming
                    )
                case let .monitorsConfigured(configuration):
                    await emit(.displayMonitors(
                        channelID: connection.key.id,
                        configuration
                    ))
                case .ignored:
                    break
                }
            }
        } catch {
            await retireFramePublisher(framePublisher)
            throw error
        }
        if connection === runConnection {
            await runConnection.fail(.transport(.cancelled))
        }
        await retireFramePublisher(framePublisher)
    }

    package func processNext() async throws(ChannelError) -> DisplayEvent {
        try await processNext(runGeneration: nil)
    }

    private func processNext(
        runGeneration: UInt64?
    ) async throws(ChannelError) -> DisplayEvent {
        let activeConnection = connection
        do {
            return try await processNextImpl(runGeneration: runGeneration)
        } catch let error {
            if connection === activeConnection {
                await activeConnection.fail(error)
            }
            throw error
        }
    }

    private func processNextImpl(
        runGeneration: UInt64?
    ) async throws(ChannelError) -> DisplayEvent {
        if let asynchronousFailure {
            throw asynchronousFailure
        }
        completedFrameSourceTiming = nil
        let framed = try await connection.receive()
        currentMessageReceivedAt = diagnosticsClock.now
        currentMessageRetainedByteCount = framed.retainedBodyByteCount
        let message: SpiceServerMessage
        do {
            message = try SpiceServerMessageDecoder.decode(
                id: framed.type,
                body: framed.bodySlice,
                channel: .display
            )
        } catch let error {
            throw .wire(error)
        }

        switch message {
        case let .displaySurfaceCreate(create):
            do {
                try await surfaces.create(
                    id: create.surfaceID,
                    width: create.width,
                    height: create.height,
                    format: create.format
                )
            } catch {
                throw .protocolViolation(String(describing: error))
            }
            try await acknowledgeIfNeeded()
            return .surfaceCreated(create.surfaceID)
        case let .displaySurfaceDestroy(destroy):
            let removedStreams = streams.values.filter { $0.surfaceID == destroy.surfaceID }
            streams = streams.filter { $0.value.surfaceID != destroy.surfaceID }
            for stream in removedStreams {
                cancelScheduledMJPEG(streamID: stream.streamID)
                await retireAdvancedDecoder(stream.advancedDecoder)
                await retireMJPEGDecoder(stream.mjpegDecoder)
            }
            do {
                try await surfaces.destroy(id: destroy.surfaceID)
            } catch {
                throw .protocolViolation(String(describing: error))
            }
            try await acknowledgeIfNeeded()
            return .surfaceDestroyed(destroy.surfaceID)
        case .displayReset:
            palettes.removeAll(keepingCapacity: true)
            let removedStreams = Array(streams.values)
            streams.removeAll(keepingCapacity: true)
            for stream in removedStreams {
                cancelScheduledMJPEG(streamID: stream.streamID)
                await retireAdvancedDecoder(stream.advancedDecoder)
                await retireMJPEGDecoder(stream.mjpegDecoder)
            }
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayInvalidateImages(imageIDs):
            await imageCache.invalidate(ids: imageIDs)
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayInvalidateAllImages(waits):
            try await connection.waitUntilProcessed(waits.map {
                ChannelSerialBarrier.Requirement(
                    key: ChannelKey(type: $0.channelType, id: $0.channelID),
                    serial: $0.messageSerial
                )
            })
            await imageCache.invalidateAll()
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayInvalidatePalette(paletteID):
            palettes.removeValue(forKey: paletteID)
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case .displayInvalidateAllPalettes:
            palettes.removeAll(keepingCapacity: true)
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayStreamCreate(create):
            try await createStream(create)
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayStreamData(data):
            if let runGeneration,
               streams[data.streamID]?.codec == .mjpeg {
                try await enqueueMJPEGFrame(
                    streamID: data.streamID,
                    runGeneration: runGeneration,
                    multimediaTime: data.multimediaTime,
                    sizing: nil,
                    data: data.data,
                    receivedAt: currentMessageReceivedAt ?? diagnosticsClock.now
                )
                try await acknowledgeIfNeeded()
                return .ignored(framed.type)
            }
            let surfaceRevision = try await renderStreamFrame(
                streamID: data.streamID,
                multimediaTime: data.multimediaTime,
                sizing: nil,
                data: data.data,
                videoSequence: try reserveVideoSequence(streamID: data.streamID)
            )
            let event = frameEvent(surfaceRevision, ignoredType: framed.type)
            try await acknowledgeIfNeeded()
            return event
        case let .displayStreamDataSized(data):
            if let runGeneration,
               streams[data.streamID]?.codec == .mjpeg {
                try await enqueueMJPEGFrame(
                    streamID: data.streamID,
                    runGeneration: runGeneration,
                    multimediaTime: data.multimediaTime,
                    sizing: (data.width, data.height, data.destination),
                    data: data.data,
                    receivedAt: currentMessageReceivedAt ?? diagnosticsClock.now
                )
                try await acknowledgeIfNeeded()
                return .ignored(framed.type)
            }
            let surfaceRevision = try await renderStreamFrame(
                streamID: data.streamID,
                multimediaTime: data.multimediaTime,
                sizing: (data.width, data.height, data.destination),
                data: data.data,
                videoSequence: try reserveVideoSequence(streamID: data.streamID)
            )
            let event = frameEvent(surfaceRevision, ignoredType: framed.type)
            try await acknowledgeIfNeeded()
            return event
        case let .displayStreamClip(clip):
            try await updateStreamClip(clip)
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayStreamDestroy(streamID):
            guard let removed = streams.removeValue(forKey: streamID) else {
                throw .protocolViolation("destroy of unknown stream \(streamID)")
            }
            cancelScheduledMJPEG(streamID: streamID)
            await retireAdvancedDecoder(removed.advancedDecoder)
            await retireMJPEGDecoder(removed.mjpegDecoder)
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case .displayStreamDestroyAll:
            let removedStreams = Array(streams.values)
            streams.removeAll(keepingCapacity: true)
            for stream in removedStreams {
                cancelScheduledMJPEG(streamID: stream.streamID)
                await retireAdvancedDecoder(stream.advancedDecoder)
                await retireMJPEGDecoder(stream.mjpegDecoder)
            }
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayMonitorsConfiguration(configuration):
            try await acknowledgeIfNeeded()
            guard !configuration.monitors.isEmpty else {
                return .ignored(framed.type)
            }
            return .monitorsConfigured(configuration)
        case let .displayCopyBits(command):
            let surfaceRevision = try await execute(command)
            let event = frameEvent(surfaceRevision, ignoredType: framed.type)
            try await acknowledgeIfNeeded()
            return event
        case let .displayDrawFill(command):
            let surfaceRevision = try await execute(command)
            let event = frameEvent(surfaceRevision, ignoredType: framed.type)
            try await acknowledgeIfNeeded()
            return event
        case let .displayDrawCopy(command):
            let surfaceRevision = try await execute(command)
            let event = frameEvent(surfaceRevision, ignoredType: framed.type)
            try await acknowledgeIfNeeded()
            return event
        case let .setAck(setAck):
            await connection.configureAcknowledgments(
                generation: setAck.generation,
                window: setAck.window
            )
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .ping(ping):
            try await connection.send(SpiceMsgcPong(id: ping.id, time: ping.time))
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case .disconnecting:
            throw .transport(.connectionClosed)
        case .unknown:
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case .mainInit,
             .mainMultimediaTime,
             .mainChannelsList,
             .mainMouseMode,
             .mainAgentConnected,
             .mainAgentDisconnected,
             .mainAgentData,
             .mainAgentToken,
             .mainMigration,
             .inputsInit,
             .inputsKeyModifiers,
             .inputsMouseMotionAck,
             .cursor,
             .playback,
             .record,
             .smartcard:
            throw .protocolViolation("message received on wrong Display Channel")
        }
    }

    package func snapshot(surfaceID: UInt32) async throws(ChannelError) -> FrameSnapshot {
        do {
            return try await surfaces.snapshot(surfaceID: surfaceID)
        } catch {
            throw .protocolViolation(String(describing: error))
        }
    }

    private func frameEvent(
        _ surfaceRevision: SurfaceRevision?,
        ignoredType: UInt16
    ) -> DisplayEvent {
        guard let surfaceRevision else { return .ignored(ignoredType) }
        if let currentMessageReceivedAt {
            completedFrameSourceTiming = DisplayFrameSourceTiming(
                messageReceivedAt: currentMessageReceivedAt,
                surfaceReadyAt: diagnosticsClock.now
            )
        }
        return .frameChanged(surfaceRevision)
    }

    private func enqueueMJPEGFrame(
        streamID: UInt32,
        runGeneration: UInt64,
        multimediaTime: UInt32,
        sizing: (width: UInt32, height: UInt32, destination: SpiceRect)?,
        data: Data,
        receivedAt: ContinuousClock.Instant
    ) async throws(ChannelError) {
        guard let stream = streams[streamID], stream.codec == .mjpeg else {
            throw .protocolViolation("data for unknown MJPEG stream \(streamID)")
        }
        let expectedMutationBarrier: SurfaceMutationBarrier
        do {
            expectedMutationBarrier = try await surfaces.descriptor(
                surfaceID: stream.surfaceID
            ).mutationBarrier
        } catch {
            throw .protocolViolation(String(describing: error))
        }
        guard streams[streamID]?.generation == stream.generation else {
            return
        }
        let videoSequence = try reserveVideoSequence(for: stream)
        guard let originConnection = asynchronousMJPEGRunConnections[runGeneration] else {
            return
        }
        if pendingMJPEGFrames[streamID] != nil {
            mjpegFramesSupersededBeforeDecode &+= 1
        }
        pendingMJPEGFrames[streamID] = PendingMJPEGFrame(
            streamID: streamID,
            streamGeneration: stream.generation,
            runGeneration: runGeneration,
            originConnection: originConnection,
            expectedMutationBarrier: expectedMutationBarrier,
            videoSequence: videoSequence,
            clip: stream.clip,
            multimediaTime: multimediaTime,
            sizing: sizing,
            data: data,
            receivedAt: receivedAt
        )
        guard mjpegFrameTasks[streamID] == nil else { return }
        mjpegFrameTasks[streamID] = Task { [weak self] in
            await self?.drainScheduledMJPEG(
                streamID: streamID,
                streamGeneration: stream.generation
            )
        }
    }

    private func drainScheduledMJPEG(
        streamID: UInt32,
        streamGeneration: UInt64
    ) async {
        while !Task.isCancelled {
            guard streams[streamID]?.generation == streamGeneration,
                  let pending = pendingMJPEGFrames.removeValue(forKey: streamID),
                  pending.streamGeneration == streamGeneration
            else {
                break
            }
            do {
                guard let revision = try await renderStreamFrame(
                    streamID: pending.streamID,
                    multimediaTime: pending.multimediaTime,
                    sizing: pending.sizing,
                    data: pending.data,
                    expectedMutationBarrier: pending.expectedMutationBarrier,
                    videoSequence: pending.videoSequence,
                    clipOverride: pending.clip
                ) else {
                    continue
                }
                let timing = DisplayFrameSourceTiming(
                    messageReceivedAt: pending.receivedAt,
                    surfaceReadyAt: diagnosticsClock.now
                )
                let publishers = Array(framePublishers.values)
                for publisher in publishers {
                    await publisher.submit(revision, sourceTiming: timing)
                }
            } catch {
                guard !Task.isCancelled,
                      streams[streamID]?.generation == streamGeneration
                else {
                    break
                }
                guard asynchronousMJPEGRunGeneration == pending.runGeneration,
                      connection === pending.originConnection
                else {
                    continue
                }
                asynchronousFailure = error
                await connection.close()
                break
            }
        }
        if streams[streamID]?.generation == streamGeneration {
            mjpegFrameTasks.removeValue(forKey: streamID)
        }
    }

    private func reserveVideoSequence(
        for stream: VideoStream
    ) throws(ChannelError) -> SurfaceVideoSequence {
        let current = nextSurfaceVideoSequences[stream.surfaceID, default: 0]
        let (next, overflow) = current.addingReportingOverflow(1)
        guard !overflow else {
            throw .protocolViolation("surface video sequence overflow")
        }
        nextSurfaceVideoSequences[stream.surfaceID] = next
        return SurfaceVideoSequence(
            surfaceID: stream.surfaceID,
            lifecycleGeneration: stream.surfaceLifecycleGeneration,
            value: next
        )
    }

    private func reserveVideoSequence(
        streamID: UInt32
    ) throws(ChannelError) -> SurfaceVideoSequence {
        guard let stream = streams[streamID] else {
            throw .protocolViolation("data for unknown stream \(streamID)")
        }
        return try reserveVideoSequence(for: stream)
    }

    private func cancelScheduledMJPEG(streamID: UInt32) {
        pendingMJPEGFrames.removeValue(forKey: streamID)
        mjpegFrameTasks.removeValue(forKey: streamID)?.cancel()
    }

    private func beginAsynchronousMJPEGScheduling() -> UInt64 {
        nextRunGeneration &+= 1
        if nextRunGeneration == 0 {
            nextRunGeneration = 1
        }
        asynchronousMJPEGRunGeneration = nextRunGeneration
        asynchronousMJPEGRunConnections[nextRunGeneration] = connection
        return nextRunGeneration
    }

    private func stopAsynchronousMJPEGScheduling(runGeneration: UInt64? = nil) {
        if let runGeneration {
            asynchronousMJPEGRunConnections.removeValue(forKey: runGeneration)
            if asynchronousMJPEGRunGeneration != runGeneration {
                return
            }
        } else {
            asynchronousMJPEGRunConnections.removeAll(keepingCapacity: false)
        }
        asynchronousMJPEGRunGeneration = nil
        pendingMJPEGFrames.removeAll(keepingCapacity: false)
        for task in mjpegFrameTasks.values {
            task.cancel()
        }
        mjpegFrameTasks.removeAll(keepingCapacity: false)
    }

    package func close() async {
        stopAsynchronousMJPEGScheduling()
        await connection.close()
        if ownsImageCache {
            await imageCache.close()
        }
        let publishers = Array(framePublishers.values)
        for publisher in publishers {
            await retireFramePublisher(publisher)
        }
        let removedStreams = Array(streams.values)
        streams.removeAll(keepingCapacity: false)
        for stream in removedStreams {
            cancelScheduledMJPEG(streamID: stream.streamID)
            await retireAdvancedDecoder(stream.advancedDecoder)
            await retireMJPEGDecoder(stream.mjpegDecoder)
        }
        await surfaces.close()
    }

    package func diagnosticsSnapshot() async -> DisplayChannelDiagnostics {
        var advancedVideo = retiredAdvancedVideoDiagnostics
        let activeDecoders = streams.values.compactMap(\.advancedDecoder)
        for decoder in activeDecoders {
            advancedVideo.accumulate(await decoder.diagnosticsSnapshot())
        }
        var publisherMetrics = completedPublisherMetrics
        let activePublishers = Array(framePublishers.values)
        for publisher in activePublishers {
            publisherMetrics.accumulate(await publisher.metrics())
        }
        var mjpeg = retiredMJPEGDiagnostics
        let activeMJPEGDecoders = streams.values.compactMap(\.mjpegDecoder)
        for decoder in activeMJPEGDecoders {
            mjpeg.accumulate(await decoder.diagnosticsSnapshot())
        }
        mjpeg.supersededBeforeDecode = mjpegFramesSupersededBeforeDecode
        return DisplayChannelDiagnostics(
            surfaces: await surfaces.metrics(),
            publisher: publisherMetrics,
            advancedVideo: advancedVideo,
            mjpeg: mjpeg,
            advancedCPUFallbackFrames: advancedCPUFallbackFrames,
            metalGenerationDisableCount: metalGenerationDisableCount,
            firstMetalGenerationDisableReason: firstMetalGenerationDisableReason,
            imageCacheCommittedMutations: imageCacheCommittedMutations,
            imageCacheInvalidatedMutations: imageCacheInvalidatedMutations,
            imageCacheDiscardedMutations: imageCacheDiscardedMutations
        )
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) async throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Display Channel")
        }
        let previous = connection
        try await replacement.activate()
        await previous.supersede(
            preservingSerialBarrier: previous.sharesSerialBarrier(with: replacement)
        )
        connection = replacement
        return previous
    }

    private func createStream(_ create: SpiceDisplayStreamCreate) async throws(ChannelError) {
        guard create.codec == .mjpeg || create.codec == .h264 || create.codec == .h265 else {
            throw .protocolViolation("unsupported stream codec \(create.codec.rawValue)")
        }
        guard streams[create.streamID] == nil else {
            throw .protocolViolation("duplicate stream \(create.streamID)")
        }
        guard streams.count < maximumStreams else {
            throw .protocolViolation("stream limit exceeded")
        }
        guard let streamWidth = Int(exactly: create.streamWidth),
              let streamHeight = Int(exactly: create.streamHeight),
              let sourceWidth = Int(exactly: create.sourceWidth),
              let sourceHeight = Int(exactly: create.sourceHeight)
        else {
            throw .protocolViolation("invalid stream dimensions")
        }
        let destination = try pixelRect(create.destination)
        let descriptor: SurfaceDescriptor
        do {
            descriptor = try await surfaces.descriptor(surfaceID: create.surfaceID)
        } catch {
            throw .protocolViolation(String(describing: error))
        }
        try validateStreamDestination(destination, in: descriptor)
        _ = try pixelRegion(
            destination: create.destination,
            clip: create.clip,
            surface: descriptor
        )

        let advancedDecoder: (any SpiceAdvancedVideoDecoder)?
        let mjpegDecoder: SpiceMJPEGStreamDecoder?
        do {
            switch create.codec {
            case .h264:
                advancedDecoder = try advancedVideoDecoderFactory.makeDecoder(
                    codec: .h264,
                    width: streamWidth,
                    height: streamHeight
                )
            case .h265:
                advancedDecoder = try advancedVideoDecoderFactory.makeDecoder(
                    codec: .h265,
                    width: streamWidth,
                    height: streamHeight
                )
            case .mjpeg:
                advancedDecoder = nil
            default:
                advancedDecoder = nil
            }
            if create.codec == .mjpeg, !usesInjectedJPEGDecoder {
                mjpegDecoder = try SpiceMJPEGStreamDecoder(limiter: mjpegDecodeLimiter)
            } else {
                mjpegDecoder = nil
            }
        } catch {
            throw Self.channelError(for: error)
        }

        let generation = nextStreamGeneration
        let (followingGeneration, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else {
            throw .protocolViolation("stream generation overflow")
        }
        nextStreamGeneration = followingGeneration
        streams[create.streamID] = VideoStream(
            surfaceID: create.surfaceID,
            surfaceLifecycleGeneration: descriptor.lifecycleGeneration,
            streamID: create.streamID,
            generation: generation,
            topDown: create.topDown,
            streamWidth: streamWidth,
            streamHeight: streamHeight,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            destination: create.destination,
            codec: create.codec,
            advancedDecoder: advancedDecoder,
            mjpegDecoder: mjpegDecoder,
            clip: create.clip,
            nextFrameSequence: 0,
            lastPresentedSequence: 0,
            lastMultimediaTime: nil,
            metalCompositorDisabled: false
        )
    }

    private func updateStreamClip(_ update: SpiceDisplayStreamClip) async throws(ChannelError) {
        guard let stream = streams[update.streamID] else {
            throw .protocolViolation("clip for unknown stream \(update.streamID)")
        }
        let expectedGeneration = stream.generation
        let expectedSurfaceID = stream.surfaceID
        let descriptor: SurfaceDescriptor
        do {
            descriptor = try await surfaces.descriptor(surfaceID: expectedSurfaceID)
        } catch {
            throw .protocolViolation(String(describing: error))
        }
        guard var current = streams[update.streamID],
              current.generation == expectedGeneration,
              current.surfaceID == expectedSurfaceID
        else {
            throw .protocolViolation("clip for retired stream \(update.streamID)")
        }
        _ = try pixelRegion(
            destination: current.destination,
            clip: update.clip,
            surface: descriptor
        )
        current.clip = update.clip
        streams[update.streamID] = current
    }

    private func renderStreamFrame(
        streamID: UInt32,
        multimediaTime: UInt32,
        sizing: (width: UInt32, height: UInt32, destination: SpiceRect)?,
        data: Data,
        expectedMutationBarrier: SurfaceMutationBarrier? = nil,
        videoSequence: SurfaceVideoSequence? = nil,
        clipOverride: SpiceClip? = nil
    ) async throws(ChannelError) -> SurfaceRevision? {
        guard var stream = streams[streamID] else {
            throw .protocolViolation("data for unknown stream \(streamID)")
        }
        let (frameSequence, overflow) = stream.nextFrameSequence.addingReportingOverflow(1)
        guard !overflow else {
            throw .protocolViolation("stream frame sequence overflow")
        }
        stream.nextFrameSequence = frameSequence
        streams[streamID] = stream

        let alreadyLate: Bool
        if let multimediaClock, case .late = await multimediaClock.timing(for: multimediaTime) {
            alreadyLate = true
        } else {
            alreadyLate = false
        }
        if alreadyLate, stream.codec == .mjpeg {
            return nil
        }

        let frameWidth: Int
        let frameHeight: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let destinationRect: SpiceRect
        if let sizing {
            guard let width = Int(exactly: sizing.width),
                  let height = Int(exactly: sizing.height)
            else {
                throw .protocolViolation("invalid sized stream dimensions")
            }
            frameWidth = width
            frameHeight = height
            sourceWidth = width
            sourceHeight = height
            destinationRect = sizing.destination
        } else {
            frameWidth = stream.streamWidth
            frameHeight = stream.streamHeight
            sourceWidth = stream.sourceWidth
            sourceHeight = stream.sourceHeight
            destinationRect = stream.destination
        }

        let decodedFrame: any SpiceDecodedVideoFrame
        do {
            if stream.codec == .mjpeg {
                let descriptor = SpiceCodecImageDescriptor(
                    width: frameWidth,
                    height: frameHeight
                )
                if let decoder = stream.mjpegDecoder {
                    decodedFrame = try await decoder.decodeVideoFrame(
                        descriptor: descriptor,
                        payload: data
                    )
                } else {
                    await mjpegDecodeLimiter.acquire()
                    let result: Result<SpiceDecodedImage, SpiceCodecError>
                    if Task.isCancelled {
                        result = .failure(.cancelled)
                    } else {
                        do {
                            result = .success(try await jpegDecoder.decode(
                                descriptor: descriptor,
                                payload: data
                            ))
                        } catch {
                            result = .failure(error)
                        }
                    }
                    await mjpegDecodeLimiter.release()
                    decodedFrame = try result.get()
                }
            } else {
                guard let decoder = stream.advancedDecoder else {
                    throw SpiceCodecError.backendFailure("advanced stream has no decoder")
                }
                guard let advanced = try await decoder.decodeVideoFrame(
                    payload: data,
                    multimediaTime: multimediaTime
                ) else {
                    return nil
                }
                decodedFrame = advanced
            }
        } catch let error as SpiceCodecError {
            throw Self.channelError(for: error)
        } catch {
            throw .protocolViolation("video decode failed: \(String(describing: error))")
        }
        if alreadyLate {
            return nil
        }
        if let multimediaClock {
            let timing: MultimediaFrameTiming
            do {
                timing = try await multimediaClock.wait(until: multimediaTime)
            } catch is CancellationError {
                throw .transport(.cancelled)
            } catch {
                throw .protocolViolation("multimedia clock wait failed: \(error)")
            }
            guard timing == .due else {
                return nil
            }
        }
        guard let current = streams[streamID],
              current.generation == stream.generation,
              frameSequence > current.lastPresentedSequence
        else {
            return nil
        }

        let destination = try pixelRect(destinationRect)
        let surfaceDescriptor: SurfaceDescriptor
        do {
            surfaceDescriptor = try await surfaces.descriptor(surfaceID: stream.surfaceID)
        } catch {
            throw .protocolViolation(String(describing: error))
        }
        let clippedRegion = try pixelRegion(
            destination: destinationRect,
            clip: clipOverride ?? stream.clip,
            surface: surfaceDescriptor
        )
        if clippedRegion.isEmpty {
            guard var committed = streams[streamID],
                  committed.generation == stream.generation
            else {
                return nil
            }
            committed.lastPresentedSequence = frameSequence
            committed.lastMultimediaTime = multimediaTime
            streams[streamID] = committed
            return nil
        }
        let source = PixelRect(
            x: 0,
            y: stream.topDown ? 0 : frameHeight - sourceHeight,
            width: sourceWidth,
            height: sourceHeight
        )
        var usedNativeVideoPath = false
        var surfaceRevision: SurfaceRevision?
        let clipped = Array(clippedRegion)
        if (stream.codec != .mjpeg || decodedFrame is SpiceMJPEGFrame),
           !stream.metalCompositorDisabled
        {
            do {
                surfaceRevision = try await surfaces.drawNativeVideoFrame(
                    surfaceID: stream.surfaceID,
                    destination: destination,
                    frame: decodedFrame,
                    source: source,
                    topDown: stream.topDown,
                    clippedDestinations: clipped,
                    isAdvancedVideo: stream.codec == .h264 || stream.codec == .h265,
                    expectedMutationBarrier: expectedMutationBarrier,
                    videoSequence: videoSequence
                )
                usedNativeVideoPath = surfaceRevision != nil
            } catch {
                switch error {
                case .staleSurface:
                    return nil
                case let .render(renderError):
                    throw .protocolViolation(String(describing: renderError))
                case let .compositor(compositorError):
                    if error.disablesStreamGeneration,
                       var currentStream = streams[streamID],
                       currentStream.generation == stream.generation
                    {
                        currentStream.metalCompositorDisabled = true
                        streams[streamID] = currentStream
                        stream.metalCompositorDisabled = true
                        metalGenerationDisableCount &+= 1
                        if firstMetalGenerationDisableReason == nil {
                            firstMetalGenerationDisableReason = compositorError.description
                        }
                    }
                }
            }
        }
        if !usedNativeVideoPath {
            if stream.codec != .mjpeg {
                advancedCPUFallbackFrames &+= 1
            }
            let decoded: SpiceDecodedImage
            do {
                decoded = try decodedFrame.copyBGRA()
            } catch {
                throw .protocolViolation(
                    "video BGRA fallback failed: \(String(describing: error))"
                )
            }
            let bitmap = RawBitmap(
                format: .xRGB8888,
                width: decoded.width,
                height: decoded.height,
                stride: decoded.bytesPerRow,
                topDown: stream.topDown,
                pixels: decoded.pixelsBGRA
            )
            do {
                surfaceRevision = try await surfaces.drawScaledCopy(
                    surfaceID: stream.surfaceID,
                    destination: destination,
                    bitmap: bitmap,
                    source: source,
                    clippedDestinations: clipped,
                    expectedMutationBarrier: expectedMutationBarrier,
                    videoSequence: videoSequence
                )
            } catch {
                throw .protocolViolation(String(describing: error))
            }
        }

        guard var committed = streams[streamID], committed.generation == stream.generation else {
            return nil
        }
        committed.lastPresentedSequence = frameSequence
        committed.lastMultimediaTime = multimediaTime
        streams[streamID] = committed
        return surfaceRevision
    }

    private func retireAdvancedDecoder(
        _ decoder: (any SpiceAdvancedVideoDecoder)?
    ) async {
        guard let decoder else { return }
        retiredAdvancedVideoDiagnostics.accumulate(await decoder.diagnosticsSnapshot())
        await decoder.close()
    }

    private func retireMJPEGDecoder(_ decoder: SpiceMJPEGStreamDecoder?) async {
        guard let decoder else { return }
        retiredMJPEGDiagnostics.accumulate(await decoder.diagnosticsSnapshot())
        await decoder.close()
    }

    private nonisolated static func channelError(
        for error: SpiceCodecError
    ) -> ChannelError {
        switch error {
        case let .videoHardwareUnavailable(codec, status):
            .videoCodecFailure(
                codec: codec == .h264 ? .h264 : .h265,
                reason: .hardwareUnavailable(status: status)
            )
        case let .unsupportedVideoFormat(codec, status):
            .videoCodecFailure(
                codec: codec == .h264 ? .h264 : .h265,
                reason: .unsupportedFormat(status: status)
            )
        default:
            .protocolViolation("video decode failed: \(error.description)")
        }
    }

    private func retireFramePublisher(_ publisher: DisplayFramePublisher) async {
        await publisher.cancel()
        let metrics = await publisher.metrics()
        let identifier = ObjectIdentifier(publisher)
        guard framePublishers.removeValue(forKey: identifier) != nil else { return }
        completedPublisherMetrics.accumulate(metrics)
    }

    private func execute(
        _ command: SpiceDisplayDrawFill
    ) async throws(ChannelError) -> SurfaceRevision? {
        guard command.ropDescriptor == 0x08 else {
            throw .protocolViolation("unsupported DRAW_FILL ROP \(command.ropDescriptor)")
        }
        guard command.mask.bitmap == nil else {
            throw .protocolViolation("masked DRAW_FILL is not implemented")
        }
        guard case let .solid(color) = command.brush else {
            throw .protocolViolation("only solid DRAW_FILL brushes are implemented")
        }
        let region = try await pixelRegion(command.base)
        do {
            return try await surfaces.fill(
                surfaceID: command.base.surfaceID,
                region: region,
                colorARGB: color
            )
        } catch {
            throw .protocolViolation(String(describing: error))
        }
    }

    private func execute(
        _ command: SpiceDisplayCopyBits
    ) async throws(ChannelError) -> SurfaceRevision? {
        let base = try pixelRectAllowingEmpty(command.base.box)
        let region = try await pixelRegion(command.base)
        do {
            return try await surfaces.copyBits(
                surfaceID: command.base.surfaceID,
                region: region,
                destination: base,
                sourceX: Int(command.sourcePosition.x),
                sourceY: Int(command.sourcePosition.y)
            )
        } catch {
            throw .protocolViolation(String(describing: error))
        }
    }

    private func execute(
        _ command: SpiceDisplayDrawCopy
    ) async throws(ChannelError) -> SurfaceRevision? {
        guard command.ropDescriptor == 0x08 else {
            throw .protocolViolation("unsupported DRAW_COPY ROP \(command.ropDescriptor)")
        }
        guard command.mask.bitmap == nil else {
            throw .protocolViolation("masked DRAW_COPY is not implemented")
        }
        let base = try pixelRectAllowingEmpty(command.base.box)
        let sourceArea = try pixelRectAllowingEmpty(command.sourceArea)
        guard base.width == sourceArea.width, base.height == sourceArea.height else {
            throw .protocolViolation("scaled DRAW_COPY is not implemented")
        }

        if let mutationIntent = try cacheMutationIntent(image: command.sourceImage) {
            let mutation = try await imageCache.begin(
                id: mutationIntent.id,
                lossy: mutationIntent.lossy,
                mode: mutationIntent.mode,
                retainedByteCount: mutationIntent.retainedByteCount
            )
            return try await execute(
                command,
                base: base,
                sourceArea: sourceArea,
                mutation: consume mutation
            )
        }

        let region = try await pixelRegion(command.base)
        let (resolvedSource, paletteToCache) = try await resolveSource(command.sourceImage)
        try validateSourceArea(sourceArea, for: resolvedSource)
        let surfaceRevision = try await drawResolvedSource(
            resolvedSource,
            command: command,
            base: base,
            sourceArea: sourceArea,
            region: region
        )
        if let paletteToCache {
            palettes[paletteToCache.uniqueID] = paletteToCache
        }
        return surfaceRevision
    }

    private func execute(
        _ command: SpiceDisplayDrawCopy,
        base: PixelRect,
        sourceArea: PixelRect,
        mutation: consuming DisplayImageCacheMutation
    ) async throws(ChannelError) -> SurfaceRevision? {
        do {
            let region = try await pixelRegion(command.base)
            let (resolvedSource, paletteToCache) = try await resolveSource(command.sourceImage)
            try validateSourceArea(sourceArea, for: resolvedSource)
            guard case let .bitmap(bitmap) = resolvedSource else {
                throw ChannelError.protocolViolation(
                    "only decoded bitmaps can enter shared image cache"
                )
            }
            _ = try await imageCache.stage(mutation, bitmap: bitmap)
            let surfaceRevision = try await drawResolvedSource(
                resolvedSource,
                command: command,
                base: base,
                sourceArea: sourceArea,
                region: region
            )
            if let paletteToCache {
                palettes[paletteToCache.uniqueID] = paletteToCache
            }
            recordImageCacheCommit(
                await imageCache.commit(consume mutation)
            )
            return surfaceRevision
        } catch let error as ChannelError {
            await imageCache.abort(consume mutation)
            throw error
        } catch {
            await imageCache.abort(consume mutation)
            assertionFailure("unexpected DRAW_COPY cache mutation error: \(error)")
            throw .invalidState
        }
    }

    private func validateSourceArea(
        _ sourceArea: PixelRect,
        for resolvedSource: ResolvedSource
    ) throws(ChannelError) {
        guard case let .bitmap(bitmap) = resolvedSource else { return }
        let (right, rightOverflow) = sourceArea.x.addingReportingOverflow(sourceArea.width)
        let (bottom, bottomOverflow) = sourceArea.y.addingReportingOverflow(sourceArea.height)
        guard sourceArea.x >= 0, sourceArea.y >= 0,
              !rightOverflow, !bottomOverflow,
              right <= bitmap.width,
              bottom <= bitmap.height
        else {
            throw .protocolViolation("DRAW_COPY source area exceeds image")
        }
    }

    private func recordImageCacheCommit(_ outcome: DisplayImageCacheCommitOutcome) {
        switch outcome {
        case .committed:
            imageCacheCommittedMutations &+= 1
        case .invalidated:
            imageCacheInvalidatedMutations &+= 1
        case .discarded:
            imageCacheDiscardedMutations &+= 1
        }
    }

    private func drawResolvedSource(
        _ resolvedSource: ResolvedSource,
        command: SpiceDisplayDrawCopy,
        base: PixelRect,
        sourceArea: PixelRect,
        region: PixelRegion
    ) async throws(ChannelError) -> SurfaceRevision? {
        do {
            switch resolvedSource {
            case let .bitmap(bitmap):
                return try await surfaces.drawCopy(
                    surfaceID: command.base.surfaceID,
                    region: region,
                    destination: base,
                    bitmap: bitmap,
                    source: sourceArea
                )
            case let .surface(sourceSurfaceID):
                return try await surfaces.drawCopy(
                    surfaceID: command.base.surfaceID,
                    region: region,
                    destination: base,
                    sourceSurfaceID: sourceSurfaceID,
                    source: sourceArea
                )
            }
        } catch {
            throw .protocolViolation(String(describing: error))
        }
    }

    private func resolveSource(
        _ image: SpiceImage
    ) async throws(ChannelError) -> (ResolvedSource, SpiceLZPalette?) {
        switch image {
        case let .surface(descriptor, surfaceID):
            guard descriptor.flags & 0x05 == 0 else {
                throw .protocolViolation("surface image cannot mutate shared image cache")
            }
            return (.surface(surfaceID), nil)
        case let .cached(descriptor, requirement):
            guard descriptor.flags & 0x05 == 0 else {
                throw .protocolViolation("cache reference cannot mutate shared image cache")
            }
            let retainedByteCount: Int
            if let currentMessageRetainedByteCount {
                retainedByteCount = currentMessageRetainedByteCount
            } else {
                retainedByteCount = try imageRetainedByteCount(descriptor: descriptor)
            }
            let bitmap = try await imageCache.resolve(
                id: descriptor.id,
                requirement: requirement,
                retainedByteCount: retainedByteCount
            )
            guard bitmap.width == Int(descriptor.width),
                  bitmap.height == Int(descriptor.height)
            else {
                throw .protocolViolation("cached image dimensions do not match descriptor")
            }
            return (.bitmap(bitmap), nil)
        case let .bitmap(_, bitmap):
            guard let format = RawBitmapFormat(rawValue: bitmap.format),
                  let width = Int(exactly: bitmap.width),
                  let height = Int(exactly: bitmap.height),
                  let stride = Int(exactly: bitmap.stride)
            else {
                throw .protocolViolation("invalid raw bitmap")
            }
            return (.bitmap(RawBitmap(
                format: format,
                width: width,
                height: height,
                stride: stride,
                topDown: bitmap.flags & 0x04 != 0,
                pixels: bitmap.pixels
            )), nil)
        case let .quic(descriptor, data):
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: data.data,
                decoder: quicDecoder,
                name: "QUIC"
            )), nil)
        case let .jpeg(descriptor, data):
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: data.data,
                decoder: jpegDecoder,
                name: "JPEG"
            )), nil)
        case let .lzRGB(descriptor, data):
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: data.data,
                decoder: lzDecoder,
                name: "LZ"
            )), nil)
        case let .glzRGB(descriptor, data):
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: data.data,
                decoder: glzDecoder,
                name: "GLZ",
                usesCodecExecutor: false
            )), nil)
        case let .zlibGLZ(descriptor, data):
            guard let glzDataSize = Int(exactly: data.glzDataSize) else {
                throw .protocolViolation("invalid ZLIB GLZ output size")
            }
            let glzPayload: Data
            let inflator = zlibInflator
            do {
                glzPayload = try await executeCodecWork(retainedByteCount: data.data.count) {
                    () async throws(SpiceCodecError) -> Data in
                    try await inflator.inflate(
                        payload: data.data,
                        exactOutputByteCount: glzDataSize
                    )
                }
            } catch let error {
                throw .protocolViolation("ZLIB GLZ inflate failed: \(error.description)")
            }
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: glzPayload,
                decoder: glzDecoder,
                name: "ZLIB GLZ",
                usesCodecExecutor: false
            )), nil)
        case let .lzPalette(descriptor, data):
            guard let width = Int(exactly: descriptor.width),
                  let height = Int(exactly: descriptor.height)
            else {
                throw .protocolViolation("invalid LZ palette dimensions")
            }
            let paletteResolution = try resolvePalette(data)
            let decoded: SpiceDecodedImage
            let paletteDecoder = paletteLZDecoder
            do {
                decoded = try await executeCodecWork(retainedByteCount: data.data.count) {
                    () async throws(SpiceCodecError) -> SpiceDecodedImage in
                    try await paletteDecoder.decodePalette(
                        descriptor: SpiceCodecImageDescriptor(width: width, height: height),
                        payload: data.data,
                        palette: paletteResolution.palette
                    )
                }
            } catch let error {
                throw .protocolViolation("LZ palette decode failed: \(error.description)")
            }
            let pendingPalette = paletteResolution.cacheAfterDecode
                ? paletteResolution.palette
                : nil
            return (.bitmap(rawBitmap(decoded, forcedFormat: .xRGB8888)), pendingPalette)
        }
    }

    private func decode(
        descriptor: SpiceImageDescriptor,
        data: Data,
        decoder: any SpiceImageDecoder,
        name: String,
        usesCodecExecutor: Bool = true
    ) async throws(ChannelError) -> RawBitmap {
        guard let width = Int(exactly: descriptor.width),
              let height = Int(exactly: descriptor.height)
        else {
            throw .protocolViolation("invalid \(name) dimensions")
        }
        do {
            let descriptor = SpiceCodecImageDescriptor(width: width, height: height)
            let decoded: SpiceDecodedImage
            if usesCodecExecutor {
                decoded = try await executeCodecWork(retainedByteCount: data.count) {
                    () async throws(SpiceCodecError) -> SpiceDecodedImage in
                    try await decoder.decode(descriptor: descriptor, payload: data)
                }
            } else {
                decoded = try await decoder.decode(descriptor: descriptor, payload: data)
            }
            return rawBitmap(decoded)
        } catch let error {
            throw .protocolViolation("\(name) decode failed: \(error.description)")
        }
    }

    private func executeCodecWork<Success: Sendable>(
        retainedByteCount: Int,
        operation: @escaping @Sendable () async throws(SpiceCodecError) -> Success
    ) async throws(SpiceCodecError) -> Success {
        do {
            return try await codecTaskExecutor.executeThrowing(
                retainedByteCount: retainedByteCount,
                operation: operation
            )
        } catch let error {
            switch error {
            case let .operation(codecError):
                throw codecError
            case let .executor(executorError):
                if executorError == .cancelled || executorError == .closed {
                    throw .cancelled
                }
                throw .backendFailure("codec executor rejected work: \(executorError)")
            }
        }
    }

    private func rawBitmap(
        _ decoded: SpiceDecodedImage,
        forcedFormat: RawBitmapFormat? = nil
    ) -> RawBitmap {
        RawBitmap(
            format: forcedFormat ?? (decoded.alphaMode == .straight ? .argb8888 : .xRGB8888),
            width: decoded.width,
            height: decoded.height,
            stride: decoded.bytesPerRow,
            topDown: decoded.topDown,
            pixels: decoded.pixelsBGRA
        )
    }

    private func cacheMutationIntent(
        image: SpiceImage
    ) throws(ChannelError) -> ImageCacheMutationIntent? {
        let (descriptor, lossy): (SpiceImageDescriptor, Bool)
        switch image {
        case let .bitmap(value, _), let .quic(value, _), let .lzRGB(value, _),
             let .glzRGB(value, _),
             let .zlibGLZ(value, _),
             let .lzPalette(value, _):
            descriptor = value
            lossy = false
        case let .jpeg(value, _):
            descriptor = value
            lossy = true
        case .surface, .cached:
            return nil
        }
        let cacheMe = descriptor.flags & 0x01 != 0
        let replaceMe = descriptor.flags & 0x04 != 0
        guard !(cacheMe && replaceMe) else {
            throw .protocolViolation("CACHE_ME and CACHE_REPLACE_ME cannot both be set")
        }
        guard cacheMe || replaceMe else {
            return nil
        }
        let retainedByteCount: Int
        if let currentMessageRetainedByteCount {
            retainedByteCount = currentMessageRetainedByteCount
        } else {
            retainedByteCount = try imageRetainedByteCount(descriptor: descriptor)
        }
        guard !lossy else {
            guard cacheMe else {
                throw .protocolViolation("CACHE_REPLACE_ME source must be lossless")
            }
            return ImageCacheMutationIntent(
                id: descriptor.id,
                lossy: true,
                mode: .cache,
                retainedByteCount: retainedByteCount
            )
        }
        return ImageCacheMutationIntent(
            id: descriptor.id,
            lossy: false,
            mode: cacheMe ? .cache : .replace,
            retainedByteCount: retainedByteCount
        )
    }

    private func imageRetainedByteCount(
        descriptor: SpiceImageDescriptor
    ) throws(ChannelError) -> Int {
        guard let width = Int(exactly: descriptor.width),
              let height = Int(exactly: descriptor.height)
        else {
            throw .protocolViolation("invalid cached image dimensions")
        }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow else {
            throw .protocolViolation("cached image retained byte count overflow")
        }
        return bytes
    }

    private func resolvePalette(
        _ data: SpiceLZPaletteData
    ) throws(ChannelError) -> (palette: SpiceLZPalette, cacheAfterDecode: Bool) {
        switch data.palette {
        case let .cached(id):
            guard let palette = palettes[id] else {
                throw .protocolViolation("missing cached palette \(id)")
            }
            return (palette, false)
        case let .inline(wirePalette):
            let palette = SpiceLZPalette(
                uniqueID: wirePalette.uniqueID,
                entriesARGB: wirePalette.entriesARGB
            )
            let cacheAfterDecode = data.flags & 0x01 != 0
            if cacheAfterDecode,
               palettes[palette.uniqueID] == nil,
               palettes.count >= maximumCachedPalettes
            {
                throw .protocolViolation("palette cache limit exceeded")
            }
            return (palette, cacheAfterDecode)
        }
    }

    private func pixelRegion(_ base: SpiceDisplayBase) async throws(ChannelError) -> PixelRegion {
        let descriptor: SurfaceDescriptor
        do {
            descriptor = try await surfaces.descriptor(surfaceID: base.surfaceID)
        } catch {
            throw .protocolViolation(String(describing: error))
        }
        return try pixelRegion(
            destination: base.box,
            clip: base.clip,
            surface: descriptor
        )
    }

    private func pixelRegion(
        destination destinationRect: SpiceRect,
        clip: SpiceClip,
        surface: SurfaceDescriptor
    ) throws(ChannelError) -> PixelRegion {
        let destination = try pixelRectAllowingEmpty(destinationRect)
        let clips: [PixelRect]?
        switch clip {
        case .none:
            clips = nil
        case let .rectangles(rectangles):
            var converted: [PixelRect] = []
            converted.reserveCapacity(rectangles.count)
            for rectangle in rectangles {
                converted.append(try pixelRectAllowingEmpty(rectangle))
            }
            clips = converted
        }
        do {
            return try PixelRegion(
                destination: destination,
                surfaceBounds: PixelRect(
                    x: 0,
                    y: 0,
                    width: surface.width,
                    height: surface.height
                ),
                clips: clips
            )
        } catch let error {
            throw .protocolViolation(String(describing: error))
        }
    }

    private func validateStreamDestination(
        _ destination: PixelRect,
        in descriptor: SurfaceDescriptor
    ) throws(ChannelError) {
        let (right, rightOverflow) = destination.x.addingReportingOverflow(destination.width)
        let (bottom, bottomOverflow) = destination.y.addingReportingOverflow(destination.height)
        guard destination.x >= 0, destination.y >= 0,
              !rightOverflow, !bottomOverflow,
              right <= descriptor.width, bottom <= descriptor.height
        else {
            throw .protocolViolation("stream destination exceeds Surface")
        }
    }

    private func pixelRect(_ rectangle: SpiceRect) throws(ChannelError) -> PixelRect {
        let result = try pixelRectAllowingEmpty(rectangle)
        guard result.width > 0, result.height > 0 else {
            throw .protocolViolation("invalid Display rectangle")
        }
        return result
    }

    private func pixelRectAllowingEmpty(
        _ rectangle: SpiceRect
    ) throws(ChannelError) -> PixelRect {
        let left = Int(rectangle.left)
        let top = Int(rectangle.top)
        let width = Int64(rectangle.right) - Int64(rectangle.left)
        let height = Int64(rectangle.bottom) - Int64(rectangle.top)
        guard width >= 0, height >= 0,
              let width = Int(exactly: width), let height = Int(exactly: height)
        else {
            throw .protocolViolation("invalid Display rectangle")
        }
        return PixelRect(x: left, y: top, width: width, height: height)
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        try await connection.acknowledgeLastDelivered()
    }
}
