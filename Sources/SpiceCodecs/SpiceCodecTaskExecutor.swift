import Dispatch
import Foundation

package struct SpiceCodecTaskExecutorLimits: Sendable, Equatable {
    package var maximumConcurrentJobs: Int
    package var maximumPendingJobs: Int
    package var maximumQueuedRetainedBytes: Int

    package init(
        maximumConcurrentJobs: Int = 2,
        maximumPendingJobs: Int = 64,
        maximumQueuedRetainedBytes: Int = 256 * 1_024 * 1_024
    ) {
        self.maximumConcurrentJobs = maximumConcurrentJobs
        self.maximumPendingJobs = maximumPendingJobs
        self.maximumQueuedRetainedBytes = maximumQueuedRetainedBytes
    }
}

package enum SpiceCodecTaskExecutorError: Error, Sendable, Equatable {
    case invalidLimits
    case invalidRetainedByteCount(Int)
    case tooManyPendingJobs(actual: Int, maximum: Int)
    case queuedRetainedBytesExceeded(actual: Int, maximum: Int)
    case cancelled
    case closed
}

package enum SpiceCodecTaskExecutionError<Failure>: Error, Sendable
where Failure: Error & Sendable {
    case executor(SpiceCodecTaskExecutorError)
    case operation(Failure)
}

extension SpiceCodecTaskExecutionError: Equatable where Failure: Equatable {}

package struct SpiceCodecTaskExecutorDiagnostics: Sendable, Equatable {
    package let activeJobs: Int
    package let queuedJobs: Int
    package let activeRetainedBytes: Int
    package let queuedRetainedBytes: Int
    package let currentRetainedBytes: Int
    package let peakActiveJobs: Int
    package let peakQueuedJobs: Int
    package let peakRetainedBytes: Int
    package let completedJobs: UInt64
    package let failedJobs: UInt64
    package let cancelledJobs: UInt64
    package let rejectedJobs: UInt64
}

/// One per SPICE Session. Admission is FIFO and bounded independently from the
/// GCD-backed Swift task executor on which admitted codec continuations run.
package final class SpiceCodecTaskExecutor: Sendable {
    private let taskExecutor = SpiceCodecGCDTaskExecutor()
    private let admission: SpiceCodecTaskAdmission

    package init(limits: SpiceCodecTaskExecutorLimits = .init()) {
        admission = SpiceCodecTaskAdmission(limits: limits)
    }

    package func execute<Success: Sendable>(
        retainedByteCount: Int,
        operation: @escaping @Sendable () async -> Success
    ) async throws(SpiceCodecTaskExecutorError) -> Success {
        let ticket = UUID()
        try await admission.acquire(ticket: ticket, retainedByteCount: retainedByteCount)
        if Task.isCancelled {
            await admission.finish(ticket: ticket, outcome: .cancelled)
            throw .cancelled
        }

        let value = await withTaskExecutorPreference(taskExecutor) {
            await operation()
        }
        if Task.isCancelled {
            await admission.finish(ticket: ticket, outcome: .cancelled)
            throw .cancelled
        }
        await admission.finish(ticket: ticket, outcome: .completed)
        return value
    }

    package func executeThrowing<Success: Sendable, Failure: Error & Sendable>(
        retainedByteCount: Int,
        operation: @escaping @Sendable () async throws(Failure) -> Success
    ) async throws(SpiceCodecTaskExecutionError<Failure>) -> Success {
        let ticket = UUID()
        do {
            try await admission.acquire(ticket: ticket, retainedByteCount: retainedByteCount)
        } catch let error {
            throw .executor(error)
        }
        if Task.isCancelled {
            await admission.finish(ticket: ticket, outcome: .cancelled)
            throw .executor(.cancelled)
        }

        let result: Result<Success, Failure>
        do {
            result = .success(try await withTaskExecutorPreference(taskExecutor) {
                try await operation()
            })
        } catch let error as Failure {
            result = .failure(error)
        } catch {
            preconditionFailure("typed codec operation emitted unexpected error: \(error)")
        }
        if Task.isCancelled {
            await admission.finish(ticket: ticket, outcome: .cancelled)
            throw .executor(.cancelled)
        }
        switch result {
        case let .success(value):
            await admission.finish(ticket: ticket, outcome: .completed)
            return value
        case let .failure(error):
            await admission.finish(ticket: ticket, outcome: .failed)
            throw .operation(error)
        }
    }

    package func diagnosticsSnapshot() async -> SpiceCodecTaskExecutorDiagnostics {
        await admission.diagnosticsSnapshot()
    }

    package func close() async {
        await admission.close()
    }
}

private final class SpiceCodecGCDTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "org.swiftspice.codec-task-executor",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let unownedExecutor = asUnownedTaskExecutor()
        queue.async {
            unownedJob.runSynchronously(on: unownedExecutor)
        }
    }
}

