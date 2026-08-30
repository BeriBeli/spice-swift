import CoreVideo
import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import OSLog
import QuartzCore
import SpiceIOSurface
import SpiceMetalCompositor
import Synchronization

private let spiceRenderingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "org.swiftspice.SwiftSpice",
    category: "Rendering"
)

package struct SpiceMetalPresenterMetrics: Sendable, Equatable {
    package let commandErrors: UInt64
    package let textureCacheHits: UInt64
    package let textureCacheMisses: UInt64
    package let textureCacheEvictions: UInt64
    package let textureCacheEntries: Int
    package let gpuBusySkips: UInt64
    package let inFlightCommands: Int
    package let maximumInFlightCommands: Int
    package let drawablePresentedFrames: UInt64
    package let lastRequestToPresented: Duration?
}

package enum SpiceMetalTextureResult {
    case texture(any MTLTexture)
    case cpuFallback(SpiceCPUPresentationFallbackReason)
}

package enum SpiceMetalSamplingFilter: Sendable, Equatable {
    case nearest
    case lanczos
}

fileprivate final class SpiceMetalPresenterCompletionMetrics: Sendable {
    private struct State: Sendable {
        var commandErrors: UInt64 = 0
        var loggedFirstCommandError = false
        var textureCacheHits: UInt64 = 0
        var textureCacheMisses: UInt64 = 0
        var textureCacheEvictions: UInt64 = 0
        var textureCacheEntries = 0
        var gpuBusySkips: UInt64 = 0
        var inFlightCommands = 0
        var maximumInFlightCommands = 0
        var drawablePresentedFrames: UInt64 = 0
        var lastRequestToPresented: Duration?
    }

    private let state = Mutex(State())

    func reserveCommandSlot(limit: Int) -> Bool {
        state.withLock { state in
            guard state.inFlightCommands < limit else {
                state.gpuBusySkips &+= 1
                return false
            }
            state.inFlightCommands += 1
            state.maximumInFlightCommands = max(
                state.maximumInFlightCommands,
                state.inFlightCommands
            )
            return true
        }
    }

    func releaseCommandSlot() {
        state.withLock { state in
            state.inFlightCommands = max(0, state.inFlightCommands - 1)
        }
    }

    func hasAvailableCommandSlot(limit: Int) -> Bool {
        state.withLock { $0.inFlightCommands < limit }
    }

    func recordCommandError() -> Bool {
        state.withLock { state in
            state.commandErrors &+= 1
            guard !state.loggedFirstCommandError else { return false }
            state.loggedFirstCommandError = true
            return true
        }
    }

    func recordTextureCacheHit() {
        state.withLock { $0.textureCacheHits &+= 1 }
    }

    func recordTextureCacheMiss() {
        state.withLock { $0.textureCacheMisses &+= 1 }
    }

    func recordGPUBusySkip() {
        state.withLock { $0.gpuBusySkips &+= 1 }
    }

    func recordTextureCacheInsertion(entryCount: Int, evicted: Bool) {
        state.withLock { state in
            state.textureCacheEntries = entryCount
            if evicted {
                state.textureCacheEvictions &+= 1
            }
        }
    }

    func recordDrawablePresented(_ duration: Duration) {
        state.withLock { state in
            state.drawablePresentedFrames &+= 1
            state.lastRequestToPresented = duration
        }
    }

    func snapshot() -> SpiceMetalPresenterMetrics {
        state.withLock { state in
            SpiceMetalPresenterMetrics(
                commandErrors: state.commandErrors,
                textureCacheHits: state.textureCacheHits,
                textureCacheMisses: state.textureCacheMisses,
                textureCacheEvictions: state.textureCacheEvictions,
                textureCacheEntries: state.textureCacheEntries,
                gpuBusySkips: state.gpuBusySkips,
                inFlightCommands: state.inFlightCommands,
                maximumInFlightCommands: state.maximumInFlightCommands,
                drawablePresentedFrames: state.drawablePresentedFrames,
                lastRequestToPresented: state.lastRequestToPresented
            )
        }
    }
}

