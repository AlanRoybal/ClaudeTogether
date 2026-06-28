import Foundation

/// Manages user-installed theme files from ~/.config/claudetogether/themes/.
/// Loaded themes are merged with TerminalTheme.allBuiltin by TerminalModel.
@MainActor
final class ThemeLibrary: ObservableObject {
    @Published private(set) var themes: [TerminalTheme] = []

    let themesDir: URL = {
        let config = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/claudetogether/themes", isDirectory: true)
        return config
    }()

    private var fsSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    func load() {
        reloadThemes()
        ensureWatching()
    }

    /// Re-enumerate the themes directory into `themes` (no watch side effects).
    private func reloadThemes() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: themesDir.path) {
            try? fm.createDirectory(at: themesDir, withIntermediateDirectories: true)
        }
        guard let enumerator = fm.enumerator(
            at: themesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]
        ) else { return }

        var loaded: [TerminalTheme] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "claudetheme" || ext == "itermcolors" else { continue }
            if let theme = try? ThemeImporter.load(from: url) {
                loaded.append(theme)
            }
        }
        loaded.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        themes = loaded
    }

    /// Copies a theme file into the themes directory and reloads.
    func importFile(from url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: themesDir.path) {
            try fm.createDirectory(at: themesDir, withIntermediateDirectories: true)
        }
        let dest = themesDir.appendingPathComponent(url.lastPathComponent)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: url, to: dest)
        load()
    }

    // MARK: - FSEvents directory watch

    private func ensureWatching() {
        guard fsSource == nil else { return }
        let fd = open(themesDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            self.reloadThemes()
            // If the directory itself was renamed/deleted, our fd now points at
            // a dead inode and will never fire again — tear down and re-arm a
            // fresh watch on the recreated directory.
            if flags.contains(.delete) || flags.contains(.rename) {
                self.restartWatching()
            }
        }
        // Capture this fd so the handler closes exactly the fd it owns, even if
        // `dirFD` has since been replaced by a re-armed watch.
        source.setCancelHandler { [weak self] in
            close(fd)
            if self?.dirFD == fd { self?.dirFD = -1 }
        }
        source.resume()
        fsSource = source
    }

    /// Cancel the current watch and arm a fresh one (used after the themes
    /// directory's inode is replaced).
    private func restartWatching() {
        fsSource?.cancel()
        fsSource = nil      // drop our reference now so ensureWatching re-arms
        ensureWatching()
    }
}
