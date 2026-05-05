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

/// SwiftUI suggestion list. The caller positions it (typically with
/// `.position` or `.offset`) — this view only draws the list and tracks
/// selection through the bound `AutocompleteState`.
struct AutocompletePopover: View {
    @ObservedObject var state: AutocompleteState

    var body: some View {
        if state.visible, !state.items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(state.items.enumerated()), id: \.offset) { index, item in
                    HStack(spacing: 0) {
                        Text(item)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(index == state.selectedIndex
                                             ? Color.white
                                             : Color.primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .background(index == state.selectedIndex
                                ? Color.accentColor
                                : Color.clear)
                }
            }
            .frame(maxWidth: 320)
            .background(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.18), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 4)
            .allowsHitTesting(false)
        }
    }
}
