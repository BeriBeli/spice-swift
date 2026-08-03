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

package enum ChannelError: Error, Sendable, Equatable {
    case transport(TransportError)
    case wire(WireError)
    case authentication(AuthenticationError)
    case linkRejected(code: UInt32)
    case migrationRequested(key: ChannelKey, data: Data?)
    case agentQueueFull
    case agentCancelled(partial: Bool)
    case agentDisconnected
    case agentMessageFailed(partial: Bool)
    case agentMigrationRebind(partial: Bool)
    case agentStalled(partial: Bool)
    case invalidState
    case unsupportedCapability
    case protocolViolation(String)
}

package protocol TicketEncrypting: Sendable {
    func encryptTicket(
        password: consuming Data,
        publicKeyDER: Data
    ) throws(AuthenticationError) -> Data
}
