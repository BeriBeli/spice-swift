import Foundation

public struct SpiceFileTransferID: RawRepresentable, Sendable, Hashable, Equatable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum SpiceFileTransferError: Error, Sendable, Equatable, CustomStringConvertible {
    case agentManagerNotRunning
    case agentUnavailable
    case disabledByGuest
    case tooManyConcurrentTransfers(maximum: Int)
    case invalidFile(String)
    case fileTooLarge(actual: UInt64, maximum: UInt64)
    case invalidAgentResponse(String)
    case localReadFailed(String)
    case transport(SpiceError)

    public var description: String {
        switch self {
        case .agentManagerNotRunning:
            "agent manager is not running"
        case .agentUnavailable:
            "guest agent is unavailable"
        case .disabledByGuest:
            "guest disabled file transfer"
        case let .tooManyConcurrentTransfers(maximum):
            "maximum concurrent file transfers reached (\(maximum))"
        case let .invalidFile(reason):
            "invalid transfer source: \(reason)"
        case let .fileTooLarge(actual, maximum):
            "file size \(actual) exceeds configured maximum \(maximum)"
        case let .invalidAgentResponse(reason):
            "invalid file-transfer agent response: \(reason)"
        case let .localReadFailed(reason):
            "file read failed: \(reason)"
        case let .transport(error):
            "file-transfer transport failed: \(error)"
        }
    }
}

public enum SpiceFileTransferEvent: Sendable, Equatable {
    case queued(id: SpiceFileTransferID, name: String, totalBytes: UInt64)
    case awaitingGuestApproval(id: SpiceFileTransferID)
    case progress(id: SpiceFileTransferID, sentBytes: UInt64, totalBytes: UInt64)
    case completed(id: SpiceFileTransferID)
    case cancelled(id: SpiceFileTransferID)
    case failed(id: SpiceFileTransferID?, SpiceFileTransferError)
}

package enum FileTransferPhase: Sendable, Equatable {
    case queuedStart
    case awaitingGuestApproval
    case readyToRead
    case reading
    case readyToSend(Data)
    case awaitingCompletion
    case queuedCancellation
    case awaitingCancellation
    case queuedFailure(SpiceFileTransferError)
}

package struct FileTransferJob: Sendable, Equatable {
    package let id: SpiceFileTransferID
    package let source: URL
    package let name: String
    package let totalBytes: UInt64
    package var sentBytes: UInt64
    package var phase: FileTransferPhase
}
