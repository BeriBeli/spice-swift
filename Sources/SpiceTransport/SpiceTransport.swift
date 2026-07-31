import Foundation

public enum TransportError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case connectionClosed
    case timeout
    case tlsFailure(String)
    case cancelled
}

public protocol SpiceTransport: Actor {
    func connect() async throws(TransportError)

    func read(
        minimum: Int,
        maximum: Int
    ) async throws(TransportError) -> Data

    func write(_ data: sending Data) async throws(TransportError)

    func close() async
}
