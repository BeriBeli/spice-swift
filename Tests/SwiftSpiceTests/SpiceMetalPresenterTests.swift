import Foundation
import Metal
import SpiceIOSurface
import SpiceRenderer
import Testing
@testable import SwiftSpice

@Suite("Metal IOSurface presenter")
@MainActor
struct SpiceMetalPresenterTests {
    @Test func mapsAndPresentsIOSurfaceWithoutChangingPixels() async throws {
        let store = makeIOSurfaceStore()
        try await store.create(id: 12, width: 2, height: 1, format: 32)
        try await store.fill(
            surfaceID: 12,
            rectangle: PixelRect(x: 0, y: 0, width: 2, height: 1),
            colorARGB: 0x0011_2233
        )
        let frame = SpiceFrame(try await store.snapshot(surfaceID: 12))
        let presenter = try #require(SpiceMetalPresenter())
        let source = try #require(presenter.makeTexture(for: frame))
        #expect(source.width == 2)
        #expect(source.height == 1)
        #expect(source.pixelFormat == .bgra8Unorm)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 2,
            height: 1,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        let destination = try #require(presenter.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(presenter.makePresentationCommand(
            source: source,
            destination: destination,
            retaining: frame
        ))
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
            commandBuffer.commit()
        }
        #expect(commandBuffer.status == .completed)
        #expect(commandBuffer.error == nil)

        var pixels = Data(count: 8)
        pixels.withUnsafeMutableBytes { bytes in
            destination.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 8,
                from: MTLRegionMake2D(0, 0, 2, 1),
                mipmapLevel: 0
            )
        }
        #expect(pixels == Data([
            0x33, 0x22, 0x11, 0xff,
            0x33, 0x22, 0x11, 0xff,
        ]))
    }

    @Test func rejectsCPUOnlyFrame() throws {
        let presenter = try #require(SpiceMetalPresenter())
        let frame = SpiceFrame(
            surfaceID: 1,
            width: 1,
            height: 1,
            bytesPerRow: 4,
            pixels: Data([1, 2, 3, 255])
        )
        #expect(presenter.makeTexture(for: frame) == nil)
        guard case .cpuFallback(.missingIOSurface) = presenter.makeTextureResult(for: frame) else {
            Issue.record("Expected the missing IOSurface fallback reason")
            return
        }
    }

    @Test func recordsContentFreeFallbackReasons() {
        let diagnostics = SpicePresentationDiagnostics()

        diagnostics.recordMetalPresentedFrame()
        diagnostics.recordCPUFallback(.missingIOSurface)
        diagnostics.recordCPUFallback(.pixelFormatMismatch)
        diagnostics.recordCPUFallback(.metalCommandFailure)
        diagnostics.recordMetalPresentationError()
        diagnostics.recordMetalFramesSupersededBeforeDraw(2)
        diagnostics.recordMetalDrawableMiss()
        diagnostics.recordMetalCommandCreationFailure()
        diagnostics.recordMetalCommandBufferCommitted()
        diagnostics.recordMetalTextureCacheHit()
        diagnostics.recordMetalTextureCacheMiss()
        diagnostics.recordMetalTextureCacheEviction()
        diagnostics.recordMetalGPUBusySkip()
        diagnostics.recordDesktopDisplayLinkWakeup()
        diagnostics.recordDesktopDisplayLinkTick()
        diagnostics.recordDesktopDisplayLinkIdlePause()
        diagnostics.recordViewUpdateToMetalCommit(.milliseconds(3))
        diagnostics.recordMetalCommitToCompletion(.milliseconds(4))
        diagnostics.recordMetalRequestToPresented(.milliseconds(5))

        let metrics = diagnostics.snapshot()
        #expect(metrics.metalPresentedFrames == 1)
        #expect(metrics.metalPresentationErrors == 1)
        #expect(metrics.cpuFallbackFrames == 3)
        #expect(metrics.missingIOSurfaceFallbackFrames == 1)
        #expect(metrics.pixelFormatMismatchFallbackFrames == 1)
        #expect(metrics.metalCommandFailureFallbackFrames == 1)
        #expect(metrics.lastCPUFallbackReason == .metalCommandFailure)
        #expect(metrics.metalFramesSupersededBeforeDraw == 2)
        #expect(metrics.metalDrawableMisses == 1)
        #expect(metrics.metalCommandCreationFailures == 1)
        #expect(metrics.metalCommandBuffersCommitted == 1)
        #expect(metrics.metalTextureCacheHits == 1)
        #expect(metrics.metalTextureCacheMisses == 1)
        #expect(metrics.metalTextureCacheEvictions == 1)
        #expect(metrics.metalGPUBusySkips == 1)
        #expect(metrics.desktopDisplayLinkWakeups == 1)
        #expect(metrics.desktopDisplayLinkTicks == 1)
        #expect(metrics.desktopDisplayLinkIdlePauses == 1)
        #expect(metrics.viewUpdateToMetalCommit.p95Milliseconds == 3)
        #expect(metrics.metalCommitToCompletion.p95Milliseconds == 4)
        #expect(metrics.metalRequestToPresented.p95Milliseconds == 5)

        diagnostics.reset()
        #expect(diagnostics.snapshot() == .empty)
    }

    @Test func scalesIOSurfaceIntoBackingSizedTexture() async throws {
        let store = makeIOSurfaceStore()
        try await store.create(id: 13, width: 2, height: 1, format: 32)
        try await store.fill(
            surfaceID: 13,
            rectangle: PixelRect(x: 0, y: 0, width: 2, height: 1),
            colorARGB: 0x0011_2233
        )
        let frame = SpiceFrame(try await store.snapshot(surfaceID: 13))
        let presenter = try #require(SpiceMetalPresenter())
        let source = try #require(presenter.makeTexture(for: frame))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 4,
            height: 2,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        let destination = try #require(presenter.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(presenter.makePresentationCommand(
            source: source,
            destination: destination,
            retaining: frame
        ))
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in
                continuation.resume()
            }
            commandBuffer.commit()
        }

        #expect(commandBuffer.status == .completed)
        #expect(commandBuffer.error == nil)
        #expect(presenter.metrics().commandErrors == 0)

        var pixels = Data(count: 32)
        pixels.withUnsafeMutableBytes { bytes in
            destination.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 16,
                from: MTLRegionMake2D(0, 0, 4, 2),
                mipmapLevel: 0
            )
        }
        let expectedPixel: [UInt8] = [0x33, 0x22, 0x11, 0xff]
        let expectedPixels = Data((0..<8).flatMap { _ in expectedPixel })
        #expect(pixels == expectedPixels)
    }

    @Test func reusesAtMostThreeIOSurfaceTextureWrappers() async throws {
        let store = makeIOSurfaceStore(maximumFrames: 4)
        try await store.create(id: 14, width: 2, height: 2, format: 32)
        let frame = SpiceFrame(try await store.snapshot(surfaceID: 14))
        var retainedFrames = [frame]
        let presenter = try #require(SpiceMetalPresenter())

        let first = try #require(presenter.makeTexture(for: frame))
        let second = try #require(presenter.makeTexture(for: frame))

        #expect(first === second)
        for surfaceID: UInt32 in 16...18 {
            try await store.create(id: surfaceID, width: 2, height: 2, format: 32)
            let additionalFrame = SpiceFrame(
                try await store.snapshot(surfaceID: surfaceID)
            )
            retainedFrames.append(additionalFrame)
            _ = try #require(presenter.makeTexture(for: additionalFrame))
        }
        #expect(retainedFrames.count == 4)
        let metrics = presenter.metrics()
        #expect(metrics.textureCacheMisses == 4)
        #expect(metrics.textureCacheHits == 1)
        #expect(metrics.textureCacheEvictions == 1)
        #expect(metrics.textureCacheEntries == SpiceMetalPresenter.maximumTextureCacheEntries)
    }

    @Test func limitsGPUCommandsToTwoWithoutBlocking() async throws {
        let store = makeIOSurfaceStore()
        try await store.create(id: 15, width: 1, height: 1, format: 32)
        let frame = SpiceFrame(try await store.snapshot(surfaceID: 15))
        let presenter = try #require(SpiceMetalPresenter())
        let source = try #require(presenter.makeTexture(for: frame))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.renderTarget]
        let destination = try #require(presenter.device.makeTexture(descriptor: descriptor))
        let first = try #require(presenter.makePresentationCommand(
            source: source,
            destination: destination,
            retaining: frame
        ))
        let second = try #require(presenter.makePresentationCommand(
            source: source,
            destination: destination,
            retaining: frame
        ))

        #expect(presenter.makePresentationCommand(
            source: source,
            destination: destination,
            retaining: frame
        ) == nil)
        #expect(presenter.metrics().inFlightCommands == 2)
        #expect(presenter.metrics().maximumInFlightCommands == 2)
        #expect(presenter.metrics().gpuBusySkips == 1)

        await withCheckedContinuation { continuation in
            first.addCompletedHandler { _ in continuation.resume() }
            first.commit()
        }
        await withCheckedContinuation { continuation in
            second.addCompletedHandler { _ in continuation.resume() }
            second.commit()
        }
        #expect(presenter.metrics().inFlightCommands == 0)
    }

    @Test func usesNearestOnlyForOneToOneAndIntegerMagnification() {
        #expect(SpiceMetalPresenter.samplingFilter(
            sourceWidth: 640,
            sourceHeight: 480,
            destinationWidth: 640,
            destinationHeight: 480
        ) == .nearest)
        #expect(SpiceMetalPresenter.samplingFilter(
            sourceWidth: 640,
            sourceHeight: 480,
            destinationWidth: 1_280,
            destinationHeight: 960
        ) == .nearest)
        #expect(SpiceMetalPresenter.samplingFilter(
            sourceWidth: 640,
            sourceHeight: 480,
            destinationWidth: 1_024,
            destinationHeight: 768
        ) == .linear)
    }

    @Test func integerMagnificationKeepsPixelEdgesSharp() async throws {
        let presenter = try #require(SpiceMetalPresenter())
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 2,
            height: 1,
            mipmapped: false
        )
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = [.shaderRead]
        let source = try #require(presenter.device.makeTexture(descriptor: sourceDescriptor))
        let sourcePixels: [UInt8] = [
            0, 0, 0, 255,
            255, 255, 255, 255,
        ]
        sourcePixels.withUnsafeBytes { bytes in
            source.replace(
                region: MTLRegionMake2D(0, 0, 2, 1),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: 8
            )
        }
        let destinationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 4,
            height: 1,
            mipmapped: false
        )
        destinationDescriptor.storageMode = .shared
        destinationDescriptor.usage = [.renderTarget]
        let destination = try #require(
            presenter.device.makeTexture(descriptor: destinationDescriptor)
        )
        let frame = SpiceFrame(
            surfaceID: 0,
            width: 2,
            height: 1,
            bytesPerRow: 8,
            pixels: Data(sourcePixels)
        )
        let commandBuffer = try #require(presenter.makePresentationCommand(
            source: source,
            destination: destination,
            retaining: frame
        ))
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }

        var result = Data(count: 16)
        result.withUnsafeMutableBytes { bytes in
            destination.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 16,
                from: MTLRegionMake2D(0, 0, 4, 1),
                mipmapLevel: 0
            )
        }
        #expect(result == Data([
            0, 0, 0, 255,
            0, 0, 0, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
        ]))
    }

    @Test func nonIntegerScaleUsesLinearSampling() async throws {
        let presenter = try #require(SpiceMetalPresenter())
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 2,
            height: 1,
            mipmapped: false
        )
        sourceDescriptor.storageMode = .shared
        sourceDescriptor.usage = [.shaderRead]
        let source = try #require(presenter.device.makeTexture(descriptor: sourceDescriptor))
        let sourcePixels: [UInt8] = [
            0, 0, 0, 255,
            255, 255, 255, 255,
        ]
        sourcePixels.withUnsafeBytes { bytes in
            source.replace(
                region: MTLRegionMake2D(0, 0, 2, 1),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: 8
            )
        }
        let destinationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 3,
            height: 1,
            mipmapped: false
        )
        destinationDescriptor.storageMode = .shared
        destinationDescriptor.usage = [.renderTarget]
        let destination = try #require(
            presenter.device.makeTexture(descriptor: destinationDescriptor)
        )
        let frame = SpiceFrame(
            surfaceID: 0,
            width: 2,
            height: 1,
            bytesPerRow: 8,
            pixels: Data(sourcePixels)
        )
        let commandBuffer = try #require(presenter.makePresentationCommand(
            source: source,
            destination: destination,
            retaining: frame
        ))
        await withCheckedContinuation { continuation in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }

        var result = Data(count: 12)
        result.withUnsafeMutableBytes { bytes in
            destination.getBytes(
                bytes.baseAddress!,
                bytesPerRow: 12,
                from: MTLRegionMake2D(0, 0, 3, 1),
                mipmapLevel: 0
            )
        }
        let middle = Array(result[4..<8])
        #expect((127...128).contains(Int(middle[0])))
        #expect((127...128).contains(Int(middle[1])))
        #expect((127...128).contains(Int(middle[2])))
        #expect(middle[3] == 255)
    }

    @Test func metalViewIsConfiguredForExplicitDrawableRequests() throws {
        let view = try #require(SpiceMetalFrameView())
        #expect(view.isPaused)
        #expect(!view.enableSetNeedsDisplay)
        #expect(view.framebufferOnly)
        #expect(!view.presentsWithTransaction)
        #expect(!view.autoResizeDrawable)
    }
}

private func makeIOSurfaceStore(maximumFrames: Int = 3) -> SurfaceStore {
    SurfaceStore(
        framePool: IOSurfaceFramePool(limits: .init(maximumFrames: maximumFrames)),
        backingPolicy: .dataOnly
    )
}
