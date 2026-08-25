import CoreVideo
import Foundation
import IOSurface
import Metal
import SpiceCodecs
import SpiceIOSurface
import SpiceVideoToolbox
import Synchronization

package enum SpiceMetalVideoOrientation: Sendable, Equatable {
    case topDown
    case bottomUp
}

package struct SpiceMetalVideoRectangle: Sendable, Equatable {
    package let x: Int
    package let y: Int
    package let width: Int
    package let height: Int

    package init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

package enum SpiceMetalCompositorFallback: Sendable, Equatable {
    /// The native binding or metadata for this frame cannot be used by Metal.
    /// The stream generation may try the GPU path again on its next frame.
    case frame

    /// The pipeline or command submission failed. The caller must keep the
    /// current stream generation on its CPU materializer from this point on.
    case streamGeneration
}

package enum SpiceMetalCompositorError: Error, Sendable, Equatable {
    case unsupportedDevice
    case shaderLibraryUnavailable(String)
    case pipelineCreationFailed(String)
    case commandQueueUnavailable
    case unsupportedPixelFormat(OSType)
    case unsupportedColorMatrix
    case unsupportedColorRange
    case unsupportedGeometry(width: Int, height: Int)
    case invalidSourceRectangle
    case invalidDestination(String)
    case sourceTextureMappingFailed(plane: Int, status: CVReturn)
    case destinationTextureMappingFailed
    case commandBufferUnavailable
    case commandEncoderUnavailable
    case commandExecutionFailed(String)

    package var fallback: SpiceMetalCompositorFallback {
        switch self {
        case .unsupportedPixelFormat,
             .unsupportedColorMatrix,
             .unsupportedColorRange,
             .unsupportedGeometry,
             .invalidSourceRectangle,
             .invalidDestination,
             .sourceTextureMappingFailed,
             .destinationTextureMappingFailed:
            .frame
        case .unsupportedDevice,
             .shaderLibraryUnavailable,
             .pipelineCreationFailed,
             .commandQueueUnavailable,
             .commandBufferUnavailable,
             .commandEncoderUnavailable,
             .commandExecutionFailed:
            .streamGeneration
        }
    }
}

extension SpiceMetalCompositorError: CustomStringConvertible {
    package var description: String {
        switch self {
        case .unsupportedDevice:
            "Metal compositor requires Apple unified memory and GPU family Apple 7 or newer"
        case let .shaderLibraryUnavailable(reason):
            "Metal shader library is unavailable: \(reason)"
        case let .pipelineCreationFailed(reason):
            "Metal compositor pipeline creation failed: \(reason)"
        case .commandQueueUnavailable:
            "Metal device did not create a command queue"
        case let .unsupportedPixelFormat(pixelFormat):
            "Metal compositor does not support pixel format \(pixelFormat)"
        case .unsupportedColorMatrix:
            "Metal compositor does not recognize the source color matrix"
        case .unsupportedColorRange:
            "Metal compositor does not recognize the source color range"
        case let .unsupportedGeometry(width, height):
            "Metal compositor does not support source dimensions \(width)x\(height)"
        case .invalidSourceRectangle:
            "Metal compositor source rectangle is outside the decoded frame"
        case let .invalidDestination(reason):
            "Metal compositor destination is invalid: \(reason)"
        case let .sourceTextureMappingFailed(plane, status):
            "CVMetalTexture mapping failed for plane \(plane) with status \(status)"
        case .destinationTextureMappingFailed:
            "IOSurface could not be mapped as a writable BGRA Metal texture"
        case .commandBufferUnavailable:
            "Metal command queue did not create a command buffer"
        case .commandEncoderUnavailable:
            "Metal command buffer did not create a compute encoder"
        case let .commandExecutionFailed(reason):
            "Metal compositor command failed: \(reason)"
        }
    }
}

/// Converts IOSurface-backed NV12 or packed-BGRA `CVPixelBuffer` frames directly
/// into a candidate BGRA IOSurface. The caller remains responsible for
/// transactional publication: only make the candidate canonical after this
/// method returns successfully.
package final class SpiceMetalCompositor: @unchecked Sendable {
    package let device: any MTLDevice

    private let commandQueue: any MTLCommandQueue
    private let nv12Pipeline: any MTLComputePipelineState
    private let bgraPipeline: any MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private let textureCacheLock = Mutex(())

    package static func supportsUnifiedVideoPath(device: any MTLDevice) -> Bool {
        device.hasUnifiedMemory && device.supportsFamily(.apple7)
    }

    package init(
        device: (any MTLDevice)? = SpiceMetalSystemDevice.shared.device,
        libraryURL: URL? = nil
    ) throws(SpiceMetalCompositorError) {
        guard let device, Self.supportsUnifiedVideoPath(device: device) else {
            throw .unsupportedDevice
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw .commandQueueUnavailable
        }
        guard ShaderUniforms.hasExpectedMetalLayout else {
            throw .pipelineCreationFailed("Swift/Metal uniform layout does not match")
        }

        let resolvedLibraryURL: URL
        if let libraryURL {
            resolvedLibraryURL = libraryURL
        } else if let bundledURL = Self.bundledShaderLibraryURL() {
            resolvedLibraryURL = bundledURL
        } else {
            throw .shaderLibraryUnavailable("SpiceVideoCompositor.metallib is missing from the resource bundle")
        }

        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(URL: resolvedLibraryURL)
        } catch {
            throw .shaderLibraryUnavailable(String(describing: error))
        }
        guard let nv12Function = library.makeFunction(name: "spice_nv12_to_bgra") else {
            throw .shaderLibraryUnavailable("spice_nv12_to_bgra entry point is missing")
        }
        guard let bgraFunction = library.makeFunction(name: "spice_bgra_to_bgra") else {
            throw .shaderLibraryUnavailable("spice_bgra_to_bgra entry point is missing")
        }

        let nv12Pipeline: any MTLComputePipelineState
        let bgraPipeline: any MTLComputePipelineState
        do {
            nv12Pipeline = try device.makeComputePipelineState(function: nv12Function)
            bgraPipeline = try device.makeComputePipelineState(function: bgraFunction)
        } catch {
            throw .pipelineCreationFailed(String(describing: error))
        }

        var cache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard cacheStatus == kCVReturnSuccess, let cache else {
            throw .pipelineCreationFailed("CVMetalTextureCache creation status \(cacheStatus)")
        }

        self.device = device
        self.commandQueue = commandQueue
        self.nv12Pipeline = nv12Pipeline
        self.bgraPipeline = bgraPipeline
        self.textureCache = cache
    }

    private static func bundledShaderLibraryURL() -> URL? {
        // Locate by relative bundle structure in packaged apps and SwiftPM test
        // runs. Deliberately avoid Bundle.module here: its generated fallback
        // embeds an absolute build-machine path in clients of a static library.
        var searchRoots: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            searchRoots.append(resourceURL)
        }
        if let executableURL = Bundle.main.executableURL {
            searchRoots.append(executableURL.deletingLastPathComponent())
        }
        for root in searchRoots {
            let resourceBundle = root.appending(
                path: "SwiftSpice_SpiceMetalCompositor.bundle"
            )
            let libraryURL = resourceBundle.appending(
                path: "SpiceVideoCompositor.metallib"
            )
            if FileManager.default.fileExists(atPath: libraryURL.path()) {
                return libraryURL
            }
        }
        #if DEBUG
        // SwiftPM's test runner is not always Bundle.main. Its generated module
        // accessor is safe as a debug-only fallback; release binaries retain
        // only the relocatable app/resource lookup above.
        return Bundle.module.url(
            forResource: "SpiceVideoCompositor",
            withExtension: "metallib"
        )
        #else
        return nil
        #endif
    }

    /// Uses one compute pass for range expansion, YCbCr conversion, orientation,
    /// nearest-neighbor scaling, clipping, and candidate-surface output.
    ///
    /// This function never waits synchronously for the GPU. The continuation is
    /// resumed by Metal's completion callback, which also owns every live Core
    /// Video texture binding until the command has finished.
    package func composite(
        frame: any SpiceDecodedVideoFrame,
        sourceRect: SpiceMetalVideoRectangle? = nil,
        orientation: SpiceMetalVideoOrientation,
        into destination: IOSurfaceRef,
        destinationRect: SpiceMetalVideoRectangle,
        clip: SpiceMetalVideoRectangle
    ) async throws(SpiceMetalCompositorError) {
        try await composite(
            frame: frame,
            sourceRect: sourceRect,
            orientation: orientation,
            into: destination,
            destinationRect: destinationRect,
            clips: [clip]
        )
    }

    package func composite(
        frame: any SpiceDecodedVideoFrame,
        sourceRect: SpiceMetalVideoRectangle? = nil,
        orientation: SpiceMetalVideoOrientation,
        into destination: IOSurfaceRef,
        destinationRect: SpiceMetalVideoRectangle,
        clips: [SpiceMetalVideoRectangle]
    ) async throws(SpiceMetalCompositorError) {
        let pixelBuffer: CVPixelBuffer
        if let frame = frame as? SpiceVideoToolboxFrame {
            pixelBuffer = frame.pixelBuffer
        } else if let frame = frame as? SpiceMJPEGFrame {
            pixelBuffer = frame.pixelBuffer
        } else {
            throw .unsupportedPixelFormat(0)
        }
        // In particular, SpiceMJPEGFrame owns the pool lease that prevents a
        // decoder from reusing this pixel buffer. Keep the frame itself alive
        // through Metal completion, not only its CVPixelBuffer view.
        defer { withExtendedLifetime(frame) {} }
        try await composite(
            pixelBuffer: pixelBuffer,
            pixelFormat: frame.pixelFormat,
            colorMatrix: frame.colorMatrix,
            colorRange: frame.colorRange,
            sourceRect: sourceRect,
            orientation: orientation,
            into: destination,
            destinationRect: destinationRect,
            clips: clips
        )
    }

    package func composite(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: SpiceDecodedVideoPixelFormat,
        colorMatrix: SpiceVideoColorMatrix,
        colorRange: SpiceVideoColorRange,
        sourceRect requestedSourceRect: SpiceMetalVideoRectangle? = nil,
        orientation: SpiceMetalVideoOrientation,
        into destination: IOSurfaceRef,
        destinationRect: SpiceMetalVideoRectangle,
        clip: SpiceMetalVideoRectangle
    ) async throws(SpiceMetalCompositorError) {
        try await composite(
            pixelBuffer: pixelBuffer,
            pixelFormat: pixelFormat,
            colorMatrix: colorMatrix,
            colorRange: colorRange,
            sourceRect: requestedSourceRect,
            orientation: orientation,
            into: destination,
            destinationRect: destinationRect,
            clips: [clip]
        )
    }

    package func composite(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: SpiceDecodedVideoPixelFormat,
        colorMatrix: SpiceVideoColorMatrix,
        colorRange: SpiceVideoColorRange,
        sourceRect requestedSourceRect: SpiceMetalVideoRectangle? = nil,
        orientation: SpiceMetalVideoOrientation,
        into destination: IOSurfaceRef,
        destinationRect: SpiceMetalVideoRectangle,
        clips: [SpiceMetalVideoRectangle]
    ) async throws(SpiceMetalCompositorError) {
        if pixelFormat == .bgra8 {
            try await compositePackedBGRA(
                pixelBuffer: pixelBuffer,
                sourceRect: requestedSourceRect,
                orientation: orientation,
                into: destination,
                destinationRect: destinationRect,
                clips: clips
            )
            return
        }
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard sourceWidth > 0,
              sourceHeight > 0,
              sourceWidth.isMultiple(of: 2),
              sourceHeight.isMultiple(of: 2),
              UInt32(exactly: sourceWidth) != nil,
              UInt32(exactly: sourceHeight) != nil
        else {
            throw .unsupportedGeometry(width: sourceWidth, height: sourceHeight)
        }
        guard pixelFormat == .nv12 else {
            throw .unsupportedPixelFormat(CVPixelBufferGetPixelFormatType(pixelBuffer))
        }
        let cvPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard cvPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || cvPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        else {
            throw .unsupportedPixelFormat(cvPixelFormat)
        }
        guard (cvPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                && colorRange == .video)
                || (cvPixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                    && colorRange == .full)
        else {
            throw .unsupportedColorRange
        }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) == 2,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == sourceWidth,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == sourceHeight,
              CVPixelBufferGetWidthOfPlane(pixelBuffer, 1) == sourceWidth / 2,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 1) == sourceHeight / 2
        else {
            throw .unsupportedGeometry(width: sourceWidth, height: sourceHeight)
        }
        let sourceBounds = SpiceMetalVideoRectangle(
            x: 0,
            y: 0,
            width: sourceWidth,
            height: sourceHeight
        )
        let sourceRect = requestedSourceRect ?? sourceBounds
        guard sourceRect.isValid,
              sourceRect.fitsShaderCoordinates,
              sourceRect.intersection(sourceBounds) == sourceRect
        else {
            throw .invalidSourceRectangle
        }

        let destinationWidth = IOSurfaceGetWidth(destination)
        let destinationHeight = IOSurfaceGetHeight(destination)
        let (destinationRowBytes, destinationRowOverflow) = destinationWidth
            .multipliedReportingOverflow(by: 4)
        guard destinationWidth > 0, destinationHeight > 0,
              !destinationRowOverflow,
              UInt32(exactly: destinationWidth) != nil,
              UInt32(exactly: destinationHeight) != nil,
              IOSurfaceGetPixelFormat(destination) == kCVPixelFormatType_32BGRA,
              IOSurfaceGetBytesPerRow(destination) >= destinationRowBytes
        else {
            throw .invalidDestination("IOSurface is not a valid packed BGRA surface")
        }
        let surfaceBounds = SpiceMetalVideoRectangle(
            x: 0,
            y: 0,
            width: destinationWidth,
            height: destinationHeight
        )
        guard destinationRect.isValid,
              destinationRect.fitsShaderCoordinates,
              destinationRect.intersection(surfaceBounds) == destinationRect
        else {
            throw .invalidDestination("destination rectangle is outside the IOSurface")
        }
        let (_, horizontalScaleOverflow) = UInt32(destinationRect.width - 1)
            .multipliedReportingOverflow(by: UInt32(sourceRect.width))
        let (_, verticalScaleOverflow) = UInt32(destinationRect.height - 1)
            .multipliedReportingOverflow(by: UInt32(sourceRect.height))
        guard !horizontalScaleOverflow, !verticalScaleOverflow else {
            throw .invalidDestination("scale geometry exceeds shader coordinates")
        }
        var clippedRectangles: [SpiceMetalVideoRectangle] = []
        clippedRectangles.reserveCapacity(clips.count)
        for clip in clips {
            guard clip.isValid else {
                throw .invalidDestination("clip rectangle is invalid")
            }
            guard let clipped = clip.intersection(destinationRect) else {
                continue
            }
            guard clipped.fitsShaderCoordinates else {
                throw .invalidDestination("clip rectangle exceeds shader coordinates")
            }
            clippedRectangles.append(clipped)
        }
        guard !clippedRectangles.isEmpty else {
            return
        }

        let colorConversion = try ColorConversion(
            matrix: colorMatrix,
            range: colorRange
        )
        let sourceTextures = try makeSourceTextures(
            pixelBuffer: pixelBuffer,
            width: sourceWidth,
            height: sourceHeight
        )
        let destinationTexture = try makeDestinationTexture(
            surface: destination,
            width: destinationWidth,
            height: destinationHeight
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw .commandBufferUnavailable
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw .commandEncoderUnavailable
        }

        encoder.setComputePipelineState(nv12Pipeline)
        encoder.setTexture(sourceTextures.lumaTexture, index: 0)
        encoder.setTexture(sourceTextures.chromaTexture, index: 1)
        encoder.setTexture(destinationTexture, index: 2)

        let threadWidth = nv12Pipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            nv12Pipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        for clippedRect in clippedRectangles {
            var uniforms = ShaderUniforms(
                sourceAndFlags: SIMD4(
                    UInt32(sourceWidth),
                    UInt32(sourceHeight),
                    orientation == .bottomUp ? 1 : 0,
                    0
                ),
                sourceRect: sourceRect.unsignedComponents,
                destinationRect: destinationRect.unsignedComponents,
                clipRect: clippedRect.unsignedComponents,
                rangeParameters: colorConversion.rangeParameters,
                redCoefficients: colorConversion.redCoefficients,
                greenCoefficients: colorConversion.greenCoefficients,
                blueCoefficients: colorConversion.blueCoefficients
            )
            encoder.setBytes(
                &uniforms,
                length: MemoryLayout<ShaderUniforms>.stride,
                index: 0
            )
            encoder.dispatchThreads(
                MTLSize(width: clippedRect.width, height: clippedRect.height, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: threadWidth,
                    height: threadHeight,
                    depth: 1
                )
            )
        }
        encoder.endEncoding()

        let retainedResources = RetainedVideoResources(
            pixelBuffer: pixelBuffer,
            lumaBinding: sourceTextures.lumaBinding,
            chromaBinding: sourceTextures.chromaBinding,
            destinationSurface: destination,
            destinationTexture: destinationTexture
        )
        let result: Result<Void, SpiceMetalCompositorError> = await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { completedBuffer in
                defer { withExtendedLifetime(retainedResources) {} }
                if completedBuffer.status == .completed {
                    continuation.resume(returning: .success(()))
                } else {
                    let reason = completedBuffer.error.map(String.init(describing:))
                        ?? "command status \(completedBuffer.status.rawValue)"
                    continuation.resume(returning: .failure(.commandExecutionFailed(reason)))
                }
            }
            commandBuffer.commit()
        }
        try result.get()
    }

    /// Copies an IOSurface-backed packed-BGRA stream frame into the candidate
    /// surface while applying the same orientation, nearest scaling, and clip
    /// semantics as the CPU SurfaceStore path. No intermediate texture or Data
    /// allocation is created.
    private func compositePackedBGRA(
        pixelBuffer: CVPixelBuffer,
        sourceRect requestedSourceRect: SpiceMetalVideoRectangle?,
        orientation: SpiceMetalVideoOrientation,
        into destination: IOSurfaceRef,
        destinationRect: SpiceMetalVideoRectangle,
        clips: [SpiceMetalVideoRectangle]
    ) async throws(SpiceMetalCompositorError) {
        let sourceWidth = CVPixelBufferGetWidth(pixelBuffer)
        let sourceHeight = CVPixelBufferGetHeight(pixelBuffer)
        let cvPixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard sourceWidth > 0,
              sourceHeight > 0,
              UInt32(exactly: sourceWidth) != nil,
              UInt32(exactly: sourceHeight) != nil
        else {
            throw .unsupportedGeometry(width: sourceWidth, height: sourceHeight)
        }
        guard cvPixelFormat == kCVPixelFormatType_32BGRA else {
            throw .unsupportedPixelFormat(cvPixelFormat)
        }
        let sourceBounds = SpiceMetalVideoRectangle(
            x: 0,
            y: 0,
            width: sourceWidth,
            height: sourceHeight
        )
        let sourceRect = requestedSourceRect ?? sourceBounds
        guard sourceRect.isValid,
              sourceRect.fitsShaderCoordinates,
              sourceRect.intersection(sourceBounds) == sourceRect
        else {
            throw .invalidSourceRectangle
        }

        let destinationWidth = IOSurfaceGetWidth(destination)
        let destinationHeight = IOSurfaceGetHeight(destination)
        let (destinationRowBytes, destinationRowOverflow) = destinationWidth
            .multipliedReportingOverflow(by: 4)
        guard destinationWidth > 0, destinationHeight > 0,
              !destinationRowOverflow,
              UInt32(exactly: destinationWidth) != nil,
              UInt32(exactly: destinationHeight) != nil,
              IOSurfaceGetPixelFormat(destination) == kCVPixelFormatType_32BGRA,
              IOSurfaceGetBytesPerRow(destination) >= destinationRowBytes
        else {
            throw .invalidDestination("IOSurface is not a valid packed BGRA surface")
        }
        let surfaceBounds = SpiceMetalVideoRectangle(
            x: 0,
            y: 0,
            width: destinationWidth,
            height: destinationHeight
        )
        guard destinationRect.isValid,
              destinationRect.fitsShaderCoordinates,
              destinationRect.intersection(surfaceBounds) == destinationRect
        else {
            throw .invalidDestination("destination rectangle is outside the IOSurface")
        }
        let (_, horizontalScaleOverflow) = UInt32(destinationRect.width - 1)
            .multipliedReportingOverflow(by: UInt32(sourceRect.width))
        let (_, verticalScaleOverflow) = UInt32(destinationRect.height - 1)
            .multipliedReportingOverflow(by: UInt32(sourceRect.height))
        guard !horizontalScaleOverflow, !verticalScaleOverflow else {
            throw .invalidDestination("scale geometry exceeds shader coordinates")
        }
        var clippedRectangles: [SpiceMetalVideoRectangle] = []
        clippedRectangles.reserveCapacity(clips.count)
        for clip in clips {
            guard clip.isValid else {
                throw .invalidDestination("clip rectangle is invalid")
            }
            guard let clipped = clip.intersection(destinationRect) else {
                continue
            }
            guard clipped.fitsShaderCoordinates else {
                throw .invalidDestination("clip rectangle exceeds shader coordinates")
            }
            clippedRectangles.append(clipped)
        }
        guard !clippedRectangles.isEmpty else {
            return
        }

        let sourceTexture = try makePackedSourceTexture(
            pixelBuffer: pixelBuffer,
            width: sourceWidth,
            height: sourceHeight
        )
        let destinationTexture = try makeDestinationTexture(
            surface: destination,
            width: destinationWidth,
            height: destinationHeight
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw .commandBufferUnavailable
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw .commandEncoderUnavailable
        }

        encoder.setComputePipelineState(bgraPipeline)
        encoder.setTexture(sourceTexture.texture, index: 0)
        encoder.setTexture(destinationTexture, index: 2)
        let threadWidth = bgraPipeline.threadExecutionWidth
        let threadHeight = max(
            1,
            bgraPipeline.maxTotalThreadsPerThreadgroup / threadWidth
        )
        for clippedRect in clippedRectangles {
            var uniforms = ShaderUniforms(
                sourceAndFlags: SIMD4(
                    UInt32(sourceWidth),
                    UInt32(sourceHeight),
                    orientation == .bottomUp ? 1 : 0,
                    0
                ),
                sourceRect: sourceRect.unsignedComponents,
                destinationRect: destinationRect.unsignedComponents,
                clipRect: clippedRect.unsignedComponents,
                rangeParameters: .zero,
                redCoefficients: .zero,
                greenCoefficients: .zero,
                blueCoefficients: .zero
            )
            encoder.setBytes(
                &uniforms,
                length: MemoryLayout<ShaderUniforms>.stride,
                index: 0
            )
            encoder.dispatchThreads(
                MTLSize(width: clippedRect.width, height: clippedRect.height, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: threadWidth,
                    height: threadHeight,
                    depth: 1
                )
            )
        }
        encoder.endEncoding()

        let retainedResources = RetainedPackedVideoResources(
            pixelBuffer: pixelBuffer,
            sourceBinding: sourceTexture.binding,
            sourceTexture: sourceTexture.texture,
            destinationSurface: destination,
            destinationTexture: destinationTexture
        )
        let result: Result<Void, SpiceMetalCompositorError> = await withCheckedContinuation {
            continuation in
            commandBuffer.addCompletedHandler { completedBuffer in
                defer { withExtendedLifetime(retainedResources) {} }
                if completedBuffer.status == .completed {
                    continuation.resume(returning: .success(()))
                } else {
                    let reason = completedBuffer.error.map(String.init(describing:))
                        ?? "command status \(completedBuffer.status.rawValue)"
                    continuation.resume(returning: .failure(.commandExecutionFailed(reason)))
                }
            }
            commandBuffer.commit()
        }
        try result.get()
    }

    private func makePackedSourceTexture(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws(SpiceMetalCompositorError) -> PackedSourceTexture {
        let result: Result<PackedSourceTexture, SpiceMetalCompositorError> = textureCacheLock.withLock { _ in
            do {
                let source = try makeSourceTexture(
                    pixelBuffer: pixelBuffer,
                    pixelFormat: .bgra8Unorm,
                    width: width,
                    height: height,
                    plane: 0
                )
                return .success(PackedSourceTexture(
                    binding: source.binding,
                    texture: source.texture
                ))
            } catch let error as SpiceMetalCompositorError {
                return .failure(error)
            } catch {
                return .failure(.pipelineCreationFailed(String(describing: error)))
            }
        }
        return try result.get()
    }

    private func makeSourceTextures(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) throws(SpiceMetalCompositorError) -> SourceTextures {
        let result: Result<SourceTextures, SpiceMetalCompositorError> = textureCacheLock.withLock { _ in
            do {
                let lumaBinding = try makeSourceTexture(
                    pixelBuffer: pixelBuffer,
                    pixelFormat: .r8Unorm,
                    width: width,
                    height: height,
                    plane: 0
                )
                let chromaBinding = try makeSourceTexture(
                    pixelBuffer: pixelBuffer,
                    pixelFormat: .rg8Unorm,
                    width: width / 2,
                    height: height / 2,
                    plane: 1
                )
                return .success(SourceTextures(
                    lumaBinding: lumaBinding.binding,
                    lumaTexture: lumaBinding.texture,
                    chromaBinding: chromaBinding.binding,
                    chromaTexture: chromaBinding.texture
                ))
            } catch let error as SpiceMetalCompositorError {
                return .failure(error)
            } catch {
                return .failure(.pipelineCreationFailed(String(describing: error)))
            }
        }
        return try result.get()
    }

    private func makeSourceTexture(
        pixelBuffer: CVPixelBuffer,
        pixelFormat: MTLPixelFormat,
        width: Int,
        height: Int,
        plane: Int
    ) throws(SpiceMetalCompositorError) -> (binding: CVMetalTexture, texture: any MTLTexture) {
        var binding: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            pixelFormat,
            width,
            height,
            plane,
            &binding
        )
        guard status == kCVReturnSuccess,
              let binding,
              let texture = CVMetalTextureGetTexture(binding)
        else {
            throw .sourceTextureMappingFailed(plane: plane, status: status)
        }
        return (binding, texture)
    }

    private func makeDestinationTexture(
        surface: IOSurfaceRef,
        width: Int,
        height: Int
    ) throws(SpiceMetalCompositorError) -> any MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let texture = device.makeTexture(
            descriptor: descriptor,
            iosurface: surface,
            plane: 0
        ) else {
            throw .destinationTextureMappingFailed
        }
        return texture
    }
}

