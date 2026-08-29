import CoreVideo
import Foundation
import SpiceChannels
import SpiceIOSurface
import SpiceProtocol
import SpiceRenderer

public struct SpiceIOSurfaceFrame: Sendable, Equatable {
    public let id: UInt32
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixelFormat: UInt32

    package let backing: IOSurfaceFrame

    package init(_ backing: IOSurfaceFrame) {
        self.backing = backing
        id = backing.id
        width = backing.width
        height = backing.height
        bytesPerRow = backing.bytesPerRow
        pixelFormat = backing.pixelFormat
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.bytesPerRow == rhs.bytesPerRow
            && lhs.pixelFormat == rhs.pixelFormat
    }
}

public struct SpiceFrame: Sendable, Equatable {
    public let surfaceID: UInt32
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    private let pixelStorage: FramePixelStorage
    public let ioSurface: SpiceIOSurfaceFrame?
    package let isAdvancedVideoFrame: Bool

    /// Copies IOSurface-backed frames only when a CPU consumer requests pixels.
    /// Metal presentation can retain and present the IOSurface without creating
    /// a second full-frame Data snapshot.
    public var pixels: Data {
        pixelStorage.pixels()
    }

    /// Borrows the published BGRA bytes without populating the full-frame
    /// IOSurface materialization cache. The pointer is closure-scoped.
    package func withReadOnlyPixelBytes<Result>(
        _ body: (UnsafeRawPointer, Int, Int) -> Result
    ) -> Result? {
        let (compactBytesPerRow, overflow) = width.multipliedReportingOverflow(by: 4)
        guard width >= 0,
              height >= 0,
              bytesPerRow >= compactBytesPerRow,
              !overflow,
              ioSurface.map({ $0.pixelFormat == kCVPixelFormatType_32BGRA }) ?? true
        else {
            return nil
        }
        return pixelStorage.withReadOnlyBytes(
            dataBytesPerRow: ioSurface == nil ? bytesPerRow : compactBytesPerRow,
            body
        )
    }

    package init(_ snapshot: FrameSnapshot) {
        surfaceID = snapshot.surfaceID
        width = snapshot.width
        height = snapshot.height
        bytesPerRow = snapshot.bytesPerRow
        pixelStorage = snapshot.pixelStorage
        ioSurface = snapshot.ioSurfaceFrame.map(SpiceIOSurfaceFrame.init)
        isAdvancedVideoFrame = snapshot.isAdvancedVideoFrame
    }

    public init(
        surfaceID: UInt32,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: consuming Data
    ) {
        self.surfaceID = surfaceID
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        pixelStorage = FramePixelStorage(pixels: pixels, ioSurfaceFrame: nil)
        self.ioSurface = nil
        isAdvancedVideoFrame = false
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.surfaceID == rhs.surfaceID,
              lhs.width == rhs.width,
              lhs.height == rhs.height,
              lhs.bytesPerRow == rhs.bytesPerRow,
              lhs.isAdvancedVideoFrame == rhs.isAdvancedVideoFrame
        else {
            return false
        }
        if lhs.pixelStorage === rhs.pixelStorage {
            return true
        }
        // A distinct GPU-backed storage object represents a distinct committed
        // frame revision. Comparing its pixels would synchronously read the
        // entire IOSurface back to the CPU during SwiftUI view diffing.
        guard lhs.ioSurface == nil, rhs.ioSurface == nil else {
            return false
        }
        return lhs.pixels == rhs.pixels
    }

    package func sharesPresentationStorage(with other: Self) -> Bool {
        surfaceID == other.surfaceID
            && width == other.width
            && height == other.height
            && bytesPerRow == other.bytesPerRow
            && pixelStorage === other.pixelStorage
    }
}

public struct SpiceGuestMonitor: Sendable, Equatable {
    public let id: UInt32
    public let surfaceID: UInt32
    public let x: UInt32
    public let y: UInt32
    public let width: UInt32
    public let height: UInt32
    public let flags: UInt32

