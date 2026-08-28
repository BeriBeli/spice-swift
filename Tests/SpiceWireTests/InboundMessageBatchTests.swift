import Foundation
import Testing
@testable import SpiceWire

@Suite("Full-header inbound message batches")
struct InboundMessageBatchTests {
    private static let messageListType: UInt16 = 8

    @Test func listOnlyUsesListOrderAndOnePhysicalAcknowledgment() throws {
        let fixture = Self.makeSubmessageBody(
            main: Data(),
            submessages: [
                (type: 201, body: Data([0x11, 0x12])),
                (type: 202, body: Data([0x21, 0x22, 0x23])),
            ],
            listOrder: [1, 0]
        )
        let frame = try Self.parseFullFrame(
            serial: 0x0102_0304_0506_0708,
            type: Self.messageListType,
            body: fixture.body,
            subListOffset: 0
        )

        let batch = try frame.messageBatch()

        #expect(batch.serial == 0x0102_0304_0506_0708)
        #expect(batch.physicalType == Self.messageListType)
        #expect(batch.physicalBodySize == fixture.body.count)
        #expect(batch.acknowledgmentCount == 1)
        #expect(batch.logicalMessages.map(\.type) == [202, 201])
        #expect(batch.logicalMessages.map(\.bodyRange) == [
            fixture.payloadRanges[1],
            fixture.payloadRanges[0],
        ])
        #expect(batch.logicalMessages.map(\.index) == [0, 1])
        #expect(batch.logicalMessages.map(\.isLastInPhysicalMessage) == [false, true])
        #expect(batch.body(for: batch.logicalMessages[0]) == Data([0x21, 0x22, 0x23]))
        #expect(batch.body(for: batch.logicalMessages[1]) == Data([0x11, 0x12]))
    }

    @Test func mainMessageExecutesAfterSubmessagesAndUsesOnlyItsPrefix() throws {
        let main = Data([0xa0, 0xa1, 0xa2])
        let fixture = Self.makeSubmessageBody(
            main: main,
            submessages: [
                (type: 301, body: Data([0x31])),
                (type: 302, body: Data([0x32, 0x33])),
            ],
            listOrder: [0, 1]
        )
        let frame = try Self.parseFullFrame(
            serial: 77,
            type: 103,
            body: fixture.body,
            subListOffset: UInt32(main.count)
        )

        let batch = try frame.messageBatch()

        #expect(batch.logicalMessages.map(\.type) == [301, 302, 103])
        #expect(batch.logicalMessages.map(\.bodyRange) == [
            fixture.payloadRanges[0],
            fixture.payloadRanges[1],
            0..<main.count,
        ])
        #expect(batch.logicalMessages.map { batch.body(for: $0) } == [
            Data([0x31]),
            Data([0x32, 0x33]),
            main,
        ])
        #expect(batch.logicalMessages.map(\.index) == [0, 1, 2])
        #expect(batch.logicalMessages.map(\.isLastInPhysicalMessage) == [false, false, true])
        #expect(batch.acknowledgmentCount == 1)
    }

    @Test func zeroSubmessageListStillRepresentsOnePhysicalAcknowledgment() throws {
        let listOnly = try Self.parseFullFrame(
            serial: 9,
            type: Self.messageListType,
            body: Self.littleEndian(UInt16(0)),
            subListOffset: 0
        ).messageBatch()

        #expect(listOnly.logicalMessages.isEmpty)
        #expect(listOnly.acknowledgmentCount == 1)

        let main = Data([0xde, 0xad])
        let mainAndEmptyList = try Self.parseFullFrame(
            serial: 10,
            type: 104,
            body: main + Self.littleEndian(UInt16(0)),
            subListOffset: UInt32(main.count)
        ).messageBatch()

        #expect(mainAndEmptyList.logicalMessages.count == 1)
        #expect(mainAndEmptyList.logicalMessages[0].type == 104)
        #expect(mainAndEmptyList.logicalMessages[0].bodyRange == 0..<main.count)
        #expect(mainAndEmptyList.body(for: mainAndEmptyList.logicalMessages[0]) == main)
        #expect(mainAndEmptyList.logicalMessages[0].isLastInPhysicalMessage)
        #expect(mainAndEmptyList.acknowledgmentCount == 1)
    }

    @Test func plainFullAndMiniMessagesRemainSingleLogicalBatches() throws {
        let body = Data([1, 2, 3, 4])
        let full = try Self.parseFullFrame(
            serial: 42,
            type: 105,
            body: body,
            subListOffset: 0
        ).messageBatch()

        #expect(full.logicalMessages.count == 1)
        #expect(full.logicalMessages[0].type == 105)
        #expect(full.logicalMessages[0].bodyRange == 0..<body.count)
        #expect(full.body(for: full.logicalMessages[0]) == body)
        #expect(full.acknowledgmentCount == 1)

        var framer = MessageFramer(mode: .mini)
        try framer.append(Self.makeWire(mode: .mini, serial: nil, type: 106, body: body))
        let maybeMiniFrame = try framer.nextMessage()
        let miniFrame = try #require(maybeMiniFrame)
        let mini = try miniFrame.messageBatch()

        #expect(mini.serial == nil)
        #expect(mini.logicalMessages.count == 1)
        #expect(mini.logicalMessages[0].type == 106)
        #expect(mini.logicalMessages[0].bodyRange == 0..<body.count)
        #expect(mini.body(for: mini.logicalMessages[0]) == body)
        #expect(mini.acknowledgmentCount == 1)
    }

    @Test func everyPhysicalWireSplitProducesTheSameBatch() throws {
        let main = Data([0xa1, 0xa2])
        let fixture = Self.makeSubmessageBody(
            main: main,
            submessages: [
                (type: 401, body: Data([1, 2, 3])),
                (type: 402, body: Data()),
            ],
            listOrder: [1, 0]
        )
        let wire = Self.makeWire(
            mode: .full,
            serial: 123,
            type: 107,
            body: fixture.body,
            subListOffset: UInt32(main.count)
        )

        for split in 0...wire.count {
            var framer = MessageFramer(mode: .full)
            try framer.append(Data(wire.prefix(split)))
            if split < wire.count {
                #expect(try framer.nextBatch() == nil, "split \(split) completed too early")
                try framer.append(Data(wire.suffix(wire.count - split)))
            }

            let maybeBatch = try framer.nextBatch()
            let batch = try #require(maybeBatch, "split \(split) did not complete")
            #expect(batch.serial == 123)
            #expect(batch.logicalMessages.map(\.type) == [402, 401, 107])
            #expect(batch.logicalMessages.map { batch.body(for: $0) } == [
                Data(),
                Data([1, 2, 3]),
                main,
            ])
            #expect(batch.acknowledgmentCount == 1)
            #expect(framer.bufferedByteCount == 0)
        }
    }

    @Test func acceptsTheDefaultMaximumSubmessageCount() throws {
        let count = 4_096
        let fixture = Self.makeSubmessageBody(
            main: Data(),
            submessages: (0..<count).map { index in
                (type: UInt16(500 + index % 10), body: Data())
            },
            listOrder: Array(0..<count)
        )
        let batch = try Self.parseFullFrame(
            serial: 1,
            type: Self.messageListType,
            body: fixture.body,
            subListOffset: 0
        ).messageBatch()

        #expect(batch.logicalMessages.count == count)
        #expect(batch.logicalMessages.first?.index == 0)
        #expect(batch.logicalMessages.last?.index == count - 1)
        #expect(batch.logicalMessages.last?.isLastInPhysicalMessage == true)
        #expect(batch.acknowledgmentCount == 1)
    }

    @Test func rejectsInvalidMaximumAndCountBeyondConfiguredLimit() throws {
        let fixture = Self.makeSubmessageBody(
            main: Data(),
            submessages: [
                (type: 1, body: Data()),
                (type: 2, body: Data()),
                (type: 3, body: Data()),
            ],
            listOrder: [0, 1, 2]
        )
        let frame = try Self.parseFullFrame(
            serial: 1,
            type: Self.messageListType,
            body: fixture.body,
            subListOffset: 0
        )

        #expect(throws: WireError.self) {
            try frame.messageBatch(maximumSubmessages: 2)
        }
        #expect(throws: WireError.self) {
            try frame.messageBatch(maximumSubmessages: -1)
        }
    }

    @Test(arguments: malformedBodies())
    func rejectsMalformedListsBeforeReturningAnyLogicalMessage(malformed: MalformedFixture) throws {
        let frame = try Self.parseFullFrame(
            serial: 88,
            type: malformed.physicalType,
            body: malformed.body,
            subListOffset: malformed.subListOffset
        )

        #expect(throws: WireError.self, "expected rejection for \(malformed.name)") {
            try frame.messageBatch()
        }
    }

    @Test func framerRejectsSubListOffsetBeyondPhysicalBody() throws {
        let wire = Self.makeWire(
            mode: .full,
            serial: 5,
            type: 109,
            body: Data([0, 0]),
            subListOffset: 3
        )
        var framer = MessageFramer(mode: .full)
        try framer.append(wire)

        #expect(throws: WireError.invalidOffset(3)) {
            try framer.nextMessage()
        }
    }
}

