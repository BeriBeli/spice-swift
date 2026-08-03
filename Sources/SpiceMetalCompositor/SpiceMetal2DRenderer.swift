import CoreVideo
import Foundation
import IOSurface
import Metal
import SpiceIOSurface
import Synchronization

package struct SpiceMetal2DRectangle: Sendable, Equatable {
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

package struct SpiceMetal2DMetrics: Sendable, Equatable {
    package let commandBuffers: UInt64
    package let commands: UInt64
    package let uploadedBytes: UInt64
    package let blitBytes: UInt64
    package let gpuNanoseconds: UInt64
    package let errors: UInt64
    package let fillCommands: UInt64
    package let bitmapCopyCommands: UInt64
    package let copyBitsCommands: UInt64
    package let surfaceCopyCommands: UInt64
    package let uploadBufferAllocations: UInt64
    package let uploadBufferReuses: UInt64
}

/// Encodes ordinary SPICE 2D operations into one transactional command buffer.
/// The caller owns the IOSurface candidate and decides whether a successfully
/// completed batch becomes the next published Surface revision.
package final class SpiceMetal2DRenderer: @unchecked Sendable {
    fileprivate struct MetricsState {
        var commandBuffers: UInt64 = 0
        var commands: UInt64 = 0
        var uploadedBytes: UInt64 = 0
        var blitBytes: UInt64 = 0
        var gpuNanoseconds: UInt64 = 0
        var errors: UInt64 = 0
        var fillCommands: UInt64 = 0
        var bitmapCopyCommands: UInt64 = 0
        var copyBitsCommands: UInt64 = 0
        var surfaceCopyCommands: UInt64 = 0
        var uploadBufferAllocations: UInt64 = 0
        var uploadBufferReuses: UInt64 = 0
    }

    package let device: any MTLDevice
    private let commandQueue: any MTLCommandQueue
    fileprivate let fillPipeline: any MTLComputePipelineState
    fileprivate let bitmapPipeline: any MTLComputePipelineState
    fileprivate let surfaceCopyPipeline: any MTLComputePipelineState
    fileprivate let uploadBufferPool: SpiceMetalUploadBufferPool
    fileprivate let metricsState = Mutex(MetricsState())

    package init(
        device: (any MTLDevice)? = SpiceMetalSystemDevice.shared.device,
        libraryURL: URL? = nil
    ) throws(SpiceMetalCompositorError) {
        guard let device, SpiceMetalCompositor.supportsUnifiedVideoPath(device: device) else {
            throw .unsupportedDevice
        }
        guard let commandQueue = device.makeCommandQueue() else {
            throw .commandQueueUnavailable
        }
        let resolvedURL = libraryURL ?? SpiceMetalCompositor.bundledShaderLibraryURL()
        guard let resolvedURL else {
            throw .shaderLibraryUnavailable(
                "SpiceVideoCompositor.metallib is missing from the resource bundle"
            )
        }
        let library: any MTLLibrary
        do {
            library = try device.makeLibrary(URL: resolvedURL)
        } catch {
            throw .shaderLibraryUnavailable(String(describing: error))
        }
        guard let fillFunction = library.makeFunction(name: "spice_fill_rect"),
              let bitmapFunction = library.makeFunction(name: "spice_bitmap_copy"),
              let surfaceCopyFunction = library.makeFunction(name: "spice_surface_copy")
        else {
            throw .shaderLibraryUnavailable("SPICE 2D shader entry points are missing")
        }
        do {
            fillPipeline = try device.makeComputePipelineState(function: fillFunction)
            bitmapPipeline = try device.makeComputePipelineState(function: bitmapFunction)
            surfaceCopyPipeline = try device.makeComputePipelineState(
                function: surfaceCopyFunction
            )
        } catch {
            throw .pipelineCreationFailed(String(describing: error))
        }
        self.device = device
        self.commandQueue = commandQueue
        uploadBufferPool = SpiceMetalUploadBufferPool(device: device)
    }

    package func makeBatch(
        destination: IOSurfaceRef
    ) throws(SpiceMetalCompositorError) -> SpiceMetal2DBatch {
        let width = IOSurfaceGetWidth(destination)
        let height = IOSurfaceGetHeight(destination)
        guard width > 0, height > 0,
              IOSurfaceGetPixelFormat(destination) == kCVPixelFormatType_32BGRA,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            throw .commandBufferUnavailable
        }
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
            iosurface: destination,
            plane: 0
        ) else {
            throw .destinationTextureMappingFailed
        }
        return SpiceMetal2DBatch(
            renderer: self,
            destinationSurface: destination,
            destinationTexture: texture,
            commandBuffer: commandBuffer
        )
    }

    package func metrics() -> SpiceMetal2DMetrics {
        metricsState.withLock {
            SpiceMetal2DMetrics(
                commandBuffers: $0.commandBuffers,
                commands: $0.commands,
                uploadedBytes: $0.uploadedBytes,
                blitBytes: $0.blitBytes,
                gpuNanoseconds: $0.gpuNanoseconds,
                errors: $0.errors,
                fillCommands: $0.fillCommands,
                bitmapCopyCommands: $0.bitmapCopyCommands,
                copyBitsCommands: $0.copyBitsCommands,
                surfaceCopyCommands: $0.surfaceCopyCommands,
                uploadBufferAllocations: $0.uploadBufferAllocations,
                uploadBufferReuses: $0.uploadBufferReuses
            )
        }
    }
}

