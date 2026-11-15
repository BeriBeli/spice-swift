import SpiceProtocol

/// Fixed-size metadata for received, decoded Display protocol messages. Counts
/// describe peer requests before execution, not successful rendering/decoding.
/// Image categories cover DRAW_COPY sources, including cache/surface references.
package struct DisplayTrafficDiagnostics: Sendable, Equatable {
    package var receivedBytes: UInt64 = 0
    package var messages: UInt64 = 0
    package var copyBitsMessages: UInt64 = 0
    package var bitmapImages: UInt64 = 0
    package var quicImages: UInt64 = 0
    package var jpegImages: UInt64 = 0
    package var lzImages: UInt64 = 0
    package var cachedImages: UInt64 = 0
    package var surfaceImages: UInt64 = 0
    package var streamCreateMessages: UInt64 = 0
    package var mjpegStreamRequests: UInt64 = 0
    package var h264StreamRequests: UInt64 = 0
    package var h265StreamRequests: UInt64 = 0
    package var streamDataMessages: UInt64 = 0

    package mutating func record(_ message: SpiceServerMessage) {
        messages &+= 1
        switch message {
        case .displayCopyBits:
            copyBitsMessages &+= 1
        case let .displayDrawCopy(copy):
            switch copy.sourceImage {
            case .bitmap: bitmapImages &+= 1
            case .quic: quicImages &+= 1
            case .jpeg: jpegImages &+= 1
            case .lzRGB, .glzRGB, .zlibGLZ, .lzPalette: lzImages &+= 1
            case .cached: cachedImages &+= 1
            case .surface: surfaceImages &+= 1
            }
        case let .displayStreamCreate(create):
            streamCreateMessages &+= 1
            switch create.codec {
            case .mjpeg: mjpegStreamRequests &+= 1
            case .h264: h264StreamRequests &+= 1
            case .h265: h265StreamRequests &+= 1
            default: break
            }
        case .displayStreamData, .displayStreamDataSized:
            streamDataMessages &+= 1
        default: break
        }
    }
}
