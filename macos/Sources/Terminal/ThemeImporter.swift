import Foundation

enum ThemeImportError: LocalizedError {
    case unsupportedFormat(String)
    case missingField(String)
    case invalidColor(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "Unsupported theme format: .\(ext)"
        case .missingField(let key):      return "Theme file missing required field: \(key)"
        case .invalidColor(let val):      return "Invalid color value: \(val)"
        }
    }
}

enum ThemeImporter {
    static func load(from url: URL) throws -> TerminalTheme {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "claudetheme": return try loadClaudeTheme(from: url)
        case "itermcolors": return try loadItermColors(from: url)
        default:            throw ThemeImportError.unsupportedFormat(ext)
        }
    }
}

// MARK: - .claudetheme parser (TOML subset)

private func loadClaudeTheme(from url: URL) throws -> TerminalTheme {
    let text = try String(contentsOf: url, encoding: .utf8)
    var name: String?
    var bg: UInt32?
    var fg: UInt32?
    var cursor: UInt32?
    var selection: UInt32?
    // palette indices 0-15; nil entries are filled with defaults after parsing
    var palette: [UInt32?] = Array(repeating: nil, count: 16)

    let ansiKeyIndex: [String: Int] = [
        "black": 0, "red": 1, "green": 2, "yellow": 3,
        "blue": 4, "magenta": 5, "cyan": 6, "white": 7,
        "bright_black": 8, "bright_red": 9, "bright_green": 10, "bright_yellow": 11,
        "bright_blue": 12, "bright_magenta": 13, "bright_cyan": 14, "bright_white": 15,
    ]

    var inAnsi = false
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { continue }

        if line == "[ansi]" {
            inAnsi = true
            continue
        }
        if line.hasPrefix("[") {
            inAnsi = false
            continue
        }

        let parts = line.split(separator: "=", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        guard parts.count == 2 else { continue }
        let key = parts[0].lowercased()
        let val = parts[1]

        if inAnsi {
            if let idx = ansiKeyIndex[key] {
                palette[idx] = try parseHex(val)
            }
        } else {
            switch key {
            case "name":       name = parts[1]
            case "background": bg = try parseHex(val)
            case "foreground": fg = try parseHex(val)
            case "cursor":     cursor = try parseHex(val)
            case "selection":  selection = try parseHex(val)
            default:           break
            }
        }
    }

    guard let resolvedBg = bg   else { throw ThemeImportError.missingField("background") }
    guard let resolvedFg = fg   else { throw ThemeImportError.missingField("foreground") }
    let resolvedName = name ?? url.deletingPathExtension().lastPathComponent

    // Fill missing bright variants from their normal counterparts
    var resolved = palette
    for i in 0..<8 {
        if resolved[i + 8] == nil { resolved[i + 8] = resolved[i] }
    }
    // Fill any still-nil entries with defaults
    let finalPalette: [UInt32] = resolved.enumerated().map { idx, v in
        v ?? TerminalTheme.zigPalette16[idx]
    }

    let selBg = selection ?? blendColor(resolvedBg, resolvedFg, t: 0.25)
    return TerminalTheme(
        name: resolvedName,
        background: resolvedBg,
        foreground: resolvedFg,
        palette: finalPalette,
        selectionBg: selBg,
        cursorColor: cursor ?? resolvedFg
    )
}

// MARK: - .itermcolors parser (XML plist)

private func loadItermColors(from url: URL) throws -> TerminalTheme {
    let data = try Data(contentsOf: url)
    guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    else { throw ThemeImportError.missingField("root dict") }

    func extractColor(_ key: String) throws -> UInt32 {
        guard let sub = plist[key] as? [String: Any] else { throw ThemeImportError.missingField(key) }
        // Clamp before converting: UInt32(Double) traps on negative/NaN, and
        // ThemeLibrary imports every file in the themes dir at startup — one
        // malformed component would crash the app on every launch.
        func channel(_ key: String) -> UInt32 {
            let v = (sub[key] as? Double) ?? 0
            guard v.isFinite else { return 0 }
            return UInt32(min(max(v, 0), 1) * 255)
        }
        let r = channel("Red Component")
        let g = channel("Green Component")
        let b = channel("Blue Component")
        return (r << 16) | (g << 8) | b
    }

    let bg     = try extractColor("Background Color")
    let fg     = try extractColor("Foreground Color")
    let cursor = (try? extractColor("Cursor Color")) ?? fg
    let selBg  = (try? extractColor("Selection Color")) ?? blendColor(bg, fg, t: 0.25)

    var palette: [UInt32] = TerminalTheme.zigPalette16
    for i in 0..<16 {
        if let c = try? extractColor("Ansi \(i) Color") {
            palette[i] = c
        }
    }

    let themeName = url.deletingPathExtension().lastPathComponent
    return TerminalTheme(
        name: themeName,
        background: bg,
        foreground: fg,
        palette: palette,
        selectionBg: selBg,
        cursorColor: cursor
    )
}

// MARK: - Helpers

private func parseHex(_ s: String) throws -> UInt32 {
    let clean = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
    guard clean.count == 6, let value = UInt32(clean, radix: 16) else {
        throw ThemeImportError.invalidColor(s)
    }
    return value
}

// Mirror of the private blendColor in TerminalTheme.swift (same formula).
private func blendColor(_ a: UInt32, _ b: UInt32, t: Double) -> UInt32 {
    func lerp(_ ca: UInt32, _ cb: UInt32) -> UInt32 {
        UInt32(Double(ca) + (Double(cb) - Double(ca)) * t)
    }
    let r = lerp((a >> 16) & 0xFF, (b >> 16) & 0xFF)
    let g = lerp((a >>  8) & 0xFF, (b >>  8) & 0xFF)
    let bv = lerp(a & 0xFF, b & 0xFF)
    return (r << 16) | (g << 8) | bv
}
