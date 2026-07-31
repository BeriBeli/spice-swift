import Foundation
import SpiceTransport

public actor FakeTransport: SpiceTransport {
    private var inbound: [Result<Data, TransportError>]
    public private(set) var outbound: [Data] = []
    public private(set) var isConnected = false
    public private(set) var isClosed = false

    public init(inbound: [Result<Data, TransportError>] = []) {
        self.inbound = inbound
    }

    public func enqueue(_ result: Result<Data, TransportError>) {
        inbound.append(result)
    }

    public func connect() async throws(TransportError) {
        guard !isClosed else {
            throw .connectionClosed
        }
        isConnected = true
    }

    public func read(
        minimum: Int,
        maximum: Int
    ) async throws(TransportError) -> Data {
        guard isConnected, !isClosed else {
            throw .connectionClosed
        }
        guard minimum >= 0, maximum >= minimum else {
            throw .connectionFailed("invalid read bounds")
        }
        guard !inbound.isEmpty else {
            throw .connectionClosed
        }
        let result = inbound.removeFirst()
        let data = try result.get()
        guard data.count <= maximum else {
            throw .connectionFailed("fixture exceeds requested maximum")
        }
        return data
    }

    public func write(_ data: sending Data) async throws(TransportError) {
        guard isConnected, !isClosed else {
            throw .connectionClosed
        }
        outbound.append(data)
    }

    public func close() async {
        isClosed = true
        isConnected = false
    }
}
