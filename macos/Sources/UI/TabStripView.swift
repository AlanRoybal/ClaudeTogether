import SwiftUI

struct TabStripView: View {
    @ObservedObject var model: TerminalModel

    // Absolute X of the tab's slot when drag began; stays fixed throughout the drag.
    @State private var dragStartSlotX: CGFloat = 0
    // Absolute X of the tab's current slot after any live swaps; updated on each swap.
    @State private var dragCurrentSlotX: CGFloat = 0
    @State private var currentTranslation: CGFloat = 0
    @State private var previousTranslation: CGFloat = 0
    @State private var draggingTabId: UInt32? = nil
    @State private var tabFrames: [UInt32: CGRect] = [:]
    @State private var previewOrder: [UInt32]? = nil

    private var theme: TerminalTheme { model.terminalTheme }

    // Visual offset for the dragged tab: keeps the tab pinned under the cursor
    // regardless of how many slot-swaps have occurred.
    private func dragOffset(for tabId: UInt32) -> CGFloat {
        guard tabId == draggingTabId else { return 0 }
        return dragStartSlotX + currentTranslation - dragCurrentSlotX
    }

    private var displayedTabs: [TabState] {
        guard let order = previewOrder else { return model.tabs }
        return order.compactMap { id in model.tabs.first(where: { $0.id == id }) }
    }

    var body: some View {
        HStack(spacing: 4) {
            // Tabs expand to fill all available space equally.
            HStack(spacing: 4) {
                ForEach(Array(displayedTabs.enumerated()), id: \.element.id) { idx, tab in
                    TabStripButton(
                        title: tab.title,
                        index: idx,
                        isActive: tab.id == model.activeTabId,
                        canClose: model.sessionManager.role == .host,
                        isPinned: tab.isPinned,
                        isDragging: draggingTabId == tab.id,
                        hasUnreadOutput: tab.hasUnreadOutput,
                        theme: theme,
                        onSelect: { model.focusTab(id: tab.id) },
                        onClose: { model.closeTab(id: tab.id) },
                        onTogglePin: { model.togglePin(id: tab.id) })
                    .frame(maxWidth: .infinity)
                    .background(frameCapture(for: tab.id))
                    .offset(x: dragOffset(for: tab.id))
                    .zIndex(draggingTabId == tab.id ? 1 : 0)
                    .simultaneousGesture(dragGesture(for: tab))
                }
            }
            .frame(maxWidth: .infinity)

            // Fixed-width trailing controls.
            HStack(spacing: 4) {
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
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(theme.swiftUIBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.swiftUIForeground.opacity(0.12))
                .frame(height: 1)
        }
        .coordinateSpace(name: "tabStrip")
        .onPreferenceChange(TabFrameKey.self) { tabFrames = $0 }
    }

    private func isPinned(_ id: UInt32) -> Bool {
        model.tabs.first(where: { $0.id == id })?.isPinned ?? false
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
                guard model.sessionManager.role == .host else { return }

                if draggingTabId == nil {
                    guard let frame = tabFrames[tab.id] else { return }
                    draggingTabId = tab.id
                    previewOrder = model.tabs.map(\.id)
                    dragStartSlotX = frame.minX
                    dragCurrentSlotX = frame.minX
                }
                guard draggingTabId == tab.id else { return }

                let translation = value.translation.width
                let delta = translation - previousTranslation
                previousTranslation = translation
                currentTranslation = translation

                guard delta != 0 else { return }

                let tabWidth = tabFrames[tab.id]?.width ?? 100
                let visualLeftEdge = dragStartSlotX + currentTranslation
                let visualRightEdge = visualLeftEdge + tabWidth

                if delta > 0 {
                    // Moving right: only check right neighbor to avoid stale-frame false triggers.
                    if let fromIdx = previewOrder?.firstIndex(of: tab.id),
                       let order = previewOrder,
                       fromIdx + 1 < order.count {
                        let rightId = order[fromIdx + 1]
                        // Don't let a tab cross the pin boundary.
                        if isPinned(rightId) != tab.isPinned { return }
                        if let rightFrame = tabFrames[rightId], visualRightEdge > rightFrame.midX {
                            var newOrder = order
                            newOrder.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: fromIdx + 2)
                            dragCurrentSlotX = rightFrame.minX
                            withAnimation(.easeInOut(duration: 0.18)) { previewOrder = newOrder }
                        }
                    }
                } else {
                    // Moving left: only check left neighbor.
                    if let fromIdx = previewOrder?.firstIndex(of: tab.id),
                       let order = previewOrder,
                       fromIdx > 0 {
                        let leftId = order[fromIdx - 1]
                        // Don't let a tab cross the pin boundary.
                        if isPinned(leftId) != tab.isPinned { return }
                        if let leftFrame = tabFrames[leftId], visualLeftEdge < leftFrame.midX {
                            var newOrder = order
                            newOrder.move(fromOffsets: IndexSet(integer: fromIdx), toOffset: fromIdx - 1)
                            dragCurrentSlotX = leftFrame.minX
                            withAnimation(.easeInOut(duration: 0.18)) { previewOrder = newOrder }
                        }
                    }
                }
            }
            .onEnded { _ in
                guard model.sessionManager.role == .host else { return }
                if let order = previewOrder,
                   let finalIdx = order.firstIndex(of: tab.id),
                   let originalIdx = model.tabs.firstIndex(where: { $0.id == tab.id }) {
                    model.moveTab(fromIndex: originalIdx, toIndex: finalIdx)
                }
                draggingTabId = nil
                dragStartSlotX = 0
                dragCurrentSlotX = 0
                currentTranslation = 0
                previousTranslation = 0
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

/// Three dots that fade in sequence to signal background activity on a tab.
/// The view occupies a fixed width so toggling visibility on the parent does
/// not shift the tab title's layout.
private struct AnimatedEllipsisView: View {
    let color: Color

    private let dotSize: CGFloat = 2.5
    private let spacing: CGFloat = 2
    private let cycle: TimeInterval = 1.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: cycle) / cycle
            HStack(spacing: spacing) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(color)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(opacity(at: t, index: i))
                }
            }
        }
        .frame(width: dotSize * 3 + spacing * 2, alignment: .leading)
        .accessibilityHidden(true)
    }

    /// Each dot peaks 1/3 of a cycle apart, easeInOut between 0.2 and 1.0.
    private func opacity(at t: Double, index: Int) -> Double {
        let phase = (t - Double(index) / 3.0).truncatingRemainder(dividingBy: 1.0)
        let wrapped = phase < 0 ? phase + 1.0 : phase
        // Triangle wave 0..1..0, then ease.
        let tri = wrapped < 0.5 ? wrapped * 2.0 : (1.0 - wrapped) * 2.0
        let eased = tri * tri * (3.0 - 2.0 * tri)
        return 0.2 + 0.8 * eased
    }
}

