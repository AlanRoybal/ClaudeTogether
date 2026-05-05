import SwiftUI

@main
struct ClaudeTogetherApp: App {
    var body: some Scene {
        WindowGroup("ClaudeTogether") {
            ContentView()
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
            // Tabs commands. We post NotificationCenter messages instead of
            // talking to TerminalModel directly so the @StateObject inside
            // ContentView remains the single source of truth.
            CommandGroup(after: .newItem) {
                Divider()
                Button("New Tab") {
                    NotificationCenter.default.post(
                        name: .ctTabsNew, object: nil)
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Tab") {
                    NotificationCenter.default.post(
                        name: .ctTabsClose, object: nil)
                }
                .keyboardShortcut("w", modifiers: .command)

                Divider()

                Button("Show Next Tab") {
                    NotificationCenter.default.post(
                        name: .ctTabsNext, object: nil)
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Show Previous Tab") {
                    NotificationCenter.default.post(
                        name: .ctTabsPrevious, object: nil)
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }
        }
    }
}
