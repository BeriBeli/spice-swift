import Foundation
import SpiceWire

package enum SpiceVMCWire {
    package static let serverData: UInt16 = 101
    package static let serverCompressedData: UInt16 = 102
    package static let clientData: UInt16 = 101
}

package struct SpiceVMCWireLimits: Sendable, Equatable {
    package var maximumPacketBytes: Int

    package init(maximumPacketBytes: Int = 1 * 1_024 * 1_024) {
        self.maximumPacketBytes = maximumPacketBytes
    }
}

package struct SpiceVMCWireCodec: Sendable {
    private let limits: SpiceVMCWireLimits

    package init(limits: SpiceVMCWireLimits = .init()) {
        self.limits = limits
    }

    package func decodeServer(id: UInt16, body: Data) throws(WireError) -> Data {
        switch id {
        case SpiceVMCWire.serverData:
            try validate(body)
            return body
        case SpiceVMCWire.serverCompressedData:
            throw .unsupportedFeature("compressed SpiceVMC data was not negotiated")
        default:
            throw .unsupportedFeature("SpiceVMC message \(id)")
        }
    }

    package func encodeClientData(_ data: Data) throws(WireError) -> Data {
        try validate(data)
        return data
    }

    private func validate(_ data: Data) throws(WireError) {
        guard !data.isEmpty else {
            throw .invalidSize(0)
        }
        guard data.count <= limits.maximumPacketBytes else {
            throw .messageTooLarge(actual: data.count, maximum: limits.maximumPacketBytes)
        }
    }
}
