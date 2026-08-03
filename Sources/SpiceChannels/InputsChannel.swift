import SpiceCore
import SpiceProtocol
import SpiceWire

package enum SpiceMouseButton: UInt8, Sendable, Equatable, Hashable {
    case left = 1
    case middle = 2
    case right = 3
    case scrollUp = 4
    case scrollDown = 5
    case side = 6
    case extra = 7
}

/// Inputs Channel transports physical PC scan-code events. It is not a
/// Unicode or IME committed-text transport.
package enum SpiceInputEvent: Sendable, Equatable {
    case keyDown(scanCode: UInt32)
    case keyUp(scanCode: UInt32)
    case lockModifiers(UInt16)
    case mouseMotion(dx: Int32, dy: Int32)
    case mousePosition(x: UInt32, y: UInt32, displayID: UInt8)
    case mousePress(SpiceMouseButton)
    case mouseRelease(SpiceMouseButton)
}

package enum InputsServerEvent: Sendable, Equatable {
    case initialized(keyboardModifiers: UInt16)
    case keyboardModifiersChanged(UInt16)
    case mouseMotionAcknowledged
    case ignored(UInt16)
}

package actor InputsChannel: SpiceManagedChannel {
    private enum SendTurn: Sendable {
        case acquired
        case cancelled
        case generationChanged
    }

    private struct SendWaiter {
        let id: UInt64
        let continuation: CheckedContinuation<SendTurn, Never>
    }

    private var connection: ChannelConnection
    private var connectionGeneration: UInt64 = 0
    private var activeSendGeneration: UInt64?
    private var buttonsState: UInt16 = 0
    private var ackController = AckController()
    private var isSending = false
    private var nextSendWaiterID: UInt64 = 0
    private var sendWaiters: [SendWaiter] = []
    private var queuedSendTestWaiters: [CheckedContinuation<Void, Never>] = []
    private var isClosed = false
    private(set) var keyboardModifiers: UInt16 = 0

    package init(connection: ChannelConnection) {
        self.connection = connection
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        while !Task.isCancelled {
            let event = try await processNext()
            if case .ignored = event {
                continue
            }
            await emit(.inputs(event))
        }
    }

    package func send(
        _ event: SpiceInputEvent,
        generation expectedSendGeneration: UInt64
    ) async throws(ChannelError) {
        guard !isClosed, activeSendGeneration == expectedSendGeneration else {
            throw .invalidState
        }
        let admittedGeneration = connectionGeneration
        switch await acquireSendTurn() {
        case .acquired:
            break
        case .cancelled:
            throw .cancelledBeforeWrite
        case .generationChanged:
            throw .invalidState
        }
        defer { releaseSendTurn() }
        guard !Task.isCancelled else {
            throw .cancelledBeforeWrite
        }
        guard admittedGeneration == connectionGeneration,
              activeSendGeneration == expectedSendGeneration,
              !isClosed else {
            throw .invalidState
        }
        let generation = connectionGeneration
        var proposedButtonsState: UInt16?
        do {
            switch event {
            case let .keyDown(scanCode):
                try await connection.send(SpiceMsgcInputsKeyDown(
                    code: try encodedScanCode(scanCode, release: false)
                ))
            case let .keyUp(scanCode):
                try await connection.send(SpiceMsgcInputsKeyUp(
                    code: try encodedScanCode(scanCode, release: true)
                ))
            case let .lockModifiers(modifiers):
                try await connection.send(SpiceMsgcInputsKeyModifiers(modifiers: modifiers))
            case let .mouseMotion(dx, dy):
                try await connection.send(SpiceMsgcInputsMouseMotion(
                    dx: dx,
                    dy: dy,
                    buttonsState: buttonsState
                ))
            case let .mousePosition(x, y, displayID):
                try await connection.send(SpiceMsgcInputsMousePosition(
                    x: x,
                    y: y,
                    buttonsState: buttonsState,
                    displayID: displayID
                ))
            case let .mousePress(button):
                let nextButtonsState = buttonsState | mask(for: button)
                try await connection.send(SpiceMsgcInputsMousePress(
                    button: button.rawValue,
                    buttonsState: nextButtonsState
                ))
                proposedButtonsState = nextButtonsState
            case let .mouseRelease(button):
                let nextButtonsState = buttonsState & ~mask(for: button)
                try await connection.send(SpiceMsgcInputsMouseRelease(
                    button: button.rawValue,
                    buttonsState: nextButtonsState
                ))
                proposedButtonsState = nextButtonsState
            }
        } catch let error {
            // A transport failure is a physical-terminal ambiguity. Fence the
            // queue before releasing the active turn so an older waiter cannot
            // enter the same connection generation ahead of session teardown.
            if case .transport = error, generation == connectionGeneration {
                invalidateSendGeneration()
            }
            throw error
        }

        guard generation == connectionGeneration,
              activeSendGeneration == expectedSendGeneration,
              !isClosed else {
            throw .invalidState
        }
        guard !Task.isCancelled else {
            // Cancellation observed after a successful write is likewise
            // ambiguous. Poison queued work before defer releases the turn.
            invalidateSendGeneration()
            throw .transport(.cancelled)
        }
        if let proposedButtonsState {
            buttonsState = proposedButtonsState
        }
    }

    /// Invalidates the local send generation without replacing or closing the
    /// transport. Active wire work may finish ambiguously, but every waiter
    /// admitted before this barrier is rejected before it can start a write.
    package func invalidateSendGeneration() {
        activeSendGeneration = nil
        connectionGeneration &+= 1
        invalidateSendWaiters()
    }

    package func activateSendGeneration(_ generation: UInt64) throws(ChannelError) {
        guard !isClosed else { throw .invalidState }
        connectionGeneration &+= 1
        invalidateSendWaiters()
        activeSendGeneration = generation
    }

    package func waitUntilSendIsQueuedForTesting() async {
        guard sendWaiters.isEmpty else { return }
        await withCheckedContinuation { continuation in
            queuedSendTestWaiters.append(continuation)
        }
    }

    package func processNext() async throws(ChannelError) -> InputsServerEvent {
        let framed = try await connection.receive()
        let message: SpiceServerMessage
        do {
            message = try SpiceServerMessageDecoder.decode(
                id: framed.type,
                body: framed.body,
                channel: .inputs
            )
        } catch let error {
            throw .wire(error)
        }

        switch message {
        case let .inputsInit(initial):
            keyboardModifiers = initial.keyboardModifiers
            try await acknowledgeIfNeeded()
            return .initialized(keyboardModifiers: initial.keyboardModifiers)
        case let .inputsKeyModifiers(modifiers):
            keyboardModifiers = modifiers.modifiers
            try await acknowledgeIfNeeded()
            return .keyboardModifiersChanged(modifiers.modifiers)
        case .inputsMouseMotionAck:
            try await acknowledgeIfNeeded()
            return .mouseMotionAcknowledged
        case let .setAck(setAck):
            ackController.configure(generation: setAck.generation, window: setAck.window)
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
            return .ignored(framed.type)
        case let .ping(ping):
            try await connection.send(SpiceMsgcPong(id: ping.id, time: ping.time))
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case .disconnecting:
            throw .transport(.connectionClosed)
        case .unknown:
            try await acknowledgeIfNeeded()
            return .ignored(framed.type)
        case .mainInit,
             .mainMultimediaTime,
             .mainChannelsList,
             .mainMouseMode,
             .mainAgentConnected,
             .mainAgentDisconnected,
             .mainAgentData,
             .mainAgentToken,
             .mainMigration,
             .displaySurfaceCreate,
             .displaySurfaceDestroy,
             .displayCopyBits,
             .displayDrawFill,
             .displayDrawCopy,
             .displayReset,
             .displayInvalidateImages,
             .displayInvalidateAllImages,
             .displayInvalidatePalette,
             .displayInvalidateAllPalettes,
             .displayStreamCreate,
             .displayStreamData,
             .displayStreamDataSized,
             .displayStreamClip,
             .displayStreamDestroy,
             .displayStreamDestroyAll,
             .displayMonitorsConfiguration,
             .cursor,
             .playback,
             .record,
             .smartcard:
            throw .protocolViolation("message received on wrong Inputs Channel")
        }
    }

    package func close() async {
        guard !isClosed else { return }
        isClosed = true
        invalidateSendGeneration()
        await connection.close()
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) throws(ChannelError) -> ChannelConnection {
        guard !isClosed else { throw .invalidState }
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Inputs Channel")
        }
        let previous = connection
        connection = replacement
        invalidateSendGeneration()
        return previous
    }

    private func mask(for button: SpiceMouseButton) -> UInt16 {
        UInt16(1) << UInt16(button.rawValue - 1)
    }

    private func acquireSendTurn() async -> SendTurn {
        guard !Task.isCancelled else { return .cancelled }
        guard isSending else {
            isSending = true
            return .acquired
        }
        nextSendWaiterID &+= 1
        let waiterID = nextSendWaiterID
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                sendWaiters.append(SendWaiter(
                    id: waiterID,
                    continuation: continuation
                ))
                let testWaiters = queuedSendTestWaiters
                queuedSendTestWaiters.removeAll(keepingCapacity: false)
                for waiter in testWaiters { waiter.resume() }
            }
        } onCancel: {
            Task { await self.cancelSendWaiter(id: waiterID) }
        }
    }

    private func releaseSendTurn() {
        guard !sendWaiters.isEmpty else {
            isSending = false
            return
        }
        sendWaiters.removeFirst().continuation.resume(returning: .acquired)
    }

    private func cancelSendWaiter(id: UInt64) {
        guard let index = sendWaiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        sendWaiters.remove(at: index).continuation.resume(returning: .cancelled)
    }

    private func invalidateSendWaiters() {
        let waiters = sendWaiters
        sendWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.continuation.resume(returning: .generationChanged)
        }
    }

    private func encodedScanCode(
        _ scanCode: UInt32,
        release: Bool
    ) throws(ChannelError) -> UInt32 {
        guard scanCode > 0, scanCode <= 0x37f else {
            throw .protocolViolation("invalid PC XT scan code \(scanCode)")
        }
        var encoded = scanCode
        if release {
            encoded |= 0x80
        }
        if encoded < 0x100 {
            return encoded
        }
        let lowByte = UInt16(truncatingIfNeeded: encoded - 0x100)
        return UInt32(UInt16(bigEndian: 0xe000 | lowByte))
    }

    private func acknowledgeIfNeeded() async throws(ChannelError) {
        if ackController.didProcessMessage() {
            try await connection.send(SpiceMsgcAck())
        }
    }
}
