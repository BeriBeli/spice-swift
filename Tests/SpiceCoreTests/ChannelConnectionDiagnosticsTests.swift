import Foundation
import SpiceTestSupport
import Synchronization
import Testing
@testable import SpiceCore
@testable import SpiceWire

@Suite("Channel connection diagnostics")
struct ChannelConnectionDiagnosticsTests {
    @Test func sampledFramerPhasesUseInjectedClock() async throws {
        let clock = DiagnosticTestClock(step: 10)
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 0x1234, body: Data([1, 2, 3]))),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini,
            diagnosticsMode: .sampled(commandPeriod: 1),
            diagnosticsClock: clock.read
        )

        let message = try await connection.receive()
        let metrics = await connection.metrics()

        #expect(message.type == 0x1234)
        #expect(message.body == Data([1, 2, 3]))
        #expect(metrics.framerNextTiming == RenderPhaseMetrics(
            samplePeriod: 1,
            samples: 2,
            sampledNanoseconds: 20
        ))
        #expect(metrics.framerAppendTiming == RenderPhaseMetrics(
            samplePeriod: 1,
            samples: 1,
            sampledNanoseconds: 10
        ))
        #expect(clock.readCount == 6)
    }

    @Test func disabledFramerPhasesDoNotReadInjectedClock() async throws {
        let clock = DiagnosticTestClock(step: 10)
        let transport = FakeTransport(inbound: [
            .success(encodeMini(id: 7, body: Data())),
        ])
        try await transport.connect()
        let connection = ChannelConnection(
            key: ChannelKey(type: 2, id: 0),
            transport: transport,
            headerMode: .mini,
            diagnosticsClock: clock.read
        )

        _ = try await connection.receive()

        #expect(await connection.metrics() == ChannelConnectionMetrics())
        #expect(clock.readCount == 0)
    }

    private func encodeMini(id: UInt16, body: Data) -> Data {
        var writer = ByteWriter()
        writer.writeUInt16LE(id)
        writer.writeUInt32LE(UInt32(body.count))
        writer.writeBytes(body)
        return writer.data
    }
}

private final class DiagnosticTestClock: Sendable {
    private struct State: Sendable {
        var next: UInt64 = 0
        var reads = 0
    }

    private let state = Mutex(State())
    private let step: UInt64

    init(step: UInt64) {
        self.step = step
    }

    func read() -> UInt64 {
        state.withLock { state in
            defer {
                state.next &+= step
                state.reads += 1
            }
            return state.next
        }
    }

    var readCount: Int {
        state.withLock(\.reads)
    }
}
