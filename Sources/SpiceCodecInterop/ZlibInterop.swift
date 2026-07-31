import CZlib
import Foundation

package enum SpiceZlibInteropError: Error, Sendable, Equatable {
    case invalidArgument
    case initializationFailed
    case inflateFailed
    case sizeMismatch(actual: Int)
    case trailingInput(consumed: Int)
}

package enum SpiceZlibInterop {
    package static func inflateExact(
        payload: Data,
        outputByteCount: Int
    ) throws(SpiceZlibInteropError) -> Data {
        guard !payload.isEmpty, outputByteCount > 0 else {
            throw .invalidArgument
        }
        var output = Data(count: outputByteCount)
        var sourceConsumed = 0
        var destinationWritten = 0
        let status = payload.withUnsafeBytes { sourceBytes in
            output.withUnsafeMutableBytes { destinationBytes in
                spice_swift_zlib_inflate_exact(
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress,
                    sourceBytes.count,
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress,
                    destinationBytes.count,
                    &sourceConsumed,
                    &destinationWritten
                )
            }
        }
        switch Int(status) {
        case SPICE_SWIFT_ZLIB_OK:
            return output
        case SPICE_SWIFT_ZLIB_INITIALIZATION_FAILED:
            throw .initializationFailed
        case SPICE_SWIFT_ZLIB_INFLATE_FAILED:
            throw .inflateFailed
        case SPICE_SWIFT_ZLIB_SIZE_MISMATCH:
            throw .sizeMismatch(actual: destinationWritten)
        case SPICE_SWIFT_ZLIB_TRAILING_INPUT:
            throw .trailingInput(consumed: sourceConsumed)
        default:
            throw .invalidArgument
        }
    }
}
