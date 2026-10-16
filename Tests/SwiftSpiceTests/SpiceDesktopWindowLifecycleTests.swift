import AppKit
import SpiceChannels
import SpiceRenderer
import Synchronization
import Testing
@testable import SwiftSpice

@MainActor
@Suite("Desktop window presentation lifecycle")
struct SpiceDesktopWindowLifecycleTests {
    // Model the transient occlusion reported during a native full-screen or
    // screen transition without depending on the test machine's active Space.
    private final class Window: NSWindow {
        var reportedOcclusion: NSWindow.OcclusionState = []

        override var occlusionState: NSWindow.OcclusionState {
            reportedOcclusion
        }
    }

    @Test func visibilityResumeAcknowledgesUnchangedFrameAgain() {
        let source = SpiceDesktopSource()
        source.beginSession(pointerMode: .absolute)
        let unchangedFrame = frame(revision: 1)
        let consumed = Mutex<[UInt64]>([])
        let registration = source.frameDemandCoordinator.register(channelID: 0) { event in
            switch event {
            case .demandChanged(_, true):
                // Emulate the publisher's fresh, same-revision snapshot on
                // each demand resume, through the production delivery path.
                source.receiveFrame(unchangedFrame, displayChannelID: 0)
            case let .frameConsumed(revision):
                consumed.withLock { $0.append(revision.revision) }
            default:
                break
            }
        }
        let view = SpiceFramebufferView(desktop: source, surface: .primary) { _ in }
        let window = Window(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.reportedOcclusion = .visible
        window.contentView = view
        defer {
            registration.cancel()
            view.prepareForDismantle()
            window.contentView = nil
            window.close()
        }
        #expect(consumed.withLock { $0 } == [1])

        // Entering full screen can hide and restore a desktop without any
        // guest mutation. The publisher republishes that unchanged revision
        // and waits for a new consumption acknowledgement before sending more.
        for _ in 0..<2 {
            window.reportedOcclusion = []
            NotificationCenter.default.post(
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
            consumed.withLock { $0.removeAll() }

            window.reportedOcclusion = .visible
            NotificationCenter.default.post(
                name: NSWindow.didChangeOcclusionStateNotification, object: window
            )
            #expect(source.metrics().visibleSubscriptions == 1)
            #expect(consumed.withLock { $0 } == [1])
        }
    }

    private func frame(revision: UInt64) -> FrameSnapshot {
        FrameSnapshot(
            surfaceID: 0, width: 2, height: 2, bytesPerRow: 8,
            lifecycleGeneration: 1, revision: revision,
            pixels: Data(repeating: UInt8(revision), count: 16),
            ioSurfaceFrame: nil
        )
    }
}
