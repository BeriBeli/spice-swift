import CoreVideo
import Metal
import MetalKit
import MetalPerformanceShaders
import OSLog
import SpiceIOSurface
import Synchronization

private let spiceRenderingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "org.swiftspice.SwiftSpice",
    category: "Rendering"
)

package struct SpiceMetalPresenterMetrics: Sendable, Equatable {
    package let commandErrors: UInt64
}

package enum SpiceMetalTextureResult {
    case texture(any MTLTexture)
    case cpuFallback(SpiceCPUPresentationFallbackReason)
}

private final class SpiceMetalPresenterCompletionMetrics: Sendable {
    private struct State: Sendable {
        var commandErrors: UInt64 = 0
        var loggedFirstCommandError = false
    }

    private let state = Mutex(State())

    func recordCommandError() -> Bool {
        state.withLock { state in
            state.commandErrors &+= 1
            guard !state.loggedFirstCommandError else { return false }
            state.loggedFirstCommandError = true
            return true
        }
    }

    func snapshot() -> SpiceMetalPresenterMetrics {
        state.withLock { SpiceMetalPresenterMetrics(commandErrors: $0.commandErrors) }
    }
}

@MainActor
package final class SpiceMetalPresenter {
    package let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    private let scaler: MPSImageLanczosScale
    private let completionMetrics = SpiceMetalPresenterCompletionMetrics()
    private var presentationDiagnostics: SpicePresentationDiagnostics?

    package init?(
        device: (any MTLDevice)? = SpiceMetalSystemDevice.shared.device,
        presentationDiagnostics: SpicePresentationDiagnostics? = nil
    ) {
        guard let device, let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        let scaler = MPSImageLanczosScale(device: device)
        scaler.edgeMode = .clamp
        self.scaler = scaler
        self.presentationDiagnostics = presentationDiagnostics
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
        return .texture(texture)
    }

    package nonisolated func metrics() -> SpiceMetalPresenterMetrics {
        completionMetrics.snapshot()
    }

    package func setPresentationDiagnostics(_ diagnostics: SpicePresentationDiagnostics?) {
        presentationDiagnostics = diagnostics
    }

    /// The returned command buffer retains the frame lease until GPU completion,
    /// preventing the pool from recycling its IOSurface during an in-flight copy.
    package func makeCopyCommand(
        source: any MTLTexture,
        destination: any MTLTexture,
        retaining frame: SpiceFrame
    ) -> (any MTLCommandBuffer)? {
        guard source.pixelFormat == .bgra8Unorm,
              destination.pixelFormat == .bgra8Unorm,
              source.width == destination.width,
              source.height == destination.height,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            return nil
        }
        blit.copy(
            from: source,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: source.width, height: source.height, depth: 1),
            to: destination,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        blit.endEncoding()
        commandBuffer.addCompletedHandler {
            [completionMetrics, presentationDiagnostics] commandBuffer in
            if commandBuffer.status == .error, completionMetrics.recordCommandError() {
                spiceRenderingLogger.error(
                    "Metal frame copy failed: \(commandBuffer.error?.localizedDescription ?? "unknown", privacy: .public)"
                )
            }
            if commandBuffer.status == .error {
                presentationDiagnostics?.recordMetalPresentationError()
            }
            withExtendedLifetime(frame) {}
        }
        return commandBuffer
    }

    /// Builds a presentation command that preserves exact pixels at 1:1 and
    /// performs one high-quality GPU scale when the drawable uses backing pixels.
    package func makePresentationCommand(
        source: any MTLTexture,
        destination: any MTLTexture,
        retaining frame: SpiceFrame
    ) -> (any MTLCommandBuffer)? {
        guard source.pixelFormat == .bgra8Unorm,
              destination.pixelFormat == .bgra8Unorm
        else {
            return nil
        }
        if source.width == destination.width, source.height == destination.height {
            return makeCopyCommand(
                source: source,
                destination: destination,
                retaining: frame
            )
        }
        guard source.width > 0,
              source.height > 0,
              destination.width > 0,
              destination.height > 0,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return nil
        }
        scaler.encode(
            commandBuffer: commandBuffer,
            sourceTexture: source,
            destinationTexture: destination
        )
        commandBuffer.addCompletedHandler {
            [completionMetrics, presentationDiagnostics] commandBuffer in
            if commandBuffer.status == .error, completionMetrics.recordCommandError() {
                spiceRenderingLogger.error(
                    "Metal frame scale failed: \(commandBuffer.error?.localizedDescription ?? "unknown", privacy: .public)"
                )
            }
            if commandBuffer.status == .error {
                presentationDiagnostics?.recordMetalPresentationError()
            }
            withExtendedLifetime(frame) {}
        }
        return commandBuffer
    }
}

