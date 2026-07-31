import Testing
@testable import SpiceWire

@Suite("SpiceAddressResolver")
struct AddressResolverTests {
    @Test func resolvesContainedRange() throws {
        let resolver = try SpiceAddressResolver(messageSize: 32)
        #expect(try resolver.resolve(8, minimumSize: 12) == 8..<20)
    }

    @Test func rejectsOutOfBoundsRange() throws {
        let resolver = try SpiceAddressResolver(messageSize: 32)
        #expect(throws: WireError.invalidOffset(24)) {
            try resolver.resolve(24, minimumSize: 9)
        }
    }

    @Test func rejectsUnrepresentableAddress() throws {
        let resolver = try SpiceAddressResolver(messageSize: 32)
        #expect(throws: WireError.invalidOffset(UInt64.max)) {
            try resolver.resolve(UInt64.max, minimumSize: 1)
        }
    }
}
