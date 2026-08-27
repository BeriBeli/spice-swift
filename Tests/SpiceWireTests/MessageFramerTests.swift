import Foundation
import Testing
@testable import SpiceWire

@Suite("MessageFramer")
struct MessageFramerTests {
    @Test(arguments: [HeaderMode.full, .mini])
    func everySplitProducesSameMessage(mode: HeaderMode) throws {
        let body = Data([1, 2, 3, 4, 5])
        let wire = makeMessage(mode: mode, type: 103, body: body)

        for split in 0...wire.count {
            var framer = MessageFramer(mode: mode)
            try framer.append(wire.prefix(split))
            let message: FramedMessage?
            if split < wire.count {
                #expect(try framer.nextMessage() == nil)
                try framer.append(wire.suffix(wire.count - split))
                message = try framer.nextMessage()
            } else {
                message = try framer.nextMessage()
            }
            #expect(message?.type == 103)
            #expect(message?.body == body)
            #expect(framer.bufferedByteCount == 0)
        }
    }

    @Test func returnsMultipleMessagesFromOneAppend() throws {
        let first = makeMessage(mode: .mini, type: 3, body: Data([1]))
        let second = makeMessage(mode: .mini, type: 4, body: Data([2, 3]))
        var framer = MessageFramer(mode: .mini)

        try framer.append(first + second)
        #expect(try framer.nextMessage()?.type == 3)
        #expect(try framer.nextMessage()?.type == 4)
        #expect(try framer.nextMessage() == nil)
    }

