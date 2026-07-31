import Foundation
import SpiceCodecInterop

package struct SpiceQUICDecodeLimits: Sendable, Equatable {
    package var maximumDimension: Int
    package var maximumEncodedBytes: Int
    package var maximumDecodedBytes: Int

    package init(
        maximumDimension: Int = 16_384,
        maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
        maximumDecodedBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumDimension = maximumDimension
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
    }
}

package struct SpiceQUICDecoder: SpiceImageDecoder {
    package nonisolated let format = SpiceImageFormat.quic
    private let limits: SpiceQUICDecodeLimits

    package init(limits: SpiceQUICDecodeLimits = .init()) {
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
        guard payload.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw .invalidContainer
        }
        let width = descriptor.width
        let height = descriptor.height
        guard width > 0, height > 0,
              width <= limits.maximumDimension, height <= limits.maximumDimension
        else {
            throw .invalidDimensions(width: width, height: height)
        }
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (outputByteCount, outputOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !outputOverflow else {
            throw .integerOverflow
        }
        guard outputByteCount <= limits.maximumDecodedBytes else {
            throw .decodedImageTooLarge(
                actual: outputByteCount,
                maximum: limits.maximumDecodedBytes
            )
        }

        let decoded: SpiceQUICInteropResult
        do {
            decoded = try SpiceQUICInterop.decode(
                payload: payload,
                width: width,
                height: height,
                outputByteCount: outputByteCount
            )
        } catch let error {
            switch error {
            case .badInput:
                throw .malformedPayload("QUIC backend rejected input")
            case let .dimensionMismatch(actualWidth, actualHeight):
                throw .dimensionMismatch(
                    expectedWidth: width,
                    expectedHeight: height,
                    actualWidth: actualWidth,
                    actualHeight: actualHeight
                )
            case let .unsupportedType(type):
                throw .unsupportedFormat(type)
            case .allocationFailed:
                throw .backendFailure("QUIC allocation failed")
            }
        }
        return SpiceDecodedImage(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            topDown: false,
            alphaMode: decoded.sourceType == 5 ? .straight : .opaque,
            pixelsBGRA: decoded.pixelsBGRA
        )
    }
}
