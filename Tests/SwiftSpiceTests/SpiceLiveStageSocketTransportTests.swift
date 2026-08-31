import Darwin
import Dispatch
import Foundation
import Synchronization
import Testing
@testable import SpiceLiveInteractionSupport

@Suite("Live stage socket transport")
struct SpiceLiveStageSocketTransportTests {
    @Test func realSocketPairIsFullDuplex() async throws {
        let pair = try SocketPair()
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: pair.takeTransportDescriptor()
        )
        let transport = socket.stageTransport

        let first = Data("first-inbound\n".utf8)
        let second = Data("second-inbound\n".utf8)
        let outbound = Data("outbound-ack\n".utf8)
        let inboundWire = first + second
        let peerWriteCompletion = ObservationLatch()
        let peerReadCompletion = ObservationLatch()
        let sendCompletion = ObservationLatch()
        let firstReceiveCompletion = ObservationLatch()
        let peerWrite = Task {
            defer { peerWriteCompletion.signal() }
            try await Self.onIOQueue {
                try Self.writeAll(inboundWire, to: pair.peerDescriptor)
            }
        }
        let peerRead = Task {
            defer { peerReadCompletion.signal() }
            return try await Self.onIOQueue {
                try Self.readExactly(outbound.count, from: pair.peerDescriptor)
            }
        }
        let send = Task {
            defer { sendCompletion.signal() }
            try await transport.sendFrame(outbound)
        }
        let receivedFirst = Task {
            defer { firstReceiveCompletion.signal() }
            return try await transport.receiveFrame(
                maximumBytes: SpiceLiveStageProtocolCodec.maximumFrameBytes
            )
        }

        do {
            try await Self.waitForCompletions([
                peerWriteCompletion,
                peerReadCompletion,
                sendCompletion,
                firstReceiveCompletion,
            ])
        } catch {
            pair.closePeer()
            peerWrite.cancel()
            peerRead.cancel()
            send.cancel()
            receivedFirst.cancel()
            _ = try? await Self.waitForCompletions([
                peerWriteCompletion,
                peerReadCompletion,
                sendCompletion,
                firstReceiveCompletion,
            ])
            _ = try? await Self.closeWithinDeadline(transport)
            throw SpiceLiveInteractionSupportError.operationTimedOut
        }

        do {
            try await peerWrite.value
            #expect(try await receivedFirst.value == first)
            try await send.value
            #expect(try await peerRead.value == outbound)
        } catch {
            pair.closePeer()
            _ = try? await Self.closeWithinDeadline(transport)
            throw error
        }

