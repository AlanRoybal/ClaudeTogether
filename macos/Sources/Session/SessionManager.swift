import Foundation
import Combine
import CollabTermC

/// Thin Swift wrapper around the C ABI session (`ct_session_*`). Owns the
/// handle, runs a timer-driven poll loop, decodes inbound frames with
/// `FrameCodec`, and exposes role-specific state (`participants`, public URL)
/// for the UI.
///
/// Topology: star. Peers connect to the host; the host is authoritative for
/// the roster and re-broadcasts it whenever someone joins or leaves. Peers
/// read `participants` from the last Roster frame; the host maintains it
/// from Hello frames + lifecycle events.
@MainActor
final class SessionManager: ObservableObject {
    enum Role: Equatable {
        case host
        case peer
    }

    enum State: Equatable {
        case idle
        case starting
        case running
        case disconnected  // peer-only: host went away
        case failed(String)
    }

    /// Who's in the session (host + peers), by user identity. Name, color,
    /// and role come from Hello frames. On peers, this list arrives via
    /// Roster broadcasts from the host.
    struct Participant: Identifiable, Equatable {
        var id: UserIdentity { identity }
        var identity: UserIdentity
        var role: SessionRole
        var name: String
        var color: UInt32
    }

    @Published private(set) var role: Role = .host
    @Published private(set) var state: State = .idle
    @Published private(set) var participants: [Participant] = []
    @Published private(set) var localPort: UInt16 = 0
    @Published private(set) var publicURL: String?
    @Published var lastError: String?

    /// Last mode broadcast by the host. Peers consult this to decide whether
    /// to drop keystrokes and surface a creator-only banner. Defaults to
    /// `.line` so a fresh peer allows input until it hears otherwise.
    @Published private(set) var remoteMode: TermMode = .line

    let localIdentity: UserIdentity
    @Published var localName: String {
        didSet {
            guard oldValue != localName, handle != nil else { return }
            // Local entry mirrors localName; re-announce ourselves.
            updateLocalParticipantField { $0.name = localName }
            sendHello()
            if role == .host { broadcastRoster() }
        }
    }
    var localColor: UInt32

    private var handle: OpaquePointer?
    private var boreHandle: OpaquePointer?
    private var pollTimer: Timer?
    private var borePumpTimer: Timer?
    private var keepAliveTimer: Timer?

    /// Host-only: transport peer id → user identity (filled on Hello).
    private var transportToIdentity: [UInt32: UserIdentity] = [:]

    private static let keepAliveInterval: TimeInterval = 15

    /// Decoded inbound frame + the transport peer id that sent it.
    var onFrame: ((Frame, UInt32) -> Void)?

    init(identity: UserIdentity = .random(),
         name: String? = nil,
         color: UInt32? = nil)
    {
        self.localIdentity = identity
        self.localName = name ?? SessionManager.savedOrDefaultName()
        self.localColor = color ?? Self.defaultColor(for: identity)
    }

    deinit {
        pollTimer?.invalidate()
        borePumpTimer?.invalidate()
        keepAliveTimer?.invalidate()
        if let h = handle { ct_session_free(h) }
        if let b = boreHandle { ct_bore_free(b) }
    }

    // MARK: lifecycle

    func startHost(port: UInt16 = 0) {
        guard handle == nil else { return }
        role = .host
        state = .starting
        guard let h = ct_session_new_host(port) else {
            state = .failed(Self.readLastError()
                ?? "ct_session_new_host failed")
            return
        }
        handle = h
        localPort = ct_session_port(h)
        participants = [Participant(
            identity: localIdentity, role: .host,
            name: localName, color: localColor)]
        state = .running
        startPolling()
        startKeepAlive()
    }

    /// Connect to `host:port`. `host` can be an IP literal or DNS name
    /// (e.g. "bore.pub"). Blocking; returns once the initial TCP handshake
    /// completes or fails.
    func joinPeer(host: String, port: UInt16) {
        guard handle == nil else { return }
        role = .peer
        state = .starting
        let h = host.withCString { cstr in
            ct_session_new_peer(cstr, port)
        }
        guard let h = h else {
            let detail = Self.readLastError() ?? "unknown error"
            state = .failed("\(detail) — host=\(host) port=\(port)")
            return
        }
        handle = h
        participants = [Participant(
            identity: localIdentity, role: .peer,
            name: localName, color: localColor)]
        state = .running
        startPolling()
        startKeepAlive()
        sendHello()  // tell the host who we are; host broadcasts Roster back
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        borePumpTimer?.invalidate(); borePumpTimer = nil
        keepAliveTimer?.invalidate(); keepAliveTimer = nil
        if let h = handle {
            ct_session_free(h)
            handle = nil
        }
        if let b = boreHandle {
            ct_bore_free(b)
            boreHandle = nil
        }
        participants.removeAll()
        transportToIdentity.removeAll()
        localPort = 0
        publicURL = nil
        lastError = nil
        state = .idle
    }