extension InboundMessageBatchTests {
    struct SubmessageFixture {
        let body: Data
        let payloadRanges: [Range<Int>]
    }

    struct MalformedFixture: Sendable, CustomTestStringConvertible {
        let name: String
        let physicalType: UInt16
        let body: Data
        let subListOffset: UInt32

        var testDescription: String { name }
    }

    static func malformedBodies() -> [MalformedFixture] {
        let list = messageListType
        return [
            MalformedFixture(
                name: "truncated list count",
                physicalType: list,
                body: Data([1]),
                subListOffset: 0
            ),
            MalformedFixture(
                name: "truncated offset table",
                physicalType: list,
                body: littleEndian(UInt16(2)) + littleEndian(UInt32(10)),
                subListOffset: 0
            ),
            MalformedFixture(
                name: "submessage offset at body end",
                physicalType: list,
                body: littleEndian(UInt16(1)) + littleEndian(UInt32(6)),
                subListOffset: 0
            ),
            MalformedFixture(
                name: "submessage header truncated",
                physicalType: list,
                body: littleEndian(UInt16(1)) + littleEndian(UInt32(6)) + Data(repeating: 0, count: 5),
                subListOffset: 0
            ),
            MalformedFixture(
                name: "submessage payload extends beyond body",
                physicalType: list,
                body: littleEndian(UInt16(1))
                    + littleEndian(UInt32(6))
                    + littleEndian(UInt16(7))
                    + littleEndian(UInt32.max),
                subListOffset: 0
            ),
            MalformedFixture(
                name: "maximum UInt32 submessage offset",
                physicalType: list,
                body: littleEndian(UInt16(1)) + littleEndian(UInt32.max),
                subListOffset: 0
            ),
            MalformedFixture(
                name: "offset points to list count metadata",
                physicalType: list,
                body: littleEndian(UInt16(1)) + littleEndian(UInt32(0)) + Data(repeating: 0, count: 6),
                subListOffset: 0
            ),
            MalformedFixture(
                name: "offset points inside list offset table",
                physicalType: list,
                body: littleEndian(UInt16(1)) + littleEndian(UInt32(3)) + Data(repeating: 0, count: 6),
                subListOffset: 0
            ),
            duplicateOffsetsFixture(),
            overlappingSubmessagesFixture(),
            submessageOverlapsListMetadataFixture(),
            submessagePointsIntoMainBodyFixture(),
            MalformedFixture(
                name: "non-list sub-list offset at body end has no list count",
                physicalType: 110,
                body: Data([0xaa, 0xbb]),
                subListOffset: 2
            ),
            MalformedFixture(
                name: "count bomb is rejected before table traversal",
                physicalType: list,
                body: littleEndian(UInt16.max),
                subListOffset: 0
            ),
        ]
    }

