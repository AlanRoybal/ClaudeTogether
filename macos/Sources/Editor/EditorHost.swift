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

            ZStack(alignment: .topLeading) {
                MetalEditorView(controller: controller)
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
