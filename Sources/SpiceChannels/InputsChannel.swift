import SpiceCore
import SpiceProtocol
import SpiceWire

package enum SpiceMouseButton: UInt8, Sendable, Equatable {
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
    private var connection: ChannelConnection
    private var buttonsState: UInt16 = 0
    private(set) var keyboardModifiers: UInt16 = 0

    package init(connection: ChannelConnection) {
        self.connection = connection
    }

    package func run(
        emit: @escaping @Sendable (SpiceChannelEvent) async -> Void
    ) async throws(ChannelError) {
        let runConnection = connection
        while !Task.isCancelled {
            let event = try await processNext()
            if case .ignored = event {
                continue
            }
            await emit(.inputs(event))
        }
        if connection === runConnection {
            await runConnection.fail(.transport(.cancelled))
        }
    }

    package func send(_ event: SpiceInputEvent) async throws(ChannelError) {
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
            buttonsState |= mask(for: button)
            try await connection.send(SpiceMsgcInputsMousePress(
                button: button.rawValue,
                buttonsState: buttonsState
            ))
        case let .mouseRelease(button):
            buttonsState &= ~mask(for: button)
            try await connection.send(SpiceMsgcInputsMouseRelease(
                button: button.rawValue,
                buttonsState: buttonsState
            ))
        }
    }

    package func processNext() async throws(ChannelError) -> InputsServerEvent {
        let activeConnection = connection
        do {
            return try await processNextImpl()
        } catch let error {
            if connection === activeConnection {
                await activeConnection.fail(error)
            }
            throw error
        }
    }

    private func processNextImpl() async throws(ChannelError) -> InputsServerEvent {
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
            await connection.configureAcknowledgments(
                generation: setAck.generation,
                window: setAck.window
            )
            try await connection.send(SpiceMsgcAckSync(generation: setAck.generation))
            try await acknowledgeIfNeeded()
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
        await connection.close()
    }

    package func replaceConnection(
        with replacement: ChannelConnection
    ) async throws(ChannelError) -> ChannelConnection {
        guard replacement.key == connection.key else {
            throw .protocolViolation("replacement connection key does not match Inputs Channel")
        }
        let previous = connection
        try await replacement.activate()
        await previous.supersede(
            preservingSerialBarrier: previous.sharesSerialBarrier(with: replacement)
        )
        connection = replacement
        return previous
    }

    private func mask(for button: SpiceMouseButton) -> UInt16 {
        UInt16(1) << UInt16(button.rawValue - 1)
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
        try await connection.acknowledgeLastDelivered()
    }
}
