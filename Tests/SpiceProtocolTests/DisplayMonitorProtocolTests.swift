import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Display monitors configuration wire protocol")
struct DisplayMonitorProtocolTests {
    @Test func decodesMultipleHeadsAndServerDispatch() throws {
        let body = monitorBody(
            maximumAllowed: 4,
            heads: [
                (0, 10, 1_920, 1_080, 0, 0, 0),
                (2, 11, 1_280, 1_024, 1_920, 0, 7),
            ]
        )
        let expected = SpiceDisplayMonitorsConfiguration(
            maximumAllowed: 4,
            monitors: [
                .init(id: 0, surfaceID: 10, width: 1_920, height: 1_080,
                      x: 0, y: 0, flags: 0),
                .init(id: 2, surfaceID: 11, width: 1_280, height: 1_024,
                      x: 1_920, y: 0, flags: 7),
            ]
        )

        #expect(try SpiceDisplayMonitorCodec.decode(body) == expected)
        #expect(try SpiceServerMessageDecoder.decode(
            id: 317,
            body: body,
            channel: .display
        ) == .displayMonitorsConfiguration(expected))
    }

    @Test func acceptsEmptyNotificationButBoundsCounts() throws {
        #expect(try SpiceDisplayMonitorCodec.decode(monitorBody(
            maximumAllowed: 0,
            heads: []
        )).monitors.isEmpty)

        var tooMany = ByteWriter()
        tooMany.writeUInt16LE(257)
        tooMany.writeUInt16LE(0)
        #expect(throws: WireError.invalidSize(257)) {
            try SpiceDisplayMonitorCodec.decode(tooMany.data)
        }

        var invalidMaximum = ByteWriter()
        invalidMaximum.writeUInt16LE(0)
        invalidMaximum.writeUInt16LE(257)
        #expect(throws: WireError.invalidSize(257)) {
            try SpiceDisplayMonitorCodec.decode(invalidMaximum.data)
        }
        #expect(throws: WireError.invalidSize(2)) {
            try SpiceDisplayMonitorCodec.decode(monitorBody(
                maximumAllowed: 1,
                heads: [
                    (0, 0, 800, 600, 0, 0, 0),
                    (1, 0, 800, 600, 800, 0, 0),
                ]
            ))
        }
    }

    @Test func rejectsTruncationTrailingDuplicateAndInvalidGeometry() {
        let valid = monitorBody(
            maximumAllowed: 2,
            heads: [(0, 0, 800, 600, 0, 0, 0)]
        )
        #expect(throws: WireError.truncated(expected: 28, remaining: 27)) {
            try SpiceDisplayMonitorCodec.decode(Data(valid.dropLast()))
        }
        #expect(throws: WireError.trailingBytes(1)) {
            try SpiceDisplayMonitorCodec.decode(valid + Data([0]))
        }
        #expect(throws: WireError.unsupportedFeature(
            "duplicate Display monitor id 0"
        )) {
            try SpiceDisplayMonitorCodec.decode(monitorBody(
                maximumAllowed: 2,
                heads: [
                    (0, 0, 800, 600, 0, 0, 0),
                    (0, 1, 640, 480, 800, 0, 0),
                ]
            ))
        }
        #expect(throws: WireError.invalidSize(0)) {
            try SpiceDisplayMonitorCodec.decode(monitorBody(
                maximumAllowed: 1,
                heads: [(0, 0, 0, 600, 0, 0, 0)]
            ))
        }
        #expect(throws: WireError.integerOverflow) {
            try SpiceDisplayMonitorCodec.decode(monitorBody(
                maximumAllowed: 1,
                heads: [(0, 0, 2, 2, UInt32.max, 0, 0)]
            ))
        }
    }

    private typealias Head = (
        id: UInt32,
        surfaceID: UInt32,
        width: UInt32,
        height: UInt32,
        x: UInt32,
        y: UInt32,
        flags: UInt32
    )

    private func monitorBody(maximumAllowed: UInt16, heads: [Head]) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(UInt16(heads.count))
        writer.writeUInt16LE(maximumAllowed)
        for head in heads {
            writer.writeUInt32LE(head.id)
            writer.writeUInt32LE(head.surfaceID)
            writer.writeUInt32LE(head.width)
            writer.writeUInt32LE(head.height)
            writer.writeUInt32LE(head.x)
            writer.writeUInt32LE(head.y)
            writer.writeUInt32LE(head.flags)
        }
        return writer.data
    }
}