private actor SpiceCodecTaskAdmission {
    fileprivate enum Outcome {
        case completed
        case failed
        case cancelled
    }

    private struct Waiter {
        let ticket: UUID
        let retainedByteCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let limits: SpiceCodecTaskExecutorLimits
    private var active: [UUID: Int] = [:]
    private var queued: [Waiter] = []
    private var queuedRetainedBytes = 0
    private var peakActiveJobs = 0
    private var peakQueuedJobs = 0
    private var peakRetainedBytes = 0
    private var completedJobs: UInt64 = 0
    private var failedJobs: UInt64 = 0
    private var cancelledJobs: UInt64 = 0
    private var rejectedJobs: UInt64 = 0
    private var isClosed = false

    init(limits: SpiceCodecTaskExecutorLimits) {
        self.limits = limits
    }

    func acquire(
        ticket: UUID,
        retainedByteCount: Int
    ) async throws(SpiceCodecTaskExecutorError) {
        guard limits.maximumConcurrentJobs > 0,
              limits.maximumPendingJobs >= 0,
              limits.maximumQueuedRetainedBytes >= 0
        else {
            reject()
            throw .invalidLimits
        }
        guard retainedByteCount >= 0 else {
            reject()
            throw .invalidRetainedByteCount(retainedByteCount)
        }
        guard !isClosed else {
            reject()
            throw .closed
        }
        guard !Task.isCancelled else {
            cancel()
            throw .cancelled
        }
        if active.count < limits.maximumConcurrentJobs, queued.isEmpty {
            activate(ticket: ticket, retainedByteCount: retainedByteCount)
            return
        }

        let actualPending = queued.count + 1
        guard actualPending <= limits.maximumPendingJobs else {
            reject()
            throw .tooManyPendingJobs(
                actual: actualPending,
                maximum: limits.maximumPendingJobs
            )
        }
        let (actualBytes, byteOverflow) = queuedRetainedBytes.addingReportingOverflow(
            retainedByteCount
        )
        guard !byteOverflow, actualBytes <= limits.maximumQueuedRetainedBytes else {
            reject()
            throw .queuedRetainedBytesExceeded(
                actual: byteOverflow ? .max : actualBytes,
                maximum: limits.maximumQueuedRetainedBytes
            )
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, any Error>) in
                    queued.append(Waiter(
                        ticket: ticket,
                        retainedByteCount: retainedByteCount,
                        continuation: continuation
                    ))
                    queuedRetainedBytes = actualBytes
                    peakQueuedJobs = max(peakQueuedJobs, queued.count)
                    updateRetainedPeak()
                }
            } onCancel: {
                Task { await self.cancelQueued(ticket: ticket) }
            }
        } catch let error as SpiceCodecTaskExecutorError {
            throw error
        } catch {
            // The continuation is stored privately and is resumed only with
            // SpiceCodecTaskExecutorError. Keep the typed API total on older
            // Swift runtimes whose continuation failure is fixed to any Error.
            throw .cancelled
        }
    }

    func finish(ticket: UUID, outcome: Outcome) {
        guard active.removeValue(forKey: ticket) != nil else { return }
        switch outcome {
        case .completed: increment(&completedJobs)
        case .failed: increment(&failedJobs)
        case .cancelled: cancel()
        }
        promoteWaiters()
    }

    func diagnosticsSnapshot() -> SpiceCodecTaskExecutorDiagnostics {
        let activeBytes = currentActiveRetainedBytes
        return SpiceCodecTaskExecutorDiagnostics(
            activeJobs: active.count,
            queuedJobs: queued.count,
            activeRetainedBytes: activeBytes,
            queuedRetainedBytes: queuedRetainedBytes,
            currentRetainedBytes: addingSaturated(activeBytes, queuedRetainedBytes),
            peakActiveJobs: peakActiveJobs,
            peakQueuedJobs: peakQueuedJobs,
            peakRetainedBytes: peakRetainedBytes,
            completedJobs: completedJobs,
            failedJobs: failedJobs,
            cancelledJobs: cancelledJobs,
            rejectedJobs: rejectedJobs
        )
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        let waiters = queued
        queued.removeAll(keepingCapacity: false)
        queuedRetainedBytes = 0
        for waiter in waiters {
            cancel()
            waiter.continuation.resume(throwing: SpiceCodecTaskExecutorError.closed)
        }
    }

    private func cancelQueued(ticket: UUID) {
        guard let index = queued.firstIndex(where: { $0.ticket == ticket }) else { return }
        let waiter = queued.remove(at: index)
        queuedRetainedBytes -= waiter.retainedByteCount
        cancel()
        waiter.continuation.resume(throwing: SpiceCodecTaskExecutorError.cancelled)
    }

    private func activate(ticket: UUID, retainedByteCount: Int) {
        active[ticket] = retainedByteCount
        peakActiveJobs = max(peakActiveJobs, active.count)
        updateRetainedPeak()
    }

    private func promoteWaiters() {
        while !isClosed,
              active.count < limits.maximumConcurrentJobs,
              !queued.isEmpty
        {
            let waiter = queued.removeFirst()
            queuedRetainedBytes -= waiter.retainedByteCount
            activate(ticket: waiter.ticket, retainedByteCount: waiter.retainedByteCount)
            waiter.continuation.resume()
        }
    }

    private func updateRetainedPeak() {
        peakRetainedBytes = max(
            peakRetainedBytes,
            addingSaturated(currentActiveRetainedBytes, queuedRetainedBytes)
        )
    }

    private var currentActiveRetainedBytes: Int {
        active.values.reduce(into: 0) { total, bytes in
            total = addingSaturated(total, bytes)
        }
    }

    private func addingSaturated(_ lhs: Int, _ rhs: Int) -> Int {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }

    private func reject() {
        increment(&rejectedJobs)
    }

    private func cancel() {
        increment(&cancelledJobs)
    }

    private func increment(_ value: inout UInt64) {
        value = value == .max ? .max : value + 1
    }
}
