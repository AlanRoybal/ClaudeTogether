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
    }
}
