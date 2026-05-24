import SwiftUI
import Combine
import Darwin
import CollabTermC

/// NSTextField subclass that routes Cmd+V/C/X/A through the responder chain
/// so standard edit shortcuts work inside NSAlert accessory views.
private class EditableTextField: NSTextField {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
        else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "v": return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case "c": return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case "x": return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case "a": return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        default:  return super.performKeyEquivalent(with: event)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: TerminalModel
    // Explicit title bar inset: SwiftUI doesn't observe our imperative
    // titlebarAppearsTransparent call, so we bypass safe-area and manage
    // the inset ourselves. WindowThemeNSView writes the real value here.
    @State private var titleBarInset: CGFloat = 28

    var body: some View {
        ZStack(alignment: .top) {
            if let controller = model.activeEditor {
                EditorHost(
                    controller: controller,
                    mouseModeEnabled: model.mouseMode,
                    theme: model.terminalTheme)
                    .frame(minWidth: 500, minHeight: 300)
                    .padding(.top, titleBarInset)
            } else if !model.tabs.isEmpty {
                VStack(spacing: 0) {
                    TabStripView(model: model)
                    if let tab = model.activeTabForView {
                        SplitPaneView(tab: tab, model: model, searchState: model.searchState)
                            .frame(minWidth: 500, minHeight: 300)
                    }
                }
                .padding(.top, titleBarInset)
            } else {
                // Tabs are empty — auto-open the initial terminal. This
                // state is only visible briefly on first launch or after a
                // peer session ends while the tab is being created.
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onAppear { model.openInitialTab() }
            }

            if model.isViewOnlyPeer {
                HStack {
                    Spacer()
                    Text("View Only")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.trailing, 12)
                }
                .padding(.top, titleBarInset + 8)
            }

        }
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 800, minHeight: 550)
        .background(WindowThemeSetter(theme: model.terminalTheme, titleBarInset: $titleBarInset))
    }
}

/// Applies theme colors to the NSWindow (background + title bar) whenever
/// the theme changes. Uses a custom NSView subclass so `viewDidMoveToWindow`
/// fires reliably — the plain-`NSView` + `DispatchQueue.main.async` approach
/// is fragile because the view may not yet be in a window when the block runs.
private struct WindowThemeSetter: NSViewRepresentable {
    let theme: TerminalTheme
    @Binding var titleBarInset: CGFloat

    func makeNSView(context: Context) -> WindowThemeNSView {
        WindowThemeNSView(theme: theme, titleBarInset: $titleBarInset)
    }

    func updateNSView(_ nsView: WindowThemeNSView, context: Context) {
        nsView.theme = theme
        nsView.titleBarInset = $titleBarInset
    }
}

private final class WindowThemeNSView: NSView {
    var theme: TerminalTheme {
        didSet { applyToWindow() }
    }
    var titleBarInset: Binding<CGFloat>

    private var windowObservers: [NSObjectProtocol] = []

    init(theme: TerminalTheme, titleBarInset: Binding<CGFloat>) {
        self.theme = theme
        self.titleBarInset = titleBarInset
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        guard let window else { return }
        applyToWindow()
        // Belt-and-suspenders: re-apply after the run loop so any SwiftUI
        // post-setup window changes are overridden by our theme.
        DispatchQueue.main.async { [weak self] in self?.applyToWindow() }
        let reapply: (Notification) -> Void = { [weak self] _ in self?.applyToWindow() }
        windowObservers = [
            // Reapply after deminiaturize: macOS rebuilds the titlebar layer.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didDeminiaturizeNotification,
                object: window, queue: .main, using: reapply),
            // Reapply (and restore inset) when returning from full screen.
            NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: window, queue: .main, using: reapply),
            // Zero the inset when entering full screen (no title bar).
            NotificationCenter.default.addObserver(
                forName: NSWindow.didEnterFullScreenNotification,
                object: window, queue: .main) { [weak self] _ in
                    self?.titleBarInset.wrappedValue = 0
                },
        ]
    }

    private func applyToWindow() {
        guard let window else { return }
        let color = theme.nsBackground
        window.titlebarAppearsTransparent = true
        window.backgroundColor = color
        window.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)

        // Walk up from the close button by class name until we reach
        // NSTitlebarContainerView. Fixed-depth .superview chains break when
        // Apple changes the view hierarchy between macOS releases.
        if let closeButton = window.standardWindowButton(.closeButton) {
            var candidate: NSView? = closeButton.superview
            while let v = candidate {
                if String(describing: type(of: v)).contains("TitlebarContainer") {
                    v.wantsLayer = true
                    v.layer?.backgroundColor = color.cgColor
                    break
                }
                candidate = v.superview
            }
        }

        // Compute actual title bar height: contentLayoutRect is the usable area
        // below chrome; the difference from the window frame height is the inset.
        let raw = window.frame.height - window.contentLayoutRect.height
        // Sanity-clamp: ignore absurd values (e.g. window not yet sized).
        let inset = (raw > 0 && raw < 100) ? raw : 28
        if titleBarInset.wrappedValue != inset {
            titleBarInset.wrappedValue = inset
        }
    }
}

/// A secondary terminal pane created by splitting the primary pane of a tab.
struct SplitPaneState: Identifiable {
    /// Unique pane identifier used in wire frames.
    let id: UInt32
    /// Host: the PTY backing this pane. Peer: nil (display-only mirror).
    var pty: PTYSession?
    /// Render target for this pane. Independent from the primary pane grid.
    var grid: GridModel
}

/// One tab in a session. Each tab owns its own grid; on the host each tab
/// also owns a PTY shell (peer tabs are display-only and have nil pty).
struct TabState: Identifiable {
    let id: UInt32
    var title: String
    /// Host: the PTY backing this tab. Peer: nil (display-only mirror).
    let pty: PTYSession?
    /// Render target for this tab. The active tab's grid is the one that
    /// `MetalTerminalView` is currently rendering.
    let grid: GridModel
    /// Non-nil when this tab has been split into two panes.
    var splitPane: SplitPaneState? = nil
    /// Whether the split is side-by-side or stacked.
    var splitAxis: SplitAxis = .horizontal
    /// 0 = primary pane, 1 = split pane. Determines where keystrokes go.
    var activePaneIndex: Int = 0
    /// True when output has arrived on this tab while it was in the
    /// background for this participant. Cleared on focus.
    var hasUnreadOutput: Bool = false

    /// True if the underlying tool has put the PTY in raw mode — either via
    /// the alt-screen DECSET (vim, htop) or via termios ICANON-off (claude,
    /// codex). Peer-side tabs have no PTY and report based on alt-screen only.
    var isRawMode: Bool {
        if grid.isUsingAlternateScreen { return true }
        return pty?.isRaw ?? false
    }
}

extension Notification.Name {
    static let ctTabsNew = Notification.Name("ct.tabs.new")
    static let ctTabsClose = Notification.Name("ct.tabs.close")
    static let ctTabsNext = Notification.Name("ct.tabs.next")
    static let ctTabsPrevious = Notification.Name("ct.tabs.previous")
    static let ctPaneSplitH = Notification.Name("ct.pane.splitH")
    static let ctPaneSplitV = Notification.Name("ct.pane.splitV")
    static let ctPaneClose = Notification.Name("ct.pane.close")
    static let ctPaneNext = Notification.Name("ct.pane.next")
}

@MainActor
final class TerminalModel: ObservableObject {
    /// All open tabs. On the host, each tab owns a PTY; on peers they're
    /// display-only mirrors fed by inbound TabPtyOutput frames.
    @Published var tabs: [TabState] = []
    /// Which tab is currently focused (the one MetalTerminalView renders).
    @Published var activeTabId: UInt32?

    @Published var rootPath: String?
    @Published var boreBundlePath: String?  // kept for sidebar diagnostics display
    /// Non-nil when a supported tunnel tool (ngrok or bore) is available.
    var tunnelTool: (path: String, server: String)?
    @Published var coreVersion: Int32 = 0
    @Published var activeEditor: EditorController?
    /// User-visible "Mouse mode" toggle. When false, MetalTerminalView drops
    /// mouse events on the floor (no SGR encoding, no PTY traffic, no editor
    /// or shared-input cursor moves) until the user opts in.
    @Published var mouseMode: Bool = false

    /// Persisted command history feeding the shared-input autocomplete.
    /// Captured from `inputCommit` whenever a line dispatches to the PTY.
    let commandHistory = CommandHistory()

    /// Autocomplete state for the shared input line. Updated as the
    /// shared input mutates; consumed by ContentView's overlay.
    let inputAutocomplete = AutocompleteState()

    /// Find-bar state shared across the window. Searched against the
    /// active pane's grid; highlights rendered by the Metal BG pass.
    let searchState = SearchState()

    /// CWD used for the currently-visible filesystem completion hints.
    /// Non-nil iff filesystem hints are showing; nil otherwise.
    private var filesystemCompletionCwd: String?

    /// Terminal text point size. Driven by the View menu (⌘+/⌘-/⌘0).
    /// `MetalTerminalView` observes this and rebuilds the GlyphAtlas when
    /// it changes. Persisted to UserDefaults under `ClaudeTogether.fontSize`.
    @Published var fontSize: CGFloat = TerminalModel.defaultFontSize {
        didSet {
            guard fontSize != oldValue else { return }
            UserDefaults.standard.set(Double(fontSize),
                                      forKey: TerminalModel.fontSizeDefaultsKey)
        }
    }

    static let defaultFontSize: CGFloat = 13
    static let minimumFontSize: CGFloat = 8
    static let maximumFontSize: CGFloat = 48
    static let fontSizeStep: CGFloat = 1

    fileprivate static let fontSizeDefaultsKey = "CoTTY.fontSize"
    fileprivate static let themeDefaultsKey = "CoTTY.terminalTheme"
    fileprivate static let customThemeBgKey = "CoTTY.customThemeBg"
    fileprivate static let customThemeFgKey = "CoTTY.customThemeFg"
    fileprivate static let ligaturesEnabledKey = "CoTTY.ligaturesEnabled"
    fileprivate static let fontNameKey = "CoTTY.fontName"
    /// PostScript name of the preferred font. Falls back to system monospace if
    /// the named font is not installed.
    static let defaultFontName = "FiraCode-Regular"

    /// User-installed themes loaded from ~/.config/claudetogether/themes/.
    let themeLibrary = ThemeLibrary()

    /// Config file reader/watcher for ~/.config/CoTTY/config.toml.
    let configFile = ConfigFile()

    /// All available themes: built-ins first, then user-installed.
    var allThemes: [TerminalTheme] { TerminalTheme.allBuiltin + themeLibrary.themes }

    @Published var terminalTheme: TerminalTheme = .defaultDark {
        didSet {
            guard terminalTheme != oldValue else { return }
            UserDefaults.standard.set(terminalTheme.name, forKey: TerminalModel.themeDefaultsKey)
        }
    }

    // Hex color values backing the "Custom" theme. Changing either one while
    // Custom is active rebuilds and re-applies the theme immediately.
    @Published var customThemeBg: UInt32 = 0x1E1E2E {
        didSet {
            UserDefaults.standard.set(customThemeBg, forKey: TerminalModel.customThemeBgKey)
            if terminalTheme.name == "Custom" {
                terminalTheme = TerminalTheme.custom(background: customThemeBg, foreground: customThemeFg)
            }
        }
    }
    @Published var customThemeFg: UInt32 = 0xCDD6F4 {
        didSet {
            UserDefaults.standard.set(customThemeFg, forKey: TerminalModel.customThemeFgKey)
            if terminalTheme.name == "Custom" {
                terminalTheme = TerminalTheme.custom(background: customThemeBg, foreground: customThemeFg)
            }
        }
    }

    @Published var fontName: String = TerminalModel.defaultFontName {
        didSet {
            guard fontName != oldValue else { return }
            UserDefaults.standard.set(fontName, forKey: TerminalModel.fontNameKey)
        }
    }

    @Published var ligaturesEnabled: Bool = true {
        didSet {
            guard ligaturesEnabled != oldValue else { return }
            UserDefaults.standard.set(ligaturesEnabled, forKey: TerminalModel.ligaturesEnabledKey)
        }
    }

    let sessionManager = SessionManager()

    /// Brief auto-dismissing status message shown as an overlay banner.
    @Published var sessionNotificationMessage: String? = nil
    private var notificationDismissTask: Task<Void, Never>?

    /// A placeholder token currently live in the terminal input line.
    /// Carries the actual bytes so it can be expanded on demand or on Enter.
    private struct ActivePlaceholder {
        let text: String      // literal text sent to the terminal (e.g. "[Pasted text #1 + 5 lines]")
        let bytes: [UInt8]    // real bytes to substitute when expanding
        var cursorAfter: Bool // true = terminal cursor is positioned after the placeholder
    }
    private var activePlaceholder: ActivePlaceholder? = nil
    private var pasteCounter: Int = 0
    private var imageDropCounter: Int = 0

    /// Snapshot of participants from the previous roster update, used to
    /// detect joins and leaves without a dedicated diff frame.
    private var previousParticipants: [SessionManager.Participant] = []

    /// Guards the one-time "view only" hint so it doesn't spam on every blocked key.
    private var hasShownViewOnlyHint = false

    /// Compatibility shim: returns the active tab's grid. Kept so existing
    /// call sites that read `model.grid` (renderer, sidebar, snapshot helpers)
    /// continue to work after the multi-tab refactor.
    var grid: GridModel? { tabs.first(where: { $0.id == activeTabId })?.grid }
    /// Returns the grid for the currently focused pane (primary or split).
    var activeGrid: GridModel? {
        guard let tab = tabs.first(where: { $0.id == activeTabId }) else { return nil }
        return tab.activePaneIndex == 1 ? tab.splitPane?.grid : tab.grid
    }
    /// Compatibility shim: returns the active tab's PTY (nil for peer tabs).
    var pty: PTYSession? { tabs.first(where: { $0.id == activeTabId })?.pty }

    private var activeTab: TabState? {
        tabs.first(where: { $0.id == activeTabId })
    }
    var activeTabForView: TabState? { activeTab }
    private var nextTabId: UInt32 = 1
    /// Pane IDs start above the tab-ID range so they never collide on the wire.
    private var nextPaneId: UInt32 = 10_000
    /// Tracks which pane ID each participant is currently focused in, for
    /// routing paneCursorPos updates to the correct GridModel.
    private var participantFocusedPane: [UserIdentity: UInt32] = [:]
    /// paneId → the grid that owns it (split pane grids only; primary pane
    /// grids are looked up via the TabState they belong to).
    private var splitPaneGrids: [UInt32: GridModel] = [:]

    /// Keep the tab strip visible from the first tab onward so adding the
    /// second tab does not shrink the terminal viewport and drop visible
    /// history lines out of the grid.
    var shouldShowTabStrip: Bool { !tabs.isEmpty }

    /// Host only: edge-detector for creator-only mode. We currently treat the
    /// terminal alternate screen as the signal for "a full-screen app owns the
    /// terminal", which avoids misclassifying normal shell prompts.
    private var lastLocalCreatorOnlyMode: Bool = false
    private var modeTimer: Timer?
    private var titleTimer: Timer?
    private var sharedInputs: [UInt32: SharedInputState] = [:]
    private var sharedInputPromptTimers: [UInt32: Timer] = [:]
    private var sharedInputTransientOutputTimers: [UInt32: Timer] = [:]
    /// Tabs whose shared input was activated with pre-existing text (typed
    /// before sharing started, or recalled via ↑ history). The commit handler
    /// prepends Ctrl+U to clear the shell's readline buffer before sending
    /// the committed line, since the shell already holds that text.
    private var sharedInputNeedsLineClear = Set<UInt32>()
    /// Per-tab idle timer that clears the activity indicator after a short
    /// period without typing. Rescheduled on each typing event.
    private var unreadIdleTimers: [UInt32: Timer] = [:]
    private let unreadIdleInterval: TimeInterval = 1.5
    private var participantFocusedTab: [UserIdentity: UInt32] = [:]
    private var editorSavedRevisions: [UInt64: UInt32] = [:]
    private var fileSyncWatcher: FSSyncWatcher?
    private var fileSyncTimer: Timer?
    /// Host-only: newly opened shared tabs request one full snapshot after
    /// their first live PTY output chunk so peers see the initial prompt even
    /// if tab-open/focus beats the shell's first paint.
    private var pendingHostTabInitialSnapshots = Set<UInt32>()
    /// Tabs whose PTY was just respawned (e.g. when a session begins and the
    /// shell needs to move into the chosen root). Their next shared-input
    /// activation must NOT extract existing row text as initialText — the
    /// shell is guaranteed fresh, so any cells before the cursor are the
    /// prompt itself, not user-typed input.
    private var freshlyRespawnedTabs = Set<UInt32>()
    /// Peer-only: TabPtyOutput can arrive before TabOpen during join-time
    /// catch-up, so buffer it until the mirrored tab exists locally.
    private var pendingPeerTabOutput: [UInt32: [Data]] = [:]
    /// Peer-only: same idea for focus announcements during join-time catch-up.
    private var pendingPeerFocusedTabId: UInt32?
    /// Last terminal viewport measured by the renderer. Reused when a new tab
    /// is created before SwiftUI has had a chance to lay out its Metal view.
    private var lastKnownTerminalGridSize: (cols: UInt16, rows: UInt16)?
    /// Host-only: first tab PTYs are started after the Metal view reports its
    /// real size so zsh does not render prompts during startup resizes.
    private var pendingHostTabStartCwds: [UInt32: String] = [:]
    private var pendingHostTabStartWorkItems: [UInt32: DispatchWorkItem] = [:]
    private let fileSyncApplier = FSSyncApplier()

