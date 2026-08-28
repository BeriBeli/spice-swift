import Foundation
import Testing
@testable import SpiceCodecs

@Suite("Session codec task executor")
struct CodecTaskExecutorTests {
    @Test func admitsInFIFOOrderAndNeverExceedsConfiguredWidth() async throws {
        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 2,
            maximumPendingJobs: 64,
            maximumQueuedRetainedBytes: 256 * 1_024 * 1_024
        ))
        let gate = CodecOperationGate()

        let first = executorTask(executor, gate: gate, id: 0, retainedBytes: 10)
        await gate.waitUntilStarted(count: 1)
        let second = executorTask(executor, gate: gate, id: 1, retainedBytes: 20)
        await gate.waitUntilStarted(count: 2)
        let third = executorTask(executor, gate: gate, id: 2, retainedBytes: 30)
        await waitForExecutor(executor) { $0.queuedJobs == 1 }
        let fourth = executorTask(executor, gate: gate, id: 3, retainedBytes: 40)
        await waitForExecutor(executor) { $0.queuedJobs == 2 }

        var diagnostics = await executor.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 2)
        #expect(diagnostics.queuedJobs == 2)
        #expect(diagnostics.activeRetainedBytes == 30)
        #expect(diagnostics.queuedRetainedBytes == 70)
        #expect(diagnostics.currentRetainedBytes == 100)
        #expect(diagnostics.peakActiveJobs == 2)
        #expect(await gate.startedIDs == [0, 1])

        await gate.release(id: 0)
        await gate.waitUntilStarted(count: 3)
        #expect(await gate.startedIDs == [0, 1, 2])
        await gate.release(id: 1)
        await gate.waitUntilStarted(count: 4)
        #expect(await gate.startedIDs == [0, 1, 2, 3])
        await gate.release(id: 2)
        await gate.release(id: 3)

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

    @Test func rejectsTheSixtyFifthPendingJobWithoutLeakingState() async throws {
        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 64,
            maximumQueuedRetainedBytes: 256 * 1_024 * 1_024
        ))
        let gate = CodecOperationGate()
        let active = executorTask(executor, gate: gate, id: -1, retainedBytes: 1)
        await gate.waitUntilStarted(count: 1)

        var queued: [Task<Int, any Error>] = []
        queued.reserveCapacity(64)
        for id in 0..<64 {
            queued.append(executorTask(executor, gate: gate, id: id, retainedBytes: 1))
            await waitForExecutor(executor) { $0.queuedJobs == id + 1 }
        }
        let before = await executor.diagnosticsSnapshot()
        #expect(before.activeJobs == 1)
        #expect(before.queuedJobs == 64)
        #expect(before.queuedRetainedBytes == 64)
        #expect(before.peakQueuedJobs == 64)

        await #expect(throws: SpiceCodecTaskExecutorError.tooManyPendingJobs(
            actual: 65,
            maximum: 64
        )) {
            try await executeValue(executor, retainedByteCount: 1, value: 65)
        }
        var rejected = await executor.diagnosticsSnapshot()
        #expect(rejected.activeJobs == before.activeJobs)
        #expect(rejected.queuedJobs == before.queuedJobs)
        #expect(rejected.currentRetainedBytes == before.currentRetainedBytes)
        #expect(rejected.rejectedJobs == before.rejectedJobs + 1)

        for task in queued {
            task.cancel()
        }
        for task in queued {
            await #expect(throws: SpiceCodecTaskExecutorError.cancelled) {
                try await task.value
            }
        }
        await waitForExecutor(executor) {
            $0.queuedJobs == 0 && $0.queuedRetainedBytes == 0
        }
        await gate.release(id: -1)
        #expect(try await active.value == -1)
        rejected = await executor.diagnosticsSnapshot()
        #expect(rejected.activeJobs == 0)
        #expect(rejected.currentRetainedBytes == 0)
        #expect(rejected.completedJobs == 1)
        #expect(rejected.cancelledJobs == 64)
        #expect(rejected.rejectedJobs == 1)
    }

    @Test func queuedByteCancellationRestoresCapacityImmediately() async throws {
        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 4,
            maximumQueuedRetainedBytes: 3
        ))
        let gate = CodecOperationGate()
        let active = executorTask(executor, gate: gate, id: 0, retainedBytes: 10)
        await gate.waitUntilStarted(count: 1)
        let queued = executorTask(executor, gate: gate, id: 1, retainedBytes: 3)
        await waitForExecutor(executor) { $0.queuedRetainedBytes == 3 }

        await #expect(throws: SpiceCodecTaskExecutorError.queuedRetainedBytesExceeded(
            actual: 4,
            maximum: 3
        )) {
            try await executeValue(executor, retainedByteCount: 1, value: 2)
        }
        queued.cancel()
        await #expect(throws: SpiceCodecTaskExecutorError.cancelled) {
            try await queued.value
        }
        await waitForExecutor(executor) {
            $0.queuedJobs == 0 && $0.queuedRetainedBytes == 0
        }

        let replacement = executorTask(executor, gate: gate, id: 2, retainedBytes: 3)
        await waitForExecutor(executor) {
            $0.queuedJobs == 1 && $0.queuedRetainedBytes == 3
        }
        await gate.release(id: 0)
        await gate.waitUntilStarted(count: 2)
        #expect(await gate.startedIDs == [0, 2])
        await gate.release(id: 2)
        #expect(try await active.value == 0)
        #expect(try await replacement.value == 2)

        let diagnostics = await executor.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 0)
        #expect(diagnostics.queuedJobs == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.cancelledJobs == 1)
        #expect(diagnostics.rejectedJobs == 1)
    }

    @Test func activeCancellationEventuallyReleasesItsPermitAndBytes() async throws {
        let executor = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 1,
            maximumQueuedRetainedBytes: 1
        ))
        let probe = CancellationAwareOperationProbe()
        let operation: @Sendable () async -> Void = {
            await probe.run()
        }
        let cancelled = Task {
            try await executor.execute(retainedByteCount: 7, operation: operation)
        }
        await probe.waitUntilStarted()
        #expect(await executor.diagnosticsSnapshot().activeRetainedBytes == 7)

        cancelled.cancel()
        await probe.waitUntilCancelled()
        await #expect(throws: SpiceCodecTaskExecutorError.cancelled) {
            try await cancelled.value
        }
        await waitForExecutor(executor) {
            $0.activeJobs == 0 && $0.currentRetainedBytes == 0
        }
        let diagnostics = await executor.diagnosticsSnapshot()
        #expect(diagnostics.cancelledJobs == 1)
        #expect(diagnostics.completedJobs == 0)
        #expect(diagnostics.failedJobs == 0)
    }

    @Test func throwingFailureCloseAndInvalidLimitsReleaseStateExactlyOnce() async throws {
        let throwing = SpiceCodecTaskExecutor()
        await #expect(throws: SpiceCodecTaskExecutionError<SpiceCodecError>.operation(
            .decodeFailed
        )) {
            try await throwing.executeThrowing(retainedByteCount: 11) {
                () async throws(SpiceCodecError) -> Int in
                throw .decodeFailed
            }
        }
        var diagnostics = await throwing.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.completedJobs == 0)
        #expect(diagnostics.failedJobs == 1)
        #expect(diagnostics.cancelledJobs == 0)

        await #expect(
            throws: SpiceCodecTaskExecutionError<
                SpiceCodecTaskExecutionError<SpiceCodecError>
            >.operation(.operation(.decodeFailed))
        ) {
            try await throwing.executeThrowing(retainedByteCount: 13) {
                () async throws(SpiceCodecTaskExecutionError<SpiceCodecError>) -> Int in
                throw .operation(.decodeFailed)
            }
        }
        diagnostics = await throwing.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.completedJobs == 0)
        #expect(diagnostics.failedJobs == 2)
        #expect(diagnostics.cancelledJobs == 0)

        let invalid = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 0,
            maximumPendingJobs: 0,
            maximumQueuedRetainedBytes: 0
        ))
        await #expect(throws: SpiceCodecTaskExecutorError.invalidLimits) {
            try await executeValue(invalid, retainedByteCount: 0, value: 1)
        }
        diagnostics = await invalid.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 0)
        #expect(diagnostics.queuedJobs == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.rejectedJobs == 1)

        let closing = SpiceCodecTaskExecutor(limits: .init(
            maximumConcurrentJobs: 1,
            maximumPendingJobs: 1,
            maximumQueuedRetainedBytes: 1
        ))
        let gate = CodecOperationGate()
        let active = executorTask(closing, gate: gate, id: 0, retainedBytes: 1)
        await gate.waitUntilStarted(count: 1)
        let queued = executorTask(closing, gate: gate, id: 1, retainedBytes: 1)
        await waitForExecutor(closing) { $0.queuedJobs == 1 }
        await closing.close()
        await #expect(throws: SpiceCodecTaskExecutorError.closed) {
            try await queued.value
        }
        await #expect(throws: SpiceCodecTaskExecutorError.closed) {
            try await executeValue(closing, retainedByteCount: 0, value: 2)
        }
        diagnostics = await closing.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 1)
        #expect(diagnostics.queuedJobs == 0)
        #expect(diagnostics.activeRetainedBytes == 1)
        #expect(diagnostics.queuedRetainedBytes == 0)
        #expect(diagnostics.cancelledJobs == 1)
        #expect(diagnostics.rejectedJobs == 1)
        await gate.release(id: 0)
        #expect(try await active.value == 0)
        diagnostics = await closing.diagnosticsSnapshot()
        #expect(diagnostics.activeJobs == 0)
        #expect(diagnostics.currentRetainedBytes == 0)
        #expect(diagnostics.completedJobs == 1)
    }
}

