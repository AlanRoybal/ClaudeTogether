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

            GroupBox("Root folder") {
                if let path = model.rootPath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                } else {
                    Text("(no session)")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
            }

            if model.pty != nil {
                Button("End session") { model.endSession() }
            } else {
                Button("Start session…") { model.startSession() }
            }

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
                        Button("Join shared session…") { model.promptJoin() }
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
                            } else {
                                Text("Waiting for bore URL…")
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
                        Button("Leave") { model.stopSharing() }
                            .controlSize(.small)
                    case .disconnected:
                        Text("Host disconnected")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Dismiss") { model.stopSharing() }
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

            Divider()

            GroupBox("Diagnostics") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("core v\(model.coreVersion)")
                        .font(.caption)
                    if let bore = model.boreBundlePath {
                        Text("bore: bundled")
                            .font(.caption)
                            .foregroundStyle(.green)
                        Text(bore)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    } else {
                        Text("bore: MISSING")
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
}