    init() {
        coreVersion = ct_version()
        tunnelTool = Self.findTunnelTool()
        // Keep boreBundlePath populated for the diagnostics panel
        boreBundlePath = tunnelTool.map { $0.path }
        NSLog("[ct] TerminalModel init tunnelTool=%@ server=%@",
              tunnelTool?.path ?? "<nil>", tunnelTool?.server ?? "(ngrok)")

        // Restore persisted UI prefs without firing the didSet writers.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: TerminalModel.fontSizeDefaultsKey) != nil {
            let raw = CGFloat(defaults.double(forKey: TerminalModel.fontSizeDefaultsKey))
            fontSize = TerminalModel.clampFontSize(raw)
        }
        if let rawBg = defaults.object(forKey: TerminalModel.customThemeBgKey) as? UInt32 {
            customThemeBg = rawBg
        }
        if let rawFg = defaults.object(forKey: TerminalModel.customThemeFgKey) as? UInt32 {
            customThemeFg = rawFg
        }
        // Load user-installed themes before resolving saved theme name so
        // imported presets survive restarts.
        themeLibrary.load()
        if let name = defaults.string(forKey: TerminalModel.themeDefaultsKey) {
            if name == "Custom" {
                terminalTheme = TerminalTheme.custom(background: customThemeBg, foreground: customThemeFg)
            } else {
                terminalTheme = allThemes.first { $0.name == name } ?? .defaultDark
            }
        }
        if let savedFont = defaults.string(forKey: TerminalModel.fontNameKey) {
            fontName = savedFont
        }
        // ligaturesEnabled defaults to true; only override if the user has
        // explicitly saved a false value.
        if defaults.object(forKey: TerminalModel.ligaturesEnabledKey) != nil {
            ligaturesEnabled = defaults.bool(forKey: TerminalModel.ligaturesEnabledKey)
        }
        // Apply config file overrides after the UserDefaults baseline is set.
        // themeLibrary.load() has already run above, so allThemes is populated.
        configFile.load()
        applyConfig(configFile.current)
        // Re-publish child ObservableObject changes.
        sessionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        sessionManager.$participants.sink { [weak self] newParticipants in
            guard let self = self else { return }
            self.syncSharedInputParticipants(
                broadcast: self.sessionManager.role == .host)
            self.syncAllGridSharedInputOverlays()
            self.syncEditorParticipants()
            for p in newParticipants
                where !self.previousParticipants.contains(where: { $0.identity == p.identity })
                   && p.identity != self.sessionManager.localIdentity {
                self.showSessionNotification("\(p.name) joined")
            }
            for p in self.previousParticipants
                where !newParticipants.contains(where: { $0.identity == p.identity })
                   && p.identity != self.sessionManager.localIdentity {
                self.showSessionNotification("\(p.name) left")
            }
            self.previousParticipants = newParticipants
            // Mode probe is gated on hosting + having a remote peer; the
            // first peer's Hello starts it, the last peer's leave stops it.
            self.startModeProbe()
        }.store(in: &cancellables)
        sessionManager.$accessMode.sink { [weak self] _ in
            self?.syncEditorReadOnlyState()
            self?.hasShownViewOnlyHint = false
        }.store(in: &cancellables)
        sessionManager.$publicURL
            .compactMap { $0.flatMap(URL.init) }
            .removeDuplicates()
            .sink { [weak self] url in
                self?.showShareSheet(for: url)
            }.store(in: &cancellables)
        configFile.$current
            .dropFirst()
            .sink { [weak self] newValues in self?.applyConfig(newValues) }
            .store(in: &cancellables)

        // Route inbound frames.
        sessionManager.onFrame = { [weak self] frame, peerID in
            self?.handleInbound(frame, from: peerID)
        }

        // DIAG: auto-share on launch when CT_AUTOSHARE=1 so we can test
        // bore/URL without requiring a UI click.
        NotificationCenter.default.addObserver(
            forName: .init("ct.diag.autoshare"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                NSLog("[ct] DIAG autoshare fired")
                self?.startSharing()
            }
        }