        let secondReceiveCompletion = ObservationLatch()
        let receivedSecond = Task {
            defer { secondReceiveCompletion.signal() }
            return try await transport.receiveFrame(
                maximumBytes: SpiceLiveStageProtocolCodec.maximumFrameBytes
            )
        }
        do {
            try await Self.waitForCompletions([secondReceiveCompletion])
        } catch {
            pair.closePeer()
            receivedSecond.cancel()
            _ = try? await Self.waitForCompletions([secondReceiveCompletion])
            _ = try? await Self.closeWithinDeadline(transport)
            throw SpiceLiveInteractionSupportError.operationTimedOut
        }
        do {
            #expect(try await receivedSecond.value == second)
        } catch {
            pair.closePeer()
            _ = try? await Self.closeWithinDeadline(transport)
            throw error
        }
        pair.closePeer()
        try await Self.closeWithinDeadline(transport)
    }

    @Test(
        "Receive retries EINTR, assembles fragments, and preserves read-ahead",
        arguments: ReceiveAssemblyScenario.allCases
    )
    fileprivate func receiveRetriesAndPreservesReadAhead(
        _ scenario: ReceiveAssemblyScenario
    ) async throws {
        let first = Data("first\n".utf8)
        let second = Data("second\n".utf8)
        let wire = first + second
        let directives: [ScriptedSocketCalls.ReadDirective]
        switch scenario {
        case .fragmented:
            directives = [
                .result(.interrupted),
                .result(.bytes(Data(wire.prefix(1)))),
                .result(.bytes(Data(wire.dropFirst(1).prefix(2)))),
                .result(.bytes(Data(wire.dropFirst(3).prefix(3)))),
                .result(.bytes(Data(wire.dropFirst(6)))),
            ]
        case .readAhead:
            directives = [
                .result(.interrupted),
                .result(.bytes(wire)),
            ]
        case .partialReadAheadAcrossInterruption:
            directives = [
                .result(.bytes(first + second.prefix(2))),
                .result(.interrupted),
                .result(.bytes(Data(second.dropFirst(2)))),
            ]
        }
        let calls = ScriptedSocketCalls(reads: directives)
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 41,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        let receivedFirst = try await Self.boundedReceiveFrame(
            from: transport,
            maximumBytes: 64
        )
        let receivedSecond = try await Self.boundedReceiveFrame(
            from: transport,
            maximumBytes: 64
        )
        #expect(receivedFirst == first)
        #expect(receivedSecond == second)
        let snapshot = calls.snapshot
        #expect(snapshot.readRequests.allSatisfy { $0 <= 64 })
        switch scenario {
        case .fragmented:
            #expect(snapshot.readRequests.count == 5)
        case .readAhead:
            #expect(snapshot.readRequests.count == 2)
        case .partialReadAheadAcrossInterruption:
            #expect(snapshot.readRequests.count == 3)
        }
        try await Self.closeWithinDeadline(transport)
        Self.expectOwnedDescriptor(41, in: calls.snapshot)
    }

    @Test(
        "Clean EOF is nil; truncated and failed reads throw",
        arguments: ReceiveTerminationScenario.allCases
    )
    fileprivate func receiveTerminationIsFailClosed(
        _ scenario: ReceiveTerminationScenario
    ) async throws {
        let frame = Data("payload\n".utf8)
        let reads: [ScriptedSocketCalls.ReadDirective]
        switch scenario {
        case .cleanEOF:
            reads = [.result(.endOfFile)]
        case .truncatedFrame:
            reads = [
                .result(.bytes(Data(frame.dropLast()))),
                .result(.endOfFile),
            ]
        case .readError:
            reads = [.result(.failed(errno: ECONNRESET))]
        }
        let calls = ScriptedSocketCalls(reads: reads)
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 42,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        switch scenario {
        case .cleanEOF:
            let frame = try await Self.boundedReceiveFrame(
                from: transport,
                maximumBytes: 64
            )
            #expect(frame == nil)
        case .truncatedFrame:
            let error = await Self.socketError {
                _ = try await Self.boundedReceiveFrame(
                    from: transport,
                    maximumBytes: 64
                )
            }
            #expect(error == .truncatedFrame)
        case .readError:
            let error = await Self.socketError {
                _ = try await Self.boundedReceiveFrame(
                    from: transport,
                    maximumBytes: 64
                )
            }
            #expect(error == .receiveFailed(ECONNRESET))
        }
        try await Self.closeWithinDeadline(transport)
        Self.expectOwnedDescriptor(42, in: calls.snapshot)
    }

    @Test(
        "Send retries EINTR and advances exact write-all offsets",
        arguments: WriteProgressScenario.allCases
    )
    fileprivate func sendRetriesAndAdvancesOffsets(
        _ scenario: WriteProgressScenario
    ) async throws {
        let frame = Data("hello\n".utf8)
        let writes: [SpiceLiveStageSocketSystemCalls.WriteResult]
        let expectedOffsets: [Int]
        switch scenario {
        case .interruptedAndFragmented:
            writes = [
                .interrupted,
                .written(1),
                .written(2),
                .written(frame.count - 3),
            ]
            expectedOffsets = [0, 0, 1, 3]
        case .fragmented:
            writes = [
                .written(3),
                .written(1),
                .written(frame.count - 4),
            ]
            expectedOffsets = [0, 3, 4]
        case .interruptedAfterPartialProgress:
            writes = [
                .written(2),
                .interrupted,
                .written(frame.count - 2),
            ]
            expectedOffsets = [0, 2, 2]
        }
        let calls = ScriptedSocketCalls(writes: writes)
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 43,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        try await Self.boundedSendFrame(frame, through: transport)
        let snapshot = calls.snapshot
        #expect(snapshot.writeOffsets == expectedOffsets)
        #expect(snapshot.writeBuffers.allSatisfy { $0 == frame })
        try await Self.closeWithinDeadline(transport)
        Self.expectOwnedDescriptor(43, in: calls.snapshot)
    }

    @Test(
        "EPIPE, zero progress, and over-count writes fail closed",
        arguments: InvalidWriteScenario.allCases
    )
    fileprivate func invalidWriteResultsFailClosed(
        _ scenario: InvalidWriteScenario
    ) async throws {
        let frame = Data("ack\n".utf8)
        let writes: [SpiceLiveStageSocketSystemCalls.WriteResult]
        let expectedOffsets: [Int]
        switch scenario {
        case .brokenPipe:
            writes = [.failed(errno: EPIPE)]
            expectedOffsets = [0]
        case .zeroProgress:
            writes = [.written(0)]
            expectedOffsets = [0]
        case .overCount:
            writes = [.written(frame.count + 1)]
            expectedOffsets = [0]
        case .partialProgressOverCount:
            writes = [.written(2), .written(3)]
            expectedOffsets = [0, 2]
        }
        let calls = ScriptedSocketCalls(writes: writes)
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 44,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        let error = await Self.socketError {
            try await Self.boundedSendFrame(frame, through: transport)
        }
        switch scenario {
        case .brokenPipe:
            #expect(error == .sendFailed(EPIPE))
        case .zeroProgress, .overCount, .partialProgressOverCount:
            #expect(error == .invalidSystemCallResult)
        }
        #expect(calls.snapshot.writeOffsets == expectedOffsets)
        try await Self.closeWithinDeadline(transport)
        Self.expectOwnedDescriptor(44, in: calls.snapshot)
    }

    @Test(
        "Outbound frames are checked before any syscall",
        arguments: OutboundBoundaryScenario.allCases
    )
    fileprivate func outboundFramePreflightUsesZeroSyscallsOnFailure(
        _ scenario: OutboundBoundaryScenario
    ) async throws {
        let maximum = 4_096
        #expect(SpiceLiveStageProtocolCodec.maximumFrameBytes == maximum)
        let frame: Data
        switch scenario {
        case .exactMaximum:
            frame = Data(repeating: 0x61, count: maximum - 1) + Data([0x0a])
        case .empty:
            frame = Data()
        case .loneLineFeed:
            frame = Data([0x0a])
        case .maximumWithoutFinalLineFeed:
            frame = Data(repeating: 0x61, count: maximum)
        case .internalLineFeed:
            frame = Data("a\nb\n".utf8)
        case .oneByteTooLarge:
            frame = Data(repeating: 0x61, count: maximum) + Data([0x0a])
        }
        let calls = ScriptedSocketCalls()
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 45,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        switch scenario {
        case .exactMaximum:
            try await Self.boundedSendFrame(frame, through: transport)
            #expect(calls.snapshot.writeOffsets == [0])
            #expect(calls.snapshot.writeBuffers == [frame])
        case .empty, .loneLineFeed, .maximumWithoutFinalLineFeed,
             .internalLineFeed:
            let error = await Self.socketError {
                try await Self.boundedSendFrame(frame, through: transport)
            }
            #expect(error == .invalidFrame)
            #expect(calls.snapshot.writeOffsets.isEmpty)
        case .oneByteTooLarge:
            let error = await Self.socketError {
                try await Self.boundedSendFrame(frame, through: transport)
            }
            #expect(error == .frameTooLarge)
            #expect(calls.snapshot.writeOffsets.isEmpty)
        }
        try await Self.closeWithinDeadline(transport)
        Self.expectOwnedDescriptor(45, in: calls.snapshot)
    }

    @Test(
        "Inbound length and syscall-return bounds are enforced",
        arguments: InboundBoundaryScenario.allCases
    )
    fileprivate func inboundBoundsFailClosed(
        _ scenario: InboundBoundaryScenario
    ) async throws {
        let maximum = 4_096
        #expect(SpiceLiveStageProtocolCodec.maximumFrameBytes == maximum)
        let reads: [ScriptedSocketCalls.ReadDirective]
        switch scenario {
        case .exactMaximum:
            reads = [
                .result(
                    .bytes(
                        Data(repeating: 0x62, count: maximum - 1)
                            + Data([0x0a])
                    )
                ),
            ]
        case .delimiterBeyondBound:
            reads = [
                .result(.bytes(Data(repeating: 0x62, count: maximum))),
            ]
        case .syscallOverReturn:
            reads = [.overReturn]
        }
        let calls = ScriptedSocketCalls(reads: reads)
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 46,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        switch scenario {
        case .exactMaximum:
            let frame = try await Self.boundedReceiveFrame(
                from: transport,
                maximumBytes: maximum
            )
            #expect(frame?.count == maximum)
            let successfulReadRequests = calls.snapshot.readRequests
            for invalidMaximum in [1, maximum + 1] {
                let error = await Self.socketError {
                    _ = try await Self.boundedReceiveFrame(
                        from: transport,
                        maximumBytes: invalidMaximum
                    )
                }
                #expect(error == .invalidMaximumBytes)
            }
            #expect(calls.snapshot.readRequests == successfulReadRequests)
        case .delimiterBeyondBound:
            let error = await Self.socketError {
                _ = try await Self.boundedReceiveFrame(
                    from: transport,
                    maximumBytes: maximum
                )
            }
            #expect(error == .frameTooLarge)
        case .syscallOverReturn:
            let error = await Self.socketError {
                _ = try await Self.boundedReceiveFrame(
                    from: transport,
                    maximumBytes: maximum
                )
            }
            #expect(error == .invalidSystemCallResult)
        }
        #expect(calls.snapshot.readRequests.allSatisfy { $0 <= maximum })
        try await Self.closeWithinDeadline(transport)
        Self.expectOwnedDescriptor(46, in: calls.snapshot)
    }

    @Test(
        "A second same-direction operation is rejected before a worker starts",
        arguments: SameDirectionScenario.allCases
    )
    fileprivate func sameDirectionAdmissionIsBounded(
        _ scenario: SameDirectionScenario
    ) async throws {
        let calls = BlockingSocketCalls()
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 50,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport
        let firstCompletion = ObservationLatch()
        let first: Task<Void, Never>
        switch scenario {
        case .receive:
            first = Task {
                defer { firstCompletion.signal() }
                _ = try? await transport.receiveFrame(
                    maximumBytes: SpiceLiveStageProtocolCodec.maximumFrameBytes
                )
            }
        case .send:
            first = Task {
                defer { firstCompletion.signal() }
                try? await transport.sendFrame(Data("first\n".utf8))
            }
        }
        do {
            try await Self.waitUntil {
                let snapshot = calls.snapshot
                switch scenario {
                case .receive: return snapshot.activeReads == 1
                case .send: return snapshot.activeWrites == 1
                }
            }
        } catch {
            calls.emergencyReleaseForTestCleanup()
            first.cancel()
            try await Self.awaitCompletedVoidTasks(
                [first],
                completions: [firstCompletion]
            )
            try await Self.closeWithinDeadline(transport)
            throw error
        }

        let completion = OperationCompletion()
        let secondCompletion = ObservationLatch()
        let second = Task {
            defer { secondCompletion.signal() }
            do {
                switch scenario {
                case .receive:
                    _ = try await transport.receiveFrame(
                        maximumBytes:
                            SpiceLiveStageProtocolCodec.maximumFrameBytes
                    )
                case .send:
                    try await transport.sendFrame(Data("second\n".utf8))
                }
                completion.finish(.succeeded)
            } catch let error as SpiceLiveStageSocketTransport.SocketError {
                #expect(error == .operationAlreadyInProgress)
                completion.finish(.failed)
            } catch {
                Issue.record("unexpected admission error: \(error)")
                completion.finish(.failed)
            }
        }
        let boundedResult: Void? = try? await Self.waitUntil {
            let snapshot = calls.snapshot
            return completion.outcome != .pending
                || snapshot.readCalls > 1
                || snapshot.writeCalls > 1
        }
        let beforeCleanup = calls.snapshot
        #expect(boundedResult != nil)
        #expect(completion.outcome == .failed)
        switch scenario {
        case .receive:
            #expect(beforeCleanup.readCalls == 1)
            #expect(beforeCleanup.maximumActiveReads == 1)
            #expect(beforeCleanup.writeCalls == 0)
        case .send:
            #expect(beforeCleanup.writeCalls == 1)
            #expect(beforeCleanup.maximumActiveWrites == 1)
            #expect(beforeCleanup.readCalls == 0)
        }

        calls.emergencyReleaseForTestCleanup()
        do {
            try await Self.awaitCompletedVoidTasks(
                [first, second],
                completions: [firstCompletion, secondCompletion]
            )
        } catch {
            calls.emergencyReleaseForTestCleanup()
            first.cancel()
            second.cancel()
            _ = try? await Self.awaitCompletedVoidTasks(
                [first, second],
                completions: [firstCompletion, secondCompletion]
            )
            _ = try? await Self.closeWithinDeadline(transport)
            throw error
        }
        try await Self.closeWithinDeadline(transport)
        let terminal = calls.snapshot
        #expect(terminal.rawCloseCalls == 1)
        Self.expectOwnedDescriptor(50, in: terminal)
    }

    @Test(
        "Close maps both failed and EOF wakeups after worker retirement",
        arguments: BlockingReceiveOutcome.allCases
    )
    fileprivate func closeUnblocksWorkersBeforeRawDescriptorClose(
        _ receiveOutcome: BlockingReceiveOutcome
    ) async throws {
        let calls = BlockingSocketCalls(receiveOutcome: receiveOutcome)
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 47,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport
        let receiveError = SocketErrorCapture()
        let sendError = SocketErrorCapture()
        let receiveCompletion = ObservationLatch()
        let sendCompletion = ObservationLatch()
        let receive = Task {
            defer { receiveCompletion.signal() }
            do {
                _ = try await transport.receiveFrame(
                    maximumBytes:
                        SpiceLiveStageProtocolCodec.maximumFrameBytes
                )
                Issue.record("closed receive unexpectedly succeeded")
            } catch let error as SpiceLiveStageSocketTransport.SocketError {
                receiveError.record(error)
            } catch {
                Issue.record("unexpected closed-receive error: \(error)")
            }
        }
        let send = Task {
            defer { sendCompletion.signal() }
            do {
                try await transport.sendFrame(Data("blocked\n".utf8))
                Issue.record("closed send unexpectedly succeeded")
            } catch let error as SpiceLiveStageSocketTransport.SocketError {
                sendError.record(error)
            } catch {
                Issue.record("unexpected closed-send error: \(error)")
            }
        }
        do {
            try await Self.waitUntil {
                let snapshot = calls.snapshot
                return snapshot.activeReads == 1
                    && snapshot.activeWrites == 1
            }
        } catch {
            calls.emergencyReleaseForTestCleanup()
            receive.cancel()
            send.cancel()
            try await Self.awaitCompletedVoidTasks(
                [receive, send],
                completions: [receiveCompletion, sendCompletion]
            )
            try await Self.closeWithinDeadline(transport)
            throw error
        }

        let closeCompletion = ObservationLatch()
        let close = Task {
            defer { closeCompletion.signal() }
            await transport.close()
        }
        do {
            try await Self.waitUntil {
                calls.shutdownWasObserved
            }
        } catch {
            calls.emergencyReleaseForTestCleanup()
            receive.cancel()
            send.cancel()
            close.cancel()
            try await Self.awaitCompletedVoidTasks(
                [receive, send, close],
                completions: [
                    receiveCompletion,
                    sendCompletion,
                    closeCompletion,
                ]
            )
            throw error
        }
        let beforeWorkerRelease = calls.snapshot
        #expect(beforeWorkerRelease.shutdownCalls == 1)
        #expect(beforeWorkerRelease.activeReads == 1)
        #expect(beforeWorkerRelease.activeWrites == 1)
        #expect(beforeWorkerRelease.rawCloseCalls == 0)
        Self.expectOwnedDescriptor(47, in: beforeWorkerRelease)

        calls.releaseWorkersForTest()
        try await Self.awaitCompletedVoidTasks(
            [receive, send, close],
            completions: [
                receiveCompletion,
                sendCompletion,
                closeCompletion,
            ]
        )
        let terminal = calls.snapshot
        #expect(receiveError.error == .closed)
        #expect(sendError.error == .closed)
        #expect(terminal.activeReads == 0)
        #expect(terminal.activeWrites == 0)
        #expect(terminal.maximumActiveReads == 1)
        #expect(terminal.maximumActiveWrites == 1)
        #expect(terminal.shutdownCalls == 1)
        #expect(terminal.rawCloseCalls == 1)
        #expect(!terminal.rawCloseObservedActiveWorker)
        Self.expectOwnedDescriptor(47, in: terminal)
    }

    @Test func repeatedCloseCannotAffectAReusedDescriptor() async throws {
        let firstCalls = BlockingSocketCalls()
        let first = try SpiceLiveStageSocketTransport(
            takingDescriptor: 48,
            systemCalls: firstCalls.systemCalls,
            closeCallDidEnter: {
                firstCalls.recordCloseCallDidEnter()
            }
        )
        let firstTransport = first.stageTransport
        let receiveError = SocketErrorCapture()
        let receiveCompletion = ObservationLatch()
        let receive = Task {
            defer { receiveCompletion.signal() }
            do {
                _ = try await firstTransport.receiveFrame(
                    maximumBytes:
                        SpiceLiveStageProtocolCodec.maximumFrameBytes
                )
                Issue.record("closed receive unexpectedly succeeded")
            } catch let error as SpiceLiveStageSocketTransport.SocketError {
                receiveError.record(error)
            } catch {
                Issue.record("unexpected closed-receive error: \(error)")
            }
        }
        do {
            try await Self.waitUntil {
                firstCalls.snapshot.activeReads == 1
            }
        } catch {
            firstCalls.emergencyReleaseForTestCleanup()
            receive.cancel()
            try await Self.awaitCompletedVoidTasks(
                [receive],
                completions: [receiveCompletion]
            )
            try await Self.closeWithinDeadline(firstTransport)
            throw error
        }

        let firstCloseCompletion = ObservationLatch()
        let firstClose = Task {
            defer { firstCloseCompletion.signal() }
            await firstTransport.close()
        }
        do {
            try await Self.waitUntil {
                firstCalls.shutdownWasObserved
            }
        } catch {
            firstCalls.emergencyReleaseForTestCleanup()
            receive.cancel()
            firstClose.cancel()
            try await Self.awaitCompletedVoidTasks(
                [receive, firstClose],
                completions: [receiveCompletion, firstCloseCompletion]
            )
            throw error
        }

        let secondCloseCompletion = ObservationLatch()
        let thirdCloseCompletion = ObservationLatch()
        let secondClose = Task {
            defer { secondCloseCompletion.signal() }
            await firstTransport.close()
        }
        let thirdClose = Task {
            defer { thirdCloseCompletion.signal() }
            await firstTransport.close()
        }
        do {
            try await Self.waitUntil {
                firstCalls.snapshot.closeCallEntries == 3
            }
        } catch {
            firstCalls.emergencyReleaseForTestCleanup()
            receive.cancel()
            firstClose.cancel()
            secondClose.cancel()
            thirdClose.cancel()
            try await Self.awaitCompletedVoidTasks(
                [receive, firstClose, secondClose, thirdClose],
                completions: [
                    receiveCompletion,
                    firstCloseCompletion,
                    secondCloseCompletion,
                    thirdCloseCompletion,
                ]
            )
            throw error
        }

        let overlapping = firstCalls.snapshot
        #expect(overlapping.closeCallEntries == 3)
        #expect(overlapping.activeReads == 1)
        #expect(overlapping.shutdownCalls == 1)
        #expect(overlapping.rawCloseCalls == 0)
        Self.expectOwnedDescriptor(48, in: overlapping)

        firstCalls.releaseWorkersForTest()
        try await Self.awaitCompletedVoidTasks(
            [receive, firstClose, secondClose, thirdClose],
            completions: [
                receiveCompletion,
                firstCloseCompletion,
                secondCloseCompletion,
                thirdCloseCompletion,
            ]
        )
        let firstTerminal = firstCalls.snapshot
        #expect(receiveError.error == .closed)
        #expect(firstTerminal.activeReads == 0)
        #expect(firstTerminal.closeCallEntries == 3)
        #expect(firstTerminal.shutdownCalls == 1)
        #expect(firstTerminal.rawCloseCalls == 1)
        #expect(!firstTerminal.rawCloseObservedActiveWorker)
        Self.expectOwnedDescriptor(48, in: firstTerminal)

        let reusedCalls = ScriptedSocketCalls()
        let reused = try SpiceLiveStageSocketTransport(
            takingDescriptor: 48,
            systemCalls: reusedCalls.systemCalls
        )
        let reusedTransport = reused.stageTransport
        try await Self.boundedSendFrame(
            Data("new-owner\n".utf8),
            through: reusedTransport
        )

        let firstBeforeClosedIO = firstCalls.snapshot
        let reusedBeforeClosedIO = reusedCalls.snapshot
        Self.expectOwnedDescriptor(48, in: reusedBeforeClosedIO)
        let closedReceiveError = SocketErrorCapture()
        let closedSendError = SocketErrorCapture()
        let closedReceiveCompletion = ObservationLatch()
        let closedSendCompletion = ObservationLatch()
        let closedReceive = Task {
            defer { closedReceiveCompletion.signal() }
            do {
                _ = try await firstTransport.receiveFrame(
                    maximumBytes:
                        SpiceLiveStageProtocolCodec.maximumFrameBytes
                )
                Issue.record("post-close receive unexpectedly succeeded")
            } catch let error as SpiceLiveStageSocketTransport.SocketError {
                closedReceiveError.record(error)
            } catch {
                Issue.record("unexpected post-close receive error: \(error)")
            }
        }
        let closedSend = Task {
            defer { closedSendCompletion.signal() }
            do {
                try await firstTransport.sendFrame(Data("old-owner\n".utf8))
                Issue.record("post-close send unexpectedly succeeded")
            } catch let error as SpiceLiveStageSocketTransport.SocketError {
                closedSendError.record(error)
            } catch {
                Issue.record("unexpected post-close send error: \(error)")
            }
        }
        do {
            try await Self.awaitCompletedVoidTasks(
                [closedReceive, closedSend],
                completions: [closedReceiveCompletion, closedSendCompletion]
            )
        } catch {
            firstCalls.emergencyReleaseForTestCleanup()
            closedReceive.cancel()
            closedSend.cancel()
            _ = try? await Self.awaitCompletedVoidTasks(
                [closedReceive, closedSend],
                completions: [closedReceiveCompletion, closedSendCompletion]
            )
            _ = try? await Self.closeWithinDeadline(reusedTransport)
            throw error
        }
        #expect(closedReceiveError.error == .closed)
        #expect(closedSendError.error == .closed)

        let firstAfterClosedIO = firstCalls.snapshot
        Self.expectOwnedDescriptor(48, in: firstAfterClosedIO)
        #expect(firstAfterClosedIO.readCalls == firstBeforeClosedIO.readCalls)
        #expect(firstAfterClosedIO.writeCalls == firstBeforeClosedIO.writeCalls)
        #expect(
            firstAfterClosedIO.shutdownCalls
                == firstBeforeClosedIO.shutdownCalls
        )
        #expect(
            firstAfterClosedIO.rawCloseCalls
                == firstBeforeClosedIO.rawCloseCalls
        )
        let reusedAfterClosedIO = reusedCalls.snapshot
        Self.expectOwnedDescriptor(48, in: reusedAfterClosedIO)
        #expect(
            reusedAfterClosedIO.readRequests
                == reusedBeforeClosedIO.readRequests
        )
        #expect(
            reusedAfterClosedIO.writeOffsets
                == reusedBeforeClosedIO.writeOffsets
        )
        #expect(
            reusedAfterClosedIO.shutdownCalls
                == reusedBeforeClosedIO.shutdownCalls
        )
        #expect(
            reusedAfterClosedIO.rawCloseCalls
                == reusedBeforeClosedIO.rawCloseCalls
        )

        try await Self.closeWithinDeadline(firstTransport)
        #expect(firstCalls.snapshot.closeCallEntries == 4)
        #expect(firstCalls.snapshot.rawCloseCalls == 1)
        #expect(reusedCalls.snapshot.rawCloseCalls == 0)
        #expect(reusedCalls.snapshot.writeOffsets == [0])
        try await Self.boundedSendFrame(
            Data("new-owner-again\n".utf8),
            through: reusedTransport
        )
        #expect(reusedCalls.snapshot.writeOffsets == [0, 0])
        try await Self.closeWithinDeadline(reusedTransport)
        let reusedTerminal = reusedCalls.snapshot
        #expect(reusedTerminal.shutdownCalls == 1)
        #expect(reusedTerminal.rawCloseCalls == 1)
        Self.expectOwnedDescriptor(48, in: reusedTerminal)
    }

    @Test(
        "Taking-descriptor init configures SO_NOSIGPIPE or closes on failure",
        arguments: ConfigurationScenario.allCases
    )
    fileprivate func descriptorConfigurationOwnsExactlyOneClose(
        _ scenario: ConfigurationScenario
    ) async throws {
        let configuration: SpiceLiveStageSocketSystemCalls.ConfigurationResult
        switch scenario {
        case .success:
            configuration = .succeeded
        case .failure:
            configuration = .failed(errno: EACCES)
        }
        let calls = ScriptedSocketCalls(configuration: configuration)

        switch scenario {
        case .success:
            let socket = try SpiceLiveStageSocketTransport(
                takingDescriptor: 49,
                systemCalls: calls.systemCalls
            )
            let beforeClose = calls.snapshot
            #expect(beforeClose.events == ["configure_no_sigpipe"])
            #expect(beforeClose.configuredDescriptors == [49])
            try await Self.closeWithinDeadline(socket.stageTransport)
            let closed = calls.snapshot
            #expect(closed.events == [
                "configure_no_sigpipe",
                "shutdown",
                "raw_close",
            ])
            #expect(closed.rawCloseCalls == 1)
            Self.expectOwnedDescriptor(49, in: closed)
        case .failure:
            let error = Self.synchronousSocketError {
                _ = try SpiceLiveStageSocketTransport(
                    takingDescriptor: 49,
                    systemCalls: calls.systemCalls
                )
            }
            #expect(error == .configurationFailed(EACCES))
            let failed = calls.snapshot
            #expect(failed.events == [
                "configure_no_sigpipe",
                "raw_close",
            ])
            #expect(failed.shutdownCalls == 0)
            #expect(failed.rawCloseCalls == 1)
            Self.expectOwnedDescriptor(49, in: failed)
        }
    }
}

