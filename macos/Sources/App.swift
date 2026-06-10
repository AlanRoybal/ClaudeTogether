import SwiftUI
import AppKit

@main
struct CoTTYApp: App {
    /// The model is owned at the App level so menu commands (which live in
    /// `.commands { ... }` on the scene) can drive the same TerminalModel
    /// instance that ContentView renders.
    @StateObject private var model = TerminalModel()

    init() {
        // Kill macOS native window tabbing entirely (the system "CoTTY + tab
        // bar" at the top). The app has its own tab strip; the native one is
        // redundant. Class-level toggle, read when windows are created, so it
        // must be set before the first window appears.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup("CoTTY") {
            ContentView(model: model)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    // DIAG: auto-fire bore so we can see logs without a click.
                    if ProcessInfo.processInfo.environment["CT_AUTOSHARE"] == "1" {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            NotificationCenter.default.post(
                                name: .init("ct.diag.autoshare"), object: nil)
                        }
                    }
                }
                .onOpenURL { url in model.joinFromURL(url) }
        }
        .commands {
            // File menu: standard Mac terminal session lifecycle and tabs.
            CommandGroup(replacing: .newItem) {
                Button("New Tab") { model.openNewTab() }
                    .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") { model.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: .command)
                    .disabled(model.tabs.isEmpty)

                Divider()

                Button("Choose Project Folder…") { model.pickProjectFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.sessionManager.state == .running)

                Divider()

                Button("End Session") { model.endSession() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.hasActiveSession)

                Divider()

                Button("Show Next Tab") { model.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Show Previous Tab") { model.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                ForEach(Array(model.tabs.enumerated()), id: \.element.id) { idx, tab in
                    if idx < 9 {
                        Button("Select Tab \(idx + 1)") { model.focusTab(id: tab.id) }
                            .keyboardShortcut(KeyEquivalent(Character(String(idx + 1))), modifiers: .command)
                    }
                }

                Divider()

                Button("Split Pane Horizontally") {
                    NotificationCenter.default.post(name: .ctPaneSplitH, object: nil)
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(model.sessionManager.role != .host
                          || model.activeTabForView?.splitPane != nil
                          || model.tabs.isEmpty)

                Button("Split Pane Vertically") {
                    NotificationCenter.default.post(name: .ctPaneSplitV, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(model.sessionManager.role != .host
                          || model.activeTabForView?.splitPane != nil
                          || model.tabs.isEmpty)

                Button("Close Split Pane") {
                    NotificationCenter.default.post(name: .ctPaneClose, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(model.sessionManager.role != .host
                          || model.activeTabForView?.splitPane == nil)

                Button("Focus Next Pane") {
                    NotificationCenter.default.post(name: .ctPaneNext, object: nil)
                }
                .keyboardShortcut("\t", modifiers: [.command, .option])
                .disabled(model.activeTabForView?.splitPane == nil)
            }

            // Edit menu: clipboard + find. We replace .pasteboard so our
            // Copy/Paste fire even when no NSText responder is available.
            // Existing performKeyEquivalent overrides on the terminal/editor
            // views still intercept ⌘V before the menu sees it.
            CommandGroup(replacing: .pasteboard) {
                Button("Copy") { model.menuCopy() }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Paste") { model.menuPaste() }
                    .keyboardShortcut("v", modifiers: .command)
                Divider()
                Button("Find") { model.searchState.isVisible.toggle() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.activeGrid == nil)
                Button("Find Next") { model.searchState.selectNext() }
                    .keyboardShortcut("g", modifiers: .command)
                    .disabled(!model.searchState.isVisible || model.searchState.matches.isEmpty)
                Button("Find Previous") { model.searchState.selectPrev() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(!model.searchState.isVisible || model.searchState.matches.isEmpty)
            }

            CommandMenu("Format") {
                Button("Format with Prettier") { model.formatWithPrettier() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                    .disabled(model.activeEditor == nil || model.sessionManager.role != .host)
            }

            // View menu: clear screen, font size, theme.
            CommandGroup(after: .toolbar) {
                Button("Clear Screen") { model.clearScreen() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.grid == nil)
                Divider()
                Button("Increase Font Size") { model.increaseFontSize() }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Font Size") { model.decreaseFontSize() }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Font Size") { model.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Picker("Theme", selection: Binding(
                    get: { model.terminalTheme.name },
                    set: { name in
                        if name == "Custom" {
                            model.terminalTheme = TerminalTheme.custom(
                                background: model.customThemeBg,
                                foreground: model.customThemeFg)
                        } else {
                            model.terminalTheme = model.allThemes.first { $0.name == name } ?? .defaultDark
                        }
                    }
                )) {
                    ForEach(model.allThemes, id: \.name) { t in
                        Text(t.name).tag(t.name)
                    }
                    Divider()
                    Text("Custom").tag("Custom")
                }
            }

            // Session menu: sharing controls, mouse mode, participants.
            CommandMenu("Session") {
                Toggle("Mouse Mode", isOn: $model.mouseMode)

                Divider()

                sessionMenuItems(model: model)
            }
        }

        // Settings scene -> automatically wires Preferences… (⌘,) into the
        // app menu on macOS 13+.
        Settings {
            PreferencesView(model: model)
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model: TerminalModel

    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Your name") {
                    TextField(
                        "Display name",
                        text: Binding(
                            get: { model.sessionManager.localName },
                            set: { model.sessionManager.localName = $0 }),
                        onCommit: { model.sessionManager.persistName() })
                        .textFieldStyle(.roundedBorder)
                }

                GroupBox("Diagnostics") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("core v\(model.coreVersion)")
                            .font(.caption)
                        if let tool = model.tunnelTool {
                            let label = tool.server.isEmpty ? "tunnel: ngrok" : "tunnel: bore relay"
                            Text(label).font(.caption).foregroundStyle(.green)
                            Text(tool.path)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        } else {
                            Text("tunnel: not found").font(.caption).foregroundStyle(.red)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .tabItem { Label("General", systemImage: "gear") }

            VStack(alignment: .leading, spacing: 12) {
                Text("Terminal Theme")
                    .font(.headline)

                ThemeSwatchPickerView(
                    themes: model.allThemes,
                    selected: model.terminalTheme.name,
                    onSelect: { name in
                        model.terminalTheme = model.allThemes.first { $0.name == name } ?? .defaultDark
                    }
                )

                // Custom entry below the grid
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(model.terminalTheme.name == "Custom"
                              ? Color.accentColor : Color.primary.opacity(0.08))
                        .frame(width: 16, height: 16)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(
                                    model.terminalTheme.name == "Custom"
                                        ? Color.accentColor : Color.primary.opacity(0.25),
                                    lineWidth: 1)
                        )
                    Text("Custom")
                        .font(.subheadline)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    model.terminalTheme = TerminalTheme.custom(
                        background: model.customThemeBg,
                        foreground: model.customThemeFg)
                }

                if model.terminalTheme.name == "Custom" {
                    Divider()
                    Text("Custom Colors")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    HexColorField(label: "Background", color: $model.customThemeBg)
                    HexColorField(label: "Foreground", color: $model.customThemeFg)
                }

                HStack {
                    Button("Import Theme File…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = []
                        panel.allowsOtherFileTypes = true
                        panel.message = "Choose a .claudetheme or .itermcolors file"
                        panel.prompt = "Import"
                        if panel.runModal() == .OK, let url = panel.url {
                            try? model.themeLibrary.importFile(from: url)
                        }
                    }
                    Text("Supports .claudetheme and .itermcolors")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                Text("Font")
                    .font(.headline)
                HStack(spacing: 6) {
                    TextField("PostScript font name", text: $model.fontName)
                        .textFieldStyle(.roundedBorder)
                    let installed = NSFont(name: model.fontName, size: 13) != nil
                    Image(systemName: installed ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(installed ? Color.green : Color.red)
                        .help(installed ? "Font found" : "Font not installed — falling back to system monospace")
                }
                Text("Leave blank or enter a PostScript font name (e.g. FiraCode-Regular).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                Toggle("Enable Ligatures", isOn: $model.ligaturesEnabled)
                Text("Renders programming sequences (→, ⇒, ≠, …) as combined glyphs when your font supports them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 520, height: 600)
    }
}

// MARK: - Theme swatch picker

private struct ThemeSwatchPickerView: View {
    let themes: [TerminalTheme]
    let selected: String
    let onSelect: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 10)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(themes, id: \.name) { theme in
                    ThemeSwatchCell(theme: theme, isSelected: selected == theme.name)
                        .onTapGesture { onSelect(theme.name) }
                }
            }
            .padding(2)
        }
        .frame(maxHeight: 280)
    }
}

private struct ThemeSwatchCell: View {
    let theme: TerminalTheme
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(theme.name)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(packedRGB: theme.foreground))
                .lineLimit(1)
                .truncationMode(.tail)

            HStack(spacing: 3) {
                ForEach(0..<8, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(packedRGB: theme.palette[i]))
                        .frame(width: 14, height: 10)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(packedRGB: theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                    lineWidth: isSelected ? 2 : 1)
        )
    }
}

/// State-dependent session menu items used inside `CommandMenu("Session")`.
/// Extracted to a function so the switch/if-else tree is readable and
/// compiles cleanly under @ViewBuilder.
@MainActor @ViewBuilder
private func sessionMenuItems(model: TerminalModel) -> some View {
    switch model.sessionManager.state {
    case .idle:
        Button("Start Shared Session") { model.startSharing() }
        Button("Join Shared Session…") { model.promptJoin() }

    case .starting:
        Button("Starting…") {}.disabled(true)

    case .running:
        let statusLabel = model.sessionManager.role == .host
            ? "Hosting on port \(model.sessionManager.localPort)"
            : "Connected as peer"
        Button(statusLabel) {}.disabled(true)

        if model.sessionManager.role == .host {
            if let urlStr = model.sessionManager.publicURL,
               let url = URL(string: urlStr) {
                ShareLink("Share Session URL", item: url)
                    .keyboardShortcut("u", modifiers: [.command, .shift])
            } else if let err = model.sessionManager.lastError {
                Button("Tunnel Error: \(err)") {}.disabled(true)
                Button("Retry Tunnel") { model.retryBoreTunnel() }
            } else {
                Button("Connecting to relay…") {}.disabled(true)
            }
        } else if let urlStr = model.sessionManager.publicURL,
                  let url = URL(string: urlStr) {
            ShareLink("Share Session URL", item: url)
        }

        if !model.sessionManager.participants.isEmpty {
            Divider()
            ForEach(model.sessionManager.participants) { p in
                let suffix = p.identity == model.sessionManager.localIdentity ? " (you)" : ""
                if model.sessionManager.role == .host
                    && p.identity != model.sessionManager.localIdentity {
                    Menu(p.name) {
                        Button("Remove from Session") {
                            model.sessionManager.kickPeer(p.identity)
                        }
                    }
                } else {
                    Button(p.name + suffix) {}.disabled(true)
                }
            }
        }

        Divider()

        if model.sessionManager.role == .host {
            Picker("Access Mode", selection: Binding(
                get: { model.sessionManager.accessMode },
                set: { model.sessionManager.setAccessMode($0) }
            )) {
                Text("Full Access").tag(AccessMode.full)
                Text("View Only").tag(AccessMode.viewOnly)
            }
        } else {
            let accessLabel = model.sessionManager.accessMode == .full
                ? "Access: Full" : "Access: View Only"
            Button(accessLabel) {}.disabled(true)
        }

        Divider()

        Button("Leave Session") {
            if model.sessionManager.role == .peer {
                model.endSession()
            } else {
                model.stopSharing()
            }
        }

    case .reconnecting(let attempt):
        Button("Reconnecting… (attempt \(attempt) of \(SessionManager.maxReconnectAttempts))") {}
            .disabled(true)
        Button("Leave Session") { model.endSession() }

    case .disconnected:
        Button("Host Disconnected") {}.disabled(true)
        Button("Dismiss") { model.endSession() }

    case .failed(let msg):
        Button("Error: \(msg)") {}.disabled(true)
        Button("Reset Session") { model.stopSharing() }
    }
}

// MARK: - Hex color input

/// Labeled hex color field with a live color swatch. Accepts 6-digit hex
/// with or without a leading '#'. Updates the binding on every valid change.
struct HexColorField: View {
    let label: String
    @Binding var color: UInt32
    @State private var text: String = ""
    @State private var isValid: Bool = true

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .frame(width: 80, alignment: .leading)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(packedRGB: color))
                .frame(width: 22, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.secondary.opacity(0.4)))
            TextField("#RRGGBB", text: $text)
                .frame(width: 90)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(isValid ? nil : Color.red)
                .onChange(of: text) { val in
                    if let parsed = parseHex(val) {
                        color = parsed
                        isValid = true
                    } else {
                        isValid = text.trimmingCharacters(in: .init(charactersIn: "#")).isEmpty || false
                        isValid = false
                    }
                }
                .onAppear { text = String(format: "#%06X", color) }
                .onChange(of: color) { newColor in
                    let expected = String(format: "#%06X", newColor)
                    if parseHex(text) != newColor { text = expected }
                }
        }
    }

    private func parseHex(_ s: String) -> UInt32? {
        let clean = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard clean.count == 6, let value = UInt32(clean, radix: 16) else { return nil }
        return value
    }
}

