import Foundation
import SpiceCodecInterop

package struct SpiceZlibInflateLimits: Sendable, Equatable {
    package var maximumEncodedBytes: Int
    package var maximumDecodedBytes: Int

    package init(
        maximumEncodedBytes: Int = 64 * 1_024 * 1_024,
        maximumDecodedBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumEncodedBytes = maximumEncodedBytes
        self.maximumDecodedBytes = maximumDecodedBytes
    }
}

package struct SpiceZlibInflator: Sendable {
    private let limits: SpiceZlibInflateLimits

    package init(limits: SpiceZlibInflateLimits = .init()) {
        self.limits = limits
    }

    @concurrent
    package func inflate(
        payload: Data,
        exactOutputByteCount: Int
    ) async throws(SpiceCodecError) -> Data {
        guard !payload.isEmpty else {
            throw .emptyPayload
        }
        guard payload.count <= limits.maximumEncodedBytes else {
            throw .encodedImageTooLarge(
                actual: payload.count,
                maximum: limits.maximumEncodedBytes
            )
        }
        guard exactOutputByteCount > 0,
              exactOutputByteCount <= limits.maximumDecodedBytes
        else {
            throw .decodedImageTooLarge(
                actual: exactOutputByteCount,
                maximum: limits.maximumDecodedBytes
            )
        }
        do {
            return try SpiceZlibInterop.inflateExact(
                payload: payload,
                outputByteCount: exactOutputByteCount
            )
        } catch let error {
            switch error {
            case .invalidArgument:
                throw .malformedPayload("invalid zlib buffer")
            case .initializationFailed:
                throw .backendFailure("zlib initialization failed")
            case .inflateFailed:
                throw .malformedPayload("zlib inflate failed")
            case let .sizeMismatch(actual):
                throw .malformedPayload(
                    "zlib output size \(actual) does not match \(exactOutputByteCount)"
                )
            case let .trailingInput(consumed):
                throw .malformedPayload("zlib trailing input after byte \(consumed)")
            }
        }
    }
}
