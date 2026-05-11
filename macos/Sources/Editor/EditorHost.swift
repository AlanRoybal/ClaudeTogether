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
                EditorAutocompleteOverlay(
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


/// Floats the autocomplete popover above (or below, when there is no
/// room above) the local caret in the editor. Reads cursor position
/// from `EditorGridModel.cursors` and derives cell size from the live
/// SwiftUI bounds so it tracks the renderer at any window size.
struct EditorAutocompleteOverlay: View {
    @ObservedObject var autocomplete: AutocompleteState
    @ObservedObject var gridModel: EditorGridModel

    private let estItemHeight: CGFloat = 22
    private let estPadding: CGFloat = 8
    private let estWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            if autocomplete.visible,
               !autocomplete.items.isEmpty,
               let local = gridModel.cursors.first(where: { $0.isLocal })
            {
                let position = computePosition(geo: geo, local: local)
                AutocompletePopover(state: autocomplete)
                    .frame(width: estWidth, alignment: .leading)
                    .offset(x: position.x, y: position.y)
            }
        }
        .allowsHitTesting(false)
    }

    private func computePosition(geo: GeometryProxy,
                                 local: UserCursor) -> CGPoint
    {
        let cols = max(CGFloat(gridModel.cols), 1)
        let rows = max(CGFloat(gridModel.rows), 1)
        let cellW = geo.size.width / cols
        let cellH = geo.size.height / rows
        let caretX = CGFloat(local.col) * cellW
        let caretY = CGFloat(local.row) * cellH

        let estHeight = max(1, CGFloat(autocomplete.items.count)
                            * estItemHeight + estPadding)
        let preferredAbove = caretY - estHeight - 4
        let py = preferredAbove >= 0 ? preferredAbove : caretY + cellH + 4
        let px = min(max(0, caretX),
                     max(0, geo.size.width - estWidth))
        return CGPoint(x: px, y: py)
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