    // MARK: bore tunnel (host only)

    func startBoreTunnel(borePath: String) {
        NSLog("[ct] startBoreTunnel role=%@ handle=%@ port=%d path=%@",
              role == .host ? "host" : "peer",
              boreHandle == nil ? "nil" : "set",
              Int32(localPort),
              borePath)
        guard role == .host, boreHandle == nil, localPort != 0 else {
            NSLog("[ct] startBoreTunnel early return")
            return
        }
        publicURL = nil
        lastError = nil
        guard let b = ct_bore_new() else {
            lastError = "ct_bore_new failed"
            NSLog("[ct] ct_bore_new returned nil")
            return
        }
        boreHandle = b
        let rc = borePath.withCString { cstr in
            ct_bore_start(b, cstr, localPort)
        }
        NSLog("[ct] ct_bore_start rc=%d", rc)
        if rc != 0 {
            lastError = "ct_bore_start failed"
            ct_bore_free(b)
            boreHandle = nil
            return
        }
        startBorePumping()
    }

    // MARK: send helpers

    /// Broadcast to every transport peer (no filtering).
    func broadcast(_ frame: Frame) {
        guard let h = handle else { return }
        let data = FrameCodec.encode(frame)
        let rc = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return ct_session_broadcast(
                h,
                base.assumingMemoryBound(to: UInt8.self),
                data.count)
        }
        if rc != 0 {
            NSLog("[ct] broadcast failed rc=%d bytes=%d", rc, data.count)
        }
    }

    func send(_ frame: Frame, toTransportPeerID peerID: UInt32) {
        guard let h = handle else { return }
        let data = FrameCodec.encode(frame)
        let rc = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return ct_session_send_to(
                h,
                peerID,
                base.assumingMemoryBound(to: UInt8.self),
                data.count)
        }
        if rc != 0 {
            NSLog("[ct] send_to failed peer=%u bytes=%d err=%@",
                  peerID, data.count, Self.readLastError() ?? "<unknown>")
        }
    }

    func sendHello() {
        broadcast(.hello(
            localIdentity,
            role: role == .host ? .host : .peer,
            color: localColor,
            name: localName))
    }

    func sendCursor(col: UInt16, row: UInt16) {
        broadcast(.cursorPos(localIdentity, col: col, row: row))
    }

    /// Host only: fan PTY output out to every peer.
    func sendPtyOutput(_ bytes: Data) {
        guard role == .host, state == .running, !bytes.isEmpty else { return }
        broadcast(.ptyOutput(bytes))
    }

    /// Host only: broadcast a mode transition. Idempotent — callers should
    /// gate with their own edge detector.
    func sendMode(_ mode: TermMode) {
        guard role == .host, state == .running else { return }
        remoteMode = mode
        broadcast(.modeChange(mode))
    }

    /// Peer only: ship keystroke bytes to the host as an opaque `inputOp`
    /// payload. (Full CRDT merge is a future step; Phase 3 uses this as a
    /// "raw-bytes passthrough" so end-to-end shared typing works.)
    func sendInputBytes(_ bytes: Data) {
        guard role == .peer, state == .running, !bytes.isEmpty else { return }
        broadcast(.inputOp(bytes))
    }

    func sendEditorOpen(docId: UInt64, path: String, snapshot: Data) {
        guard role == .host, state == .running else { return }
        broadcast(.editorOpen(docId: docId, path: path, snapshot: snapshot))
    }

    func sendEditorOp(docId: UInt64, opBytes: Data) {
        guard state == .running, !opBytes.isEmpty else { return }
        broadcast(.editorOp(docId: docId, opBytes: opBytes))
    }

    func sendEditorPresence(docId: UInt64,
                            userId: UInt32,
                            anchor: CrdtId?,
                            selectionAnchor: CrdtId?)
    {
        guard state == .running else { return }
        broadcast(.editorPresence(
            docId: docId,
            userId: userId,
            anchor: anchor,
            selectionAnchor: selectionAnchor))
    }

    func sendEditorSave(docId: UInt64) {
        guard state == .running else { return }
        broadcast(.editorSave(docId: docId))
    }

    func sendEditorSaved(docId: UInt64, rev: UInt32) {
        guard role == .host, state == .running else { return }
        broadcast(.editorSaved(docId: docId, rev: rev))
    }

    func sendEditorClose(docId: UInt64) {
        guard state == .running else { return }
        broadcast(.editorClose(docId: docId))
    }

    func sendFileSyncDelta(_ delta: FSSyncDelta, toTransportPeerID peerID: UInt32? = nil) {
        guard role == .host, state == .running else { return }
        let frame = Frame.fsDelta(delta)
        if let peerID {
            send(frame, toTransportPeerID: peerID)
        } else {
            broadcast(frame)
        }
    }

    func sendFileSyncSnapshot(_ entries: [FSSnapshotEntry],
                              toTransportPeerID peerID: UInt32? = nil)
    {
        guard role == .host, state == .running else { return }
        let frame = Frame.fsSnapshot(entries)
        if let peerID {
            send(frame, toTransportPeerID: peerID)
        } else {
            broadcast(frame)
        }
    }

    func sendHeartbeat() {
        guard state == .running else { return }
        broadcast(.heartbeat)
    }

    // MARK: polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
    }

    private func startKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(
            withTimeInterval: Self.keepAliveInterval,
            repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendHeartbeat() }
        }
    }

    private var borePumpTickCount: Int = 0
    private func startBorePumping() {
        NSLog("[ct] startBorePumping scheduling timer")
        borePumpTickCount = 0
        borePumpTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self = self, let b = self.boreHandle else {
                    NSLog("[ct] bore pump timer: no handle, invalidating")
                    t.invalidate()
                    return
                }
                self.borePumpTickCount += 1
                var buf = [UInt8](repeating: 0, count: 256)
                let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                    Int(ct_bore_pump(b, p.baseAddress, p.count))
                }
                if self.borePumpTickCount <= 5 || self.borePumpTickCount % 5 == 0 {
                    NSLog("[ct] bore pump tick=%d rc=%d", self.borePumpTickCount, n)
                }
                if n > 0 {
                    let url = String(bytes: buf.prefix(min(n, buf.count)), encoding: .utf8)
                    self.publicURL = url
                    NSLog("[ct] bore url ready: %@", url ?? "<nil>")
                    t.invalidate()
                } else if n < 0 {
                    // Snapshot whatever bore has printed so we can diagnose.
                    var dbuf = [UInt8](repeating: 0, count: 4096)
                    let dlen = dbuf.withUnsafeMutableBufferPointer { p -> Int in
                        Int(ct_bore_debug(b, p.baseAddress, p.count))
                    }
                    let preview = String(bytes: dbuf.prefix(min(dlen, dbuf.count)),
                                         encoding: .utf8) ?? "<binary>"
                    let trimmed = preview.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.lastError = trimmed.isEmpty
                        ? "bore exited before reporting a public URL"
                        : trimmed
                    NSLog("[ct] bore pump rc=-1 bufferedLen=%d preview=%@",
                          dlen, preview)
                    t.invalidate()
                }
            }
        }
    }

    private func pump() {
        drainEvents()
        drainFrames()
    }

    private func drainEvents() {
        for _ in 0..<32 {
            // Re-check every iteration: an event handler may have called
            // stop() (e.g. peer-side on host disconnect), freeing the handle.
            guard let h = handle else { return }
            var kind: UInt8 = 0
            var peerID: UInt32 = 0
            let r = ct_session_poll_event(h, &kind, &peerID)
            if r == 0 { return }
            switch kind {
            case 0: handleConnected(peerID)
            case 1: handleDisconnected(peerID)
            default: break
            }
        }
    }

    private func drainFrames() {
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        for _ in 0..<64 {
            guard let h = handle else { return }
            var peerID: UInt32 = 0
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Int(ct_session_poll(h, p.baseAddress, p.count, &peerID))
            }
            if n == 0 { return }
            if n > buf.count {
                buf = [UInt8](repeating: 0, count: n)
                continue
            }
            let data = Data(buf.prefix(n))
            do {
                let frame = try FrameCodec.decode(data)
                handleFrame(frame, from: peerID)
            } catch {
                lastError = "decode: \(error)"
            }
        }
    }

    // MARK: event / frame handlers

    private func handleConnected(_ peerID: UInt32) {
        // Host: a peer's TCP just landed; roster updates on their Hello.
        // On the peer side the one "connected" event is the host socket —
        // no state change needed until the host's Roster arrives.
        _ = peerID
    }

    private func handleDisconnected(_ peerID: UInt32) {
        if role == .host {
            if let gone = transportToIdentity.removeValue(forKey: peerID) {
                participants.removeAll { $0.identity == gone }
                broadcastRoster()
            }
        } else {
            // Peer-side: the host dropped. Tear down.
            // (`ct_session_peer_count` would be 0 here too.)
            stop()
            state = .disconnected
        }
    }

    private func handleFrame(_ frame: Frame, from peerID: UInt32) {
        switch frame {
        case .hello(let id, let helloRole, let color, let name):
            if role == .host {
                transportToIdentity[peerID] = id
                upsertParticipant(identity: id, role: helloRole,
                                  name: name, color: color)
                broadcastRoster()
            }
        case .roster(let entries):
            if role == .peer {
                // Peer: replace participants with authoritative list.
                var next: [Participant] = entries.map {
                    Participant(identity: $0.identity,
                                role: $0.role,
                                name: $0.name,
                                color: $0.color)
                }
                // Make sure our own entry is present with our current name.
                if !next.contains(where: { $0.identity == localIdentity }) {
                    next.append(Participant(
                        identity: localIdentity, role: .peer,
                        name: localName, color: localColor))
                }
                if let localEntry = next.first(where: { $0.identity == localIdentity }) {
                    localColor = localEntry.color
                }
                participants = next
            }
        case .modeChange(let m):
            if role == .peer { remoteMode = m }
        case .heartbeat:
            break
        default:
            break
        }
        onFrame?(frame, peerID)
    }

    // MARK: participants / roster

    private func upsertParticipant(identity: UserIdentity,
                                   role helloRole: SessionRole,
                                   name: String,
                                   color: UInt32)
    {
        let resolvedColor = resolvedParticipantColor(
            for: identity,
            preferredColor: color)
        if let i = participants.firstIndex(where: { $0.identity == identity }) {
            participants[i].role = helloRole
            participants[i].name = name
            participants[i].color = resolvedColor
        } else {
            participants.append(Participant(
                identity: identity, role: helloRole,
                name: name, color: resolvedColor))
        }
    }

    private func resolvedParticipantColor(for identity: UserIdentity,
                                          preferredColor: UInt32) -> UInt32
    {
        let usedColors = Set(
            participants
                .filter { $0.identity != identity }
                .map(\.color))
        if !usedColors.contains(preferredColor) {
            return preferredColor
        }

        let palette = Self.participantPalette
        guard !palette.isEmpty else { return preferredColor }

        let start = Int(Self.colorHash(for: identity) % UInt32(palette.count))
        for offset in 0..<palette.count {
            let candidate = palette[(start + offset) % palette.count]
            if !usedColors.contains(candidate) {
                return candidate
            }
        }
        return preferredColor
    }

    private func updateLocalParticipantField(_ mutate: (inout Participant) -> Void) {
        if let i = participants.firstIndex(where: { $0.identity == localIdentity }) {
            mutate(&participants[i])
        }
    }

    /// Host only: broadcast the current full roster to all peers.
    private func broadcastRoster() {
        guard role == .host else { return }
        let entries = participants.map {
            RosterEntry(identity: $0.identity, role: $0.role,
                        color: $0.color, name: $0.name)
        }
        broadcast(.roster(entries))
    }

    // MARK: persisted name

    static let nameDefaultsKey = "ClaudeTogether.displayName"

    /// Read the last-error slot populated by the Zig C ABI. Returns nil
    /// if empty.
    nonisolated static func readLastError() -> String? {
        var buf = [UInt8](repeating: 0, count: 512)
        let n = buf.withUnsafeMutableBufferPointer { p -> Int in
            Int(ct_last_error(p.baseAddress, p.count))
        }
        if n == 0 { return nil }
        let len = min(n, buf.count)
        return String(bytes: buf.prefix(len), encoding: .utf8)
    }

    nonisolated static func savedOrDefaultName() -> String {
        if let s = UserDefaults.standard.string(forKey: nameDefaultsKey),
           !s.isEmpty
        {
            return s
        }
        return NSUserName()
    }

    func persistName() {
        UserDefaults.standard.set(localName, forKey: Self.nameDefaultsKey)
    }

    nonisolated static var participantPalette: [UInt32] {
        [
            0xFF3B30, // red
            0xFFD60A, // yellow
            0x32D74B, // green
            0x00C7BE, // teal
            0x64D2FF, // cyan
            0x0A84FF, // blue
            0x5E5CE6, // indigo
            0xBF5AF2, // purple
            0xFF375F, // pink
            0xFF9F0A, // orange
        ]
    }

    nonisolated static func defaultColor(for identity: UserIdentity) -> UInt32 {
        let palette = participantPalette
        return palette[Int(colorHash(for: identity) % UInt32(palette.count))]
    }

    nonisolated static func editorUserID(for identity: UserIdentity) -> UInt32 {
        let hash = colorHash(for: identity)
        // Reserve 0 for deterministic snapshot-loaded CRDT items so anchor
        // ids from initial file contents are replica-stable across peers.
        return hash == 0 ? 1 : hash
    }

    func participant(forEditorUserID editorUserID: UInt32) -> Participant? {
        participants.first { Self.editorUserID(for: $0.identity) == editorUserID }
    }

    nonisolated private static func colorHash(for identity: UserIdentity) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in identity.bytes {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return hash
    }
}