    public init(
        id: UInt32,
        surfaceID: UInt32,
        x: UInt32,
        y: UInt32,
        width: UInt32,
        height: UInt32,
        flags: UInt32
    ) {
        self.id = id
        self.surfaceID = surfaceID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.flags = flags
    }
}

public struct SpiceGuestDisplayConfiguration: Sendable, Equatable {
    public let channelID: UInt8
    public let maximumAllowed: UInt16?
    public let monitors: [SpiceGuestMonitor]

    public init(
        channelID: UInt8,
        maximumAllowed: UInt16?,
        monitors: [SpiceGuestMonitor]
    ) {
        self.channelID = channelID
        self.maximumAllowed = maximumAllowed
        self.monitors = monitors
    }
}

public enum SpiceCursorImageFormat: UInt8, Sendable, Equatable {
    case alpha = 0
    case mono = 1
    case color4 = 2
    case color8 = 3
    case color16 = 4
    case color24 = 5
    case color32 = 6
}

public struct SpiceCursorImage: Sendable, Equatable {
    public let id: UInt64
    public let format: SpiceCursorImageFormat
    public let width: Int
    public let height: Int
    public let hotSpotX: Int
    public let hotSpotY: Int
    public let data: Data

    public init(
        id: UInt64,
        format: SpiceCursorImageFormat,
        width: Int,
        height: Int,
        hotSpotX: Int,
        hotSpotY: Int,
        data: consuming Data
    ) {
        self.id = id
        self.format = format
        self.width = width
        self.height = height
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
        self.data = data
    }
}

public struct SpiceCursorState: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let isVisible: Bool
    public let image: SpiceCursorImage?

    public init(x: Int, y: Int, isVisible: Bool, image: SpiceCursorImage?) {
        self.x = x
        self.y = y
        self.isVisible = isVisible
        self.image = image
    }

    package init(_ snapshot: CursorSnapshot) {
        x = Int(snapshot.position.x)
        y = Int(snapshot.position.y)
        isVisible = snapshot.visible
        if let payload = snapshot.cursor, let header = payload.header,
           let format = SpiceCursorImageFormat(rawValue: header.type.rawValue) {
            image = SpiceCursorImage(
                id: header.unique,
                format: format,
                width: Int(header.width),
                height: Int(header.height),
                hotSpotX: Int(header.hotSpotX),
                hotSpotY: Int(header.hotSpotY),
                data: payload.data
            )
        } else {
            image = nil
        }
    }
}

public enum SpiceMouseButton: UInt8, Sendable, Equatable {
    case left = 1
    case middle = 2
    case right = 3
    case scrollUp = 4
    case scrollDown = 5
    case side = 6
    case extra = 7
}

/// Physical PC XT set-1 key transitions and pointer events. This is not a
/// Unicode or IME committed-text API.
public enum SpiceClientInput: Sendable, Equatable {
    case keyDown(scanCode: UInt32)
    case keyUp(scanCode: UInt32)
    case lockModifiers(UInt16)
    case mouseMotion(dx: Int32, dy: Int32)
    case mousePosition(x: UInt32, y: UInt32, displayID: UInt8)
    case mousePress(SpiceMouseButton)
    case mouseRelease(SpiceMouseButton)
}

public enum SpicePlaybackDataMode: UInt32, Sendable, Equatable {
    case raw = 1
}

public enum SpicePlaybackSampleFormat: UInt16, Sendable, Equatable {
    case signed16LittleEndian = 1
}

public struct SpicePlaybackConfiguration: Sendable, Equatable {
    public let channels: Int
    public let format: SpicePlaybackSampleFormat
    public let sampleRate: Int

    public init(channels: Int, format: SpicePlaybackSampleFormat, sampleRate: Int) {
        self.channels = channels
        self.format = format
        self.sampleRate = sampleRate
    }
}