private struct ShaderUniforms {
    var sourceAndFlags: SIMD4<UInt32>
    var sourceRect: SIMD4<UInt32>
    var destinationRect: SIMD4<UInt32>
    var clipRect: SIMD4<UInt32>
    var rangeParameters: SIMD4<Float>
    var redCoefficients: SIMD4<Float>
    var greenCoefficients: SIMD4<Float>
    var blueCoefficients: SIMD4<Float>

    static var hasExpectedMetalLayout: Bool {
        MemoryLayout<Self>.stride == 128
            && MemoryLayout<Self>.alignment == 16
            && MemoryLayout<Self>.offset(of: \.sourceAndFlags) == 0
            && MemoryLayout<Self>.offset(of: \.sourceRect) == 16
            && MemoryLayout<Self>.offset(of: \.destinationRect) == 32
            && MemoryLayout<Self>.offset(of: \.clipRect) == 48
            && MemoryLayout<Self>.offset(of: \.rangeParameters) == 64
            && MemoryLayout<Self>.offset(of: \.redCoefficients) == 80
            && MemoryLayout<Self>.offset(of: \.greenCoefficients) == 96
            && MemoryLayout<Self>.offset(of: \.blueCoefficients) == 112
    }
}

private struct ColorConversion {
    let rangeParameters: SIMD4<Float>
    let redCoefficients: SIMD4<Float>
    let greenCoefficients: SIMD4<Float>
    let blueCoefficients: SIMD4<Float>

