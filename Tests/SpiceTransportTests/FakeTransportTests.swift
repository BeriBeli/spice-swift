import Foundation
import SpiceTestSupport
import SpiceTransport
import Testing

@Suite("FakeTransport")
struct FakeTransportTests {
    @Test func recordsWritesAndInjectedReads() async throws {
        let transport = FakeTransport(inbound: [.success(Data([1, 2]))])
        try await transport.connect()

        #expect(try await transport.read(minimum: 1, maximum: 8) == Data([1, 2]))
        try await transport.write(Data([3, 4]))
        #expect(await transport.outbound == [Data([3, 4])])

        await transport.close()
        #expect(await transport.isClosed)
    }

    @Test func propagatesInjectedError() async throws {
        let transport = FakeTransport(inbound: [.failure(.timeout)])
        try await transport.connect()

        await #expect(throws: TransportError.timeout) {
            try await transport.read(minimum: 1, maximum: 8)
        }
    }

    @Test func exactReadCombinesTransportFragments() async throws {
        let transport = FakeTransport(inbound: [
            .success(Data([1, 2])),
            .success(Data([3])),
            .success(Data([4, 5])),
        ])
        try await transport.connect()

        #expect(try await transport.readExactly(5) == Data([1, 2, 3, 4, 5]))
    }
}