private extension SpiceLiveStageSocketTransportTests {
    enum FixtureError: Error, Sendable {
        case systemCall(Int32)
        case unexpectedEndOfFile
    }

    final class SocketPair: Sendable {
        private struct State: Sendable {
            var transportDescriptor: Int32?
            var peerDescriptor: Int32?
        }

        private let state: Mutex<State>

        init() throws {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw FixtureError.systemCall(errno)
            }

            var noSigPipe: Int32 = 1
            let configurationResult = withUnsafePointer(to: &noSigPipe) {
                setsockopt(
                    descriptors[1],
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            guard configurationResult == 0 else {
                let configurationErrno = errno
                _ = Darwin.close(descriptors[0])
                _ = Darwin.close(descriptors[1])
                throw FixtureError.systemCall(configurationErrno)
            }

            state = Mutex(
                State(
                    transportDescriptor: descriptors[0],
                    peerDescriptor: descriptors[1]
                )
            )
        }

        var peerDescriptor: Int32 {
            state.withLock { $0.peerDescriptor ?? -1 }
        }

        func takeTransportDescriptor() throws -> Int32 {
            try state.withLock { storage in
                guard let descriptor = storage.transportDescriptor else {
                    throw FixtureError.systemCall(EBADF)
                }
                storage.transportDescriptor = nil
                return descriptor
            }
        }

        func closePeer() {
            let descriptor = state.withLock { storage -> Int32? in
                defer { storage.peerDescriptor = nil }
                return storage.peerDescriptor
            }
            if let descriptor {
                _ = Darwin.close(descriptor)
            }
        }

        deinit {
            let descriptors = state.withLock { storage -> [Int32] in
                let result = [storage.transportDescriptor, storage.peerDescriptor]
                    .compactMap { $0 }
                storage.transportDescriptor = nil
                storage.peerDescriptor = nil
                return result
            }
            for descriptor in descriptors {
                _ = Darwin.close(descriptor)
            }
        }
    }

