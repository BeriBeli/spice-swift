import CSpiceQUIC
import Foundation

package enum SpiceQUICInteropError: Error, Sendable, Equatable {
    case badInput
    case dimensionMismatch(width: Int, height: Int)
    case unsupportedType(Int)
    case allocationFailed
}

package struct SpiceQUICInteropResult: Sendable, Equatable {
    package let sourceType: Int
    package let pixelsBGRA: Data
}

package enum SpiceQUICInterop {
    package static func decode(
        payload: Data,
        width: Int,
        height: Int,
        outputByteCount: Int
    ) throws(SpiceQUICInteropError) -> SpiceQUICInteropResult {
        var output = Data(repeating: 0, count: outputByteCount)
        var sourceType: Int32 = 0
        var decodedWidth: Int32 = 0
        var decodedHeight: Int32 = 0
        let status = payload.withUnsafeBytes { encodedBytes in
            output.withUnsafeMutableBytes { outputBytes in
                spice_swift_quic_decode(
                    encodedBytes.bindMemory(to: UInt8.self).baseAddress,
                    encodedBytes.count,
                    Int32(width),
                    Int32(height),
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputBytes.count,
                    &sourceType,
                    &decodedWidth,
                    &decodedHeight
                )
            }
        }
        switch status {
        case SPICE_SWIFT_QUIC_OK:
            return SpiceQUICInteropResult(
                sourceType: Int(sourceType),
                pixelsBGRA: output
            )
        case SPICE_SWIFT_QUIC_DIMENSION_MISMATCH:
            throw .dimensionMismatch(
                width: Int(decodedWidth),
                height: Int(decodedHeight)
            )
        case SPICE_SWIFT_QUIC_UNSUPPORTED_TYPE:
            throw .unsupportedType(Int(sourceType))
        case SPICE_SWIFT_QUIC_ALLOCATION_FAILED:
            throw .allocationFailed
        default:
            throw .badInput
        }
    }
}
