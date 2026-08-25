import Foundation
import SpiceTransport
import SpiceWire

package enum AuthenticationError: Error, Sendable, Equatable {
    case passwordTooLong(maximumBytes: Int)
    case passwordContainsNUL
    case invalidPublicKey
    case unsupportedPublicKey
    case encryptionFailed(String)
    case unsupportedMethod
    case rejected(code: UInt32)
}

/// Dependency-neutral advanced-video identity used to carry a recoverable
/// decoder compatibility failure from SpiceChannels into the public session.
package enum VideoCodecIdentifier: Sendable, Equatable {
    case h264
    case h265
}

package enum VideoCodecFailureReason: Sendable, Equatable {
    case hardwareUnavailable(status: Int32?)
    case unsupportedFormat(status: Int32)
}

package enum ChannelError: Error, Sendable, Equatable {
    case transport(TransportError)
    case wire(WireError)
    case authentication(AuthenticationError)
    case linkRejected(code: UInt32)
    case migrationRequested(key: ChannelKey, data: Data?)
    case invalidState
    case unsupportedCapability
    case videoCodecFailure(
        codec: VideoCodecIdentifier,
        reason: VideoCodecFailureReason
    )
    case protocolViolation(String)
}

package protocol TicketEncrypting: Sendable {
    func encryptTicket(
        password: consuming Data,
        publicKeyDER: Data
    ) throws(AuthenticationError) -> Data
}
