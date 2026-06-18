import SwiftUI

/// Observable state shared between the autocomplete owner (TerminalModel
/// / EditorController) and the popover view. The owner produces the
/// item list as the user types; the view drives selection navigation
/// (Up/Down).
@MainActor
final class AutocompleteState: ObservableObject {
    /// True when the popover should be visible. Set by `update` /
    /// `dismiss` — also flipped to false when items become empty.
    @Published var visible: Bool = false

    /// Suggestion items, top-first.
    @Published var items: [String] = []

    /// Index of the highlighted item, [0, items.count). Always 0 right
    /// after `update`; advanced by `moveSelection`.
    @Published var selectedIndex: Int = 0

    /// The user-typed prefix that produced this suggestion list. The
    /// editor uses this to compute the suffix to insert on accept; the
    /// terminal uses it to know what to replace.
    @Published var prefix: String = ""

    /// True if the user has explicitly navigated since the popover was
    /// last shown. Enter only auto-accepts when this is true so the
    /// default "type and hit Enter" path stays unaffected.
    @Published var userHasNavigated: Bool = false

    /// Replace the suggestion list. Resets selection to top and clears
    /// the navigation flag. Visibility flips to true iff `items` is
    /// non-empty.
    func update(items: [String], prefix: String) {
        self.items = items
        self.prefix = prefix
        self.selectedIndex = 0
        self.userHasNavigated = false
        self.visible = !items.isEmpty
    }

    /// Hide and clear all state.
    func dismiss() {
        visible = false
        items = []
        selectedIndex = 0
        prefix = ""
        userHasNavigated = false
    }

    /// Wrap-around selection navigation. `delta` is +1 / -1 (Down / Up).
    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        let next = ((selectedIndex + delta) % count + count) % count
        selectedIndex = next
        userHasNavigated = true
    }

    /// Currently-highlighted suggestion, or nil if hidden / empty.
    var currentSelection: String? {
        guard visible, !items.isEmpty else { return nil }
        let i = max(0, min(selectedIndex, items.count - 1))
        return items[i]
    }
}

/// Renders completion hints one row below the shared-input cursor, styled as
/// plain terminal output — like zsh/bash Tab completion display.
/// Dismissed by a second Tab or when typing narrows to zero matches.
struct SharedInputCompletionHintsOverlay: View {
    @ObservedObject var grid: GridModel
    @ObservedObject var autocomplete: AutocompleteState
    var terminalFont: Font = .system(size: 12, design: .monospaced)
    var theme: TerminalTheme = .defaultDark

    var body: some View {
        GeometryReader { geo in
            if autocomplete.visible,
               !autocomplete.items.isEmpty,
               let local = grid.cursors.first(where: { $0.isLocal })
            {
                let cols = max(CGFloat(grid.cols), 1)
                let rows = max(CGFloat(grid.rows), 1)
                let cellW = geo.size.width / cols
                let cellH = geo.size.height / rows
                // One row below the cursor — same as zsh Tab display
                let y = CGFloat(local.row + 1) * cellH

                completionLine(cellW: cellW, cellH: cellH, width: geo.size.width,
                               font: terminalFont)
                    .offset(x: 0, y: y)
            }
        }
        .allowsHitTesting(false)
    }

    private func completionLine(cellW: CGFloat, cellH: CGFloat, width: CGFloat,
                                font: Font) -> some View {
        let colWidth = max(1, Int(width / cellW))
        // Compute column width: longest item + 2-space gap, at least 8
        let maxLen = autocomplete.items.prefix(50).map(\.count).max() ?? 0
        let itemCols = max(8, maxLen + 2)
        let perRow = max(1, colWidth / itemCols)
        let displayItems = Array(autocomplete.items.prefix(50))
        let overflow = autocomplete.items.count > 50

        return VStack(alignment: .leading, spacing: 0) {
            let rows = stride(from: 0, to: displayItems.count, by: perRow).map {
                Array(displayItems[$0 ..< min($0 + perRow, displayItems.count)])
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, rowItems in
                HStack(spacing: 0) {
                    ForEach(Array(rowItems.enumerated()), id: \.offset) { _, item in
                        Text(item)
                            .font(font)
                            .foregroundColor(Color(packedRGB: theme.foreground))
                            .frame(width: CGFloat(itemCols) * cellW, alignment: .leading)
                    }
                }
                .frame(height: cellH)
            }
            if overflow {
                Text("… \(autocomplete.items.count - 50) more")
                    .font(font)
                    .foregroundColor(Color(packedRGB: theme.foreground).opacity(0.6))
                    .frame(height: cellH)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// SwiftUI suggestion list. The caller positions it (typically with
/// `.position` or `.offset`) — this view only draws the list and tracks
/// selection through the bound `AutocompleteState`.
struct AutocompletePopover: View {
    @ObservedObject var state: AutocompleteState
    var theme: TerminalTheme = .defaultDark

    var body: some View {
        if state.visible, !state.items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 0) {
                        Text(item)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(index == state.selectedIndex
                                             ? theme.popupOnAccent
                                             : theme.popupForeground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(index == state.selectedIndex
                                ? theme.popupSelectionBackground
                                : Color.clear)
                }
            }
            .frame(maxWidth: 320)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .themedPopupSurface(theme, cornerRadius: 6, shadowRadius: 8)
            .allowsHitTesting(false)
        }
    }
}
