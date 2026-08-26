import CSpicePixelOps
import Foundation
import Testing

@Suite("Apple Silicon BGRA pixel kernels")
struct SpicePixelOpsTests {
    @Test func copiesOpaquePixelsAcrossVectorAndScalarTails() {
        for pixelCount in 0...65 {
            let byteCount = pixelCount * 4
            let source = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 &* 37) })
            var destination = Data(repeating: 0xa5, count: byteCount)

            source.withUnsafeBytes { sourceBytes in
                destination.withUnsafeMutableBytes { destinationBytes in
                    spice_copy_bgra_opaque(
                        sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        destinationBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        pixelCount
                    )
                }
            }

            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                #expect(destination[offset] == source[offset])
                #expect(destination[offset + 1] == source[offset + 1])
                #expect(destination[offset + 2] == source[offset + 2])
                #expect(destination[offset + 3] == 0xff)
            }
        }
    }

    @Test func copiesOnlyAlphaAcrossVectorAndScalarTails() {
        for pixelCount in 0...65 {
            let byteCount = pixelCount * 4
            let source = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 &* 29) })
            let original = Data((0..<byteCount).map { UInt8(truncatingIfNeeded: $0 &* 11) })
            var destination = original

            source.withUnsafeBytes { sourceBytes in
                destination.withUnsafeMutableBytes { destinationBytes in
                    spice_copy_bgra_alpha(
                        sourceBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        destinationBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        pixelCount
                    )
                }
            }

            for pixel in 0..<pixelCount {
                let offset = pixel * 4
                #expect(destination[offset] == original[offset])
                #expect(destination[offset + 1] == original[offset + 1])
                #expect(destination[offset + 2] == original[offset + 2])
                #expect(destination[offset + 3] == source[offset + 3])
            }
        }
    }

    @Test func expandsOverlappingAlphaReferencesWithoutChangingColor() {
        for distance in [1, 2, 3, 4, 5, 15, 16, 17, 31] {
            for pixelCount in [1, 3, 4, 15, 16, 17, 33, 65] {
                let destinationPixel = distance
                let totalPixels = destinationPixel + pixelCount
                var pixels = Data((0..<(totalPixels * 4)).map {
                    UInt8(truncatingIfNeeded: $0 &* 17)
                })
                var expected = pixels
                for copiedPixel in 0..<pixelCount {
                    expected[(destinationPixel + copiedPixel) * 4 + 3] =
                        expected[copiedPixel * 4 + 3]
                }

                pixels.withUnsafeMutableBytes { bytes in
                    spice_copy_bgra_alpha_overlap(
                        bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        0,
                        destinationPixel,
                        pixelCount
                    )
                }

                #expect(pixels == expected)
            }
        }
    }
}
