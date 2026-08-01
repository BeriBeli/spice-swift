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

    package init?(device: (any MTLDevice)? = SpiceMetalSystemDevice.shared.device) {
        guard let device, let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
        self.scaler = MPSImageLanczosScale(device: device)
    }

    package func makeTexture(for frame: SpiceFrame) -> (any MTLTexture)? {
        guard let ioSurface = frame.ioSurface,
              ioSurface.width == frame.width,
              ioSurface.height == frame.height,
              ioSurface.pixelFormat == kCVPixelFormatType_32BGRA
        else {
            return nil
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        return ioSurface.backing.withIOSurface { surface in
            device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)
        }
    }

    package nonisolated func metrics() -> SpiceMetalPresenterMetrics {
        completionMetrics.snapshot()
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
        commandBuffer.addCompletedHandler { [completionMetrics] commandBuffer in
            if commandBuffer.status == .error, completionMetrics.recordCommandError() {
                spiceRenderingLogger.error(
                    "Metal frame copy failed: \(commandBuffer.error?.localizedDescription ?? "unknown", privacy: .public)"
                )
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
        commandBuffer.addCompletedHandler { [completionMetrics] commandBuffer in
            if commandBuffer.status == .error, completionMetrics.recordCommandError() {
                spiceRenderingLogger.error(
                    "Metal frame scale failed: \(commandBuffer.error?.localizedDescription ?? "unknown", privacy: .public)"
                )
            }
            withExtendedLifetime(frame) {}
        }
        return commandBuffer
    }
}

@MainActor
final class SpiceMetalFrameView: MTKView, MTKViewDelegate {
    private let presenter: SpiceMetalPresenter
    private var presentedFrame: SpiceFrame?
    private var sourceTexture: (any MTLTexture)?
    private var wasUsingMetal = false

    override var isOpaque: Bool { true }

    init?(presenter: SpiceMetalPresenter? = nil) {
        guard let presenter = presenter ?? SpiceMetalPresenter() else {
            return nil
        }
        self.presenter = presenter
        super.init(frame: .zero, device: presenter.device)
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
        guard let frame, let texture = presenter.makeTexture(for: frame) else {
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
        if !wasUsingMetal {
            spiceRenderingLogger.info("Presentation path changed to Metal IOSurface")
        }
        wasUsingMetal = true
        isHidden = false
        needsDisplay = true
        return true
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
              let sourceTexture,
              let drawable = currentDrawable,
              let commandBuffer = presenter.makePresentationCommand(
                  source: sourceTexture,
                  destination: drawable.texture,
                  retaining: frame
              )
        else {
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
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
