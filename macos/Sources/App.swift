import SwiftUI

@main
struct CoTTYApp: App {
    /// The model is owned at the App level so menu commands (which live in
    /// `.commands { ... }` on the scene) can drive the same TerminalModel
    /// instance that ContentView renders.
    @StateObject private var model = TerminalModel()

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
        }
        .commands {
            // File menu: standard Mac terminal session lifecycle and tabs.
            CommandGroup(replacing: .newItem) {
                Button("New Session") { model.startSession() }
                    .keyboardShortcut("n", modifiers: .command)

                Button("New Tab") { model.openNewTab() }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") { model.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(model.tabs.isEmpty)

                Divider()

                Button("Close Session") { model.endSession() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(!model.hasActiveSession)

                Divider()

                Button("Show Next Tab") { model.nextTab() }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Show Previous Tab") { model.previousTab() }
                .keyboardShortcut("[", modifiers: [.command, .shift])

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
                Button("Find...") { model.presentFindPrompt() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.grid == nil)
            }

            // View menu: clear screen, font size, sidebar.
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
                Button(model.sidebarVisible ? "Hide Sidebar" : "Show Sidebar") {
                    model.sidebarVisible.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        // Settings scene -> automatically wires Preferences… (⌘,) into the
        // app menu on macOS 13+.
        Settings {
            PreferencesView()
        }
    }
}

/// Placeholder Preferences window. Tabs are intentionally empty so the
/// scaffolding is in place but no behavior changes are advertised yet.
struct PreferencesView: View {
    var body: some View {
        TabView {
            VStack(alignment: .leading, spacing: 8) {
                Text("General preferences will appear here.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .tabItem { Label("General", systemImage: "gear") }

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance preferences will appear here.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(20)
            .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 480, height: 240)
    }
}
