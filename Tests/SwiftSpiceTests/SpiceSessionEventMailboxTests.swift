import Testing
@testable import SwiftSpice

@Suite("SpiceSession control event mailbox")
struct SpiceSessionEventMailboxTests {
    @Test func preservesControlEventFIFO() async {
        let mailbox = SpiceSessionEventMailbox()
        mailbox.send(.keyboardModifiers(0x0200))
        mailbox.send(.mouseMotionAcknowledged)
        mailbox.send(.disconnected)

        #expect(await mailbox.next() == .keyboardModifiers(0x0200))
        #expect(await mailbox.next() == .mouseMotionAcknowledged)
        #expect(await mailbox.next() == .disconnected)
        mailbox.finish()
    }

    @Test func resumesWaitingConsumerAndFinishesCleanly() async {
        let mailbox = SpiceSessionEventMailbox()
        let waiter = Task { await mailbox.next() }
        await Task.yield()
        mailbox.send(.keyboardModifiers(7))
        #expect(await waiter.value == .keyboardModifiers(7))

        let finishedWaiter = Task { await mailbox.next() }
        await Task.yield()
        mailbox.finish()
        #expect(await finishedWaiter.value == nil)
        #expect(await mailbox.next() == nil)
    }

    @Test func cancellingWaiterDoesNotConsumeFollowingControlEvent() async {
        let mailbox = SpiceSessionEventMailbox()
        let cancelled = Task { await mailbox.next() }
        await Task.yield()
        cancelled.cancel()
        #expect(await cancelled.value == nil)

        mailbox.send(.keyboardModifiers(9))
        #expect(await mailbox.next() == .keyboardModifiers(9))
        mailbox.finish()
    }

    @Test func ignoresControlEventsAfterFinish() async {
        let mailbox = SpiceSessionEventMailbox()
        mailbox.finish()
        mailbox.send(.keyboardModifiers(1))

        #expect(await mailbox.next() == nil)
    }
}
