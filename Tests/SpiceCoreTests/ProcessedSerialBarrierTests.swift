import Foundation
import SpiceTestSupport
import SpiceTransport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceWire

@Suite("Processed serial barriers")
struct ProcessedSerialBarrierTests {
    @Test func receivingAFullMessageDoesNotAdvanceBeforeExplicitCompletion() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 2, id: 0)
        let transport = FakeTransport(inbound: [
            .success(aip11FullMessage(serial: 42, type: 901, body: Data([1]))),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .full,
            serialBarrier: barrier
        )

        let message = try await connection.receive()
        #expect(message.serial == 42)
        let (probe, waiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 42)]
        )
        await aip11ExpectWaiting(probe)

        try await connection.completeLastDelivered()
        await waiter.value
        #expect(await probe.state == .succeeded)
    }

    @Test func fullBatchAdvancesOnlyAfterEveryLogicalMessageCompletes() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 2, id: 1)
        let main = Data([0xa0, 0xa1])
        let body = aip11ListBody(
            main: main,
            submessages: [
                (type: 911, body: Data([0x11])),
                (type: 912, body: Data([0x12])),
            ],
            listOrder: [1, 0]
        )
        let transport = FakeTransport(inbound: [
            .success(aip11FullMessage(
                serial: 50,
                type: 910,
                body: body,
                subListOffset: UInt32(main.count)
            )),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .full,
            serialBarrier: barrier
        )
        let (probe, waiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 50)]
        )

        let first = try await connection.receive()
        #expect(first.type == 912)
        try await connection.completeLastDelivered()
        await aip11ExpectWaiting(probe)

        let second = try await connection.receive()
        #expect(second.type == 911)
        try await connection.completeLastDelivered()
        await aip11ExpectWaiting(probe)

        let physicalMain = try await connection.receive()
        #expect(physicalMain.type == 910)
        #expect(physicalMain.body == main)
        await aip11ExpectWaiting(probe)

        try await connection.completeLastDelivered()
        await waiter.value
        #expect(await probe.state == .succeeded)
    }

    @Test func implicitMiniSerialAdvancesAfterEachPhysicalCompletion() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 5, id: 0)
        let transport = FakeTransport(inbound: [
            .success(
                aip11MiniMessage(type: 920, body: Data([1]))
                    + aip11MiniMessage(type: 921, body: Data([2]))
            ),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini,
            serialBarrier: barrier
        )

        _ = try await connection.receive()
        let (firstProbe, firstWaiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 1)]
        )
        await aip11ExpectWaiting(firstProbe)
        try await connection.completeLastDelivered()
        await firstWaiter.value
        #expect(await firstProbe.state == .succeeded)

        _ = try await connection.receive()
        let (secondProbe, secondWaiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 2)]
        )
        await aip11ExpectWaiting(secondProbe)
        try await connection.completeLastDelivered()
        await secondWaiter.value
        #expect(await secondProbe.state == .succeeded)
    }

    @Test func realPlaybackHandlerFailureTerminatesAnExistingWaiter() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 5, id: 1)
        let invalidMode = aip11LE(UInt32(100)) + aip11LE(UInt16(3))
        let transport = FakeTransport(inbound: [
            .success(aip11MiniMessage(type: 102, body: invalidMode)),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let channel = PlaybackChannel(
            connection: connection,
            multimediaClock: MultimediaClock()
        )
        let (probe, waiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 1)]
        )
        await aip11ExpectWaiting(probe)

        await #expect(throws: ChannelError.protocolViolation("unsupported Playback mode 3")) {
            try await channel.processNext()
        }
        await waiter.value
        #expect(await probe.failed)
    }

    @Test func transportFailureTerminatesExistingAndFutureWaiters() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 2, id: 2)
        let transport = FakeTransport(inbound: [
            .failure(.connectionFailed("fixture failure")),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let (probe, waiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 1)]
        )
        await aip11ExpectWaiting(probe)

        await #expect(throws: ChannelError.transport(.connectionFailed("fixture failure"))) {
            try await connection.receive()
        }
        await waiter.value
        #expect(await probe.failed)
        await #expect(throws: ChannelError.self) {
            try await connection.waitUntilProcessed([.init(key: key, serial: 1)])
        }
    }

    @Test func closeTerminatesWaiterAndIsIdempotent() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 2, id: 3)
        let transport = FakeTransport()
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let (probe, waiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 1)]
        )
        await aip11ExpectWaiting(probe)

        await connection.close()
        await connection.close()
        await waiter.value
        #expect(await probe.failed)
        #expect(await transport.isClosed)
    }

    @Test func cancellingAWaitDoesNotPoisonTheChannelOrLeakItsContinuation() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 2, id: 4)
        let transport = FakeTransport(inbound: [
            .success(aip11MiniMessage(type: 930, body: Data())),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let cancelledWaiter = Task {
            try await connection.waitUntilProcessed([.init(key: key, serial: 1)])
        }
        await Task.yield()
        cancelledWaiter.cancel()
        await #expect(throws: ChannelError.transport(.cancelled)) {
            try await cancelledWaiter.value
        }

        _ = try await connection.receive()
        try await connection.completeLastDelivered()
        try await connection.waitUntilProcessed([.init(key: key, serial: 1)])
    }

    @Test func cancellingARealChannelRunTerminatesItsProcessedSerialWaiters() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 5, id: 9)
        let transport = AIP11CancellationTransport()
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let channel = PlaybackChannel(
            connection: connection,
            multimediaClock: MultimediaClock()
        )
        let (probe, waiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 1)]
        )
        let runTask = Task {
            try await channel.run { _ in }
        }
        for _ in 0..<100 where !(await transport.readStarted) {
            await Task.yield()
        }
        #expect(await transport.readStarted)
        await aip11ExpectWaiting(probe)

        runTask.cancel()
        await #expect(throws: ChannelError.transport(.cancelled)) {
            try await runTask.value
        }
        await waiter.value
        #expect(await probe.failed)
    }

    @Test func cancellingSupersededRunDoesNotTerminateReplacementConnection() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 5, id: 10)
        let sourceTransport = AIP11CancellationTransport()
        try await sourceTransport.connect()
        let sourceConnection = ChannelConnection(
            key: key,
            transport: sourceTransport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let channel = PlaybackChannel(
            connection: sourceConnection,
            multimediaClock: MultimediaClock()
        )
        let sourceRun = Task {
            try await channel.run { _ in }
        }
        for _ in 0..<100 where !(await sourceTransport.readStarted) {
            await Task.yield()
        }
        #expect(await sourceTransport.readStarted)

        let modeBody = aip11LE(UInt32(123)) + aip11LE(UInt16(1))
        let replacementTransport = FakeTransport(inbound: [
            .success(aip11MiniMessage(type: 102, body: modeBody)),
        ])
        try await replacementTransport.connect()
        let replacementConnection = ChannelConnection(
            key: key,
            transport: replacementTransport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        _ = try await channel.replaceConnection(with: replacementConnection)

        sourceRun.cancel()
        await #expect(throws: ChannelError.transport(.cancelled)) {
            try await sourceRun.value
        }

        #expect(try await channel.processNext() == .modeChanged(
            multimediaTime: 123,
            mode: .raw
        ))
        try await replacementConnection.waitUntilProcessed([
            .init(key: key, serial: 1),
        ])
        #expect(await replacementTransport.isConnected)
    }

    @Test func unrelatedChannelFailureDoesNotResolveOrFailTheWaiter() async throws {
        let barrier = ChannelSerialBarrier()
        let awaitedKey = ChannelKey(type: 2, id: 5)
        let failedKey = ChannelKey(type: 2, id: 6)
        let awaitedTransport = FakeTransport(inbound: [
            .success(aip11MiniMessage(type: 940, body: Data())),
        ])
        let failedTransport = FakeTransport()
        try await awaitedTransport.connect()
        try await failedTransport.connect()
        let awaitedConnection = ChannelConnection(
            key: awaitedKey,
            transport: awaitedTransport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let failedConnection = ChannelConnection(
            key: failedKey,
            transport: failedTransport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let (probe, waiter) = aip11StartWait(
            on: awaitedConnection,
            requirements: [.init(key: awaitedKey, serial: 1)]
        )
        await aip11ExpectWaiting(probe)

        await failedConnection.fail(.protocolViolation("unrelated"))
        await aip11ExpectWaiting(probe)

        _ = try await awaitedConnection.receive()
        try await awaitedConnection.completeLastDelivered()
        await waiter.value
        #expect(await probe.state == .succeeded)
    }

    @Test func emptyListCompletesImmediatelyButFollowingMessageStillNeedsCompletion() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 2, id: 7)
        let emptyList = aip11FullMessage(
            serial: 60,
            type: 8,
            body: aip11LE(UInt16(0)),
            subListOffset: 0
        )
        let following = aip11FullMessage(serial: 61, type: 950, body: Data([1]))
        let transport = FakeTransport(inbound: [.success(emptyList + following)])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .full,
            serialBarrier: barrier
        )

        let delivered = try await connection.receive()
        #expect(delivered.serial == 61)
        try await connection.waitUntilProcessed([.init(key: key, serial: 60)])

        let (probe, waiter) = aip11StartWait(
            on: connection,
            requirements: [.init(key: key, serial: 61)]
        )
        await aip11ExpectWaiting(probe)
        try await connection.completeLastDelivered()
        await waiter.value
        #expect(await probe.state == .succeeded)
    }

    @Test func setAckCompletesItsSerialWithoutCountingAgainstTheNewWindow() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 5, id: 8)
        let setAckBody = aip11LE(UInt32(7)) + aip11LE(UInt32(1))
        let transport = FakeTransport(inbound: [
            .success(aip11MiniMessage(type: 3, body: setAckBody)),
            .success(aip11MiniMessage(type: 999, body: Data())),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        let channel = PlaybackChannel(
            connection: connection,
            multimediaClock: MultimediaClock()
        )

        #expect(try await channel.processNext() == .ignored(3))
        try await connection.waitUntilProcessed([.init(key: key, serial: 1)])
        var outbound = await transport.outbound
        #expect(try outbound.map(aip11MiniType) == [1])

        #expect(try await channel.processNext() == .ignored(999))
        try await connection.waitUntilProcessed([.init(key: key, serial: 2)])
        outbound = await transport.outbound
        #expect(try outbound.map(aip11MiniType) == [1, 2])
    }

    @Test func migrationRequestCompletesSerialWithoutTerminatingTheSourceBarrier() async throws {
        let barrier = ChannelSerialBarrier()
        let key = ChannelKey(type: 2, id: 9)
        let migration = aip11MiniMessage(type: 1, body: aip11LE(UInt32(0)))
        let following = aip11MiniMessage(type: 960, body: Data())
        let transport = FakeTransport(inbound: [.success(migration + following)])
        try await transport.connect()
        let connection = ChannelConnection(
            key: key,
            transport: transport,
            headerMode: .mini,
            serialBarrier: barrier
        )

        await #expect(throws: ChannelError.migrationRequested(key: key, data: nil)) {
            try await connection.receive()
        }
        try await connection.waitUntilProcessed([.init(key: key, serial: 1)])

        await connection.resumeAfterMigrationCancellation()
        let delivered = try await connection.receive()
        #expect(delivered.type == 960)
        try await connection.completeLastDelivered()
        try await connection.waitUntilProcessed([.init(key: key, serial: 2)])
    }

    @Test func barrierTerminationIsScopedAndCancellationRemovesWaiter() async throws {
        let barrier = ChannelSerialBarrier()
        let terminated = ChannelKey(type: 2, id: 10)
        let healthy = ChannelKey(type: 2, id: 11)
        let failedWaiter = Task {
            try await barrier.wait(for: [.init(key: terminated, serial: 1)])
        }
        let cancelledWaiter = Task {
            try await barrier.wait(for: [.init(key: healthy, serial: 1)])
        }
        await Task.yield()

        await barrier.terminate(key: terminated)
        await #expect(throws: ChannelSerialBarrier.WaitError.channelTerminated(terminated)) {
            try await failedWaiter.value
        }
        cancelledWaiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelledWaiter.value
        }

        await barrier.record(key: healthy, serial: 1)
        try await barrier.wait(for: [.init(key: healthy, serial: 1)])
        await #expect(throws: ChannelSerialBarrier.WaitError.channelTerminated(terminated)) {
            try await barrier.wait(for: [.init(key: terminated, serial: 2)])
        }
    }
}

