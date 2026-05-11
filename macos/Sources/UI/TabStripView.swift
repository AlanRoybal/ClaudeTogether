import SwiftUI

struct TabStripView: View {
    @ObservedObject var model: TerminalModel

    private var theme: TerminalTheme { model.terminalTheme }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                TabStripButton(
                    title: tab.title,
                    isActive: tab.id == model.activeTabId,
                    canClose: model.sessionManager.role == .host,
                    theme: theme,
                    onSelect: { model.focusTab(id: tab.id) },
                    onClose: { model.closeTab(id: tab.id) })
            }

            if model.sessionManager.role == .host {
                Button(action: { model.openNewTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .foregroundColor(theme.swiftUIForeground.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("New tab (⌘T)")
                .accessibilityLabel("New tab")
            }

            Spacer(minLength: 0)

            if let tab = model.activeTabForView {
                if tab.splitPane == nil {
                    if model.sessionManager.role == .host {
                        Button(action: {
                            NotificationCenter.default.post(name: .ctPaneSplitH, object: nil)
                        }) {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 18, height: 18)
                                .foregroundColor(theme.swiftUIForeground.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Split pane horizontally (⌘D)")
                        .accessibilityLabel("Split pane horizontally")

                        Button(action: {
                            NotificationCenter.default.post(name: .ctPaneSplitV, object: nil)
                        }) {
                            Image(systemName: "rectangle.split.1x2")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 18, height: 18)
                                .foregroundColor(theme.swiftUIForeground.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .help("Split pane vertically (⌘⇧D)")
                        .accessibilityLabel("Split pane vertically")
                    }
                } else {
                    Button(action: {
                        NotificationCenter.default.post(name: .ctPaneNext, object: nil)
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .foregroundColor(theme.swiftUIForeground.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("Focus next pane (⌘⌥⇥)")
                    .accessibilityLabel("Focus next pane")

                    if model.sessionManager.role == .host {
                        Button(action: {
                            NotificationCenter.default.post(name: .ctPaneClose, object: nil)
                        }) {
                            Image(systemName: "rectangle.grid.1x2")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 18, height: 18)
                                .foregroundColor(theme.swiftUIForeground.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("Close split pane (⌘⇧P)")
                        .accessibilityLabel("Close split pane")
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.swiftUIBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.swiftUIForeground.opacity(0.12))
                .frame(height: 1)
        }
    }
}

private struct TabStripButton: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let theme: TerminalTheme
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onSelect) {
                Text(title)
                    .font(.system(size: 11,
                                  weight: isActive ? .semibold : .regular,
                                  design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(isActive
                                     ? theme.swiftUIForeground
                                     : theme.swiftUIForeground.opacity(0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(minWidth: 70, maxWidth: 180, alignment: .leading)
                    .background(tabBackground)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select tab \(title)")

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .foregroundColor(isActive
                                         ? theme.swiftUIForeground.opacity(0.8)
                                         : theme.swiftUIForeground.opacity(0.35))
                        .background(closeBackground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab \(title)")
                .help("Close \(title)")
            }
        }
    }

    private var tabBackground: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(theme.swiftUIForeground.opacity(isActive ? 0.18 : 0.06))
    }

    private var closeBackground: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(theme.swiftUIForeground.opacity(isActive ? 0.12 : 0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(theme.swiftUIForeground.opacity(0.06), lineWidth: 1))
    }
}