@MainActor
final class SpiceMetalFrameView: MTKView, MTKViewDelegate {
    private let presenter: SpiceMetalPresenter
    private var presentationDiagnostics: SpicePresentationDiagnostics?
    private var presentedFrame: SpiceFrame?
    private var sourceTexture: (any MTLTexture)?
    private var wasUsingMetal = false
    private var presentedFrameGeneration: UInt64 = 0
    private var recordedFrameGeneration: UInt64?
    private let clock = ContinuousClock()
    private var presentedFrameRequestedAt: ContinuousClock.Instant?

    override var isOpaque: Bool { true }

    init?(
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
        framebufferOnly = false
        autoResizeDrawable = true
        enableSetNeedsDisplay = true
        isPaused = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        delegate = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func present(_ frame: SpiceFrame?) -> Bool {
        guard let frame else {
            if wasUsingMetal {
                spiceRenderingLogger.info("Presentation path changed to AppKit CPU fallback")
            }
            wasUsingMetal = false
            presentedFrame = nil
            sourceTexture = nil
            isHidden = true
            return false
        }
        let texture: any MTLTexture
        switch presenter.makeTextureResult(for: frame) {
        case let .texture(sourceTexture):
            texture = sourceTexture
        case let .cpuFallback(reason):
            presentationDiagnostics?.recordCPUFallback(reason)
            if wasUsingMetal {
                spiceRenderingLogger.info("Presentation path changed to AppKit CPU fallback")
            }
            wasUsingMetal = false
            presentedFrame = nil
            sourceTexture = nil
            isHidden = true
            return false
        }
        presentedFrame = frame
        sourceTexture = texture
        presentedFrameGeneration &+= 1
        presentedFrameRequestedAt = clock.now
        if !wasUsingMetal {
            spiceRenderingLogger.info("Presentation path changed to Metal IOSurface")
        }
        wasUsingMetal = true
        isHidden = false
        needsDisplay = true
        return true
    }

    func setPresentationDiagnostics(_ diagnostics: SpicePresentationDiagnostics?) {
        presentationDiagnostics = diagnostics
        presenter.setPresentationDiagnostics(diagnostics)
    }

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    func draw(in view: MTKView) {
        guard let frame = presentedFrame,
              let sourceTexture else { return }
        guard let drawable = currentDrawable else {
            presentationDiagnostics?.recordMetalDrawableMiss()
            return
        }
        guard let commandBuffer = presenter.makePresentationCommand(
            source: sourceTexture,
            destination: drawable.texture,
            retaining: frame
        ) else {
            presentationDiagnostics?.recordMetalCommandCreationFailure()
            return
        }
        let committedAt = clock.now
        let isNewFrame = recordedFrameGeneration != presentedFrameGeneration
        if isNewFrame {
            if let presentedFrameRequestedAt {
                presentationDiagnostics?.recordViewUpdateToMetalCommit(
                    presentedFrameRequestedAt.duration(to: committedAt)
                )
            }
            self.presentedFrameRequestedAt = nil
            let completionStartedAt = committedAt
            commandBuffer.addCompletedHandler { [presentationDiagnostics] _ in
                presentationDiagnostics?.recordMetalCommitToCompletion(
                    completionStartedAt.duration(to: ContinuousClock().now)
                )
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if isNewFrame {
            let previousGeneration = recordedFrameGeneration ?? 0
            let superseded = presentedFrameGeneration > previousGeneration
                ? presentedFrameGeneration - previousGeneration - 1
                : 0
            presentationDiagnostics?.recordMetalFramesSupersededBeforeDraw(superseded)
            recordedFrameGeneration = presentedFrameGeneration
            presentationDiagnostics?.recordMetalPresentedFrame()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func updateDrawableSize() {
        let backingScaleFactor = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        drawableSize = SpiceDesktopPresentationPolicy.drawableSize(
            for: bounds.size,
            backingScaleFactor: backingScaleFactor
        )
        needsDisplay = true
    }
}