    init(
        matrix: SpiceVideoColorMatrix,
        range: SpiceVideoColorRange
    ) throws(SpiceMetalCompositorError) {
        switch range {
        case .video:
            rangeParameters = SIMD4(
                16.0 / 255.0,
                255.0 / 219.0,
                128.0 / 255.0,
                255.0 / 224.0
            )
        case .full:
            rangeParameters = SIMD4(
                0,
                1,
                128.0 / 255.0,
                1
            )
        case .unknown:
            throw .unsupportedColorRange
        }

        switch matrix {
        case .bt601:
            redCoefficients = SIMD4(1, 0, 1.402, 0)
            greenCoefficients = SIMD4(1, -0.344_136, -0.714_136, 0)
            blueCoefficients = SIMD4(1, 1.772, 0, 0)
        case .bt709:
            redCoefficients = SIMD4(1, 0, 1.5748, 0)
            greenCoefficients = SIMD4(1, -0.187_324, -0.468_124, 0)
            blueCoefficients = SIMD4(1, 1.8556, 0, 0)
        case .unknown:
            throw .unsupportedColorMatrix
        }
    }
}

private struct SourceTextures: @unchecked Sendable {
    let lumaBinding: CVMetalTexture
    let lumaTexture: any MTLTexture
    let chromaBinding: CVMetalTexture
    let chromaTexture: any MTLTexture
}

