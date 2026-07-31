import AppKit
import SwiftUI

@main
struct SpiceViewerApp: App {
    @State private var store = ViewerStore()
    @State private var profileStore = ViewerProfileStore()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("SwiftSpice") {
            ViewerContentView(store: store, profileStore: profileStore)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { store.start() }
                .onDisappear { store.stop() }
        }
        .defaultSize(width: 1_080, height: 700)
    }
}
