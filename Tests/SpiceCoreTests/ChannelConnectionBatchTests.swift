import Foundation
import SpiceTestSupport
import Testing
@testable import SpiceCore
@testable import SpiceWire

@Suite("ChannelConnection physical message batches")
struct ChannelConnectionBatchTests {
    @Test func dispatchesSubmessagesInListOrderAndAcknowledgesThePhysicalMessageOnce() async throws {
        let listBody = makeListBody(
            submessages: [
                (type: 601, body: Data([0x61])),
                (type: 602, body: Data([0x62, 0x63])),
            ],
            listOrder: [1, 0]
        )
        let transport = FakeTransport(inbound: [
            .success(fullMessage(serial: 10, type: 8, body: listBody, subListOffset: 0)),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .full
        )
        await connection.configureAcknowledgments(generation: 7, window: 1)

        let first = try await connection.receive()
        #expect(first.serial == 10)
        #expect(first.type == 602)
        #expect(first.body == Data([0x62, 0x63]))
        #expect(first.acknowledgmentCount == 0)
        try await connection.acknowledgeLastDelivered()
        #expect(await transport.outbound.isEmpty)

        let second = try await connection.receive()
        #expect(second.serial == 10)
        #expect(second.type == 601)
        #expect(second.body == Data([0x61]))
        #expect(second.acknowledgmentCount == 1)
        try await connection.acknowledgeLastDelivered()

        let outbound = await transport.outbound
        #expect(outbound.count == 1)
        #expect(try fullMessageType(outbound[0]) == 2)
    }

    @Test func dispatchesSubmessagesBeforeTheMainPrefixAndOnlyTheMainCompletesAck() async throws {
        let main = Data([0xa0, 0xa1])
        let listBody = makeListBody(
            main: main,
            submessages: [
                (type: 701, body: Data([0x71])),
                (type: 702, body: Data([0x72])),
            ],
            listOrder: [1, 0]
        )
        let transport = FakeTransport(inbound: [
            .success(fullMessage(
                serial: 11,
                type: 700,
                body: listBody,
                subListOffset: UInt32(main.count)
            )),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 2, id: 1),
            transport: transport,
            headerMode: .full
        )
        await connection.configureAcknowledgments(generation: 8, window: 1)

        var delivered: [(UInt16, Data, Int)] = []
        for _ in 0..<3 {
            let message = try await connection.receive()
            delivered.append((message.type, message.body, message.acknowledgmentCount))
            try await connection.acknowledgeLastDelivered()
        }

        #expect(delivered.map(\.0) == [702, 701, 700])
        #expect(delivered.map(\.1) == [Data([0x72]), Data([0x71]), main])
        #expect(delivered.map(\.2) == [0, 0, 1])
        let outbound = await transport.outbound
        #expect(outbound.count == 1)
        #expect(try fullMessageType(outbound[0]) == 2)
    }

    @Test func emptyListAcknowledgesOnceWithoutInventingALogicalMessage() async throws {
        let emptyList = fullMessage(
            serial: 20,
            type: 8,
            body: littleEndian(UInt16(0)),
            subListOffset: 0
        )
        let following = fullMessage(
            serial: 21,
            type: 801,
            body: Data([0x81]),
            subListOffset: 0
        )
        let transport = FakeTransport(inbound: [.success(emptyList + following)])
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 2, id: 2),
            transport: transport,
            headerMode: .full
        )
        await connection.configureAcknowledgments(generation: 9, window: 1)

        let delivered = try await connection.receive()
        #expect(delivered.serial == 21)
        #expect(delivered.type == 801)
        #expect(delivered.body == Data([0x81]))

        var outbound = await transport.outbound
        #expect(outbound.count == 1)
        #expect(try fullMessageType(outbound[0]) == 2)

        try await connection.acknowledgeLastDelivered()
        outbound = await transport.outbound
        #expect(outbound.count == 2)
        #expect(try outbound.allSatisfy { try fullMessageType($0) == 2 })
    }
}

private func makeListBody(
    main: Data = Data(),
    submessages: [(type: UInt16, body: Data)],
    listOrder: [Int]
) -> Data {
    precondition(submessages.count == listOrder.count)
    precondition(Set(listOrder) == Set(submessages.indices))

    var records: [Data] = []
    records.reserveCapacity(submessages.count)
    var offsets: [UInt32] = []
    offsets.reserveCapacity(submessages.count)
    var nextOffset = main.count + 2 + submessages.count * 4
    for message in submessages {
        var record = littleEndian(message.type)
        record += littleEndian(UInt32(message.body.count))
        record += message.body
        records.append(record)
        offsets.append(UInt32(nextOffset))
        nextOffset += record.count
    }

    var body = main + littleEndian(UInt16(submessages.count))
    for index in listOrder {
        body += littleEndian(offsets[index])
    }
    for record in records {
        body += record
    }
    return body
}

private func fullMessage(
    serial: UInt64,
    type: UInt16,
    body: Data,
    subListOffset: UInt32
) -> Data {
    var writer = ByteWriter()
    writer.writeUInt64LE(serial)
    writer.writeUInt16LE(type)
    writer.writeUInt32LE(UInt32(body.count))
    writer.writeUInt32LE(subListOffset)
    writer.writeBytes(body)
    return writer.data
}

private func fullMessageType(_ data: Data) throws -> UInt16 {
    var reader = try ByteReader(data)
    _ = try reader.readUInt64LE()
    return try reader.readUInt16LE()
}

private func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}
