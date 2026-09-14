import Darwin
import Dispatch
import Foundation
import Synchronization

struct SpiceLiveStageSocketSystemCalls: Sendable {
    enum ConfigurationResult: Sendable, Equatable {
        case succeeded
        case failed(errno: Int32)
    }

    enum ReceiveResult: Sendable, Equatable {
        case bytes(Data)
        case endOfFile
        case interrupted
        case failed(errno: Int32)
    }

    enum WriteResult: Sendable, Equatable {
        case written(Int)
        case interrupted
        case failed(errno: Int32)
    }

    private let configureNoSigPipeOperation:
        @Sendable (Int32) -> ConfigurationResult
    private let receiveOperation:
        @Sendable (Int32, Int) -> ReceiveResult
    private let sendOperation:
        @Sendable (Int32, Data, Int) -> WriteResult
    private let shutdownOperation: @Sendable (Int32) -> Void
    private let closeOperation: @Sendable (Int32) -> Void

    init(
        configureNoSigPipe: @escaping @Sendable (Int32) -> ConfigurationResult,
        receive: @escaping @Sendable (Int32, Int) -> ReceiveResult,
        send: @escaping @Sendable (Int32, Data, Int) -> WriteResult,
        shutdown: @escaping @Sendable (Int32) -> Void,
        close: @escaping @Sendable (Int32) -> Void
    ) {
        configureNoSigPipeOperation = configureNoSigPipe
        receiveOperation = receive
        sendOperation = send
        shutdownOperation = shutdown
        closeOperation = close
    }

    fileprivate func configureNoSigPipe(
        _ descriptor: Int32
    ) -> ConfigurationResult {
        configureNoSigPipeOperation(descriptor)
    }

    fileprivate func receive(
        _ descriptor: Int32,
        maximumBytes: Int
    ) -> ReceiveResult {
        receiveOperation(descriptor, maximumBytes)
    }

    fileprivate func send(
        _ descriptor: Int32,
        buffer: Data,
        offset: Int
    ) -> WriteResult {
        sendOperation(descriptor, buffer, offset)
    }

    fileprivate func shutdown(_ descriptor: Int32) {
        shutdownOperation(descriptor)
    }

    fileprivate func close(_ descriptor: Int32) {
        closeOperation(descriptor)
    }

