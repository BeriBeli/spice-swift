import Darwin
import Foundation
import CoreGraphics
import ImageIO
import Metal
import SpiceCodecs
import SpiceRenderer
import SwiftSpice
import UniformTypeIdentifiers

/// Finite, opt-in local measurements; never connects to a SPICE peer.
@main
struct PipelineBenchmark {
    enum Failure: Error { case usage, missingNativeFrame, incorrectPixels, incorrectCounters }

    struct PresentationResult: Encodable {
        let scale: Double
        let width: Int
        let height: Int
        let encoding: Summary
        let commitToCompletion: Summary
        let gpuExecution: Summary?
    }

    struct Summary: Encodable {
        let samples: Int
        let p50Milliseconds: Double
        let p95Milliseconds: Double
        let maximumMilliseconds: Double

        init(_ values: [Double]) {
            let sorted = values.sorted()
            samples = sorted.count
            p50Milliseconds = sorted[Int(ceil(Double(samples) * 0.5)) - 1]
            p95Milliseconds = sorted[Int(ceil(Double(samples) * 0.95)) - 1]
            maximumMilliseconds = sorted[samples - 1]
        }
    }

    struct Result: Encodable {
        let width: Int
        let height: Int
        let coverage: String
        let composition: Summary
        let publication: Summary
        let processCPUMillisecondsPerFrame: Double
        let gpuCopyBytesPerFrame: UInt64
        let directIOSurfaceWriteBytes: UInt64
        let maximumPixelError: Int
        let offscreenPresentation: [PresentationResult]
    }

