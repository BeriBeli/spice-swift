import Foundation
import Testing
@testable import SpiceChannels
@testable import SpiceCore
@testable import SpiceProtocol

@Suite("VDAgent outbound scheduler")
struct AgentOutboundSchedulerTests {
    @Test func weightedSelectionUsesEightFourOneCycle() throws {
        var scheduler = AgentOutboundScheduler(limits: .init(
            maximumMessageDataBytes: 1_024,
            maximumMessages: 32,
            maximumQueuedLowMessages: 4
        ))
        var priorities: [UInt64: AgentOutboundPriority] = [:]
        for priority in
            Array(repeating: AgentOutboundPriority.high, count: 10)
                + Array(repeating: .normal, count: 6)
                + Array(repeating: .low, count: 2) {
            let id = scheduler.allocateID()
            priorities[id] = priority
            #expect(scheduler.enqueue(
                id: id,
                payload: try payload(byteCount: 1),
                priority: priority,
                requiredControl: false,
                completion: { _ in }
            ).isAccepted)
        }

        var selected: [AgentOutboundPriority] = []
        for _ in 0..<13 {
            let candidate = scheduler.activateNextIfNeeded()
            let id = try #require(candidate)
            selected.append(try #require(priorities[id]))
            _ = scheduler.didWriteFragment(id: id)
        }
        #expect(selected == Array(repeating: .high, count: 8)
            + Array(repeating: .normal, count: 4)
            + [.low])
    }

    @Test func productionMessageBoundRejectsNinthLogicalMessage() throws {
        var scheduler = AgentOutboundScheduler(limits: .init(
            maximumMessageDataBytes: 1_024
        ))
        for _ in 0..<8 {
            #expect(scheduler.enqueue(
                id: scheduler.allocateID(),
                payload: try payload(byteCount: 1),
                priority: .normal,
                requiredControl: false,
                completion: { _ in }
            ).isAccepted)
        }
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 1),
            priority: .normal,
            requiredControl: false,
            completion: { _ in }
        ).isQueueFull)
    }

    @Test func payloadBudgetsReserveNormalAndHighControlCapacity() throws {
        var scheduler = AgentOutboundScheduler(limits: .init(
            maximumMessageDataBytes: 100,
            maximumMessages: 8,
            controlReserveBytes: 10
        ))
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 100),
            priority: .low,
            requiredControl: false,
            completion: { _ in }
        ).isAccepted)
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 10),
            priority: .normal,
            requiredControl: false,
            completion: { _ in }
        ).isAccepted)
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 10),
            priority: .high,
            requiredControl: false,
            completion: { _ in }
        ).isAccepted)
        #expect(scheduler.retainedPayloadBytes == 120)
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 1),
            priority: .high,
            requiredControl: false,
            completion: { _ in }
        ).isQueueFull)
    }

    @Test func onlyOneLowMessageMayWaitBehindActiveLowMessage() throws {
        var scheduler = AgentOutboundScheduler(limits: .init(
            maximumMessageDataBytes: 100
        ))
        let first = scheduler.allocateID()
        #expect(scheduler.enqueue(
            id: first,
            payload: try payload(byteCount: 1),
            priority: .low,
            requiredControl: false,
            completion: { _ in }
        ).isAccepted)
        #expect(scheduler.activateNextIfNeeded() == first)
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 1),
            priority: .low,
            requiredControl: false,
            completion: { _ in }
        ).isAccepted)
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 1),
            priority: .low,
            requiredControl: false,
            completion: { _ in }
        ).isQueueFull)
    }

    @Test func requiredHighControlReportsConnectionResetRequirement() throws {
        var scheduler = AgentOutboundScheduler(limits: .init(
            maximumMessageDataBytes: 1,
            maximumMessages: 1,
            controlReserveBytes: 0
        ))
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 1),
            priority: .normal,
            requiredControl: false,
            completion: { _ in }
        ).isAccepted)
        #expect(scheduler.enqueue(
            id: scheduler.allocateID(),
            payload: try payload(byteCount: 1),
            priority: .high,
            requiredControl: true,
            completion: { _ in }
        ).requiresConnectionReset)
    }

    @Test func cancellationRemovesUnstartedButDetachesAfterFirstFragment() throws {
        var scheduler = AgentOutboundScheduler(limits: .init(
            maximumMessageDataBytes: 100
        ))
        let queued = scheduler.allocateID()
        #expect(scheduler.enqueue(
            id: queued,
            payload: try payload(byteCount: 1),
            priority: .normal,
            requiredControl: false,
            completion: { _ in }
        ).isAccepted)
        guard case .removed = scheduler.cancel(id: queued, writeInFlightID: nil) else {
            Issue.record("unstarted cancellation must remove the request")
            return
        }

        let active = scheduler.allocateID()
        #expect(scheduler.enqueue(
            id: active,
            payload: try payload(byteCount: 3_000),
            priority: .normal,
            requiredControl: false,
            completion: { _ in }
        ).isAccepted)
        #expect(scheduler.activateNextIfNeeded() == active)
        _ = scheduler.didWriteFragment(id: active)
        guard case .detached = scheduler.cancel(id: active, writeInFlightID: nil) else {
            Issue.record("partial cancellation must detach only the caller")
            return
        }
        #expect(scheduler.activeID == active)
        #expect(scheduler.activeFragment() != nil)
    }

    private func payload(byteCount: Int) throws -> VDAgentWireEncoder.EncodedMessage {
        try VDAgentWireEncoder.encode(
            VDAgentMessage(type: 3, data: Data(repeating: 0xa5, count: byteCount)),
            limits: .init(maximumMessageDataBytes: max(16 * 1_024 * 1_024, byteCount))
        )
    }
}

private extension AgentOutboundScheduler.EnqueueResult {
    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }

    var isQueueFull: Bool {
        if case .queueFull = self { return true }
        return false
    }

    var requiresConnectionReset: Bool {
        if case .requiredControlCannotFit = self { return true }
        return false
    }
}
