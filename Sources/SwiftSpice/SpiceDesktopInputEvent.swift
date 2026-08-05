/// Describes whether a desktop input was caused by real local activity or by
/// synthetic focus-loss cleanup.
///
/// Applications can use `.humanActivity` to initiate local takeover before
/// forwarding the associated input. `.focusCleanup` releases existing human
/// ownership and must not itself be treated as new human activity.
public enum SpiceDesktopInputOrigin: Sendable, Equatable {
    case humanActivity
    case focusCleanup
}

/// One physical desktop input together with its local activity semantics.
public struct SpiceDesktopInputEvent: Sendable, Equatable {
    public let input: SpiceClientInput
    public let origin: SpiceDesktopInputOrigin

    public init(
        input: SpiceClientInput,
        origin: SpiceDesktopInputOrigin
    ) {
        self.input = input
        self.origin = origin
    }
}

/// Tracks controls physically held through the AppKit desktop bridge.
///
/// Scroll pulses and pointer motion are stateless and do not enter this value.
/// The source-aware application coordinator remains authoritative for aggregate
/// human/agent ownership; this state only prevents duplicate local edges and
/// forms deterministic human-only focus cleanup.
package struct SpiceHumanInputState: Sendable, Equatable {
    private var pressedScanCodes: Set<UInt32> = []
    private var pressedButtons: Set<SpiceMouseButton> = []

    package init() {}

    package mutating func keyDown(
        scanCode: UInt32,
        isRepeat: Bool
    ) -> SpiceDesktopInputEvent? {
        let inserted = pressedScanCodes.insert(scanCode).inserted
        guard inserted || isRepeat else { return nil }
        return activity(.keyDown(scanCode: scanCode))
    }

    package mutating func keyUp(
        scanCode: UInt32
    ) -> SpiceDesktopInputEvent? {
        guard pressedScanCodes.remove(scanCode) != nil else { return nil }
        return activity(.keyUp(scanCode: scanCode))
    }

    package mutating func modifierChanged(
        scanCode: UInt32
    ) -> SpiceDesktopInputEvent {
        if pressedScanCodes.insert(scanCode).inserted {
            return activity(.keyDown(scanCode: scanCode))
        }
        pressedScanCodes.remove(scanCode)
        return activity(.keyUp(scanCode: scanCode))
    }

    package mutating func buttonDown(
        _ button: SpiceMouseButton
    ) -> SpiceDesktopInputEvent? {
        guard pressedButtons.insert(button).inserted else { return nil }
        return activity(.mousePress(button))
    }

    package mutating func buttonUp(
        _ button: SpiceMouseButton
    ) -> SpiceDesktopInputEvent? {
        guard pressedButtons.remove(button) != nil else { return nil }
        return activity(.mouseRelease(button))
    }

    package mutating func releaseForFocusLoss() -> [SpiceDesktopInputEvent] {
        let buttonEvents = pressedButtons
            .sorted { $0.rawValue < $1.rawValue }
            .map { cleanup(.mouseRelease($0)) }
        let keyEvents = pressedScanCodes
            .sorted()
            .map { cleanup(.keyUp(scanCode: $0)) }
        pressedButtons.removeAll(keepingCapacity: true)
        pressedScanCodes.removeAll(keepingCapacity: true)
        return buttonEvents + keyEvents
    }

    private func activity(_ input: SpiceClientInput) -> SpiceDesktopInputEvent {
        SpiceDesktopInputEvent(input: input, origin: .humanActivity)
    }

    private func cleanup(_ input: SpiceClientInput) -> SpiceDesktopInputEvent {
        SpiceDesktopInputEvent(input: input, origin: .focusCleanup)
    }
}
