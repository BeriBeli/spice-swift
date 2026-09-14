import Foundation

package struct SpiceLiveStageTransport: Sendable {
    private let receiveFrameOperation: @Sendable (Int) async throws -> Data?
    private let sendFrameOperation: @Sendable (Data) async throws -> Void
    private let closeOperation: @Sendable () async -> Void

    package init(
        receiveFrame: @escaping @Sendable (Int) async throws -> Data?,
        sendFrame: @escaping @Sendable (Data) async throws -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        receiveFrameOperation = receiveFrame
        sendFrameOperation = sendFrame
        closeOperation = close
    }

    func receiveFrame(maximumBytes: Int) async throws -> Data? {
        try await receiveFrameOperation(maximumBytes)
    }

    func sendFrame(_ frame: Data) async throws {
        try await sendFrameOperation(frame)
    }

    func close() async {
        await closeOperation()
    }
}
