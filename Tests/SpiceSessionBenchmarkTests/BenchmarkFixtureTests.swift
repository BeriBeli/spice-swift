import CoreGraphics
import Foundation
import ImageIO
import SwiftSpice
import Testing
@testable import SpiceSessionBenchmark

@Suite("Explicit benchmark fixture operations")
struct BenchmarkFixtureTests {
    @Test func transferFailureCategoriesExcludeUnderlyingPrivateDetails() {
        let sensitive = "/private/user-fixture secret-token"
        #expect(fixtureTransferFailureCategory(SpiceFileTransferError.invalidFile(sensitive)) == "invalid_file")
        #expect(fixtureTransferFailureCategory(SpiceFileTransferError.invalidAgentResponse(sensitive)) == "guest_response")
        #expect(fixtureTransferFailureCategory(SpiceFileTransferError.localReadFailed(sensitive)) == "local_read")
        #expect(fixtureTransferFailureCategory(SessionBenchmarkError.timedOut) == "timeout")
        #expect(fixtureTransferFailureCategory(CancellationError()) == "cancelled")
    }

    @Test func transferModeIsHeadlessAndCannotCollectOrExportFrames() throws {
        let configuration = try BenchmarkConfiguration.parse(
            ["example", "5900", "--transfer-fixture", "fixture.html"], environment: [:]
        )
        #expect(configuration.headless)
        #expect(configuration.fixtureURL?.lastPathComponent == "fixture.html")
        #expect(configuration.snapshotURL == nil)
    }

    @Test(arguments: [
        ["--transfer-fixture", "fixture.html", "--snapshot", "frame.png"],
        ["--transfer-fixture", "fixture.html", "--observe-seconds", "1"],
        ["--transfer-fixture", "fixture.html", "--marker-base", "1234567800000000", "--trace", "trace.jsonl"],
        ["--snapshot", "frame.png", "--marker-base", "1234567800000000", "--trace", "trace.jsonl"],
    ])
    func refusesAmbiguousWorkloads(_ options: [String]) {
        #expect(throws: SessionBenchmarkError.usage) {
            try BenchmarkConfiguration.parse(["example", "5900"] + options, environment: [:])
        }
    }

    @Test func snapshotExportPreservesBGRAColorsAndIgnoresRowPadding() throws {
        let output = FileManager.default.temporaryDirectory.appending(path: "frame-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: output) }
        let frame = SpiceFrame(
            surfaceID: 0, width: 2, height: 1, bytesPerRow: 12,
            pixels: Data([0, 0, 255, 255, 255, 0, 0, 255, 0xa5, 0xa5, 0xa5, 0xa5])
        )
        try writeBenchmarkSnapshot(frame, to: output)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.width == 2)
        #expect(image.height == 1)
        var pixels = Data(count: 8)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(
                data: bytes.baseAddress, width: 2, height: 1, bitsPerComponent: 8,
                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 1))
        }
        #expect(pixels == Data([0, 0, 255, 255, 255, 0, 0, 255]))
    }

    @Test func missingFrameDoesNotProduceAnImage() {
        let output = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID()).png")
        #expect(throws: (any Error).self) { try writeBenchmarkSnapshot(nil, to: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }
}
