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
    package let connection: ChannelConnectionMetrics
    package let surfaces: SurfaceStoreMetrics
    package let publisher: DisplayFramePublisherMetrics
    /// Starts after `ChannelConnection.receive()` returns and covers decode,
    /// dispatch, validation, cache work, SurfaceStore calls, and acknowledgement.
    /// It excludes transport receive wait and contains the narrower timings.
    package let messageHandlingTiming: RenderPhaseMetrics
    package let messageDecodeTiming: RenderPhaseMetrics
    /// Time across the bitmap SurfaceStore actor call, including executor
    /// queueing and method execution. This is not a pure actor-wait metric.
    package let bitmapSurfaceStoreRoundTripTiming: RenderPhaseMetrics
    /// Time across DisplayFramePublisher submission, including executor queueing
    /// and submission execution.
    package let publisherSubmitRoundTripTiming: RenderPhaseMetrics
    package let advancedVideo: SpiceAdvancedVideoDecoderDiagnostics
    package let advancedCPUFallbackFrames: UInt64
    package let metalGenerationDisableCount: UInt64
    package let firstMetalGenerationDisableReason: String?
}

package actor DisplayChannel: SpiceManagedChannel {
    private static let pixmapCachePixels: UInt64 = 16 * 1_024 * 1_024
    private static let glzDictionaryWindowPixels: Int32 = 8 * 1_024 * 1_024

    private struct CachedImage: Sendable {
        let bitmap: RawBitmap
        let lossy: Bool
        let referenceCount: UInt32
    }

    private enum ResolvedSource: Sendable {
        case bitmap(RawBitmap)
        case surface(UInt32)
    }

    private enum PendingImageCacheMutation: Sendable {
        case insert(UInt64, CachedImage)
        case replace(UInt64, CachedImage)
    }

    private struct VideoStream: Sendable {
        let surfaceID: UInt32
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
        var clip: SpiceClip
        var nextFrameSequence: UInt64
        var lastPresentedSequence: UInt64
        var lastMultimediaTime: UInt32?
        var metalCompositorDisabled: Bool
    }

    private var connection: ChannelConnection
    private var completedConnectionMetrics = ChannelConnectionMetrics()
    /// Metrics already attributed to the currently active connection. This
    /// prevents migration rollback from adding the same connection history a
    /// second time without retaining retired connections or transports.
    private var activeConnectionMetricsBaseline = ChannelConnectionMetrics()
    private let surfaces: SurfaceStore
    private let jpegDecoder: any SpiceImageDecoder
    private let lzDecoder: any SpiceImageDecoder
    private let glzDecoder: SpiceGLZDecoder
    private let zlibInflator: SpiceZlibInflator
    private let paletteLZDecoder: any SpicePaletteImageDecoder
    private let quicDecoder: any SpiceImageDecoder
    private let advancedVideoDecoderFactory: any SpiceAdvancedVideoDecoderFactory
    private let multimediaClock: (any MultimediaClockScheduling)?
    private let maximumCachedPalettes: Int
    private let maximumCachedImages: Int
    private let maximumCachedImageBytes: Int
    private let maximumStreams: Int
    private let framePublicationInterval: Duration
    private let diagnosticsEnabled: Bool
    private let framePublisherDiagnosticsMode: RenderDiagnosticsMode
    private let diagnosticsClock: RenderPhaseRecorder.Clock
    private var palettes: [UInt64: SpiceLZPalette] = [:]
    private var images: [UInt64: CachedImage] = [:]
    private var cachedImageBytes = 0
    private var streams: [UInt32: VideoStream] = [:]
    private var nextStreamGeneration: UInt64 = 1
    private var ackController = AckController()
    private var framePublishers: [ObjectIdentifier: DisplayFramePublisher] = [:]
    private var completedPublisherMetrics = DisplayFramePublisherMetrics()
    private var retiredAdvancedVideoDiagnostics = SpiceAdvancedVideoDecoderDiagnostics()
    private var advancedCPUFallbackFrames: UInt64 = 0
    private var metalGenerationDisableCount: UInt64 = 0
    private var firstMetalGenerationDisableReason: String?
    private var messageHandlingTiming: RenderPhaseRecorder
    private var messageDecodeTiming: RenderPhaseRecorder
    private var bitmapSurfaceStoreRoundTripTiming: RenderPhaseRecorder
    private var publisherSubmitRoundTripTiming: RenderPhaseRecorder

    package init(
        connection: ChannelConnection,
        surfaces: SurfaceStore = SurfaceStore(),
        jpegDecoder: any SpiceImageDecoder = SpiceJPEGDecoder(),
        lzDecoder: any SpiceImageDecoder = SpiceLZDecoder(),
        glzDecoder: SpiceGLZDecoder = SpiceGLZDecoder(),
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
        diagnosticsMode: RenderDiagnosticsMode = .disabled,
        diagnosticsClock: @escaping RenderPhaseRecorder.Clock =
            RenderPhaseRecorder.systemClock
    ) {
        self.connection = connection
        self.surfaces = surfaces
        self.jpegDecoder = jpegDecoder
        self.lzDecoder = lzDecoder
        self.glzDecoder = glzDecoder
        self.zlibInflator = zlibInflator
        self.paletteLZDecoder = paletteLZDecoder
        self.quicDecoder = quicDecoder
        self.advancedVideoDecoderFactory = advancedVideoDecoderFactory
        self.multimediaClock = multimediaClock
        self.maximumCachedPalettes = max(1, maximumCachedPalettes)
        self.maximumCachedImages = max(1, maximumCachedImages)
        self.maximumCachedImageBytes = max(1, maximumCachedImageBytes)
        self.maximumStreams = min(64, max(1, maximumStreams))
        self.framePublicationInterval = framePublicationInterval
        diagnosticsEnabled = diagnosticsMode.normalizedCommandPeriod != nil
        framePublisherDiagnosticsMode = diagnosticsEnabled
            ? .sampled(commandPeriod: 1)
            : .disabled
        self.diagnosticsClock = diagnosticsClock
        messageHandlingTiming = RenderPhaseRecorder(
            mode: diagnosticsMode,
            clock: diagnosticsClock
        )
        messageDecodeTiming = RenderPhaseRecorder(
            mode: diagnosticsMode,
            clock: diagnosticsClock
        )
        bitmapSurfaceStoreRoundTripTiming = RenderPhaseRecorder(
            mode: diagnosticsMode,
            clock: diagnosticsClock
        )
        publisherSubmitRoundTripTiming = RenderPhaseRecorder(
            mode: diagnosticsMode,
            clock: diagnosticsClock
        )
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        try await connection.send(SpiceMsgcDisplayInit(
            pixmapCacheID: 1,
            pixmapCacheSize: Self.pixmapCachePixels,
            glzDictionaryID: 1,
            glzDictionaryWindowSize: Self.glzDictionaryWindowPixels
        ))
        let framePublisher = DisplayFramePublisher(
            interval: framePublicationInterval,
            diagnosticsMode: framePublisherDiagnosticsMode,
            diagnosticsClock: diagnosticsClock,
            snapshot: { [surfaces] surfaceRevision in
                await surfaces.snapshot(atLeast: surfaceRevision)
            },
            emit: { frame in
                await emit(.frame(frame))
            }
        )
        framePublishers[ObjectIdentifier(framePublisher)] = framePublisher
        do {
            while !Task.isCancelled {
                switch try await processNext() {
                case let .surfaceCreated(surfaceID):
                    await emit(.surfaceCreated(surfaceID))
                case let .surfaceDestroyed(surfaceID):
                    await framePublisher.remove(surfaceID: surfaceID)
                    await emit(.surfaceDestroyed(surfaceID))
                case let .frameChanged(surfaceRevision):
                    if diagnosticsEnabled {
                        var submitSample = publisherSubmitRoundTripTiming.beginCommand()
                        await framePublisher.submit(surfaceRevision)
                        publisherSubmitRoundTripTiming.finishCommand(&submitSample)
                    } else {
                        await framePublisher.submit(surfaceRevision)
                    }
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
        await retireFramePublisher(framePublisher)
    }

    package func processNext() async throws(ChannelError) -> DisplayEvent {
        let framed = try await connection.receive()
        var handlingSample: RenderPhaseSample?
        if diagnosticsEnabled {
            handlingSample = messageHandlingTiming.beginCommand()
        }
        defer {
            if diagnosticsEnabled {
                messageHandlingTiming.finishCommand(&handlingSample)
            }
        }
        let message = try decode(framed)

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
            do {
                try await surfaces.destroy(id: destroy.surfaceID)
            } catch {
                throw .protocolViolation(String(describing: error))
            }
            let removedStreams = streams.values.filter { $0.surfaceID == destroy.surfaceID }
            streams = streams.filter { $0.value.surfaceID != destroy.surfaceID }
            for stream in removedStreams {
                await retireAdvancedDecoder(stream.advancedDecoder)
            }
            try await acknowledgeIfNeeded()
            return .surfaceDestroyed(destroy.surfaceID)
        case .displayReset:
            palettes.removeAll(keepingCapacity: true)
            let removedStreams = Array(streams.values)
            streams.removeAll(keepingCapacity: true)
            for stream in removedStreams {
                await retireAdvancedDecoder(stream.advancedDecoder)
            }
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayInvalidateImages(imageIDs):
            for imageID in imageIDs {
                removeCachedImage(id: imageID)
            }
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayInvalidateAllImages(waits):
            try await connection.waitUntilReceived(waits.map {
                ChannelSerialBarrier.Requirement(
                    key: ChannelKey(type: $0.channelType, id: $0.channelID),
                    serial: $0.messageSerial
                )
            })
            images.removeAll(keepingCapacity: true)
            cachedImageBytes = 0
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
            let surfaceRevision = try await renderStreamFrame(
                streamID: data.streamID,
                multimediaTime: data.multimediaTime,
                sizing: nil,
                data: data.data
            )
            try await acknowledgeIfNeeded()
            return surfaceRevision.map(DisplayEvent.frameChanged) ?? .ignored(framed.type)
        case let .displayStreamDataSized(data):
            let surfaceRevision = try await renderStreamFrame(
                streamID: data.streamID,
                multimediaTime: data.multimediaTime,
                sizing: (data.width, data.height, data.destination),
                data: data.data
            )
            try await acknowledgeIfNeeded()
            return surfaceRevision.map(DisplayEvent.frameChanged) ?? .ignored(framed.type)
        case let .displayStreamClip(clip):
            try updateStreamClip(clip)
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case let .displayStreamDestroy(streamID):
            guard let removed = streams.removeValue(forKey: streamID) else {
                throw .protocolViolation("destroy of unknown stream \(streamID)")
            }
            await retireAdvancedDecoder(removed.advancedDecoder)
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case .displayStreamDestroyAll:
            let removedStreams = Array(streams.values)
            streams.removeAll(keepingCapacity: true)
            for stream in removedStreams {
                await retireAdvancedDecoder(stream.advancedDecoder)
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
            try await acknowledgeIfNeeded()
            return surfaceRevision.map(DisplayEvent.frameChanged) ?? .ignored(framed.type)
        case let .displayDrawFill(command):
            let surfaceRevision = try await execute(command)
            try await acknowledgeIfNeeded()
            return surfaceRevision.map(DisplayEvent.frameChanged) ?? .ignored(framed.type)
        case let .displayDrawCopy(command):
            let surfaceRevision = try await execute(command)
            try await acknowledgeIfNeeded()
            return surfaceRevision.map(DisplayEvent.frameChanged) ?? .ignored(framed.type)
        case let .setAck(setAck):
            ackController.configure(generation: setAck.generation, window: setAck.window)
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
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

    /// Flushes publishers known to be quiescent for deterministic tests.
    ///
    /// This is not a general completion barrier: a publisher that is already
    /// flushing may return before its in-flight emission completes.
    package func flushPendingFramesForTesting() async {
        let publishers = framePublishers.keys.sorted().compactMap {
            framePublishers[$0]
        }
        for publisher in publishers {
            await publisher.flushNow()
        }
    }

    package func close() async {
        await connection.close()
        let publishers = Array(framePublishers.values)
        for publisher in publishers {
            await retireFramePublisher(publisher)
        }
        let removedStreams = Array(streams.values)
        streams.removeAll(keepingCapacity: false)
        for stream in removedStreams {
            await retireAdvancedDecoder(stream.advancedDecoder)
        }
        await surfaces.close()
    }

    package func diagnosticsSnapshot() async -> DisplayChannelDiagnostics {
        let activeConnection = connection
        let activeBaseline = activeConnectionMetricsBaseline
        var connectionMetrics = completedConnectionMetrics
        connectionMetrics.accumulate(
            await activeConnection.metrics().subtracting(activeBaseline)
        )
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
        return DisplayChannelDiagnostics(
            connection: connectionMetrics,
            surfaces: await surfaces.metrics(),
            publisher: publisherMetrics,
            messageHandlingTiming: messageHandlingTiming.metrics,
            messageDecodeTiming: messageDecodeTiming.metrics,
            bitmapSurfaceStoreRoundTripTiming:
                bitmapSurfaceStoreRoundTripTiming.metrics,
            publisherSubmitRoundTripTiming: publisherSubmitRoundTripTiming.metrics,
            advancedVideo: advancedVideo,
            advancedCPUFallbackFrames: advancedCPUFallbackFrames,
            metalGenerationDisableCount: metalGenerationDisableCount,
            firstMetalGenerationDisableReason: firstMetalGenerationDisableReason
        )
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) async throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Display Channel")
        }
        let previous = connection
        if diagnosticsEnabled {
            // Read both actors before mutating DisplayChannel state so any
            // reentrant diagnostics snapshot observes one coherent owner.
            let replacementBaseline = await replacement.metrics()
            let previousMetrics = await previous.metrics()
            completedConnectionMetrics.accumulate(
                previousMetrics.subtracting(activeConnectionMetricsBaseline)
            )
            activeConnectionMetricsBaseline = replacementBaseline
        }
        connection = replacement
        return previous
    }

    private func decode(_ framed: FramedMessage) throws(ChannelError) -> SpiceServerMessage {
        do {
            if diagnosticsEnabled {
                var decodeSample = messageDecodeTiming.beginCommand()
                defer { messageDecodeTiming.finishCommand(&decodeSample) }
                return try SpiceServerMessageDecoder.decode(
                    id: framed.type,
                    body: framed.body,
                    channel: .display
                )
            }
            return try SpiceServerMessageDecoder.decode(
                id: framed.type,
                body: framed.body,
                channel: .display
            )
        } catch let error {
            throw .wire(error)
        }
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
        _ = try clippedRectangles(destination: create.destination, clip: create.clip)

        let advancedDecoder: (any SpiceAdvancedVideoDecoder)?
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
            default:
                advancedDecoder = nil
            }
        } catch let error {
            throw .protocolViolation("advanced video decoder creation failed: \(error.description)")
        }

        let generation = nextStreamGeneration
        let (followingGeneration, overflow) = generation.addingReportingOverflow(1)
        guard !overflow else {
            throw .protocolViolation("stream generation overflow")
        }
        nextStreamGeneration = followingGeneration
        streams[create.streamID] = VideoStream(
            surfaceID: create.surfaceID,
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
            clip: create.clip,
            nextFrameSequence: 0,
            lastPresentedSequence: 0,
            lastMultimediaTime: nil,
            metalCompositorDisabled: false
        )
    }

    private func updateStreamClip(_ update: SpiceDisplayStreamClip) throws(ChannelError) {
        guard var stream = streams[update.streamID] else {
            throw .protocolViolation("clip for unknown stream \(update.streamID)")
        }
        _ = try clippedRectangles(destination: stream.destination, clip: update.clip)
        stream.clip = update.clip
        streams[update.streamID] = stream
    }

    private func renderStreamFrame(
        streamID: UInt32,
        multimediaTime: UInt32,
        sizing: (width: UInt32, height: UInt32, destination: SpiceRect)?,
        data: Data
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
                decodedFrame = try await jpegDecoder.decode(
                    descriptor: SpiceCodecImageDescriptor(width: frameWidth, height: frameHeight),
                    payload: data
                )
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
        let clipped = try clippedRectangles(destination: destinationRect, clip: stream.clip)
        if clipped.isEmpty {
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
        if stream.codec != .mjpeg, !stream.metalCompositorDisabled {
            do {
                surfaceRevision = try await surfaces.drawNativeVideoFrame(
                    surfaceID: stream.surfaceID,
                    destination: destination,
                    frame: decodedFrame,
                    source: source,
                    topDown: stream.topDown,
                    clippedDestinations: clipped
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
                    clippedDestinations: clipped
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
        var surfaceRevision: SurfaceRevision?
        for rectangle in try clippedRectangles(command.base) {
            do {
                surfaceRevision = try await surfaces.fill(
                    surfaceID: command.base.surfaceID,
                    rectangle: rectangle,
                    colorARGB: color
                )
            } catch {
                throw .protocolViolation(String(describing: error))
            }
        }
        return surfaceRevision
    }

    private func execute(
        _ command: SpiceDisplayCopyBits
    ) async throws(ChannelError) -> SurfaceRevision? {
        let base = try pixelRect(command.base.box)
        var surfaceRevision: SurfaceRevision?
        for destination in try clippedRectangles(command.base) {
            let sourceX = Int(command.sourcePosition.x) + destination.x - base.x
            let sourceY = Int(command.sourcePosition.y) + destination.y - base.y
            do {
                surfaceRevision = try await surfaces.copyBits(
                    surfaceID: command.base.surfaceID,
                    destination: destination,
                    sourceX: sourceX,
                    sourceY: sourceY
                )
            } catch {
                throw .protocolViolation(String(describing: error))
            }
        }
        return surfaceRevision
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
        let base = try pixelRect(command.base.box)
        let sourceArea = try pixelRect(command.sourceArea)
        guard base.width == sourceArea.width, base.height == sourceArea.height else {
            throw .protocolViolation("scaled DRAW_COPY is not implemented")
        }

        let (resolvedSource, paletteToCache) = try await resolveSource(command.sourceImage)
        let cacheMutation = try preflightCacheMutation(
            image: command.sourceImage,
            resolvedSource: resolvedSource
        )

        if case let .bitmap(bitmap) = resolvedSource {
            guard sourceArea.x >= 0, sourceArea.y >= 0,
                  sourceArea.x + sourceArea.width <= bitmap.width,
                  sourceArea.y + sourceArea.height <= bitmap.height
            else {
                throw .protocolViolation("DRAW_COPY source area exceeds image")
            }
        }

        var surfaceRevision: SurfaceRevision?
        for destination in try clippedRectangles(command.base) {
            let source = PixelRect(
                x: sourceArea.x + destination.x - base.x,
                y: sourceArea.y + destination.y - base.y,
                width: destination.width,
                height: destination.height
            )
            do {
                switch resolvedSource {
                case let .bitmap(bitmap):
                    if diagnosticsEnabled {
                        var roundTripSample =
                            bitmapSurfaceStoreRoundTripTiming.beginCommand()
                        defer {
                            bitmapSurfaceStoreRoundTripTiming.finishCommand(
                                &roundTripSample
                            )
                        }
                        surfaceRevision = try await surfaces.drawCopy(
                            surfaceID: command.base.surfaceID,
                            destination: destination,
                            bitmap: bitmap,
                            source: source
                        )
                    } else {
                        surfaceRevision = try await surfaces.drawCopy(
                            surfaceID: command.base.surfaceID,
                            destination: destination,
                            bitmap: bitmap,
                            source: source
                        )
                    }
                case let .surface(sourceSurfaceID):
                    surfaceRevision = try await surfaces.drawCopy(
                        surfaceID: command.base.surfaceID,
                        destination: destination,
                        sourceSurfaceID: sourceSurfaceID,
                        source: source
                    )
                }
            } catch {
                throw .protocolViolation(String(describing: error))
            }
        }
        if let paletteToCache {
            palettes[paletteToCache.uniqueID] = paletteToCache
        }
        commit(cacheMutation)
        return surfaceRevision
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
            guard let cached = images[descriptor.id] else {
                throw .protocolViolation("missing cached image \(descriptor.id)")
            }
            guard cached.bitmap.width == Int(descriptor.width),
                  cached.bitmap.height == Int(descriptor.height)
            else {
                throw .protocolViolation("cached image dimensions do not match descriptor")
            }
            if requirement == .lossless, cached.lossy {
                throw .protocolViolation("cached image \(descriptor.id) is lossy")
            }
            return (.bitmap(cached.bitmap), nil)
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
                data: data,
                decoder: quicDecoder,
                name: "QUIC"
            )), nil)
        case let .jpeg(descriptor, data):
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: data,
                decoder: jpegDecoder,
                name: "JPEG"
            )), nil)
        case let .lzRGB(descriptor, data):
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: data,
                decoder: lzDecoder,
                name: "LZ"
            )), nil)
        case let .glzRGB(descriptor, data):
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: data,
                decoder: glzDecoder,
                name: "GLZ"
            )), nil)
        case let .zlibGLZ(descriptor, data):
            guard let glzDataSize = Int(exactly: data.glzDataSize) else {
                throw .protocolViolation("invalid ZLIB GLZ output size")
            }
            let glzPayload: Data
            do {
                glzPayload = try await zlibInflator.inflate(
                    payload: data.data,
                    exactOutputByteCount: glzDataSize
                )
            } catch let error {
                throw .protocolViolation("ZLIB GLZ inflate failed: \(error.description)")
            }
            return (.bitmap(try await decode(
                descriptor: descriptor,
                data: glzPayload,
                decoder: glzDecoder,
                name: "ZLIB GLZ"
            )), nil)
        case let .lzPalette(descriptor, data):
            guard let width = Int(exactly: descriptor.width),
                  let height = Int(exactly: descriptor.height)
            else {
                throw .protocolViolation("invalid LZ palette dimensions")
            }
            let paletteResolution = try resolvePalette(data)
            let decoded: SpiceDecodedImage
            do {
                decoded = try await paletteLZDecoder.decodePalette(
                    descriptor: SpiceCodecImageDescriptor(width: width, height: height),
                    payload: data.data,
                    palette: paletteResolution.palette
                )
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
        name: String
    ) async throws(ChannelError) -> RawBitmap {
        guard let width = Int(exactly: descriptor.width),
              let height = Int(exactly: descriptor.height)
        else {
            throw .protocolViolation("invalid \(name) dimensions")
        }
        do {
            let decoded = try await decoder.decode(
                descriptor: SpiceCodecImageDescriptor(width: width, height: height),
                payload: data
            )
            return rawBitmap(decoded)
        } catch let error {
            throw .protocolViolation("\(name) decode failed: \(error.description)")
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

    private func preflightCacheMutation(
        image: SpiceImage,
        resolvedSource: ResolvedSource
    ) throws(ChannelError) -> PendingImageCacheMutation? {
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
        guard case let .bitmap(bitmap) = resolvedSource else {
            throw .protocolViolation("only decoded bitmaps can enter shared image cache")
        }
        let existing = images[descriptor.id]
        if cacheMe {
            guard existing != nil || images.count < maximumCachedImages else {
                throw .protocolViolation("image cache entry limit exceeded")
            }
            let referenceCount: UInt32
            if let existing {
                let (incremented, overflow) = existing.referenceCount.addingReportingOverflow(1)
                guard !overflow else {
                    throw .protocolViolation("image cache reference count overflow")
                }
                referenceCount = incremented
            } else {
                referenceCount = 1
            }
            let remainingBytes = cachedImageBytes - (existing?.bitmap.pixels.count ?? 0)
            guard bitmap.pixels.count <= maximumCachedImageBytes - remainingBytes else {
                throw .protocolViolation("image cache byte limit exceeded")
            }
            let cached = CachedImage(
                bitmap: bitmap,
                lossy: lossy,
                referenceCount: referenceCount
            )
            return .insert(descriptor.id, cached)
        }
        guard !lossy else {
            throw .protocolViolation("CACHE_REPLACE_ME source must be lossless")
        }
        let remainingBytes = cachedImageBytes - (existing?.bitmap.pixels.count ?? 0)
        guard bitmap.pixels.count <= maximumCachedImageBytes - remainingBytes else {
            throw .protocolViolation("image cache byte limit exceeded")
        }
        guard existing != nil || images.count < maximumCachedImages else {
            throw .protocolViolation("image cache entry limit exceeded")
        }
        let cached = CachedImage(
            bitmap: bitmap,
            lossy: false,
            referenceCount: existing?.referenceCount ?? 1
        )
        return .replace(descriptor.id, cached)
    }

    private func commit(_ mutation: PendingImageCacheMutation?) {
        guard let mutation else { return }
        switch mutation {
        case let .insert(id, cached):
            if let previous = images.updateValue(cached, forKey: id) {
                cachedImageBytes -= previous.bitmap.pixels.count
            }
            cachedImageBytes += cached.bitmap.pixels.count
        case let .replace(id, cached):
            if let previous = images.updateValue(cached, forKey: id) {
                cachedImageBytes -= previous.bitmap.pixels.count
            }
            cachedImageBytes += cached.bitmap.pixels.count
        }
    }

    private func removeCachedImage(id: UInt64) {
        guard let cached = images[id] else { return }
        if cached.referenceCount > 1 {
            images[id] = CachedImage(
                bitmap: cached.bitmap,
                lossy: cached.lossy,
                referenceCount: cached.referenceCount - 1
            )
        } else {
            images.removeValue(forKey: id)
            cachedImageBytes -= cached.bitmap.pixels.count
        }
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

    private func clippedRectangles(_ base: SpiceDisplayBase) throws(ChannelError) -> [PixelRect] {
        try clippedRectangles(destination: base.box, clip: base.clip)
    }

    private func clippedRectangles(
        destination destinationRect: SpiceRect,
        clip: SpiceClip
    ) throws(ChannelError) -> [PixelRect] {
        let destination = try pixelRect(destinationRect)
        switch clip {
        case .none:
            return [destination]
        case let .rectangles(rectangles):
            var clipped: [PixelRect] = []
            clipped.reserveCapacity(rectangles.count)
            for rectangle in rectangles {
                if let intersection = intersection(destination, try pixelRect(rectangle)) {
                    clipped.append(intersection)
                }
            }
            return clipped
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
        let left = Int(rectangle.left)
        let top = Int(rectangle.top)
        let width = Int64(rectangle.right) - Int64(rectangle.left)
        let height = Int64(rectangle.bottom) - Int64(rectangle.top)
        guard width > 0, height > 0,
              let width = Int(exactly: width), let height = Int(exactly: height)
        else {
            throw .protocolViolation("invalid Display rectangle")
        }
        return PixelRect(x: left, y: top, width: width, height: height)
    }

    private func intersection(_ lhs: PixelRect, _ rhs: PixelRect) -> PixelRect? {
        let left = max(lhs.x, rhs.x)
        let top = max(lhs.y, rhs.y)
        let right = min(lhs.x + lhs.width, rhs.x + rhs.width)
        let bottom = min(lhs.y + lhs.height, rhs.y + rhs.height)
        guard right > left, bottom > top else {
            return nil
        }
        return PixelRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        if ackController.didProcessMessage() {
            try await connection.send(SpiceMsgcAck())
        }
    }
}