        // Menubar / keyboard-shortcut hooks for tabs (see App.swift commands).
        NotificationCenter.default.addObserver(
            forName: .ctTabsNew, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openNewTab() }
        }
        NotificationCenter.default.addObserver(
            forName: .ctTabsClose, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeActiveTab() }
        }
        NotificationCenter.default.addObserver(
            forName: .ctTabsNext, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.nextTab() }
        }
        NotificationCenter.default.addObserver(
            forName: .ctTabsPrevious, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.previousTab() }
        }
        NotificationCenter.default.addObserver(
            forName: .ctPaneSplitH, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.splitActivePane(axis: .horizontal) }
        }
        NotificationCenter.default.addObserver(
            forName: .ctPaneSplitV, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.splitActivePane(axis: .vertical) }
        }
        NotificationCenter.default.addObserver(
            forName: .ctPaneClose, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeSplitPane() }
        }
        NotificationCenter.default.addObserver(
            forName: .ctPaneNext, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.focusNextPane() }
        }
    }

    private var cancellables = Set<AnyCancellable>()

    deinit {
        modeTimer?.invalidate()
        titleTimer?.invalidate()
        for timer in sharedInputPromptTimers.values {
            timer.invalidate()
        }
        for timer in sharedInputTransientOutputTimers.values {
            timer.invalidate()
        }
        fileSyncTimer?.invalidate()
    }

    /// Returns (toolPath, server) for the best available tunnel tool.
    /// ngrok (user-installed) is preferred; bundled bore is the fallback.
    /// Returns nil if neither is available.
    static func findTunnelTool() -> (path: String, server: String)? {
        let fm = FileManager.default
        // Prefer ngrok: search PATH and common Homebrew locations
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        let ngrokCandidates = pathDirs.map { "\($0)/ngrok" }
            + ["/usr/local/bin/ngrok", "/opt/homebrew/bin/ngrok", "/usr/bin/ngrok"]
        if let ngrok = ngrokCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return (path: ngrok, server: "")  // empty server → ngrok mode
        }
        // Fall back to bundled bore binary
        let boreCandidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bore").path,
            Bundle.main.url(forResource: "bore", withExtension: nil)?.path,
        ].compactMap { $0 }
        if let bore = boreCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return (path: bore, server: SessionManager.defaultBoreServer)
        }
        return nil
    }

    // MARK: - Config file

    private func applyConfig(_ c: ConfigValues) {
        if let v = c.fontSize { fontSize = Self.clampFontSize(CGFloat(v)) }
        if let v = c.fontName { fontName = v }
        if let v = c.ligaturesEnabled { ligaturesEnabled = v }
        // Apply custom colors before resolving the theme name so that
        // TerminalTheme.custom(…) picks them up when theme = "Custom".
        if let v = c.customBg { customThemeBg = v }
        if let v = c.customFg { customThemeFg = v }
        if let name = c.theme {
            if name == "Custom" {
                terminalTheme = TerminalTheme.custom(background: customThemeBg,
                                                     foreground: customThemeFg)
            } else {
                terminalTheme = allThemes.first { $0.name == name } ?? terminalTheme
            }
        }
        if let v = c.displayName { sessionManager.localName = v }
        if let v = c.boreServer { sessionManager.boreServer = v }
    }

    // MARK: derived UI state

    /// True when a peer should see the creator-only banner.
    var showRawBanner: Bool {
        sessionManager.role == .peer &&
        sessionManager.state == .running &&
        sessionManager.remoteMode == .raw
    }

    /// True when the host has put the session into view-only mode and we
    /// are observing as a peer.
    var isViewOnlyPeer: Bool {
        sessionManager.role == .peer &&
        sessionManager.state == .running &&
        sessionManager.accessMode == .viewOnly
    }

    /// False when the terminal view should drop keystrokes. View-only
    /// peers are always blocked. In raw (TUI) mode peers stay enabled
    /// so their keystrokes ride the existing inputOp→pty.send passthrough
    /// fallback into the host's PTY — see the host-side handler in
    /// `handleFrame(.inputOp)` where a payload that isn't a SharedInputCodec
    /// packet is forwarded to the active tab's PTY.
    var inputEnabled: Bool { !isViewOnlyPeer }

    // MARK: host session

    /// Open a terminal at the home directory without requiring a project folder.
    /// Called automatically on launch and whenever the tab list becomes empty.
    func openInitialTab() {
        guard sessionManager.role == .host, tabs.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let tabId = nextTabId
        nextTabId &+= 1
        let title = TabTitleResolver.initialTitle(cwd: home, sessionRootPath: nil)
        let shouldDefer = lastKnownTerminalGridSize == nil
        guard let tab = makeHostTab(id: tabId, title: title, cwd: home,
                                    spawnImmediately: !shouldDefer)
        else { return }
        tabs.append(tab)
        if shouldDefer { pendingHostTabStartCwds[tabId] = home }
        activeTabId = tabId
        recordLocalTabFocus(tabId, broadcast: false)
        startTitlePolling()
        startModeProbe()
        syncAllGridSharedInputOverlays()
    }

    /// Let the host choose a project root folder for file sync. Does not open
    /// a new terminal tab. Required before starting a shared session.
    func pickProjectFolder() {
        guard let folder = FolderPicker.pick() else { return }
        rootPath = folder
        fileSyncWatcher = nil
        fileSyncApplier.configure(rootPath: nil)
        // If a shared session is already running, re-activate the jail at the
        // new root so subsequent shells inherit the updated CT_SESSION_ROOT.
        if sessionManager.state == .running {
            SessionRootJail.activate(rootPath: folder)
        }
        // Reset every host PTY into the new root so the terminal reflects the
        // user's explicit folder change.
        respawnAllPtys(at: folder)
    }

    private func respawnAllPtys(at rootPath: String) {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let notice = "[CoTTY] root folder changed — restarting shell at \(root)"
        for tab in tabs {
            if let pty = tab.pty, pty.pid > 0 {
                respawnPty(pty: pty, grid: tab.grid, root: root, notice: notice)
            }
            if let pane = tab.splitPane, let pty = pane.pty, pty.pid > 0 {
                respawnPty(pty: pty, grid: pane.grid, root: root, notice: notice)
            }
        }
    }

    /// Respawn a PTY at `root` with a fully reset grid. Feeds RIS (ESC c) so
    /// the new shell starts on a virgin screen with cursor at row 0 col 0,
    /// preventing ZLE from redrawing on top of the previous shell's prompt.
    private func respawnPty(pty: PTYSession, grid: GridModel, root: String,
                            notice: String)
    {
        let cols = grid.cols
        let rows = grid.rows
        // ESC c (RIS) — full terminal reset: clears screen + scrollback,
        // exits alt screen, resets attributes, homes cursor.
        let payload = Array("\u{1B}c\(notice)\r\n".utf8)
        grid.feed(payload)
        pty.terminate()
        if !pty.spawn(cwd: root, cols: cols, rows: rows) {
            NSLog("respawnPty: spawn failed at %@", root)
        }
    }

    /// Kept for call-sites that still reference startSession by name.
    func startSession() { pickProjectFolder() }

    func endSession() {
        for tab in tabs {
            tab.pty?.terminate()
            tab.splitPane?.pty?.terminate()
        }
        tabs.removeAll()
        activeTabId = nil
        nextTabId = 1
        nextPaneId = 10_000
        splitPaneGrids.removeAll()
        participantFocusedPane.removeAll()
        participantFocusedTab.removeAll()
        sharedInputNeedsLineClear.removeAll()
        for timer in sharedInputTransientOutputTimers.values {
            timer.invalidate()
        }
        sharedInputTransientOutputTimers.removeAll()
        rootPath = nil
        activeEditor = nil
        editorSavedRevisions.removeAll()
        pendingHostTabInitialSnapshots.removeAll()
        pendingPeerTabOutput.removeAll()
        pendingPeerFocusedTabId = nil
        lastKnownTerminalGridSize = nil
        cancelPendingHostTabStarts()
        pendingHostTabStartCwds.removeAll()
        freshlyRespawnedTabs.removeAll()
        stopSharing()
        stopTitlePolling()
        stopModeProbe()
        stopFileSyncPolling()
        fileSyncApplier.configure(rootPath: nil)
        resetSharedInputState()
        // Reopen a terminal at home so the user is never left with a blank window.
        openInitialTab()
    }

    // MARK: tabs

    /// Host: spawn a new PTY, allocate a tab id, broadcast TabOpen + TabFocus,
    /// and switch to the new tab. Uses rootPath when set; falls back to home.
    func openNewTab() {
        guard sessionManager.role == .host else { return }
        let folder = rootPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        let tabId = nextTabId
        nextTabId &+= 1
        let title = TabTitleResolver.initialTitle(
            cwd: folder,
            sessionRootPath: rootPath)
        let shouldDeferSpawn = tabs.isEmpty && lastKnownTerminalGridSize == nil
        guard let tab = makeHostTab(
            id: tabId,
            title: title,
            cwd: folder,
            spawnImmediately: !shouldDeferSpawn)
        else {
            return
        }
        tabs.append(tab)
        // Mark the tab as a freshly spawned shell so the shared-input anchor
        // recomputation skips the "reuse prior anchor on the same row" path
        // (which, without this flag, would lock the anchor at col 0 — the
        // cursor position at the moment of tab creation, before the prompt
        // had rendered — and let participants edit the prompt characters
        // themselves). Cleared on first user input by
        // applyAuthoritativeSharedInputRequest.
        freshlyRespawnedTabs.insert(tabId)
        if shouldDeferSpawn {
            pendingHostTabStartCwds[tabId] = folder
        }
        activeTabId = tabId
        recordLocalTabFocus(tabId, broadcast: false)
        refreshTabTitle(forTabID: tabId)
        let currentTitle = tabs.first(where: { $0.id == tabId })?.title ?? title
        if sessionManager.state == .running {
            pendingHostTabInitialSnapshots.insert(tabId)
            sessionManager.sendTabOpen(tabId: tabId, title: currentTitle)
            sessionManager.sendTabFocus(tabId: tabId)
            broadcastSharedInputSnapshot(tabId: tabId)
        }
        syncGridSharedInputOverlay(tabId: tabId)
        probeLocalMode(force: true)
        if sessionManager.role == .host, sessionManager.state == .running,
           !lastLocalCreatorOnlyMode
        {
            activateSharedInputAtCurrentCursor(tabId: tabId, broadcast: true)
        }
    }

    /// Host: close a tab by id. Terminates the PTY, broadcasts TabClose, and
    /// if the closed tab was active, switches focus to a sibling. Closing the
    /// last tab is treated as ending the session.
    func closeTab(id: UInt32) {
        guard sessionManager.role == .host else { return }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[idx]
        tab.pty?.terminate()
        tabs.remove(at: idx)
        sharedInputs.removeValue(forKey: id)
        sharedInputPromptTimers.removeValue(forKey: id)?.invalidate()
        sharedInputTransientOutputTimers.removeValue(forKey: id)?.invalidate()
        unreadIdleTimers.removeValue(forKey: id)?.invalidate()
        participantFocusedTab = participantFocusedTab.filter { $0.value != id }
        pendingHostTabInitialSnapshots.remove(id)
        pendingHostTabStartCwds.removeValue(forKey: id)
        pendingHostTabStartWorkItems.removeValue(forKey: id)?.cancel()
        if sessionManager.state == .running {
            sessionManager.sendTabClose(tabId: id)
        }
        if activeTabId == id {
            if let next = tabs.first {
                focusTab(id: next.id)
            } else {
                activeTabId = nil
                // Last tab gone — tear down the rest of the session.
                endSession()
            }
        }
    }

    func closeActiveTab() {
        guard let id = activeTabId else { return }
        closeTab(id: id)
    }

    func moveTab(fromIndex: Int, toIndex: Int) {
        guard sessionManager.role == .host else { return }
        guard fromIndex != toIndex,
              tabs.indices.contains(fromIndex),
              tabs.indices.contains(toIndex) else { return }
        tabs.move(fromOffsets: IndexSet(integer: fromIndex),
                  toOffset: toIndex < fromIndex ? toIndex : toIndex + 1)
    }

    /// Update which tab this local user is focused on. Focus is local to
    /// each participant; peers are not forced to follow the host.
    /// Mark a background tab as having unread output, so the tab strip can
    /// surface an activity indicator. Each call also (re)schedules an idle
    /// timer that clears the indicator after a short pause in typing.
    func markTabUnread(id: UInt32) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if !tabs[idx].hasUnreadOutput {
            tabs[idx].hasUnreadOutput = true
        }
        unreadIdleTimers.removeValue(forKey: id)?.invalidate()
        unreadIdleTimers[id] = Timer.scheduledTimer(
            withTimeInterval: unreadIdleInterval,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearTabUnread(id: id)
            }
        }
    }

    private func clearTabUnread(id: UInt32) {
        unreadIdleTimers.removeValue(forKey: id)?.invalidate()
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs[idx].hasUnreadOutput {
            tabs[idx].hasUnreadOutput = false
        }
    }

    func focusTab(id: UInt32) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let previousId = activeTabId
        activeTabId = id
        clearTabUnread(id: id)
        recordLocalTabFocus(id, broadcast: sessionManager.state == .running)
        if sessionManager.role == .host, sessionManager.state == .running {
            sendTabSnapshot(tabId: id)
            if let previousId, previousId != id {
                syncSharedInputParticipants(tabId: previousId, broadcast: true)
            }
            syncSharedInputParticipants(tabId: id, broadcast: true)
        }
        if let previousId, previousId != id {
            syncGridSharedInputOverlay(tabId: previousId)
        }
        syncGridSharedInputOverlay(tabId: id)
        probeLocalMode(force: true)
        if sessionManager.role == .host, sessionManager.state == .running,
           !lastLocalCreatorOnlyMode
        {
            activateSharedInputAtCurrentCursor(tabId: id, broadcast: true)
        }
    }

    func nextTab() {
        guard !tabs.isEmpty else { return }
        guard let activeId = activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == activeId })
        else {
            focusTab(id: tabs[0].id)
            return
        }
        let next = tabs[(idx + 1) % tabs.count]
        focusTab(id: next.id)
    }

    func previousTab() {
        guard !tabs.isEmpty else { return }
        guard let activeId = activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == activeId })
        else {
            focusTab(id: tabs[0].id)
            return
        }
        let count = tabs.count
        let prev = tabs[(idx - 1 + count) % count]
        focusTab(id: prev.id)
    }

    // MARK: panes

    /// Split the active tab's primary pane along `axis`. On the host a new PTY
    /// is spawned; on peers the split is display-only until the host announces
    /// it via a `paneOpen` frame. Ignored if the tab is already split.
    /// Only the host can split. The split is broadcast to all peers so every
    /// participant shares the same two terminals side-by-side.
    func splitActivePane(axis: SplitAxis) {
        guard sessionManager.role == .host else { return }
        guard let activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == activeTabId }),
              tabs[idx].splitPane == nil
        else { return }

        let paneId = nextPaneId
        nextPaneId &+= 1
        let tabId  = activeTabId
        let spawnCols = max(tabs[idx].grid.cols / (axis == .horizontal ? 2 : 1), 20)
        let spawnRows = max(tabs[idx].grid.rows / (axis == .vertical   ? 2 : 1), 6)
        guard let grid = GridModel(cols: spawnCols, rows: spawnRows) else { return }

        let cwd = rootPath ?? FileManager.default.homeDirectoryForCurrentUser.path
        let p = PTYSession()
        p.onOutput = { [weak self] bytes in
            guard let self else { return }
            grid.feed(bytes)
            if self.sessionManager.state == .running {
                self.sessionManager.sendPanePtyOutput(paneId: paneId, data: Data(bytes))
            }
        }
        p.onExit = { grid.feed(Array("\r\n[process exited]\r\n".utf8)) }
        guard p.spawn(cwd: cwd, cols: spawnCols, rows: spawnRows) else { return }

        let pane = SplitPaneState(id: paneId, pty: p, grid: grid)
        splitPaneGrids[paneId] = grid
        tabs[idx].splitPane = pane
        tabs[idx].splitAxis = axis
        tabs[idx].activePaneIndex = 1

        if sessionManager.state == .running {
            sessionManager.sendPaneOpen(tabId: tabId, paneId: paneId, axis: axis)
        }
    }

    /// Host only: close the split pane and broadcast the teardown.
    func closeSplitPane() {
        guard sessionManager.role == .host else { return }
        guard let activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == activeTabId }),
              let pane = tabs[idx].splitPane
        else { return }

        pane.pty?.terminate()
        splitPaneGrids.removeValue(forKey: pane.id)
        let paneId = pane.id
        tabs[idx].splitPane = nil
        tabs[idx].activePaneIndex = 0

        if sessionManager.state == .running {
            sessionManager.sendPaneClose(tabId: activeTabId, paneId: paneId)
        }
    }

    /// Cycle focus between the primary and split pane of the active tab.
    func focusNextPane() {
        guard let activeTabId,
              let idx = tabs.firstIndex(where: { $0.id == activeTabId }),
              tabs[idx].splitPane != nil
        else { return }
        tabs[idx].activePaneIndex = tabs[idx].activePaneIndex == 0 ? 1 : 0
    }

    /// Update which pane is active locally (called from the `onKey` closures
    /// so clicking / typing in a pane makes it the target).
    func setActivePaneIndex(tabId: UInt32, index: Int) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard tabs[idx].activePaneIndex != index else { return }
        tabs[idx].activePaneIndex = index
    }

    /// Broadcast the local participant's terminal cursor position inside the
    /// split pane so every peer can render their unique cursor there.
    func broadcastSplitPaneCursor(paneId: UInt32, grid: GridModel) {
        guard sessionManager.state == .running else { return }
        var col: UInt16 = 0
        var row: UInt16 = 0
        if let local = grid.cursors.first(where: { $0.isLocal }) {
            col = local.col
            row = local.row
        }
        sessionManager.sendPaneCursor(paneId: paneId, col: col, row: row)
    }

    /// Resize a specific split pane's grid and PTY independently of the
    /// primary pane. Called from the split pane's `MetalTerminalView.onResize`.
    func handleSplitPaneResize(tabId: UInt32, paneId: UInt32,
                               cols: UInt16, rows: UInt16)
    {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }),
              tabs[idx].splitPane?.id == paneId
        else { return }
        let pane = tabs[idx].splitPane!
        pane.pty?.resize(cols: cols, rows: rows)
        pane.grid.resize(cols: cols, rows: rows, preserveTop: true)
    }

    private func makeHostTab(id: UInt32,
                             title: String,
                             cwd: String,
                             spawnImmediately: Bool = true) -> TabState?
    {
        // Match the user's current viewport so the new tab's PTY and grid
        // come up at the same size the renderer is about to lay them out at,
        // not the default 80x24.
        let cols = activeTab?.grid.cols ?? lastKnownTerminalGridSize?.cols ?? 80
        let rows = activeTab?.grid.rows ?? lastKnownTerminalGridSize?.rows ?? 24
        let pty = PTYSession()
        guard let grid = GridModel(cols: cols, rows: rows) else {
            NSLog("GridModel init failed for tab %u", id)
            return nil
        }
        // Host: PTY output → feed this tab's grid AND fan out to peers.
        pty.onOutput = { [weak self] bytes in
            guard let self = self else { return }
            grid.feed(bytes)
            let shouldShare = self.sessionManager.role == .host
                && self.sessionManager.state == .running
            NSLog("[ct] pty->out tab=%u bytes=%d share=%@",
                  id, bytes.count, shouldShare ? "Y" : "N")
            if shouldShare {
                let payload = Data(bytes)
                self.sessionManager.sendTabPtyOutput(tabId: id, data: payload)
                if self.pendingHostTabInitialSnapshots.contains(id),
                   self.tabs.contains(where: { $0.id == id })
                {
                    self.sendTabSnapshot(tabId: id)
                    self.pendingHostTabInitialSnapshots.remove(id)
                }
                // Backward compat for single-tab peers only. In multi-tab
                // sessions, bare PtyOutput is session-wide and can repaint
                // unrelated peer tabs with this tab's escape stream.
                if self.tabs.count <= 1, id == self.activeTabId {
                    self.sessionManager.sendPtyOutput(payload)
                }
            }
            // Mode probe is per-tab via the active grid; only re-probe when
            // output landed on the active tab.
            if id == self.activeTabId {
                self.probeLocalMode()
            }
            if shouldShare {
                self.handleHostPtyOutput(tabId: id)
            }
        }
        pty.onExit = { [weak self] in
            let msg: [UInt8] = Array("\r\n[process exited]\r\n".utf8)
            grid.feed(msg)
            self?.pendingHostTabInitialSnapshots.remove(id)
        }
        if spawnImmediately {
            guard pty.spawn(cwd: cwd, cols: cols, rows: rows) else {
                NSLog("PTY spawn failed for tab %u", id)
                return nil
            }
        }
        return TabState(id: id, title: title, pty: pty, grid: grid)
    }

    private func startPendingHostTabIfNeeded(tabId: UInt32,
                                             cols: UInt16? = nil,
                                             rows: UInt16? = nil)
    {
        guard let cwd = pendingHostTabStartCwds[tabId],
              let tab = tabs.first(where: { $0.id == tabId }),
              let pty = tab.pty
        else {
            return
        }
        pendingHostTabStartWorkItems.removeValue(forKey: tabId)?.cancel()
        let fallbackSize = currentTerminalGridSize()
        let spawnCols = cols ?? fallbackSize.cols
        let spawnRows = rows ?? fallbackSize.rows
        tab.grid.resize(cols: spawnCols, rows: spawnRows, preserveTop: true)
        guard pty.spawn(cwd: cwd, cols: spawnCols, rows: spawnRows) else {
            NSLog("PTY spawn failed for deferred tab %u", tabId)
            pendingHostTabStartCwds.removeValue(forKey: tabId)
            return
        }
        pendingHostTabStartCwds.removeValue(forKey: tabId)
        refreshTabTitle(forTabID: tabId)
    }

    private func startPendingHostTabs(cols: UInt16, rows: UInt16) {
        for tab in tabs {
            startPendingHostTabIfNeeded(
                tabId: tab.id,
                cols: cols,
                rows: rows)
        }
    }

    private func schedulePendingHostTabStart(tabId: UInt32,
                                             cols: UInt16,
                                             rows: UInt16)
    {
        guard pendingHostTabStartCwds[tabId] != nil else { return }
        pendingHostTabStartWorkItems.removeValue(forKey: tabId)?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingHostTabStartWorkItems.removeValue(forKey: tabId)
                self?.startPendingHostTabIfNeeded(
                    tabId: tabId,
                    cols: cols,
                    rows: rows)
            }
        }
        pendingHostTabStartWorkItems[tabId] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func schedulePendingHostTabStarts(cols: UInt16, rows: UInt16) {
        for tab in tabs {
            schedulePendingHostTabStart(
                tabId: tab.id,
                cols: cols,
                rows: rows)
        }
    }

    private func cancelPendingHostTabStarts() {
        for workItem in pendingHostTabStartWorkItems.values {
            workItem.cancel()
        }
        pendingHostTabStartWorkItems.removeAll()
    }

    private func currentTerminalGridSize() -> (cols: UInt16, rows: UInt16) {
        if let lastKnownTerminalGridSize {
            return lastKnownTerminalGridSize
        }
        if let activeTab {
            return (cols: activeTab.grid.cols, rows: activeTab.grid.rows)
        }
        return (cols: 80, rows: 24)
    }

    private func makePeerTab(id: UInt32, title: String,
                             preferredSize: (cols: UInt16, rows: UInt16)? = nil)
    -> TabState?
    {
        let cols = preferredSize?.cols ?? lastKnownTerminalGridSize?.cols ?? 80
        let rows = preferredSize?.rows ?? lastKnownTerminalGridSize?.rows ?? 24
        guard let grid = GridModel(cols: cols, rows: rows) else {
            NSLog("GridModel init failed for peer tab %u", id)
            return nil
        }
        return TabState(id: id, title: title, pty: nil, grid: grid)
    }

    // MARK: tab titles

    private func startTitlePolling() {
        titleTimer?.invalidate()
        titleTimer = Timer.scheduledTimer(
            withTimeInterval: 0.75,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAllTabTitles()
            }
        }
        refreshAllTabTitles()
    }

    private func stopTitlePolling() {
        titleTimer?.invalidate()
        titleTimer = nil
    }

    private func refreshAllTabTitles() {
        for tab in tabs where tab.pty != nil {
            refreshTabTitle(forTabID: tab.id)
        }
    }

    private func refreshTabTitle(forTabID tabId: UInt32) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabId }),
              let pty = tabs[idx].pty
        else {
            return
        }

        let fallback = tabs[idx].title
        let nextTitle = TabTitleResolver.resolveTitle(
            fd: pty.fd,
            pid: pty.pid,
            sessionRootPath: rootPath,
            fallbackTitle: fallback)
        guard nextTitle != tabs[idx].title else { return }

        tabs[idx].title = nextTitle
        if sessionManager.role == .host, sessionManager.state == .running {
            sessionManager.sendTabOpen(tabId: tabId, title: nextTitle)
        }
    }

    /// SwiftUI font matching the current terminal font settings. Used by
    /// overlays that render text over the terminal (autocomplete hints, etc.)
    /// so each user sees hints in their own chosen font.
    var terminalFont: Font {
        if !fontName.isEmpty, NSFont(name: fontName, size: fontSize) != nil {
            return .custom(fontName, size: fontSize)
        }
        return .system(size: fontSize, design: .monospaced)
    }

    // MARK: menu / hotkey actions

    /// True when there's something for ⌘W to close (host PTY, peer grid,
    /// active shared session, or open editor).
    var hasActiveSession: Bool {
        !tabs.isEmpty || activeEditor != nil || sessionManager.state != .idle
    }

    /// ⌘K — clear scrollback + visible screen, home the cursor.
    /// Sequence: ED 2 (erase display) + CUP 1;1 (home) + ED 3 (erase
    /// scrollback). Most modern terminals understand `\e[3J`.
    func clearScreen() {
        guard let activeTabId,
              let tab = tabs.first(where: { $0.id == activeTabId })
        else { return }
        let bytes = Array("\u{1B}[2J\u{1B}[H\u{1B}[3J".utf8)
        tab.grid.feed(bytes)
        // If we're hosting a shared session, propagate the clear so peers'
        // mirrored grids stay in sync.
        if sessionManager.role == .host, sessionManager.state == .running {
            let payload = Data(bytes)
            sessionManager.sendTabPtyOutput(tabId: activeTabId, data: payload)
            if tabs.count <= 1 {
                sessionManager.sendPtyOutput(payload)
            }
        }
    }

    /// ⌘+ — bump terminal point size by one step (clamped).
    func increaseFontSize() {
        fontSize = TerminalModel.clampFontSize(fontSize + TerminalModel.fontSizeStep)
    }

    /// ⌘- — drop terminal point size by one step (clamped).
    func decreaseFontSize() {
        fontSize = TerminalModel.clampFontSize(fontSize - TerminalModel.fontSizeStep)
    }

    /// ⌘0 — restore default terminal point size.
    func resetFontSize() {
        fontSize = TerminalModel.defaultFontSize
    }

    fileprivate static func clampFontSize(_ value: CGFloat) -> CGFloat {
        if !value.isFinite || value <= 0 { return defaultFontSize }
        return min(max(value, minimumFontSize), maximumFontSize)
    }

    /// ⌘C — copy the visible terminal grid (no selection model yet) to the
    /// system pasteboard. Matches the "or visible terminal if no selection"
    /// fallback in the spec.
    func menuCopy() {
        if activeEditor != nil {
            // Forward to the active responder so the editor (or any focused
            // NSText subclass) gets a chance to copy its own selection.
            if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
                return
            }
        }
        copyVisibleTerminalToPasteboard()
    }

    /// ⌘V — paste from system pasteboard. Routed through the same
    /// pipeline as the terminal view's performKeyEquivalent so PTY and
    /// peer-as-input flows both work.
    func menuPaste() {
        if activeEditor != nil {
            if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
                return
            }
        }
        guard inputEnabled else {
            NSSound.beep()
            return
        }
        guard let activeTabId,
              grid != nil,
              let s = NSPasteboard.general.string(forType: .string),
              !s.isEmpty
        else { return }
        let sanitized = TerminalPasteSanitizer.sanitize(s)
        guard !sanitized.isEmpty else { return }
        handlePaste(sanitized, forTabId: activeTabId)
    }

    func handlePaste(_ sanitized: String, forTabId tabId: UInt32, paneIndex: Int = 0) {
        guard tabId == activeTabId else { return }

        // "Paste again" — expand the active placeholder with the real content
        if let ph = activePlaceholder {
            expandActivePlaceholder(ph, forTabId: tabId, paneIndex: paneIndex)
            return
        }

        let bracketedPaste = activeTab?.grid.term.bracketedPasteMode == true
        let body = Array(sanitized.utf8)
        let bytes: [UInt8] = bracketedPaste
            ? Array("\u{1b}[200~".utf8) + body + Array("\u{1b}[201~".utf8)
            : body

        if sanitized.contains("\n") {
            pasteCounter += 1
            let extraLines = sanitized.components(separatedBy: "\n").count - 1
            let text = "[Pasted text #\(pasteCounter) + \(extraLines) lines]"
            activePlaceholder = ActivePlaceholder(text: text, bytes: bytes, cursorAfter: true)
            handleKey(Array(text.utf8), forTabId: tabId, paneIndex: paneIndex)
        } else {
            handleKey(bytes, forTabId: tabId, paneIndex: paneIndex)
        }
    }

    private func expandActivePlaceholder(_ ph: ActivePlaceholder, forTabId tabId: UInt32, paneIndex: Int, thenSend extra: [UInt8] = []) {
        activePlaceholder = nil
        let n = ph.text.utf8.count
        if !ph.cursorAfter {
            handleKey((0..<n).flatMap { _ in [0x1b, 0x5b, 0x43] as [UInt8] }, forTabId: tabId, paneIndex: paneIndex)
        }
        handleKey(Array(repeating: 0x7f, count: n), forTabId: tabId, paneIndex: paneIndex)
        handleKey(ph.bytes, forTabId: tabId, paneIndex: paneIndex)
        if !extra.isEmpty {
            handleKey(extra, forTabId: tabId, paneIndex: paneIndex)
        }
    }

    func handleFileDrop(_ url: URL, forTabId tabId: UInt32, paneIndex: Int = 0) {
        guard tabId == activeTabId else { return }
        let isImage: Bool
        if let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            isImage = contentType.conforms(to: .image)
        } else {
            let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "tiff", "bmp", "webp", "heic", "svg", "ico"]
            isImage = imageExts.contains(url.pathExtension.lowercased())
        }
        if isImage {
            imageDropCounter += 1
            let text = "[Image #\(imageDropCounter)]"
            let path = url.path
            let expandBytes = Array(path.utf8)
            activePlaceholder = ActivePlaceholder(text: text, bytes: expandBytes, cursorAfter: true)
            handleKey(Array(text.utf8), forTabId: tabId, paneIndex: paneIndex)
        } else {
            let path = url.path
            let text = path.contains(" ") ? "'\(path)'" : path
            handleKey(Array(text.utf8), forTabId: tabId, paneIndex: paneIndex)
        }
    }

    func formatWithPrettier() {
        guard sessionManager.role == .host,
              let editor = activeEditor,
              let url = resolveEditorURL(sessionPath: editor.state.path) else { return }
        saveEditor(docId: editor.state.docId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["prettier", "--write", url.path]
        process.terminationHandler = { [weak self] proc in
            guard proc.terminationStatus == 0 else {
                if proc.terminationStatus == 127 {
                    DispatchQueue.main.async {
                        self?.postTerminalNotice("prettier not found — install with: npm i -g prettier")
                    }
                }
                return
            }
            guard let formatted = try? String(contentsOf: url, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                try? editor.replaceText(formatted)
                self?.saveEditor(docId: editor.state.docId)
            }
        }
        try? process.run()
    }

    /// Decode the visible cells into a String (one line per row, no trailing
    /// blanks) and push it to NSPasteboard.
    func copyVisibleTerminalToPasteboard() {
        guard let grid = grid else {
            NSSound.beep()
            return
        }
        let text = visibleTerminalText(grid: grid)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }


    /// Decode visible cells row-by-row into Swift strings. Trailing blanks
    /// per row are trimmed. Wide cells (`width == 0` continuations) are
    /// skipped — they're already covered by the leading half.
    private func visibleTerminalLines(grid: GridModel) -> [String] {
        let snap = grid.snapshot()
        let cols = Int(grid.cols)
        let rows = Int(grid.rows)
        guard cols > 0, rows > 0, snap.count >= cols * rows else { return [] }

        var lines: [String] = []
        lines.reserveCapacity(rows)
        for r in 0..<rows {
            var line = ""
            for c in 0..<cols {
                let cell = snap[r * cols + c]
                if cell.width == 0 { continue }
                let cp = cell.codepoint
                if cp == 0 {
                    line.append(" ")
                } else if let scalar = UnicodeScalar(cp) {
                    line.append(Character(scalar))
                } else {
                    line.append(" ")
                }
            }
            // Trim trailing whitespace so blank cells don't pollute matches.
            while let last = line.last, last == " " { line.removeLast() }
            lines.append(line)
        }
        return lines
    }

    private func visibleTerminalText(grid: GridModel) -> String {
        visibleTerminalLines(grid: grid).joined(separator: "\n")
    }

    // MARK: sharing

    func startSharing() {
        // Sharing requires an explicit project root for file sync. If none has
        // been chosen yet, prompt the user before proceeding.
        if rootPath == nil {
            guard let folder = FolderPicker.pick() else { return }
            rootPath = folder
            fileSyncApplier.configure(rootPath: nil)
        }
        // Activate the session-root jail so any shells spawned (or respawned)
        // from here on are confined to the chosen root.
        var didRespawn = false
        if let root = rootPath {
            SessionRootJail.activate(rootPath: root)
            didRespawn = respawnPtysOutsideRoot(rootPath: root)
        }
        let size = currentTerminalGridSize()
        startPendingHostTabs(cols: size.cols, rows: size.rows)
        sessionManager.startHost()
        restartFileSyncWatcher()
        startFileSyncPolling()
        if let tool = tunnelTool {
            sessionManager.startBoreTunnel(
                borePath: tool.path,
                server: tool.server,
                secret: tool.server.isEmpty ? "" : SessionManager.boreSecret)
        }
        // Immediately publish our current mode so fresh joiners aren't stuck
        // on the default (.line) assumption.
        probeLocalMode(force: true)
        if let activeTabId {
            recordLocalTabFocus(activeTabId, broadcast: true)
        }
        if sessionManager.state == .running, !lastLocalCreatorOnlyMode {
            // If we just respawned shells, the new prompts haven't been
            // written to the grid yet (PTY output is async, and zsh startup
            // through user rcfiles can take hundreds of milliseconds).
            // Activating now would anchor the shared input at column 0 of an
            // empty row, so when the prompt eventually paints it would land
            // inside the editable region — making prompt characters look
            // like typed text. Poll until the prompt is detectable, then
            // activate.
            for tab in tabs {
                if didRespawn {
                    waitForPromptThenActivateSharedInput(tabId: tab.id)
                } else {
                    activateSharedInputAtCurrentCursor(
                        tabId: tab.id, broadcast: true)
                }
            }
        }
    }

    /// Poll up to ~2s waiting for a shell prompt to appear on the active row
    /// of `tabId`'s grid, then activate the shared input. Falls through and
    /// activates anyway after the timeout so an unusual prompt format
    /// doesn't permanently block sharing.
    private func waitForPromptThenActivateSharedInput(tabId: UInt32,
                                                      attempts: Int = 0)
    {
        let maxAttempts = 20
        guard let grid = tabs.first(where: { $0.id == tabId })?.grid else {
            return
        }
        let cursor = grid.term.cursor()
        let promptEnd = shellPromptEnd(onRow: cursor.y, before: cursor.x, grid: grid)
        let detected = cursor.x > 0 && promptEnd < cursor.x
        if detected || attempts >= maxAttempts {
            activateSharedInputAtCurrentCursor(tabId: tabId, broadcast: true)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.waitForPromptThenActivateSharedInput(
                tabId: tabId, attempts: attempts + 1)
        }
    }

    func stopSharing() {
        stopFileSyncPolling()
        sessionManager.stop()
        // Deactivate jail before spawning so new shells don't inherit ZDOTDIR/CT_SESSION_ROOT
        let wasJailed = SessionRootJail.activeRoot != nil
        SessionRootJail.deactivate()
        // Respawn any live PTYs at home so they escape the session-root jail.
        // Mirrors what session-start does (respawn into root) but in reverse.
        if wasJailed {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            for tab in tabs {
                if let pty = tab.pty, pty.pid > 0 {
                    respawnPty(pty: pty, grid: tab.grid, root: home,
                               notice: "[CoTTY] session ended — returning to home")
                }
                if let pane = tab.splitPane, let pty = pane.pty, pty.pid > 0 {
                    respawnPty(pty: pty, grid: pane.grid, root: home,
                               notice: "[CoTTY] session ended — returning to home")
                }
            }
        }
        resetSharedInputState()
        freshlyRespawnedTabs.removeAll()
    }

    /// Walk every host PTY (primary + split panes) and respawn any whose
    /// shell has wandered outside `rootPath`. PTYs already inside the chosen
    /// root keep their state so in-flight work isn't disturbed.
    @discardableResult
    private func respawnPtysOutsideRoot(rootPath: String) -> Bool {
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        var any = false
        for tab in tabs {
            if let pty = tab.pty, pty.pid > 0 {
                if respawnIfOutsideRoot(pty: pty, grid: tab.grid, root: root) {
                    sharedInputs.removeValue(forKey: tab.id)
                    sharedInputNeedsLineClear.remove(tab.id)
                    freshlyRespawnedTabs.insert(tab.id)
                    any = true
                }
            }
            if let pane = tab.splitPane, let pty = pane.pty, pty.pid > 0 {
                if respawnIfOutsideRoot(pty: pty, grid: pane.grid, root: root) {
                    sharedInputs.removeValue(forKey: tab.id)
                    sharedInputNeedsLineClear.remove(tab.id)
                    freshlyRespawnedTabs.insert(tab.id)
                    any = true
                }
            }
        }
        return any
    }

    /// Returns true if the PTY was actually respawned.
    private func respawnIfOutsideRoot(pty: PTYSession, grid: GridModel, root: String) -> Bool {
        let cwd = TabTitleResolver.cwd(pid: pty.pid)
        if let cwd {
            let normalized = URL(fileURLWithPath: cwd).standardizedFileURL.path
            if normalized == root || normalized.hasPrefix(root + "/") {
                return false
            }
        }
        respawnPty(
            pty: pty,
            grid: grid,
            root: root,
            notice: "[CoTTY] session started — restarting shell at session root")
        return true
    }

    func retryBoreTunnel() {
        // Re-detect in case user just installed ngrok
        tunnelTool = Self.findTunnelTool()
        boreBundlePath = tunnelTool.map { $0.path }
        guard let tool = tunnelTool else { return }
        sessionManager.startBoreTunnel(
            borePath: tool.path,
            server: tool.server,
            secret: tool.server.isEmpty ? "" : SessionManager.boreSecret)
    }

    func promptJoin() {
        let alert = NSAlert()
        alert.messageText = "Join shared session"
        alert.informativeText = "Paste the share URL"
        alert.alertStyle = .informational
        let input = EditableTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24))
        input.placeholderString = "cotty://join?... or host:port#k=..."
        alert.accessoryView = input
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle claudetogether:// deep-link URLs pasted directly into the dialog.
        if let parsed = URL(string: raw), parsed.scheme == "cotty" {
            joinFromURL(parsed)
            return
        }
        // Strip optional #k=<base64url> fragment and extract session key.
        let (hostPort, extractedKey): (String, SessionKey?) = {
            if let hashIdx = raw.firstIndex(of: "#") {
                let fragment = String(raw[raw.index(after: hashIdx)...])
                let addr = String(raw[..<hashIdx])
                if fragment.hasPrefix("k=") {
                    return (addr, SessionKey(base64url: String(fragment.dropFirst(2))))
                }
                return (addr, nil)
            }
            return (raw, nil)
        }()
        guard let colon = hostPort.lastIndex(of: ":"),
              let port = UInt16(hostPort[hostPort.index(after: colon)...]),
              !hostPort[..<colon].isEmpty
        else {
            NSLog("join: malformed \(raw)")
            return
        }
        let host = String(hostPort[..<colon])
        guard let peerRoot = FolderPicker.pick(
            prompt: "Choose the local folder this peer should use as the session root"
        ) else {
            return
        }
        // Tear down any existing session (local PTY or stale peer) before
        // joining — peers have no PTY of their own.
        endSession()
        sessionManager.stop()

        // Peer path: create a placeholder display-only tab so the UI is
        // populated immediately. This tab is replaced by real tabs as soon
        // as the host announces them via TabOpen frames; it also serves as
        // a fallback target for any legacy bare PtyOutput frames.
        guard let placeholder = makePeerTab(
            id: TerminalModel.placeholderTabId,
            title: "Shell")
        else {
            NSLog("placeholder tab create failed")
            return
        }
        tabs = [placeholder]
        activeTabId = placeholder.id
        rootPath = peerRoot
        fileSyncApplier.configure(rootPath: peerRoot)
        resetSharedInputState()
        sessionManager.sessionKey = extractedKey
        DispatchQueue.main.async { [weak self] in
            self?.sessionManager.joinPeer(host: host, port: port)
        }
    }

    /// Sentinel id used for the peer-side placeholder tab created on join.
    /// Replaced as soon as the host announces a real tab via TabOpen.
    static let placeholderTabId: UInt32 = .max

    /// Handles `claudetogether://join?addr=host:port&k=...` URLs opened by
    /// the system (e.g. clicking a shared link in Messages or Mail).
    func joinFromURL(_ url: URL) {
        guard url.scheme == "cotty", url.host == "join",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let addr = comps.queryItems?.first(where: { $0.name == "addr" })?.value
        else { return }
        let keyStr = comps.queryItems?.first(where: { $0.name == "k" })?.value
        let extractedKey = keyStr.flatMap { SessionKey(base64url: $0) }
        guard let colon = addr.lastIndex(of: ":"),
              let port = UInt16(addr[addr.index(after: colon)...]),
              !addr[..<colon].isEmpty
        else {
            NSLog("[ct] joinFromURL: malformed addr \(addr)")
            return
        }
        let host = String(addr[..<colon])
        guard let peerRoot = FolderPicker.pick(
            prompt: "Choose the local folder this peer should use as the session root"
        ) else { return }
        endSession()
        sessionManager.stop()
        guard let placeholder = makePeerTab(id: TerminalModel.placeholderTabId, title: "Shell")
        else {
            NSLog("[ct] joinFromURL: placeholder tab create failed")
            return
        }
        tabs = [placeholder]
        activeTabId = placeholder.id
        rootPath = peerRoot
        fileSyncApplier.configure(rootPath: peerRoot)
        resetSharedInputState()
        sessionManager.sessionKey = extractedKey
        DispatchQueue.main.async { [weak self] in
            self?.sessionManager.joinPeer(host: host, port: port)
        }
    }

    /// Presents the native macOS share sheet pre-loaded with the session URL,
    /// with "Copy Link" prepended as the first option.
    func showShareSheet(for url: URL) {
        guard let window = NSApplication.shared.keyWindow
                        ?? NSApplication.shared.windows.first,
              let anchor = window.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        let delegate = CopyLinkPickerDelegate(url: url)
        picker.delegate = delegate
        _sharePickerDelegate = delegate
        picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
    }

    // Held strongly so the picker delegate lives as long as the model.
    private var _sharePickerDelegate: NSObject?

    /// Shows a brief auto-dismissing notification banner overlay.
    func showSessionNotification(_ message: String) {
        notificationDismissTask?.cancel()
        withAnimation { sessionNotificationMessage = message }
        notificationDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation { self.sessionNotificationMessage = nil }
        }
    }

    // MARK: keystroke + resize handling

    /// Called by MetalTerminalView when the user types. The tab id is
    /// supplied so each per-tab view writes only to its own PTY — no central
    /// "active session" lookup that could leak keystrokes across tabs.
    func handleKey(_ bytes: [UInt8], forTabId tabId: UInt32, paneIndex: Int = 0) {
        guard tabId == activeTabId else { return }

        // Intercepts while a placeholder is live in the terminal input line
        if var ph = activePlaceholder {
            let n = ph.text.utf8.count
            let leftArrow:  [UInt8] = [0x1b, 0x5b, 0x44]
            let rightArrow: [UInt8] = [0x1b, 0x5b, 0x43]
            if bytes == [0x0d] || bytes == [0x0a] {
                // Enter → expand placeholder then submit
                expandActivePlaceholder(ph, forTabId: tabId, paneIndex: paneIndex, thenSend: bytes)
                return
            } else if bytes == [0x7f] {
                // Backspace → erase entire placeholder without expanding
                let wasAfter = ph.cursorAfter
                activePlaceholder = nil
                if !wasAfter {
                    handleKey((0..<n).flatMap { _ in rightArrow as [UInt8] }, forTabId: tabId, paneIndex: paneIndex)
                }
                handleKey(Array(repeating: 0x7f, count: n), forTabId: tabId, paneIndex: paneIndex)
                return
            } else if bytes == leftArrow && ph.cursorAfter {
                ph.cursorAfter = false
                activePlaceholder = ph
                handleKey((0..<n).flatMap { _ in leftArrow as [UInt8] }, forTabId: tabId, paneIndex: paneIndex)
                return
            } else if bytes == rightArrow && !ph.cursorAfter {
                ph.cursorAfter = true
                activePlaceholder = ph
                handleKey((0..<n).flatMap { _ in rightArrow as [UInt8] }, forTabId: tabId, paneIndex: paneIndex)
                return
            }
        }

        startPendingHostTabIfNeeded(tabId: tabId)
        // View-only enforcement: the MetalTerminalNSView already gates via
        // `inputEnabled`, but defend in depth so a programmatic call site
        // can't bypass the policy. The host always types locally.
        if isViewOnlyPeer {
            NSSound.beep()
            if !hasShownViewOnlyHint {
                hasShownViewOnlyHint = true
                showSessionNotification("View only — contact the host to request edit access")
            }
            return
        }
        // Route to the split pane when paneIndex == 1 and the tab is split.
        // Route to the split pane (host: local PTY; peer: send to host).
        if paneIndex == 1,
           let pane = tabs.first(where: { $0.id == tabId })?.splitPane
        {
            pane.grid.scrollToBottom()
            if let pty = pane.pty {
                pty.send(bytes)
            } else if sessionManager.role == .peer, sessionManager.state == .running {
                sessionManager.sendPaneInput(paneId: pane.id, data: Data(bytes))
            }
            return
        }
        // Primary pane (unchanged behavior).
        tabs.first(where: { $0.id == tabId })?.grid.scrollToBottom()
        if handleSharedInputKey(bytes, tabId: tabId) {
            return
        }
        if let pty = tabs.first(where: { $0.id == tabId })?.pty {
            pty.send(bytes)
            return
        }
        if sessionManager.role == .peer, sessionManager.state == .running {
            let payload = Data(bytes)
            if tabId == TerminalModel.placeholderTabId {
                sessionManager.sendInputBytes(payload)
            } else {
                sessionManager.sendTabInput(tabId: tabId, data: payload)
            }
        }
    }

    func handleTerminalMouseCell(col: UInt16, row: UInt16, forTabId tabId: UInt32) -> Bool {
        guard mouseMode,
              tabId == activeTabId,
              let tab = tabs.first(where: { $0.id == tabId }),
              let offset = tab.grid.inputOverlayOffset(atCol: col, row: row)
        else {
            return false
        }
        let request = SharedInputRequest(
            actor: sessionManager.localIdentity,
            kind: .moveTo,
            offset: offset)

        if canUseHostSharedInput(tabId: tabId) {
            applyAuthoritativeSharedInputRequest(tabId: tabId, request)
            return true
        }
        if canUsePeerSharedInput(tabId: tabId) {
            applyOptimisticSharedInputRequest(tabId: tabId, request)
            sessionManager.sendInputBytes(
                SharedInputCodec.encode(.request(tabId: tabId, request)))
            return true
        }
        return false
    }

    /// Called when the Metal renderer re-measures the terminal grid. We
    /// resize every tab's grid (and host PTY) so output streamed while a
    /// tab is inactive still renders correctly when the user switches to it.
    func handleResize(cols: UInt16, rows: UInt16) {
        lastKnownTerminalGridSize = (cols, rows)
        for tab in tabs {
            preserveSharedInputAcrossTransientOutput(tabId: tab.id)
            tab.pty?.resize(cols: cols, rows: rows)
            tab.grid.resize(cols: cols, rows: rows, preserveTop: true)
            reanchorSharedInputToGridCursor(tabId: tab.id)
        }
        schedulePendingHostTabStarts(cols: cols, rows: rows)
    }

    // MARK: inbound frames

    private func applyPeerTabFocus(_ tabId: UInt32) {
        guard tabs.contains(where: { $0.id == tabId }) else {
            pendingPeerFocusedTabId = tabId
            return
        }
        if activeTabId == nil ||
            activeTabId == TerminalModel.placeholderTabId ||
            activeTabId == tabId
        {
            activeTabId = tabId
            recordLocalTabFocus(tabId, broadcast: sessionManager.state == .running)
            syncGridSharedInputOverlay(tabId: tabId)
        }
    }

    private func handleInbound(_ frame: Frame, from peerID: UInt32) {
        switch frame {
        case .ptyOutput(let data):
            NSLog("[ct] inbound ptyOutput bytes=%d role=%@ grid=%@",
                  data.count,
                  sessionManager.role == .peer ? "peer" : "host",
                  grid != nil ? "Y" : "N")
            // Peers prefer per-tab TabPtyOutput frames. Legacy bare
            // PtyOutput is treated as a backward-compat fallback: feed it
            // only when we have no real tabs yet (i.e. just the join-time
            // placeholder, or nothing at all). Once any real TabOpen has
            // arrived, ignore it — otherwise the host's active tab would
            // overwrite whichever tab the peer has chosen to view.
            if sessionManager.role == .peer {
                let onlyPlaceholder = tabs.count == 1
                    && tabs[0].id == TerminalModel.placeholderTabId
                if tabs.isEmpty || onlyPlaceholder {
                    grid?.feed(Array(data))
                }
            }
        case .inputOp(let data):
            NSLog("[ct] inbound inputOp bytes=%d role=%@ pty=%@",
                  data.count,
                  sessionManager.role == .host ? "host" : "peer",
                  pty != nil ? "Y" : "N")
            if let packet = try? SharedInputCodec.decode(data) {
                handleSharedInputPacket(packet)
                return
            }
            // Backward-compatible fallback for any non-shared-input payload.
            if sessionManager.role == .host, let pty = pty, !data.isEmpty {
                pty.send(Array(data))
            }
        case .hello:
            if sessionManager.role == .host, sessionManager.state == .running {
                preserveActiveSharedInputsAcrossTransientOutput()
                syncSharedInputParticipants(broadcast: false)
                sessionManager.sendMode(lastLocalCreatorOnlyMode ? .raw : .line)
                sessionManager.broadcastAccessMode()
                // Send current tab list (TabOpen + per-tab snapshot + TabFocus)
                // to the joining peer so it materializes the same tabs we have.
                sendTabSnapshots(toTransportPeerID: peerID)
                // Legacy bare-PtyOutput snapshot for backward compat.
                broadcastTerminalSnapshot()
                broadcastSharedInputSnapshots()
                if let editor = activeEditor {
                    sessionManager.sendEditorOpen(
                        docId: editor.state.docId,
                        path: editor.state.path,
                        snapshot: editor.snapshotData)
                    editor.broadcastPresenceNow()
                }
                sendFullFileSync(toTransportPeerID: peerID)
            } else {
                syncSharedInputParticipants(broadcast: false)
            }
        case .tabOpen(let tabId, let title):
            guard sessionManager.role == .peer else { return }
            var preferredGridSize = lastKnownTerminalGridSize
            if let activeTab {
                preferredGridSize = (
                    cols: activeTab.grid.cols,
                    rows: activeTab.grid.rows)
            }
            // Replace the placeholder once a real tab announces itself so we
            // don't leave a phantom "Shell" entry around.
            if tabId != TerminalModel.placeholderTabId,
               tabs.count == 1,
               tabs[0].id == TerminalModel.placeholderTabId
            {
                preferredGridSize = (
                    cols: tabs[0].grid.cols,
                    rows: tabs[0].grid.rows)
                let placeholder = tabs.removeFirst()
                if activeTabId == placeholder.id {
                    activeTabId = nil
                }
            }
            if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
                tabs[idx].title = title
            } else if let tab = makePeerTab(
                id: tabId,
                title: title,
                preferredSize: preferredGridSize)
            {
                tabs.append(tab)
                if activeTabId == nil {
                    activeTabId = tabId
                    recordLocalTabFocus(tabId, broadcast: sessionManager.state == .running)
                }
                if let pendingFrames = pendingPeerTabOutput.removeValue(forKey: tabId) {
                    for frame in pendingFrames {
                        tabs.first(where: { $0.id == tabId })?.grid.feed(Array(frame))
                    }
                }
                if pendingPeerFocusedTabId == tabId {
                    pendingPeerFocusedTabId = nil
                    applyPeerTabFocus(tabId)
                } else {
                    syncGridSharedInputOverlay(tabId: tabId)
                }
            }
        case .tabClose(let tabId):
            guard sessionManager.role == .peer else { return }
            pendingPeerTabOutput.removeValue(forKey: tabId)
            if pendingPeerFocusedTabId == tabId {
                pendingPeerFocusedTabId = nil
            }
            if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
                tabs.remove(at: idx)
            }
            if activeTabId == tabId {
                activeTabId = tabs.first?.id
            }
        case .tabFocus(let tabId):
            if sessionManager.role == .host {
                guard tabs.contains(where: { $0.id == tabId }),
                      let identity = sessionManager.identity(forTransportPeerID: peerID)
                else {
                    return
                }
                let previousId = participantFocusedTab[identity]
                participantFocusedTab[identity] = tabId
                if let previousId, previousId != tabId {
                    syncSharedInputParticipants(tabId: previousId, broadcast: true)
                }
                syncSharedInputParticipants(tabId: tabId, broadcast: true)
                if sharedInputs[tabId]?.isActive != true {
                    activateSharedInputAtCurrentCursor(tabId: tabId, broadcast: true)
                }
            } else if sessionManager.role == .peer {
                if activeTabId == nil || activeTabId == TerminalModel.placeholderTabId {
                    applyPeerTabFocus(tabId)
                } else if !tabs.contains(where: { $0.id == tabId }) {
                    pendingPeerFocusedTabId = tabId
                }
            }
        case .tabPtyOutput(let tabId, let data):
            guard sessionManager.role == .peer else { return }
            if let tab = tabs.first(where: { $0.id == tabId }) {
                tab.grid.feed(Array(data))
            } else {
                pendingPeerTabOutput[tabId, default: []].append(data)
            }
        case .tabInput(let tabId, let data):
            guard sessionManager.role == .host, !data.isEmpty
            else {
                return
            }
            if let packet = try? SharedInputCodec.decode(data) {
                handleSharedInputPacket(packet)
                return
            }
            guard let tab = tabs.first(where: { $0.id == tabId }),
                  let pty = tab.pty
            else { return }
            pty.send(Array(data))
            if tabId != activeTabId {
                markTabUnread(id: tabId)
            }
        case .cursorPos(let identity, let col, let row):
            // Update the peer's cursor in the active tab's primary pane grid.
            guard identity != sessionManager.localIdentity,
                  let participant = sessionManager.participants.first(where: { $0.identity == identity }),
                  let grid = tabs.first(where: { $0.id == activeTabId })?.grid
            else { return }
            grid.upsertPeerCursor(
                id: identity.uuidValue,
                col: col, row: row,
                color: participant.color)
            if sessionManager.role == .host {
                sessionManager.broadcast(.cursorPos(identity, col: col, row: row))
            }
        case .fsDelta(let delta):
            guard sessionManager.role == .peer else { return }
            fileSyncApplier.apply(delta)
        case .fsSnapshot(let entries):
            guard sessionManager.role == .peer else { return }
            fileSyncApplier.reconcile(snapshot: entries)
        case .roster:
            syncSharedInputParticipants(broadcast: false)
            syncAllGridSharedInputOverlays()
            syncEditorParticipants()
        case .modeChange(let mode):
            if sessionManager.role == .peer, mode == .raw {
                resetSharedInputState()
            }
        case .editorOpen(let docId, let path, let snapshot):
            if let editor = activeEditor, editor.state.docId == docId {
                return
            }
            openEditor(docId: docId, path: path, snapshot: snapshot)
        case .editorOp(let docId, let opBytes):
            guard let editor = activeEditor, editor.state.docId == docId else { return }
            if sessionManager.role == .host {
                // Host-side enforcement: in view-only access mode, inbound
                // editor ops can only have come from a peer, so drop them
                // and don't fan them out.
                if sessionManager.accessMode == .viewOnly { return }
                editor.onRemoteOp(opBytes)
                sessionManager.sendEditorOp(docId: docId, opBytes: opBytes)
            } else {
                editor.onRemoteOp(opBytes)
            }
        case .editorPresence(let docId, let userId, let anchor, let selectionAnchor):
            guard let editor = activeEditor, editor.state.docId == docId else { return }
            guard let participant = sessionManager.participant(forEditorUserID: userId) else {
                return
            }
            if participant.identity != sessionManager.localIdentity {
                editor.onRemotePresence(
                    userId: participant.identity,
                    anchor: anchor,
                    selectionAnchor: selectionAnchor,
                    color: nsColor(for: participant.identity))
            }
            if sessionManager.role == .host {
                sessionManager.sendEditorPresence(
                    docId: docId,
                    userId: userId,
                    anchor: anchor,
                    selectionAnchor: selectionAnchor)
            }
        case .editorSave(let docId):
            guard sessionManager.role == .host else { return }
            saveEditor(docId: docId)
        case .editorSaved(let docId, let rev):
            guard let editor = activeEditor, editor.state.docId == docId else { return }
            editorSavedRevisions[docId] = rev
            editor.markSaved(rev: rev)
        case .editorClose(let docId):
            if sessionManager.role == .host {
                arbitrateCloseEditor(docId: docId)
            } else {
                closeEditor(docId: docId, broadcast: false)
            }

        // MARK: split-pane inbound
        case .paneOpen(let tabId, let paneId, let axis):
            guard sessionManager.role == .peer else { return }
            guard let tabIdx = tabs.firstIndex(where: { $0.id == tabId }) else { return }
            // Replace any stale local split so the host's layout wins.
            if let existing = tabs[tabIdx].splitPane {
                existing.pty?.terminate()
                splitPaneGrids.removeValue(forKey: existing.id)
            }
            let cols = max(tabs[tabIdx].grid.cols / (axis == .horizontal ? 2 : 1), 20)
            let rows = max(tabs[tabIdx].grid.rows / (axis == .vertical   ? 2 : 1), 6)
            guard let grid = GridModel(cols: cols, rows: rows) else { return }
            let pane = SplitPaneState(id: paneId, pty: nil, grid: grid)
            splitPaneGrids[paneId] = grid
            tabs[tabIdx].splitPane = pane
            tabs[tabIdx].splitAxis = axis

        case .paneClose(let tabId, let paneId):
            guard sessionManager.role == .peer else { return }
            guard let tabIdx = tabs.firstIndex(where: { $0.id == tabId }),
                  tabs[tabIdx].splitPane?.id == paneId
            else { return }
            splitPaneGrids.removeValue(forKey: paneId)
            tabs[tabIdx].splitPane = nil
            tabs[tabIdx].activePaneIndex = 0

        case .panePtyOutput(let paneId, let data):
            guard sessionManager.role == .peer else { return }
            splitPaneGrids[paneId]?.feed(Array(data))

        case .paneInput(let paneId, let data):
            guard sessionManager.role == .host, !data.isEmpty else { return }
            for tab in tabs {
                if let pane = tab.splitPane, pane.id == paneId, let pty = pane.pty {
                    pty.send(Array(data))
                    return
                }
            }

        case .paneCursorPos(let identity, let paneId, let col, let row):
            guard identity != sessionManager.localIdentity,
                  let participant = sessionManager.participants.first(where: { $0.identity == identity }),
                  let grid = splitPaneGrids[paneId]
            else { return }
            grid.upsertPeerCursor(
                id: identity.uuidValue, col: col, row: row, color: participant.color)
            if sessionManager.role == .host {
                sessionManager.relayPaneCursor(from: identity, paneId: paneId, col: col, row: row)
            }

        case .kick(let id):
            guard sessionManager.role == .peer,
                  id == sessionManager.localIdentity else { return }
            showSessionNotification("You were removed from this session.")
            endSession()

        default:
            break
        }
    }

    // MARK: mode probe (host only)

    private func startModeProbe() {
        modeTimer?.invalidate()
        modeTimer = nil
        // probeLocalMode is a no-op unless we are hosting a running session
        // with at least one remote peer — skip the timer entirely otherwise
        // to keep the main thread idle when the app is local-only.
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              sessionManager.participants.count > 1
        else {
            return
        }
        // Faster cadence in line mode so we catch claude/codex flipping
        // termios before they (sometimes) toggle alt-screen; once raw we
        // back off to 200ms.
        let interval = lastLocalCreatorOnlyMode ? 0.2 : 0.06
        modeTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeLocalMode() }
        }
    }

    private func stopModeProbe() {
        modeTimer?.invalidate()
        modeTimer = nil
        lastLocalCreatorOnlyMode = false
    }

    private func probeLocalMode(force: Bool = false) {
        let creatorOnlyMode = activeTab?.isRawMode ?? (grid?.isUsingAlternateScreen ?? false)
        guard force || creatorOnlyMode != lastLocalCreatorOnlyMode else { return }
        lastLocalCreatorOnlyMode = creatorOnlyMode
        // Re-arm at the cadence that matches the new mode (60ms in line,
        // 200ms in raw). Cheap: just a Timer.replace.
        if modeTimer != nil { startModeProbe() }
        // Only propagate if we're currently hosting a shared session.
        if sessionManager.role == .host, sessionManager.state == .running {
            sessionManager.sendMode(creatorOnlyMode ? .raw : .line)
            if creatorOnlyMode {
                if let activeTabId {
                    // Cancel any pending re-activation so a late timer
                    // doesn't bring the shared-input overlay back on top of
                    // a TUI that's about to paint the same screen region.
                    sharedInputPromptTimers.removeValue(forKey: activeTabId)?.invalidate()
                    sharedInputTransientOutputTimers.removeValue(forKey: activeTabId)?.invalidate()
                    deactivateSharedInput(tabId: activeTabId, bumpRevision: true)
                    syncGridSharedInputOverlay(tabId: activeTabId)
                    broadcastSharedInputSnapshot(tabId: activeTabId)
                }
            } else if let activeTabId {
                activateSharedInputAtCurrentCursor(tabId: activeTabId, broadcast: true)
            }
        }
    }

    // MARK: shared input line

    private var sharedInputParticipants: [UserIdentity] {
        var ids = sessionManager.participants.map(\.identity)
        if !ids.contains(sessionManager.localIdentity) {
            ids.insert(sessionManager.localIdentity, at: 0)
        }
        return ids
    }

    private func sharedInputParticipants(forTabId tabId: UInt32) -> [UserIdentity] {
        sharedInputParticipants.filter { identity in
            if let focused = participantFocusedTab[identity] {
                return focused == tabId
            }
            return identity == sessionManager.localIdentity && activeTabId == tabId
        }
    }

    private func recordLocalTabFocus(_ tabId: UInt32, broadcast: Bool) {
        let previousId = participantFocusedTab[sessionManager.localIdentity]
        participantFocusedTab[sessionManager.localIdentity] = tabId
        if let previousId, previousId != tabId {
            syncSharedInputParticipants(tabId: previousId, broadcast: sessionManager.role == .host)
        }
        syncSharedInputParticipants(tabId: tabId, broadcast: sessionManager.role == .host)
        if broadcast, sessionManager.state == .running {
            sessionManager.sendTabFocus(tabId: tabId)
        }
    }

    private func isHostSharedLineSession(tabId: UInt32) -> Bool {
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              let tab = tabs.first(where: { $0.id == tabId })
        else {
            return false
        }
        return !tab.isRawMode
    }

    private func isPeerSharedLineSession(tabId: UInt32) -> Bool {
        sessionManager.role == .peer &&
        sessionManager.state == .running &&
        sessionManager.remoteMode == .line &&
        tabs.contains(where: { $0.id == tabId })
    }

    private func canUseHostSharedInput(tabId: UInt32) -> Bool {
        isHostSharedLineSession(tabId: tabId) &&
        (sharedInputs[tabId]?.isActive ?? false)
    }

    private func canUsePeerSharedInput(tabId: UInt32) -> Bool {
        isPeerSharedLineSession(tabId: tabId) &&
        (sharedInputs[tabId]?.isActive ?? false) &&
        sessionManager.accessMode == .full
    }

    private func handleSharedInputKey(_ bytes: [UInt8], tabId: UInt32) -> Bool {
        // Tab: filesystem completion (or dismiss existing hints on second Tab)
        if bytes == [0x09],
           canUseHostSharedInput(tabId: tabId) || canUsePeerSharedInput(tabId: tabId)
        {
            if inputAutocomplete.visible {
                inputAutocomplete.dismiss()
                filesystemCompletionCwd = nil
            } else {
                handleFilesystemTab(tabId: tabId)
            }
            return true
        }

        let actor = sessionManager.localIdentity
        guard let request = sharedInputRequest(for: bytes, actor: actor) else {
            return false
        }

        if canUseHostSharedInput(tabId: tabId) {
            applyAuthoritativeSharedInputRequest(tabId: tabId, request)
            return true
        }
        if canUsePeerSharedInput(tabId: tabId) {
            applyOptimisticSharedInputRequest(tabId: tabId, request)
            let payload = SharedInputCodec.encode(.request(tabId: tabId, request))
            if tabId == TerminalModel.placeholderTabId {
                sessionManager.sendInputBytes(payload)
            } else {
                sessionManager.sendTabInput(tabId: tabId, data: payload)
            }
            return true
        }
        return false
    }

    private func sharedInputRequest(for bytes: [UInt8],
                                    actor: UserIdentity) -> SharedInputRequest?
    {
        switch bytes {
        case [0x0D]:
            return SharedInputRequest(actor: actor, kind: .commit)
        case [0x7F]:
            return SharedInputRequest(actor: actor, kind: .backspace)
        case [0x03]:
            return SharedInputRequest(actor: actor, kind: .interrupt)
        case [0x01], Array("\u{1B}[H".utf8):
            return SharedInputRequest(actor: actor, kind: .moveHome)
        case [0x05], Array("\u{1B}[F".utf8):
            return SharedInputRequest(actor: actor, kind: .moveEnd)
        case [0x02], Array("\u{1B}[D".utf8):
            return SharedInputRequest(actor: actor, kind: .moveLeft)
        case [0x06], Array("\u{1B}[C".utf8):
            return SharedInputRequest(actor: actor, kind: .moveRight)
        case Array("\u{1B}b".utf8):
            return SharedInputRequest(actor: actor, kind: .movePreviousWord)
        case Array("\u{1B}f".utf8):
            return SharedInputRequest(actor: actor, kind: .moveNextWord)
        case [0x15]:
            return SharedInputRequest(actor: actor, kind: .deleteToStart)
        case [0x17], [0x1B, 0x7F]:
            return SharedInputRequest(actor: actor, kind: .deletePreviousWord)
        case [0x09]:
            return SharedInputRequest(actor: actor, kind: .insertText, text: "    ")
        default:
            guard let text = String(bytes: bytes, encoding: .utf8),
                  !text.isEmpty,
                  !text.unicodeScalars.contains(where: {
                      $0.value < 0x20 || $0.value == 0x7F
                  })
            else {
                return nil
            }
            return SharedInputRequest(actor: actor, kind: .insertText, text: text)
        }
    }

    private func handleSharedInputPacket(_ packet: SharedInputPacket) {
        switch packet {
        case .request(let tabId, let request):
            guard sessionManager.role == .host,
                  tabs.contains(where: { $0.id == tabId })
            else {
                return
            }
            if participantFocusedTab[request.actor] != tabId {
                let previousId = participantFocusedTab[request.actor]
                participantFocusedTab[request.actor] = tabId
                if let previousId, previousId != tabId {
                    syncSharedInputParticipants(tabId: previousId, broadcast: true)
                }
            }
            applyAuthoritativeSharedInputRequest(tabId: tabId, request)
        case .snapshot(let tabId, let snapshot):
            guard sessionManager.role == .peer else { return }
            var state = sharedInputs[tabId] ?? SharedInputState()
            let wasActive = state.isActive
            let preservedAnchor = (state.anchorCol, state.anchorRow)
            let preservedText = state.text
            let localAnchor = tabs.first(where: { $0.id == tabId })?.grid.term.cursor()

            // If the text is unchanged this snapshot was triggered by a pure
            // cursor move (arrow keys) on another participant — not an
            // insert/delete. Preserve the local user's own cursor so optimistic
            // moves aren't rolled back by another user's navigation.
            let localId = sessionManager.localIdentity
            let textUnchanged = snapshot.isActive
                && state.isActive
                && snapshot.text == state.text
            let savedLocalCursor: Int? = textUnchanged
                ? state.cursors[localId]
                : nil

            state.apply(snapshot)

            // Restore local cursor for move-only snapshots (text didn't change).
            if let saved = savedLocalCursor, state.isActive {
                state.restoreCursor(for: localId, to: saved)
            }

            // The host's anchor (already applied by state.apply above) is
            // authoritative: it marks exactly where user input starts on the
            // prompt line. Overriding it with the local terminal cursor would
            // place the anchor at the END of any typed text, causing the
            // overlay to render that text again after what is already visible
            // in the terminal grid (duplicating the command line content).
            _ = (wasActive, preservedAnchor, localAnchor) // unused now
            sharedInputs[tabId] = state
            syncGridSharedInputOverlay(tabId: tabId)
            refreshInputAutocomplete()
            // Only treat snapshots that change the text as typing activity.
            // Snapshots also fire on tab open, peer join (host floods all
            // tabs), focus changes, and cursor-only moves — none of which
            // should trip the indicator.
            let isTypingActivity = wasActive
                && snapshot.isActive
                && snapshot.text != preservedText
            if isTypingActivity, tabId != activeTabId {
                markTabUnread(id: tabId)
            }
        }
    }

    private func applyAuthoritativeSharedInputRequest(tabId: UInt32,
                                                     _ request: SharedInputRequest)
    {
        // Any user interaction with the shared input means startup is done
        // and any future reactivation should resume normal prompt-aware
        // extraction (e.g. for history recall via ↑).
        freshlyRespawnedTabs.remove(tabId)
        syncSharedInputParticipants(tabId: tabId, broadcast: false)
        // Mark the tab unread for the local participant whenever a typing
        // request arrives for a tab they aren't currently viewing — even if
        // the host's shared-input state for that tab isn't active yet (e.g.
        // host has never visited the tab). This is the only signal the host
        // has that a guest is typing on a background tab.
        if request.actor != sessionManager.localIdentity, tabId != activeTabId {
            markTabUnread(id: tabId)
        }
        var state = sharedInputs[tabId] ?? SharedInputState()
        if !state.isActive {
            sharedInputs[tabId] = state
            return
        }
        _ = state.ensureParticipant(request.actor, bumpRevision: false)
        let effect = state.apply(request, bumpRevision: true)
        sharedInputs[tabId] = state
        syncGridSharedInputOverlay(tabId: tabId)
        broadcastSharedInputSnapshot(tabId: tabId)
        handleSharedInputEffect(tabId: tabId, effect)
        refreshInputAutocomplete()
    }

    private func applyOptimisticSharedInputRequest(tabId: UInt32,
                                                  _ request: SharedInputRequest)
    {
        var state = sharedInputs[tabId] ?? SharedInputState()
        _ = state.ensureParticipant(request.actor, bumpRevision: false)
        let effect = state.apply(request, bumpRevision: false)
        sharedInputs[tabId] = state
        syncGridSharedInputOverlay(tabId: tabId)
        refreshInputAutocomplete()
        if case .none = effect {
            return
        }
        handleSharedInputEffect(tabId: tabId, effect)
    }

    private func handleSharedInputEffect(tabId: UInt32,
                                         _ effect: SharedInputApplyEffect)
    {
        switch effect {
        case .none:
            return
        case .commit(let line):
            syncGridSharedInputOverlay(tabId: tabId)
            commandHistory.record(line)
            inputAutocomplete.dismiss()
            if sessionManager.role == .host,
               interceptEditorCommand(line, fromTabId: tabId)
            {
                return
            }
            if sessionManager.role == .host,
               let pty = tabs.first(where: { $0.id == tabId })?.pty
            {
                sharedInputPromptTimers.removeValue(forKey: tabId)?.invalidate()
                // The shell's readline buffer was cleared with Ctrl+U at
                // activation time (see activateSharedInputAtCurrentCursor),
                // so we just send the committed line and Enter.
                sharedInputNeedsLineClear.remove(tabId)
                let payload = Array(line.utf8) + [0x0D]
                pty.send(payload)
            }
        case .interrupt:
            syncGridSharedInputOverlay(tabId: tabId)
            inputAutocomplete.dismiss()
            if sessionManager.role == .host,
               let pty = tabs.first(where: { $0.id == tabId })?.pty
            {
                sharedInputPromptTimers.removeValue(forKey: tabId)?.invalidate()
                pty.send([0x03])
            }
        }
    }

    private func handleHostPtyOutput(tabId: UInt32) {
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              let tab = tabs.first(where: { $0.id == tabId }),
              !tab.isRawMode
        else {
            return
        }
        if sharedInputs[tabId]?.isActive == true {
            if sharedInputTransientOutputTimers[tabId] != nil {
                reanchorSharedInputToGridCursor(tabId: tabId)
                broadcastSharedInputSnapshot(tabId: tabId)
                return
            }
            deactivateSharedInput(tabId: tabId, bumpRevision: true)
            syncGridSharedInputOverlay(tabId: tabId)
            broadcastSharedInputSnapshot(tabId: tabId)
        }
        sharedInputPromptTimers.removeValue(forKey: tabId)?.invalidate()
        sharedInputPromptTimers[tabId] = Timer.scheduledTimer(
            withTimeInterval: 0.35,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activateSharedInputAtCurrentCursor(
                    tabId: tabId,
                    broadcast: true)
            }
        }
    }

    private func activateSharedInputAtCurrentCursor(tabId: UInt32,
                                                   broadcast: Bool)
    {
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              let tab = tabs.first(where: { $0.id == tabId }),
              !tab.isRawMode
        else { return }
        let grid = tab.grid

        syncSharedInputParticipants(tabId: tabId, broadcast: false)
        let cursor = grid.term.cursor()
        let cols   = Int(grid.cols)
        let existingState = sharedInputs[tabId]
        var state = existingState ?? SharedInputState()

        // Determine where user-editable input starts on the current prompt line.
        // Priority 1: saved anchor on the SAME ROW (reliable — set by a prior
        //   activation, e.g. from history navigation or typing before sharing).
        // Priority 2: scan the current row for a shell prompt pattern (% $ # >).
        // Fallback: cursor position — nothing to recover, fresh prompt.
        // Tabs whose PTY was just respawned have a guaranteed-fresh shell:
        // the cells before the cursor are the new prompt, never user input.
        // Skip the prompt-detection / extraction path entirely so we can't
        // accidentally pull prompt characters into initialText.
        //
        // The flag is sticky — we do NOT clear it here. Shell startup emits
        // output in multiple chunks (zshrc sourcing, prompt redraws), each
        // of which can trigger handleHostPtyOutput → reschedule a 350 ms
        // sharedInputPromptTimer that reactivates after this call. Clearing
        // on the first activation would let a later activation extract the
        // prompt as initialText. Cleared only when the user actually types
        // (see appendSharedInputCharacter / sendSharedInputCommit) or when
        // the session ends.
        let isFreshShell = freshlyRespawnedTabs.contains(tabId)

        let userInputCol: UInt16
        if isFreshShell {
            userInputCol = cursor.x
        } else if let es = existingState,
           !es.isActive,
           es.anchorRow == cursor.y,
           es.anchorCol < cursor.x,
           es.textScalars.isEmpty
        {
            userInputCol = es.anchorCol
        } else {
            userInputCol = shellPromptEnd(onRow: cursor.y, before: cursor.x, grid: grid)
        }

        let inputLinear  = Int(cursor.y) * cols + Int(userInputCol)
        let cursorLinear = Int(cursor.y) * cols + Int(cursor.x)

        let anchorCol:   UInt16
        let anchorRow:   UInt16
        let initialText: String

        if userInputCol < cursor.x, inputLinear < cursorLinear {
            // Text already sits between the detected prompt end and the cursor
            // (typed before sharing started, or recalled via ↑). Read it so
            // users can arrow through and delete it normally.
            let snap = grid.snapshot()
            var extracted = ""
            for i in inputLinear..<min(cursorLinear, snap.count) {
                let cell = snap[i]
                if cell.width == 0 { continue }
                if cell.codepoint == 0 { extracted.append(" ") }
                else if let sc = UnicodeScalar(cell.codepoint) { extracted.append(Character(sc)) }
            }
            initialText = extracted.replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression)
            anchorCol = userInputCol
            anchorRow = cursor.y
            // Mark this tab so the commit prepends Ctrl+U to clear the shell's
            // readline buffer (which already holds this text).
            if !initialText.isEmpty {
                sharedInputNeedsLineClear.insert(tabId)
            }
        } else {
            initialText = ""
            anchorCol   = cursor.x
            anchorRow   = cursor.y
        }

        let changed = state.activate(
            anchorCol: anchorCol,
            anchorRow: anchorRow,
            initialText: initialText,
            participants: sharedInputParticipants(forTabId: tabId),
            bumpRevision: true)
        sharedInputs[tabId] = state

        // Place all participants at the end of any pre-loaded text so they
        // start in the natural editing position (after the existing command).
        if !initialText.isEmpty {
            let end = state.textScalars.count
            for identity in sharedInputParticipants(forTabId: tabId) {
                if sharedInputs[tabId]?.cursors[identity] != nil {
                    sharedInputs[tabId]?.restoreCursor(for: identity, to: end)
                }
            }
        }

        syncGridSharedInputOverlay(tabId: tabId)

        // After loading existing text into the overlay, clear the shell's
        // readline buffer so PTY and UI agree: the shell holds the same text
        // we just loaded (typed before sharing, or recalled via ↑). Ctrl+U
        // (0x15) kills from cursor to beginning of line. The shell will
        // redraw the empty input area; preserveSharedInputAcrossTransientOutput
        // ensures that redraw doesn't tear down the overlay we just set up.
        // After the redraw the cursor sits at the prompt end and the terminal
        // cells beyond our overlay are blank, so subsequent backspaces no
        // longer leave residue from the original (longer) command.
        if !initialText.isEmpty,
           let pty = tabs.first(where: { $0.id == tabId })?.pty
        {
            preserveSharedInputAcrossTransientOutput(tabId: tabId)
            pty.send([0x15])
        }

        if broadcast && (changed || state.isActive) {
            broadcastSharedInputSnapshot(tabId: tabId)
        }
    }

    /// Scan `row` of the terminal grid up to `before` (the cursor column) and
    /// return the column right after the last common shell prompt indicator
    /// ("% ", "$ ", "# ", "> "). Returns `before` if no pattern is found.
    private func shellPromptEnd(onRow row: UInt16, before col: UInt16,
                                grid: GridModel) -> UInt16
    {
        let snap = grid.snapshot()
        let cols = Int(grid.cols)
        let rowStart = Int(row) * cols
        let limit = min(Int(col), cols)
        guard rowStart + limit <= snap.count, limit > 0 else { return col }

        var text = ""
        for c in 0..<limit {
            let cell = snap[rowStart + c]
            if cell.codepoint == 0 { text.append(" ") }
            else if let sc = UnicodeScalar(cell.codepoint) { text.append(Character(sc)) }
        }

        for pattern in ["% ", "$ ", "# ", "> "] {
            if let range = text.range(of: pattern, options: .backwards) {
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                if end < Int(col) { return UInt16(end) }
            }
        }
        return col
    }

    private func syncSharedInputParticipants(broadcast: Bool) {
        for tab in tabs {
            syncSharedInputParticipants(tabId: tab.id, broadcast: broadcast)
        }
    }

    private func syncSharedInputParticipants(tabId: UInt32, broadcast: Bool) {
        guard sessionManager.role == .host else { return }
        guard var state = sharedInputs[tabId] else { return }
        let changed = state.syncParticipants(
            sharedInputParticipants(forTabId: tabId),
            bumpRevision: true)
        if changed {
            sharedInputs[tabId] = state
            syncGridSharedInputOverlay(tabId: tabId)
            if broadcast {
                broadcastSharedInputSnapshot(tabId: tabId)
            }
        }
    }

    private func broadcastSharedInputSnapshot(tabId: UInt32) {
        guard sessionManager.role == .host,
              sessionManager.state == .running
        else {
            return
        }
        let state = sharedInputs[tabId] ?? SharedInputState()
        let ptyPid = tabs.first(where: { $0.id == tabId })?.pty?.pid ?? 0
        let currentCwd = ptyPid > 0 ? (TabTitleResolver.cwd(pid: ptyPid) ?? "") : ""
        let snapshot = state.snapshot(
            participants: sharedInputParticipants(forTabId: tabId),
            cwd: currentCwd)
        sessionManager.broadcast(.inputOp(
            SharedInputCodec.encode(.snapshot(tabId: tabId, snapshot))))
    }

    private func broadcastSharedInputSnapshots() {
        for tab in tabs {
            broadcastSharedInputSnapshot(tabId: tab.id)
        }
    }

    private func deactivateSharedInput(tabId: UInt32,
                                       bumpRevision: Bool) {
        sharedInputTransientOutputTimers.removeValue(forKey: tabId)?.invalidate()
        sharedInputNeedsLineClear.remove(tabId)
        var state = sharedInputs[tabId] ?? SharedInputState()
        _ = state.deactivate(bumpRevision: bumpRevision)
        sharedInputs[tabId] = state
    }

    private func preserveActiveSharedInputsAcrossTransientOutput() {
        for tab in tabs where sharedInputs[tab.id]?.isActive == true {
            preserveSharedInputAcrossTransientOutput(tabId: tab.id)
        }
    }

    private func preserveSharedInputAcrossTransientOutput(tabId: UInt32) {
        guard sharedInputs[tabId]?.isActive == true else { return }
        sharedInputTransientOutputTimers.removeValue(forKey: tabId)?.invalidate()
        sharedInputTransientOutputTimers[tabId] = Timer.scheduledTimer(
            withTimeInterval: 0.75,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sharedInputTransientOutputTimers.removeValue(forKey: tabId)
            }
        }
    }

    private func reanchorSharedInputToGridCursor(tabId: UInt32) {
        guard var state = sharedInputs[tabId],
              state.isActive,
              let grid = tabs.first(where: { $0.id == tabId })?.grid
        else {
            return
        }
        let cursor = grid.term.cursor()
        state.overrideAnchor(anchorCol: cursor.x, anchorRow: cursor.y)
        sharedInputs[tabId] = state
        syncGridSharedInputOverlay(tabId: tabId)
    }

    private func broadcastTerminalSnapshot() {
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              tabs.count <= 1,
              let grid
        else {
            return
        }

        let bytes = encodeTerminalSnapshot(from: grid)
        guard !bytes.isEmpty else { return }
        sessionManager.sendPtyOutput(Data(bytes))
    }

    private func sendTabSnapshot(tabId: UInt32,
                                 toTransportPeerID peerID: UInt32? = nil)
    {
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              let tab = tabs.first(where: { $0.id == tabId })
        else {
            return
        }
        // Only send scrollback on the initial join handshake (peerID is set).
        // Broadcast refreshes on tab-focus must not flood all peers with history.
        if let peerID {
            let history = encodeScrollbackHistory(from: tab.grid)
            if !history.isEmpty {
                sessionManager.sendTabPtyOutput(
                    tabId: tabId,
                    data: Data(history),
                    toTransportPeerID: peerID)
            }
        }
        let bytes = encodeTerminalSnapshot(from: tab.grid)
        guard !bytes.isEmpty else { return }
        sessionManager.sendTabPtyOutput(
            tabId: tabId,
            data: Data(bytes),
            toTransportPeerID: peerID)
    }

    /// Send a TabOpen + per-tab snapshot + TabFocus to a freshly-joined peer
    /// so its tab strip and grids match the host's state. Companion to the
    /// legacy bare-PtyOutput snapshot sent by `broadcastTerminalSnapshot()`.
    private func sendTabSnapshots(toTransportPeerID peerID: UInt32) {
        guard sessionManager.role == .host,
              sessionManager.state == .running
        else { return }
        for tab in tabs {
            sessionManager.sendTabOpen(
                tabId: tab.id,
                title: tab.title,
                toTransportPeerID: peerID)
            sendTabSnapshot(tabId: tab.id, toTransportPeerID: peerID)
            let sharedSnapshot = (sharedInputs[tab.id] ?? SharedInputState())
                .snapshot(participants: sharedInputParticipants(forTabId: tab.id))
            sessionManager.send(
                .inputOp(SharedInputCodec.encode(
                    .snapshot(tabId: tab.id, sharedSnapshot))),
                toTransportPeerID: peerID)
            // If the tab is currently split, announce the pane and send its content.
            if let pane = tab.splitPane {
                sessionManager.sendPaneOpen(
                    tabId: tab.id, paneId: pane.id, axis: tab.splitAxis,
                    toTransportPeerID: peerID)
                let paneHistory = encodeScrollbackHistory(from: pane.grid)
                if !paneHistory.isEmpty {
                    sessionManager.sendPanePtyOutput(
                        paneId: pane.id, data: Data(paneHistory),
                        toTransportPeerID: peerID)
                }
                let snap = encodeTerminalSnapshot(from: pane.grid)
                if !snap.isEmpty {
                    sessionManager.sendPanePtyOutput(
                        paneId: pane.id, data: Data(snap),
                        toTransportPeerID: peerID)
                }
            }
        }
        if let activeId = activeTabId {
            sessionManager.sendTabFocus(
                tabId: activeId,
                toTransportPeerID: peerID)
        }
    }

    private func encodeTerminalSnapshot(from grid: GridModel) -> [UInt8] {
        // Always encode the live viewport, never the scroll-adjusted overlay.
        // grid.snapshot() blends scrollback rows in when the host has scrolled
        // back, which would send the wrong view and misplace the cursor.
        let snapshot = grid.term.snapshot()
        let cols = Int(grid.cols)
        let rows = Int(grid.rows)
        guard cols > 0, rows > 0, snapshot.count >= cols * rows else {
            return []
        }

        var out = ""
        // Repaint the host's visible screen so a newly joined peer inherits
        // the current prompt and command line before new output arrives.
        out += "\u{1B}[?25l"
        out += "\u{1B}[0m"
        out += "\u{1B}[2J"

        var lastStyle = SnapshotStyle.default
        for row in 0..<rows {
            var rendered = ""
            var visibleLine = ""
            var pendingStyle = lastStyle

            for col in 0..<cols {
                let cell = snapshot[row * cols + col]
                if cell.width == 0 { continue }

                let ch = scalarString(from: cell.codepoint)
                let style = SnapshotStyle(cell: cell)

                if style != pendingStyle {
                    rendered += style.sgrTransition(from: pendingStyle)
                    pendingStyle = style
                }
                rendered += ch
                if ch != " " || style != .default {
                    visibleLine = rendered
                }
            }

            guard !visibleLine.isEmpty else { continue }
            out += "\u{1B}[\(row + 1);1H"
            out += visibleLine
            lastStyle = pendingStyle
        }

        let cursor = grid.term.cursor()
        out += "\u{1B}[0m"
        out += "\u{1B}[\(Int(cursor.y) + 1);\(Int(cursor.x) + 1)H"
        out += "\u{1B}[?25h"
        return Array(out.utf8)
    }

    private func encodeScrollbackHistory(from grid: GridModel) -> [UInt8] {
        let cols = Int(grid.cols)
        let totalRows = grid.term.scrollbackLength
        guard cols > 0, totalRows > 0 else { return [] }

        var out = ""
        out += "\u{1B}[?25l"
        out += "\u{1B}[0m"

        let batchSize = 500
        for startRow in stride(from: 0, to: totalRows, by: batchSize) {
            let rowCount = min(batchSize, totalRows - startRow)
            var cells = [ct_cell](repeating: ct_cell(), count: rowCount * cols)
            let copied = grid.term.copyScrollback(
                startRow: startRow,
                rowCount: rowCount,
                into: &cells)

            for r in 0..<copied {
                var rendered = "\u{1B}[0m"
                var visibleLine = ""
                var pendingStyle = SnapshotStyle.default

                for c in 0..<cols {
                    let cell = cells[r * cols + c]
                    if cell.width == 0 { continue }
                    let ch = scalarString(from: cell.codepoint)
                    let style = SnapshotStyle(cell: cell)
                    if style != pendingStyle {
                        rendered += style.sgrTransition(from: pendingStyle)
                        pendingStyle = style
                    }
                    rendered += ch
                    if ch != " " || style != .default {
                        visibleLine = rendered
                    }
                }

                if visibleLine.isEmpty {
                    out += "\r\n"
                } else {
                    out += visibleLine
                    out += "\u{1B}[0m\r\n"
                }
            }
        }

        // Flush whatever is still on the visible screen into the peer's
        // scrollback ring. After sending totalRows lines, the last min(rows,
        // totalRows) rows are on-screen and have not yet been pushed to
        // scrollback. Sending grid.rows blank newlines scrolls them off —
        // they land in the ring — so the subsequent \u{1B}[2J in the viewport
        // frame cannot erase them.
        let flushCount = Int(grid.rows)
        for _ in 0..<flushCount {
            out += "\r\n"
        }

        return Array(out.utf8)
    }

    private func scalarString(from codepoint: UInt32) -> String {
        guard codepoint != 0,
              let scalar = UnicodeScalar(codepoint)
        else {
            return " "
        }
        return String(scalar)
    }

    private func syncGridSharedInputOverlay() {
        guard let activeTabId else { return }
        syncGridSharedInputOverlay(tabId: activeTabId)
    }

    private func syncGridSharedInputOverlay(tabId: UInt32) {
        guard let grid = tabs.first(where: { $0.id == tabId })?.grid else { return }
        guard let state = sharedInputs[tabId], state.isActive else {
            grid.clearInputOverlay()
            return
        }

        let participants = sessionManager.role == .host
            ? sharedInputParticipants(forTabId: tabId)
            : receivedSharedInputParticipants(in: state)
        let overlayCursors = state.snapshot(participants: participants)
            .cursors
            .map { cursor -> GridModel.InputOverlayCursor in
                let isLocal = cursor.identity == sessionManager.localIdentity
                return GridModel.InputOverlayCursor(
                    id: isLocal ? grid.localCursorID : cursor.identity.uuidValue,
                    offset: cursor.offset,
                    color: color(for: cursor.identity),
                    isLocal: isLocal)
            }

        grid.setInputOverlay(
            anchorCol: state.anchorCol,
            anchorRow: state.anchorRow,
            text: state.text,
            cursors: overlayCursors)
    }

    private func receivedSharedInputParticipants(in state: SharedInputState) -> [UserIdentity] {
        let localIdentity = sessionManager.localIdentity
        return Array(state.cursors.keys).sorted { lhs, rhs in
            if lhs == localIdentity { return true }
            if rhs == localIdentity { return false }
            return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
        }
    }

    // MARK: shared-input autocomplete

    private func refreshInputAutocomplete() {
        // Overlay not shown yet — skip rather than clearing filesystemCompletionCwd.
        // This prevents mid-setup calls (e.g. from insertTextIntoSharedInput) from
        // tearing down state that handleFilesystemTab is about to use.
        guard inputAutocomplete.visible else { return }
        guard let cwd = filesystemCompletionCwd,
              let tabId = activeTabId,
              let text = sharedInputs[tabId]?.text
        else {
            inputAutocomplete.dismiss()
            filesystemCompletionCwd = nil
            return
        }
        let token = lastPathToken(in: text)
        if let result = computeFilesystemMatches(token: token, cwd: cwd) {
            inputAutocomplete.update(items: result.items, prefix: token)
        } else {
            inputAutocomplete.dismiss()
            filesystemCompletionCwd = nil
        }
    }

    private func acceptInputAutocompleteSelection(tabId: UInt32) {
        guard let suggestion = inputAutocomplete.currentSelection else { return }
        replaceSharedInputLine(tabId: tabId, with: suggestion)
        inputAutocomplete.dismiss()
    }

    // MARK: Filesystem tab completion

    private func handleFilesystemTab(tabId: UInt32) {
        guard sharedInputs[tabId]?.isActive == true else { return }
        let text = sharedInputs[tabId]?.text ?? ""
        let token = lastPathToken(in: text)

        // Handle bare `~` → complete to `~/`
        if token == "~" {
            insertTextIntoSharedInput(tabId: tabId, text: "/")
            return
        }

        let cwd: String
        if let pty = tabs.first(where: { $0.id == tabId })?.pty, pty.pid > 0,
           let resolved = TabTitleResolver.cwd(pid: pty.pid) {
            cwd = resolved
        } else if let peerCwd = sharedInputs[tabId]?.lastKnownCwd, !peerCwd.isEmpty {
            cwd = peerCwd   // use host's CWD broadcast via snapshot (peer/guest path)
        } else {
            cwd = NSHomeDirectory()
        }

        // Merge filesystem matches with command matches when completing the first token
        let fileResult = computeFilesystemMatches(token: token, cwd: cwd)
        let cmds: [String] = isCommandPosition(in: text) && !token.isEmpty
            ? commandCompletions(prefix: token)
            : []

        // Combine: commands first, then file/dir matches not already in commands
        var combined: [String] = cmds
        let cmdSet = Set(cmds)
        if let fr = fileResult {
            for item in fr.items where !cmdSet.contains(item) {
                combined.append(item)
            }
        }
        guard !combined.isEmpty else { return }

        let filePrefix = fileResult?.filePrefix ?? token

        if combined.count == 1 {
            let suffix = String(combined[0].dropFirst(filePrefix.count))
            if !suffix.isEmpty { insertTextIntoSharedInput(tabId: tabId, text: suffix) }
            inputAutocomplete.dismiss()
            filesystemCompletionCwd = nil
        } else {
            // Insert longest-common-prefix suffix, then show hints
            let lcp = longestCommonPrefix(of: combined)
            let lcpSuffix = String(lcp.dropFirst(filePrefix.count))
            if !lcpSuffix.isEmpty { insertTextIntoSharedInput(tabId: tabId, text: lcpSuffix) }
            filesystemCompletionCwd = cwd
            let updatedToken = lastPathToken(in: (sharedInputs[tabId]?.text ?? ""))
            inputAutocomplete.update(items: combined, prefix: updatedToken)
        }
    }

    private func computeFilesystemMatches(token: String, cwd: String)
        -> (items: [String], filePrefix: String)?
    {
        let expanded: String
        if token.hasPrefix("~/") {
            expanded = NSHomeDirectory() + String(token.dropFirst(1))
        } else {
            expanded = token
        }

        let dir: String
        let filePrefix: String
        if expanded.isEmpty {
            // Empty token (e.g. after `ls `): list CWD with no filter
            dir = cwd.hasSuffix("/") ? cwd : cwd + "/"
            filePrefix = ""
        } else if let slashIdx = expanded.lastIndex(of: "/") {
            let afterSlash = expanded.index(after: slashIdx)
            let dirPart = String(expanded[...slashIdx])
            filePrefix = String(expanded[afterSlash...])
            dir = expanded.hasPrefix("/")
                ? dirPart
                : (cwd.hasSuffix("/") ? cwd : cwd + "/") + dirPart
        } else {
            dir = cwd.hasSuffix("/") ? cwd : cwd + "/"
            filePrefix = expanded
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return nil
        }
        let matches: [String] = entries
            .filter { $0.hasPrefix(filePrefix) }
            .sorted()
            .map { entry -> String in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(
                    atPath: (dir as NSString).appendingPathComponent(entry),
                    isDirectory: &isDir)
                return isDir.boolValue ? entry + "/" : entry
            }
        guard !matches.isEmpty else { return nil }
        return (matches, filePrefix)
    }

    private func insertTextIntoSharedInput(tabId: UInt32, text: String) {
        let actor = sessionManager.localIdentity
        let request = SharedInputRequest(actor: actor, kind: .insertText, text: text)
        if canUseHostSharedInput(tabId: tabId) {
            applyAuthoritativeSharedInputRequest(tabId: tabId, request)
        } else if canUsePeerSharedInput(tabId: tabId) {
            applyOptimisticSharedInputRequest(tabId: tabId, request)
            let payload = SharedInputCodec.encode(.request(tabId: tabId, request))
            if tabId == TerminalModel.placeholderTabId {
                sessionManager.sendInputBytes(payload)
            } else {
                sessionManager.sendTabInput(tabId: tabId, data: payload)
            }
        }
    }

    private func lastPathToken(in text: String) -> String {
        text.components(separatedBy: .whitespaces).last ?? ""
    }

    /// True when the token being completed is the command word (no prior
    /// non-whitespace tokens), so we should also search $PATH.
    private func isCommandPosition(in text: String) -> Bool {
        let parts = text.components(separatedBy: .whitespaces)
        return parts.dropLast().allSatisfy { $0.isEmpty }
    }

    /// Executables in $PATH whose name starts with `prefix`, sorted.
    private func commandCompletions(prefix: String) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .components(separatedBy: ":")
        var seen = Set<String>()
        var results: [String] = []
        for dir in pathDirs where !dir.isEmpty {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir)
            else { continue }
            for entry in entries where entry.hasPrefix(prefix) {
                let full = (dir as NSString).appendingPathComponent(entry)
                if FileManager.default.isExecutableFile(atPath: full),
                   seen.insert(entry).inserted {
                    results.append(entry)
                }
            }
        }
        return results.sorted()
    }

    private func longestCommonPrefix(of strings: [String]) -> String {
        guard let first = strings.first else { return "" }
        var prefix = first
        for s in strings.dropFirst() {
            while !s.hasPrefix(prefix) { prefix = String(prefix.dropLast()) }
            if prefix.isEmpty { break }
        }
        return prefix
    }

    private func replaceSharedInputLine(tabId: UInt32, with text: String) {
        guard sharedInputs[tabId]?.isActive == true else { return }
        let actor = sessionManager.localIdentity
        if canUseHostSharedInput(tabId: tabId) {
            var state = sharedInputs[tabId]!
            _ = state.apply(SharedInputRequest(actor: actor, kind: .moveEnd), bumpRevision: false)
            let count = state.textScalars.count
            for _ in 0..<count {
                _ = state.apply(SharedInputRequest(actor: actor, kind: .backspace), bumpRevision: false)
            }
            _ = state.apply(SharedInputRequest(actor: actor, kind: .insertText, text: text), bumpRevision: true)
            sharedInputs[tabId] = state
            syncGridSharedInputOverlay(tabId: tabId)
            broadcastSharedInputSnapshot(tabId: tabId)
        } else if canUsePeerSharedInput(tabId: tabId) {
            var state = sharedInputs[tabId]!
            let moveEnd = SharedInputRequest(actor: actor, kind: .moveEnd)
            _ = state.apply(moveEnd, bumpRevision: false)
            let moveEndPayload = SharedInputCodec.encode(.request(tabId: tabId, moveEnd))
            if tabId == TerminalModel.placeholderTabId {
                sessionManager.sendInputBytes(moveEndPayload)
            } else {
                sessionManager.sendTabInput(tabId: tabId, data: moveEndPayload)
            }
            let count = state.textScalars.count
            for _ in 0..<count {
                let bs = SharedInputRequest(actor: actor, kind: .backspace)
                _ = state.apply(bs, bumpRevision: false)
                let bsPayload = SharedInputCodec.encode(.request(tabId: tabId, bs))
                if tabId == TerminalModel.placeholderTabId {
                    sessionManager.sendInputBytes(bsPayload)
                } else {
                    sessionManager.sendTabInput(tabId: tabId, data: bsPayload)
                }
            }
            let ins = SharedInputRequest(actor: actor, kind: .insertText, text: text)
            _ = state.apply(ins, bumpRevision: false)
            let insPayload = SharedInputCodec.encode(.request(tabId: tabId, ins))
            if tabId == TerminalModel.placeholderTabId {
                sessionManager.sendInputBytes(insPayload)
            } else {
                sessionManager.sendTabInput(tabId: tabId, data: insPayload)
            }
            sharedInputs[tabId] = state
            syncGridSharedInputOverlay(tabId: tabId)
        }
    }

    private func syncAllGridSharedInputOverlays() {
        for tab in tabs {
            syncGridSharedInputOverlay(tabId: tab.id)
        }
    }

    private func resetSharedInputState() {
        for timer in sharedInputPromptTimers.values {
            timer.invalidate()
        }
        for timer in sharedInputTransientOutputTimers.values {
            timer.invalidate()
        }
        sharedInputPromptTimers.removeAll()
        sharedInputTransientOutputTimers.removeAll()
        sharedInputs.removeAll()
        syncAllGridSharedInputOverlays()
        inputAutocomplete.dismiss()
    }

    private func interceptEditorCommand(_ line: String,
                                        fromTabId tabId: UInt32) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/edit ") else { return false }

        let path = String(trimmed.dropFirst(6))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            postTerminalNotice("usage: /edit <path>")
            return true
        }
        guard activeEditor == nil else {
            postTerminalNotice("an editor is already open")
            return true
        }
        guard let url = resolveEditorURL(sessionPath: path) else {
            postTerminalNotice("invalid editor path: \(path)")
            return true
        }

        let snapshot: Data
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url)
        {
            snapshot = data
        } else {
            snapshot = Data()
        }

        sharedInputPromptTimers.removeValue(forKey: tabId)?.invalidate()
        if sharedInputs[tabId]?.isActive == true {
            deactivateSharedInput(tabId: tabId, bumpRevision: true)
            syncGridSharedInputOverlay(tabId: tabId)
            if sessionManager.role == .host, sessionManager.state == .running {
                broadcastSharedInputSnapshot(tabId: tabId)
            }
        }

        let docId = UInt64.random(in: 1...UInt64.max)
        editorSavedRevisions[docId] = 0
        openEditor(docId: docId, path: path, snapshot: snapshot)
        sessionManager.sendEditorOpen(docId: docId, path: path, snapshot: snapshot)
        return true
    }

    private func openEditor(docId: UInt64, path: String, snapshot: Data) {
        let clientId = SessionManager.editorUserID(for: sessionManager.localIdentity)
        let controller = EditorController(
            docId: docId,
            path: path,
            clientId: clientId,
            localCursorColor: nsColor(for: sessionManager.localIdentity),
            snapshot: snapshot,
            sendOp: { [weak self] opBytes in
                self?.sessionManager.sendEditorOp(docId: docId, opBytes: opBytes)
            },
            sendPresence: { [weak self] anchor, selectionAnchor in
                guard let self else { return }
                self.sessionManager.sendEditorPresence(
                    docId: docId,
                    userId: clientId,
                    anchor: anchor,
                    selectionAnchor: selectionAnchor)
            },
            requestSave: { [weak self] in
                guard let self else { return }
                if self.sessionManager.role == .host {
                    self.saveEditor(docId: docId)
                } else {
                    self.sessionManager.sendEditorSave(docId: docId)
                }
            },
            requestClose: { [weak self] in
                guard let self else { return }
                if self.sessionManager.role == .host {
                    self.arbitrateCloseEditor(docId: docId)
                } else {
                    self.sessionManager.sendEditorClose(docId: docId)
                }
            })

        if let rev = editorSavedRevisions[docId] {
            controller.markSaved(rev: rev)
        }

        activeEditor = controller
        syncEditorReadOnlyState()
        controller.broadcastPresenceNow()
    }

    private func saveEditor(docId: UInt64) {
        guard sessionManager.role == .host,
              let editor = activeEditor,
              editor.state.docId == docId
        else {
            return
        }
        guard let url = resolveEditorURL(sessionPath: editor.state.path) else {
            postTerminalNotice("save failed: invalid path")
            return
        }

        do {
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true,
                attributes: nil)
            try editor.textData.write(to: url, options: .atomic)
            let nextRev = (editorSavedRevisions[docId] ?? editor.state.lastSavedRev) &+ 1
            editorSavedRevisions[docId] = nextRev
            editor.markSaved(rev: nextRev)
            sessionManager.sendEditorSaved(docId: docId, rev: nextRev)
            broadcastFileSyncDeltas()
        } catch {
            postTerminalNotice("save failed: \(error.localizedDescription)")
        }
    }

    private func arbitrateCloseEditor(docId: UInt64) {
        guard let editor = activeEditor, editor.state.docId == docId else { return }
        guard editor.state.dirty else {
            closeEditor(docId: docId, broadcast: true)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close collaborative editor?"
        alert.informativeText = "\(editor.state.path) has unsaved changes."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Close Without Saving")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveEditor(docId: docId)
            if activeEditor?.state.dirty == false {
                closeEditor(docId: docId, broadcast: true)
            }
        case .alertSecondButtonReturn:
            closeEditor(docId: docId, broadcast: true)
        default:
            break
        }
    }

    private func closeEditor(docId: UInt64, broadcast: Bool) {
        guard activeEditor?.state.docId == docId else { return }
        if broadcast, sessionManager.role == .host {
            sessionManager.sendEditorClose(docId: docId)
        }
        editorSavedRevisions.removeValue(forKey: docId)
        activeEditor = nil
        if sessionManager.role == .host,
           sessionManager.state == .running,
           !lastLocalCreatorOnlyMode,
           let activeTabId
        {
            activateSharedInputAtCurrentCursor(tabId: activeTabId, broadcast: true)
        }
    }

    private func syncEditorParticipants() {
        guard let editor = activeEditor else { return }
        let live = Set(sessionManager.participants.map(\.identity))
            .union([sessionManager.localIdentity])
        for identity in Array(editor.state.remoteCursors.keys) where !live.contains(identity) {
            editor.removeRemoteUser(identity)
        }
    }

    /// Mirror the SessionManager's access policy onto the active editor.
    /// Hosts always retain edit rights; peers go read-only when the host
    /// has flipped access to view-only.
    private func syncEditorReadOnlyState() {
        guard let editor = activeEditor else { return }
        editor.isReadOnly = sessionManager.role == .peer
            && sessionManager.accessMode == .viewOnly
    }

    private func resolveEditorURL(sessionPath: String) -> URL? {
        SessionPathResolver.resolve(rootPath: rootPath, sessionPath: sessionPath)
    }

    // MARK: file sync

    private func restartFileSyncWatcher() {
        guard sessionManager.role == .host,
              let rootPath
        else {
            fileSyncWatcher = nil
            return
        }
        fileSyncWatcher = FSSyncWatcher(
            rootURL: URL(fileURLWithPath: rootPath, isDirectory: true))
    }

    private func startFileSyncPolling() {
        stopFileSyncPolling()
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              rootPath != nil
        else {
            return
        }

        if fileSyncWatcher == nil {
            restartFileSyncWatcher()
        }

        fileSyncTimer = Timer.scheduledTimer(
            withTimeInterval: 0.75,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.broadcastFileSyncDeltas()
            }
        }
    }

    private func stopFileSyncPolling() {
        fileSyncTimer?.invalidate()
        fileSyncTimer = nil
        fileSyncWatcher = nil
    }

    private func sendFullFileSync(toTransportPeerID peerID: UInt32) {
        guard sessionManager.role == .host,
              sessionManager.state == .running
        else {
            return
        }
        if fileSyncWatcher == nil {
            restartFileSyncWatcher()
        }
        guard let watcher = fileSyncWatcher else { return }
        let update = watcher.fullSync()
        for delta in update.deltas {
            sessionManager.sendFileSyncDelta(delta, toTransportPeerID: peerID)
        }
        if let snapshot = update.snapshot {
            sessionManager.sendFileSyncSnapshot(snapshot, toTransportPeerID: peerID)
        }
    }

    private func broadcastFileSyncDeltas() {
        guard sessionManager.role == .host,
              sessionManager.state == .running
        else {
            return
        }
        // No remote peers → no one to deliver deltas to. Skip the directory
        // walk in `incrementalSync()`; a fresh `restartFileSyncWatcher` (with
        // a `fullSync`) runs when a peer actually joins.
        guard sessionManager.participants.count > 1 else { return }
        if fileSyncWatcher == nil {
            restartFileSyncWatcher()
        }
        guard let update = fileSyncWatcher?.incrementalSync() else { return }
        for delta in update.deltas {
            sessionManager.sendFileSyncDelta(delta)
        }
    }

    private func postTerminalNotice(_ message: String) {
        guard activeEditor == nil else { return }
        let bytes = Array("\r\n[\(message)]\r\n".utf8)
        grid?.feed(bytes)
        if sessionManager.role == .host, sessionManager.state == .running {
            if let activeId = activeTabId {
                sessionManager.sendTabPtyOutput(tabId: activeId, data: Data(bytes))
            }
            if tabs.count <= 1 {
                sessionManager.sendPtyOutput(Data(bytes))
            }
        }
    }

    private func nsColor(for identity: UserIdentity) -> NSColor {
        let packed = color(for: identity)
        return NSColor(
            srgbRed: CGFloat((packed >> 16) & 0xFF) / 255.0,
            green: CGFloat((packed >> 8) & 0xFF) / 255.0,
            blue: CGFloat(packed & 0xFF) / 255.0,
            alpha: 1.0)
    }

    private func color(for identity: UserIdentity) -> UInt32 {
        sessionManager.participants.first(where: { $0.identity == identity })?.color
            ?? (identity == sessionManager.localIdentity
                ? sessionManager.localColor
                : 0x5AC8FA)
    }
}