    static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if result > 0 {
                    offset += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw FixtureError.systemCall(result == 0 ? EIO : errno)
                }
            }
        }
    }

    static func readExactly(_ count: Int, from descriptor: Int32) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < count {
                let readCount = Darwin.read(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    count - offset
                )
                if readCount > 0 {
                    offset += readCount
                } else if readCount < 0, errno == EINTR {
                    continue
                } else if readCount == 0 {
                    throw FixtureError.unexpectedEndOfFile
                } else {
                    throw FixtureError.systemCall(errno)
                }
            }
        }
        return result
    }

    static func onIOQueue<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    static func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        try await withSpiceLiveTimeout(.seconds(2)) {
            while true {
                try Task.checkCancellation()
                if await condition() {
                    return
                }
                await Task.yield()
            }
        }
    }

    static func waitForCompletions(
        _ completions: [ObservationLatch]
    ) async throws {
        try await waitUntil {
            completions.allSatisfy(\.isSignaled)
        }
    }

    static func awaitCompletedVoidTasks(
        _ tasks: [Task<Void, Never>],
        completions: [ObservationLatch]
    ) async throws {
        do {
            try await waitForCompletions(completions)
        } catch {
            tasks.forEach { $0.cancel() }
            throw error
        }
        for task in tasks {
            await task.value
        }
    }

    static func boundedTransportOperation<Value: Sendable>(
        transport: SpiceLiveStageTransport,
        emergencyRelease: @escaping @Sendable () -> Void = {},
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let completion = ObservationLatch()
        let task = Task {
            defer { completion.signal() }
            return try await operation()
        }
        do {
            try await waitForCompletions([completion])
        } catch {
            emergencyRelease()
            task.cancel()
            _ = try? await closeWithinDeadline(transport)
            throw SpiceLiveInteractionSupportError.operationTimedOut
        }
        return try await task.value
    }

    static func boundedReceiveFrame(
        from transport: SpiceLiveStageTransport,
        maximumBytes: Int,
        emergencyRelease: @escaping @Sendable () -> Void = {}
    ) async throws -> Data? {
        try await boundedTransportOperation(
            transport: transport,
            emergencyRelease: emergencyRelease
        ) {
            try await transport.receiveFrame(maximumBytes: maximumBytes)
        }
    }

    static func boundedSendFrame(
        _ frame: Data,
        through transport: SpiceLiveStageTransport,
        emergencyRelease: @escaping @Sendable () -> Void = {}
    ) async throws {
        try await boundedTransportOperation(
            transport: transport,
            emergencyRelease: emergencyRelease
        ) {
            try await transport.sendFrame(frame)
        }
    }

    static func closeWithinDeadline(
        _ transport: SpiceLiveStageTransport
    ) async throws {
        let completion = ObservationLatch()
        let close = Task {
            defer { completion.signal() }
            await transport.close()
        }
        try await awaitCompletedVoidTasks(
            [close],
            completions: [completion]
        )
    }

    static func expectOwnedDescriptor(
        _ descriptor: Int32,
        in snapshot: ScriptedSocketCalls.Snapshot
    ) {
        #expect(snapshot.configuredDescriptors == [descriptor])
        #expect(
            snapshot.receiveDescriptors.count == snapshot.readRequests.count
        )
        #expect(
            snapshot.receiveDescriptors.allSatisfy { $0 == descriptor }
        )
        #expect(snapshot.sendDescriptors.count == snapshot.writeOffsets.count)
        #expect(snapshot.sendDescriptors.allSatisfy { $0 == descriptor })
        #expect(
            snapshot.shutdownDescriptors.count == snapshot.shutdownCalls
        )
        #expect(
            snapshot.shutdownDescriptors.allSatisfy { $0 == descriptor }
        )
        #expect(
            snapshot.rawCloseDescriptors.count == snapshot.rawCloseCalls
        )
        #expect(
            snapshot.rawCloseDescriptors.allSatisfy { $0 == descriptor }
        )
    }

    static func expectOwnedDescriptor(
        _ descriptor: Int32,
        in snapshot: BlockingSocketCalls.Snapshot
    ) {
        #expect(snapshot.configuredDescriptors == [descriptor])
        #expect(snapshot.receiveDescriptors.count == snapshot.readCalls)
        #expect(
            snapshot.receiveDescriptors.allSatisfy { $0 == descriptor }
        )
        #expect(snapshot.sendDescriptors.count == snapshot.writeCalls)
        #expect(snapshot.sendDescriptors.allSatisfy { $0 == descriptor })
        #expect(
            snapshot.shutdownDescriptors.count == snapshot.shutdownCalls
        )
        #expect(
            snapshot.shutdownDescriptors.allSatisfy { $0 == descriptor }
        )
        #expect(
            snapshot.rawCloseDescriptors.count == snapshot.rawCloseCalls
        )
        #expect(
            snapshot.rawCloseDescriptors.allSatisfy { $0 == descriptor }
        )
    }

    static func socketError(
        _ operation: () async throws -> Void
    ) async -> SpiceLiveStageSocketTransport.SocketError? {
        do {
            try await operation()
            Issue.record("operation unexpectedly succeeded")
            return nil
        } catch let error as SpiceLiveStageSocketTransport.SocketError {
            return error
        } catch {
            Issue.record("unexpected socket error: \(error)")
            return nil
        }
    }

    static func synchronousSocketError(
        _ operation: () throws -> Void
    ) -> SpiceLiveStageSocketTransport.SocketError? {
        do {
            try operation()
            Issue.record("operation unexpectedly succeeded")
            return nil
        } catch let error as SpiceLiveStageSocketTransport.SocketError {
            return error
        } catch {
            Issue.record("unexpected socket error: \(error)")
            return nil
        }
    }
}