package final class SpiceMetal2DBatch: @unchecked Sendable {
    private struct FillUniforms {
        var rectangle: SIMD4<UInt32>
        var colorRGBA: SIMD4<Float>
    }

    private struct BitmapUniforms {
        var sourceGeometry: SIMD4<UInt32>
        var sourceRectangle: SIMD4<UInt32>
        var destinationRectangle: SIMD4<UInt32>
        var flags: SIMD4<UInt32>
    }

    private struct SurfaceCopyUniforms {
        var sourceRectangle: SIMD4<UInt32>
        var destinationRectangle: SIMD4<UInt32>
        var flags: SIMD4<UInt32>
    }

    private let renderer: SpiceMetal2DRenderer
    private let destinationSurface: IOSurfaceRef
    private let destinationTexture: any MTLTexture
    private let commandBuffer: any MTLCommandBuffer
    private var computeEncoder: (any MTLComputeCommandEncoder)?
    private var retainedResources: [AnyObject] = []
    private var finalized = false
    private(set) package var commandCount = 0
    private(set) package var uploadedBytes = 0
    private(set) package var blitBytes = 0
    private var fillCommandCount = 0
    private var bitmapCopyCommandCount = 0
    private var copyBitsCommandCount = 0
    private var surfaceCopyCommandCount = 0

    fileprivate init(
        renderer: SpiceMetal2DRenderer,
        destinationSurface: IOSurfaceRef,
        destinationTexture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) {
        self.renderer = renderer
        self.destinationSurface = destinationSurface
        self.destinationTexture = destinationTexture
        self.commandBuffer = commandBuffer
    }

    deinit {
        // Metal requires every encoder to be ended before it is released. A
        // batch may be discarded when its surface is destroyed, the store is
        // closed, or an encode/transaction validation fails, so keep this as
        // a last-resort invariant in addition to the explicit cancel paths.
        cancel()
    }

    package func encodeFill(
        rectangle: SpiceMetal2DRectangle,
        colorRGBA: SIMD4<Float>
    ) throws(SpiceMetalCompositorError) {
        guard rectangle.isValid(width: destinationTexture.width, height: destinationTexture.height)
        else {
            throw .invalidDestination("fill rectangle is outside the IOSurface")
        }
        let encoder = try activeComputeEncoder()
        encoder.setComputePipelineState(renderer.fillPipeline)
        encoder.setTexture(destinationTexture, index: 0)
        var uniforms = FillUniforms(
            rectangle: rectangle.unsignedComponents,
            colorRGBA: colorRGBA
        )
        encoder.setBytes(&uniforms, length: MemoryLayout<FillUniforms>.stride, index: 0)
        dispatch(
            encoder: encoder,
            pipeline: renderer.fillPipeline,
            width: rectangle.width,
            height: rectangle.height
        )
        commandCount += 1
        fillCommandCount += 1
    }

    package func encodeBitmapCopy(
        pixels: Data,
        bitmapWidth: Int,
        bitmapHeight: Int,
        sourceStride: Int,
        topDown: Bool,
        source: SpiceMetal2DRectangle,
        destination: SpiceMetal2DRectangle,
        preservesAlpha: Bool
    ) throws(SpiceMetalCompositorError) {
        guard bitmapWidth > 0, bitmapHeight > 0,
              sourceStride >= bitmapWidth * 4,
              pixels.count == sourceStride * bitmapHeight,
              source.isValid(width: bitmapWidth, height: bitmapHeight),
              destination.isValid(
                  width: destinationTexture.width,
                  height: destinationTexture.height
              )
        else {
            throw .invalidSourceRectangle
        }
        guard let upload = renderer.uploadBufferPool.checkout(pixels: pixels) else {
            throw .commandBufferUnavailable
        }
        renderer.metricsState.withLock {
            if upload.allocated {
                $0.uploadBufferAllocations &+= 1
            } else {
                $0.uploadBufferReuses &+= 1
            }
        }
        retainedResources.append(upload.lease)
        let encoder = try activeComputeEncoder()
        encoder.setComputePipelineState(renderer.bitmapPipeline)
        encoder.setBuffer(upload.lease.buffer, offset: 0, index: 0)
        encoder.setTexture(destinationTexture, index: 0)
        var uniforms = BitmapUniforms(
            sourceGeometry: SIMD4(
                UInt32(bitmapWidth), UInt32(bitmapHeight), UInt32(sourceStride), 0
            ),
            sourceRectangle: source.unsignedComponents,
            destinationRectangle: destination.unsignedComponents,
            flags: SIMD4(topDown ? 1 : 0, preservesAlpha ? 1 : 0, 0, 0)
        )
        encoder.setBytes(&uniforms, length: MemoryLayout<BitmapUniforms>.stride, index: 1)
        dispatch(
            encoder: encoder,
            pipeline: renderer.bitmapPipeline,
            width: destination.width,
            height: destination.height
        )
        commandCount += 1
        bitmapCopyCommandCount += 1
        uploadedBytes += pixels.count
    }

    /// Always routes through a private scratch texture so overlapping source
    /// and destination rectangles have memmove semantics.
    package func encodeCopyBits(
        source: SpiceMetal2DRectangle,
        destination: SpiceMetal2DRectangle
    ) throws(SpiceMetalCompositorError) {
        guard source.width == destination.width, source.height == destination.height,
              source.isValid(width: destinationTexture.width, height: destinationTexture.height),
              destination.isValid(
                  width: destinationTexture.width,
                  height: destinationTexture.height
              )
        else {
            throw .invalidSourceRectangle
        }
        endComputeEncoding()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let scratch = renderer.device.makeTexture(descriptor: descriptor),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            throw .commandEncoderUnavailable
        }
        retainedResources.append(scratch as AnyObject)
        let size = MTLSize(width: source.width, height: source.height, depth: 1)
        blit.copy(
            from: destinationTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: source.x, y: source.y, z: 0),
            sourceSize: size,
            to: scratch,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blit.copy(
            from: scratch,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: size,
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: destination.x, y: destination.y, z: 0)
        )
        blit.endEncoding()
        commandCount += 1
        copyBitsCommandCount += 1
        blitBytes += source.width * source.height * 8
    }

    package func encodeSurfaceCopy(
        sourceFrame: IOSurfaceFrame,
        source: SpiceMetal2DRectangle,
        destination: SpiceMetal2DRectangle,
        preservesAlpha: Bool
    ) throws(SpiceMetalCompositorError) {
        guard source.width == destination.width, source.height == destination.height,
              source.isValid(width: sourceFrame.width, height: sourceFrame.height),
              destination.isValid(
                  width: destinationTexture.width,
                  height: destinationTexture.height
              )
        else {
            throw .invalidSourceRectangle
        }
        let sourceTexture: any MTLTexture
        do {
            sourceTexture = try sourceFrame.withIOSurface { surface in
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm,
                    width: sourceFrame.width,
                    height: sourceFrame.height,
                    mipmapped: false
                )
                descriptor.storageMode = .shared
                descriptor.usage = [.shaderRead]
                guard let texture = renderer.device.makeTexture(
                    descriptor: descriptor,
                    iosurface: surface,
                    plane: 0
                ) else {
                    throw SpiceMetalCompositorError.sourceTextureMappingFailed(
                        plane: 0,
                        status: kCVReturnError
                    )
                }
                return texture
            }
        } catch let error as SpiceMetalCompositorError {
            throw error
        } catch {
            throw .sourceTextureMappingFailed(plane: 0, status: kCVReturnError)
        }
        retainedResources.append(sourceFrame)
        retainedResources.append(sourceTexture as AnyObject)
        let encoder = try activeComputeEncoder()
        encoder.setComputePipelineState(renderer.surfaceCopyPipeline)
        encoder.setTexture(sourceTexture, index: 0)
        encoder.setTexture(destinationTexture, index: 1)
        var uniforms = SurfaceCopyUniforms(
            sourceRectangle: source.unsignedComponents,
            destinationRectangle: destination.unsignedComponents,
            flags: SIMD4(preservesAlpha ? 1 : 0, 0, 0, 0)
        )
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<SurfaceCopyUniforms>.stride,
            index: 0
        )
        dispatch(
            encoder: encoder,
            pipeline: renderer.surfaceCopyPipeline,
            width: destination.width,
            height: destination.height
        )
        commandCount += 1
        surfaceCopyCommandCount += 1
    }

    package func commit() async throws(SpiceMetalCompositorError) {
        guard !finalized else {
            throw .commandExecutionFailed("2D batch was already finalized")
        }
        finalized = true
        endComputeEncoding()
        let retained = RetainedBatchResources(
            destinationSurface: destinationSurface,
            destinationTexture: destinationTexture,
            resources: retainedResources
        )
        let result: Result<(UInt64, UInt64), SpiceMetalCompositorError> = await
            withCheckedContinuation { continuation in
                commandBuffer.addCompletedHandler { completed in
                    defer { withExtendedLifetime(retained) {} }
                    guard completed.status == .completed else {
                        let reason = completed.error.map(String.init(describing:))
                            ?? "command status \(completed.status.rawValue)"
                        continuation.resume(
                            returning: .failure(.commandExecutionFailed(reason))
                        )
                        return
                    }
                    let gpuSeconds = max(0, completed.gpuEndTime - completed.gpuStartTime)
                    continuation.resume(returning: .success((
                        UInt64(gpuSeconds * 1_000_000_000),
                        UInt64(self.commandCount)
                    )))
                }
                commandBuffer.commit()
            }
        do {
            let (gpuNanoseconds, commands) = try result.get()
            renderer.metricsState.withLock {
                $0.commandBuffers &+= 1
                $0.commands &+= commands
                $0.uploadedBytes &+= UInt64(uploadedBytes)
                $0.blitBytes &+= UInt64(blitBytes)
                $0.gpuNanoseconds &+= gpuNanoseconds
                $0.fillCommands &+= UInt64(fillCommandCount)
                $0.bitmapCopyCommands &+= UInt64(bitmapCopyCommandCount)
                $0.copyBitsCommands &+= UInt64(copyBitsCommandCount)
                $0.surfaceCopyCommands &+= UInt64(surfaceCopyCommandCount)
            }
        } catch {
            renderer.metricsState.withLock {
                $0.commandBuffers &+= 1
                $0.errors &+= 1
            }
            throw error
        }
    }

    /// Ends any recording encoder without submitting the command buffer.
    /// Safe to call repeatedly and after a successful or failed commit.
    package func cancel() {
        guard !finalized else { return }
        finalized = true
        endComputeEncoding()
        retainedResources.removeAll(keepingCapacity: false)
    }

    private func activeComputeEncoder() throws(SpiceMetalCompositorError)
        -> any MTLComputeCommandEncoder
    {
        if let computeEncoder {
            return computeEncoder
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw .commandEncoderUnavailable
        }
        computeEncoder = encoder
        return encoder
    }

    private func endComputeEncoding() {
        computeEncoder?.endEncoding()
        computeEncoder = nil
    }

    private func dispatch(
        encoder: any MTLComputeCommandEncoder,
        pipeline: any MTLComputePipelineState,
        width: Int,
        height: Int
    ) {
        let threadWidth = pipeline.threadExecutionWidth
        let threadHeight = max(1, pipeline.maxTotalThreadsPerThreadgroup / threadWidth)
        encoder.dispatchThreads(
            MTLSize(width: width, height: height, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: threadWidth,
                height: threadHeight,
                depth: 1
            )
        )
    }
}

