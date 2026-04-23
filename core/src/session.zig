//! Session runtime. Owns the listening socket (host) or outbound socket
//! (peer), spawns one reader thread per peer connection, and feeds inbound
//! frames into a single-consumer queue that the Swift side drains via
//! `ct_session_poll`.
//!
//! The session is intentionally "dumb" about the protocol — it just moves
//! opaque frame-length blobs in and out. `frame.zig` encoding/decoding is
//! the caller's job (both Zig unit tests and the Swift bridge).

const std = @import("std");
const transport = @import("transport.zig");

const InboundFrame = struct {
    /// Monotonic peer id assigned when the connection was accepted/opened.
    /// 0 is reserved for "self" / control messages.
    peer_id: u32,
    payload: []u8, // heap-allocated, owned by Session
};

pub const EventKind = enum(u8) {
    peer_connected = 0,
    peer_disconnected = 1,
};

pub const Event = struct {
    kind: EventKind,
    peer_id: u32,
};

pub const Role = enum(u8) {
    host = 0,
    peer = 1,
};

/// Per-connection state shared between the reader thread and the session.
const Peer = struct {
    id: u32,
    conn: transport.Connection,
    /// Set by the reader thread on exit; checked when the session wants to
    /// reap dead peers. Written under `Session.mutex`.
    dead: bool = false,
    /// Protects concurrent writes from the session thread and any
    /// broadcast() callers.
    write_mutex: std.Thread.Mutex = .{},
    thread: ?std.Thread = null,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    role: Role,
    /// Host-only: accept loop runs on this thread, pushing new peers.
    listener: ?transport.Listener = null,
    accept_thread: ?std.Thread = null,
    bound_port: u16 = 0,

    mutex: std.Thread.Mutex = .{},
    queue_cond: std.Thread.Condition = .{},
    peers: std.ArrayList(*Peer),
    inbound: std.ArrayList(InboundFrame),
    events: std.ArrayList(Event),
    next_peer_id: u32 = 1,
    shutting_down: bool = false,

    pub fn initHost(allocator: std.mem.Allocator, port: u16) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .role = .host,
            .peers = std.ArrayList(*Peer).init(allocator),
            .inbound = std.ArrayList(InboundFrame).init(allocator),
            .events = std.ArrayList(Event).init(allocator),
        };

        self.listener = try transport.Listener.listen(port);
        self.bound_port = self.listener.?.boundPort();

        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    pub fn initPeer(
        allocator: std.mem.Allocator,
        host: []const u8,
        port: u16,
    ) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .role = .peer,
            .peers = std.ArrayList(*Peer).init(allocator),
            .inbound = std.ArrayList(InboundFrame).init(allocator),
            .events = std.ArrayList(Event).init(allocator),
        };

        const conn = try transport.connect(allocator, host, port);
        try self.addPeer(conn);
        return self;
    }

    pub fn deinit(self: *Session) void {
        self.mutex.lock();
        self.shutting_down = true;
        self.mutex.unlock();

        if (self.listener) |*l| {
            l.close();
        }
        if (self.accept_thread) |t| t.join();

        // Close peer sockets — reader threads will exit on read error.
        self.mutex.lock();
        for (self.peers.items) |p| p.conn.close();
        self.mutex.unlock();

        for (self.peers.items) |p| {
            if (p.thread) |t| t.join();
        }

        // Drain leftover inbound buffers.
        for (self.inbound.items) |f| self.allocator.free(f.payload);
        self.inbound.deinit();
        self.events.deinit();

        for (self.peers.items) |p| self.allocator.destroy(p);
        self.peers.deinit();

        self.allocator.destroy(self);
    }

    pub fn boundPort(self: *const Session) u16 {
        return self.bound_port;
    }

    pub fn peerCount(self: *Session) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.peers.items.len;
    }

    /// Send `payload` as one framed message to every connected peer.
    /// Partial failures (one peer dead) are logged but do not fail the call.
    pub fn broadcast(self: *Session, payload: []const u8) !void {
        // Snapshot peer list under the lock; writes happen without holding
        // the session mutex (per-peer write_mutex serializes each socket).
        self.mutex.lock();
        const snapshot = try self.allocator.alloc(*Peer, self.peers.items.len);
        @memcpy(snapshot, self.peers.items);
        self.mutex.unlock();
        defer self.allocator.free(snapshot);

        for (snapshot) |p| {
            p.write_mutex.lock();
            defer p.write_mutex.unlock();
            if (p.dead) continue;
            p.conn.sendFrame(payload) catch |err| {
                self.markDead(p, err);
            };
        }
    }

    pub const SendError = error{
        PeerNotFound,
        PeerGone,
        FrameTooLarge,
        WriteFailed,
    };

    /// Send `payload` to exactly one peer by transport id. Returns an error
    /// instead of silently dropping so callers (e.g. FS snapshot delivery)
    /// can decide whether to retry.
    pub fn sendTo(self: *Session, peer_id: u32, payload: []const u8) SendError!void {
        self.mutex.lock();
        var target: ?*Peer = null;
        for (self.peers.items) |p| {
            if (p.id == peer_id) {
                target = p;
                break;
            }
        }
        self.mutex.unlock();

        const p = target orelse return error.PeerNotFound;
        p.write_mutex.lock();
        defer p.write_mutex.unlock();
        if (p.dead) return error.PeerGone;
        p.conn.sendFrame(payload) catch |err| {
            self.markDead(p, err);
            return switch (err) {
                error.FrameTooLarge => error.FrameTooLarge,
                else => error.WriteFailed,
            };
        };
    }

    /// Pop the next inbound frame. Caller must `freeFrame` the payload.
    /// Returns null if none pending.
    pub fn pollFrame(self: *Session) ?InboundFrame {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.inbound.items.len == 0) return null;
        return self.inbound.orderedRemove(0);
    }

    pub fn freeFrame(self: *Session, f: InboundFrame) void {
        self.allocator.free(f.payload);
    }

    /// Pop the next lifecycle event (peer_connected / peer_disconnected).
    /// Returns null if none pending.
    pub fn pollEvent(self: *Session) ?Event {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.events.items.len == 0) return null;
        return self.events.orderedRemove(0);
    }

    // --- internals --------------------------------------------------------

    fn addPeer(self: *Session, conn: transport.Connection) !void {
        const p = try self.allocator.create(Peer);
        self.mutex.lock();
        p.* = .{
            .id = self.next_peer_id,
            .conn = conn,
        };
        self.next_peer_id += 1;
        try self.peers.append(p);
        const peer_id = p.id;
        self.events.append(.{
            .kind = .peer_connected,
            .peer_id = peer_id,
        }) catch {};
        self.mutex.unlock();

        p.thread = try std.Thread.spawn(.{}, readerLoop, .{ self, p });
    }

    fn acceptLoop(self: *Session) void {
        while (true) {
            self.mutex.lock();
            const stopping = self.shutting_down;
            self.mutex.unlock();
            if (stopping) return;

            // accept() is blocking; the listener.close() on deinit unblocks
            // it with an error which we treat as shutdown.
            if (self.listener == null) return;
            const conn = self.listener.?.server.accept() catch return;
            const wrapped = transport.Connection{ .stream = conn.stream };
            self.addPeer(wrapped) catch {
                wrapped.stream.close();
                continue;
            };
        }
    }

    fn readerLoop(self: *Session, p: *Peer) void {
        // Conservative per-read buffer. Bounded by transport.max_frame_bytes
        // for correctness; actual allocations are sized to the header.
        var hdr: [4]u8 = undefined;
        while (true) {
            // Inline copy of recvFrame so we can allocate sized to the
            // header instead of preallocating max_frame_bytes.
            self.readInto(p, &hdr, true) catch |err| {
                self.markDead(p, err);
                return;
            };
            const n = std.mem.readInt(u32, &hdr, .big);
            if (n > transport.max_frame_bytes) {
                self.markDead(p, error.FrameTooLarge);
                return;
            }
            const buf = self.allocator.alloc(u8, n) catch {
                self.markDead(p, error.OutOfMemory);
                return;
            };
            if (n > 0) {
                self.readInto(p, buf, false) catch |err| {
                    self.allocator.free(buf);
                    self.markDead(p, err);
                    return;
                };
            }
            self.pushInbound(p.id, buf);
        }
    }

    fn readInto(
        self: *Session,
        p: *Peer,
        buf: []u8,
        allow_eof: bool,
    ) !void {
        _ = self;
        var pos: usize = 0;
        while (pos < buf.len) {
            const n = p.conn.stream.read(buf[pos..]) catch
                return error.ReadFailed;
            if (n == 0) {
                if (pos == 0 and allow_eof) return error.PeerClosed;
                return error.ReadFailed;
            }
            pos += n;
        }
    }

    fn pushInbound(self: *Session, peer_id: u32, buf: []u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutting_down) {
            self.allocator.free(buf);
            return;
        }
        self.inbound.append(.{ .peer_id = peer_id, .payload = buf }) catch {
            self.allocator.free(buf);
            return;
        };
        self.queue_cond.signal();
    }

    fn markDead(self: *Session, p: *Peer, err: anyerror) void {
        // Errors are soft here — peer goes away, session keeps running.
        _ = &err;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (p.dead) return;
        p.dead = true;
        if (!self.shutting_down) {
            self.events.append(.{
                .kind = .peer_disconnected,
                .peer_id = p.id,
            }) catch {};
        }
    }
};

