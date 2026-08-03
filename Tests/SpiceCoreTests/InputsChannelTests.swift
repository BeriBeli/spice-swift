import Foundation
import SpiceTestSupport
import SpiceTransport
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("Inputs Channel")
struct InputsChannelTests {
    @Test func preservesKeyboardOrderAndTracksButtonState() async throws {
        let inbound = try [
            encodeMini(SpiceMsgInputsInit(keyboardModifiers: 1)),
            encodeMini(SpiceMsgInputsKeyModifiers(modifiers: 3)),
            encodeMini(SpiceMsgInputsMouseMotionAck()),
        ]
        let transport = FakeTransport(inbound: inbound.map(Result.success))
        try await transport.connect()
        let channel = InputsChannel(connection: ChannelConnection(
            key: ChannelKey(type: 3, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        #expect(try await channel.processNext() == .initialized(keyboardModifiers: 1))
        #expect(try await channel.processNext() == .keyboardModifiersChanged(3))
        #expect(try await channel.processNext() == .mouseMotionAcknowledged)

        try await channel.send(.keyDown(scanCode: 0x1e))
        try await channel.send(.keyUp(scanCode: 0x1e))
        try await channel.send(.mousePress(.left))
        try await channel.send(.mouseMotion(dx: -2, dy: 4))
        try await channel.send(.mouseRelease(.left))
        try await channel.send(.mousePosition(x: 100, y: 200, displayID: 1))

        let outbound = await transport.outbound
        #expect(try outbound.map(messageID) == [101, 102, 113, 111, 114, 112])
        #expect(try keyCode(outbound[0]) == 0x1e)
        #expect(try keyCode(outbound[1]) == 0x9e)
        #expect(try buttonsState(outbound[2], offset: 1) == 1)
        #expect(try buttonsState(outbound[3], offset: 8) == 1)
        #expect(try buttonsState(outbound[4], offset: 1) == 0)
        #expect(try buttonsState(outbound[5], offset: 8) == 0)
    }

    @Test func encodesExtendedScanCodePrefixesAndReleaseBit() async throws {
        let transport = FakeTransport()
        try await transport.connect()
        let channel = InputsChannel(connection: ChannelConnection(
            key: ChannelKey(type: 3, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        try await channel.send(.keyDown(scanCode: 0x14b))
        try await channel.send(.keyUp(scanCode: 0x14b))

        let outbound = await transport.outbound
        #expect(try keyCode(outbound[0]) == 0x4be0)
        #expect(try keyCode(outbound[1]) == 0xcbe0)
    }

    @Test func failedButtonTransitionsDoNotPolluteFollowingMotion() async throws {
        let transport = SelectiveWriteFailureTransport(failingWrites: [1, 4])
        try await transport.connect()
        let channel = InputsChannel(connection: ChannelConnection(
            key: ChannelKey(type: 3, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        await #expect(throws: ChannelError.transport(
            .connectionFailed("fixture write 1")
        )) {
            try await channel.send(.mousePress(.left))
        }
        try await channel.send(.mouseMotion(dx: 1, dy: 2))
        try await channel.send(.mousePress(.left))
        await #expect(throws: ChannelError.transport(
            .connectionFailed("fixture write 4")
        )) {
            try await channel.send(.mouseRelease(.left))
        }
        try await channel.send(.mouseMotion(dx: 3, dy: 4))

        let outbound = await transport.outbound
        #expect(try outbound.map(messageID) == [111, 113, 111])
        #expect(try buttonsState(outbound[0], offset: 8) == 0)
        #expect(try buttonsState(outbound[1], offset: 1) == 1)
        #expect(try buttonsState(outbound[2], offset: 8) == 1)
    }

    @Test func concurrentButtonTransitionsAreSerialized() async throws {
        let transport = BlockingFirstWriteTransport()
        try await transport.connect()
        let channel = InputsChannel(connection: ChannelConnection(
            key: ChannelKey(type: 3, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        let left = Task { try await channel.send(.mousePress(.left)) }
        await transport.waitUntilFirstWriteStarts()
        let right = Task { try await channel.send(.mousePress(.right)) }
        await Task.yield()
        #expect(await transport.writeCount == 1)

        await transport.completeFirstWrite()
        try await left.value
        try await right.value

        let outbound = await transport.outbound
        #expect(outbound.count == 2)
        #expect(try buttonsState(outbound[0], offset: 1) == 1)
        #expect(try buttonsState(outbound[1], offset: 1) == 5)
    }

    @Test func cancellationRemovesAQueuedSendWithoutASecondWrite() async throws {
        let transport = BlockingFirstWriteTransport()
        try await transport.connect()
        let channel = InputsChannel(connection: ChannelConnection(
            key: ChannelKey(type: 3, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        let active = Task { try await channel.send(.mousePress(.left)) }
        await transport.waitUntilFirstWriteStarts()
        let queued = Task { try await channel.send(.mousePress(.right)) }
        await Task.yield()
        queued.cancel()

        await #expect(throws: ChannelError.cancelledBeforeWrite) {
            try await queued.value
        }
        #expect(await transport.writeCount == 1)
        await transport.completeFirstWrite()
        try await active.value
    }

    @Test func closeInvalidatesActiveAndQueuedSends() async throws {
        let transport = BlockingFirstWriteTransport()
        try await transport.connect()
        let channel = InputsChannel(connection: ChannelConnection(
            key: ChannelKey(type: 3, id: 0),
            transport: transport,
            headerMode: .mini
        ))

        let active = Task { try await channel.send(.mousePress(.left)) }
        await transport.waitUntilFirstWriteStarts()
        let queued = Task { try await channel.send(.mousePress(.right)) }
        await Task.yield()
        await channel.close()

        await #expect(throws: ChannelError.invalidState) {
            try await active.value
        }
        await #expect(throws: ChannelError.invalidState) {
            try await queued.value
        }
        #expect(await transport.writeCount == 1)
    }

    @Test func rebindRejectsLateButtonCompletionWithoutPollutingReplacement() async throws {
        let sourceTransport = BlockingFirstWriteTransport()
        try await sourceTransport.connect()
        let key = ChannelKey(type: 3, id: 0)
        let channel = InputsChannel(connection: ChannelConnection(
            key: key,
            transport: sourceTransport,
            headerMode: .mini
        ))

        let active = Task { try await channel.send(.mousePress(.left)) }
        await sourceTransport.waitUntilFirstWriteStarts()

        let replacementTransport = FakeTransport()
        try await replacementTransport.connect()
        let previous = try await channel.replaceConnection(with: ChannelConnection(
            key: key,
            transport: replacementTransport,
            headerMode: .mini
        ))
        await sourceTransport.completeFirstWrite()

        await #expect(throws: ChannelError.invalidState) {
            try await active.value
        }
        try await channel.send(.mouseMotion(dx: 4, dy: 5))
        let replacementOutbound = await replacementTransport.outbound
        #expect(replacementOutbound.count == 1)
        #expect(try buttonsState(replacementOutbound[0], offset: 8) == 0)
        await previous.close()
    }

    private func messageID(_ framed: Data) throws -> UInt16 {
        var reader = try ByteReader(framed)
        return try reader.readUInt16LE()
    }

    private func buttonsState(_ framed: Data, offset: Int) throws -> UInt16 {
        var reader = try ByteReader(framed, offset: 6 + offset)
        return try reader.readUInt16LE()
    }

    private func keyCode(_ framed: Data) throws -> UInt32 {
        var reader = try ByteReader(framed, offset: 6)
        return try reader.readUInt32LE()
    }

    private func encodeMini<Message: SpiceGeneratedMessage>(_ message: Message) throws -> Data {
        let id = try #require(Message.messageID)
        var body = ByteWriter()
        try message.encode(to: &body)
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.data.count))
        writer.writeBytes(body.data)
        return writer.data
    }
}

private actor SelectiveWriteFailureTransport: SpiceTransport {
    private let failingWrites: Set<Int>
    private var attemptedWrites = 0
    private(set) var outbound: [Data] = []
    private var isConnected = false

    init(failingWrites: Set<Int>) {
        self.failingWrites = failingWrites
    }

    func connect() async throws(TransportError) {
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        throw .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected else { throw .connectionClosed }
        attemptedWrites += 1
        if failingWrites.contains(attemptedWrites) {
            throw .connectionFailed("fixture write \(attemptedWrites)")
        }
        outbound.append(data)
    }

    func close() async {
        isConnected = false
    }
}

private actor BlockingFirstWriteTransport: SpiceTransport {
    private var firstWriteCompletion: CheckedContinuation<Void, Never>?
    private var firstWriteStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var outbound: [Data] = []
    private(set) var writeCount = 0
    private var isConnected = false

    func connect() async throws(TransportError) {
        isConnected = true
    }

    func read(minimum: Int, maximum: Int) async throws(TransportError) -> Data {
        throw .connectionClosed
    }

    func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected else { throw .connectionClosed }
        writeCount += 1
        if writeCount == 1 {
            let waiters = firstWriteStartWaiters
            firstWriteStartWaiters.removeAll(keepingCapacity: false)
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { continuation in
                firstWriteCompletion = continuation
            }
        }
        outbound.append(data)
    }

    func waitUntilFirstWriteStarts() async {
        guard writeCount == 0 else { return }
        await withCheckedContinuation { continuation in
            firstWriteStartWaiters.append(continuation)
        }
    }

    func completeFirstWrite() {
        firstWriteCompletion?.resume()
        firstWriteCompletion = nil
    }

    func close() async {
        isConnected = false
        completeFirstWrite()
        for waiter in firstWriteStartWaiters { waiter.resume() }
        firstWriteStartWaiters.removeAll(keepingCapacity: false)
    }
}