fileprivate final class SpiceMetalUploadBufferPool: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var available: [Int: [any MTLBuffer]] = [:]
    }

    private let device: any MTLDevice
    private let state = Mutex(State())

    init(device: any MTLDevice) {
        self.device = device
    }

    func checkout(pixels: Data) -> (lease: SpiceMetalUploadBufferLease, allocated: Bool)? {
        guard let capacity = Self.capacity(for: pixels.count) else { return nil }
        let reused = state.withLock { state in
            state.available[capacity]?.popLast()
        }
        let buffer: any MTLBuffer
        let allocated: Bool
        if let reused {
            buffer = reused
            allocated = false
        } else {
            guard let created = device.makeBuffer(
                length: capacity,
                options: .storageModeShared
            ) else {
                return nil
            }
            buffer = created
            allocated = true
        }
        pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            buffer.contents().copyMemory(from: baseAddress, byteCount: bytes.count)
        }
        return (
            SpiceMetalUploadBufferLease(
                buffer: buffer,
                capacity: capacity,
                pool: self
            ),
            allocated
        )
    }

    fileprivate func recycle(buffer: any MTLBuffer, capacity: Int) {
        state.withLock {
            $0.available[capacity, default: []].append(buffer)
        }
    }

    private static func capacity(for byteCount: Int) -> Int? {
        guard byteCount > 0 else { return nil }
        var capacity = 4_096
        while capacity < byteCount {
            let (doubled, overflow) = capacity.multipliedReportingOverflow(by: 2)
            guard !overflow else { return nil }
            capacity = doubled
        }
        return capacity
    }
}

