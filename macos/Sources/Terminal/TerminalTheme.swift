import Foundation
import SwiftUI
import AppKit

struct TerminalTheme: Equatable, Hashable {
    let name: String
    let background: UInt32
    let foreground: UInt32
    let palette: [UInt32]   // 16 entries matching zigPalette16 order
    let selectionBg: UInt32
    let cursorColor: UInt32

    // Zig's hard-coded source palette (core/src/grid.zig PALETTE_16 + defaults).
    // These are the exact values the renderer sees in c.fg / c.bg.
    static let zigDefaultFg: UInt32 = 0xCCCCCC
    static let zigDefaultBg: UInt32 = 0x000000
    static let zigPalette16: [UInt32] = [
        0x000000, 0xCD3131, 0x0DBC79, 0xE5E510,
        0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
        0x666666, 0xF14C4C, 0x23D18B, 0xF5F543,
        0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
    ]

    // Foreground color lookup. DEFAULT_FG → theme.foreground; palette entries →
    // their theme replacements. Does NOT override 0x000000 with the background,
    // so ANSI color 0 used as text color stays dark/visible on light themes.
    var fgColorMap: [UInt32: UInt32] {
        var m: [UInt32: UInt32] = [:]
        for (i, src) in TerminalTheme.zigPalette16.enumerated() {
            m[src] = palette[i]
        }
        m[TerminalTheme.zigDefaultFg] = foreground
        return m
    }

    // Background color lookup. Palette entries first, then DEFAULT_BG → theme
    // background (applied last so it wins over the palette[0] == 0x000000
    // collision that would otherwise prevent light/cream themes from working).
    var bgColorMap: [UInt32: UInt32] {
        var m: [UInt32: UInt32] = [:]
        for (i, src) in TerminalTheme.zigPalette16.enumerated() {
            m[src] = palette[i]
        }
        m[TerminalTheme.zigDefaultBg] = background
        return m
    }
}

// MARK: - Built-in themes

extension TerminalTheme {
    static let allBuiltin: [TerminalTheme] = [
        .defaultDark, .dracula, .nord, .solarizedDark,
        .light, .solarizedLight, .cream,
    ]

    static func named(_ name: String) -> TerminalTheme {
        allBuiltin.first { $0.name == name } ?? .defaultDark
    }

    // Custom theme constructed from caller-supplied bg/fg. Palette uses the
    // default Zig colors so ANSI color output stays legible on any background.
    static func custom(background: UInt32, foreground: UInt32) -> TerminalTheme {
        // Selection: blend fg toward bg for a subtle highlight
        let selBg = blendColor(background, foreground, t: 0.25)
        return TerminalTheme(
            name: "Custom",
            background: background,
            foreground: foreground,
            palette: TerminalTheme.zigPalette16,
            selectionBg: selBg,
            cursorColor: foreground
        )
    }

    // MARK: Presets

    static let defaultDark = TerminalTheme(
        name: "Default Dark",
        background: 0x000000, foreground: 0xCCCCCC,
        palette: TerminalTheme.zigPalette16,
        selectionBg: 0x4682C8, cursorColor: 0x00BFFF
    )

    static let dracula = TerminalTheme(
        name: "Dracula",
        background: 0x282A36, foreground: 0xF8F8F2,
        palette: [
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C,
            0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFF87,
            0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
        ],
        selectionBg: 0x44475A, cursorColor: 0xF8F8F0
    )

    static let nord = TerminalTheme(
        name: "Nord",
        background: 0x2E3440, foreground: 0xD8DEE9,
        palette: [
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
            0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B,
            0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4,
        ],
        selectionBg: 0x4C566A, cursorColor: 0xD8DEE9
    )

    static let solarizedDark = TerminalTheme(
        name: "Solarized Dark",
        background: 0x002B36, foreground: 0x839496,
        palette: [
            0x073642, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
            0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        ],
        selectionBg: 0x073642, cursorColor: 0x839496
    )

    // Light: white background, pure black text — maximum contrast (21:1).
    static let light = TerminalTheme(
        name: "Light",
        background: 0xFFFFFF, foreground: 0x000000,
        palette: [
            0x000000, 0xCD3131, 0x00BC00, 0x949800,
            0x0451A5, 0xBC05BC, 0x0598BC, 0x555555,
            0x666666, 0xCD3131, 0x14CE14, 0xB5BA00,
            0x0451A5, 0xBC05BC, 0x0598BC, 0x000000,
        ],
        selectionBg: 0xADD6FF, cursorColor: 0x0451A5
    )

    static let solarizedLight = TerminalTheme(
        name: "Solarized Light",
        background: 0xFDF6E3, foreground: 0x586E75,
        palette: [
            0x073642, 0xDC322F, 0x859900, 0xB58900,
            0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83,
            0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3,
        ],
        selectionBg: 0xEEE8D5, cursorColor: 0x268BD2
    )

    // Cream: soft yellow-white background (#FDFBD4), dark brown text.
    static let cream = TerminalTheme(
        name: "Cream",
        background: 0xFDFBD4, foreground: 0x2C2218,
        palette: [
            0x2C2218, 0xA3000C, 0x2E7D32, 0x7C5C00,
            0x1A5EA8, 0x7B2D8B, 0x00757D, 0x8D7D6A,
            0x6B5A45, 0xD32F2F, 0x388E3C, 0xF9A825,
            0x1976D2, 0xAB47BC, 0x00838F, 0x2C2218,
        ],
        selectionBg: 0xEDD5A3, cursorColor: 0x7C5C00
    )
}

// MARK: - SwiftUI / AppKit conveniences

extension TerminalTheme {
    var swiftUIBackground: Color { Color(packedRGB: background) }
    var swiftUIForeground: Color { Color(packedRGB: foreground) }
    var nsBackground: NSColor { NSColor(packedRGB: background) }

    /// True when the background luminance is below 50% — used to choose the
    /// correct NSAppearance so window chrome (title text, traffic lights) stays
    /// legible regardless of the terminal theme.
    var isDark: Bool {
        let r = Double((background >> 16) & 0xFF) / 255
        let g = Double((background >>  8) & 0xFF) / 255
        let b = Double( background        & 0xFF) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b < 0.5
    }
}

extension Color {
    init(packedRGB hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(packedRGB hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >>  8) & 0xFF) / 255.0
        let b = CGFloat( hex        & 0xFF) / 255.0
        self.init(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }
}

// MARK: - Helpers

// Linear interpolation between two packed RGB colors (t=0 → a, t=1 → b).
private func blendColor(_ a: UInt32, _ b: UInt32, t: Double) -> UInt32 {
    func lerp(_ ca: UInt32, _ cb: UInt32) -> UInt32 {
        UInt32(Double(ca) + (Double(cb) - Double(ca)) * t)
    }
    let r = lerp((a >> 16) & 0xFF, (b >> 16) & 0xFF)
    let g = lerp((a >>  8) & 0xFF, (b >>  8) & 0xFF)
    let bv = lerp( a        & 0xFF,  b        & 0xFF)
    return (r << 16) | (g << 8) | bv
}
