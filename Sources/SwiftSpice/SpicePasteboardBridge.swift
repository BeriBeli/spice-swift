import AppKit

public struct SpicePasteboardSnapshot: Sendable, Equatable {
    public let changeCount: Int
    public let text: String?

    public init(changeCount: Int, text: String?) {
        self.changeCount = changeCount
        self.text = text
    }
}

/// The only AppKit boundary used by clipboard synchronization.
@MainActor
public enum SpicePasteboardBridge {
    public static func snapshot() -> SpicePasteboardSnapshot {
        snapshot(from: .general)
    }

    @discardableResult
    public static func write(
        text: String
    ) throws(SpiceClipboardError) -> SpicePasteboardSnapshot {
        try write(text: text, to: .general)
    }

    package static func snapshot(from pasteboard: NSPasteboard) -> SpicePasteboardSnapshot {
        SpicePasteboardSnapshot(
            changeCount: pasteboard.changeCount,
            text: pasteboard.string(forType: .string)
        )
    }

    @discardableResult
    package static func write(
        text: String,
        to pasteboard: NSPasteboard
    ) throws(SpiceClipboardError) -> SpicePasteboardSnapshot {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw .pasteboardWriteFailed
        }
        return snapshot(from: pasteboard)
    }
}