fileprivate final class SpiceMetalUploadBufferLease: @unchecked Sendable {
    let buffer: any MTLBuffer
    private let capacity: Int
    private let pool: SpiceMetalUploadBufferPool

    init(
        buffer: any MTLBuffer,
        capacity: Int,
        pool: SpiceMetalUploadBufferPool
    ) {
        self.buffer = buffer
        self.capacity = capacity
        self.pool = pool
    }

    deinit {
        pool.recycle(buffer: buffer, capacity: capacity)
    }
}

private final class RetainedBatchResources: @unchecked Sendable {
    let destinationSurface: IOSurfaceRef
    let destinationTexture: any MTLTexture
    let resources: [AnyObject]

    init(
        destinationSurface: IOSurfaceRef,
        destinationTexture: any MTLTexture,
        resources: [AnyObject]
    ) {
        self.destinationSurface = destinationSurface
        self.destinationTexture = destinationTexture
        self.resources = resources
    }
}

private extension SpiceMetal2DRectangle {
    var unsignedComponents: SIMD4<UInt32> {
        SIMD4(UInt32(x), UInt32(y), UInt32(width), UInt32(height))
    }

    func isValid(width surfaceWidth: Int, height surfaceHeight: Int) -> Bool {
        guard x >= 0, y >= 0, width > 0, height > 0 else { return false }
        let (right, rightOverflow) = x.addingReportingOverflow(width)
        let (bottom, bottomOverflow) = y.addingReportingOverflow(height)
        return !rightOverflow && !bottomOverflow
            && right <= surfaceWidth && bottom <= surfaceHeight
    }
}