    static func main() async {
        do {
            guard (2...3).contains(CommandLine.arguments.count) else { throw Failure.usage }
            let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let output = CommandLine.arguments.count == 3
                ? URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true) : nil
            if let output {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            }
            var results: [Result] = []
            for (width, height) in [(1_920, 1_080), (3_840, 2_160)] {
                let input = try Data(contentsOf: directory.appending(path: "\(width)x\(height)-2-q80.jpg"))
                let decoder = try SpiceMJPEGStreamDecoder(limiter: .init())
                let frame = try await decoder.decodeVideoFrame(
                    descriptor: .init(width: width, height: height), payload: input
                )
                guard frame is SpiceMJPEGFrame else { throw Failure.missingNativeFrame }
                let reference = try frame.copyBGRA()
                for partial in [false, true] {
                    let result = try await measure(
                        frame: frame, reference: reference, partial: partial, output: output
                    )
                    results.append(result)
                }
                await decoder.close()
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            FileHandle.standardOutput.write(try encoder.encode(results))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("pipeline_benchmark_failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func measure(
        frame: any SpiceDecodedVideoFrame,
        reference: SpiceDecodedImage,
        partial: Bool,
        output: URL?
    ) async throws -> Result {
        let store = SurfaceStore()
        do {
            let width = frame.width, height = frame.height
            try await store.create(id: 1, width: UInt32(width), height: UInt32(height), format: 32)
            try await store.fill(
                surfaceID: 1, rectangle: .init(x: 0, y: 0, width: width, height: height),
                colorARGB: 0x0011_2233
            )
            let rectangle = PixelRect(
                x: 0, y: 0, width: partial ? 64 : width, height: partial ? 64 : height
            )
            let clock = ContinuousClock()
            var previous: FrameSnapshot?
            var compositions: [Double] = [], publications: [Double] = []
            var baseline = await store.metrics()
            var cpuStart = 0.0
            for index in 0..<35 {
                if index == 5 {
                    baseline = await store.metrics()
                    cpuStart = processCPUSeconds()
                }
                let start = clock.now
                _ = try await store.drawNativeVideoFrame(
                    surfaceID: 1, destination: rectangle, frame: frame,
                    source: rectangle, topDown: true, clippedDestinations: [rectangle]
                )
                let composed = clock.now
                let next = try await store.snapshot(surfaceID: 1)
                let published = clock.now
                withExtendedLifetime(previous) {}
                previous = next
                if index >= 5 {
                    compositions.append(milliseconds(start.duration(to: composed)))
                    publications.append(milliseconds(composed.duration(to: published)))
                }
            }
            let cpu = (processCPUSeconds() - cpuStart) * 1_000 / 30
            let metrics = await store.metrics()
            guard metrics.nativeVideoFrames - baseline.nativeVideoFrames == 30,
                  metrics.poolExhaustions == 0, metrics.nativeVideoFallbacks == 0,
                  metrics.gpuErrors == 0, let final = previous, final.ioSurfaceFrame != nil
            else { throw Failure.incorrectCounters }
            // Readback and whole-frame correctness checks are outside all timing.
            let pixels = final.pixels
            var maximumError = 0
            for y in 0..<height {
                for x in 0..<width {
                    for component in 0..<4 {
                        let expected: UInt8
                        if !partial || (x < 64 && y < 64) {
                            expected = reference.pixelsBGRA[y * reference.bytesPerRow + x * 4 + component]
                        } else {
                            expected = [0x33, 0x22, 0x11, 0xff][component]
                        }
                        maximumError = max(maximumError, abs(Int(pixels[y * final.bytesPerRow + x * 4 + component]) - Int(expected)))
                    }
                }
            }
            guard maximumError <= 1 else { throw Failure.incorrectPixels }
            let presentation = !partial && width == 1_920
                ? try await renderOffscreen(SpiceFrame(final), output: output) : []
            let result = Result(
                width: width, height: height, coverage: partial ? "64x64" : "full",
                composition: Summary(compositions), publication: Summary(publications),
                processCPUMillisecondsPerFrame: cpu,
                gpuCopyBytesPerFrame: (metrics.gpuCopyBytes - baseline.gpuCopyBytes) / 30,
                directIOSurfaceWriteBytes: metrics.directIOSurfaceWriteBytes - baseline.directIOSurfaceWriteBytes,
                maximumPixelError: maximumError,
                offscreenPresentation: presentation
            )
            previous = nil
            await store.close()
            return result
        } catch {
            await store.close()
            throw error
        }
    }

    @MainActor
    private static func renderOffscreen(
        _ frame: SpiceFrame, output: URL?
    ) async throws -> [PresentationResult] {
        guard let presenter = SpiceMetalPresenter(), let source = presenter.makeTexture(for: frame)
        else { throw Failure.missingNativeFrame }
        var results: [PresentationResult] = []
        let clock = ContinuousClock()
        for scale in [1.0, 16.0 / 15.0, 0.8] {
            let width = Int((Double(frame.width) * scale).rounded())
            let height = Int((Double(frame.height) * scale).rounded())
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
            guard let target = presenter.device.makeTexture(descriptor: descriptor)
            else { throw Failure.missingNativeFrame }
            var encoding: [Double] = [], completion: [Double] = [], gpu: [Double] = []
            for index in 0..<35 {
                let start = clock.now
                guard let command = presenter.makePresentationCommand(
                    source: source, destination: target, retaining: frame
                ) else { throw Failure.incorrectCounters }
                let encoded = clock.now
                // Metal owns the completion callback until the submitted work
                // completes; the presenter retains its frame lease until then.
                await withCheckedContinuation { continuation in
                    command.addCompletedHandler { _ in continuation.resume() }
                    command.commit()
                }
                let completed = clock.now
                guard command.status == .completed else { throw Failure.incorrectCounters }
                if index >= 5 {
                    encoding.append(milliseconds(start.duration(to: encoded)))
                    completion.append(milliseconds(encoded.duration(to: completed)))
                    if command.gpuStartTime > 0, command.gpuEndTime >= command.gpuStartTime {
                        gpu.append((command.gpuEndTime - command.gpuStartTime) * 1_000)
                    }
                }
            }
            if let output {
                var bytes = Data(count: width * height * 4)
                bytes.withUnsafeMutableBytes {
                    target.getBytes($0.baseAddress!, bytesPerRow: width * 4,
                        from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
                }
                if scale == 1, bytes != frame.pixels { throw Failure.incorrectPixels }
                guard let provider = CGDataProvider(data: bytes as CFData),
                      let image = CGImage(
                        width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                            .union(.byteOrder32Little), provider: provider, decode: nil,
                        shouldInterpolate: false, intent: .defaultIntent
                      ),
                      let writer = CGImageDestinationCreateWithURL(
                        output.appending(path: "metal-\(width)x\(height).png") as CFURL,
                        UTType.png.identifier as CFString, 1, nil
                      ) else { throw Failure.incorrectPixels }
                CGImageDestinationAddImage(writer, image, nil)
                guard CGImageDestinationFinalize(writer) else { throw Failure.incorrectPixels }
            }
            results.append(PresentationResult(
                scale: scale, width: width, height: height, encoding: Summary(encoding),
                commitToCompletion: Summary(completion), gpuExecution: gpu.isEmpty ? nil : Summary(gpu)
            ))
        }
        return results
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
    }

    private static func processCPUSeconds() -> Double {
        var value = timespec()
        precondition(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1e9
    }
}