private struct PackedSourceTexture: @unchecked Sendable {
    let binding: CVMetalTexture
    let texture: any MTLTexture
}

/// Core Video requires the CVPixelBuffer and CVMetalTexture wrappers to remain
/// alive while their MTLTexture views are in use by the command buffer.
private final class RetainedVideoResources: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let lumaBinding: CVMetalTexture
    let chromaBinding: CVMetalTexture
    let destinationSurface: IOSurfaceRef
    let destinationTexture: any MTLTexture

    init(
        pixelBuffer: CVPixelBuffer,
        lumaBinding: CVMetalTexture,
        chromaBinding: CVMetalTexture,
        destinationSurface: IOSurfaceRef,
        destinationTexture: any MTLTexture
    ) {
        self.pixelBuffer = pixelBuffer
        self.lumaBinding = lumaBinding
        self.chromaBinding = chromaBinding
        self.destinationSurface = destinationSurface
        self.destinationTexture = destinationTexture
    }
}

/// Packed stream frames use one CVMetalTexture view instead of the two-plane
/// NV12 binding, but retain the same command-buffer lifetime guarantees.
private final class RetainedPackedVideoResources: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let sourceBinding: CVMetalTexture
    let sourceTexture: any MTLTexture
    let destinationSurface: IOSurfaceRef
    let destinationTexture: any MTLTexture

    init(
        pixelBuffer: CVPixelBuffer,
        sourceBinding: CVMetalTexture,
        sourceTexture: any MTLTexture,
        destinationSurface: IOSurfaceRef,
        destinationTexture: any MTLTexture
    ) {
        self.pixelBuffer = pixelBuffer
        self.sourceBinding = sourceBinding
        self.sourceTexture = sourceTexture
        self.destinationSurface = destinationSurface
        self.destinationTexture = destinationTexture
    }
}