private actor AIP11WaitProbe {
    enum State: Sendable, Equatable {
        case starting
        case waiting
        case succeeded
        case failed(ChannelError)
    }

    private(set) var state: State = .starting

    var failed: Bool {
        if case .failed = state { return true }
        return false
    }

    func wait(
        on connection: ChannelConnection,
        requirements: [ChannelSerialBarrier.Requirement]
    ) async {
        state = .waiting
        do {
            try await connection.waitUntilProcessed(requirements)
            state = .succeeded
        } catch let error {
            state = .failed(error)
        }
    }
}

private actor AIP11CancellationTransport: SpiceTransport {
    private(set) var readStarted = false
    private var connected = false

    func connect() async throws(TransportError) {
        connected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        guard connected else { throw .connectionClosed }
        readStarted = true
        do {
            try await Task.sleep(for: .seconds(30))
            throw TransportError.connectionClosed
        } catch {
            throw .cancelled
        }
    }

    func write(_ data: sending Data) async throws(TransportError) {
        _ = data
        guard connected else { throw .connectionClosed }
    }

    func close() async {
        connected = false
    }
}

private func aip11StartWait(
    on connection: ChannelConnection,
    requirements: [ChannelSerialBarrier.Requirement]
) -> (AIP11WaitProbe, Task<Void, Never>) {
    let probe = AIP11WaitProbe()
    let task = Task {
        await probe.wait(on: connection, requirements: requirements)
    }
    return (probe, task)
}

