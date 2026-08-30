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
        defer { pair.closePeer() }

        let first = Data("first-inbound\n".utf8)
        let second = Data("second-inbound\n".utf8)
        let outbound = Data("outbound-ack\n".utf8)
        let inboundWire = first + second

        do {
            try await withSpiceLiveTimeout(.seconds(2)) {
                async let peerWrite: Void = Self.onIOQueue {
                    try Self.writeAll(inboundWire, to: pair.peerDescriptor)
                }
                async let peerRead: Data = Self.onIOQueue {
                    try Self.readExactly(outbound.count, from: pair.peerDescriptor)
                }
                async let send: Void = transport.sendFrame(outbound)
                async let receivedFirst: Data? = transport.receiveFrame(
                    maximumBytes:
                        SpiceLiveStageProtocolCodec.maximumFrameBytes
                )

                try await peerWrite
                #expect(try await receivedFirst == first)
                try await send
                #expect(try await peerRead == outbound)
                let receivedSecond = try await transport.receiveFrame(
                    maximumBytes:
                        SpiceLiveStageProtocolCodec.maximumFrameBytes
                )
                #expect(receivedSecond == second)
            }
        } catch {
            await transport.close()
            throw error
        }
        await transport.close()
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
        }
        let calls = ScriptedSocketCalls(reads: directives)
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 41,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        let receivedFirst = try await transport.receiveFrame(maximumBytes: 64)
        let receivedSecond = try await transport.receiveFrame(maximumBytes: 64)
        #expect(receivedFirst == first)
        #expect(receivedSecond == second)
        let snapshot = calls.snapshot
        #expect(snapshot.readRequests.allSatisfy { $0 <= 64 })
        switch scenario {
        case .fragmented:
            #expect(snapshot.readRequests.count == 5)
        case .readAhead:
            #expect(snapshot.readRequests.count == 2)
        }
        await transport.close()
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
            let frame = try await transport.receiveFrame(maximumBytes: 64)
            #expect(frame == nil)
        case .truncatedFrame:
            let error = await Self.socketError {
                _ = try await transport.receiveFrame(maximumBytes: 64)
            }
            #expect(error == .truncatedFrame)
        case .readError:
            let error = await Self.socketError {
                _ = try await transport.receiveFrame(maximumBytes: 64)
            }
            #expect(error == .receiveFailed(ECONNRESET))
        }
        await transport.close()
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
        }
        let calls = ScriptedSocketCalls(writes: writes)
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 43,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        try await transport.sendFrame(frame)
        let snapshot = calls.snapshot
        #expect(snapshot.writeOffsets == expectedOffsets)
        #expect(snapshot.writeBuffers.allSatisfy { $0 == frame })
        await transport.close()
    }

    @Test(
        "EPIPE, zero progress, and over-count writes fail closed",
        arguments: InvalidWriteScenario.allCases
    )
    fileprivate func invalidWriteResultsFailClosed(
        _ scenario: InvalidWriteScenario
    ) async throws {
        let frame = Data("ack\n".utf8)
        let result: SpiceLiveStageSocketSystemCalls.WriteResult
        switch scenario {
        case .brokenPipe:
            result = .failed(errno: EPIPE)
        case .zeroProgress:
            result = .written(0)
        case .overCount:
            result = .written(frame.count + 1)
        }
        let calls = ScriptedSocketCalls(writes: [result])
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 44,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport

        let error = await Self.socketError {
            try await transport.sendFrame(frame)
        }
        switch scenario {
        case .brokenPipe:
            #expect(error == .sendFailed(EPIPE))
        case .zeroProgress, .overCount:
            #expect(error == .invalidSystemCallResult)
        }
        #expect(calls.snapshot.writeOffsets == [0])
        await transport.close()
    }

    @Test(
        "Outbound frames are checked before any syscall",
        arguments: OutboundBoundaryScenario.allCases
    )
    fileprivate func outboundFramePreflightUsesZeroSyscallsOnFailure(
        _ scenario: OutboundBoundaryScenario
    ) async throws {
        let maximum = SpiceLiveStageProtocolCodec.maximumFrameBytes
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
            try await transport.sendFrame(frame)
            #expect(calls.snapshot.writeOffsets == [0])
            #expect(calls.snapshot.writeBuffers == [frame])
        case .empty, .loneLineFeed, .maximumWithoutFinalLineFeed,
             .internalLineFeed:
            let error = await Self.socketError {
                try await transport.sendFrame(frame)
            }
            #expect(error == .invalidFrame)
            #expect(calls.snapshot.writeOffsets.isEmpty)
        case .oneByteTooLarge:
            let error = await Self.socketError {
                try await transport.sendFrame(frame)
            }
            #expect(error == .frameTooLarge)
            #expect(calls.snapshot.writeOffsets.isEmpty)
        }
        await transport.close()
    }

    @Test(
        "Inbound length and syscall-return bounds are enforced",
        arguments: InboundBoundaryScenario.allCases
    )
    fileprivate func inboundBoundsFailClosed(
        _ scenario: InboundBoundaryScenario
    ) async throws {
        let maximum = SpiceLiveStageProtocolCodec.maximumFrameBytes
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
            let frame = try await transport.receiveFrame(maximumBytes: maximum)
            #expect(frame?.count == maximum)
            let successfulReadRequests = calls.snapshot.readRequests
            for invalidMaximum in [1, maximum + 1] {
                let error = await Self.socketError {
                    _ = try await transport.receiveFrame(
                        maximumBytes: invalidMaximum
                    )
                }
                #expect(error == .invalidMaximumBytes)
            }
            #expect(calls.snapshot.readRequests == successfulReadRequests)
        case .delimiterBeyondBound:
            let error = await Self.socketError {
                _ = try await transport.receiveFrame(maximumBytes: maximum)
            }
            #expect(error == .frameTooLarge)
        case .syscallOverReturn:
            let error = await Self.socketError {
                _ = try await transport.receiveFrame(maximumBytes: maximum)
            }
            #expect(error == .invalidSystemCallResult)
        }
        #expect(calls.snapshot.readRequests.allSatisfy { $0 <= maximum })
        await transport.close()
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
        let first: Task<Void, Never>
        switch scenario {
        case .receive:
            first = Task {
                _ = try? await transport.receiveFrame(
                    maximumBytes: SpiceLiveStageProtocolCodec.maximumFrameBytes
                )
            }
        case .send:
            first = Task {
                try? await transport.sendFrame(Data("first\n".utf8))
            }
        }
        try await Self.waitUntil {
            let snapshot = calls.snapshot
            switch scenario {
            case .receive: return snapshot.activeReads == 1
            case .send: return snapshot.activeWrites == 1
            }
        }

        let completion = OperationCompletion()
        let second = Task {
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
        await first.value
        await second.value
        await transport.close()
        #expect(calls.snapshot.rawCloseCalls == 1)
    }

    @Test func closeUnblocksWorkersBeforeRawDescriptorClose() async throws {
        let calls = BlockingSocketCalls()
        let socket = try SpiceLiveStageSocketTransport(
            takingDescriptor: 47,
            systemCalls: calls.systemCalls
        )
        let transport = socket.stageTransport
        let receiveError = SocketErrorCapture()
        let sendError = SocketErrorCapture()
        let receive = Task {
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
            do {
                try await transport.sendFrame(Data("blocked\n".utf8))
                Issue.record("closed send unexpectedly succeeded")
            } catch let error as SpiceLiveStageSocketTransport.SocketError {
                sendError.record(error)
            } catch {
                Issue.record("unexpected closed-send error: \(error)")
            }
        }
        try await Self.waitUntil {
            let snapshot = calls.snapshot
            return snapshot.activeReads == 1 && snapshot.activeWrites == 1
        }

        let close = Task { await transport.close() }
        let closeFinished: Void? = try? await Self.waitUntil {
            calls.snapshot.rawCloseCalls == 1
        }
        let beforeEmergencyCleanup = calls.snapshot
        #expect(closeFinished != nil)
        #expect(beforeEmergencyCleanup.shutdownCalls == 1)
        #expect(beforeEmergencyCleanup.rawCloseCalls == 1)
        #expect(!beforeEmergencyCleanup.rawCloseObservedActiveWorker)

        calls.emergencyReleaseForTestCleanup()
        await close.value
        await receive.value
        await send.value
        let terminal = calls.snapshot
        #expect(receiveError.error == .closed)
        #expect(sendError.error == .closed)
        #expect(terminal.activeReads == 0)
        #expect(terminal.activeWrites == 0)
        #expect(terminal.maximumActiveReads == 1)
        #expect(terminal.maximumActiveWrites == 1)
        #expect(terminal.shutdownCalls == 1)
        #expect(terminal.rawCloseCalls == 1)
    }

    @Test func repeatedCloseCannotAffectAReusedDescriptor() async throws {
        let firstCalls = ScriptedSocketCalls()
        let first = try SpiceLiveStageSocketTransport(
            takingDescriptor: 48,
            systemCalls: firstCalls.systemCalls
        )
        let firstTransport = first.stageTransport
        await firstTransport.close()
        await firstTransport.close()
        await firstTransport.close()
        #expect(firstCalls.snapshot.shutdownCalls == 1)
        #expect(firstCalls.snapshot.rawCloseCalls == 1)

        let reusedCalls = ScriptedSocketCalls()
        let reused = try SpiceLiveStageSocketTransport(
            takingDescriptor: 48,
            systemCalls: reusedCalls.systemCalls
        )
        let reusedTransport = reused.stageTransport
        try await reusedTransport.sendFrame(Data("new-owner\n".utf8))
        await firstTransport.close()
        #expect(firstCalls.snapshot.rawCloseCalls == 1)
        #expect(reusedCalls.snapshot.rawCloseCalls == 0)
        #expect(reusedCalls.snapshot.writeOffsets == [0])
        await reusedTransport.close()
        #expect(reusedCalls.snapshot.shutdownCalls == 1)
        #expect(reusedCalls.snapshot.rawCloseCalls == 1)
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
            await socket.stageTransport.close()
            let closed = calls.snapshot
            #expect(closed.events == [
                "configure_no_sigpipe",
                "shutdown",
                "raw_close",
            ])
            #expect(closed.rawCloseCalls == 1)
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
            configureNoSigPipe: { [self] _ in
                state.withLock { storage in
                    storage.events.append("configure_no_sigpipe")
                    return storage.configuration
                }
            },
            receive: { [self] _, maximumBytes in
                state.withLock { storage in
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
            send: { [self] _, buffer, offset in
                state.withLock { storage in
                    storage.writeBuffers.append(buffer)
                    storage.writeOffsets.append(offset)
                    guard !storage.writes.isEmpty else {
                        return .written(buffer.count - offset)
                    }
                    return storage.writes.removeFirst()
                }
            },
            shutdown: { [self] _ in
                state.withLock { storage in
                    storage.events.append("shutdown")
                    storage.shutdownCalls += 1
                }
            },
            close: { [self] _ in
                state.withLock { storage in
                    storage.events.append("raw_close")
                    storage.rawCloseCalls += 1
                }
            }
        )
    }

    var snapshot: Snapshot {
        state.withLock { storage in
            Snapshot(
                events: storage.events,
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
    private let releaseRead = DispatchSemaphore(value: 0)
    private let releaseWrite = DispatchSemaphore(value: 0)

    var systemCalls: SpiceLiveStageSocketSystemCalls {
        SpiceLiveStageSocketSystemCalls(
            configureNoSigPipe: { _ in .succeeded },
            receive: { [self] _, _ in
                state.withLock { storage in
                    storage.readCalls += 1
                    storage.activeReads += 1
                    storage.maximumActiveReads = max(
                        storage.maximumActiveReads,
                        storage.activeReads
                    )
                }
                releaseRead.wait()
                state.withLock { $0.activeReads -= 1 }
                return .failed(errno: ECANCELED)
            },
            send: { [self] _, _, _ in
                state.withLock { storage in
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
            shutdown: { [self] _ in
                state.withLock { $0.shutdownCalls += 1 }
                releaseRead.signal()
                releaseWrite.signal()
            },
            close: { [self] _ in
                state.withLock { storage in
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

    func emergencyReleaseForTestCleanup() {
        for _ in 0..<4 {
            releaseRead.signal()
            releaseWrite.signal()
        }
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

    var testDescription: String {
        switch self {
        case .fragmented: "EINTR plus fragmented prefix and payload"
        case .readAhead: "two frames from one read"
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

    var testDescription: String {
        switch self {
        case .interruptedAndFragmented: "EINTR then partial writes"
        case .fragmented: "partial writes"
        }
    }
}

private enum InvalidWriteScenario: CaseIterable, CustomTestStringConvertible {
    case brokenPipe
    case zeroProgress
    case overCount

    var testDescription: String {
        switch self {
        case .brokenPipe: "EPIPE"
        case .zeroProgress: "zero progress"
        case .overCount: "over-count"
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
