import CTurboJPEG
import Foundation

package enum TurboJPEGInteropError: Error, Sendable, Equatable {
    case initializationFailed(String)
    case invalidHeader(String)
    case dimensionMismatch(actualWidth: Int, actualHeight: Int)
    case decompressionFailed(String)
}

/// The only libturbojpeg pointer/handle boundary. Callers provide a fully
/// bounded destination layout; this layer validates the JPEG header against it
/// before allowing the C decoder to write any output bytes.
package struct TurboJPEGInterop: Sendable {
    package init() {}

    package func decodeBGRA(
        payload: Data,
        expectedWidth: Int,
        expectedHeight: Int,
        bytesPerRow: Int,
        outputByteCount: Int
    ) throws(TurboJPEGInteropError) -> Data {
        guard let handle = tjInitDecompress() else {
            throw .initializationFailed(errorString(handle: nil))
        }
        defer { tjDestroy(handle) }

        var output = Data(count: outputByteCount)
        var decodedAsCMYK = false
        let result: Result<Void, TurboJPEGInteropError> = payload.withUnsafeBytes { jpegBytes in
            guard let jpegBase = jpegBytes.bindMemory(to: UInt8.self).baseAddress else {
                return .failure(.invalidHeader("empty JPEG buffer"))
            }
            var width: Int32 = 0
            var height: Int32 = 0
            var subsampling: Int32 = 0
            var colorSpace: Int32 = 0
            guard tjDecompressHeader3(
                handle,
                jpegBase,
                UInt(payload.count),
                &width,
                &height,
                &subsampling,
                &colorSpace
            ) == 0 else {
                return .failure(.invalidHeader(errorString(handle: handle)))
            }
            guard Int(width) == expectedWidth, Int(height) == expectedHeight else {
                return .failure(.dimensionMismatch(
                    actualWidth: Int(width),
                    actualHeight: Int(height)
                ))
            }
            decodedAsCMYK = colorSpace == Int32(TJCS_CMYK.rawValue)
                || colorSpace == Int32(TJCS_YCCK.rawValue)
            let pixelFormat = decodedAsCMYK ? TJPF_CMYK : TJPF_BGRA
            return output.withUnsafeMutableBytes { outputBytes in
                guard let outputBase = outputBytes.bindMemory(to: UInt8.self).baseAddress else {
                    return .failure(.decompressionFailed("empty output buffer"))
                }
                guard tjDecompress2(
                    handle,
                    jpegBase,
                    UInt(payload.count),
                    outputBase,
                    width,
                    Int32(bytesPerRow),
                    height,
                    Int32(pixelFormat.rawValue),
                    Int32(TJFLAG_STOPONWARNING)
                ) == 0 else {
                    return .failure(.decompressionFailed(errorString(handle: handle)))
                }
                return .success(())
            }
        }
        try result.get()
        if decodedAsCMYK {
            convertCMYKToBGRA(&output)
        }
        return output
    }

    /// libturbojpeg deliberately exposes CMYK/YCCK JPEGs only as CMYK pixels.
    /// Convert conventional 0-is-no-ink CMYK into the renderer's BGRA layout
    /// with integer rounding, retaining the same bounded four-byte allocation.
    private func convertCMYKToBGRA(_ pixels: inout Data) {
        pixels.withUnsafeMutableBytes { bytes in
            let components = bytes.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: components.count, by: 4) {
                let cyan = UInt16(components[offset])
                let magenta = UInt16(components[offset + 1])
                let yellow = UInt16(components[offset + 2])
                let black = UInt16(components[offset + 3])
                let red = UInt8(((255 - cyan) * (255 - black) + 127) / 255)
                let green = UInt8(((255 - magenta) * (255 - black) + 127) / 255)
                let blue = UInt8(((255 - yellow) * (255 - black) + 127) / 255)
                components[offset] = blue
                components[offset + 1] = green
                components[offset + 2] = red
                components[offset + 3] = 255
            }
        }
    }

    private func errorString(handle: tjhandle?) -> String {
        guard let pointer = tjGetErrorStr2(handle) else {
            return "unknown libturbojpeg error"
        }
        return String(cString: pointer)
    }
}
