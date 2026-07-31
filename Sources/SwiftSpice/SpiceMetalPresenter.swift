import CoreVideo
import Metal
import MetalKit
import OSLog

private let spiceRenderingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "org.swiftspice.SwiftSpice",
    category: "Rendering"
)

@MainActor
package final class SpiceMetalPresenter {
    package let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue

    package init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let commandQueue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = commandQueue
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
        commandBuffer.addCompletedHandler { commandBuffer in
            if commandBuffer.status == .error {
                spiceRenderingLogger.error(
                    "Metal frame copy failed: \(commandBuffer.error?.localizedDescription ?? "unknown", privacy: .public)"
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
        autoResizeDrawable = false
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
        drawableSize = CGSize(width: frame.width, height: frame.height)
        isHidden = false
        needsDisplay = true
        return true
    }

    func draw(in view: MTKView) {
        guard let frame = presentedFrame,
              let sourceTexture,
              let drawable = currentDrawable,
              let commandBuffer = presenter.makeCopyCommand(
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
}
