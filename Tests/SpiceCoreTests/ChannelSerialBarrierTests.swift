import SpiceTestSupport
import Testing
@testable import SpiceCore
@testable import SpiceWire

@Suite("Cross-channel serial barrier")
struct ChannelSerialBarrierTests {
    @Test func resumesOnlyAfterEveryRequiredChannelSerial() async throws {
        let barrier = ChannelSerialBarrier()
        let display0 = ChannelKey(type: 2, id: 0)
        let display1 = ChannelKey(type: 2, id: 1)
        let waiter = Task {
            try await barrier.wait(for: [
                .init(key: display0, serial: 3),
                .init(key: display1, serial: 2),
            ])
        }

        barrier.record(key: display0, serial: 3)
        barrier.record(key: display1, serial: 1)
        barrier.record(key: display1, serial: 2)
        try await waiter.value
    }

    @Test func ignoresOutOfOrderOlderSerials() async throws {
        let barrier = ChannelSerialBarrier()
        let display = ChannelKey(type: 2, id: 0)

        barrier.record(key: display, serial: 5)
        barrier.record(key: display, serial: 3)

        try await barrier.wait(for: [.init(key: display, serial: 5)])
    }

    @Test func cancellationRemovesSuspendedWaiter() async {
        let barrier = ChannelSerialBarrier()
        let waiter = Task {
            try await barrier.wait(for: [
                .init(key: ChannelKey(type: 2, id: 1), serial: 99),
            ])
        }
        waiter.cancel()
        await #expect(throws: CancellationError.self) {
            try await waiter.value
        }
    }

    @Test func cancellationBeforeRegistrationCannotBeLost() async {
        let barrier = ChannelSerialBarrier()
        let requirement = ChannelSerialBarrier.Requirement(
            key: ChannelKey(type: 2, id: 1),
            serial: 99
        )

        for _ in 0..<1_000 {
            let waiter = Task {
                try await barrier.wait(for: [requirement])
            }
            waiter.cancel()
            await #expect(throws: CancellationError.self) {
                try await waiter.value
            }
        }
    }

    @Test func concurrentRecordAndCancellationAlwaysResolveOnce() async {
        let key = ChannelKey(type: 2, id: 1)
        let barrier = ChannelSerialBarrier()

        for serial in 1...1_000 {
            let waiter = Task {
                try await barrier.wait(for: [
                    .init(key: key, serial: UInt64(serial)),
                ])
            }
            let recorder = Task.detached {
                barrier.record(key: key, serial: UInt64(serial))
            }
            waiter.cancel()
            await recorder.value
            do {
                try await waiter.value
            } catch is CancellationError {
                // Cancellation and satisfaction are intentionally racing.
            } catch {
                Issue.record("unexpected barrier error: \(error)")
            }
        }
    }

    @Test func channelConnectionPublishesFullAndImplicitMiniSerials() async throws {
        let barrier = ChannelSerialBarrier()
        let fullKey = ChannelKey(type: 2, id: 0)
        var fullWriter = ByteWriter()
        fullWriter.writeUInt64LE(42)
        fullWriter.writeUInt16LE(999)
        fullWriter.writeUInt32LE(0)
        fullWriter.writeUInt32LE(0)
        let fullTransport = FakeTransport(inbound: [.success(fullWriter.data)])
        try await fullTransport.connect()
        let fullConnection = ChannelConnection(
            key: fullKey,
            transport: fullTransport,
            headerMode: .full,
            serialBarrier: barrier
        )
        _ = try await fullConnection.receive()
        try await barrier.wait(for: [.init(key: fullKey, serial: 42)])

        let miniKey = ChannelKey(type: 2, id: 1)
        var miniWriter = ByteWriter()
        for _ in 0..<2 {
            miniWriter.writeUInt16LE(999)
            miniWriter.writeUInt32LE(0)
        }
        let miniTransport = FakeTransport(inbound: [.success(miniWriter.data)])
        try await miniTransport.connect()
        let miniConnection = ChannelConnection(
            key: miniKey,
            transport: miniTransport,
            headerMode: .mini,
            serialBarrier: barrier
        )
        _ = try await miniConnection.receive()
        _ = try await miniConnection.receive()
        try await barrier.wait(for: [.init(key: miniKey, serial: 2)])
    }
}
