import Testing
@testable import SpiceProtocol

@Suite("CapabilitySet")
struct CapabilitySetTests {
    @Test func insertsAndChecksTypedCapability() {
        var capabilities = CapabilitySet<CommonCapability>()
        capabilities.insert(.miniHeader)

        #expect(capabilities.contains(.miniHeader))
        #expect(!capabilities.contains(.authSpice))
        #expect(capabilities.wireWords == [0b1000])
    }
}
