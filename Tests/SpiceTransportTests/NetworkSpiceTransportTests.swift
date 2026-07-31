import Foundation
import Network
import SpiceTransport
import SpiceTransportNetwork
import Testing

@Suite("NetworkSpiceTransport")
struct NetworkSpiceTransportTests {
    @Test func cancellationStopsPendingEstablishment() async throws {
        let transport = NetworkSpiceTransport(host: "192.0.2.1", port: 5900)
        let task = Task {
            try await transport.connect()
        }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            try await task.value
            Issue.record("cancelled connection unexpectedly succeeded")
        } catch TransportError.cancelled {
            // Expected: cancellation must not wait for the TCP timeout.
        } catch {
            Issue.record("expected cancellation, got \(error)")
        }
    }

    @Test func exchangesBytesWithLocalTCPListener() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "swiftspice.network-test")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) {
                data,
                _,
                _,
                error in
                guard error == nil, let data else {
                    return
                }
                connection.send(content: data, completion: .idempotent)
            }
        }

        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { state in
                continuation.yield(state)
                switch state {
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        var port: NWEndpoint.Port?
        for await state in states {
            switch state {
            case .ready:
                port = listener.port
            case let .failed(error):
                Issue.record("local listener failed: \(error)")
            default:
                break
            }
            if port != nil {
                break
            }
        }
        let resolvedPort = try #require(port)

        let transport = NetworkSpiceTransport(
            host: "127.0.0.1",
            port: resolvedPort.rawValue
        )
        try await transport.connect()
        try await transport.write(Data([1, 2, 3, 4]))
        #expect(try await transport.read(minimum: 1, maximum: 1_024) == Data([1, 2, 3, 4]))
        await transport.close()
    }

    @Test func timesOutWhenPeerNeverCompletesTLSHandshake() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "swiftspice.tls-timeout-test")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
        }

        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { state in
                continuation.yield(state)
                switch state {
                case .failed, .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
        }
        listener.start(queue: queue)
        defer { listener.cancel() }

        var port: NWEndpoint.Port?
        for await state in states {
            if case .ready = state {
                port = listener.port
                break
            }
        }
        let resolvedPort = try #require(port)
        let transport = NetworkSpiceTransport(
            host: "127.0.0.1",
            port: resolvedPort.rawValue,
            tlsPolicy: .system,
            establishmentTimeout: .milliseconds(100)
        )

        await #expect(throws: TransportError.timeout) {
            try await transport.connect()
        }
    }
}