private final class ScriptedSocketCalls: Sendable {
    enum ReadDirective: Sendable, Equatable {
        case result(SpiceLiveStageSocketSystemCalls.ReceiveResult)
        case overReturn
    }

    struct Snapshot: Sendable {
        var events: [String]
        var configuredDescriptors: [Int32]
        var receiveDescriptors: [Int32]
        var sendDescriptors: [Int32]
        var shutdownDescriptors: [Int32]
        var rawCloseDescriptors: [Int32]
        var readRequests: [Int]
        var writeBuffers: [Data]
        var writeOffsets: [Int]
        var shutdownCalls: Int
        var rawCloseCalls: Int
    }

    private struct State: Sendable {
        var configuration: SpiceLiveStageSocketSystemCalls.ConfigurationResult
        var reads: [ReadDirective]
        var writes: [SpiceLiveStageSocketSystemCalls.WriteResult]
        var events: [String] = []
        var configuredDescriptors: [Int32] = []
        var receiveDescriptors: [Int32] = []
        var sendDescriptors: [Int32] = []
        var shutdownDescriptors: [Int32] = []
        var rawCloseDescriptors: [Int32] = []
        var readRequests: [Int] = []
        var writeBuffers: [Data] = []
        var writeOffsets: [Int] = []
        var shutdownCalls = 0
        var rawCloseCalls = 0
    }

