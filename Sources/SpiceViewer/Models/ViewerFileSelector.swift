import AppKit

@MainActor
package protocol ViewerFileSelecting {
    func selectFile() async -> URL?
}

@MainActor
package struct SystemViewerFileSelector: ViewerFileSelecting {
    package init() {}

    package func selectFile() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Send"
        panel.message = "Choose one regular file to send to the connected guest."
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}