    static func duplicateOffsetsFixture() -> MalformedFixture {
        let metadataSize = 2 + 2 * 4
        let offset = UInt32(metadataSize)
        let body = littleEndian(UInt16(2))
            + littleEndian(offset)
            + littleEndian(offset)
            + submessage(type: 1, body: Data([1]))
        return MalformedFixture(
            name: "duplicate submessage offsets",
            physicalType: messageListType,
            body: body,
            subListOffset: 0
        )
    }

    static func overlappingSubmessagesFixture() -> MalformedFixture {
        let metadataSize = 2 + 2 * 4
        let firstOffset = UInt32(metadataSize)
        let secondOffset = firstOffset + 7
        let first = submessage(type: 1, body: Data(repeating: 0xaa, count: 8))
        let body = littleEndian(UInt16(2))
            + littleEndian(firstOffset)
            + littleEndian(secondOffset)
            + first
            + Data(repeating: 0, count: 6)
        return MalformedFixture(
            name: "second submessage header overlaps first payload",
            physicalType: messageListType,
            body: body,
            subListOffset: 0
        )
    }

    static func submessageOverlapsListMetadataFixture() -> MalformedFixture {
        var prefix = submessage(type: 1, body: Data(repeating: 0xcc, count: 8))
        let listOffset = prefix.count - 2
        prefix += littleEndian(UInt16(1))
        prefix += littleEndian(UInt32(0))
        return MalformedFixture(
            name: "submessage payload overlaps list metadata",
            physicalType: 111,
            body: prefix,
            subListOffset: UInt32(listOffset)
        )
    }