    private let state: Mutex<State>

    init(
        configuration: SpiceLiveStageSocketSystemCalls.ConfigurationResult = .succeeded,
        reads: [ReadDirective] = [],
        writes: [SpiceLiveStageSocketSystemCalls.WriteResult] = []
    ) {
        state = Mutex(
            State(
                configuration: configuration,
                reads: reads,
                writes: writes
            )
        )
    }

    var systemCalls: SpiceLiveStageSocketSystemCalls {
        SpiceLiveStageSocketSystemCalls(
            configureNoSigPipe: { [self] descriptor in
                state.withLock { storage in
                    storage.events.append("configure_no_sigpipe")
                    storage.configuredDescriptors.append(descriptor)
                    return storage.configuration
                }
            },
            receive: { [self] descriptor, maximumBytes in
                state.withLock { storage in
                    storage.receiveDescriptors.append(descriptor)
                    storage.readRequests.append(maximumBytes)
                    guard !storage.reads.isEmpty else {
                        return .endOfFile
                    }
                    switch storage.reads.removeFirst() {
                    case let .result(result):
                        return result
                    case .overReturn:
                        return .bytes(
                            Data(repeating: 0, count: maximumBytes + 1)
                        )
                    }
                }
            },
            send: { [self] descriptor, buffer, offset in
                state.withLock { storage in
                    storage.sendDescriptors.append(descriptor)
                    storage.writeBuffers.append(buffer)
                    storage.writeOffsets.append(offset)
                    guard !storage.writes.isEmpty else {
                        return .written(buffer.count - offset)
                    }
                    return storage.writes.removeFirst()
                }
            },
            shutdown: { [self] descriptor in
                state.withLock { storage in
                    storage.events.append("shutdown")
                    storage.shutdownDescriptors.append(descriptor)
                    storage.shutdownCalls += 1
                }
            },
            close: { [self] descriptor in
                state.withLock { storage in
                    storage.events.append("raw_close")
                    storage.rawCloseDescriptors.append(descriptor)
                    storage.rawCloseCalls += 1
                }
            }
        )
    }

