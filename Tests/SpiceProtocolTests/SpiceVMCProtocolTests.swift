import Foundation
import Testing
@testable import SpiceProtocol
@testable import SpiceWire

@Suite("SpiceVMC wire protocol")
struct SpiceVMCProtocolTests {
    @Test func passesBoundedOpaquePacketsWithoutMutation() throws {
        let packet = Data([1, 2, 3, 4])
        let codec = SpiceVMCWireCodec()
        #expect(try codec.decodeServer(id: 101, body: packet) == packet)
        #expect(try codec.encodeClientData(packet) == packet)
    }

    @Test func rejectsEmptyOversizedCompressedAndUnknownPackets() {
        let codec = SpiceVMCWireCodec(limits: .init(maximumPacketBytes: 3))
        #expect(throws: WireError.invalidSize(0)) {
            try codec.encodeClientData(Data())
        }
        #expect(throws: WireError.messageTooLarge(actual: 4, maximum: 3)) {
            try codec.decodeServer(id: 101, body: Data(repeating: 0, count: 4))
        }
        #expect(throws: WireError.unsupportedFeature(
            "compressed SpiceVMC data was not negotiated"
        )) {
            try codec.decodeServer(id: 102, body: Data([1]))
        }
        #expect(throws: WireError.unsupportedFeature("SpiceVMC message 200")) {
            try codec.decodeServer(id: 200, body: Data([1]))
        }
    }
}