private func aip11ExpectWaiting(_ probe: AIP11WaitProbe) async {
    for _ in 0..<100 where await probe.state == .starting {
        await Task.yield()
    }
    for _ in 0..<20 {
        await Task.yield()
    }
    #expect(await probe.state == .waiting)
}

private func aip11ListBody(
    main: Data,
    submessages: [(type: UInt16, body: Data)],
    listOrder: [Int]
) -> Data {
    precondition(submessages.count == listOrder.count)
    precondition(Set(listOrder) == Set(submessages.indices))

    var records: [Data] = []
    var offsets: [UInt32] = []
    var nextOffset = main.count + 2 + submessages.count * 4
    for message in submessages {
        var record = aip11LE(message.type)
        record += aip11LE(UInt32(message.body.count))
        record += message.body
        records.append(record)
        offsets.append(UInt32(nextOffset))
        nextOffset += record.count
    }

    var body = main + aip11LE(UInt16(submessages.count))
    for index in listOrder { body += aip11LE(offsets[index]) }
    for record in records { body += record }
    return body
}

private func aip11FullMessage(
    serial: UInt64,
    type: UInt16,
    body: Data,
    subListOffset: UInt32 = 0
) -> Data {
    var writer = ByteWriter()
    writer.writeUInt64LE(serial)
    writer.writeUInt16LE(type)
    writer.writeUInt32LE(UInt32(body.count))
    writer.writeUInt32LE(subListOffset)
    writer.writeBytes(body)
    return writer.data
}

private func aip11MiniMessage(type: UInt16, body: Data) -> Data {
    var writer = ByteWriter()
    writer.writeUInt16LE(type)
    writer.writeUInt32LE(UInt32(body.count))
    writer.writeBytes(body)
    return writer.data
}

private func aip11MiniType(_ data: Data) throws -> UInt16 {
    var reader = try ByteReader(data)
    return try reader.readUInt16LE()
}

private func aip11LE<T: FixedWidthInteger>(_ value: T) -> Data {
    withUnsafeBytes(of: value.littleEndian) { Data($0) }
}