private struct TabStripButton: View {
    let title: String
    let index: Int
    let isActive: Bool
    let canClose: Bool
    let isPinned: Bool
    let isDragging: Bool
    let hasUnreadOutput: Bool
    let theme: TerminalTheme
    let onSelect: () -> Void
    let onClose: () -> Void
    let onTogglePin: () -> Void

    @State private var isHovered = false
    @State private var isXHovered = false

    private var showsActivityIndicator: Bool { hasUnreadOutput && !isActive }

    var body: some View {
        HStack(spacing: 0) {
            // Leading control — always reserves space to prevent layout shifts.
            // A pinned tab shows a pin glyph (no close button); clicking it
            // unpins. An unpinned tab shows the close button (host only).
            if canClose {
                if isPinned {
                    Button(action: onTogglePin) {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(theme.swiftUIForeground.opacity(isXHovered ? 0.85 : 0.5))
                            .frame(width: 14, height: 14)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(theme.swiftUIForeground.opacity(isXHovered ? 0.15 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isXHovered = $0 }
                    .accessibilityLabel("Unpin tab \(title)")
                    .help("Unpin \(title)")
                    .padding(.leading, 6)
                } else {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(theme.swiftUIForeground.opacity(isXHovered ? 0.85 : 0.3))
                            .frame(width: 14, height: 14)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(theme.swiftUIForeground.opacity(isXHovered ? 0.15 : 0))
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { isXHovered = $0 }
                    .accessibilityLabel("Close tab \(title)")
                    .help("Close \(title)")
                    .padding(.leading, 6)
                }
            }

            // Title — fills remaining space, tap selects the tab.
            Button(action: onSelect) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 11, weight: isActive ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(isActive
                                         ? theme.swiftUIForeground
                                         : theme.swiftUIForeground.opacity(0.38))
                        .layoutPriority(1)
                    if showsActivityIndicator {
                        AnimatedEllipsisView(color: theme.swiftUIForeground.opacity(0.55))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsActivityIndicator
                                ? "Select tab \(title), new activity"
                                : "Select tab \(title)")

            // ⌘N shortcut hint.
            if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 9, weight: .regular))
                    .foregroundColor(theme.swiftUIForeground.opacity(isActive ? 0.3 : 0.18))
                    .padding(.trailing, 7)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(theme.swiftUIForeground.opacity(isActive ? 0.13 : 0.04))
        )
        .onHover { isHovered = $0 }
        .opacity(isDragging ? 0.7 : 1.0)
        .shadow(color: isDragging ? .black.opacity(0.2) : .clear, radius: 5, x: 0, y: 2)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
        .contextMenu {
            // Tab actions are host-only, mirroring the close/new affordances.
            if canClose {
                Button(isPinned ? "Unpin Tab" : "Pin Tab", action: onTogglePin)
                if !isPinned {
                    Button("Close Tab", action: onClose)
                }
            }
        }
    }
}