@MainActor
package final class SpiceMetalPresenter {
    private struct TextureCacheKey: Hashable {
        let id: UInt32
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let pixelFormat: UInt32
    }

    private struct TextureCacheEntry {
        let texture: any MTLTexture
        var lastUse: UInt64
    }

    package nonisolated static let maximumTextureCacheEntries = 3
    package nonisolated static let maximumInFlightCommands = 2

    package let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState
    private let nearestSampler: any MTLSamplerState
    private let lanczosScaler: MPSImageLanczosScale
    fileprivate let completionMetrics = SpiceMetalPresenterCompletionMetrics()
    private var presentationDiagnostics: SpicePresentationDiagnostics?
    private var textureCache: [TextureCacheKey: TextureCacheEntry] = [:]
    private var textureUseCounter: UInt64 = 0

    package init?(
        device: (any MTLDevice)? = SpiceMetalSystemDevice.shared.device,
        presentationDiagnostics: SpicePresentationDiagnostics? = nil,
        libraryURL: URL? = nil
    ) {
        guard let device,
              let commandQueue = device.makeCommandQueue(),
              let libraryURL = libraryURL ?? Self.bundledShaderLibraryURL(),
              let library = try? device.makeLibrary(URL: libraryURL),
              let vertexFunction = library.makeFunction(name: "spice_present_vertex"),
              let fragmentFunction = library.makeFunction(name: "spice_present_fragment")
        else {
            return nil
        }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "SwiftSpice IOSurface presentation"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(
            descriptor: pipelineDescriptor
        ) else {
            return nil
        }

        let nearestDescriptor = MTLSamplerDescriptor()
        nearestDescriptor.minFilter = .nearest
        nearestDescriptor.magFilter = .nearest
        nearestDescriptor.mipFilter = .notMipmapped
        nearestDescriptor.sAddressMode = .clampToEdge
        nearestDescriptor.tAddressMode = .clampToEdge

        guard let nearestSampler = device.makeSamplerState(descriptor: nearestDescriptor) else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.nearestSampler = nearestSampler
        let lanczosScaler = MPSImageLanczosScale(device: device)
        lanczosScaler.edgeMode = .clamp
        self.lanczosScaler = lanczosScaler
        self.presentationDiagnostics = presentationDiagnostics
    }

    package static func samplingFilter(
        sourceWidth: Int,
        sourceHeight: Int,
        destinationWidth: Int,
        destinationHeight: Int
    ) -> SpiceMetalSamplingFilter {
        guard sourceWidth > 0,
              sourceHeight > 0,
              destinationWidth > 0,
              destinationHeight > 0
        else {
            return .lanczos
        }
        if sourceWidth == destinationWidth, sourceHeight == destinationHeight {
            return .nearest
        }
        let isIntegerMagnification = destinationWidth >= sourceWidth
            && destinationHeight >= sourceHeight
            && destinationWidth.isMultiple(of: sourceWidth)
            && destinationHeight.isMultiple(of: sourceHeight)
        return isIntegerMagnification ? .nearest : .lanczos
    }

    package func makeTexture(for frame: SpiceFrame) -> (any MTLTexture)? {
        guard case let .texture(texture) = makeTextureResult(for: frame) else {
            return nil
        }
        return texture
    }

    package func makeTextureResult(for frame: SpiceFrame) -> SpiceMetalTextureResult {
        guard let ioSurface = frame.ioSurface else {
            return .cpuFallback(.missingIOSurface)
        }
        guard ioSurface.width == frame.width, ioSurface.height == frame.height else {
            return .cpuFallback(.ioSurfaceDimensionMismatch)
        }
        guard ioSurface.pixelFormat == kCVPixelFormatType_32BGRA else {
            return .cpuFallback(.pixelFormatMismatch)
        }

        let key = TextureCacheKey(
            id: ioSurface.id,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            pixelFormat: ioSurface.pixelFormat
        )
        textureUseCounter &+= 1
        if var cached = textureCache[key] {
            cached.lastUse = textureUseCounter
            textureCache[key] = cached
            completionMetrics.recordTextureCacheHit()
            presentationDiagnostics?.recordMetalTextureCacheHit()
            return .texture(cached.texture)
        }

        completionMetrics.recordTextureCacheMiss()
        presentationDiagnostics?.recordMetalTextureCacheMiss()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        let texture = ioSurface.backing.withIOSurface { surface in
            device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        }
        guard let texture else {
            return .cpuFallback(.textureCreationFailed)
        }

        textureCache[key] = TextureCacheEntry(
            texture: texture,
            lastUse: textureUseCounter
        )
        var evicted = false
        if textureCache.count > Self.maximumTextureCacheEntries,
           let leastRecentlyUsed = textureCache.min(by: {
               $0.value.lastUse < $1.value.lastUse
           })?.key {
            textureCache.removeValue(forKey: leastRecentlyUsed)
            evicted = true
        }
        completionMetrics.recordTextureCacheInsertion(
            entryCount: textureCache.count,
            evicted: evicted
        )
        if evicted {
            presentationDiagnostics?.recordMetalTextureCacheEviction()
        }
        return .texture(texture)
    }

    package nonisolated func metrics() -> SpiceMetalPresenterMetrics {
        completionMetrics.snapshot()
    }

    package func setPresentationDiagnostics(_ diagnostics: SpicePresentationDiagnostics?) {
        presentationDiagnostics = diagnostics
    }

    package nonisolated func hasAvailableCommandSlot() -> Bool {
        completionMetrics.hasAvailableCommandSlot(
            limit: Self.maximumInFlightCommands
        )
    }

    package func recordGPUBusySkip() {
        completionMetrics.recordGPUBusySkip()
        presentationDiagnostics?.recordMetalGPUBusySkip()
    }

    /// Encodes one complete drawable overwrite. The completion handler owns the
    /// frame lease until the GPU is finished with its IOSurface texture.
    package func makePresentationCommand(
        source: any MTLTexture,
        destination: any MTLTexture,
        retaining frame: SpiceFrame,
        presentationEpoch: UInt64? = nil
    ) -> (any MTLCommandBuffer)? {
        guard source.pixelFormat == .bgra8Unorm,
              destination.pixelFormat == .bgra8Unorm,
              source.width > 0,
              source.height > 0,
              destination.width > 0,
              destination.height > 0
        else {
            return nil
        }
        guard completionMetrics.reserveCommandSlot(
            limit: Self.maximumInFlightCommands
        ) else {
            presentationDiagnostics?.recordMetalGPUBusySkip()
            return nil
        }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completionMetrics.releaseCommandSlot()
            return nil
        }

        let filter = Self.samplingFilter(
            sourceWidth: source.width,
            sourceHeight: source.height,
            destinationWidth: destination.width,
            destinationHeight: destination.height
        )
        if filter == .lanczos {
            // MPS writes its high-quality scale directly into the drawable. This
            // restores v0.1.x text clarity without an intermediate texture or blit.
            lanczosScaler.encode(
                commandBuffer: commandBuffer,
                sourceTexture: source,
                destinationTexture: destination
            )
        } else {
            let renderPass = MTLRenderPassDescriptor()
            renderPass.colorAttachments[0].texture = destination
            renderPass.colorAttachments[0].loadAction = .clear
            renderPass.colorAttachments[0].storeAction = .store
            renderPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
            guard let encoder = commandBuffer.makeRenderCommandEncoder(
                descriptor: renderPass
            ) else {
                completionMetrics.releaseCommandSlot()
                return nil
            }
            encoder.label = "SwiftSpice fullscreen IOSurface presentation"
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(source, index: 0)
            encoder.setFragmentSamplerState(nearestSampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }

        let commandEpoch = presentationEpoch ?? presentationDiagnostics?.currentEpoch()
        commandBuffer.addCompletedHandler {
            [completionMetrics, presentationDiagnostics] commandBuffer in
            defer {
                completionMetrics.releaseCommandSlot()
                withExtendedLifetime(frame) {}
            }
            if commandBuffer.status == .error, completionMetrics.recordCommandError() {
                spiceRenderingLogger.error(
                    "Metal frame presentation failed: \(commandBuffer.error?.localizedDescription ?? "unknown", privacy: .public)"
                )
            }
            if commandBuffer.status == .error {
                presentationDiagnostics?.recordMetalPresentationError(epoch: commandEpoch)
            }
        }
        return commandBuffer
    }

    package static func bundledShaderLibraryURL(searchRoots: [URL]? = nil) -> URL? {
        return SpiceMetalShaderLibraryLocator.libraryURL(
            resourceBundleName: "SwiftSpice_SwiftSpice.bundle",
            searchRoots: searchRoots
                ?? SpiceMetalShaderLibraryLocator.mainBundleSearchRoots()
        )
    }
}

