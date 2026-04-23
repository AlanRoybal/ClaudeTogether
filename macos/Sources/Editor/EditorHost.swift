import SwiftUI

struct EditorHost: View {
    let controller: EditorController
    @ObservedObject private var state: EditorState

    init(controller: EditorController) {
        self.controller = controller
        self._state = ObservedObject(wrappedValue: controller.state)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.path)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text(statusLine)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 16)

                Button("Save") { controller.requestSave() }
                    .keyboardShortcut("s", modifiers: [.command])
                Button("Close") { controller.requestClose() }
                    .keyboardShortcut("w", modifiers: [.command])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            MetalEditorView(controller: controller)
                .frame(minWidth: 500, minHeight: 300)
        }
    }

    private var statusLine: String {
        let editors = 1 + state.remoteCursors.count
        if state.dirty {
            return "\(editors) editor\(editors == 1 ? "" : "s") • unsaved changes"
        }
        return "\(editors) editor\(editors == 1 ? "" : "s") • saved r\(state.lastSavedRev)"
    }
}
