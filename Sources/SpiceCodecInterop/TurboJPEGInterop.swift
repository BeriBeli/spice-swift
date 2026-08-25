import CTurboJPEG
import Foundation

package enum TurboJPEGInteropError: Error, Sendable, Equatable {
    case initializationFailed(String)
    case invalidHeader(String)
    case dimensionMismatch(actualWidth: Int, actualHeight: Int)
    case invalidDestination(String)
    case decompressionFailed(String)
}

/// One persistent libturbojpeg decompressor. The C handle is not internally
/// thread safe, so calls are serialized even though stream decoders normally
/// isolate an instance inside their own actor.
package final class TurboJPEGDecoderHandle: @unchecked Sendable {
    private let handle: tjhandle
    private let lock = NSLock()

    package init() throws(TurboJPEGInteropError) {
        guard let handle = tjInitDecompress() else {
            throw .initializationFailed(Self.errorString(handle: nil))
        }
        self.handle = handle
    }

    deinit {
        tjDestroy(handle)
    }

    package func decodeBGRA(
        payload: Data,
        expectedWidth: Int,
        expectedHeight: Int,
        bytesPerRow: Int,
        outputByteCount: Int,
        into destination: UnsafeMutableRawBufferPointer
    ) throws(TurboJPEGInteropError) {
        let (minimumRowBytes, rowOverflow) = expectedWidth.multipliedReportingOverflow(by: 4)
        let (minimumByteCount, countOverflow) = bytesPerRow.multipliedReportingOverflow(
            by: expectedHeight
        )
        guard !rowOverflow, !countOverflow else {
            throw .invalidDestination("decoded output geometry overflow")
        }
        guard expectedWidth > 0, expectedHeight > 0,
              bytesPerRow >= minimumRowBytes,
              Int32(exactly: bytesPerRow) != nil,
              outputByteCount >= minimumByteCount,
              destination.count >= outputByteCount,
              destination.baseAddress != nil
        else {
            throw .invalidDestination("decoded BGRA destination is too small")
        }

        lock.lock()
        defer { lock.unlock() }

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
                return .failure(.invalidHeader(Self.errorString(handle: handle)))
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
            guard let cBytesPerRow = Int32(exactly: bytesPerRow) else {
                return .failure(.invalidDestination("BGRA row stride exceeds TurboJPEG limits"))
            }
            let flags = Int32(TJFLAG_STOPONWARNING)
            guard let outputBase = destination.baseAddress?.assumingMemoryBound(to: UInt8.self)
            else {
                return .failure(.invalidDestination("empty output buffer"))
            }
            guard tjDecompress2(
                handle,
                jpegBase,
                UInt(payload.count),
                outputBase,
                width,
                cBytesPerRow,
                height,
                Int32(pixelFormat.rawValue),
                flags
            ) == 0 else {
                return .failure(.decompressionFailed(Self.errorString(handle: handle)))
            }
            return .success(())
        }
        try result.get()
        if decodedAsCMYK, let outputBase = destination.baseAddress {
            Self.convertCMYKToBGRA(
                outputBase,
                width: expectedWidth,
                height: expectedHeight,
                bytesPerRow: bytesPerRow
            )
        }
    }

    package func decodeBGRAData(
        payload: Data,
        expectedWidth: Int,
        expectedHeight: Int,
        bytesPerRow: Int,
        outputByteCount: Int
    ) throws(TurboJPEGInteropError) -> Data {
        var output = Data(count: outputByteCount)
        let result: Result<Void, TurboJPEGInteropError> = output.withUnsafeMutableBytes {
            outputBytes in
            do {
                try decodeBGRA(
                    payload: payload,
                    expectedWidth: expectedWidth,
                    expectedHeight: expectedHeight,
                    bytesPerRow: bytesPerRow,
                    outputByteCount: outputByteCount,
                    into: outputBytes
                )
                return .success(())
            } catch let error as TurboJPEGInteropError {
                return .failure(error)
            } catch {
                return .failure(.decompressionFailed(String(describing: error)))
            }
        }
        try result.get()
        return output
    }

    /// libturbojpeg deliberately exposes CMYK/YCCK JPEGs only as CMYK pixels.
    /// Convert conventional 0-is-no-ink CMYK into the renderer's BGRA layout
    /// while leaving any IOSurface row padding untouched.
    private static func convertCMYKToBGRA(
        _ baseAddress: UnsafeMutableRawPointer,
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) {
        let components = baseAddress.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let rowBase = components.advanced(by: row * bytesPerRow)
            for column in 0..<width {
                let offset = column * 4
                let cyan = UInt16(rowBase[offset])
                let magenta = UInt16(rowBase[offset + 1])
                let yellow = UInt16(rowBase[offset + 2])
                let black = UInt16(rowBase[offset + 3])
                let red = UInt8(((255 - cyan) * (255 - black) + 127) / 255)
                let green = UInt8(((255 - magenta) * (255 - black) + 127) / 255)
                let blue = UInt8(((255 - yellow) * (255 - black) + 127) / 255)
                rowBase[offset] = blue
                rowBase[offset + 1] = green
                rowBase[offset + 2] = red
                rowBase[offset + 3] = 255
            }
        }
    }

    private static func errorString(handle: tjhandle?) -> String {
        guard let pointer = tjGetErrorStr2(handle) else {
            return "unknown libturbojpeg error"
        }
        return String(cString: pointer)
    }
}

/// Convenience boundary for one-shot decodes. It intentionally creates and
/// destroys a handle so static JPEG behavior remains independent from the
/// persistent MJPEG stream path.
package struct TurboJPEGInterop: Sendable {
    package init() {}

    package func decodeBGRA(
        payload: Data,
        expectedWidth: Int,
        expectedHeight: Int,
        bytesPerRow: Int,
        outputByteCount: Int
    ) throws(TurboJPEGInteropError) -> Data {
        let handle = try TurboJPEGDecoderHandle()
        return try handle.decodeBGRAData(
            payload: payload,
            expectedWidth: expectedWidth,
            expectedHeight: expectedHeight,
            bytesPerRow: bytesPerRow,
            outputByteCount: outputByteCount
        )
    }
}
