import SwiftUI

struct ViewerContentView: View {
    let store: ViewerStore
    let profileStore: ViewerProfileStore

    var body: some View {
        NavigationSplitView {
            List(selection: modeBinding) {
                ForEach(ViewerMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode)
                }
            }
            .navigationTitle("SwiftSpice")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            Group {
                switch store.mode {
                case .offline:
                    OfflineViewerView(store: store)
                case .remote:
                    RemoteViewerView(store: store, profileStore: profileStore)
                }
            }
            .navigationTitle(store.windowTitle)
        }
    }

    private var modeBinding: Binding<ViewerMode?> {
        Binding(
            get: { store.mode },
            set: { nextMode in
                if let nextMode { store.selectMode(nextMode) }
            }
        )
    }
}
