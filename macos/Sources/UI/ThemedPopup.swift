import SwiftUI

/// Shared surface treatment for every in-window popup (banners, toasts, the
/// find bar, the autocomplete list, the participant legend). Keeping the
/// background / border / shadow in one place guarantees all popups share the
/// same shape and elevation, and all of it is driven by the active terminal
/// theme so the coloring follows whichever theme — built-in or custom — the
/// user has selected.
struct ThemedPopupSurface: ViewModifier {
    let theme: TerminalTheme
    var cornerRadius: CGFloat = 10
    var shadowRadius: CGFloat = 10

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(theme.popupSurface, in: shape)
            .overlay(shape.stroke(theme.popupBorder, lineWidth: 1))
            .shadow(color: theme.popupShadow, radius: shadowRadius, y: 3)
    }
}

extension View {
    /// Apply the standard themed popup surface (rounded background + hairline
    /// border + drop shadow) derived from `theme`.
    func themedPopupSurface(_ theme: TerminalTheme,
                            cornerRadius: CGFloat = 10,
                            shadowRadius: CGFloat = 10) -> some View {
        modifier(ThemedPopupSurface(theme: theme,
                                    cornerRadius: cornerRadius,
                                    shadowRadius: shadowRadius))
    }
}