private enum TabTitleResolver {
    private static let shellNames: Set<String> = [
        "bash", "csh", "dash", "fish", "ksh", "nu",
        "pwsh", "sh", "tcsh", "xonsh", "zsh",
    ]

    static func initialTitle(cwd: String?, sessionRootPath: String?) -> String {
        displayPath(cwd, sessionRootPath: sessionRootPath) ?? "Shell"
    }

    static func resolveTitle(fd: Int32,
                             pid: Int32,
                             sessionRootPath: String?,
                             fallbackTitle: String) -> String
    {
        guard fd >= 0, pid > 0 else { return fallbackTitle }

        let foregroundPID = foregroundProcessGroupLeader(fd: fd) ?? pid
        let processName = executableName(pid: foregroundPID)
            ?? executableName(pid: pid)
            ?? commandName(pid: foregroundPID)
            ?? fallbackTitle
        let cwd = currentDirectoryPath(pid: foregroundPID)
            ?? currentDirectoryPath(pid: pid)
        let pathLabel = displayPath(cwd, sessionRootPath: sessionRootPath)

        if isShellLike(processName) {
            return pathLabel ?? fallbackTitle
        }
        if let pathLabel, !pathLabel.isEmpty {
            return "\(processName) - \(pathLabel)"
        }
        return processName
    }