    static func submessagePointsIntoMainBodyFixture() -> MalformedFixture {
        let main = submessage(type: 1, body: Data([0xdd]))
        let list = littleEndian(UInt16(1)) + littleEndian(UInt32(0))
        return MalformedFixture(
            name: "submessage points into main body prefix",
            physicalType: 112,
            body: main + list,
            subListOffset: UInt32(main.count)
        )
    }

    static func makeSubmessageBody(
        main: Data,
        submessages: [(type: UInt16, body: Data)],
        listOrder: [Int]
    ) -> SubmessageFixture {
        precondition(listOrder.count == submessages.count)
        precondition(Set(listOrder) == Set(submessages.indices))

        let metadataSize = 2 + submessages.count * 4
        var nextOffset = main.count + metadataSize
        var payloadRanges: [Range<Int>] = []
        var records = Data()
        for message in submessages {
            let payloadStart = nextOffset + 6
            payloadRanges.append(payloadStart..<(payloadStart + message.body.count))
            let record = submessage(type: message.type, body: message.body)
            records += record
            nextOffset += record.count
        }

        var metadata = littleEndian(UInt16(submessages.count))
        for index in listOrder {
            metadata += littleEndian(UInt32(payloadRanges[index].lowerBound - 6))
        }
        return SubmessageFixture(body: main + metadata + records, payloadRanges: payloadRanges)
    }

    static func submessage(type: UInt16, body: Data) -> Data {
        littleEndian(type) + littleEndian(UInt32(body.count)) + body
    }

    static func parseFullFrame(
        serial: UInt64,
        type: UInt16,
        body: Data,
        subListOffset: UInt32
    ) throws -> FramedMessage {
        var framer = MessageFramer(mode: .full)
        try framer.append(makeWire(
            mode: .full,
            serial: serial,
            type: type,
            body: body,
            subListOffset: subListOffset
        ))
        let message = try framer.nextMessage()
        return try #require(message)
    }

    static func makeWire(
        mode: HeaderMode,
        serial: UInt64?,
        type: UInt16,
        body: Data,
        subListOffset: UInt32 = 0
    ) -> Data {
        var writer = ByteWriter()
        if mode == .full {
            writer.writeUInt64LE(serial ?? 0)
        }
        writer.writeUInt16LE(type)
        writer.writeUInt32LE(UInt32(body.count))
        if mode == .full {
            writer.writeUInt32LE(subListOffset)
        }
        writer.writeBytes(body)
        return writer.data
    }

    static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
