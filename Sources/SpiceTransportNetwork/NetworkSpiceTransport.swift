import Foundation
import Network
import SpiceTransport

public enum NetworkTLSPolicy: Sendable {
    case system
    case insecureForTestingOnly
}

public actor NetworkSpiceTransport: SpiceTransport {
    private enum Configuration: Sendable {
        case tcp
        case tls(NetworkTLSPolicy)
    }

    private enum Connection {
        case tcp(NetworkConnection<TCP>)
        case tls(NetworkConnection<TLS>)
    }

    private enum EstablishmentState: Sendable {
        case ready
        case failed(TransportError)
        case cancelled
    }

    private let host: String
    private let port: UInt16
    private let configuration: Configuration
    private let establishmentTimeout: Duration
    private var connection: Connection?

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
        configuration = .tcp
        establishmentTimeout = .seconds(10)
    }

    public init(
        host: String,
        port: UInt16,
        tlsPolicy: NetworkTLSPolicy
    ) {
        self.host = host
        self.port = port
        configuration = .tls(tlsPolicy)
        establishmentTimeout = .seconds(10)
    }

    package init(
        host: String,
        port: UInt16,
        tlsPolicy: NetworkTLSPolicy,
        establishmentTimeout: Duration
    ) {
        self.host = host
        self.port = port
        configuration = .tls(tlsPolicy)
        self.establishmentTimeout = establishmentTimeout
    }

    public func connect() async throws(TransportError) {
        guard connection == nil else {
            return
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw .connectionFailed("invalid TCP port \(port)")
        }
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: endpointPort
        )

        let newConnection: Connection
        switch configuration {
        case .tcp:
            newConnection = .tcp(NetworkConnection(to: endpoint) {
                TCP().noDelay(true).connectionTimeout(10)
            })
        case let .tls(policy):
            let tls = makeTLS(policy: policy)
            newConnection = .tls(NetworkConnection(to: endpoint, using: .parameters {
                tls
            }))
        }
        connection = newConnection

        do {
            switch newConnection {
            case let .tcp(connection):
                try await startAndWaitUntilReady(connection)
            case let .tls(connection):
                try await startAndWaitUntilReady(connection)
            }
        } catch is CancellationError {
            // Dropping the unestablished channel is deliberate. An async
            // end-of-stream send can itself wait for establishment and would
            // make cancellation non-terminating.
            connection = nil
            throw .cancelled
        } catch let error as TransportError {
            connection = nil
            throw error
        } catch {
            connection = nil
            throw .connectionFailed(String(describing: error))
        }
    }

    private func startAndWaitUntilReady(_ connection: NetworkConnection<TCP>) async throws {
        let states = AsyncStream.makeStream(
            of: EstablishmentState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        connection.onStateUpdate { _, state in
            switch state {
            case .ready:
                states.continuation.yield(.ready)
                states.continuation.finish()
            case let .failed(error):
                states.continuation.yield(.failed(
                    .connectionFailed(String(describing: error))
                ))
                states.continuation.finish()
            case .cancelled:
                states.continuation.yield(.cancelled)
                states.continuation.finish()
            case .setup, .waiting, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.sendIdempotent(Data())
        try await waitForEstablishment(states)
    }

    private func startAndWaitUntilReady(_ connection: NetworkConnection<TLS>) async throws {
        let states = AsyncStream.makeStream(
            of: EstablishmentState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        connection.onStateUpdate { _, state in
            switch state {
            case .ready:
                states.continuation.yield(.ready)
                states.continuation.finish()
            case let .failed(error):
                states.continuation.yield(.failed(
                    .tlsFailure(String(describing: error))
                ))
                states.continuation.finish()
            case .cancelled:
                states.continuation.yield(.cancelled)
                states.continuation.finish()
            case .setup, .waiting, .preparing:
                break
            @unknown default:
                break
            }
        }
        connection.sendIdempotent(Data())
        try await waitForEstablishment(states)
    }

    private func waitForEstablishment(
        _ states: (
            stream: AsyncStream<EstablishmentState>,
            continuation: AsyncStream<EstablishmentState>.Continuation
        )
    ) async throws {
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: EstablishmentState.self) { group in
                group.addTask {
                    for await state in states.stream {
                        return state
                    }
                    try Task.checkCancellation()
                    throw TransportError.connectionClosed
                }
                group.addTask { [establishmentTimeout] in
                    try await Task.sleep(for: establishmentTimeout)
                    return .failed(.timeout)
                }
                defer {
                    group.cancelAll()
                    states.continuation.finish()
                }

                guard let state = try await group.next() else {
                    throw TransportError.connectionClosed
                }
                switch state {
                case .ready:
                    return
                case let .failed(error):
                    throw error
                case .cancelled:
                    throw CancellationError()
                }
            }
        } onCancel: {
            states.continuation.finish()
        }
    }

    public func read(
        minimum: Int,
        maximum: Int
    ) async throws(TransportError) -> Data {
        guard minimum >= 0, maximum >= minimum, maximum > 0 else {
            throw .connectionFailed("invalid read bounds")
        }
        guard let connection else {
            throw .connectionClosed
        }

        do {
            switch connection {
            case let .tcp(connection):
                let message = try await connection.receive(atLeast: minimum, atMost: maximum)
                guard !message.content.isEmpty || !message.metadata.endOfStream else {
                    throw TransportError.connectionClosed
                }
                return message.content
            case let .tls(connection):
                let message = try await connection.receive(atLeast: minimum, atMost: maximum)
                guard !message.content.isEmpty || !message.metadata.endOfStream else {
                    throw TransportError.connectionClosed
                }
                return message.content
            }
        } catch is CancellationError {
            throw .cancelled
        } catch let error as TransportError {
            throw error
        } catch {
            throw mapNetworkError(error)
        }
    }

    public func write(_ data: sending Data) async throws(TransportError) {
        guard let connection else {
            throw .connectionClosed
        }
        do {
            switch connection {
            case let .tcp(connection):
                try await connection.send(data)
            case let .tls(connection):
                try await connection.send(data)
            }
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw mapNetworkError(error)
        }
    }

    public func close() async {
        guard let connection else {
            return
        }
        self.connection = nil
        await closeConnection(connection)
    }

    private func makeTLS(policy: NetworkTLSPolicy) -> TLS {
        let tls = TLS {
            TCP().noDelay(true)
        }
        switch policy {
        case .system:
            return tls
        case .insecureForTestingOnly:
            return tls.certificateValidator { _, _ in true }
        }
    }

    private func closeConnection(_ connection: Connection) async {
        switch connection {
        case let .tcp(connection):
            try? await connection.send(Data(), endOfStream: true)
        case let .tls(connection):
            try? await connection.send(Data(), endOfStream: true)
        }
    }

    private func mapNetworkError(_ error: any Error) -> TransportError {
        switch configuration {
        case .tcp:
            .connectionFailed(String(describing: error))
        case .tls:
            .tlsFailure(String(describing: error))
        }
    }
}