private extension SpiceMetalVideoRectangle {
    var isValid: Bool {
        guard x >= 0, y >= 0, width > 0, height > 0 else {
            return false
        }
        let (_, xOverflow) = x.addingReportingOverflow(width)
        let (_, yOverflow) = y.addingReportingOverflow(height)
        return !xOverflow && !yOverflow
    }

    var unsignedComponents: SIMD4<UInt32> {
        SIMD4(UInt32(x), UInt32(y), UInt32(width), UInt32(height))
    }

    var fitsShaderCoordinates: Bool {
        UInt32(exactly: x) != nil
            && UInt32(exactly: y) != nil
            && UInt32(exactly: width) != nil
            && UInt32(exactly: height) != nil
    }

    func intersection(_ other: Self) -> Self? {
        guard width > 0, height > 0, other.width > 0, other.height > 0,
              x >= 0, y >= 0, other.x >= 0, other.y >= 0
        else {
            return nil
        }
        let (ownMaxX, ownXOverflow) = x.addingReportingOverflow(width)
        let (ownMaxY, ownYOverflow) = y.addingReportingOverflow(height)
        let (otherMaxX, otherXOverflow) = other.x.addingReportingOverflow(other.width)
        let (otherMaxY, otherYOverflow) = other.y.addingReportingOverflow(other.height)
        guard !ownXOverflow, !ownYOverflow, !otherXOverflow, !otherYOverflow else {
            return nil
        }
        let resultX = max(x, other.x)
        let resultY = max(y, other.y)
        let resultMaxX = min(ownMaxX, otherMaxX)
        let resultMaxY = min(ownMaxY, otherMaxY)
        guard resultX < resultMaxX, resultY < resultMaxY else {
            return nil
        }
        return Self(
            x: resultX,
            y: resultY,
            width: resultMaxX - resultX,
            height: resultMaxY - resultY
        )
    }
}
