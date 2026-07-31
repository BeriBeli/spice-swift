import SwiftSpice
import Testing
@testable import SpiceViewer

@Suite("Viewer file-transfer status")
struct ViewerFileTransferStatusTests {
    @Test("tracks bounded progress and terminal states")
    func tracksTransfer() {
        let id = SpiceFileTransferID(rawValue: 7)
        var status = ViewerFileTransferStatus()
        status.consume(.queued(id: id, name: "fixture.bin", totalBytes: 10))
        #expect(status.activeCount == 1)
        status.consume(.awaitingGuestApproval(id: id))
        #expect(status.items[0].summary == "Waiting for guest")
        status.consume(.progress(id: id, sentBytes: 4, totalBytes: 10))
        #expect(status.items[0].summary == "40%")
        status.consume(.completed(id: id))
        #expect(status.activeCount == 0)
        #expect(status.items[0].summary == "Completed")
    }

    @Test("surfaces submission and per-transfer failures")
    func tracksFailures() {
        let id = SpiceFileTransferID(rawValue: 9)
        var status = ViewerFileTransferStatus()
        status.recordSubmissionFailure(.agentUnavailable)
        #expect(status.label == "File Error")
        status.consume(.queued(id: id, name: "x", totalBytes: 1))
        status.consume(.failed(id: id, .disabledByGuest))
        #expect(status.items[0].phase == .failed("guest disabled file transfer"))
    }
}
