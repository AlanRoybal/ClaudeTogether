import SwiftUI

struct SessionSidebar: View {
    @ObservedObject var model: TerminalModel

    var body: some View {
        let _ = NSLog("[ct] sidebar render url=%@ state=%@",
                      model.sessionManager.publicURL ?? "<nil>",
                      "\(model.sessionManager.state)")
        VStack(alignment: .leading, spacing: 12) {
            Text("Session")
                .font(.headline)

            GroupBox("Project folder") {
                VStack(alignment: .leading, spacing: 4) {
                    if let path = model.rootPath {
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                    } else {
                        Text("Not set — required to share")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Button(model.rootPath == nil ? "Choose folder…" : "Change folder…") {
                        model.pickProjectFolder()
                    }
                    .font(.caption)
                    .disabled(model.sessionManager.state == .running)
                }
            }

            // Mouse-reporting (xterm SGR) — when off, mouse events fall
            // through to default NSView behavior. TUIs that DECSET 1000/
            // 1002/1003 will still work the moment this is flipped back on.
            Toggle("Mouse mode", isOn: $model.mouseMode)
                .help("Enable terminal mouse reporting and click/drag cursor control in the shared terminal input line and /edit editor.")

            Divider()

            GroupBox("Your name") {
                TextField(
                    "Display name",
                    text: Binding(
                        get: { model.sessionManager.localName },
                        set: { model.sessionManager.localName = $0 }),
                    onCommit: { model.sessionManager.persistName() })
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }

            GroupBox("Share") {
                VStack(alignment: .leading, spacing: 6) {
                    switch model.sessionManager.state {
                    case .idle:
                        Button("Start shared session") { model.startSharing() }
                        Text("Starts a tunnel and gives you a URL to share.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Divider()
                        Button("Join shared session…") { model.promptJoin() }
                        Text("Paste the host:port#k=... URL you received.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    case .starting:
                        Text("Starting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    case .running:
                        Text(model.sessionManager.role == .host
                             ? "Hosting on port \(model.sessionManager.localPort)"
                             : "Connected as peer")
                            .font(.caption)
                        if let url = model.sessionManager.publicURL {
                            HStack {
                                Text(url)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                }
                                .controlSize(.mini)
                            }
                        } else if model.sessionManager.role == .host {
                            if let err = model.sessionManager.lastError {
                                Text(err)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                Button("Retry") { model.retryBoreTunnel() }
                                    .controlSize(.small)
                            } else {
                                Text("Connecting to relay…")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if !model.sessionManager.participants.isEmpty {
                            Text("Users:")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ParticipantColorLegend(
                                participants: model.sessionManager.participants,
                                localIdentity: model.sessionManager.localIdentity)
                        }
                        Button("Leave") {
                            if model.sessionManager.role == .peer {
                                model.endSession()
                            } else {
                                model.stopSharing()
                            }
                        }
                            .controlSize(.small)
                    case .disconnected:
                        Text("Host disconnected")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Dismiss") { model.endSession() }
                            .controlSize(.small)
                    case .failed(let msg):
                        Text("Failed: \(msg)")
                            .font(.caption)
                            .foregroundStyle(.red)
                        Button("Reset") { model.stopSharing() }
                            .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if model.sessionManager.role == .host
                && model.sessionManager.state == .running
            {
                GroupBox("Access") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker(
                            "Mode",
                            selection: Binding(
                                get: { model.sessionManager.accessMode },
                                set: { model.sessionManager.setAccessMode($0) })
                        ) {
                            Text("Full access").tag(AccessMode.full)
                            Text("View only").tag(AccessMode.viewOnly)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        Text(accessHostHelp)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if model.sessionManager.role == .peer
                && model.sessionManager.state == .running
            {
                GroupBox("Access") {
                    HStack {
                        Text(accessPeerLabel)
                            .font(.caption)
                            .foregroundStyle(accessPeerLabelColor)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("core v\(model.coreVersion)")
                        .font(.caption)
                    if let tool = model.tunnelTool {
                        let label = tool.server.isEmpty ? "tunnel: ngrok" : "tunnel: bore relay"
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(tool.path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        Text("tunnel: not found")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()
        }
        .padding(12)
    }

    /// Per-mode helper text shown beneath the host's access Picker.
    private var accessHostHelp: String {
        switch model.sessionManager.accessMode {
        case .full:
            return "Peers can type, edit, and use shared input."
        case .viewOnly:
            return "Peers observe only — input is dropped."
        }
    }

    private var accessPeerLabel: String {
        switch model.sessionManager.accessMode {
        case .full:
            return "Full access"
        case .viewOnly:
            return "View only"
        }
    }

    private var accessPeerLabelColor: Color {
        switch model.sessionManager.accessMode {
        case .full:
            return .secondary
        case .viewOnly:
            return .orange
        }
    }
}
