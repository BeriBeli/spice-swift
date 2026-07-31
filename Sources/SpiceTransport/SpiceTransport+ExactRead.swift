import Foundation

public extension SpiceTransport {
    func readExactly(_ count: Int) async throws(TransportError) -> Data {
        guard count >= 0 else {
            throw .connectionFailed("negative exact-read length")
        }
        guard count > 0 else {
            return Data()
        }

        var result = Data()
        result.reserveCapacity(count)

        while result.count < count {
            guard !Task.isCancelled else {
                throw .cancelled
            }
            let chunk = try await read(
                minimum: 1,
                maximum: count - result.count
            )
            guard !chunk.isEmpty else {
                throw .connectionClosed
            }
            result.append(chunk)
        }
        return result
    }
}