    var snapshot: Snapshot {
        state.withLock { storage in
            Snapshot(
                events: storage.events,
                configuredDescriptors: storage.configuredDescriptors,
                receiveDescriptors: storage.receiveDescriptors,
                sendDescriptors: storage.sendDescriptors,
                shutdownDescriptors: storage.shutdownDescriptors,
                rawCloseDescriptors: storage.rawCloseDescriptors,
                readRequests: storage.readRequests,
                writeBuffers: storage.writeBuffers,
                writeOffsets: storage.writeOffsets,
                shutdownCalls: storage.shutdownCalls,
                rawCloseCalls: storage.rawCloseCalls
            )
        }
    }
}

private final class BlockingSocketCalls: Sendable {
    struct Snapshot: Sendable {
        var closeCallEntries: Int
        var configuredDescriptors: [Int32]
        var receiveDescriptors: [Int32]
        var sendDescriptors: [Int32]
        var shutdownDescriptors: [Int32]
        var rawCloseDescriptors: [Int32]
        var readCalls: Int
        var writeCalls: Int
        var activeReads: Int
        var activeWrites: Int
        var maximumActiveReads: Int
        var maximumActiveWrites: Int
        var shutdownCalls: Int
        var rawCloseCalls: Int
        var rawCloseObservedActiveWorker: Bool
    }

    private struct State: Sendable {
        var closeCallEntries = 0
        var configuredDescriptors: [Int32] = []
        var receiveDescriptors: [Int32] = []
        var sendDescriptors: [Int32] = []
        var shutdownDescriptors: [Int32] = []
        var rawCloseDescriptors: [Int32] = []
        var readCalls = 0
        var writeCalls = 0
        var activeReads = 0
        var activeWrites = 0
        var maximumActiveReads = 0
        var maximumActiveWrites = 0
        var shutdownCalls = 0
        var rawCloseCalls = 0
        var rawCloseObservedActiveWorker = false
    }

    private let state = Mutex(State())
    private let receiveOutcome: BlockingReceiveOutcome
    private let shutdownObserved = ObservationLatch()
    private let releaseRead = DispatchSemaphore(value: 0)
    private let releaseWrite = DispatchSemaphore(value: 0)

    init(receiveOutcome: BlockingReceiveOutcome = .failed) {
        self.receiveOutcome = receiveOutcome
    }

    var systemCalls: SpiceLiveStageSocketSystemCalls {
        SpiceLiveStageSocketSystemCalls(
            configureNoSigPipe: { [self] descriptor in
                state.withLock {
                    $0.configuredDescriptors.append(descriptor)
                }
                return .succeeded
            },
            receive: { [self] descriptor, _ in
                state.withLock { storage in
                    storage.receiveDescriptors.append(descriptor)
                    storage.readCalls += 1
                    storage.activeReads += 1
                    storage.maximumActiveReads = max(
                        storage.maximumActiveReads,
                        storage.activeReads
                    )
                }
                releaseRead.wait()
                state.withLock { $0.activeReads -= 1 }
                switch receiveOutcome {
                case .failed:
                    return .failed(errno: ECANCELED)
                case .endOfFile:
                    return .endOfFile
                }
            },
            send: { [self] descriptor, _, _ in
                state.withLock { storage in
                    storage.sendDescriptors.append(descriptor)
                    storage.writeCalls += 1
                    storage.activeWrites += 1
                    storage.maximumActiveWrites = max(
                        storage.maximumActiveWrites,
                        storage.activeWrites
                    )
                }
                releaseWrite.wait()
                state.withLock { $0.activeWrites -= 1 }
                return .failed(errno: ECANCELED)
            },
            shutdown: { [self] descriptor in
                state.withLock {
                    $0.shutdownDescriptors.append(descriptor)
                    $0.shutdownCalls += 1
                }
                shutdownObserved.signal()
            },
            close: { [self] descriptor in
                state.withLock { storage in
                    storage.rawCloseDescriptors.append(descriptor)
                    storage.rawCloseObservedActiveWorker =
                        storage.activeReads != 0 || storage.activeWrites != 0
                    storage.rawCloseCalls += 1
                }
            }
        )
    }

