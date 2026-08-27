import Foundation
import Synchronization
import Testing
@testable import SwiftSpice

@Suite("Bounded filesystem task executor")
struct SpiceFilesystemTaskExecutorTests {
    @Test func defaultAdmissionIsFIFOAndNeverExceedsWidthTwo() async throws {
        let limits = SpiceFilesystemTaskExecutorLimits()
        #expect(limits.maximumConcurrentJobs == 2)
        #expect(limits.maximumPendingJobs == 64)
        #expect(limits.maximumQueuedRetainedBytes == 256 * 1_024 * 1_024)

        let executor = SpiceFilesystemTaskExecutor(limits: limits)
        let gate = FilesystemOperationGate()
        let first = filesystemTask(executor, gate: gate, id: 0, retainedBytes: 10)
        try #require(await gate.waitUntilAnotherOperationStarts())
        let second = filesystemTask(executor, gate: gate, id: 1, retainedBytes: 20)
        try #require(await gate.waitUntilAnotherOperationStarts())
        let third = filesystemTask(executor, gate: gate, id: 2, retainedBytes: 30)
        await waitForFilesystemExecutor(executor) { $0.queuedJobs == 1 }
        let fourth = filesystemTask(executor, gate: gate, id: 3, retainedBytes: 40)
        await waitForFilesystemExecutor(executor) { $0.queuedJobs == 2 }

        var diagnostics = await executor.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 2)
        #expect(diagnostics.queuedJobs == 2)
        #expect(diagnostics.activeRetainedBytes == 30)
        #expect(diagnostics.queuedRetainedBytes == 70)
        #expect(diagnostics.currentRetainedBytes == 100)
        #expect(diagnostics.peakActiveJobs == 2)
        #expect(gate.startedIDs == [0, 1])

        gate.release(id: 0)
        try #require(await gate.waitUntilAnotherOperationStarts())
        #expect(gate.startedIDs == [0, 1, 2])
        gate.release(id: 1)
        try #require(await gate.waitUntilAnotherOperationStarts())
        #expect(gate.startedIDs == [0, 1, 2, 3])
        gate.release(id: 2)
        gate.release(id: 3)

