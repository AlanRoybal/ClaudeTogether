import SwiftUI

/// Top-of-canvas tab strip. Hosts can open and close tabs; peers can switch
/// the active tab via tap (host broadcasts the focus change so all viewers
/// stay in sync).
struct TabStripView: View {
    @ObservedObject var model: TerminalModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(model.tabs) { tab in
                TabStripButton(
                    title: tab.title,
                    isActive: tab.id == model.activeTabId,
                    canClose: model.sessionManager.role == .host,
                    onSelect: { model.focusTab(id: tab.id) },
                    onClose: { model.closeTab(id: tab.id) })
            }

            if model.sessionManager.role == .host {
                Button(action: { model.openNewTab() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("New tab (Cmd+T)")
                .accessibilityLabel("New tab")
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
}

private struct TabStripButton: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11,
                              weight: isActive ? .semibold : .regular,
                              design: .rounded))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? .primary : .secondary)
            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .opacity(0.75)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(minWidth: 70, maxWidth: 180, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isActive
                      ? Color.accentColor.opacity(0.22)
                      : Color.secondary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}
