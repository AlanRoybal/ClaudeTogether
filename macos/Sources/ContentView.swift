import SwiftUI
import Combine
import CollabTermC

struct ContentView: View {
    @StateObject private var model = TerminalModel()

    var body: some View {
        HSplitView {
            SessionSidebar(model: model)
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)

            ZStack(alignment: .top) {
                if let controller = model.activeEditor {
                    EditorHost(controller: controller)
                        .frame(minWidth: 500, minHeight: 300)
                } else if let grid = model.grid {
                    VStack(spacing: 0) {
                        if model.shouldShowTabStrip {
                            TabStripView(model: model)
                        }
                        MetalTerminalView(
                            grid: grid,
                            onKey: { model.handleKey($0) },
                            onResize: { cols, rows in
                                model.handleResize(cols: cols, rows: rows)
                            },
                            inputEnabled: model.inputEnabled)
                            .frame(minWidth: 500, minHeight: 300)
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
    private var nextTabId: UInt32 = 1

    /// Hide the tab strip when a session has at most one tab so the
    /// single-tab UX is identical to the pre-tabs implementation.
    var shouldShowTabStrip: Bool { tabs.count > 1 }

    /// Host only: edge-detector for creator-only mode. We currently treat the
    /// terminal alternate screen as the signal for "a full-screen app owns the
    /// terminal", which avoids misclassifying normal shell prompts.
    private var lastLocalCreatorOnlyMode: Bool = false
    private var modeTimer: Timer?
    private var sharedInput = SharedInputState()
    private var sharedInputPromptTimer: Timer?
    private var editorSavedRevisions: [UInt64: UInt32] = [:]
    private var fileSyncWatcher: FSSyncWatcher?
    private var fileSyncTimer: Timer?
    private let fileSyncApplier = FSSyncApplier()

    init() {
        coreVersion = ct_version()
        boreBundlePath = Self.findBoreBinaryPath()
        NSLog("[ct] TerminalModel init borePath=%@", boreBundlePath ?? "<nil>")
        // Re-publish child ObservableObject changes.
        sessionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)
        sessionManager.$participants.sink { [weak self] _ in
            guard let self = self else { return }
            self.syncSharedInputParticipants(
                broadcast: self.sessionManager.role == .host)
            self.syncGridSharedInputOverlay()
            self.syncEditorParticipants()
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
        sharedInputPromptTimer?.invalidate()
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

    /// False when the terminal view should drop keystrokes (peer + creator-only mode).
    var inputEnabled: Bool { !showRawBanner }

    // MARK: host session

    func startSession() {
        guard let folder = FolderPicker.pick() else { return }
        rootPath = folder
        fileSyncWatcher = nil
        fileSyncApplier.configure(rootPath: nil)
        // Default to one tab so the single-session UX matches the pre-tabs
        // experience. Subsequent tabs are user-initiated (⌘T / +).
        openNewTab()
        startModeProbe()
        syncGridSharedInputOverlay()
    }

    func endSession() {
        for tab in tabs {
            tab.pty?.terminate()
        }
        tabs.removeAll()
        activeTabId = nil
        nextTabId = 1
        rootPath = nil
        activeEditor = nil
        editorSavedRevisions.removeAll()
        stopSharing()
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
        let title = "Shell \(tabId)"
        guard let tab = makeHostTab(id: tabId, title: title, cwd: folder) else {
            return
        }
        tabs.append(tab)
        activeTabId = tabId
        if sessionManager.state == .running {
            sessionManager.sendTabOpen(tabId: tabId, title: title)
            sessionManager.sendTabFocus(tabId: tabId)
        }
        syncGridSharedInputOverlay()
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

    /// Update which tab is focused. On the host this is the source of truth
    /// and is broadcast via TabFocus; on the peer this is also called from
    /// inbound TabFocus frames (without re-broadcasting).
    func focusTab(id: UInt32) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        activeTabId = id
        if sessionManager.role == .host, sessionManager.state == .running {
            sessionManager.sendTabFocus(tabId: id)
            // Re-paint legacy peers' single-grid view to match the new
            // active tab — they only see content from the bare PtyOutput
            // channel and would otherwise stay stuck on the old tab's
            // last frame.
            broadcastTerminalSnapshot()
        }
        syncGridSharedInputOverlay()
        // Mode/raw-screen state is per-tab; re-probe so the banner/raw-mode
        // signal reflects the new active tab right away.
        probeLocalMode(force: true)
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

    private func makeHostTab(id: UInt32, title: String, cwd: String) -> TabState? {
        // Match the user's current viewport so the new tab's PTY and grid
        // come up at the same size the renderer is about to lay them out at,
        // not the default 80x24.
        let cols = activeTab?.grid.cols ?? 80
        let rows = activeTab?.grid.rows ?? 24
        let pty = PTYSession()
        guard pty.spawn(cwd: cwd, cols: cols, rows: rows) else {
            NSLog("PTY spawn failed for tab %u", id)
            return nil
        }
        guard let grid = GridModel(cols: cols, rows: rows) else {
            NSLog("GridModel init failed for tab %u", id)
            pty.terminate()
            return nil
        }
        // Host: PTY output → feed this tab's grid AND fan out to peers.
        pty.onOutput = { [weak self] bytes in
            guard let self = self else { return }
            guard let tab = self.tabs.first(where: { $0.id == id }) else { return }
            tab.grid.feed(bytes)
            let shouldShare = self.sessionManager.role == .host
                && self.sessionManager.state == .running
            NSLog("[ct] pty->out tab=%u bytes=%d share=%@",
                  id, bytes.count, shouldShare ? "Y" : "N")
            if shouldShare {
                let payload = Data(bytes)
                self.sessionManager.sendTabPtyOutput(tabId: id, data: payload)
                // Backward compat: legacy peers (and our own legacy code path)
                // expect bare PtyOutput frames for the active tab.
                if id == self.activeTabId {
                    self.sessionManager.sendPtyOutput(payload)
                }
            }
            // Mode probe is per-tab via the active grid; only re-probe when
            // output landed on the active tab.
            if id == self.activeTabId {
                self.probeLocalMode()
                if shouldShare {
                    self.handleHostPtyOutput()
                }
            }
        }
        pty.onExit = { [weak self] in
            let msg: [UInt8] = Array("\r\n[process exited]\r\n".utf8)
            self?.tabs.first(where: { $0.id == id })?.grid.feed(msg)
        }
        return TabState(id: id, title: title, pty: pty, grid: grid)
    }

    private func makePeerTab(id: UInt32, title: String) -> TabState? {
        guard let grid = GridModel(cols: 80, rows: 24) else {
            NSLog("GridModel init failed for peer tab %u", id)
            return nil
        }
        return TabState(id: id, title: title, pty: nil, grid: grid)
    }

    // MARK: sharing

    func startSharing() {
        sessionManager.startHost()
        restartFileSyncWatcher()
        startFileSyncPolling()
        if let borePath = boreBundlePath {
            sessionManager.startBoreTunnel(borePath: borePath)
        }
        // Immediately publish our current mode so fresh joiners aren't stuck
        // on the default (.line) assumption.
        probeLocalMode(force: true)
        if sessionManager.state == .running, !lastLocalCreatorOnlyMode {
            activateSharedInputAtCurrentCursor(broadcast: true)
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
        sessionManager.joinPeer(host: host, port: port)
    }

    /// Sentinel id used for the peer-side placeholder tab created on join.
    /// Replaced as soon as the host announces a real tab via TabOpen.
    static let placeholderTabId: UInt32 = .max

    // MARK: keystroke + resize handling

    /// Called by MetalTerminalView when the user types.
    func handleKey(_ bytes: [UInt8]) {
        if isHostSharedLineSession || isPeerSharedLineSession {
            _ = handleSharedInputKey(bytes)
            return
        }
        if handleSharedInputKey(bytes) {
            return
        }
        if let pty = pty {
            // Host (or solo): write directly to local PTY.
            pty.send(bytes)
            return
        }
        // Peer: ship keystrokes to the host for it to write into its PTY.
        // Opaque bytes payload — full CRDT merge is a later refinement.
        if sessionManager.role == .peer, sessionManager.state == .running {
            sessionManager.sendInputBytes(Data(bytes))
        }
    }

    /// Called when the Metal renderer re-measures the terminal grid. We
    /// resize every tab's grid (and host PTY) so output streamed while a
    /// tab is inactive still renders correctly when the user switches to it.
    func handleResize(cols: UInt16, rows: UInt16) {
        for tab in tabs {
            tab.pty?.resize(cols: cols, rows: rows)
            tab.grid.resize(cols: cols, rows: rows)
        }
    }

    // MARK: inbound frames

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
                syncSharedInputParticipants(broadcast: false)
                sessionManager.sendMode(lastLocalCreatorOnlyMode ? .raw : .line)
                // Send current tab list (TabOpen + per-tab snapshot + TabFocus)
                // to the joining peer so it materializes the same tabs we have.
                sendTabSnapshots(toTransportPeerID: peerID)
                // Legacy bare-PtyOutput snapshot for backward compat.
                broadcastTerminalSnapshot()
                broadcastSharedInputSnapshot()
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
            // Replace the placeholder once a real tab announces itself so we
            // don't leave a phantom "Shell" entry around.
            if tabId != TerminalModel.placeholderTabId,
               tabs.count == 1,
               tabs[0].id == TerminalModel.placeholderTabId
            {
                let placeholder = tabs.removeFirst()
                if activeTabId == placeholder.id {
                    activeTabId = nil
                }
            }
            if !tabs.contains(where: { $0.id == tabId }) {
                if let tab = makePeerTab(id: tabId, title: title) {
                    // Match the live grid size so output streamed in via
                    // TabPtyOutput renders at the user's viewport size.
                    if let template = activeTab?.grid {
                        tab.grid.resize(cols: template.cols, rows: template.rows)
                    }
                    tabs.append(tab)
                    if activeTabId == nil {
                        activeTabId = tabId
                    }
                }
            }
        case .tabClose(let tabId):
            guard sessionManager.role == .peer else { return }
            if let idx = tabs.firstIndex(where: { $0.id == tabId }) {
                tabs.remove(at: idx)
            }
            if activeTabId == tabId {
                activeTabId = tabs.first?.id
            }
        case .tabFocus(let tabId):
            guard sessionManager.role == .peer else { return }
            if tabs.contains(where: { $0.id == tabId }) {
                activeTabId = tabId
                syncGridSharedInputOverlay()
            }
        case .tabPtyOutput(let tabId, let data):
            guard sessionManager.role == .peer else { return }
            tabs.first(where: { $0.id == tabId })?.grid.feed(Array(data))
        case .fsDelta(let delta):
            guard sessionManager.role == .peer else { return }
            fileSyncApplier.apply(delta)
        case .fsSnapshot(let entries):
            guard sessionManager.role == .peer else { return }
            fileSyncApplier.reconcile(snapshot: entries)
        case .roster:
            syncSharedInputParticipants(broadcast: false)
            syncGridSharedInputOverlay()
            syncEditorParticipants()
        case .modeChange(let mode):
            if sessionManager.role == .peer, mode == .raw {
                _ = sharedInput.deactivate(bumpRevision: false)
                syncGridSharedInputOverlay()
            }
        case .editorOpen(let docId, let path, let snapshot):
            if let editor = activeEditor, editor.state.docId == docId {
                return
            }
            openEditor(docId: docId, path: path, snapshot: snapshot)
        case .editorOp(let docId, let opBytes):
            guard let editor = activeEditor, editor.state.docId == docId else { return }
            if sessionManager.role == .host {
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
                _ = sharedInput.deactivate(bumpRevision: true)
                syncGridSharedInputOverlay()
                broadcastSharedInputSnapshot()
            } else {
                activateSharedInputAtCurrentCursor(broadcast: true)
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

    private var isHostSharedLineSession: Bool {
        sessionManager.role == .host &&
        sessionManager.state == .running &&
        !lastLocalCreatorOnlyMode
    }

    private var isPeerSharedLineSession: Bool {
        sessionManager.role == .peer &&
        sessionManager.state == .running &&
        sessionManager.remoteMode == .line
    }

    private var canUseHostSharedInput: Bool {
        isHostSharedLineSession &&
        sharedInput.isActive
    }

    private var canUsePeerSharedInput: Bool {
        isPeerSharedLineSession &&
        sharedInput.isActive
    }

    private func handleSharedInputKey(_ bytes: [UInt8]) -> Bool {
        let actor = sessionManager.localIdentity
        guard let request = sharedInputRequest(for: bytes, actor: actor) else {
            return false
        }

        if canUseHostSharedInput {
            applyAuthoritativeSharedInputRequest(request)
            return true
        }
        if canUsePeerSharedInput {
            applyOptimisticSharedInputRequest(request)
            sessionManager.sendInputBytes(
                SharedInputCodec.encode(.request(request)))
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
        case .request(let request):
            guard sessionManager.role == .host else { return }
            applyAuthoritativeSharedInputRequest(request)
        case .snapshot(let snapshot):
            guard sessionManager.role == .peer else { return }
            let wasActive = sharedInput.isActive
            let preservedAnchor = (sharedInput.anchorCol, sharedInput.anchorRow)
            let localAnchor = grid?.term.cursor()
            sharedInput.apply(snapshot)
            if snapshot.isActive {
                if wasActive {
                    sharedInput.overrideAnchor(
                        anchorCol: preservedAnchor.0,
                        anchorRow: preservedAnchor.1)
                } else if let localAnchor {
                    sharedInput.overrideAnchor(
                        anchorCol: localAnchor.x,
                        anchorRow: localAnchor.y)
                }
            }
            syncGridSharedInputOverlay()
        }
    }

    private func applyAuthoritativeSharedInputRequest(_ request: SharedInputRequest) {
        syncSharedInputParticipants(broadcast: false)
        let effect = sharedInput.apply(request, bumpRevision: true)
        syncGridSharedInputOverlay()
        broadcastSharedInputSnapshot()
        handleSharedInputEffect(effect)
    }

    private func applyOptimisticSharedInputRequest(_ request: SharedInputRequest) {
        _ = sharedInput.syncParticipants(
            sharedInputParticipants,
            bumpRevision: false)
        let effect = sharedInput.apply(request, bumpRevision: false)
        syncGridSharedInputOverlay()
        if case .none = effect {
            return
        }
        handleSharedInputEffect(effect)
    }

    private func handleSharedInputEffect(_ effect: SharedInputApplyEffect) {
        switch effect {
        case .none:
            return
        case .commit(let line):
            syncGridSharedInputOverlay()
            if sessionManager.role == .host,
               interceptEditorCommand(line)
            {
                return
            }
            if sessionManager.role == .host, let pty = pty {
                sharedInputPromptTimer?.invalidate()
                let payload = Array(line.utf8) + [0x0D]
                pty.send(payload)
            }
        case .interrupt:
            syncGridSharedInputOverlay()
            if sessionManager.role == .host, let pty = pty {
                sharedInputPromptTimer?.invalidate()
                pty.send([0x03])
            }
        }
    }

    private func handleHostPtyOutput() {
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              !lastLocalCreatorOnlyMode
        else {
            return
        }
        let wasActive = sharedInput.isActive
        if wasActive {
            _ = sharedInput.deactivate(bumpRevision: true)
            syncGridSharedInputOverlay()
            broadcastSharedInputSnapshot()
        }
        sharedInputPromptTimer?.invalidate()
        sharedInputPromptTimer = Timer.scheduledTimer(
            withTimeInterval: 0.35,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.activateSharedInputAtCurrentCursor(broadcast: true)
            }
        }
    }

    private func activateSharedInputAtCurrentCursor(broadcast: Bool) {
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              !lastLocalCreatorOnlyMode,
              let grid
        else {
            return
        }
        syncSharedInputParticipants(broadcast: false)
        let (col, row) = grid.term.cursor()
        let changed = sharedInput.activate(
            anchorCol: col,
            anchorRow: row,
            participants: sharedInputParticipants,
            bumpRevision: true)
        syncGridSharedInputOverlay()
        if broadcast && changed {
            broadcastSharedInputSnapshot()
        } else if broadcast && sharedInput.isActive {
            broadcastSharedInputSnapshot()
        }
    }

    private func syncSharedInputParticipants(broadcast: Bool) {
        let changed = sharedInput.syncParticipants(
            sharedInputParticipants,
            bumpRevision: sessionManager.role == .host)
        if changed {
            syncGridSharedInputOverlay()
            if broadcast && sessionManager.role == .host {
                broadcastSharedInputSnapshot()
            }
        }
    }

    private func broadcastSharedInputSnapshot() {
        guard sessionManager.role == .host,
              sessionManager.state == .running
        else {
            return
        }
        let snapshot = sharedInput.snapshot(participants: sharedInputParticipants)
        sessionManager.broadcast(.inputOp(
            SharedInputCodec.encode(.snapshot(snapshot))))
    }

    private func broadcastTerminalSnapshot() {
        guard sessionManager.role == .host,
              sessionManager.state == .running,
              let grid
        else {
            return
        }

        let bytes = encodeTerminalSnapshot(from: grid)
        guard !bytes.isEmpty else { return }
        sessionManager.sendPtyOutput(Data(bytes))
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
            let bytes = encodeTerminalSnapshot(from: tab.grid)
            if !bytes.isEmpty {
                sessionManager.sendTabPtyOutput(
                    tabId: tab.id,
                    data: Data(bytes),
                    toTransportPeerID: peerID)
            }
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
        guard let grid else { return }
        guard sharedInput.isActive else {
            grid.clearInputOverlay()
            return
        }

        let overlayCursors = sharedInput.snapshot(participants: sharedInputParticipants)
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
            anchorCol: sharedInput.anchorCol,
            anchorRow: sharedInput.anchorRow,
            text: sharedInput.text,
            cursors: overlayCursors)
    }

    private func resetSharedInputState() {
        sharedInputPromptTimer?.invalidate()
        sharedInputPromptTimer = nil
        _ = sharedInput.deactivate(bumpRevision: false)
        syncGridSharedInputOverlay()
    }

    private func interceptEditorCommand(_ line: String) -> Bool {
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

        sharedInputPromptTimer?.invalidate()
        if sharedInput.isActive {
            _ = sharedInput.deactivate(bumpRevision: true)
            syncGridSharedInputOverlay()
            if sessionManager.role == .host, sessionManager.state == .running {
                broadcastSharedInputSnapshot()
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
           !lastLocalCreatorOnlyMode
        {
            activateSharedInputAtCurrentCursor(broadcast: true)
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
            sessionManager.sendPtyOutput(Data(bytes))
            if let activeId = activeTabId {
                sessionManager.sendTabPtyOutput(tabId: activeId, data: Data(bytes))
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
