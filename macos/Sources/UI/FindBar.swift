import SwiftUI

struct FindBarView: View {
    @ObservedObject var state: SearchState
    var theme: TerminalTheme = .defaultDark
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            TextField("Find", text: $state.query)
                .textFieldStyle(.plain)
                .foregroundStyle(theme.popupForeground)
                .tint(theme.popupAccent)
                .focused($fieldFocused)
                .frame(minWidth: 120)
                .onSubmit { state.selectNext() }

            if !state.query.isEmpty {
                matchLabel
                    .font(.caption)
                    .foregroundStyle(theme.popupSecondaryForeground)
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
