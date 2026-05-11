import SwiftUI

/// Renders the terminal/editor content area for a tab that may be split into
/// two panes. When `tab.splitPane` is nil this is functionally identical to
/// the single-pane layout that ContentView previously rendered inline.
struct SplitPaneView: View {
    let tab: TabState
    @ObservedObject var model: TerminalModel

    var body: some View {
        if let pane = tab.splitPane {
            switch tab.splitAxis {
            case .horizontal:
                HSplitView {
                    primaryPane
                    secondaryPane(pane)
                }
            case .vertical:
                VSplitView {
                    primaryPane
                    secondaryPane(pane)
                }
            }
        } else {
            primaryPane
        }
    }

    // MARK: - Primary pane

    @ViewBuilder
    private var primaryPane: some View {
        ZStack(alignment: .topLeading) {
            MetalTerminalView(
                grid: tab.grid,
                onKey: { bytes in
                    model.setActivePaneIndex(tabId: tab.id, index: 0)
                    model.handleKey(bytes, forTabId: tab.id, paneIndex: 0)
                },
                onResize: { cols, rows in
                    model.handleResize(cols: cols, rows: rows)
                },
                onMouseCell: { col, row in
                    model.handleTerminalMouseCell(col: col, row: row, forTabId: tab.id)
                },
                inputEnabled: model.inputEnabled,
                isActive: true,
                fontSize: model.fontSize,
                mouseModeEnabled: model.mouseMode,
                theme: model.terminalTheme)
            SharedInputCompletionHintsOverlay(
                grid: tab.grid,
                autocomplete: model.inputAutocomplete)
            if tab.splitPane != nil {
                paneFocusIndicator(active: tab.activePaneIndex == 0)
            }
        }
        .frame(minWidth: 200, minHeight: 100)
    }

    // MARK: - Secondary (split) pane

    @ViewBuilder
    private func secondaryPane(_ pane: SplitPaneState) -> some View {
        ZStack(alignment: .topLeading) {
            MetalTerminalView(
                grid: pane.grid,
                onKey: { bytes in
                    model.setActivePaneIndex(tabId: tab.id, index: 1)
                    // Broadcast this participant's cursor into the split pane
                    // so all peers see where each user is typing.
                    model.broadcastSplitPaneCursor(paneId: pane.id, grid: pane.grid)
                    model.handleKey(bytes, forTabId: tab.id, paneIndex: 1)
                },
                onResize: { cols, rows in
                    model.handleSplitPaneResize(
                        tabId: tab.id, paneId: pane.id, cols: cols, rows: rows)
                },
                inputEnabled: model.inputEnabled,
                isActive: true,
                fontSize: model.fontSize,
                mouseModeEnabled: model.mouseMode,
                theme: model.terminalTheme)
            paneFocusIndicator(active: tab.activePaneIndex == 1)
        }
        .frame(minWidth: 200, minHeight: 100)
    }

    // MARK: - Focus border

    /// Thin border showing which pane currently receives keyboard input.
    /// Color matches the theme foreground so it's always visible on the
    /// terminal background regardless of which theme is active.
    @ViewBuilder
    private func paneFocusIndicator(active: Bool) -> some View {
        if active {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(
                    model.terminalTheme.swiftUIForeground.opacity(0.55),
                    lineWidth: 2)
                .allowsHitTesting(false)
        }
    }
}