    var snapshot: Snapshot {
        state.withLock { storage in
            Snapshot(
                closeCallEntries: storage.closeCallEntries,
                configuredDescriptors: storage.configuredDescriptors,
                receiveDescriptors: storage.receiveDescriptors,
                sendDescriptors: storage.sendDescriptors,
                shutdownDescriptors: storage.shutdownDescriptors,
                rawCloseDescriptors: storage.rawCloseDescriptors,
                readCalls: storage.readCalls,
                writeCalls: storage.writeCalls,
                activeReads: storage.activeReads,
                activeWrites: storage.activeWrites,
                maximumActiveReads: storage.maximumActiveReads,
                maximumActiveWrites: storage.maximumActiveWrites,
                shutdownCalls: storage.shutdownCalls,
                rawCloseCalls: storage.rawCloseCalls,
                rawCloseObservedActiveWorker:
                    storage.rawCloseObservedActiveWorker
            )
        }
    }

    var shutdownWasObserved: Bool {
        shutdownObserved.isSignaled
    }

    func recordCloseCallDidEnter() {
        state.withLock { $0.closeCallEntries += 1 }
    }

    func releaseWorkersForTest() {
        releaseRead.signal()
        releaseWrite.signal()
    }

    func emergencyReleaseForTestCleanup() {
        for _ in 0..<4 {
            releaseRead.signal()
            releaseWrite.signal()
        }
    }
}

private final class ObservationLatch: Sendable {
    private let state = Mutex(false)

    var isSignaled: Bool {
        state.withLock { $0 }
    }

    func signal() {
        state.withLock { $0 = true }
    }
}

private final class OperationCompletion: Sendable {
    enum Outcome: Sendable, Equatable {
        case pending
        case succeeded
        case failed
    }

    private let state = Mutex(Outcome.pending)

    var outcome: Outcome {
        state.withLock { $0 }
    }

    func finish(_ outcome: Outcome) {
        state.withLock { current in
            if current == .pending {
                current = outcome
            }
        }
    }
}

private final class SocketErrorCapture: Sendable {
    private let state = Mutex<SpiceLiveStageSocketTransport.SocketError?>(nil)

    var error: SpiceLiveStageSocketTransport.SocketError? {
        state.withLock { $0 }
    }

    func record(_ error: SpiceLiveStageSocketTransport.SocketError) {
        state.withLock { current in
            if current == nil {
                current = error
            }
        }
    }
}

private enum ReceiveAssemblyScenario: CaseIterable, CustomTestStringConvertible {
    case fragmented
    case readAhead
    case partialReadAheadAcrossInterruption

    var testDescription: String {
        switch self {
        case .fragmented: "EINTR plus fragmented prefix and payload"
        case .readAhead: "two frames from one read"
        case .partialReadAheadAcrossInterruption:
            "partial read-ahead survives EINTR in the next receive"
        }
    }
}

private enum ReceiveTerminationScenario: CaseIterable, CustomTestStringConvertible {
    case cleanEOF
    case truncatedFrame
    case readError

    var testDescription: String {
        switch self {
        case .cleanEOF: "clean EOF"
        case .truncatedFrame: "nonempty EOF without final line feed"
        case .readError: "read error"
        }
    }
}

private enum WriteProgressScenario: CaseIterable, CustomTestStringConvertible {
    case interruptedAndFragmented
    case fragmented
    case interruptedAfterPartialProgress

    var testDescription: String {
        switch self {
        case .interruptedAndFragmented: "EINTR then partial writes"
        case .fragmented: "partial writes"
        case .interruptedAfterPartialProgress:
            "EINTR preserves offset after partial progress"
        }
    }
}

private enum InvalidWriteScenario: CaseIterable, CustomTestStringConvertible {
    case brokenPipe
    case zeroProgress
    case overCount
    case partialProgressOverCount

    var testDescription: String {
        switch self {
        case .brokenPipe: "EPIPE"
        case .zeroProgress: "zero progress"
        case .overCount: "over-count"
        case .partialProgressOverCount: "over-count after partial progress"
        }
    }
}

private enum BlockingReceiveOutcome: CaseIterable, CustomTestStringConvertible {
    case failed
    case endOfFile

    var testDescription: String {
        switch self {
        case .failed: "shutdown wakes receive with ECANCELED"
        case .endOfFile: "shutdown wakes receive with EOF"
        }
    }
}

private enum OutboundBoundaryScenario: CaseIterable, CustomTestStringConvertible {
    case exactMaximum
    case empty
    case loneLineFeed
    case maximumWithoutFinalLineFeed
    case internalLineFeed
    case oneByteTooLarge

    var testDescription: String {
        switch self {
        case .exactMaximum: "4095-byte payload plus final line feed"
        case .empty: "empty frame"
        case .loneLineFeed: "one-byte line-feed frame"
        case .maximumWithoutFinalLineFeed: "4096 bytes without final line feed"
        case .internalLineFeed: "internal line feed"
        case .oneByteTooLarge: "4096-byte payload plus line feed"
        }
    }
}

private enum InboundBoundaryScenario: CaseIterable, CustomTestStringConvertible {
    case exactMaximum
    case delimiterBeyondBound
    case syscallOverReturn

    var testDescription: String {
        switch self {
        case .exactMaximum: "4095-byte payload plus final line feed"
        case .delimiterBeyondBound: "no line feed within 4096 bytes"
        case .syscallOverReturn: "syscall returns more than requested"
        }
    }
}

private enum SameDirectionScenario: CaseIterable, CustomTestStringConvertible {
    case receive
    case send

    var testDescription: String {
        switch self {
        case .receive: "second receive while receive is pending"
        case .send: "second send while send is pending"
        }
    }
}

private enum ConfigurationScenario: CaseIterable, CustomTestStringConvertible {
    case success
    case failure

    var testDescription: String {
        switch self {
        case .success: "SO_NOSIGPIPE configured"
        case .failure: "configuration failure consumes descriptor"
        }
    }
}
