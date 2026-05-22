import SwiftUI

struct TabStripView: View {
    @ObservedObject var model: TerminalModel

    @State private var draggingTabId: UInt32? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var tabFrames: [UInt32: CGRect] = [:]
    @State private var previewOrder: [UInt32]? = nil

    private var theme: TerminalTheme { model.terminalTheme }

    private var displayedTabs: [TabState] {
        guard let order = previewOrder else { return model.tabs }
        return order.compactMap { id in model.tabs.first(where: { $0.id == id }) }
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(displayedTabs) { tab in
                TabStripButton(
                    title: tab.title,
                    isActive: tab.id == model.activeTabId,
                    canClose: model.sessionManager.role == .host,
                    isDragging: draggingTabId == tab.id,
                    theme: theme,
                    onSelect: { model.focusTab(id: tab.id) },
                    onClose: { model.closeTab(id: tab.id) })
                .background(frameCapture(for: tab.id))
                .offset(x: draggingTabId == tab.id ? dragOffset : 0)
                .zIndex(draggingTabId == tab.id ? 1 : 0)
                .gesture(model.sessionManager.role == .host ? dragGesture(for: tab) : nil)
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
        .coordinateSpace(name: "tabStrip")
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
    }

    private func frameCapture(for id: UInt32) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TabFrameKey.self,
                value: [id: geo.frame(in: .named("tabStrip"))]
            )
        }
    }

    private func dragGesture(for tab: TabState) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("tabStrip"))
            .onChanged { value in
                if draggingTabId == nil {
                    draggingTabId = tab.id
                    previewOrder = model.tabs.map(\.id)
                }
                guard draggingTabId == tab.id else { return }
                dragOffset = value.translation.width

                guard var order = previewOrder,
                      let fromIdx = order.firstIndex(of: tab.id),
                      let frame = tabFrames[tab.id] else { return }

                let draggedMidX = frame.midX + dragOffset

                for (otherIdx, otherId) in order.enumerated() where otherId != tab.id {
                    guard let otherFrame = tabFrames[otherId] else { continue }
                    if draggedMidX > otherFrame.minX && draggedMidX < otherFrame.maxX {
                        order.move(fromOffsets: IndexSet(integer: fromIdx),
                                   toOffset: otherIdx < fromIdx ? otherIdx : otherIdx + 1)
                        previewOrder = order
                        dragOffset = 0
                        break
                    }
                }
            }
            .onEnded { _ in
                if let order = previewOrder,
                   let finalIdx = order.firstIndex(of: tab.id),
                   let originalIdx = model.tabs.firstIndex(where: { $0.id == tab.id }) {
                    model.moveTab(fromIndex: originalIdx, toIndex: finalIdx)
                }
                draggingTabId = nil
                dragOffset = 0
                previewOrder = nil
            }
    }
}

private struct TabFrameKey: PreferenceKey {
    static var defaultValue: [UInt32: CGRect] = [:]
    static func reduce(value: inout [UInt32: CGRect], nextValue: () -> [UInt32: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

private struct TabStripButton: View {
    let title: String
    let isActive: Bool
    let canClose: Bool
    let isDragging: Bool
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
        .opacity(isDragging ? 0.75 : 1.0)
        .shadow(color: isDragging ? .black.opacity(0.25) : .clear, radius: 6, x: 0, y: 3)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
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
