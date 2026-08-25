import Foundation
import SwiftSpice
import SwiftUI

struct RemoteViewerView: View {
    let store: ViewerStore
    let profileStore: ViewerProfileStore

    @AppStorage("viewer.host") private var host = "127.0.0.1"
    @AppStorage("viewer.port") private var port = "5900"
    @AppStorage("viewer.tlsMode") private var tlsMode = ViewerTLSMode.plainTCP.rawValue
    @AppStorage("viewer.automaticallyReconnect") private var automaticallyReconnect = true
    @State private var password = ""
    @State private var selectedProfileID: UUID?
    @State private var profileName = ""
    @State private var profileError: String?
    @State private var showsMonitorControl = false

    var body: some View {
        VStack(spacing: 0) {
            connectionStatusBar
            ZStack {
                SpiceDesktopView(
                    desktop: store.desktop,
                    onInput: store.submit
                )
                .background(.black)

                if !store.connectionState.isConnected {
                    connectionCard
                }
            }
        }
    }

    private var connectionStatusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(store.connectionState.label)
            if store.connectionState.isConnected {
                Text(store.presentationPath)
                    .foregroundStyle(.secondary)
                Divider()
                    .frame(height: 16)
                Label(store.playbackStatus.label, systemImage: store.playbackStatus.systemImage)
                    .foregroundStyle(playbackForegroundStyle)
                    .help(store.playbackStatus.diagnosticSummary)
                Divider()
                    .frame(height: 16)
                Label(store.recordStatus.label, systemImage: store.recordStatus.systemImage)
                    .foregroundStyle(recordForegroundStyle)
                    .help(store.recordStatus.diagnosticSummary)
                if store.recordStatus.phase == .requestingPermission {
                    ProgressView()
                        .controlSize(.small)
                        .help("Waiting for microphone permission")
                    Button("Cancel Mic") {
                        store.setMicrophoneEnabled(false)
                    }
                } else if store.recordStatus.canEnable {
                    Button(store.recordStatus.phase == .denied ? "Retry Mic" : "Enable Mic") {
                        store.setMicrophoneEnabled(true)
                    }
                    .help("Request microphone permission and enable guest recording")
                } else if store.recordStatus.canDisable {
                    Button("Disable Mic") {
                        store.setMicrophoneEnabled(false)
                    }
                }
                Divider()
                    .frame(height: 16)
                Label(
                    store.clipboardStatus.label,
                    systemImage: store.clipboardStatus.systemImage
                )
                .foregroundStyle(clipboardForegroundStyle)
                .help(store.clipboardStatus.diagnosticSummary)
                if store.clipboardStatus.canEnable {
                    Button(
                        clipboardEnableButtonTitle
                    ) {
                        store.setClipboardEnabled(true)
                    }
                    .help("Synchronize UTF-8 text through the SPICE Agent; this is not keyboard or IME input")
                } else if store.clipboardStatus.canDisable {
                    Button("Disable Clipboard") {
                        store.setClipboardEnabled(false)
                    }
                }
                Divider()
                    .frame(height: 16)
                Menu {
                    Button("Send File…") {
                        store.chooseAndSendFile()
                    }
                    Divider()
                    if let error = store.fileTransferStatus.submissionError {
                        Text(error)
                    }
                    if store.fileTransferStatus.items.isEmpty {
                        Text("No transfers")
                    } else {
                        ForEach(store.fileTransferStatus.items) { item in
                            Text("\(item.name) — \(item.summary)")
                            if item.isActive {
                                Button("Cancel \(item.name)", role: .destructive) {
                                    store.cancelFileTransfer(item.id)
                                }
                            }
                        }
                    }
                } label: {
                    Label(store.fileTransferStatus.label, systemImage: "arrow.up.doc")
                        .foregroundStyle(fileTransferForegroundStyle)
                }
                .help("Explicitly select one host file to send; this does not enable clipboard access")
                Divider()
                    .frame(height: 16)
                Button {
                    showsMonitorControl = true
                } label: {
                    Label(store.monitorStatus.label, systemImage: "display.2")
                        .foregroundStyle(monitorForegroundStyle)
                }
                .buttonStyle(.plain)
                .help("Show authoritative Display inventory and request a resolution")
                .popover(isPresented: $showsMonitorControl, arrowEdge: .bottom) {
                    MonitorControlView(store: store)
                }
            }
            Spacer()
            if store.connectionState.canDisconnect {
                Button("Disconnect") { store.disconnect() }
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.bar)
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Connect to SPICE")
                    .font(.title2.weight(.semibold))
                Text("Open a TCP or TLS session and attach its display, cursor, and input channels.")
                    .foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Profile")
                    HStack {
                        Picker("Profile", selection: $selectedProfileID) {
                            Text("Custom").tag(nil as UUID?)
                            ForEach(profileStore.profiles) { profile in
                                Text(profile.name).tag(profile.id as UUID?)
                            }
                        }
                        .labelsHidden()
                        Button("Save") { saveProfile() }
                        if selectedProfileID != nil {
                            Button("Delete", role: .destructive) { deleteProfile() }
                        }
                    }
                }
                GridRow {
                    Text("Name")
                    TextField("Optional profile name", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Host")
                    TextField("127.0.0.1", text: $host)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Port")
                    TextField("5900", text: $port)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Password")
                    SecureField("Optional ticket password", text: $password)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Transport")
                    Picker("Transport", selection: $tlsMode) {
                        ForEach(ViewerTLSMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                }
            }
            .onChange(of: selectedProfileID) { _, profileID in
                loadProfile(id: profileID)
            }

            Toggle("Reconnect automatically (1, 2, 4, 8, then 16 seconds)", isOn: $automaticallyReconnect)

            if let profileError {
                Label(profileError, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if selectedTLSMode == .insecureTLS {
                Label(
                    "Certificate verification is disabled. Use only in an isolated test environment.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            if case let .failed(message) = store.connectionState {
                Label(message, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                if store.connectionState.isBusy {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(store.connectionState.isBusy ? "Connecting…" : "Connect") {
                    store.connect(
                        configuration: configuration,
                        password: password,
                        automaticallyReconnect: automaticallyReconnect
                    )
                }
                .keyboardShortcut(.defaultAction)
                .disabled(store.connectionState.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.2), radius: 24, y: 8)
        .padding(24)
    }

    private var selectedTLSMode: ViewerTLSMode {
        ViewerTLSMode(rawValue: tlsMode) ?? .plainTCP
    }

    private var configuration: ViewerEndpointConfiguration {
        ViewerEndpointConfiguration(host: host, portText: port, tlsMode: selectedTLSMode)
    }

    private func loadProfile(id: UUID?) {
        guard let id,
              let profile = profileStore.profiles.first(where: { $0.id == id })
        else {
            profileName = ""
            return
        }
        profileName = profile.name
        host = profile.host
        port = String(profile.port)
        tlsMode = profile.tlsMode.rawValue
        profileError = nil
    }

    private func saveProfile() {
        do {
            let profile = try profileStore.save(
                id: selectedProfileID,
                name: profileName,
                configuration: configuration
            )
            selectedProfileID = profile.id
            profileName = profile.name
            profileError = nil
        } catch {
            profileError = error.localizedDescription
        }
    }

    private func deleteProfile() {
        guard let selectedProfileID else { return }
        profileStore.delete(id: selectedProfileID)
        self.selectedProfileID = nil
        profileName = ""
        profileError = nil
    }

    private var statusColor: Color {
        switch store.connectionState {
        case .disconnected: .secondary
        case .connecting, .reconnecting: .orange
        case .connected: .green
        case .failed: .red
        }
    }

    private var playbackForegroundStyle: Color {
        if case .failed = store.playbackStatus.phase { return .red }
        return .secondary
    }

    private var recordForegroundStyle: Color {
        switch store.recordStatus.phase {
        case .denied, .restricted, .failed:
            .red
        case .active:
            .primary
        default:
            .secondary
        }
    }

    private var clipboardForegroundStyle: Color {
        if case .failed = store.clipboardStatus.phase { return .red }
        if case .ready = store.clipboardStatus.phase { return .primary }
        return .secondary
    }

    private var clipboardEnableButtonTitle: String {
        if case .failed = store.clipboardStatus.phase { return "Retry Clipboard" }
        return "Enable Clipboard"
    }

    private var fileTransferForegroundStyle: Color {
        if store.fileTransferStatus.submissionError != nil { return .red }
        if store.fileTransferStatus.activeCount > 0 { return .primary }
        return .secondary
    }

    private var monitorForegroundStyle: Color {
        switch store.monitorStatus.requestPhase {
        case .failed, .rejected:
            .red
        case .unsupported:
            .orange
        case .queued, .sent, .acknowledged, .applied:
            .primary
        case .idle:
            .secondary
        }
    }
}