    private static func foregroundProcessGroupLeader(fd: Int32) -> Int32? {
        var pgid: Int32 = 0
        guard ioctl(fd, UInt(TIOCGPGRP), &pgid) == 0, pgid > 0 else {
            return nil
        }
        return pgid
    }

    private static func executableName(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let rc = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard rc > 0 else { return nil }
        let path = String(cString: buf)
        let name = URL(fileURLWithPath: path).lastPathComponent
        return sanitizedTitle(name)
    }

    private static func commandName(pid: Int32) -> String? {
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        var info = proc_bsdinfo()
        let rc = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard rc == expectedSize else { return nil }
        let name = withUnsafePointer(to: &info.pbi_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) {
                String(cString: $0)
            }
        }
        return sanitizedTitle(name)
    }

    static func cwd(pid: Int32) -> String? {
        currentDirectoryPath(pid: pid)
    }

    private static func currentDirectoryPath(pid: Int32) -> String? {
        let expectedSize = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        var info = proc_vnodepathinfo()
        let rc = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, expectedSize)
        guard rc == expectedSize else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return sanitizedPath(path)
    }

    private static func isShellLike(_ processName: String) -> Bool {
        shellNames.contains(processName.lowercased())
    }

    private static func displayPath(_ path: String?, sessionRootPath: String?) -> String? {
        guard let path = sanitizedPath(path) else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path

        if let sessionRootPath = sanitizedPath(sessionRootPath) {
            let root = URL(fileURLWithPath: sessionRootPath).standardizedFileURL.path
            if normalized == root {
                return root == "/" ? "/" : URL(fileURLWithPath: root).lastPathComponent
            }
            if normalized.hasPrefix(root + "/") {
                return String(normalized.dropFirst(root.count + 1))
            }
        }

        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        if normalized == home {
            return "~"
        }
        if normalized.hasPrefix(home + "/") {
            return "~" + String(normalized.dropFirst(home.count))
        }
        if normalized == "/" {
            return "/"
        }

        let parts = normalized.split(separator: "/")
        if parts.count <= 2 {
            return normalized
        }
        return ".../" + parts.suffix(2).joined(separator: "/")
    }

    private static func sanitizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sanitizedPath(_ value: String?) -> String? {
        guard let value = sanitizedTitle(value) else { return nil }
        return value == "." ? nil : value
    }
}

