import Foundation
import Metal
import SpiceRenderer
import Testing
@testable import SwiftSpice

@Suite("Metal IOSurface presenter")
@MainActor
struct SpiceMetalPresenterTests {
    @Test func mapsAndBlitsIOSurfaceWithoutChangingPixels() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
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
        descriptor.usage = [.shaderRead]
        let destination = try #require(presenter.device.makeTexture(descriptor: descriptor))
        let commandBuffer = try #require(presenter.makeCopyCommand(
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
        diagnostics.recordMetalPresentationError()
        diagnostics.recordMetalFramesSupersededBeforeDraw(2)
        diagnostics.recordMetalDrawableMiss()
        diagnostics.recordMetalCommandCreationFailure()
        diagnostics.recordViewUpdateToMetalCommit(.milliseconds(3))
        diagnostics.recordMetalCommitToCompletion(.milliseconds(4))

        let metrics = diagnostics.snapshot()
        #expect(metrics.metalPresentedFrames == 1)
        #expect(metrics.metalPresentationErrors == 1)
        #expect(metrics.cpuFallbackFrames == 2)
        #expect(metrics.missingIOSurfaceFallbackFrames == 1)
        #expect(metrics.pixelFormatMismatchFallbackFrames == 1)
        #expect(metrics.lastCPUFallbackReason == .pixelFormatMismatch)
        #expect(metrics.metalFramesSupersededBeforeDraw == 2)
        #expect(metrics.metalDrawableMisses == 1)
        #expect(metrics.metalCommandCreationFailures == 1)
        #expect(metrics.viewUpdateToMetalCommit.p95Milliseconds == 3)
        #expect(metrics.metalCommitToCompletion.p95Milliseconds == 4)

        diagnostics.reset()
        #expect(diagnostics.snapshot() == .empty)
    }

    @Test func scalesIOSurfaceIntoBackingSizedTexture() async throws {
        let store = SurfaceStore(backingPolicy: .dataOnly)
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
}
