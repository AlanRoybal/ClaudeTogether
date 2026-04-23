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
                if let grid = model.grid {
                    MetalTerminalView(
                        grid: grid,
                        onKey: { model.handleKey($0) },
                        onResize: { cols, rows in
                            model.handleResize(cols: cols, rows: rows)
                        },
                        inputEnabled: model.inputEnabled)
                        .frame(minWidth: 500, minHeight: 300)
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

                if model.showRawBanner {
                    Text("Creator is running a full-screen app — input is disabled.")
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

@MainActor
final class TerminalModel: ObservableObject {
    /// Single source of truth for rendered cells. Created when a local PTY
    /// spawns (host) or when a peer connects to a shared session (peer).
    @Published var grid: GridModel?
    @Published var pty: PTYSession?
    @Published var rootPath: String?
    @Published var boreBundlePath: String?
    @Published var coreVersion: Int32 = 0

    let sessionManager = SessionManager()

    /// Host only: edge-detector for creator-only mode. We currently treat the
    /// terminal alternate screen as the signal for "a full-screen app owns the
    /// terminal", which avoids misclassifying normal shell prompts.
    private var lastLocalCreatorOnlyMode: Bool = false
    private var modeTimer: Timer?
    private var sharedInput = SharedInputState()
    private var sharedInputPromptTimer: Timer?

    // MARK: FS sync (Phase 4)

    /// Peer-side only: local directory where host's files land.
    @Published var syncRoot: URL?
    /// Peer-side only: count of deltas applied since session start (for UI).
    @Published var syncAppliedCount: Int = 0
    /// Peer-side only: relative paths where we detected an external edit
    /// between our writes. Surfaced as a sidebar warning.
    @Published var externalEditPaths: [String] = []

    private var fsWatcher: FSSyncWatcher?
    private var fsApplier: FSSyncApplier?

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
    }

    private var cancellables = Set<AnyCancellable>()

    deinit {
        modeTimer?.invalidate()
        sharedInputPromptTimer?.invalidate()
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
        let s = PTYSession()
        guard s.spawn(cwd: folder) else {
            NSLog("PTY spawn failed")
            return
        }
        guard let g = GridModel(cols: 80, rows: 24) else {
            NSLog("GridModel init failed")
            s.terminate()
            return
        }
        // Host: PTY output → feed grid AND broadcast to peers.
        s.onOutput = { [weak self] bytes in
            guard let self = self else { return }
            self.grid?.feed(bytes)
            let shouldShare = self.sessionManager.role == .host
                && self.sessionManager.state == .running
            NSLog("[ct] pty->out bytes=%d share=%@",
                  bytes.count, shouldShare ? "Y" : "N")
            if shouldShare {
                self.sessionManager.sendPtyOutput(Data(bytes))
            }
            // Mode may have flipped as a side effect of stty / app launch.
            self.probeLocalMode()
            if shouldShare {
                self.handleHostPtyOutput()
            }
        }
        s.onExit = { [weak self] in
            let msg: [UInt8] = Array("\r\n[process exited]\r\n".utf8)
            self?.grid?.feed(msg)
        }
        rootPath = folder
        pty = s
        grid = g
        startModeProbe()
        syncGridSharedInputOverlay()
    }

    func endSession() {
        pty?.terminate()
        pty = nil
        grid = nil
        rootPath = nil
        stopSharing()
        stopModeProbe()
        resetSharedInputState()
    }

    // MARK: sharing

    func startSharing() {
        sessionManager.startHost()
        if let borePath = boreBundlePath {
            sessionManager.startBoreTunnel(borePath: borePath)
        }
        startFSWatcher()
        // Immediately publish our current mode so fresh joiners aren't stuck
        // on the default (.line) assumption.
        probeLocalMode(force: true)
        if sessionManager.state == .running, !lastLocalCreatorOnlyMode {
            activateSharedInputAtCurrentCursor(broadcast: true)
        }
    }

    func stopSharing() {
        sessionManager.stop()
        resetSharedInputState()
        stopFSWatcher()
        teardownFSApplier()
    }

    // MARK: FS sync wiring

    private func startFSWatcher() {
        guard let rootPath, fsWatcher == nil else { return }
        let watcher = FSSyncWatcher(root: URL(fileURLWithPath: rootPath))
        watcher.onDelta = { [weak self] delta in
            guard let self = self,
                  self.sessionManager.role == .host,
                  self.sessionManager.state == .running
            else { return }
            self.sessionManager.broadcast(.fsDelta(delta))
        }
        watcher.start()
        fsWatcher = watcher
    }

    private func stopFSWatcher() {
        fsWatcher?.stop()
        fsWatcher = nil
    }

    private func setupFSApplier(at root: URL) {
        let applier = FSSyncApplier(root: root)
        applier.onApply = { [weak self] in
            self?.syncAppliedCount += 1
        }
        applier.onExternalEdit = { [weak self] path in
            guard let self = self else { return }
            if !self.externalEditPaths.contains(path) {
                self.externalEditPaths.append(path)
            }
        }
        fsApplier = applier
        syncRoot = root
        syncAppliedCount = 0
        externalEditPaths = []
    }

    private func teardownFSApplier() {
        fsApplier = nil
        syncRoot = nil
        syncAppliedCount = 0
        externalEditPaths = []
    }

    /// Host: on peer Hello, ship the FS snapshot just to that peer. Existing
    /// peers already have the files.
    private func sendFSSnapshot(toPeer peerID: UInt32) {
        guard let watcher = fsWatcher else { return }
        watcher.enumerateSnapshot { delta in
            _ = sessionManager.sendToPeer(peerID, frame: .fsDelta(delta))
        }
    }

    func dismissExternalEditWarnings() {
        externalEditPaths.removeAll()
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

        // Peers pick a local folder to receive host's files into. This
        // directory is owned by us — host writes land here; user edits
        // between deltas trigger an external-edit warning.
        guard let folderStr = FolderPicker.pick(
            prompt: "Choose a local folder to receive files from this session")
        else {
            return
        }
        let syncRootURL = URL(fileURLWithPath: folderStr)

        // Tear down any existing session (local PTY or stale peer) before
        // joining — peers have no PTY.
        endSession()
        sessionManager.stop()

        // Peer path: create a display-only grid fed by inbound .ptyOutput.
        guard let g = GridModel(cols: 80, rows: 24) else {
            NSLog("GridModel init failed")
            return
        }
        grid = g
        rootPath = folderStr
        resetSharedInputState()
        setupFSApplier(at: syncRootURL)
        sessionManager.joinPeer(host: host, port: port)
    }

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

    /// Called when the Metal renderer re-measures the terminal grid.
    func handleResize(cols: UInt16, rows: UInt16) {
        pty?.resize(cols: cols, rows: rows)
        // Peers size their grid to their own viewport; the host-side PTY
        // determines wrap/scroll.
    }

    // MARK: inbound frames

    private func handleInbound(_ frame: Frame, from peerID: UInt32) {
        switch frame {
        case .ptyOutput(let data):
            NSLog("[ct] inbound ptyOutput bytes=%d role=%@ grid=%@",
                  data.count,
                  sessionManager.role == .peer ? "peer" : "host",
                  grid != nil ? "Y" : "N")
            // Peers render the host's PTY stream; hosts ignore (they're the
            // source).
            if sessionManager.role == .peer {
                grid?.feed(Array(data))
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
                broadcastTerminalSnapshot()
                broadcastSharedInputSnapshot()
                sendFSSnapshot(toPeer: peerID)
            } else {
                syncSharedInputParticipants(broadcast: false)
            }
        case .roster:
            syncSharedInputParticipants(broadcast: false)
            syncGridSharedInputOverlay()
        case .modeChange(let mode):
            if sessionManager.role == .peer, mode == .raw {
                _ = sharedInput.deactivate(bumpRevision: false)
                syncGridSharedInputOverlay()
            }
        case .fsDelta(let delta):
            // One-way host → peer. Hosts originate these, so ignoring
            // inbound deltas on the host side is belt-and-suspenders.
            guard sessionManager.role == .peer else { return }
            fsApplier?.apply(delta)
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