private struct SnapshotStyle: Equatable {
    static let `default` = SnapshotStyle(fg: 0xCCCCCC,
                                         bg: 0x000000,
                                         attrs: 0)

    var fg: UInt32
    var bg: UInt32
    var attrs: UInt16

    init(fg: UInt32, bg: UInt32, attrs: UInt16) {
        self.fg = fg
        self.bg = bg
        self.attrs = attrs
    }

    init(cell: ct_cell) {
        self.init(fg: cell.fg, bg: cell.bg, attrs: cell.attrs)
    }

    func sgrTransition(from previous: SnapshotStyle) -> String {
        if self == previous { return "" }

        var parts = ["0"]
        if attrs & 0x01 != 0 { parts.append("1") }
        if attrs & 0x02 != 0 { parts.append("3") }
        if attrs & 0x04 != 0 { parts.append("4") }
        if attrs & 0x08 != 0 { parts.append("7") }
        if attrs & 0x10 != 0 { parts.append("2") }
        parts.append("38;2;\((fg >> 16) & 0xFF);\((fg >> 8) & 0xFF);\(fg & 0xFF)")
        parts.append("48;2;\((bg >> 16) & 0xFF);\((bg >> 8) & 0xFF);\(bg & 0xFF)")
        return "\u{1B}[\(parts.joined(separator: ";"))m"
    }
}


