import Foundation
import SpiceCore
import SpiceProtocol

package enum AgentOutboundPriority: Int, Sendable, Comparable {
    case low
    case normal
    case high

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package enum AgentOutboundCancellationCompletionPolicy: Sendable {
    /// Preserve the public caller contract: cancellation after a physical
    /// write starts completes the caller immediately while wire draining
    /// continues in the scheduler.
    case caller
    /// Keep the logical owner joined to the scheduler until the active message
    /// physically completes or its Agent generation reaches another terminal
    /// state. Used by semantic managers during lifecycle invalidation.
    case physicalTerminal
}

package protocol AgentOutboundClock: Sendable {
    func sleep(for duration: Duration) async throws
}

package struct ContinuousAgentOutboundClock: AgentOutboundClock {
    package init() {}

    package func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

package struct AgentOutboundSchedulerLimits: Sendable, Equatable {
    package let maximumMessages: Int
    package let maximumPayloadBytes: Int
    package let normalPayloadBytes: Int
    package let lowPayloadBytes: Int
    package let maximumQueuedLowMessages: Int

    package init(
        maximumMessageDataBytes: Int,
        maximumMessages: Int = 8,
        controlReserveBytes: Int = 64 * 1_024,
        maximumQueuedLowMessages: Int = 1
    ) {
        let dataLimit = max(0, maximumMessageDataBytes)
        let reserve = max(0, controlReserveBytes)
        let (normalLimit, normalOverflow) = dataLimit.addingReportingOverflow(reserve)
        let safeNormalLimit = normalOverflow ? Int.max : normalLimit
        let (totalLimit, totalOverflow) = safeNormalLimit.addingReportingOverflow(reserve)

        self.maximumMessages = max(1, maximumMessages)
        maximumPayloadBytes = totalOverflow ? Int.max : totalLimit
        normalPayloadBytes = safeNormalLimit
        lowPayloadBytes = dataLimit
        self.maximumQueuedLowMessages = max(0, maximumQueuedLowMessages)
    }
}

package struct AgentOutboundScheduler {
    package typealias Completion = @Sendable (Result<Void, ChannelError>) -> Void

    package enum EnqueueResult {
        case accepted
        case queueFull
        case requiredControlCannotFit
    }

    package enum CancellationResult {
        case removed(Completion)
        case detached(Completion)
        case deferredToPhysicalTerminal
        case notFound
    }

    package enum WriteResult {
        case notActive
        case inProgress
        case completed(Completion?, cancelledAfterStart: Bool)
    }

    package struct RemovedRequest {
        package let completion: Completion?
        package let hasStarted: Bool
    }

    private struct Request {
        let id: UInt64
        let priority: AgentOutboundPriority
        let payload: VDAgentWireEncoder.EncodedMessage
        let cancellationCompletionPolicy: AgentOutboundCancellationCompletionPolicy
        var completion: Completion?
        var nextFragmentIndex = 0
        var cancelledAfterStart = false

        var hasWrittenFragment: Bool {
            nextFragmentIndex > 0
        }
    }

    private static let weightedPriorities: [AgentOutboundPriority] =
        Array(repeating: .high, count: 8)
            + Array(repeating: .normal, count: 4)
            + [.low]

    private let limits: AgentOutboundSchedulerLimits
    private var nextID: UInt64 = 1
    private var active: Request?
    private var highQueue: [Request] = []
    private var normalQueue: [Request] = []
    private var lowQueue: [Request] = []
    private var weightedCursor = 0
    private(set) package var retainedPayloadBytes = 0
    private(set) package var retainedWireBytes = 0
    private(set) package var fragmentMaterializationCount = 0
    private(set) package var peakMaterializedFragmentBytes = 0

    package init(
        limits: AgentOutboundSchedulerLimits = .init(
            maximumMessageDataBytes: 16 * 1_024 * 1_024
        )
    ) {
        self.limits = limits
    }

    // Swift 6.3.3 release CMO can produce invalid lexical borrow lifetimes
    // when active-state boundaries inline into MainChannel's async actor code.
    // Keep every access to `active` isolated until the toolchain is fixed.
    @inline(never)
    package var isIdle: Bool {
        active == nil && queuedCount == 0
    }

    @inline(never)
    package var pendingCount: Int {
        queuedCount + (active == nil ? 0 : 1)
    }

    @inline(never)
    package var activeHasWrittenFragment: Bool {
        active?.hasWrittenFragment == true
    }

    @inline(never)
    package var activeID: UInt64? {
        active?.id
    }

    package var queuedLowCount: Int {
        lowQueue.count
    }

    package mutating func allocateID() -> UInt64 {
        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        return id
    }

    package mutating func enqueue(
        id: UInt64,
        payload: consuming VDAgentWireEncoder.EncodedMessage,
        priority: AgentOutboundPriority,
        requiredControl: Bool,
        cancellationCompletionPolicy: AgentOutboundCancellationCompletionPolicy = .caller,
        completion: @escaping Completion
    ) -> EnqueueResult {
        let payloadByteCount = payload.payloadByteCount
        let wireByteCount = payload.wireByteCount
        // Admission uses only the descriptor's checked counts.  No fragment is
        // assembled, and the single logical payload is retained only after the
        // request has been accepted.
        guard canAdmit(
            payloadByteCount: payloadByteCount,
            wireByteCount: wireByteCount,
            priority: priority
        ) else {
            return requiredControl && priority == .high
                ? .requiredControlCannotFit
                : .queueFull
        }

        let request = Request(
            id: id,
            priority: priority,
            payload: payload,
            cancellationCompletionPolicy: cancellationCompletionPolicy,
            completion: completion
        )
        queue(request)
        retainedPayloadBytes += payloadByteCount
        retainedWireBytes += wireByteCount
        return .accepted
    }

    @inline(never)
    package mutating func activateNextIfNeeded() -> UInt64? {
        guard active == nil, queuedCount > 0 else {
            return active?.id
        }
        for offset in Self.weightedPriorities.indices {
            let index = (weightedCursor + offset) % Self.weightedPriorities.count
            let priority = Self.weightedPriorities[index]
            guard let request = popFirst(priority: priority) else { continue }
            weightedCursor = (index + 1) % Self.weightedPriorities.count
            active = request
            return request.id
        }
        return nil
    }

    @inline(never)
    package mutating func activeFragment() -> (id: UInt64, data: Data)? {
        guard let active,
              let fragment = active.payload.fragment(at: active.nextFragmentIndex) else {
            return nil
        }
        fragmentMaterializationCount += 1
        peakMaterializedFragmentBytes = max(peakMaterializedFragmentBytes, fragment.count)
        return (active.id, fragment)
    }

    @inline(never)
    package mutating func didWriteFragment(id: UInt64) -> WriteResult {
        guard var request = active, request.id == id else { return .notActive }
        request.nextFragmentIndex += 1
        guard request.nextFragmentIndex == request.payload.fragmentCount else {
            active = request
            return .inProgress
        }
        retainedPayloadBytes -= request.payload.payloadByteCount
        retainedWireBytes -= request.payload.wireByteCount
        active = nil
        return .completed(
            request.completion,
            cancelledAfterStart: request.cancelledAfterStart
        )
    }

    @inline(never)
    package mutating func cancel(
        id: UInt64,
        writeInFlightID: UInt64?
    ) -> CancellationResult {
        if var request = active, request.id == id {
            guard let completion = request.completion else { return .notFound }
            if !request.hasWrittenFragment, writeInFlightID != id {
                retainedPayloadBytes -= request.payload.payloadByteCount
                retainedWireBytes -= request.payload.wireByteCount
                active = nil
                return .removed(completion)
            }
            switch request.cancellationCompletionPolicy {
            case .caller:
                request.completion = nil
                active = request
                return .detached(completion)
            case .physicalTerminal:
                request.cancelledAfterStart = true
                active = request
                return .deferredToPhysicalTerminal
            }
        }

        for priority in [AgentOutboundPriority.high, .normal, .low] {
            guard let request = removeQueued(id: id, priority: priority) else { continue }
            retainedPayloadBytes -= request.payload.payloadByteCount
            retainedWireBytes -= request.payload.wireByteCount
            guard let completion = request.completion else { return .notFound }
            return .removed(completion)
        }
        return .notFound
    }

    @inline(never)
    package mutating func removeUnstartedForMigration(
        writeInFlightID: UInt64?
    ) -> [RemovedRequest] {
        var removed = removeAllQueued().map {
            RemovedRequest(completion: $0.completion, hasStarted: false)
        }
        if let request = active,
           !request.hasWrittenFragment,
           writeInFlightID != request.id {
            retainedPayloadBytes -= request.payload.payloadByteCount
            retainedWireBytes -= request.payload.wireByteCount
            active = nil
            removed.append(RemovedRequest(
                completion: request.completion,
                hasStarted: false
            ))
        }
        return removed
    }

    @inline(never)
    package mutating func removeAll(
        writeInFlightID: UInt64?
    ) -> [RemovedRequest] {
        var removed: [RemovedRequest] = []
        if let active {
            removed.append(RemovedRequest(
                completion: active.completion,
                hasStarted: active.hasWrittenFragment || writeInFlightID == active.id
            ))
        }
        removed.append(contentsOf: removeAllQueued().map {
            RemovedRequest(completion: $0.completion, hasStarted: false)
        })
        active = nil
        retainedPayloadBytes = 0
        retainedWireBytes = 0
        return removed
    }

    private var queuedCount: Int {
        highQueue.count + normalQueue.count + lowQueue.count
    }

    private func canAdmit(
        payloadByteCount: Int,
        wireByteCount: Int,
        priority: AgentOutboundPriority
    ) -> Bool {
        guard pendingCount < limits.maximumMessages else { return false }
        let (expectedWireBytes, wireOverflow) = payloadByteCount.addingReportingOverflow(
            VDAgentMessage.headerByteCount
        )
        guard !wireOverflow, wireByteCount == expectedWireBytes else { return false }
        let (newPayloadBytes, overflow) = retainedPayloadBytes.addingReportingOverflow(
            payloadByteCount
        )
        let (_, retainedWireOverflow) = retainedWireBytes.addingReportingOverflow(wireByteCount)
        guard !overflow, !retainedWireOverflow else { return false }

        switch priority {
        case .high:
            return newPayloadBytes <= limits.maximumPayloadBytes
        case .normal:
            return newPayloadBytes <= limits.normalPayloadBytes
        case .low:
            return lowQueue.count < limits.maximumQueuedLowMessages
                && newPayloadBytes <= limits.lowPayloadBytes
        }
    }

    private mutating func queue(_ request: Request) {
        switch request.priority {
        case .high:
            highQueue.append(request)
        case .normal:
            normalQueue.append(request)
        case .low:
            lowQueue.append(request)
        }
    }

    private mutating func popFirst(priority: AgentOutboundPriority) -> Request? {
        switch priority {
        case .high:
            return highQueue.isEmpty ? nil : highQueue.removeFirst()
        case .normal:
            return normalQueue.isEmpty ? nil : normalQueue.removeFirst()
        case .low:
            return lowQueue.isEmpty ? nil : lowQueue.removeFirst()
        }
    }

    private mutating func removeQueued(
        id: UInt64,
        priority: AgentOutboundPriority
    ) -> Request? {
        switch priority {
        case .high:
            guard let index = highQueue.firstIndex(where: { $0.id == id }) else { return nil }
            return highQueue.remove(at: index)
        case .normal:
            guard let index = normalQueue.firstIndex(where: { $0.id == id }) else { return nil }
            return normalQueue.remove(at: index)
        case .low:
            guard let index = lowQueue.firstIndex(where: { $0.id == id }) else { return nil }
            return lowQueue.remove(at: index)
        }
    }

    private mutating func removeAllQueued() -> [Request] {
        let requests = highQueue + normalQueue + lowQueue
        highQueue.removeAll(keepingCapacity: false)
        normalQueue.removeAll(keepingCapacity: false)
        lowQueue.removeAll(keepingCapacity: false)
        for request in requests {
            retainedPayloadBytes -= request.payload.payloadByteCount
            retainedWireBytes -= request.payload.wireByteCount
        }
        return requests
    }
}