// --- tests ----------------------------------------------------------------

const testing = std.testing;

test "sendTo delivers to a single peer by id" {
    var host = try Session.initHost(testing.allocator, 0);
    defer host.deinit();

    const port = host.boundPort();
    var peer_a = try Session.initPeer(testing.allocator, "127.0.0.1", port);
    defer peer_a.deinit();
    var peer_b = try Session.initPeer(testing.allocator, "127.0.0.1", port);
    defer peer_b.deinit();

    // Wait until both peers show up on the host.
    var waited: usize = 0;
    while (host.peerCount() < 2 and waited < 400) : (waited += 1) {
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expect(host.peerCount() == 2);

    // Peer ids are assigned in accept order starting at 1.
    try host.sendTo(1, "only-to-one");

    var got_a: bool = false;
    var got_b: bool = false;
    var attempts: usize = 0;
    while (attempts < 200 and !got_a) : (attempts += 1) {
        if (peer_a.pollFrame()) |f| {
            defer peer_a.freeFrame(f);
            try testing.expectEqualStrings("only-to-one", f.payload);
            got_a = true;
            break;
        }
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expect(got_a);

    // Peer B must NOT have received the targeted frame. Drain for a bit and
    // confirm the queue stays empty.
    attempts = 0;
    while (attempts < 20) : (attempts += 1) {
        if (peer_b.pollFrame()) |f| {
            defer peer_b.freeFrame(f);
            got_b = true;
            break;
        }
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expect(!got_b);

    try testing.expectError(error.PeerNotFound, host.sendTo(999, "nobody"));
}

test "host + peer exchange frames" {
    var host = try Session.initHost(testing.allocator, 0);
    defer host.deinit();

    const port = host.boundPort();
    var peer = try Session.initPeer(testing.allocator, "127.0.0.1", port);
    defer peer.deinit();

    // Wait for host to register the new peer.
    var waited: usize = 0;
    while (host.peerCount() == 0 and waited < 200) : (waited += 1) {
        std.time.sleep(5 * std.time.ns_per_ms);
    }
    try testing.expect(host.peerCount() >= 1);

    // host -> peer
    try host.broadcast("hello from host");
    // Spin until peer sees it.
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (peer.pollFrame()) |f| {
            defer peer.freeFrame(f);
            try testing.expectEqualStrings("hello from host", f.payload);
            break;
        }
        std.time.sleep(5 * std.time.ns_per_ms);
    } else return error.TestUnexpectedResult;

    // peer -> host
    try peer.broadcast("hello from peer");
    attempts = 0;
    while (attempts < 200) : (attempts += 1) {
        if (host.pollFrame()) |f| {
            defer host.freeFrame(f);
            try testing.expectEqualStrings("hello from peer", f.payload);
            break;
        }
        std.time.sleep(5 * std.time.ns_per_ms);
    } else return error.TestUnexpectedResult;
}
