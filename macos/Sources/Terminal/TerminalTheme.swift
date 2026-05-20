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
        .catppuccinMocha, .catppuccinLatte, .tokyoNight, .oneDarkPro,
        .gruvboxDark, .gruvboxLight, .kanagawa, .rosePine, .ayuDark, .everforest,
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

    // MARK: Community presets

    static let catppuccinMocha = TerminalTheme(
        name: "Catppuccin Mocha",
        background: 0x1E1E2E, foreground: 0xCDD6F4,
        palette: [
            0x45475A, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xCBA6F7, 0x89DCEB, 0xBAC2DE,
            0x585B70, 0xF38BA8, 0xA6E3A1, 0xF9E2AF,
            0x89B4FA, 0xCBA6F7, 0x89DCEB, 0xA6ADC8,
        ],
        selectionBg: 0x313244, cursorColor: 0xF5E0DC
    )

    static let catppuccinLatte = TerminalTheme(
        name: "Catppuccin Latte",
        background: 0xEFF1F5, foreground: 0x4C4F69,
        palette: [
            0x5C5F77, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0xACB0BE,
            0x6C6F85, 0xD20F39, 0x40A02B, 0xDF8E1D,
            0x1E66F5, 0xEA76CB, 0x179299, 0xBCC0CC,
        ],
        selectionBg: 0xCCD0DA, cursorColor: 0xDC8A78
    )

    static let tokyoNight = TerminalTheme(
        name: "Tokyo Night",
        background: 0x1A1B26, foreground: 0xA9B1D6,
        palette: [
            0x32344A, 0xF7768E, 0x9ECE6A, 0xE0AF68,
            0x7AA2F7, 0xAD8EE6, 0x449DAB, 0x787C99,
            0x444B6A, 0xFF7A93, 0xB9F27C, 0xFF9E64,
            0x7DA6FF, 0xBB9AF7, 0x0DB9D7, 0xACB0D0,
        ],
        selectionBg: 0x283457, cursorColor: 0xC0CAF5
    )

    static let oneDarkPro = TerminalTheme(
        name: "One Dark Pro",
        background: 0x282C34, foreground: 0xABB2BF,
        palette: [
            0x282C34, 0xE06C75, 0x98C379, 0xE5C07B,
            0x61AFEF, 0xC678DD, 0x56B6C2, 0xABB2BF,
            0x5C6370, 0xE06C75, 0x98C379, 0xE5C07B,
            0x61AFEF, 0xC678DD, 0x56B6C2, 0xFFFFFF,
        ],
        selectionBg: 0x3E4451, cursorColor: 0x528BFF
    )

    static let gruvboxDark = TerminalTheme(
        name: "Gruvbox Dark",
        background: 0x282828, foreground: 0xEBDBB2,
        palette: [
            0x282828, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0xA89984,
            0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F,
            0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
        ],
        selectionBg: 0x504945, cursorColor: 0xFBF1C7
    )

    static let gruvboxLight = TerminalTheme(
        name: "Gruvbox Light",
        background: 0xFBF1C7, foreground: 0x3C3836,
        palette: [
            0xFBF1C7, 0xCC241D, 0x98971A, 0xD79921,
            0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
            0x928374, 0x9D0006, 0x79740E, 0xB57614,
            0x076678, 0x8F3F71, 0x427B58, 0x3C3836,
        ],
        selectionBg: 0xEBDBB2, cursorColor: 0x282828
    )

    static let kanagawa = TerminalTheme(
        name: "Kanagawa",
        background: 0x1F1F28, foreground: 0xDCD7BA,
        palette: [
            0x090618, 0xC34043, 0x76946A, 0xC0A36E,
            0x7E9CD8, 0x957FB8, 0x6A9589, 0xC8C093,
            0x727169, 0xE82424, 0x98BB6C, 0xE6C384,
            0x7FB4CA, 0x938AA9, 0x7AA89F, 0xDCD7BA,
        ],
        selectionBg: 0x2D4F67, cursorColor: 0xC8C093
    )

    static let rosePine = TerminalTheme(
        name: "Rosé Pine",
        background: 0x191724, foreground: 0xE0DEF4,
        palette: [
            0x26233A, 0xEB6F92, 0x31748F, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
            0x6E6A86, 0xEB6F92, 0x31748F, 0xF6C177,
            0x9CCFD8, 0xC4A7E7, 0xEBBCBA, 0xE0DEF4,
        ],
        selectionBg: 0x403D52, cursorColor: 0x524F67
    )

    static let ayuDark = TerminalTheme(
        name: "Ayu Dark",
        background: 0x0D1017, foreground: 0xBFBDB6,
        palette: [
            0x131721, 0xEA6C73, 0x91B362, 0xF9AF4F,
            0x53BDFA, 0xFAE994, 0x90E1C6, 0xC7C7C7,
            0x686868, 0xF07178, 0xC2D94C, 0xFFB454,
            0x59C2FF, 0xFFEE99, 0x95E6CB, 0xFFFFFF,
        ],
        selectionBg: 0x273747, cursorColor: 0xE6B450
    )

    static let everforest = TerminalTheme(
        name: "Everforest",
        background: 0x2D353B, foreground: 0xD3C6AA,
        palette: [
            0x475258, 0xE67E80, 0xA7C080, 0xDBBC7F,
            0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
            0x5C6A72, 0xE67E80, 0xA7C080, 0xDBBC7F,
            0x7FBBB3, 0xD699B6, 0x83C092, 0xD3C6AA,
        ],
        selectionBg: 0x415058, cursorColor: 0xD3C6AA
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

    /// Background color for non-current search match cells.
    /// Blends an amber hue into the theme background so it reads well on any theme.
    var searchMatchBg: UInt32 {
        isDark
            ? blendColor(background, 0xFBBF24, t: 0.45)
            : blendColor(background, 0xB45309, t: 0.40)
    }

    /// Background color for the currently selected search match cell.
    var searchCurrentMatchBg: UInt32 {
        isDark
            ? blendColor(background, 0xF97316, t: 0.70)
            : blendColor(background, 0x9A3412, t: 0.50)
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
