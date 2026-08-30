import Foundation
import QuartzCore

package struct SpiceInteractionFrameIdentity: Sendable, Hashable, Codable {
    package let desktopGeneration: UInt64
    package let displayChannelID: UInt8
    package let surfaceID: UInt32
    package let surfaceGeneration: UInt64
    package let frameRevision: UInt64
    package let deliverySequence: UInt64

    package init(
        desktopGeneration: UInt64,
        displayChannelID: UInt8,
        surfaceID: UInt32,
        surfaceGeneration: UInt64,
        frameRevision: UInt64,
        deliverySequence: UInt64
    ) {
        self.desktopGeneration = desktopGeneration
        self.displayChannelID = displayChannelID
        self.surfaceID = surfaceID
        self.surfaceGeneration = surfaceGeneration
        self.frameRevision = frameRevision
        self.deliverySequence = deliverySequence
    }
}

package struct SpiceInteractionPresentationContext: Sendable, Equatable {
    package let identity: SpiceInteractionFrameIdentity
    package let readyNanoseconds: UInt64
    package let selectionNanoseconds: UInt64

    package init(
        identity: SpiceInteractionFrameIdentity,
        readyNanoseconds: UInt64,
        selectionNanoseconds: UInt64
    ) {
        self.identity = identity
        self.readyNanoseconds = readyNanoseconds
        self.selectionNanoseconds = selectionNanoseconds
    }
}

package struct SpiceInteractionMarkerPayload: Sendable, Equatable {
    package let token: String
    package let markerRevision: UInt64
    package let checksum: UInt32

    package init(token: String, markerRevision: UInt64, checksum: UInt32) {
        self.token = token
        self.markerRevision = markerRevision
        self.checksum = checksum
    }
}

package enum SpiceInteractionMarkerDetection: Sendable, Equatable {
    case none
    case exact(payload: SpiceInteractionMarkerPayload, identity: SpiceInteractionFrameIdentity)
    case ambiguous(matchCount: Int)
}

package struct SpiceInteractionMarkerPlacement: Sendable, Equatable {
    package let payload: SpiceInteractionMarkerPayload
    package let originX: Int
    package let originY: Int

    package init(
        payload: SpiceInteractionMarkerPayload,
        originX: Int,
        originY: Int
    ) {
        self.payload = payload
        self.originX = originX
        self.originY = originY
    }
}

