import Foundation
import SpiceCodecInterop

package struct SpiceJPEGDecoder: SpiceImageDecoder {
    package nonisolated let format = SpiceImageFormat.jpeg
    private let limits: SpiceJPEGDecodeLimits
    private let backend = TurboJPEGInterop()

    package init(limits: SpiceJPEGDecodeLimits = .init()) {
        self.limits = limits
    }

    @concurrent
    package func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage {
        guard !payload.isEmpty else {
            throw .emptyPayload
        }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(
                actual: payload.count,
                maximum: limits.maximumEncodedBytes
            )
        }
        guard descriptor.width > 0, descriptor.height > 0,
              descriptor.width <= limits.maximumDimension,
              descriptor.height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: descriptor.width, height: descriptor.height)
        }
        let (bytesPerRow, rowOverflow) = descriptor.width.multipliedReportingOverflow(by: 4)
        let (byteCount, sizeOverflow) = bytesPerRow.multipliedReportingOverflow(
            by: descriptor.height
        )
        guard !rowOverflow, !sizeOverflow else {
            throw .integerOverflow
        }
        guard byteCount <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(actual: byteCount, maximum: limits.maximumDecodedBytes)
        }

        let pixels: Data
        do {
            pixels = try backend.decodeBGRA(
                payload: payload,
                expectedWidth: descriptor.width,
                expectedHeight: descriptor.height,
                bytesPerRow: bytesPerRow,
                outputByteCount: byteCount
            )
        } catch let error {
            switch error {
            case let .dimensionMismatch(actualWidth, actualHeight):
                throw .dimensionMismatch(
                    expectedWidth: descriptor.width,
                    expectedHeight: descriptor.height,
                    actualWidth: actualWidth,
                    actualHeight: actualHeight
                )
            default:
                throw .backendFailure(String(describing: error))
            }
        }
        return SpiceDecodedImage(
            width: descriptor.width,
            height: descriptor.height,
            bytesPerRow: bytesPerRow,
            pixelsBGRA: pixels
        )
    }
}
