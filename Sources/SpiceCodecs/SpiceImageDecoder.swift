import Foundation

package enum SpiceImageFormat: Sendable, Equatable {
    case jpeg
    case lzRGB
    case glzRGB
    case quic
}

package struct SpiceJPEGDecodeLimits: Sendable, Equatable {
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

package struct SpiceCodecImageDescriptor: Sendable, Equatable {
    package let width: Int
    package let height: Int

    package init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

package struct SpiceLZPalette: Sendable, Equatable {
    package let uniqueID: UInt64
    package let entriesARGB: [UInt32]

    package init(uniqueID: UInt64, entriesARGB: [UInt32]) {
        self.uniqueID = uniqueID
        self.entriesARGB = entriesARGB
    }
}

package struct SpiceDecodedImage: Sendable, Equatable {
    package enum AlphaMode: Sendable, Equatable {
        case opaque
        case straight
    }

    package let width: Int
    package let height: Int
    package let bytesPerRow: Int
    package let topDown: Bool
    package let alphaMode: AlphaMode
    package let pixelsBGRA: Data

    package init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        topDown: Bool = true,
        alphaMode: AlphaMode = .opaque,
        pixelsBGRA: consuming Data
    ) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.topDown = topDown
        self.alphaMode = alphaMode
        self.pixelsBGRA = pixelsBGRA
    }
}

package enum SpiceCodecError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyPayload
    case encodedImageTooLarge(actual: Int, maximum: Int)
    case invalidDimensions(width: Int, height: Int)
    case decodedImageTooLarge(actual: Int, maximum: Int)
    case invalidContainer
    case unexpectedImageCount(Int)
    case dimensionMismatch(expectedWidth: Int, expectedHeight: Int, actualWidth: Int, actualHeight: Int)
    case decodeFailed
    case backendFailure(String)
    case invalidHeader(String)
    case unsupportedFormat(Int)
    case malformedPayload(String)
    case integerOverflow
    case cancelled

    package var description: String {
        switch self {
        case .emptyPayload:
            "empty encoded image"
        case let .encodedImageTooLarge(actual, maximum):
            "encoded image has \(actual) bytes; maximum is \(maximum)"
        case let .invalidDimensions(width, height):
            "invalid image dimensions \(width)x\(height)"
        case let .decodedImageTooLarge(actual, maximum):
            "decoded image has \(actual) bytes; maximum is \(maximum)"
        case .invalidContainer:
            "encoded image is not a supported container"
        case let .unexpectedImageCount(count):
            "encoded image contains \(count) images"
        case let .dimensionMismatch(expectedWidth, expectedHeight, actualWidth, actualHeight):
            "expected \(expectedWidth)x\(expectedHeight), decoded \(actualWidth)x\(actualHeight)"
        case .decodeFailed:
            "image decode failed"
        case let .backendFailure(reason):
            "codec backend failed: \(reason)"
        case let .invalidHeader(reason):
            "invalid codec header: \(reason)"
        case let .unsupportedFormat(format):
            "unsupported codec format \(format)"
        case let .malformedPayload(reason):
            "malformed codec payload: \(reason)"
        case .integerOverflow:
            "image size overflow"
        case .cancelled:
            "codec operation cancelled"
        }
    }
}

package protocol SpiceImageDecoder: Sendable {
    nonisolated var format: SpiceImageFormat { get }

    func decode(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data
    ) async throws(SpiceCodecError) -> SpiceDecodedImage
}

package protocol SpicePaletteImageDecoder: Sendable {
    func decodePalette(
        descriptor: SpiceCodecImageDescriptor,
        payload: Data,
        palette: SpiceLZPalette
    ) async throws(SpiceCodecError) -> SpiceDecodedImage
}