    @Test func rejectsOversizedBodyBeforeBufferingIt() throws {
        var writer = ByteWriter()
        writer.writeUInt16LE(7)
        writer.writeUInt32LE(11)
        var framer = MessageFramer(
            mode: .mini,
            limits: WireLimits(maximumMessageSize: 10, maximumBufferedBytes: 100)
        )
        try framer.append(writer.data)

        #expect(throws: WireError.messageTooLarge(actual: 11, maximum: 10)) {
            try framer.nextMessage()
        }
    }

    @Test func oversizedHeaderFailureDoesNotConsumeTheBoundary() throws {
        var writer = ByteWriter()
        writer.writeUInt16LE(7)
        writer.writeUInt32LE(11)
        var framer = MessageFramer(
            mode: .mini,
            limits: WireLimits(maximumMessageSize: 10, maximumBufferedBytes: 100)
        )
        try framer.append(writer.data)
        let bufferedBefore = framer.bufferedByteCount

        for _ in 0..<2 {
            #expect(throws: WireError.messageTooLarge(actual: 11, maximum: 10)) {
                try framer.nextMessage()
            }
            #expect(framer.bufferedByteCount == bufferedBefore)
        }
    }

    @Test func invalidFullHeaderFailureDoesNotConsumeTheBoundary() throws {
        var writer = ByteWriter()
        writer.writeUInt64LE(42)
        writer.writeUInt16LE(7)
        writer.writeUInt32LE(2)
        writer.writeUInt32LE(3)
        writer.writeBytes(Data([0xaa, 0xbb]))
        var framer = MessageFramer(mode: .full)
        try framer.append(writer.data)
        let bufferedBefore = framer.bufferedByteCount

        for _ in 0..<2 {
            #expect(throws: WireError.invalidOffset(3)) {
                try framer.nextMessage()
            }
            #expect(framer.bufferedByteCount == bufferedBefore)
        }
    }

    @Test func rejectedAppendPreservesTheExistingPartialMessage() throws {
        let wire = makeMessage(mode: .mini, type: 9, body: Data([0xaa]))
        var framer = MessageFramer(
            mode: .mini,
            limits: WireLimits(maximumMessageSize: 8, maximumBufferedBytes: wire.count)
        )
        try framer.append(Data(wire.prefix(6)))
        let diagnosticsBefore = framer.diagnostics

        #expect(throws: WireError.messageTooLarge(actual: 8, maximum: 7)) {
            try framer.append(Data([0xaa, 0xbb]))
        }
        #expect(framer.bufferedByteCount == 6)
        #expect(framer.diagnostics == diagnosticsBefore)
        #expect(try framer.nextMessage() == nil)

        try framer.append(Data(wire.suffix(1)))
        let message = try #require(try framer.nextMessage())
        #expect(message.type == 9)
        #expect(message.body == Data([0xaa]))
        #expect(framer.bufferedByteCount == 0)
    }

    @Test(arguments: [HeaderMode.full, .mini])
    func incompleteMessageReturnsNilWithoutConsumingBytes(mode: HeaderMode) throws {
        let wire = makeMessage(mode: mode, type: 10, body: Data([1, 2, 3, 4]))
        let split = wire.count - 1
        var framer = MessageFramer(
            mode: mode,
            limits: WireLimits(maximumBufferedSegments: 2)
        )
        try framer.append(Data(wire.prefix(split)))

        #expect(try framer.nextMessage() == nil)
        #expect(try framer.nextMessage() == nil)
        #expect(framer.bufferedByteCount == split)

        try framer.append(Data(wire.suffix(1)))
        let message = try #require(try framer.nextMessage())
        #expect(message.type == 10)
        #expect(message.body == Data([1, 2, 3, 4]))
    }

    @Test(arguments: [HeaderMode.full, .mini])
    func emptyAndNonemptyPipelinedMessagesRemainBitExact(mode: HeaderMode) throws {
        let first = makeMessage(mode: mode, type: 11, body: Data())
        let secondBody = Data((0..<257).map { UInt8(truncatingIfNeeded: $0) })
        let second = makeMessage(mode: mode, type: 12, body: secondBody)
        var framer = MessageFramer(
            mode: mode,
            limits: WireLimits(maximumBufferedSegments: 1)
        )

        try framer.append(first + second)
        let empty = try #require(try framer.nextMessage())
        let payload = try #require(try framer.nextMessage())

        #expect(empty.type == 11)
        #expect(empty.body.isEmpty)
        #expect(payload.type == 12)
        #expect(payload.body == secondBody)
        #expect(try framer.nextMessage() == nil)
        #expect(framer.bufferedByteCount == 0)
    }

    @Test(arguments: [HeaderMode.full, .mini])
    func contiguousPhysicalMessageRetainsOneOwnerWithoutCopyingItsBody(
        mode: HeaderMode
    ) throws {
        let body = Data((0..<1_025).map { UInt8(truncatingIfNeeded: $0) })
        let wire = makeMessage(mode: mode, type: 13, body: body)
        var framer = MessageFramer(
            mode: mode,
            limits: WireLimits(maximumBufferedSegments: 1)
        )

        try framer.append(wire)
        #expect(framer.diagnostics.retainedOwnerCount == 1)
        #expect(framer.diagnostics.retainedOwnerBytes == wire.count)
        #expect(framer.diagnostics.bufferedSegmentCount == 1)

        let message = try #require(try framer.nextMessage())
        #expect(message.bodySlice.range == mode.wireSize..<wire.count)
        #expect(message.bodySlice.retainedOwnerByteCount == wire.count)
        #expect(message.body == body)
        #expect(framer.diagnostics.bodyCoalesces == 0)
        #expect(framer.diagnostics.bodyCopyBytes == 0)
        #expect(framer.diagnostics.queueCompactionBytes == 0)
        #expect(framer.diagnostics.retainedOwnerCount == 0)
        #expect(framer.diagnostics.retainedOwnerBytes == 0)
        #expect(framer.diagnostics.bufferedSegmentCount == 0)
    }

    @Test(arguments: [HeaderMode.full, .mini])
    func fragmentedPhysicalBodyIsCoalescedExactlyOnce(mode: HeaderMode) throws {
        let body = Data((0..<257).map { UInt8(truncatingIfNeeded: $0 &* 17) })
        let wire = makeMessage(mode: mode, type: 14, body: body)
        let firstEnd = mode.wireSize + 1
        let secondEnd = firstEnd + 31
        var framer = MessageFramer(
            mode: mode,
            limits: WireLimits(maximumBufferedSegments: 3)
        )

        try framer.append(Data(wire[..<firstEnd]))
        try framer.append(Data(wire[firstEnd..<secondEnd]))
        try framer.append(Data(wire[secondEnd...]))
        #expect(framer.diagnostics.retainedOwnerCount == 3)
        #expect(framer.diagnostics.retainedOwnerBytes == wire.count)

        let message = try #require(try framer.nextMessage())
        #expect(message.body == body)
        #expect(message.bodySlice.range == 0..<body.count)
        #expect(message.bodySlice.retainedOwnerByteCount == body.count)
        #expect(framer.diagnostics.bodyCoalesces == 1)
        #expect(framer.diagnostics.bodyCopyBytes == UInt64(body.count))
        #expect(framer.diagnostics.queueCompactionBytes == 0)
        #expect(framer.diagnostics.retainedOwnerCount == 0)
        #expect(framer.diagnostics.retainedOwnerBytes == 0)
        #expect(framer.diagnostics.bufferedSegmentCount == 0)
    }

    @Test func largePipelinedAppendNeverCompactsOrCopiesMessageBodies() throws {
        let messageCount = 2_048
        let wires = (0..<messageCount).map { index in
            makeMessage(
                mode: .mini,
                type: UInt16(100 + index % 10),
                body: Data([UInt8(truncatingIfNeeded: index)])
            )
        }
        let pipeline = wires.reduce(into: Data()) { $0.append($1) }
        var framer = MessageFramer(
            mode: .mini,
            limits: WireLimits(maximumBufferedSegments: 1)
        )

        try framer.append(pipeline)
        for index in 0..<messageCount {
            let message = try #require(try framer.nextMessage())
            #expect(message.type == UInt16(100 + index % 10))
            #expect(message.body == Data([UInt8(truncatingIfNeeded: index)]))
            if index < messageCount - 1 {
                #expect(framer.diagnostics.retainedOwnerCount == 1)
                #expect(framer.diagnostics.bufferedSegmentCount == 1)
                #expect(framer.diagnostics.retainedOwnerBytes == pipeline.count)
            }
        }

        #expect(framer.diagnostics.bodyCoalesces == 0)
        #expect(framer.diagnostics.bodyCopyBytes == 0)
        #expect(framer.diagnostics.queueCompactionBytes == 0)
        #expect(framer.diagnostics.retainedOwnerCount == 0)
        #expect(framer.diagnostics.retainedOwnerBytes == 0)
        #expect(framer.diagnostics.bufferedSegmentCount == 0)
    }

    @Test func bytewiseSplitPipelineCoalescesEachBodyOnceWithoutQueueCompaction() throws {
        let messageCount = 256
        let bodySize = 17
        var pipeline = Data()
        var expectedBodies: [Data] = []
        expectedBodies.reserveCapacity(messageCount)
        for index in 0..<messageCount {
            let body = Data((0..<bodySize).map {
                UInt8(truncatingIfNeeded: index &+ $0)
            })
            expectedBodies.append(body)
            pipeline.append(makeMessage(mode: .mini, type: 15, body: body))
        }
        var framer = MessageFramer(
            mode: .mini,
            limits: WireLimits(
                maximumBufferedSegments: HeaderMode.mini.wireSize + bodySize
            )
        )
        var received = 0

        for byte in pipeline {
            try framer.append(Data([byte]))
            if let message = try framer.nextMessage() {
                #expect(message.body == expectedBodies[received])
                received += 1
            }
        }

        #expect(received == messageCount)
        #expect(framer.diagnostics.bodyCoalesces == UInt64(messageCount))
        #expect(framer.diagnostics.bodyCopyBytes == UInt64(messageCount * bodySize))
        #expect(framer.diagnostics.queueCompactionBytes == 0)
        #expect(framer.diagnostics.retainedOwnerCount == 0)
        #expect(framer.diagnostics.retainedOwnerBytes == 0)
        #expect(framer.diagnostics.bufferedSegmentCount == 0)
    }

    @Test func liveSegmentLimitRejectsAtomicallyAndReusesConsumedCapacity() throws {
        let firstWire = makeMessage(mode: .mini, type: 20, body: Data([0xaa]))
        let secondBody = Data([0xbb, 0xcc])
        let secondWire = makeMessage(mode: .mini, type: 21, body: secondBody)
        var framer = MessageFramer(
            mode: .mini,
            limits: WireLimits(
                maximumMessageSize: 32,
                maximumBufferedBytes: 64,
                maximumBufferedSegments: 3
            )
        )

        try framer.append(firstWire)
        try framer.append(Data(secondWire.prefix(1)))
        try framer.append(Data(secondWire.dropFirst().prefix(1)))
        let bufferedBefore = framer.bufferedByteCount
        let diagnosticsBefore = framer.diagnostics

        #expect(throws: WireError.tooManySegments(actual: 4, maximum: 3)) {
            try framer.append(Data([secondWire[secondWire.startIndex + 2]]))
        }
        #expect(framer.bufferedByteCount == bufferedBefore)
        #expect(framer.diagnostics == diagnosticsBefore)

        var first = try framer.nextMessage()
        #expect(first?.type == 20)
        #expect(first?.body == Data([0xaa]))
        first = nil
        #expect(framer.diagnostics.retainedOwnerCount == 2)
        #expect(framer.diagnostics.bufferedSegmentCount == 2)

        // The consumed dead slot does not count against the live limit.
        try framer.append(Data(secondWire.dropFirst(2)))
        let second = try #require(try framer.nextMessage())
        #expect(second.type == 21)
        #expect(second.body == secondBody)
        #expect(framer.diagnostics.bodyCoalesces == 0)
        #expect(framer.diagnostics.bodyCopyBytes == 0)
        #expect(framer.diagnostics.queueCompactionBytes == 0)
        #expect(framer.bufferedByteCount == 0)
        #expect(framer.diagnostics.retainedOwnerCount == 0)
        #expect(framer.diagnostics.bufferedSegmentCount == 0)
    }

    @Test func consumedSegmentsReleaseTheirOwnersBeforeTheRemainingQueueDrains() throws {
        let messageCount = 32
        var lifetimeProbes: [WeakWireOwner] = []
        var framer = MessageFramer(mode: .mini)

        for index in 0..<messageCount {
            var owner: OwnedBytes? = OwnedBytes(makeMessage(
                mode: .mini,
                type: UInt16(200 + index),
                body: Data([UInt8(truncatingIfNeeded: index)])
            ))
            let probe = WeakWireOwner(try #require(owner).ownerLifetimeToken)
            lifetimeProbes.append(probe)
            try framer.append(try #require(owner))
            owner = nil
        }
        #expect(lifetimeProbes.allSatisfy { $0.value != nil })

        // Keep the queue nonempty after all complete messages are consumed.
        // A head-index queue must release dead slots without waiting for its
        // reference-array compaction threshold.
        try framer.append(Data([0xff]))
        for index in 0..<messageCount {
            var message = try framer.nextMessage()
            #expect(message?.type == UInt16(200 + index))
            message = nil
        }

        #expect(lifetimeProbes.allSatisfy { $0.value == nil })
        #expect(framer.bufferedByteCount == 1)
        #expect(framer.diagnostics.retainedOwnerCount == 1)
        #expect(framer.diagnostics.retainedOwnerBytes == 1)
        #expect(framer.diagnostics.bufferedSegmentCount == 1)
        #expect(framer.diagnostics.queueCompactionBytes == 0)
    }

    private func makeMessage(mode: HeaderMode, type: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        if mode == .full {
            writer.writeUInt64LE(1)
        }
        writer.writeUInt16LE(type)
        writer.writeUInt32LE(UInt32(body.count))
        if mode == .full {
            writer.writeUInt32LE(0)
        }
        writer.writeBytes(body)
        return writer.data
    }

}

private final class WeakWireOwner {
    private(set) weak var value: AnyObject?

    init(_ value: AnyObject) {
        self.value = value
    }
}
