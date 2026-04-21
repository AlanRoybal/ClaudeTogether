import AppKit

enum FolderPicker {
    /// Blocks on the app modal open panel. Returns chosen path, or nil if cancelled.
    static func pick(prompt: String = "Choose session root") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as session root"
        panel.message = prompt
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
