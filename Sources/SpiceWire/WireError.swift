import Foundation

package enum WireError: Error, Sendable, Equatable {
    case truncated(expected: Int, remaining: Int)
    case invalidMagic(UInt32)
    case unsupportedVersion(major: UInt32, minor: UInt32)
    case invalidSize(Int)
    case integerOverflow
    case invalidOffset(UInt64)
    case messageTooLarge(actual: Int, maximum: Int)
    case tooManySegments(actual: Int, maximum: Int)
    case trailingBytes(Int)
    case invalidEnum(type: String, value: UInt64)
    case unsupportedFeature(String)
}

package struct WireLimits: Sendable, Equatable {
    package var maximumMessageSize: Int
    package var maximumBufferedBytes: Int
    package var maximumBufferedSegments: Int

    package init(
        maximumMessageSize: Int = 64 * 1024 * 1024,
        maximumBufferedBytes: Int = 128 * 1024 * 1024,
        maximumBufferedSegments: Int = 4_096
    ) {
        self.maximumMessageSize = maximumMessageSize
        self.maximumBufferedBytes = maximumBufferedBytes
        self.maximumBufferedSegments = maximumBufferedSegments
    }
}
