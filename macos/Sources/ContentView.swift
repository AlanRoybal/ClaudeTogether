import SwiftUI
import Combine
import Darwin
import CollabTermC

struct ContentView: View {
    @ObservedObject var model: TerminalModel

    var body: some View {
        HSplitView {
            if model.sidebarVisible {
                SessionSidebar(model: model)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            }

            ZStack(alignment: .top) {
                if let controller = model.activeEditor {
                    EditorHost(controller: controller)
                        .frame(minWidth: 500, minHeight: 300)
                } else if !model.tabs.isEmpty {
                    VStack(spacing: 0) {
                        TabStripView(model: model)
                        if let tab = model.activeTabForView {
                            ZStack(alignment: .topLeading) {
                                MetalTerminalView(
                                    grid: tab.grid,
                                    onKey: { bytes in
                                        model.handleKey(bytes, forTabId: tab.id)
                                    },
                                    onResize: { cols, rows in
                                        model.handleResize(cols: cols, rows: rows)
                                    },
                                    inputEnabled: model.inputEnabled,
                                    fontSize: model.fontSize)
                                SharedInputAutocompleteOverlay(
                                    grid: tab.grid,
                                    autocomplete: model.inputAutocomplete)
                            }
                            .frame(minWidth: 500, minHeight: 300)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        Text("ClaudeTogether")
                            .font(.largeTitle)
                            .bold()
                        Text("Host: pick a folder to start a session.\nPeer: join a shared session from the sidebar.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Choose folder…") { model.startSession() }
                            .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if model.activeEditor == nil, model.showRawBanner {
                    Text("Creator is running a full-screen app. Use /edit for shared file editing; terminal input is disabled here.")
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(.top, 8)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 550)
    }
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
}

extension Notification.Name {
    static let ctTabsNew = Notification.Name("ct.tabs.new")
    static let ctTabsClose = Notification.Name("ct.tabs.close")
    static let ctTabsNext = Notification.Name("ct.tabs.next")
    static let ctTabsPrevious = Notification.Name("ct.tabs.previous")
}

@MainActor
final class TerminalModel: ObservableObject {
    /// All open tabs. On the host, each tab owns a PTY; on peers they're
    /// display-only mirrors fed by inbound TabPtyOutput frames.
    @Published var tabs: [TabState] = []
    /// Which tab is currently focused (the one MetalTerminalView renders).
    @Published var activeTabId: UInt32?

    @Published var rootPath: String?
    @Published var boreBundlePath: String?
    @Published var coreVersion: Int32 = 0
    @Published var activeEditor: EditorController?

    /// Persisted command history feeding the shared-input autocomplete.
    /// Captured from `inputCommit` whenever a line dispatches to the PTY.
    let commandHistory = CommandHistory()

    /// Autocomplete state for the shared input line. Updated as the
    /// shared input mutates; consumed by ContentView's overlay.
    let inputAutocomplete = AutocompleteState()

    /// Cap on the number of history suggestions surfaced at once.
    private static let inputAutocompleteMaxItems = 5

    /// Whether the SessionSidebar is visible. Toggled by the View menu
    /// (⌘⇧S). Persisted across launches so the user's choice survives.
    @Published var sidebarVisible: Bool = true {
        didSet {
            guard sidebarVisible != oldValue else { return }
            UserDefaults.standard.set(sidebarVisible, forKey: TerminalModel.sidebarDefaultsKey)
        }
    }

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

    fileprivate static let fontSizeDefaultsKey = "ClaudeTogether.fontSize"
    fileprivate static let sidebarDefaultsKey = "ClaudeTogether.sidebarVisible"

    let sessionManager = SessionManager()

    /// Compatibility shim: returns the active tab's grid. Kept so existing
    /// call sites that read `model.grid` (renderer, sidebar, snapshot helpers)
    /// continue to work after the multi-tab refactor.
    var grid: GridModel? { tabs.first(where: { $0.id == activeTabId })?.grid }
    /// Compatibility shim: returns the active tab's PTY (nil for peer tabs).
    var pty: PTYSession? { tabs.first(where: { $0.id == activeTabId })?.pty }

    private var activeTab: TabState? {
        tabs.first(where: { $0.id == activeTabId })
    }
    var activeTabForView: TabState? { activeTab }
    private var nextTabId: UInt32 = 1

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
    private var participantFocusedTab: [UserIdentity: UInt32] = [:]
    private var editorSavedRevisions: [UInt64: UInt32] = [:]
    private var fileSyncWatcher: FSSyncWatcher?
    private var fileSyncTimer: Timer?
    /// Host-only: newly opened shared tabs request one full snapshot after
    /// their first live PTY output chunk so peers see the initial prompt even
    /// if tab-open/focus beats the shell's first paint.
    private var pendingHostTabInitialSnapshots = Set<UInt32>()
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
        boreBundlePath = Self.findBoreBinaryPath()
        NSLog("[ct] TerminalModel init borePath=%@", boreBundlePath ?? "<nil>")

        // Restore persisted UI prefs without firing the didSet writers.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: TerminalModel.fontSizeDefaultsKey) != nil {
            let raw = CGFloat(defaults.double(forKey: TerminalModel.fontSizeDefaultsKey))
            fontSize = TerminalModel.clampFontSize(raw)
        }
        if defaults.object(forKey: TerminalModel.sidebarDefaultsKey) != nil {
            sidebarVisible = defaults.bool(forKey: TerminalModel.sidebarDefaultsKey)
        }
        // Re-publish child ObservableObject changes.
        sessionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        sessionManager.$participants.sink { [weak self] _ in
            guard let self = self else { return }
            self.syncSharedInputParticipants(
                broadcast: self.sessionManager.role == .host)
            self.syncAllGridSharedInputOverlays()
            self.syncEditorParticipants()
        }.store(in: &cancellables)
        sessionManager.$accessMode.sink { [weak self] _ in
            self?.syncEditorReadOnlyState()
        }.store(in: &cancellables)

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

    private static func findBoreBinaryPath() -> String? {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/bore").path,
            Bundle.main.url(forResource: "bore", withExtension: nil)?.path,
        ].compactMap { $0 }

        let fm = FileManager.default
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) })
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

    /// False when the terminal view should drop keystrokes:
    /// either the host is in creator-only mode (raw) or the host has
    /// flipped access to view-only.
    var inputEnabled: Bool { !showRawBanner && !isViewOnlyPeer }

    // MARK: host session

    func startSession() {
        guard let folder = FolderPicker.pick() else { return }
        rootPath = folder
        fileSyncWatcher = nil
        fileSyncApplier.configure(rootPath: nil)
        // Default to one tab so the single-session UX matches the pre-tabs
        // experience. Subsequent tabs are user-initiated (⌘T / +).
        openNewTab()
        startTitlePolling()
        startModeProbe()
        syncAllGridSharedInputOverlays()
    }

    func endSession() {
        for tab in tabs {
            tab.pty?.terminate()
        }
        tabs.removeAll()
        activeTabId = nil
        nextTabId = 1
        participantFocusedTab.removeAll()
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
        stopSharing()
        stopTitlePolling()
        stopModeProbe()
        stopFileSyncPolling()
        fileSyncApplier.configure(rootPath: nil)
        resetSharedInputState()
    }

    // MARK: tabs

    /// Host: spawn a new PTY at the current rootPath, allocate a tab id,
    /// broadcast TabOpen + TabFocus, and switch to the new tab.
    func openNewTab() {
        guard sessionManager.role == .host else { return }
        guard let folder = rootPath ?? activeTab.flatMap({ _ in rootPath }) else {
            // No session yet — bootstrap one.
            startSession()
            return
        }
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

    /// Update which tab this local user is focused on. Focus is local to
    /// each participant; peers are not forced to follow the host.
    func focusTab(id: UInt32) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        let previousId = activeTabId
        activeTabId = id
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
        handleKey(Array(s.utf8), forTabId: activeTabId)
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

    /// ⌘F — prompt for a query and search the visible terminal grid for
    /// the first occurrence (case-sensitive). Beeps on no match; otherwise
    /// shows an informational alert with the line number.
    func presentFindPrompt() {
        guard let grid = grid else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Find"
        alert.informativeText = "Search the visible terminal."
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "query"
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        alert.addButton(withTitle: "Find")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let query = input.stringValue
        guard !query.isEmpty else { return }

        let lines = visibleTerminalLines(grid: grid)
        for (idx, line) in lines.enumerated() {
            if line.range(of: query) != nil {
                let result = NSAlert()
                result.messageText = "Found"
                result.informativeText = "Match on line \(idx + 1)."
                result.alertStyle = .informational
                result.addButton(withTitle: "OK")
                result.runModal()
                return
            }
        }
        NSSound.beep()
        let miss = NSAlert()
        miss.messageText = "Not found"
        miss.informativeText = "\u{201C}\(query)\u{201D} is not on screen."
        miss.alertStyle = .warning
        miss.addButton(withTitle: "OK")
        miss.runModal()
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
        let size = currentTerminalGridSize()
        startPendingHostTabs(cols: size.cols, rows: size.rows)
        sessionManager.startHost()
        restartFileSyncWatcher()
        startFileSyncPolling()
        if let borePath = boreBundlePath {
            sessionManager.startBoreTunnel(borePath: borePath)
        }
        // Immediately publish our current mode so fresh joiners aren't stuck
        // on the default (.line) assumption.
        probeLocalMode(force: true)
        if let activeTabId {
            recordLocalTabFocus(activeTabId, broadcast: true)
        }
        if sessionManager.state == .running, !lastLocalCreatorOnlyMode {
            for tab in tabs {
                activateSharedInputAtCurrentCursor(tabId: tab.id, broadcast: true)
            }
        }
    }

    func stopSharing() {
        stopFileSyncPolling()
        sessionManager.stop()
        resetSharedInputState()
    }

    func promptJoin() {
        let alert = NSAlert()
        alert.messageText = "Join shared session"
        alert.informativeText = "Enter host:port (e.g. bore.pub:12345 or 127.0.0.1:5555)"
        alert.alertStyle = .informational
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.placeholderString = "host:port"
        alert.accessoryView = input
        alert.addButton(withTitle: "Join")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let raw = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let colon = raw.lastIndex(of: ":"),
              let port = UInt16(raw[raw.index(after: colon)...]),
              !raw[..<colon].isEmpty
        else {
            NSLog("join: malformed \(raw)")
            return
        }
        let host = String(raw[..<colon])
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
        DispatchQueue.main.async { [weak self] in
            self?.sessionManager.joinPeer(host: host, port: port)
        }
    }

    /// Sentinel id used for the peer-side placeholder tab created on join.
    /// Replaced as soon as the host announces a real tab via TabOpen.
    static let placeholderTabId: UInt32 = .max

    // MARK: keystroke + resize handling

    /// Called by MetalTerminalView when the user types. The tab id is
    /// supplied so each per-tab view writes only to its own PTY — no central
    /// "active session" lookup that could leak keystrokes across tabs.
    func handleKey(_ bytes: [UInt8], forTabId tabId: UInt32) {
        guard tabId == activeTabId else { return }
        startPendingHostTabIfNeeded(tabId: tabId)
        // View-only enforcement: the MetalTerminalNSView already gates via
        // `inputEnabled`, but defend in depth so a programmatic call site
        // can't bypass the policy. The host always types locally.
        if isViewOnlyPeer {
            NSSound.beep()
            return
        }
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
        default:
            break
        }
    }

    // MARK: mode probe (host only)

    private func startModeProbe() {
        modeTimer?.invalidate()
        modeTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeLocalMode() }
        }
    }

    private func stopModeProbe() {
        modeTimer?.invalidate()
        modeTimer = nil
        lastLocalCreatorOnlyMode = false
    }

    private func probeLocalMode(force: Bool = false) {
        let creatorOnlyMode = grid?.isUsingAlternateScreen ?? false
        guard force || creatorOnlyMode != lastLocalCreatorOnlyMode else { return }
        lastLocalCreatorOnlyMode = creatorOnlyMode
        // Only propagate if we're currently hosting a shared session.
        if sessionManager.role == .host, sessionManager.state == .running {
            sessionManager.sendMode(creatorOnlyMode ? .raw : .line)
            if creatorOnlyMode {
                if let activeTabId {
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
        return !tab.grid.isUsingAlternateScreen
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
        if (canUseHostSharedInput(tabId: tabId) || canUsePeerSharedInput(tabId: tabId)),
           inputAutocomplete.visible
        {
            switch bytes {
            case [0x09]:
                acceptInputAutocompleteSelection(tabId: tabId)
                return true
            case [0x1B]:
                inputAutocomplete.dismiss()
                return true
            case Array("\u{1B}[A".utf8):
                inputAutocomplete.moveSelection(by: -1)
                return true
            case Array("\u{1B}[B".utf8):
                inputAutocomplete.moveSelection(by: +1)
                return true
            case [0x0D]:
                if inputAutocomplete.userHasNavigated {
                    acceptInputAutocompleteSelection(tabId: tabId)
                }
            default:
                break
            }
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
            let localAnchor = tabs.first(where: { $0.id == tabId })?.grid.term.cursor()
            state.apply(snapshot)
            if snapshot.isActive {
                if wasActive {
                    state.overrideAnchor(
                        anchorCol: preservedAnchor.0,
                        anchorRow: preservedAnchor.1)
                } else if let localAnchor {
                    state.overrideAnchor(
                        anchorCol: localAnchor.x,
                        anchorRow: localAnchor.y)
                }
            }
            sharedInputs[tabId] = state
            syncGridSharedInputOverlay(tabId: tabId)
            refreshInputAutocomplete()
        }
    }

    private func applyAuthoritativeSharedInputRequest(tabId: UInt32,
                                                     _ request: SharedInputRequest)
    {
        syncSharedInputParticipants(tabId: tabId, broadcast: false)
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
              !tab.grid.isUsingAlternateScreen
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
              let grid = tabs.first(where: { $0.id == tabId })?.grid,
              !grid.isUsingAlternateScreen
        else {
            return
        }
        syncSharedInputParticipants(tabId: tabId, broadcast: false)
        let (col, row) = grid.term.cursor()
        var state = sharedInputs[tabId] ?? SharedInputState()
        let changed = state.activate(
            anchorCol: col,
            anchorRow: row,
            participants: sharedInputParticipants(forTabId: tabId),
            bumpRevision: true)
        sharedInputs[tabId] = state
        syncGridSharedInputOverlay(tabId: tabId)
        if broadcast && changed {
            broadcastSharedInputSnapshot(tabId: tabId)
        } else if broadcast && state.isActive {
            broadcastSharedInputSnapshot(tabId: tabId)
        }
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
        let snapshot = state.snapshot(
            participants: sharedInputParticipants(forTabId: tabId))
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
        }
        if let activeId = activeTabId {
            sessionManager.sendTabFocus(
                tabId: activeId,
                toTransportPeerID: peerID)
        }
    }

    private func encodeTerminalSnapshot(from grid: GridModel) -> [UInt8] {
        let snapshot = grid.snapshot()
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
        guard let tabId = activeTabId,
              (isHostSharedLineSession(tabId: tabId) || isPeerSharedLineSession(tabId: tabId)),
              sharedInputs[tabId]?.isActive == true
        else {
            inputAutocomplete.dismiss()
            return
        }
        let text = sharedInputs[tabId]?.text ?? ""
        guard !text.isEmpty else {
            inputAutocomplete.dismiss()
            return
        }
        let matches = FuzzyMatcher.rank(
            candidates: commandHistory.entries,
            needle: text,
            recencyRank: commandHistory.recencyRank,
            limit: Self.inputAutocompleteMaxItems)
        let filtered = matches.filter { $0 != text }
        if filtered.isEmpty {
            inputAutocomplete.dismiss()
            return
        }
        inputAutocomplete.update(items: filtered, prefix: text)
    }

    private func acceptInputAutocompleteSelection(tabId: UInt32) {
        guard let suggestion = inputAutocomplete.currentSelection else { return }
        replaceSharedInputLine(tabId: tabId, with: suggestion)
        inputAutocomplete.dismiss()
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
            try editor.snapshotData.write(to: url, options: .atomic)
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
