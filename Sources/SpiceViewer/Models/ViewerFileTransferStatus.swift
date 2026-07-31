import Foundation
import SwiftSpice

package struct ViewerFileTransferItem: Sendable, Equatable, Identifiable {
    package enum Phase: Sendable, Equatable {
        case queued
        case awaitingGuestApproval
        case transferring
        case completed
        case cancelled
        case failed(String)
    }

    package let id: SpiceFileTransferID
    package let name: String
    package let totalBytes: UInt64
    package var sentBytes: UInt64
    package var phase: Phase

    package var isActive: Bool {
        switch phase {
        case .queued, .awaitingGuestApproval, .transferring:
            true
        case .completed, .cancelled, .failed:
            false
        }
    }

    package var summary: String {
        switch phase {
        case .queued:
            "Queued"
        case .awaitingGuestApproval:
            "Waiting for guest"
        case .transferring:
            totalBytes == 0 ? "Sending" : "\(sentBytes * 100 / totalBytes)%"
        case .completed:
            "Completed"
        case .cancelled:
            "Cancelled"
        case let .failed(reason):
            "Failed: \(reason)"
        }
    }
}

package struct ViewerFileTransferStatus: Sendable, Equatable {
    package private(set) var items: [ViewerFileTransferItem] = []
    package private(set) var submissionError: String?

    package var activeCount: Int {
        items.reduce(into: 0) { count, item in
            if item.isActive { count += 1 }
        }
    }

    package var label: String {
        if activeCount > 0 { return "Files \(activeCount)" }
        if submissionError != nil { return "File Error" }
        return "Files"
    }

    package mutating func consume(_ event: SpiceFileTransferEvent) {
        submissionError = nil
        switch event {
        case let .queued(id, name, totalBytes):
            items.removeAll { $0.id == id }
            items.insert(ViewerFileTransferItem(
                id: id,
                name: name,
                totalBytes: totalBytes,
                sentBytes: 0,
                phase: .queued
            ), at: 0)
            if items.count > 8 { items.removeLast(items.count - 8) }
        case let .awaitingGuestApproval(id):
            update(id) { $0.phase = .awaitingGuestApproval }
        case let .progress(id, sentBytes, _):
            update(id) {
                $0.sentBytes = sentBytes
                $0.phase = .transferring
            }
        case let .completed(id):
            update(id) {
                $0.sentBytes = $0.totalBytes
                $0.phase = .completed
            }
        case let .cancelled(id):
            update(id) { $0.phase = .cancelled }
        case let .failed(id, error):
            guard let id else {
                submissionError = error.description
                return
            }
            update(id) { $0.phase = .failed(error.description) }
        }
    }

    package mutating func recordSubmissionFailure(_ error: SpiceFileTransferError) {
        submissionError = error.description
    }

    package mutating func recordManagerFailure(_ reason: String) {
        submissionError = "agent manager failed: \(reason)"
    }

    private mutating func update(
        _ id: SpiceFileTransferID,
        body: (inout ViewerFileTransferItem) -> Void
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        body(&items[index])
    }
}