private func executorTask(
    _ executor: SpiceCodecTaskExecutor,
    gate: CodecOperationGate,
    id: Int,
    retainedBytes: Int
) -> Task<Int, any Error> {
    let operation: @Sendable () async -> Int = {
        await gate.run(id: id)
    }
    return Task {
        try await executor.execute(
            retainedByteCount: retainedBytes,
            operation: operation
        )
    }
}

private func executeValue(
    _ executor: SpiceCodecTaskExecutor,
    retainedByteCount: Int,
    value: Int
) async throws(SpiceCodecTaskExecutorError) -> Int {
    let operation: @Sendable () async -> Int = { value }
    return try await executor.execute(
        retainedByteCount: retainedByteCount,
        operation: operation
    )
}

private func waitForExecutor(
    _ executor: SpiceCodecTaskExecutor,
    where predicate: (SpiceCodecTaskExecutorDiagnostics) -> Bool
) async {
    for _ in 0..<10_000 {
        if predicate(await executor.diagnosticsSnapshot()) { return }
        await Task.yield()
    }
    Issue.record("executor diagnostics did not reach the expected state")
}

private actor CodecOperationGate {
    private(set) var startedIDs: [Int] = []
    private var releases: [Int: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func run(id: Int) async -> Int {
        startedIDs.append(id)
        let ready = startWaiters.filter { startedIDs.count >= $0.0 }
        startWaiters.removeAll { startedIDs.count >= $0.0 }
        for (_, continuation) in ready { continuation.resume() }
        await withCheckedContinuation { releases[id] = $0 }
        return id
    }

    func waitUntilStarted(count: Int) async {
        guard startedIDs.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    func release(id: Int) {
        releases.removeValue(forKey: id)?.resume()
    }
}

private actor CancellationAwareOperationProbe {
    private var started = false
    private var cancelled = false
    private var release: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

    func run() async {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters.removeAll()
        await withTaskCancellationHandler {
            await withCheckedContinuation { release = $0 }
        } onCancel: {
            Task { await self.cancelOperation() }
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func waitUntilCancelled() async {
        guard !cancelled else { return }
        await withCheckedContinuation { cancellationWaiters.append($0) }
    }

    private func cancelOperation() {
        cancelled = true
        release?.resume()
        release = nil
        for waiter in cancellationWaiters { waiter.resume() }
        cancellationWaiters.removeAll()
    }
}
