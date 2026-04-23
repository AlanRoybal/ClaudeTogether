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

                        fsSyncRow

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

            if !model.externalEditPaths.isEmpty {
                GroupBox("External edits detected") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Files below were modified locally between host updates. The host's version overwrote your changes.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        ForEach(model.externalEditPaths.prefix(5), id: \.self) { path in
                            Text(path)
                                .font(.system(.caption2, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if model.externalEditPaths.count > 5 {
                            Text("+\(model.externalEditPaths.count - 5) more")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Button("Dismiss") { model.dismissExternalEditWarnings() }
                            .controlSize(.mini)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

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

    /// FS-sync readout that differs by role:
    ///   host — "Syncing <path> (N files)"
    ///   peer — "Receiving into <path>" + applied-count + external edits
    @ViewBuilder
    private var fsSyncRow: some View {
        Divider()
        if model.sessionManager.role == .host {
            VStack(alignment: .leading, spacing: 2) {
                Text("File sync")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let path = model.rootPath {
                    Text("Sharing \(path)")
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                } else {
                    Text("No folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("File sync")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let root = model.syncRoot {
                    Text("Receiving into \(root.path)")
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Text("\(model.syncAppliedCount) applied")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No local sync folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