        #expect(try await first.value == 0)
        #expect(try await second.value == 1)
        #expect(try await third.value == 2)
        #expect(try await fourth.value == 3)
        diagnostics = await executor.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 0)
        #expect(diagnostics.queuedJobs == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.completedJobs == 4)
        #expect(diagnostics.failedJobs == 0)
        #expect(diagnostics.cancelledJobs == 0)
        #expect(diagnostics.rejectedJobs == 0)
    }

    @Test func pendingAndRetainedByteLimitsRejectWithoutLeakingCapacity() async throws {
        let executor = SpiceFilesystemTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 2,
            maximumQueuedRetainedBytes: 3
        ))
        let gate = FilesystemOperationGate()
        let active = filesystemTask(executor, gate: gate, id: 0, retainedBytes: 10)
        try #require(await gate.waitUntilAnotherOperationStarts())
        let firstQueued = filesystemTask(executor, gate: gate, id: 1, retainedBytes: 1)
        await waitForFilesystemExecutor(executor) { $0.queuedRetainedBytes == 1 }
        let secondQueued = filesystemTask(executor, gate: gate, id: 2, retainedBytes: 2)
        await waitForFilesystemExecutor(executor) { $0.queuedRetainedBytes == 3 }

        await #expect(throws: SpiceFilesystemTaskExecutorError.tooManyPendingJobs(
            actual: 3,
            maximum: 2
        )) {
            try await executeFilesystemValue(executor, retainedByteCount: 0, value: 3)
        }
        firstQueued.cancel()
        secondQueued.cancel()
        await #expect(throws: SpiceFilesystemTaskExecutorError.cancelled) {
            try await firstQueued.value
        }
        await #expect(throws: SpiceFilesystemTaskExecutorError.cancelled) {
            try await secondQueued.value
        }
        await waitForFilesystemExecutor(executor) {
            $0.queuedJobs == 0 && $0.queuedRetainedBytes == 0
        }

        let replacement = filesystemTask(executor, gate: gate, id: 4, retainedBytes: 3)
        await waitForFilesystemExecutor(executor) { $0.queuedRetainedBytes == 3 }
        await #expect(throws: SpiceFilesystemTaskExecutorError.queuedRetainedBytesExceeded(
            actual: 4,
            maximum: 3
        )) {
            try await executeFilesystemValue(executor, retainedByteCount: 1, value: 5)
        }
        replacement.cancel()
        await #expect(throws: SpiceFilesystemTaskExecutorError.cancelled) {
            try await replacement.value
        }
        gate.release(id: 0)
        #expect(try await active.value == 0)

        let diagnostics = await executor.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 0)
        #expect(diagnostics.queuedJobs == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.completedJobs == 1)
        #expect(diagnostics.cancelledJobs == 3)
        #expect(diagnostics.rejectedJobs == 2)
    }

    @Test func activeCancellationAndCloseReleaseAllPermitsAndBytes() async throws {
        let executor = SpiceFilesystemTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 1,
            maximumQueuedRetainedBytes: 8
        ))
        let gate = FilesystemOperationGate()
        let active = filesystemTask(executor, gate: gate, id: 0, retainedBytes: 7)
        try #require(await gate.waitUntilAnotherOperationStarts())
        let queued = filesystemTask(executor, gate: gate, id: 1, retainedBytes: 8)
        await waitForFilesystemExecutor(executor) { $0.queuedJobs == 1 }

        active.cancel()
        await executor.close()
        await #expect(throws: SpiceFilesystemTaskExecutorError.closed) {
            try await queued.value
        }
        gate.release(id: 0)
        await #expect(throws: SpiceFilesystemTaskExecutorError.cancelled) {
            try await active.value
        }
        await waitForFilesystemExecutor(executor) {
            $0.activeJobs == 0 && $0.currentRetainedBytes == 0
        }

        let diagnostics = await executor.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 0)
        #expect(diagnostics.queuedJobs == 0)
        #expect(diagnostics.activeRetainedBytes == 0)
        #expect(diagnostics.queuedRetainedBytes == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.cancelledJobs == 2)
        #expect(diagnostics.completedJobs == 0)
    }
}

private func filesystemTask(
    _ executor: SpiceFilesystemTaskExecutor,
    gate: FilesystemOperationGate,
    id: Int,
    retainedBytes: Int
) -> Task<Int, any Error> {
    Task {
        try await executor.execute(retainedByteCount: retainedBytes) {
            gate.run(id: id)
        }
    }
}

private func executeFilesystemValue(
    _ executor: SpiceFilesystemTaskExecutor,
    retainedByteCount: Int,
    value: Int
) async throws(SpiceFilesystemTaskExecutorError) -> Int {
    try await executor.execute(retainedByteCount: retainedByteCount) { value }
}

private func waitForFilesystemExecutor(
    _ executor: SpiceFilesystemTaskExecutor,
    where predicate: (SpiceFilesystemTaskExecutorDiagnostics) -> Bool
) async {
    for _ in 0..<10_000 {
        if predicate(await executor.diagnosticsSnapshot()) { return }
        await Task.yield()
    }
    Issue.record("filesystem executor diagnostics did not reach the expected state")
}

private final class FilesystemOperationGate: @unchecked Sendable {
    private struct State: Sendable {
        var startedIDs: [Int] = []
        var releases: [Int: DispatchSemaphore] = [:]
    }

    private let state = Mutex(State())
    private let started = DispatchSemaphore(value: 0)

    var startedIDs: [Int] {
        state.withLock(\.startedIDs)
    }

    func run(id: Int) -> Int {
        let release = DispatchSemaphore(value: 0)
        state.withLock { state in
            state.startedIDs.append(id)
            state.releases[id] = release
        }
        started.signal()
        release.wait()
        return id
    }

    func waitUntilAnotherOperationStarts() async -> Bool {
        await Task.detached { [started] in
            blockingWaitForFilesystemSemaphore(started)
        }.value
    }

    func release(id: Int) {
        state.withLock { $0.releases.removeValue(forKey: id) }?.signal()
    }
}

private func blockingWaitForFilesystemSemaphore(_ semaphore: DispatchSemaphore) -> Bool {
    semaphore.wait(timeout: .now() + 10) == .success
}