package enum SpiceMetalFramePresentationResult: Sendable, Equatable {
    case committed
    case gpuBusy
    case drawableUnavailable
    case cpuFallback(SpiceCPUPresentationFallbackReason)
}

package enum SpiceMetalCommandCompletion: Sendable, Equatable {
    case succeeded
    case failed
}

@MainActor
package final class SpiceMetalFrameView: MTKView {
    private struct PendingPresentation {
        let sourceTexture: any MTLTexture
        let frame: SpiceFrame
        let requestedAt: ContinuousClock.Instant
        let interactionContext: SpiceInteractionPresentationContext?
        let onCompletion: @MainActor @Sendable (
            SpiceMetalCommandCompletion
        ) -> Void
    }

    package let presenter: SpiceMetalPresenter
    private var presentationDiagnostics: SpicePresentationDiagnostics?
    private var wasUsingMetal = false
    private var pendingPresentation: PendingPresentation?
    private var pendingDrawResult: SpiceMetalFramePresentationResult?
    private let clock = ContinuousClock()

    package override var isOpaque: Bool { true }

    package init?(
        presenter: SpiceMetalPresenter? = nil,
        presentationDiagnostics: SpicePresentationDiagnostics? = nil
    ) {
        guard let presenter = presenter ?? SpiceMetalPresenter(
            presentationDiagnostics: presentationDiagnostics
        ) else {
            return nil
        }
        self.presenter = presenter
        self.presentationDiagnostics = presentationDiagnostics
        super.init(frame: .zero, device: presenter.device)
        presenter.setPresentationDiagnostics(presentationDiagnostics)
        colorPixelFormat = .bgra8Unorm
        // MPS Lanczos writes directly into non-integer-scaled drawables.
        framebufferOnly = false
        autoResizeDrawable = false
        enableSetNeedsDisplay = false
        isPaused = true
        presentsWithTransaction = false
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        isHidden = true
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    package var canPresentWithoutBlocking: Bool {
        presenter.hasAvailableCommandSlot()
    }

    package func present(
        _ frame: SpiceFrame,
        requestedAt: ContinuousClock.Instant,
        interactionContext: SpiceInteractionPresentationContext? = nil,
        onCompletion: @escaping @MainActor @Sendable (
            SpiceMetalCommandCompletion
        ) -> Void = { _ in }
    ) -> SpiceMetalFramePresentationResult {
        let sourceTexture: any MTLTexture
        switch presenter.makeTextureResult(for: frame) {
        case let .texture(texture):
            sourceTexture = texture
        case let .cpuFallback(reason):
            presentationDiagnostics?.recordCPUFallback(reason)
            if wasUsingMetal {
                spiceRenderingLogger.info("Presentation path changed to AppKit CPU fallback")
            }
            wasUsingMetal = false
            isHidden = true
            return .cpuFallback(reason)
        }
        guard presenter.hasAvailableCommandSlot() else {
            presenter.recordGPUBusySkip()
            return .gpuBusy
        }

        // MTKView advances currentDrawable only after returning from one of its
        // drawing callbacks. Keep the view paused, but enter an explicit draw
        // cycle for every selected revision instead of reading currentDrawable
        // repeatedly from the display-link callback.
        guard pendingPresentation == nil else {
            presenter.recordGPUBusySkip()
            return .gpuBusy
        }
        pendingPresentation = PendingPresentation(
            sourceTexture: sourceTexture,
            frame: frame,
            requestedAt: requestedAt,
            interactionContext: interactionContext,
            onCompletion: onCompletion
        )
        pendingDrawResult = nil
        draw()

        guard let result = pendingDrawResult else {
            pendingPresentation = nil
            presentationDiagnostics?.recordMetalDrawableMiss()
            return .drawableUnavailable
        }
        pendingDrawResult = nil
        return result
    }

    package override func draw(_ dirtyRect: NSRect) {
        guard let pendingPresentation else { return }
        self.pendingPresentation = nil
        pendingDrawResult = presentDuringDraw(pendingPresentation)
    }

    private func presentDuringDraw(
        _ pending: PendingPresentation
    ) -> SpiceMetalFramePresentationResult {
        isHidden = false
        guard let drawable = currentDrawable else {
            presentationDiagnostics?.recordMetalDrawableMiss()
            return .drawableUnavailable
        }
        let presentationEpoch = presentationDiagnostics?.currentEpoch()
        guard let commandBuffer = presenter.makePresentationCommand(
            source: pending.sourceTexture,
            destination: drawable.texture,
            retaining: pending.frame,
            presentationEpoch: presentationEpoch
        ) else {
            if !presenter.hasAvailableCommandSlot() {
                return .gpuBusy
            }
            presentationDiagnostics?.recordMetalCommandCreationFailure()
            presentationDiagnostics?.recordCPUFallback(.metalCommandFailure)
            if wasUsingMetal {
                spiceRenderingLogger.info("Presentation path changed to AppKit CPU fallback")
            }
            wasUsingMetal = false
            isHidden = true
            return .cpuFallback(.metalCommandFailure)
        }

        let onCompletion = pending.onCompletion
        let committedAt = Mutex<ContinuousClock.Instant?>(nil)
        commandBuffer.addCompletedHandler { [presentationDiagnostics] commandBuffer in
            let completedAt = ContinuousClock().now
            if let committed = committedAt.withLock({ $0 }) {
                presentationDiagnostics?.recordMetalCommitToCompletion(
                    committed.duration(to: completedAt),
                    epoch: presentationEpoch
                )
            }
            let completion: SpiceMetalCommandCompletion =
                commandBuffer.status == .completed ? .succeeded : .failed
            Task { @MainActor in
                onCompletion(completion)
            }
        }
        let completionMetrics = presenter.completionMetrics
        let isAdvancedVideoFrame = pending.frame.isAdvancedVideoFrame
        let requestToPresentedStartedAt = pending.requestedAt
        let interactionIdentity = pending.interactionContext?.identity
        drawable.addPresentedHandler { [presentationDiagnostics] presentedDrawable in
            let mediaTimeNow = CACurrentMediaTime()
            let continuousNanosecondsNow = SpiceInteractionHostClock.nowNanoseconds()
            let presentedNanoseconds = SpiceInteractionHostClock.nanoseconds(
                forCoreAnimationTime: presentedDrawable.presentedTime,
                mediaTimeNow: mediaTimeNow,
                continuousNanosecondsNow: continuousNanosecondsNow
            )
            if let presentedNanoseconds,
               let requestedNanoseconds = SpiceInteractionHostClock.nanoseconds(
                   for: requestToPresentedStartedAt
               ),
               presentedNanoseconds >= requestedNanoseconds,
               let elapsed = Int64(
                   exactly: presentedNanoseconds - requestedNanoseconds
               ) {
                let duration = Duration.nanoseconds(elapsed)
                completionMetrics.recordDrawablePresented(duration)
                presentationDiagnostics?.recordMetalRequestToPresented(
                    duration,
                    epoch: presentationEpoch
                )
            }
            if let presentedNanoseconds {
                presentationDiagnostics?.recordMetalPresentedFrame(
                    isAdvancedVideo: isAdvancedVideoFrame,
                    epoch: presentationEpoch
                )
                Task { @MainActor in
                    if let interactionIdentity {
                        presentationDiagnostics?.recordInteractionPresented(
                            identity: interactionIdentity,
                            at: presentedNanoseconds
                        )
                    }
                }
            } else {
                Task { @MainActor in
                    if let interactionIdentity {
                        presentationDiagnostics?.recordInteractionPresentationDropped(
                            identity: interactionIdentity
                        )
                    }
                }
            }
        }
        commandBuffer.present(drawable)
        // Publish the call-boundary timestamp before commit so a completion on
        // another thread can never observe an empty timestamp. No diagnostics
        // or external work may be inserted between this store and `commit()`.
        let commitCallBoundary = clock.now
        committedAt.withLock { $0 = commitCallBoundary }
        commandBuffer.commit()
        presentationDiagnostics?.recordViewUpdateToMetalCommit(
            pending.requestedAt.duration(to: commitCallBoundary)
        )
        if let interactionIdentity,
           let committedNanoseconds = SpiceInteractionHostClock.nanoseconds(
               for: commitCallBoundary
           ) {
            presentationDiagnostics?.recordInteractionCommitted(
                identity: interactionIdentity,
                at: committedNanoseconds
            )
        }
        presentationDiagnostics?.recordMetalCommandBufferCommitted()

        if !wasUsingMetal {
            spiceRenderingLogger.info("Presentation path changed to Metal IOSurface")
        }
        wasUsingMetal = true
        return .committed
    }

    package func discardPresentedContent() {
        if wasUsingMetal {
            spiceRenderingLogger.info("Metal presentation paused while desktop is not visible")
        }
        wasUsingMetal = false
        pendingPresentation = nil
        pendingDrawResult = nil
        isHidden = true
    }

    package func setPresentationDiagnostics(_ diagnostics: SpicePresentationDiagnostics?) {
        presentationDiagnostics = diagnostics
        presenter.setPresentationDiagnostics(diagnostics)
    }

    @discardableResult
    package func updateDrawableSize(backingScaleFactor: CGFloat) -> Bool {
        let updatedSize = SpiceDesktopPresentationPolicy.drawableSize(
            for: bounds.size,
            backingScaleFactor: backingScaleFactor
        )
        guard drawableSize != updatedSize else { return false }
        drawableSize = updatedSize
        return true
    }
}
