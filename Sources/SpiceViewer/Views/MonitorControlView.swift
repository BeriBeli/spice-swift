import SwiftSpice
import SwiftUI

struct MonitorControlView: View {
    let store: ViewerStore

    @State private var draft = ViewerDisplayLayoutDraft()
    @State private var loadedInitialInventory = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            inventorySection
            Divider()
            layoutEditor
            Divider()
            requestStatus
        }
        .padding(16)
        .frame(width: 760)
        .onAppear {
            guard !loadedInitialInventory else { return }
            draft.load(configurations: store.monitorStatus.configurations)
            loadedInitialInventory = true
        }
    }

    private var inventorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Authoritative Guest Displays")
                    .font(.headline)
                Spacer()
                Button("Reload Draft") {
                    draft.load(configurations: store.monitorStatus.configurations)
                }
                .disabled(store.monitorStatus.configurations.isEmpty)
            }

            if store.monitorStatus.configurations.isEmpty {
                ContentUnavailableView(
                    "No Display Inventory",
                    systemImage: "display",
                    description: Text("Waiting for an authoritative Display Channel notification.")
                )
                .frame(minHeight: 90)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(store.monitorStatus.configurations, id: \.channelID) { configuration in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(channelTitle(configuration))
                                    .font(.subheadline.weight(.semibold))
                                ForEach(configuration.monitors, id: \.id) { monitor in
                                    Text(
                                        "Monitor \(monitor.id) · surface \(monitor.surfaceID) · \(monitor.width)×\(monitor.height) at \(monitor.x),\(monitor.y)"
                                    )
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
        }
    }

    private var layoutEditor: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Requested Layout")
                    .font(.headline)
                Spacer()
                Button {
                    draft.addMonitor()
                } label: {
                    Label("Add Monitor", systemImage: "plus")
                }
                .disabled(draft.monitors.count >= 256)
            }

            Text(draft.sourceNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            layoutHeader
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach($draft.monitors) { $monitor in
                        layoutRow($monitor)
                    }
                }
            }
            .frame(maxHeight: 190)

            HStack(alignment: .firstTextBaseline) {
                Label(store.monitorStatus.supportSummary, systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Request Layout") {
                    guard let configuration = validation.configuration else { return }
                    store.requestDisplayConfiguration(configuration)
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!validation.canSubmit)
            }

            Label(
                validation.message,
                systemImage: validation.canSubmit ? "checkmark.circle" : "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(validation.canSubmit ? Color.secondary : Color.orange)
        }
    }

    private var layoutHeader: some View {
        HStack(spacing: 8) {
            Text("ID").frame(width: 48, alignment: .leading)
            Text("X").frame(width: 90, alignment: .leading)
            Text("Y").frame(width: 90, alignment: .leading)
            Text("Width").frame(width: 110, alignment: .leading)
            Text("Height").frame(width: 110, alignment: .leading)
            Spacer()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func layoutRow(
        _ monitor: Binding<ViewerDisplayLayoutDraft.Monitor>
    ) -> some View {
        HStack(spacing: 8) {
            TextField("ID", text: monitor.monitorID)
                .frame(width: 48)
            TextField("X", text: monitor.x)
                .frame(width: 90)
            TextField("Y", text: monitor.y)
                .frame(width: 90)
            TextField("Width", text: monitor.width)
                .frame(width: 110)
            TextField("Height", text: monitor.height)
                .frame(width: 110)
            Spacer()
            Button(role: .destructive) {
                draft.removeMonitor(id: monitor.wrappedValue.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(draft.monitors.count == 1)
            .help("Remove monitor")
        }
        .textFieldStyle(.roundedBorder)
        .font(.system(.body, design: .monospaced))
    }

    private var requestStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(
                store.monitorStatus.requestSummary,
                systemImage: store.monitorStatus.requestIsActive
                    ? "arrow.triangle.2.circlepath"
                    : "info.circle"
            )
            .font(.caption)
            .foregroundStyle(requestForegroundStyle)

            Text("Agent acknowledgement is not geometry. Applied requires a later matching Display Channel notification.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var validation: ViewerDisplayLayoutDraft.Validation {
        draft.validation(support: store.monitorStatus.support)
    }

    private func channelTitle(_ configuration: SpiceGuestDisplayConfiguration) -> String {
        if let maximum = configuration.maximumAllowed {
            return "Display Channel \(configuration.channelID) · \(configuration.monitors.count)/\(maximum) heads"
        }
        return "Display Channel \(configuration.channelID) · \(configuration.monitors.count) heads"
    }

    private var requestForegroundStyle: Color {
        if case .failed = store.monitorStatus.requestPhase { return .red }
        if case .rejected = store.monitorStatus.requestPhase { return .red }
        if case .unsupported = store.monitorStatus.requestPhase { return .orange }
        return .secondary
    }
}
