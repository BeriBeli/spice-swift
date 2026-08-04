import AppKit
import Testing
@testable import SwiftSpice

@MainActor
private final class FocusLossRecorder {
    var count = 0

    func record() {
        count += 1
    }
}

@Suite("Human desktop input state")
struct SpiceHumanInputStateTests {
    @MainActor
    @Test("legacy public input callback remains mutable")
    func legacyCallbackCompatibility() {
        var view = SpiceDesktopView(frame: nil) { _ in }
        view.onInput = { _ in }
    }

    @Test("key repeat preserves wire events without duplicating ownership")
    func keyRepeatAndCleanup() {
        var state = SpiceHumanInputState()

        #expect(state.keyDown(scanCode: 0x1d, isRepeat: false) == activity(
            .keyDown(scanCode: 0x1d)
        ))
        #expect(state.keyDown(scanCode: 0x1d, isRepeat: false) == nil)
        #expect(state.keyDown(scanCode: 0x1d, isRepeat: true) == activity(
            .keyDown(scanCode: 0x1d)
        ))
        #expect(state.releaseForFocusLoss() == [cleanup(
            .keyUp(scanCode: 0x1d)
        )])
        #expect(state.keyUp(scanCode: 0x1d) == nil)
        #expect(state.releaseForFocusLoss().isEmpty)
    }

    @Test("focus loss releases buttons then keys in deterministic order")
    func deterministicFocusCleanup() {
        var state = SpiceHumanInputState()
        #expect(state.buttonDown(.right) == activity(.mousePress(.right)))
        #expect(state.buttonDown(.left) == activity(.mousePress(.left)))
        #expect(state.buttonDown(.left) == nil)
        #expect(state.keyDown(scanCode: 0x38, isRepeat: false) == activity(
            .keyDown(scanCode: 0x38)
        ))
        #expect(state.keyDown(scanCode: 0x1d, isRepeat: false) == activity(
            .keyDown(scanCode: 0x1d)
        ))

        #expect(state.releaseForFocusLoss() == [
            cleanup(.mouseRelease(.left)),
            cleanup(.mouseRelease(.right)),
            cleanup(.keyUp(scanCode: 0x1d)),
            cleanup(.keyUp(scanCode: 0x38)),
        ])
        #expect(state.buttonUp(.left) == nil)
        #expect(state.keyUp(scanCode: 0x38) == nil)
    }

    @Test("physical releases are activity but cleanup releases are not")
    func releaseOriginsStayDistinct() {
        var state = SpiceHumanInputState()
        _ = state.buttonDown(.middle)
        #expect(state.buttonUp(.middle) == activity(.mouseRelease(.middle)))

        _ = state.modifierChanged(scanCode: 0x2a)
        #expect(state.releaseForFocusLoss() == [cleanup(
            .keyUp(scanCode: 0x2a)
        )])
        #expect(state.modifierChanged(scanCode: 0x2a) == activity(
            .keyDown(scanCode: 0x2a)
        ))
    }

    @MainActor
    @Test("focus observer is target-bound, repeatable, and removable")
    func focusObserverLifecycle() {
        let recorder = FocusLossRecorder()
        let observer = SpiceDesktopFocusObserver(onFocusLoss: recorder.record)
        let target = NSObject()
        let unrelated = NSObject()
        observer.attach(to: target)

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: unrelated
        )
        #expect(recorder.count == 0)
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: target
        )
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: target
        )
        #expect(recorder.count == 2)

        observer.stop()
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: target
        )
        #expect(recorder.count == 2)
    }

    private func activity(_ input: SpiceClientInput) -> SpiceDesktopInputEvent {
        SpiceDesktopInputEvent(input: input, origin: .humanActivity)
    }

    private func cleanup(_ input: SpiceClientInput) -> SpiceDesktopInputEvent {
        SpiceDesktopInputEvent(input: input, origin: .focusCleanup)
    }
}
