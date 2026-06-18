import SwiftUI

struct FindBarView: View {
    @ObservedObject var state: SearchState
    var theme: TerminalTheme = .defaultDark
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Custom placeholder: SwiftUI's built-in TextField placeholder
            // ignores foregroundStyle and renders in a fixed muted system color
            // that washes out on themed surfaces. Drawing it ourselves keeps it
            // tied to the theme foreground so it stays legible on any theme.
            ZStack(alignment: .leading) {
                if state.query.isEmpty {
                    Text("Find")
                        .foregroundStyle(theme.popupForeground.opacity(0.5))
                        .allowsHitTesting(false)
                }
                TextField("", text: $state.query)
                    .textFieldStyle(.plain)
                    .foregroundStyle(theme.popupForeground)
                    .tint(theme.popupAccent)
                    .focused($fieldFocused)
                    .onSubmit { state.selectNext() }
            }
            .frame(minWidth: 120)

            if !state.query.isEmpty {
                matchLabel
                    .font(.caption)
                    .foregroundStyle(theme.popupForeground.opacity(0.7))
                    .fixedSize()

                Divider().frame(height: 14)

                Button(action: { state.selectPrev() }) {
                    Image(systemName: "chevron.up")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .disabled(state.matches.isEmpty)
                .keyboardShortcut("g", modifiers: [.command, .shift])

                Button(action: { state.selectNext() }) {
                    Image(systemName: "chevron.down")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .disabled(state.matches.isEmpty)
                .keyboardShortcut("g", modifiers: .command)
            }

            Divider().frame(height: 14)

            Button(action: { state.close() }) {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(theme.popupForeground)
        .tint(theme.popupAccent)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .themedPopupSurface(theme, cornerRadius: 8, shadowRadius: 8)
        .onAppear { fieldFocused = true }
        .onKeyPress(.escape) {
            state.close()
            return .handled
        }
    }

    @ViewBuilder
    private var matchLabel: some View {
        if state.matches.isEmpty {
            Text("No matches")
        } else if let idx = state.currentMatchIndex {
            Text("\(idx + 1) of \(state.matches.count)")
        } else {
            Text("\(state.matches.count) matches")
        }
    }
}
