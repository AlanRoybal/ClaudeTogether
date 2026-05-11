import SwiftUI

struct EditorHost: View {
    let controller: EditorController
    let mouseModeEnabled: Bool
    let theme: TerminalTheme
    @ObservedObject private var state: EditorState

    init(controller: EditorController,
         mouseModeEnabled: Bool = false,
         theme: TerminalTheme = .defaultDark) {
        self.controller = controller
        self.mouseModeEnabled = mouseModeEnabled
        self.theme = theme
        self._state = ObservedObject(wrappedValue: controller.state)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.path)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundColor(theme.swiftUIForeground)
                    Text(statusLine)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(theme.swiftUIForeground.opacity(0.55))
                }

                Spacer(minLength: 16)

                EditorButton("Save", theme: theme) { controller.requestSave() }
                    .keyboardShortcut("s", modifiers: [.command])
                EditorButton("Close", theme: theme) { controller.requestClose() }
                    .keyboardShortcut("w", modifiers: [.command])
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(theme.swiftUIBackground)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(theme.swiftUIForeground.opacity(0.12))
                    .frame(height: 1)
            }

            ZStack(alignment: .topLeading) {
                MetalEditorView(
                    controller: controller,
                    mouseModeEnabled: mouseModeEnabled,
                    theme: theme)
                EditorGhostTextOverlay(
                    autocomplete: controller.autocomplete,
                    gridModel: controller.gridModel)
            }
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


/// Renders the autocomplete suggestion suffix as dimmed inline ghost text
/// at the cursor position. Tab or Right Arrow accepts; Esc dismisses.
struct EditorGhostTextOverlay: View {
    @ObservedObject var autocomplete: AutocompleteState
    @ObservedObject var gridModel: EditorGridModel

    var body: some View {
        GeometryReader { geo in
            if let suffix = ghostSuffix,
               let local = gridModel.cursors.first(where: { $0.isLocal })
            {
                let cols = max(CGFloat(gridModel.cols), 1)
                let rows = max(CGFloat(gridModel.rows), 1)
                let cellW = geo.size.width / cols
                let cellH = geo.size.height / rows

                Text(suffix)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.primary.opacity(0.35))
                    .fixedSize()
                    .offset(x: CGFloat(local.col) * cellW,
                            y: CGFloat(local.row) * cellH)
                    .frame(maxWidth: .infinity,
                           maxHeight: .infinity,
                           alignment: .topLeading)
            }
        }
        .allowsHitTesting(false)
    }

    private var ghostSuffix: String? {
        guard autocomplete.visible,
              let sel = autocomplete.currentSelection,
              sel.hasPrefix(autocomplete.prefix),
              sel != autocomplete.prefix
        else { return nil }
        return String(sel.dropFirst(autocomplete.prefix.count))
    }
}

/// A small labeled button styled to match the active terminal theme.
/// Uses `.plain` style with a pill-shaped background so it looks at home on
/// any background color rather than drawing a system-blue default button.
private struct EditorButton: View {
    let label: String
    let theme: TerminalTheme
    let action: () -> Void

    init(_ label: String, theme: TerminalTheme, action: @escaping () -> Void) {
        self.label = label
        self.theme = theme
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(theme.swiftUIForeground)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(theme.swiftUIForeground.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
    }
}
