import CoreVideo
import Foundation
import IOSurface
import SpiceCodecs
import Testing
@testable import SpiceMetalCompositor

@Suite("Native NV12 Metal compositor", .serialized)
struct SpiceMetalCompositorTests {
    @Test func locatesShaderInsideStandardMacOSResourceBundle() throws {
        let fixture = try makeResourceBundleFixture(
            named: "SwiftSpice_SpiceMetalCompositor.bundle"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let resolved = SpiceMetalCompositor.bundledShaderLibraryURL(
            searchRoots: [fixture.root]
        )

        #expect(resolved?.standardizedFileURL == fixture.library.standardizedFileURL)
        #expect(resolved?.deletingLastPathComponent().lastPathComponent == "Resources")
    }

    @Test func unifiedSwiftPMTestsMaySearchOnlyTheirXCTestSiblingDirectory() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "swiftspice-xctest-bundle-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: root) }
        let testBundleURL = root.appending(path: "SwiftSpicePackageTests.xctest")
        let contents = testBundleURL.appending(path: "Contents")
        try fileManager.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "org.swiftspice.tests.unified",
                "CFBundleName": "SwiftSpicePackageTests",
                "CFBundlePackageType": "BNDL",
                "CFBundleVersion": "1",
            ],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appending(path: "Info.plist"))
        let testBundle = try #require(Bundle(url: testBundleURL))

        let roots = SpiceMetalShaderLibraryLocator.mainBundleSearchRoots(testBundle)
        let normalizedRoots = roots.map {
            $0.standardizedFileURL.path().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        let normalizedRoot = root.standardizedFileURL.path()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let externalParent = root.deletingLastPathComponent().standardizedFileURL.path()
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        #expect(normalizedRoots.contains(normalizedRoot))
        #expect(!normalizedRoots.contains(externalParent))
    }

    @Test func distinguishesFrameFallbackFromGenerationDisable() {
        #expect(
            SpiceMetalCompositorError.sourceTextureMappingFailed(
                plane: 1,
                status: kCVReturnPixelBufferNotMetalCompatible
            ).fallback == .frame
        )
        #expect(
            SpiceMetalCompositorError.unsupportedColorMatrix.fallback == .frame
        )
        #expect(
            SpiceMetalCompositorError.commandExecutionFailed("fault").fallback
                == .streamGeneration
        )
        #expect(
            SpiceMetalCompositorError.pipelineCreationFailed("missing").fallback
                == .streamGeneration
        )
    }

    @Test func convertsBottomUpNV12IntoClippedCandidateSurface() async throws {
        guard let compositor = try makeCompositorIfSupported() else { return }
        let pixelBuffer = try makeNV12PixelBuffer(
            width: 4,
            height: 4,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            lumaRows: [16, 64, 128, 235]
        )
        let destination = try makeBGRAIOSurface(width: 6, height: 6, fill: 0x5a)

        try await compositor.composite(
            pixelBuffer: pixelBuffer,
            pixelFormat: .nv12,
            colorMatrix: .bt709,
            colorRange: .video,
            sourceRect: .init(x: 0, y: 1, width: 4, height: 2),
            orientation: .bottomUp,
            into: destination,
            destinationRect: .init(x: 1, y: 1, width: 4, height: 4),
            clip: .init(x: 2, y: 2, width: 2, height: 2)
        )

        let pixels = try copyPixels(from: destination, width: 6, height: 6)
        for y in 0..<6 {
            for x in 0..<6 {
                let offset = (y * 6 + x) * 4
                if (2..<4).contains(x), (2..<4).contains(y) {
                    let expected: UInt8 = y == 2 ? 130 : 56
                    #expect(abs(Int(pixels[offset]) - Int(expected)) <= 1)
                    #expect(abs(Int(pixels[offset + 1]) - Int(expected)) <= 1)
                    #expect(abs(Int(pixels[offset + 2]) - Int(expected)) <= 1)
                    #expect(pixels[offset + 3] == 255)
                } else {
                    #expect(pixels[offset] == 0x5a)
                    #expect(pixels[offset + 1] == 0x5a)
                    #expect(pixels[offset + 2] == 0x5a)
                    #expect(pixels[offset + 3] == 0x5a)
                }
            }
        }
    }

    @Test func appliesBT601FullRangeConversionWithinTolerance() async throws {
        guard let compositor = try makeCompositorIfSupported() else { return }
        let pixelBuffer = try makeNV12PixelBuffer(
            width: 2,
            height: 2,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            lumaRows: [100, 100],
            chromaU: 90,
            chromaV: 240
        )
        let destination = try makeBGRAIOSurface(width: 2, height: 2, fill: 0)

        try await compositor.composite(
            pixelBuffer: pixelBuffer,
            pixelFormat: .nv12,
            colorMatrix: .bt601,
            colorRange: .full,
            orientation: .topDown,
            into: destination,
            destinationRect: .init(x: 0, y: 0, width: 2, height: 2),
            clip: .init(x: 0, y: 0, width: 2, height: 2)
        )

        let pixels = try copyPixels(from: destination, width: 2, height: 2)
        let reference = referenceBGRA(
            y: 100,
            u: 90,
            v: 240,
            matrix: .bt601,
            range: .full
        )
        for pixel in 0..<4 {
            let offset = pixel * 4
            for component in 0..<3 {
                #expect(abs(Int(pixels[offset + component]) - Int(reference[component])) <= 2)
            }
            #expect(pixels[offset + 3] == 255)
        }
    }

    @Test func rejectsOddNV12AsPerFrameFallback() async throws {
        guard let compositor = try makeCompositorIfSupported() else { return }
        let pixelBuffer = try makeNV12PixelBuffer(
            width: 3,
            height: 3,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            lumaRows: [0, 0, 0],
            metalCompatible: false
        )
        let destination = try makeBGRAIOSurface(width: 3, height: 3, fill: 0)

        do {
            try await compositor.composite(
                pixelBuffer: pixelBuffer,
                pixelFormat: .nv12,
                colorMatrix: .bt709,
                colorRange: .full,
                orientation: .topDown,
                into: destination,
                destinationRect: .init(x: 0, y: 0, width: 3, height: 3),
                clip: .init(x: 0, y: 0, width: 3, height: 3)
            )
            Issue.record("odd NV12 geometry unexpectedly entered the GPU path")
        } catch let error {
            #expect(error == .unsupportedGeometry(width: 3, height: 3))
            #expect(error.fallback == .frame)
        }
    }

    @Test func copiesAndScalesPackedBGRAWithinClip() async throws {
        guard let compositor = try makeCompositorIfSupported() else { return }
        let sourcePixels = Data([
            1, 2, 3, 255, 4, 5, 6, 255,
            7, 8, 9, 255, 10, 11, 12, 255,
        ])
        let pixelBuffer = try makeBGRAPixelBuffer(
            width: 2,
            height: 2,
            pixels: sourcePixels
        )
        let destination = try makeBGRAIOSurface(width: 6, height: 6, fill: 0x5a)

        try await compositor.composite(
            pixelBuffer: pixelBuffer,
            pixelFormat: .bgra8,
            colorMatrix: .unknown(nil),
            colorRange: .full,
            orientation: .bottomUp,
            into: destination,
            destinationRect: .init(x: 1, y: 1, width: 4, height: 4),
            clip: .init(x: 2, y: 2, width: 2, height: 2)
        )

        let pixels = try copyPixels(from: destination, width: 6, height: 6)
        let expected: [Int: [UInt8]] = [
            (2 * 6 + 2) * 4: [7, 8, 9, 255],
            (2 * 6 + 3) * 4: [10, 11, 12, 255],
            (3 * 6 + 2) * 4: [1, 2, 3, 255],
            (3 * 6 + 3) * 4: [4, 5, 6, 255],
        ]
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            if let expectedPixel = expected[offset] {
                #expect(Array(pixels[offset..<(offset + 4)]) == expectedPixel)
            } else {
                #expect(Array(pixels[offset..<(offset + 4)]) == [0x5a, 0x5a, 0x5a, 0x5a])
            }
        }
    }

    private func makeCompositorIfSupported() throws -> SpiceMetalCompositor? {
        do {
            return try SpiceMetalCompositor()
        } catch let error where error == .unsupportedDevice {
            return nil
        }
    }

    private func makeResourceBundleFixture(
        named bundleName: String
    ) throws -> (root: URL, library: URL) {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(
            path: "swiftspice-metal-bundle-\(UUID().uuidString)"
        )
        let bundle = root.appending(path: bundleName)
        let contents = bundle.appending(path: "Contents")
        let resources = contents.appending(path: "Resources")
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "org.swiftspice.tests.metal-compositor",
                "CFBundleName": "SwiftSpiceMetalCompositorTests",
                "CFBundlePackageType": "BNDL",
                "CFBundleVersion": "1",
            ],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appending(path: "Info.plist"))
        let library = resources.appending(path: "SpiceVideoCompositor.metallib")
        try Data("fixture".utf8).write(to: library)
        return (root, library)
    }

    private func makeNV12PixelBuffer(
        width: Int,
        height: Int,
        pixelFormat: OSType,
        lumaRows: [UInt8],
        chromaU: UInt8 = 128,
        chromaV: UInt8 = 128,
        metalCompatible: Bool = true
    ) throws -> CVPixelBuffer {
        let attributes: [CFString: Any]? = metalCompatible ? [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] : nil
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary?,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)

        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
            .assumingMemoryBound(to: UInt8.self)
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
            .assumingMemoryBound(to: UInt8.self)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<height {
            for column in 0..<width {
                luma[row * lumaStride + column] = lumaRows[row]
            }
        }
        for row in 0..<((height + 1) / 2) {
            for column in 0..<((width + 1) / 2) {
                chroma[row * chromaStride + column * 2] = chromaU
                chroma[row * chromaStride + column * 2 + 1] = chromaV
            }
        }
        return buffer
    }

    private func makeBGRAPixelBuffer(
        width: Int,
        height: Int,
        pixels: Data
    ) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        #expect(status == kCVReturnSuccess)
        let buffer = try #require(pixelBuffer)
        #expect(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let destination = try #require(CVPixelBufferGetBaseAddress(buffer))
        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        let sourceStride = width * 4
        pixels.withUnsafeBytes { sourceBytes in
            guard let source = sourceBytes.baseAddress else { return }
            for row in 0..<height {
                destination.advanced(by: row * destinationStride).copyMemory(
                    from: source.advanced(by: row * sourceStride),
                    byteCount: sourceStride
                )
            }
        }
        return buffer
    }

    private func makeBGRAIOSurface(
        width: Int,
        height: Int,
        fill: UInt8
    ) throws -> IOSurfaceRef {
        let properties: [CFString: Any] = [
            kIOSurfaceWidth: width,
            kIOSurfaceHeight: height,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA,
        ]
        let surface = try #require(IOSurfaceCreate(properties as CFDictionary))
        var seed: UInt32 = 0
        #expect(IOSurfaceLock(surface, [], &seed) == 0)
        IOSurfaceGetBaseAddress(surface).initializeMemory(
            as: UInt8.self,
            repeating: fill,
            count: IOSurfaceGetAllocSize(surface)
        )
        #expect(IOSurfaceUnlock(surface, [], &seed) == 0)
        return surface
    }

    private func copyPixels(
        from surface: IOSurfaceRef,
        width: Int,
        height: Int
    ) throws -> Data {
        var seed: UInt32 = 0
        guard IOSurfaceLock(surface, .readOnly, &seed) == 0 else {
            throw TestError.ioSurfaceLock
        }
        defer { IOSurfaceUnlock(surface, .readOnly, &seed) }
        let source = IOSurfaceGetBaseAddress(surface)
        let sourceStride = IOSurfaceGetBytesPerRow(surface)
        let rowBytes = width * 4
        var pixels = Data(count: rowBytes * height)
        pixels.withUnsafeMutableBytes { bytes in
            guard let destination = bytes.baseAddress else {
                return
            }
            for row in 0..<height {
                destination.advanced(by: row * rowBytes).copyMemory(
                    from: source.advanced(by: row * sourceStride),
                    byteCount: rowBytes
                )
            }
        }
        return pixels
    }

    private func referenceBGRA(
        y: UInt8,
        u: UInt8,
        v: UInt8,
        matrix: SpiceVideoColorMatrix,
        range: SpiceVideoColorRange
    ) -> [UInt8] {
        let normalizedY: Double
        let normalizedU: Double
        let normalizedV: Double
        switch range {
        case .video:
            normalizedY = (Double(y) - 16) / 219
            normalizedU = (Double(u) - 128) / 224
            normalizedV = (Double(v) - 128) / 224
        case .full, .unknown:
            normalizedY = Double(y) / 255
            normalizedU = (Double(u) - 128) / 255
            normalizedV = (Double(v) - 128) / 255
        }
        let red: Double
        let green: Double
        let blue: Double
        switch matrix {
        case .bt601:
            red = normalizedY + 1.402 * normalizedV
            green = normalizedY - 0.344_136 * normalizedU - 0.714_136 * normalizedV
            blue = normalizedY + 1.772 * normalizedU
        case .bt709:
            red = normalizedY + 1.5748 * normalizedV
            green = normalizedY - 0.187_324 * normalizedU - 0.468_124 * normalizedV
            blue = normalizedY + 1.8556 * normalizedU
        case .unknown:
            return [0, 0, 0, 255]
        }
        func byte(_ value: Double) -> UInt8 {
            UInt8((min(max(value, 0), 1) * 255).rounded())
        }
        return [byte(blue), byte(green), byte(red), 255]
    }
}

private enum TestError: Error {
    case ioSurfaceLock
}