/// The fixture's versioned binary-grid-v1 codec and bounded BGRA detector.
/// Production detection samples only 49 aligned top-left candidates through a
/// synchronous pixel borrow; it never asks an IOSurface frame for `pixels`.
package enum SpiceInteractionMarkerROIDetector {
    package static let magic: UInt16 = 0xA5C3
    package static let cellSize = 4
    package static let columns = 88
    package static let rows = 2
    package static let foregroundBGRA: UInt32 = 0xFF00_0000
    package static let backgroundBGRA: UInt32 = 0xFFFF_FFFF
    package static let minimumOrigin = 8
    package static let maximumOrigin = 32

    private static let bitCount = 176

    package static func renderForTesting(
        placements: [SpiceInteractionMarkerPlacement],
        frameWidth: Int,
        frameHeight: Int,
        bytesPerRow: Int
    ) -> Data {
        let (minimumBytesPerRow, rowOverflow) = frameWidth
            .multipliedReportingOverflow(by: 4)
        let (totalBytes, totalOverflow) = bytesPerRow
            .multipliedReportingOverflow(by: frameHeight)
        precondition(frameWidth > 0 && frameHeight > 0)
        precondition(!rowOverflow && bytesPerRow >= minimumBytesPerRow)
        precondition(!totalOverflow && totalBytes >= 0)
        var pixels = Data(repeating: 0x7F, count: totalBytes)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            for placement in placements {
                let bits = encodedBits(placement.payload)
                let (placementEndX, placementXOverflow) = placement.originX
                    .addingReportingOverflow(columns * cellSize)
                let (placementEndY, placementYOverflow) = placement.originY
                    .addingReportingOverflow(rows * cellSize)
                precondition(bits.count == bitCount)
                precondition(placement.originX >= 0 && placement.originY >= 0)
                precondition(!placementXOverflow && placementEndX <= frameWidth)
                precondition(!placementYOverflow && placementEndY <= frameHeight)
                for (bitIndex, bit) in bits.enumerated() {
                    let cellX = placement.originX + (bitIndex % columns) * cellSize
                    let cellY = placement.originY + (bitIndex / columns) * cellSize
                    let component: UInt8 = bit ? 0 : 255
                    for y in cellY..<(cellY + cellSize) {
                        for x in cellX..<(cellX + cellSize) {
                            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
                            pixel[0] = component
                            pixel[1] = component
                            pixel[2] = component
                            pixel[3] = 255
                        }
                    }
                }
            }
        }
        return pixels
    }

    package static func detect(
        in snapshot: SpiceDesktopSnapshot,
        expectedToken: String,
        expectedChecksum: UInt32
    ) -> SpiceInteractionMarkerDetection {
        guard let update = snapshot.frame,
              let identity = snapshot.interactionFrameIdentity,
              isCanonicalToken(expectedToken)
        else {
            return .none
        }
        let frame = update.frame
        let markerWidth = columns * cellSize
        let markerHeight = rows * cellSize
        let (minimumRowBytes, rowBytesOverflow) = frame.width
            .multipliedReportingOverflow(by: 4)
        let (requiredWidth, widthOverflow) = markerWidth.addingReportingOverflow(
            maximumOrigin
        )
        let (requiredHeight, heightOverflow) = markerHeight.addingReportingOverflow(
            maximumOrigin
        )
        guard frame.width >= 0,
              frame.height >= 0,
              frame.bytesPerRow >= 0,
              !rowBytesOverflow,
              !widthOverflow,
              !heightOverflow,
              frame.width >= requiredWidth,
              frame.height >= requiredHeight,
              frame.bytesPerRow >= minimumRowBytes
        else {
            return .none
        }
        return frame.withReadOnlyPixelBytes { rawBase, bytesPerRow, byteCount in
            guard bytesPerRow >= minimumRowBytes,
                  byteCount >= 0
            else {
                return .none
            }
            let (lastRowOffset, rowOverflow) = (maximumOrigin + markerHeight - 1)
                .multipliedReportingOverflow(by: bytesPerRow)
            let (lastColumnBytes, columnOverflow) = (maximumOrigin + markerWidth)
                .multipliedReportingOverflow(by: 4)
            let (requiredBytes, requiredOverflow) = lastRowOffset.addingReportingOverflow(
                lastColumnBytes
            )
            guard !rowOverflow,
                  !columnOverflow,
                  !requiredOverflow,
                  requiredBytes <= byteCount
            else {
                return .none
            }
            let base = rawBase.assumingMemoryBound(to: UInt8.self)
            var firstMatch: SpiceInteractionMarkerPayload?
            var matchCount = 0
            for originY in stride(
                from: minimumOrigin,
                through: maximumOrigin,
                by: cellSize
            ) {
                for originX in stride(
                    from: minimumOrigin,
                    through: maximumOrigin,
                    by: cellSize
                ) {
                    guard let payload = decode(
                        base: base,
                        bytesPerRow: bytesPerRow,
                        originX: originX,
                        originY: originY
                    ), payload.token == expectedToken,
                       payload.checksum == expectedChecksum
                    else {
                        continue
                    }
                    matchCount += 1
                    if firstMatch == nil {
                        firstMatch = payload
                    }
                }
            }
            switch matchCount {
            case 0:
                return .none
            case 1:
                guard let firstMatch else { return .none }
                return .exact(payload: firstMatch, identity: identity)
            default:
                return .ambiguous(matchCount: matchCount)
            }
        } ?? .none
    }

    private static func decode(
        base: UnsafePointer<UInt8>,
        bytesPerRow: Int,
        originX: Int,
        originY: Int
    ) -> SpiceInteractionMarkerPayload? {
        var bits = [Bool]()
        bits.reserveCapacity(bitCount)
        for bitIndex in 0..<bitCount {
            let column = bitIndex % columns
            let row = bitIndex / columns
            let x = originX + column * cellSize + cellSize / 2
            let y = originY + row * cellSize + cellSize / 2
            let pixel = base.advanced(by: y * bytesPerRow + x * 4)
            let blue = pixel[0]
            let green = pixel[1]
            let red = pixel[2]
            if red <= 8, green <= 8, blue <= 8 {
                bits.append(true)
            } else if red >= 247, green >= 247, blue >= 247 {
                bits.append(false)
            } else {
                return nil
            }
        }

        var cursor = 0
        guard read(bits, cursor: &cursor, count: 16) == UInt64(magic) else {
            return nil
        }
        let token = read(bits, cursor: &cursor, count: 64)
        let markerRevision = read(bits, cursor: &cursor, count: 64)
        let checksum = UInt32(read(bits, cursor: &cursor, count: 32))
        return SpiceInteractionMarkerPayload(
            token: String(format: "%016llx", token),
            markerRevision: markerRevision,
            checksum: checksum
        )
    }

    private static func read(
        _ bits: [Bool],
        cursor: inout Int,
        count: Int
    ) -> UInt64 {
        var value: UInt64 = 0
        for _ in 0..<count {
            value = (value << 1) | (bits[cursor] ? 1 : 0)
            cursor += 1
        }
        return value
    }

    private static func encodedBits(_ payload: SpiceInteractionMarkerPayload) -> [Bool] {
        guard isCanonicalToken(payload.token),
              let token = UInt64(payload.token, radix: 16)
        else {
            return []
        }
        var bits: [Bool] = []
        bits.reserveCapacity(bitCount)
        append(UInt64(magic), count: 16, to: &bits)
        append(token, count: 64, to: &bits)
        append(payload.markerRevision, count: 64, to: &bits)
        append(UInt64(payload.checksum), count: 32, to: &bits)
        return bits
    }

    private static func append(_ value: UInt64, count: Int, to bits: inout [Bool]) {
        for shift in (0..<count).reversed() {
            bits.append((value & (UInt64(1) << UInt64(shift))) != 0)
        }
    }

    private static func isCanonicalToken(_ value: String) -> Bool {
        value.utf8.count == 16 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

/// A measurement-only sink for exact desktop presentation evidence.
///
/// Implementations must return promptly and must not throw. SwiftSpice invokes
/// these methods after taking a single observer reference; it never retains an
/// observer-owned callback in the Metal or AppKit presentation state.
package protocol SpiceInteractionPresentationObserver: AnyObject, Sendable {
    func observeSelected(_ context: SpiceInteractionPresentationContext)
    func observeCommitted(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    )
    func observePresented(
        identity: SpiceInteractionFrameIdentity,
        at nanoseconds: UInt64
    )
    func observePresentationDropped(identity: SpiceInteractionFrameIdentity)
}

package enum SpiceInteractionHostClock {
    private static let anchor: (instant: ContinuousClock.Instant, nanoseconds: UInt64) = {
        let nanoseconds = monotonicNanoseconds()
        return (ContinuousClock().now, nanoseconds)
    }()

    private static func monotonicNanoseconds() -> UInt64 {
        var time = timespec()
        precondition(clock_gettime(CLOCK_MONOTONIC, &time) == 0)
        return UInt64(time.tv_sec) * 1_000_000_000 + UInt64(time.tv_nsec)
    }

    package static func nowNanoseconds() -> UInt64 {
        nanoseconds(for: ContinuousClock().now) ?? anchor.nanoseconds
    }

    package static func nanoseconds(for instant: ContinuousClock.Instant) -> UInt64? {
        let components = anchor.instant.duration(to: instant).components
        let (secondsNanoseconds, secondsOverflow) = components.seconds
            .multipliedReportingOverflow(by: 1_000_000_000)
        guard !secondsOverflow else { return nil }
        let fractionalNanoseconds = components.attoseconds / 1_000_000_000
        let (delta, deltaOverflow) = secondsNanoseconds
            .addingReportingOverflow(fractionalNanoseconds)
        guard !deltaOverflow else { return nil }
        if delta >= 0 {
            let (value, overflow) = anchor.nanoseconds.addingReportingOverflow(UInt64(delta))
            return overflow ? nil : value
        }
        guard delta != Int64.min else { return nil }
        let magnitude = UInt64(-delta)
        guard magnitude <= anchor.nanoseconds else { return nil }
        return anchor.nanoseconds - magnitude
    }

    /// Converts an actual drawable presentation timestamp using clock samples
    /// captured by the same callback. A process-lifetime Core Animation offset
    /// can drift after sleep, so it is deliberately not retained.
    package static func nanoseconds(
        forCoreAnimationTime mediaTime: TimeInterval,
        mediaTimeNow: TimeInterval,
        continuousNanosecondsNow: UInt64
    ) -> UInt64? {
        guard mediaTime.isFinite,
              mediaTimeNow.isFinite,
              // CAMetalDrawable uses zero when the drawable was not presented.
              mediaTime > 0,
              mediaTimeNow >= mediaTime
        else {
            return nil
        }
        let elapsedNanosecondsValue = (
            (mediaTimeNow - mediaTime) * 1_000_000_000
        ).rounded()
        guard elapsedNanosecondsValue.isFinite,
              elapsedNanosecondsValue >= 0,
              let elapsedNanoseconds = UInt64(exactly: elapsedNanosecondsValue),
              elapsedNanoseconds <= continuousNanosecondsNow
        else {
            return nil
        }
        return continuousNanosecondsNow - elapsedNanoseconds
    }
}

extension SpiceDesktopSnapshot {
    package var interactionFrameIdentity: SpiceInteractionFrameIdentity? {
        guard let revision = frame?.revision,
              let frameDeliverySequence
        else {
            return nil
        }
        return SpiceInteractionFrameIdentity(
            desktopGeneration: generation,
            displayChannelID: revision.surface.displayChannelID,
            surfaceID: revision.surface.surfaceID,
            surfaceGeneration: revision.surface.generation,
            frameRevision: revision.value,
            deliverySequence: frameDeliverySequence
        )
    }
}
