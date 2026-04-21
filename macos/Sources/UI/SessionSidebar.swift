import SwiftUI

struct SessionSidebar: View {
    @ObservedObject var model: TerminalModel

    var body: some View {
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

            if model.session != nil {
                Button("End session") { model.endSession() }
            } else {
                Button("Start session…") { model.startSession() }
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
