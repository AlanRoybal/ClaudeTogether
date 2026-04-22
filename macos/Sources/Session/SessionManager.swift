import Foundation
import Combine
import CollabTermC

/// Thin Swift wrapper around the C ABI session (`ct_session_*`). Owns the
/// handle, runs a timer-driven poll loop, decodes inbound frames with
/// `FrameCodec`, and exposes role-specific state (`peers`, public URL) for
/// the UI.
///
/// Scope: this is the Phase 3 plumbing layer — it moves frames in and out
/// and tracks connected peers. CRDT input-line semantics and PTY-output
/// replication live in future work that hooks onto the `onFrame` callback.
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
        case failed(String)
    }

    struct Peer: Identifiable, Equatable {
        let id: UInt32       // transport-level peer id from core
        var identity: UserIdentity?
        var name: String
        var color: UInt32
    }

    /// Set by `startHost` / `joinPeer`; `.host` while idle so the sidebar
    /// defaults its UI toward "Start shared session".
    @Published private(set) var role: Role = .host
    @Published private(set) var state: State = .idle
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var localPort: UInt16 = 0
    @Published private(set) var publicURL: String?
    @Published var lastError: String?

    let localIdentity: UserIdentity
    var localName: String
    var localColor: UInt32

    private var handle: OpaquePointer?
    private var boreHandle: OpaquePointer?
    private var pollTimer: Timer?
    private var borePumpTimer: Timer?

    /// Decoded inbound frame + the transport peer id that sent it.
    var onFrame: ((Frame, UInt32) -> Void)?

    init(identity: UserIdentity = .random(),
         name: String = NSUserName(),
         color: UInt32 = 0xFFFFFF)
    {
        self.localIdentity = identity
        self.localName = name
        self.localColor = color
    }

    deinit {
        pollTimer?.invalidate()
        borePumpTimer?.invalidate()
        if let h = handle { ct_session_free(h) }
        if let b = boreHandle { ct_bore_free(b) }
    }

    // MARK: lifecycle

    func startHost(port: UInt16 = 0) {
        guard handle == nil else { return }
        role = .host
        state = .starting
        guard let h = ct_session_new_host(port) else {
            state = .failed("ct_session_new_host failed")
            return
        }
        handle = h
        localPort = ct_session_port(h)
        state = .running
        startPolling()
        sendHello()
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
            state = .failed("ct_session_new_peer failed (\(host):\(port))")
            return
        }
        handle = h
        state = .running
        startPolling()
        sendHello()
    }

    func stop() {
        pollTimer?.invalidate(); pollTimer = nil
        borePumpTimer?.invalidate(); borePumpTimer = nil
        if let h = handle {
            ct_session_free(h)
            handle = nil
        }
        if let b = boreHandle {
            ct_bore_free(b)
            boreHandle = nil
        }
        peers.removeAll()
        localPort = 0
        publicURL = nil
        state = .idle
    }

    // MARK: bore tunnel (host only)

    /// Start the bundled bore binary forwarding `localPort` to `bore.pub`.
    /// Once bore prints the public URL we surface it on `publicURL`.
    func startBoreTunnel(borePath: String) {
        guard role == .host, boreHandle == nil, localPort != 0 else { return }
        guard let b = ct_bore_new() else {
            lastError = "ct_bore_new failed"
            return
        }
        boreHandle = b
        let rc = borePath.withCString { cstr in
            ct_bore_start(b, cstr, localPort)
        }
        if rc != 0 {
            lastError = "ct_bore_start failed"
            ct_bore_free(b)
            boreHandle = nil
            return
        }
        startBorePumping()
    }

    // MARK: send helpers

    func broadcast(_ frame: Frame) {
        guard let h = handle else { return }
        let data = FrameCodec.encode(frame)
        _ = data.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress else { return -1 }
            return ct_session_broadcast(
                h,
                base.assumingMemoryBound(to: UInt8.self),
                data.count)
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

    // MARK: polling

    private func startPolling() {
        // 16ms ~= 60Hz; session work is cheap (memcpy out of a queue).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pumpInbound() }
        }
    }

    private func startBorePumping() {
        borePumpTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self = self, let b = self.boreHandle else {
                    t.invalidate()
                    return
                }
                var buf = [UInt8](repeating: 0, count: 256)
                let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                    Int(ct_bore_pump(b, p.baseAddress, p.count))
                }
                if n > 0 {
                    let url = String(bytes: buf.prefix(min(n, buf.count)), encoding: .utf8)
                    self.publicURL = url
                    t.invalidate()
                }
            }
        }
    }

    private func pumpInbound() {
        guard let h = handle else { return }
        // Cap per-tick drain so a flood can't stall the main thread.
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        for _ in 0..<64 {
            var peerID: UInt32 = 0
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Int(ct_session_poll(h, p.baseAddress, p.count, &peerID))
            }
            if n == 0 { break }
            if n > buf.count {
                // Oversized frame — extend buffer and retry next tick (rare).
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
        // Refresh reported peer count (session-level transport peers).
        let count = ct_session_peer_count(h)
        if UInt32(peers.count) != count {
            // Cheap reconciliation: ensure a placeholder Peer exists per id.
            // Hellos fill in name/color.
            let knownIds = Set(peers.map(\.id))
            // We don't have a way to enumerate ids without a dedicated call,
            // so we rely on hello frames to add them. If transport-count
            // drops, trim unknown peers whose id is beyond count.
            _ = knownIds
            _ = count
        }
    }

    private func handleFrame(_ frame: Frame, from peerID: UInt32) {
        switch frame {
        case .hello(let id, _, let color, let name):
            upsertPeer(transportID: peerID, identity: id,
                       name: name, color: color)
        default:
            break
        }
        onFrame?(frame, peerID)
    }

    private func upsertPeer(transportID: UInt32, identity: UserIdentity,
                            name: String, color: UInt32)
    {
        if let i = peers.firstIndex(where: { $0.id == transportID }) {
            peers[i].identity = identity
            peers[i].name = name
            peers[i].color = color
        } else {
            peers.append(Peer(id: transportID,
                              identity: identity,
                              name: name,
                              color: color))
        }
    }
}
