import SpiceWire

package enum SpiceProtocolConstants {
    /// ASCII `REDQ` interpreted as a little-endian UInt32.
    package static let magic: UInt32 = 0x5144_4552
    package static let majorVersion: UInt32 = 2
    package static let minorVersion: UInt32 = 2
    package static let ticketPublicKeyByteCount = 162
    package static let encryptedTicketByteCount = 128
}

package extension SpiceLinkHeader {
    func validate() throws(WireError) {
        guard magic == SpiceProtocolConstants.magic else {
            throw .invalidMagic(magic)
        }
        guard majorVersion == SpiceProtocolConstants.majorVersion else {
            throw .unsupportedVersion(major: majorVersion, minor: minorVersion)
        }
    }
}