    fileprivate static let darwin = SpiceLiveStageSocketSystemCalls(
        configureNoSigPipe: { descriptor in
            var enabled: Int32 = 1
            let result = withUnsafePointer(to: &enabled) { pointer in
                setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    pointer,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            return result == 0
                ? .succeeded
                : .failed(errno: errno)
        },
        receive: { descriptor, maximumBytes in
            var buffer = Data(count: maximumBytes)
            let result = buffer.withUnsafeMutableBytes { bytes in
                Darwin.recv(
                    descriptor,
                    bytes.baseAddress,
                    maximumBytes,
                    0
                )
            }
            if result > 0 {
                buffer.removeSubrange(Int(result)..<buffer.count)
                return .bytes(buffer)
            }
            if result == 0 {
                return .endOfFile
            }
            let failure = errno
            return failure == EINTR
                ? .interrupted
                : .failed(errno: failure)
        },
        send: { descriptor, buffer, offset in
            let result = buffer.withUnsafeBytes { bytes in
                Darwin.send(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
            }
            if result >= 0 {
                return .written(result)
            }
            let failure = errno
            return failure == EINTR
                ? .interrupted
                : .failed(errno: failure)
        },
        shutdown: { descriptor in
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
        },
        close: { descriptor in
            // A Darwin close must not be retried after EINTR: the descriptor
            // number may already have been made available for reuse.
            _ = Darwin.close(descriptor)
        }
    )
}

package final class SpiceLiveStageSocketTransport: Sendable {
    package enum SocketError: Error, Sendable, Equatable {
        case operationAlreadyInProgress
        case truncatedFrame
        case receiveFailed(Int32)
        case sendFailed(Int32)
        case invalidSystemCallResult
        case invalidFrame
        case frameTooLarge
        case configurationFailed(Int32)
        case closed
        case invalidMaximumBytes
    }

    private enum Lifecycle: Sendable {
        case open
        case closing
        case closed
    }

    private enum Direction: Sendable {
        case receive
        case send
    }

    private struct Storage: Sendable {
        var lifecycle: Lifecycle = .open
        var descriptor: Int32?
        var receiveActive = false
        var sendActive = false
        var activeWorkers = 0
        var shutdownCompleted = false
        var rawCloseClaimed = false
        var readAhead = Data()
        var closeWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private let systemCalls: SpiceLiveStageSocketSystemCalls
    private let storage: Mutex<Storage>
    private let blockingQueue = DispatchQueue(
        label: "SwiftSpice.LiveStageSocketTransport",
        qos: .userInitiated,
        attributes: .concurrent
    )

    package convenience init(takingDescriptor descriptor: Int32) throws {
        try self.init(
            takingDescriptor: descriptor,
            systemCalls: .darwin
        )
    }

    init(
        takingDescriptor descriptor: Int32,
        systemCalls: SpiceLiveStageSocketSystemCalls
    ) throws {
        self.systemCalls = systemCalls
        switch systemCalls.configureNoSigPipe(descriptor) {
        case .succeeded:
            storage = Mutex(Storage(descriptor: descriptor))
        case let .failed(errorNumber):
            systemCalls.close(descriptor)
            throw SocketError.configurationFailed(errorNumber)
        }
    }

    package var stageTransport: SpiceLiveStageTransport {
        SpiceLiveStageTransport(
            receiveFrame: { [self] maximumBytes in
                try await receiveFrame(maximumBytes: maximumBytes)
            },
            sendFrame: { [self] frame in
                try await sendFrame(frame)
            },
            close: { [self] in
                await close()
            }
        )
    }

    deinit {
        let descriptor = storage.withLock { storage -> Int32? in
            guard storage.activeWorkers == 0,
                  !storage.rawCloseClaimed,
                  let descriptor = storage.descriptor
            else {
                return nil
            }
            storage.lifecycle = .closed
            storage.rawCloseClaimed = true
            storage.descriptor = nil
            return descriptor
        }
        if let descriptor {
            systemCalls.close(descriptor)
        }
    }

    private func receiveFrame(maximumBytes: Int) async throws -> Data? {
        guard (2...SpiceLiveStageProtocolCodec.maximumFrameBytes)
            .contains(maximumBytes)
        else {
            throw SocketError.invalidMaximumBytes
        }
        let descriptor = try admit(.receive)
        return try await runBlocking(direction: .receive) { [self] in
            try blockingReceive(
                descriptor: descriptor,
                maximumBytes: maximumBytes
            )
        }
    }

    private func sendFrame(_ frame: Data) async throws {
        try validateOutboundFrame(frame)
        let descriptor = try admit(.send)
        try await runBlocking(direction: .send) { [self] in
            try blockingSend(descriptor: descriptor, frame: frame)
        }
    }

    private func close() async {
        let descriptorToShutdown = storage.withLock { storage -> Int32? in
            guard storage.lifecycle == .open else {
                return nil
            }
            storage.lifecycle = .closing
            return storage.descriptor
        }

        if let descriptorToShutdown {
            systemCalls.shutdown(descriptorToShutdown)
            storage.withLock { $0.shutdownCompleted = true }
            finalizeCloseIfReady()
        }

        await waitUntilClosed()
    }

    private func admit(_ direction: Direction) throws -> Int32 {
        try storage.withLock { storage in
            guard storage.lifecycle == .open,
                  let descriptor = storage.descriptor
            else {
                throw SocketError.closed
            }
            switch direction {
            case .receive:
                guard !storage.receiveActive else {
                    throw SocketError.operationAlreadyInProgress
                }
                storage.receiveActive = true
            case .send:
                guard !storage.sendActive else {
                    throw SocketError.operationAlreadyInProgress
                }
                storage.sendActive = true
            }
            storage.activeWorkers += 1
            return descriptor
        }
    }

    private func runBlocking<Value: Sendable>(
        direction: Direction,
        operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            blockingQueue.async { [self] in
                let result = Result { try operation() }
                workerFinished(direction)
                continuation.resume(with: result)
            }
        }
    }

    private func workerFinished(_ direction: Direction) {
        storage.withLock { storage in
            switch direction {
            case .receive:
                storage.receiveActive = false
            case .send:
                storage.sendActive = false
            }
            storage.activeWorkers -= 1
        }
        finalizeCloseIfReady()
    }

    private func blockingReceive(
        descriptor: Int32,
        maximumBytes: Int
    ) throws -> Data? {
        while true {
            let buffered = try storage.withLock { storage -> Data? in
                guard storage.lifecycle == .open else {
                    throw SocketError.closed
                }
                return try takeBufferedFrame(
                    storage: &storage,
                    maximumBytes: maximumBytes
                )
            }
            if let buffered {
                return buffered
            }

            let remaining = try storage.withLock { storage -> Int in
                guard storage.lifecycle == .open else {
                    throw SocketError.closed
                }
                let remaining = maximumBytes - storage.readAhead.count
                guard remaining > 0 else {
                    throw SocketError.frameTooLarge
                }
                return remaining
            }
            let result = systemCalls.receive(
                descriptor,
                maximumBytes: remaining
            )

            let isOpen = storage.withLock { $0.lifecycle == .open }
            guard isOpen else {
                throw SocketError.closed
            }
            switch result {
            case let .bytes(bytes):
                guard !bytes.isEmpty, bytes.count <= remaining else {
                    throw SocketError.invalidSystemCallResult
                }
                storage.withLock { $0.readAhead.append(bytes) }
            case .endOfFile:
                let hasPartialFrame = storage.withLock {
                    !$0.readAhead.isEmpty
                }
                if hasPartialFrame {
                    throw SocketError.truncatedFrame
                }
                return nil
            case .interrupted:
                continue
            case let .failed(errorNumber):
                throw SocketError.receiveFailed(errorNumber)
            }
        }
    }

    private func blockingSend(
        descriptor: Int32,
        frame: Data
    ) throws {
        var offset = 0
        while offset < frame.count {
            let isOpen = storage.withLock { $0.lifecycle == .open }
            guard isOpen else {
                throw SocketError.closed
            }
            let result = systemCalls.send(
                descriptor,
                buffer: frame,
                offset: offset
            )
            let remainsOpen = storage.withLock { $0.lifecycle == .open }
            guard remainsOpen else {
                throw SocketError.closed
            }
            switch result {
            case let .written(count):
                let remaining = frame.count - offset
                guard count > 0, count <= remaining else {
                    throw SocketError.invalidSystemCallResult
                }
                offset += count
            case .interrupted:
                continue
            case let .failed(errorNumber):
                throw SocketError.sendFailed(errorNumber)
            }
        }
    }

    private func takeBufferedFrame(
        storage: inout Storage,
        maximumBytes: Int
    ) throws -> Data? {
        if let lineFeed = storage.readAhead.firstIndex(of: 0x0a) {
            let frameLength = storage.readAhead.distance(
                from: storage.readAhead.startIndex,
                to: lineFeed
            ) + 1
            guard frameLength <= maximumBytes else {
                throw SocketError.frameTooLarge
            }
            guard frameLength >= 2 else {
                throw SocketError.invalidFrame
            }
            let frame = Data(storage.readAhead.prefix(frameLength))
            storage.readAhead.removeFirst(frameLength)
            return frame
        }
        guard storage.readAhead.count < maximumBytes else {
            throw SocketError.frameTooLarge
        }
        return nil
    }

    private func validateOutboundFrame(_ frame: Data) throws {
        let maximum = SpiceLiveStageProtocolCodec.maximumFrameBytes
        guard frame.count <= maximum else {
            throw SocketError.frameTooLarge
        }
        guard frame.count >= 2,
              frame.last == 0x0a,
              !frame.dropLast().contains(0x0a)
        else {
            throw SocketError.invalidFrame
        }
    }

    private func waitUntilClosed() async {
        await withCheckedContinuation { continuation in
            let shouldResume = storage.withLock { storage -> Bool in
                if storage.lifecycle == .closed {
                    return true
                }
                storage.closeWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    private func finalizeCloseIfReady() {
        let descriptor = storage.withLock { storage -> Int32? in
            guard storage.lifecycle == .closing,
                  storage.shutdownCompleted,
                  storage.activeWorkers == 0,
                  !storage.rawCloseClaimed,
                  let descriptor = storage.descriptor
            else {
                return nil
            }
            storage.rawCloseClaimed = true
            storage.descriptor = nil
            return descriptor
        }
        guard let descriptor else {
            return
        }

        systemCalls.close(descriptor)
        let waiters = storage.withLock { storage -> [CheckedContinuation<Void, Never>] in
            storage.lifecycle = .closed
            defer { storage.closeWaiters.removeAll(keepingCapacity: false) }
            return storage.closeWaiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }
}
