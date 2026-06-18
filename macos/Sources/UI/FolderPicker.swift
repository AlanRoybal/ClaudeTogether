import AppKit

enum FolderPicker {
    /// Blocks on the app modal open panel. Returns chosen path, or nil if cancelled.
    /// `appearance`, when supplied, matches the panel's light/dark to the
    /// active terminal theme so it reads as part of the app.
    static func pick(prompt: String = "Choose session root",
                     appearance: NSAppearance? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as session root"
        panel.message = prompt
        if let appearance { panel.appearance = appearance }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
