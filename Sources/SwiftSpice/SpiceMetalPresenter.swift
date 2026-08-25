import CoreVideo
import Foundation
import Metal
import MetalKit
import OSLog
import SpiceIOSurface
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
    case linear
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
    private let linearSampler: any MTLSamplerState
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

        let linearDescriptor = MTLSamplerDescriptor()
        linearDescriptor.minFilter = .linear
        linearDescriptor.magFilter = .linear
        linearDescriptor.mipFilter = .notMipmapped
        linearDescriptor.sAddressMode = .clampToEdge
        linearDescriptor.tAddressMode = .clampToEdge

        guard let nearestSampler = device.makeSamplerState(descriptor: nearestDescriptor),
              let linearSampler = device.makeSamplerState(descriptor: linearDescriptor)
        else {
            return nil
        }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.nearestSampler = nearestSampler
        self.linearSampler = linearSampler
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
            return .linear
        }
        if sourceWidth == destinationWidth, sourceHeight == destinationHeight {
            return .nearest
        }
        let isIntegerMagnification = destinationWidth >= sourceWidth
            && destinationHeight >= sourceHeight
            && destinationWidth.isMultiple(of: sourceWidth)
            && destinationHeight.isMultiple(of: sourceHeight)
        return isIntegerMagnification ? .nearest : .linear
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
        retaining frame: SpiceFrame
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

        let filter = Self.samplingFilter(
            sourceWidth: source.width,
            sourceHeight: source.height,
            destinationWidth: destination.width,
            destinationHeight: destination.height
        )
        encoder.label = "SwiftSpice fullscreen IOSurface presentation"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        encoder.setFragmentSamplerState(
            filter == .nearest ? nearestSampler : linearSampler,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

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
                presentationDiagnostics?.recordMetalPresentationError()
            }
        }
        return commandBuffer
    }

    private static func bundledShaderLibraryURL() -> URL? {
        var searchRoots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            searchRoots.append(resourceURL)
        }
        if let executableURL = Bundle.main.executableURL {
            searchRoots.append(executableURL.deletingLastPathComponent())
        }
        for root in searchRoots {
            let resourceBundle = root.appending(path: "SwiftSpice_SwiftSpice.bundle")
            let libraryURL = resourceBundle.appending(
                path: "SpiceVideoCompositor.metallib"
            )
            if FileManager.default.fileExists(atPath: libraryURL.path()) {
                return libraryURL
            }
        }
        #if DEBUG
        return Bundle.module.url(
            forResource: "SpiceVideoCompositor",
            withExtension: "metallib"
        )
        #else
        return nil
        #endif
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
    package let presenter: SpiceMetalPresenter
    private var presentationDiagnostics: SpicePresentationDiagnostics?
    private var wasUsingMetal = false
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
        framebufferOnly = true
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

        isHidden = false
        guard let drawable = currentDrawable else {
            presentationDiagnostics?.recordMetalDrawableMiss()
            return .drawableUnavailable
        }
        guard let commandBuffer = presenter.makePresentationCommand(
            source: sourceTexture,
            destination: drawable.texture,
            retaining: frame
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

        let committedAt = clock.now
        presentationDiagnostics?.recordViewUpdateToMetalCommit(
            requestedAt.duration(to: committedAt)
        )
        let completionStartedAt = committedAt
        commandBuffer.addCompletedHandler { [presentationDiagnostics] commandBuffer in
            presentationDiagnostics?.recordMetalCommitToCompletion(
                completionStartedAt.duration(to: ContinuousClock().now)
            )
            let completion: SpiceMetalCommandCompletion =
                commandBuffer.status == .completed ? .succeeded : .failed
            Task { @MainActor in
                onCompletion(completion)
            }
        }
        let completionMetrics = presenter.completionMetrics
        drawable.addPresentedHandler { [presentationDiagnostics] _ in
            let duration = requestedAt.duration(to: ContinuousClock().now)
            completionMetrics.recordDrawablePresented(duration)
            presentationDiagnostics?.recordMetalPresentedFrame()
            presentationDiagnostics?.recordMetalRequestToPresented(duration)
        }
        commandBuffer.present(drawable)
        presentationDiagnostics?.recordMetalCommandBufferCommitted()
        commandBuffer.commit()

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
