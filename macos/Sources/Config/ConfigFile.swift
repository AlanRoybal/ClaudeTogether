import Foundation

/// Parsed snapshot of ~/.config/CoTTY/config.toml.
/// Every field is Optional — absent key means fall back to UserDefaults.
struct ConfigValues {
    // [terminal]
    var fontSize: Double?
    var fontName: String?
    var ligaturesEnabled: Bool?
    var theme: String?
    var customBg: UInt32?
    var customFg: UInt32?
    // [session]
    var displayName: String?
    var boreServer: String?
}

/// Reads and hot-reloads ~/.config/CoTTY/config.toml.
/// Mirrors ThemeLibrary: @MainActor, @Published, FSEvents on the config directory.
@MainActor
final class ConfigFile: ObservableObject {
    @Published private(set) var current: ConfigValues = ConfigValues()

    static let configDir: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".config/CoTTY", isDirectory: true)

    static let configURL: URL = configDir
        .appendingPathComponent("config.toml")

    private var fsSource: DispatchSourceFileSystemObject?
    private var dirFD: Int32 = -1

    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: Self.configDir.path) {
            try? fm.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        }
        if fm.fileExists(atPath: Self.configURL.path),
           let text = try? String(contentsOf: Self.configURL, encoding: .utf8)
        {
            current = Self.parse(text)
        } else {
            current = ConfigValues()
        }
        startWatching()
    }

    // MARK: - FSEvents directory watch (mirrors ThemeLibrary.startWatching)

    private func startWatching() {
        guard fsSource == nil else { return }
        let fd = open(Self.configDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.load() }
        source.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
            self?.dirFD = -1
            self?.fsSource = nil
        }
        source.resume()
        fsSource = source
    }

    // MARK: - TOML-subset parser (mirrors ThemeImporter.loadClaudeTheme)

    static func parse(_ text: String) -> ConfigValues {
        var vals = ConfigValues()
        var section = ""

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).lowercased()
                continue
            }

            // Strip inline comments before splitting on =
            let stripped = line.components(separatedBy: " #").first ?? line
            let parts = stripped.split(separator: "=", maxSplits: 1)
                .map { $0.trimmingCharacters(in: .whitespaces)
                         .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let val = parts[1]

            switch section {
            case "terminal":
                switch key {
                case "font_size":   vals.fontSize = Double(val)
                case "font_name":   vals.fontName = val.isEmpty ? nil : val
                case "ligatures":   vals.ligaturesEnabled = parseBool(val)
                case "theme":       vals.theme = val.isEmpty ? nil : val
                case "custom_bg":   vals.customBg = parseHex(val)
                case "custom_fg":   vals.customFg = parseHex(val)
                default: break
                }
            case "session":
                switch key {
                case "display_name": vals.displayName = val.isEmpty ? nil : val
                case "bore_server":  vals.boreServer = val.isEmpty ? nil : val
                default: break
                }
            default: break
            }
        }
        return vals
    }

    private static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "1":  return true
        case "false", "no", "0":  return false
        default:                  return nil
        }
    }

    private static func parseHex(_ s: String) -> UInt32? {
        let clean = s.replacingOccurrences(of: "#", with: "")
        guard clean.count == 6 else { return nil }
        return UInt32(clean, radix: 16)
    }
}