/// Floats the autocomplete popover above (or below) the local user's
/// cursor cell in the terminal grid. Reads cursor position from
/// `GridModel.cursors` and infers cell size from the live SwiftUI
/// bounds so it tracks the renderer at any window size.
struct SharedInputAutocompleteOverlay: View {
    @ObservedObject var grid: GridModel
    @ObservedObject var autocomplete: AutocompleteState

    private let estItemHeight: CGFloat = 22
    private let estPadding: CGFloat = 8
    private let estWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            if autocomplete.visible,
               !autocomplete.items.isEmpty,
               let local = grid.cursors.first(where: { $0.isLocal })
            {
                let position = computePosition(geo: geo, local: local)
                AutocompletePopover(state: autocomplete)
                    .frame(width: estWidth, alignment: .leading)
                    .offset(x: position.x, y: position.y)
            }
        }
        .allowsHitTesting(false)
    }

    private func computePosition(geo: GeometryProxy,
                                 local: UserCursor) -> CGPoint
    {
        let cols = max(CGFloat(grid.cols), 1)
        let rows = max(CGFloat(grid.rows), 1)
        let cellW = geo.size.width / cols
        let cellH = geo.size.height / rows
        let caretX = CGFloat(local.col) * cellW
        let caretY = CGFloat(local.row) * cellH

        let estHeight = max(1, CGFloat(autocomplete.items.count)
                            * estItemHeight + estPadding)
        let preferredAbove = caretY - estHeight - 4
        let py = preferredAbove >= 0 ? preferredAbove : caretY + cellH + 4
        let px = min(max(0, caretX),
                     max(0, geo.size.width - estWidth))
        return CGPoint(x: px, y: py)
    }
}

// MARK: - Share sheet helpers

private final class CopyLinkPickerDelegate: NSObject, NSSharingServicePickerDelegate {
    private let url: URL
    init(url: URL) { self.url = url }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        sharingServicesForItems items: [Any],
        proposedSharingServices proposedServices: [NSSharingService]
    ) -> [NSSharingService] {
        let icon = NSImage(systemSymbolName: "link", accessibilityDescription: nil)
            ?? NSImage(named: NSImage.networkName)
            ?? NSImage()
        let copyService = NSSharingService(
            title: "Copy Link",
            image: icon,
            alternateImage: nil
        ) { [weak self] in
            guard let self else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(self.url.absoluteString, forType: .string)
        }
        return [copyService] + proposedServices
    }
}