public struct SpicePlaybackPacket: Sendable, Equatable {
    public let multimediaTime: UInt32
    public let data: Data

    public init(multimediaTime: UInt32, data: consuming Data) {
        self.multimediaTime = multimediaTime
        self.data = data
    }
}

public enum SpicePlaybackEvent: Sendable, Equatable {
    case modeChanged(multimediaTime: UInt32, mode: SpicePlaybackDataMode)
    case started(SpicePlaybackConfiguration)
    case packet(SpicePlaybackPacket)
    case stopped
    case volumeChanged([UInt16])
    case muteChanged(Bool)
    case minimumLatencyChanged(milliseconds: UInt32)
}

public enum SpiceRecordSampleFormat: UInt16, Sendable, Equatable {
    case signed16LittleEndian = 1
}

public struct SpiceRecordConfiguration: Sendable, Equatable {
    public let channels: Int
    public let format: SpiceRecordSampleFormat
    public let sampleRate: Int

    public init(channels: Int, format: SpiceRecordSampleFormat, sampleRate: Int) {
        self.channels = channels
        self.format = format
        self.sampleRate = sampleRate
    }
}

public enum SpiceRecordEvent: Sendable, Equatable {
    case started(SpiceRecordConfiguration)
    case stopped
    case volumeChanged([UInt16])
    case muteChanged(Bool)
}

public enum SpiceSmartcardRequestType: UInt32, Sendable, Equatable {
    case initialize = 1
    case error = 2
    case readerAdd = 3
    case readerRemove = 4
    case atr = 5
    case cardRemove = 6
    case apdu = 7
    case flush = 8
    case flushComplete = 9
}

public struct SpiceSmartcardInitializationInfo: Sendable, Equatable {
    public let version: UInt32
    public let capabilities: [UInt32]

    public init(version: UInt32, capabilities: [UInt32]) {
        self.version = version
        self.capabilities = capabilities
    }
}

public enum SpiceSmartcardEvent: Sendable, Equatable {
    case initialized(SpiceSmartcardInitializationInfo)
    case operationCompleted(
        request: SpiceSmartcardRequestType,
        readerID: UInt32,
        errorCode: UInt32
    )
    case apdu(readerID: UInt32, data: Data)
    case flushRequested(readerID: UInt32)
}

public struct SpiceUSBRedirectionPacket: Sendable, Equatable {
    public let channelID: UInt8
    public let data: Data

    public init(channelID: UInt8, data: consuming Data) {
        self.channelID = channelID
        self.data = data
    }
}

public enum SpiceWebDAVPortEvent: UInt8, Sendable, Equatable {
    case opened = 0
    case closed = 1
    case `break` = 2
}

public enum SpiceWebDAVEvent: Sendable, Equatable {
    case initialized(name: String, opened: Bool)
    case port(SpiceWebDAVPortEvent)
    case request(clientID: Int64, data: Data)
    case clientClosed(Int64)
}

public struct SpiceAgentMessage: Sendable, Equatable {
    public let protocolID: UInt32
    public let type: UInt32
    public let opaque: UInt64
    public let data: Data

    public init(
        protocolID: UInt32,
        type: UInt32,
        opaque: UInt64,
        data: consuming Data
    ) {
        self.protocolID = protocolID
        self.type = type
        self.opaque = opaque
        self.data = data
    }
}

public enum SpiceAgentEvent: Sendable, Equatable {
    case connected
    case disconnected(errorCode: UInt32)
    case message(SpiceAgentMessage)
}

public enum SpiceSessionEvent: Sendable, Equatable {
    case displayConfiguration(SpiceGuestDisplayConfiguration)
    case keyboardModifiers(UInt16)
    case mouseMotionAcknowledged
    case migration(SpiceMigrationEvent)
    case failed(SpiceError)
    case disconnected
}
