import AppKit
import Testing
@testable import SwiftSpice

@MainActor
@Suite("Desktop keyboard input")
struct SpiceKeyboardInputTests {
    @MainActor
    private final class Recorder {
        var inputs: [SpiceClientInput] = []
    }

    private func fixture() -> (SpiceFramebufferView, Recorder) {
        let recorder = Recorder()
        let view = SpiceFramebufferView(desktop: .init(), surface: .primary) {
            recorder.inputs.append($0)
        }
        return (view, recorder)
    }

    private func event(
        _ type: NSEvent.EventType,
        keyCode: UInt16 = 0,
        flags: NSEvent.ModifierFlags = []
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode
        ))
    }

    @Test func syntheticEmptyFlagsDoNotEmitA() throws {
        let (view, recorder) = fixture()
        view.flagsChanged(with: try event(.flagsChanged))
        view.flagsChanged(with: try event(.flagsChanged))
        #expect(recorder.inputs.isEmpty)
    }

    @Test(arguments: [UInt16(0), 35, 51])
    func syntheticKeySequencePreservesOnlyTheRequestedKey(keyCode: UInt16) throws {
        let (view, recorder) = fixture()
        // Observed automation sequence: zero-keycode flags surround the real
        // key transitions. Include A itself and Backspace as well as P.
        view.flagsChanged(with: try event(.flagsChanged))
        view.keyDown(with: try event(.keyDown, keyCode: keyCode))
        view.flagsChanged(with: try event(.flagsChanged))
        view.keyUp(with: try event(.keyUp, keyCode: keyCode))
        let scanCode = try #require(MacXTScanCode.map[keyCode])
        #expect(recorder.inputs == [
            .keyDown(scanCode: scanCode), .keyUp(scanCode: scanCode),
        ])
    }

    @Test func controlUDoesNotRestoreStaleKeyUpFlags() throws {
        let (view, recorder) = fixture()
        view.flagsChanged(with: try event(.flagsChanged, flags: .control))
        view.keyDown(with: try event(.keyDown, keyCode: 32, flags: .control))
        view.flagsChanged(with: try event(.flagsChanged))
        view.keyUp(with: try event(.keyUp, keyCode: 32, flags: .control))
        _ = view.resignFirstResponder()
        #expect(recorder.inputs == [
            .keyDown(scanCode: 0x1d), .keyDown(scanCode: 0x16),
            .keyUp(scanCode: 0x1d), .keyUp(scanCode: 0x16),
        ])
    }

    @Test func repeatedModifierFlagsDoNotToggleKeys() throws {
        let (view, recorder) = fixture()
        view.flagsChanged(with: try event(.flagsChanged, flags: .shift))
        view.flagsChanged(with: try event(.flagsChanged, flags: .shift))
        view.flagsChanged(with: try event(.flagsChanged))
        view.flagsChanged(with: try event(.flagsChanged))
        #expect(recorder.inputs == [
            .keyDown(scanCode: 0x2a), .keyUp(scanCode: 0x2a),
        ])
    }

    @Test func leftAndRightShiftAreIndependent() throws {
        let (view, recorder) = fixture()
        let shift = NSEvent.ModifierFlags.shift.rawValue
        view.flagsChanged(with: try event(.flagsChanged, keyCode: 56, flags: .init(rawValue: shift | 0x2)))
        view.flagsChanged(with: try event(.flagsChanged, keyCode: 60, flags: .init(rawValue: shift | 0x6)))
        view.flagsChanged(with: try event(.flagsChanged, keyCode: 56, flags: .init(rawValue: shift | 0x4)))
        view.flagsChanged(with: try event(.flagsChanged, keyCode: 60))
        #expect(recorder.inputs == [
            .keyDown(scanCode: 0x2a), .keyDown(scanCode: 0x36),
            .keyUp(scanCode: 0x2a), .keyUp(scanCode: 0x36),
        ])
    }

    @Test func aggregateFlagsPreserveTheHeldRightModifier() throws {
        let (view, recorder) = fixture()
        let rightShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x4)
        view.flagsChanged(with: try event(.flagsChanged, keyCode: 60, flags: rightShift))
        view.flagsChanged(with: try event(.flagsChanged, flags: .shift))
        view.flagsChanged(with: try event(.flagsChanged))
        #expect(recorder.inputs == [
            .keyDown(scanCode: 0x36), .keyUp(scanCode: 0x36),
        ])
    }

    @Test func commandOptionAreReleasedOnFocusLoss() throws {
        let (view, recorder) = fixture()
        view.flagsChanged(with: try event(.flagsChanged, flags: [.command, .option]))
        #expect(recorder.inputs == [
            .keyDown(scanCode: 0x38), .keyDown(scanCode: 0x15b),
        ])
        _ = view.resignFirstResponder()
        #expect(recorder.inputs.count == 4)
        #expect(recorder.inputs.suffix(2).contains(.keyUp(scanCode: 0x38)))
        #expect(recorder.inputs.suffix(2).contains(.keyUp(scanCode: 0x15b)))
        view.flagsChanged(with: try event(.flagsChanged))
        #expect(recorder.inputs.count == 4)
    }
}
