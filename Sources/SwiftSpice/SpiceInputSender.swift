import Foundation

/// Opaque identity for one connected Inputs transport generation.
///
/// A generation is invalidated by disconnect, session failure, migration
/// rebind, or an ambiguous input transport write. Callers must obtain a new
/// ``SpiceInputSender`` after the session establishes its replacement Inputs
/// transport.
public struct SpiceInputGeneration: Sendable, Hashable {
    let sessionID: UUID
    let sequence: UInt64

    init(sessionID: UUID, sequence: UInt64) {
        self.sessionID = sessionID
        self.sequence = sequence
    }
}

/// A conservative set of controls that may still be down in the guest after
/// an Inputs transport failure.
///
/// This value deliberately contains no human/agent ownership or planned input
/// state. The application forms this set from its wire-committed, uncertain,
/// and applied ownership state, keeps source semantics itself, and may replay
/// current human-held controls only after
/// ``SpiceInputSender/sendRecoveryFence(_:)`` succeeds on a newly connected
/// session generation.
public struct SpiceInputRecoverySnapshot: Sendable, Equatable {
    public let possiblyPressedScanCodes: [UInt32]
    public let possiblyPressedButtons: [SpiceMouseButton]

    public init(
        possiblyPressedScanCodes: [UInt32],
        possiblyPressedButtons: [SpiceMouseButton]
    ) {
        self.possiblyPressedScanCodes = Array(Set(possiblyPressedScanCodes)).sorted()
        self.possiblyPressedButtons = Self.sortedUnique(possiblyPressedButtons)
    }

    fileprivate var releaseScanCodes: [UInt32] {
        possiblyPressedScanCodes
    }

    fileprivate var releaseButtons: [SpiceMouseButton] {
        possiblyPressedButtons
    }

    private static func sortedUnique(
        _ buttons: [SpiceMouseButton]
    ) -> [SpiceMouseButton] {
        Array(Set(buttons)).sorted { $0.rawValue < $1.rawValue }
    }
}

/// A narrow, generation-bound capability for sending physical SPICE input.
///
/// It does not expose the raw Inputs Channel. Once a send has an ambiguous
/// transport failure, the session invalidates this sender and tears down the
/// whole SPICE connection; independent Inputs-only reconnection is not assumed.
public struct SpiceInputSender: Sendable {
    public let generation: SpiceInputGeneration
    private let session: SpiceSession

    init(session: SpiceSession, generation: SpiceInputGeneration) {
        self.session = session
        self.generation = generation
    }

    public func send(_ input: SpiceClientInput) async throws(SpiceError) {
        try await session.send(input, generation: generation)
    }

    /// Sends only the conservative release fence carried across a full-session
    /// reconnect. It never guesses or replays application ownership.
    ///
    /// The caller retains `snapshot`; if this replacement generation fails,
    /// the same fence can be retried with a sender from another new session.
    public func sendRecoveryFence(
        _ snapshot: SpiceInputRecoverySnapshot
    ) async throws(SpiceError) {
        let scanCodes = snapshot.releaseScanCodes
        guard scanCodes.allSatisfy({ $0 > 0 && $0 <= 0x37f }) else {
            throw .protocolError("invalid scan code in input recovery snapshot")
        }

        try await session.validateInputGeneration(generation)
        for button in snapshot.releaseButtons {
            try await send(.mouseRelease(button))
        }
        for scanCode in scanCodes {
            try await send(.keyUp(scanCode: scanCode))
        }
    }
}
