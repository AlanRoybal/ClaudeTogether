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
const runtime = @import("runtime.zig");

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
    write_mutex: runtime.Mutex = .{},
    thread: ?std.Thread = null,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    role: Role,
    /// Host-only: accept loop runs on this thread, pushing new peers.
    listener: ?transport.Listener = null,
    accept_thread: ?std.Thread = null,
    bound_port: u16 = 0,

    mutex: runtime.Mutex = .{},
    peers: std.ArrayList(*Peer) = .empty,
    inbound: std.ArrayList(InboundFrame) = .empty,
    events: std.ArrayList(Event) = .empty,
    next_peer_id: u32 = 1,
    shutting_down: bool = false,

    pub fn initHost(allocator: std.mem.Allocator, port: u16) !*Session {
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .role = .host,
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

        // Shut peer sockets down — reader threads see EOF, exit, and each
        // closes its own socket (the single owner of the fd's lifetime).
        self.mutex.lock();
        for (self.peers.items) |p| {
            p.write_mutex.lock();
            p.conn.shutdownBoth();
            p.write_mutex.unlock();
        }
        self.mutex.unlock();

        for (self.peers.items) |p| {
            if (p.thread) |t| t.join();
            p.conn.close(); // no-op if the reader thread already closed it
        }

        // Drain leftover inbound buffers.
        for (self.inbound.items) |f| self.allocator.free(f.payload);
        self.inbound.deinit(self.allocator);
        self.events.deinit(self.allocator);

        for (self.peers.items) |p| self.allocator.destroy(p);
        self.peers.deinit(self.allocator);

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

    pub fn sendTo(self: *Session, peer_id: u32, payload: []const u8) !void {
        var target: ?*Peer = null;
        self.mutex.lock();
        for (self.peers.items) |p| {
            if (p.id == peer_id) {
                target = p;
                break;
            }
        }
        self.mutex.unlock();

        const p = target orelse return error.UnknownPeer;
        p.write_mutex.lock();
        defer p.write_mutex.unlock();
        if (p.dead) return error.UnknownPeer;
        p.conn.sendFrame(payload) catch |err| {
            self.markDead(p, err);
            return err;
        };
    }

    /// Host only: shut down a peer's TCP connection. The reader thread sees
    /// EOF, calls markDead (peer_disconnected event), and closes the socket.
    pub fn dropPeer(self: *Session, peer_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.peers.items) |p| {
            if (p.id == peer_id) {
                p.conn.shutdownBoth();
                break;
            }
        }
    }

    /// Pop the next inbound frame. Caller must `freeFrame` the payload.
    /// Returns null if none pending.
    pub fn pollFrame(self: *Session) ?InboundFrame {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.inbound.items.len == 0) return null;
        return self.inbound.orderedRemove(0);
    }

    pub const PollCopy = struct {
        peer_id: u32,
        len: usize,
        copied: bool,
    };

    /// Copy the next inbound frame into `out` and dequeue it. If the head
    /// frame is larger than `out`, it STAYS queued and its length is reported
    /// with `copied == false`, so the caller can grow its buffer and retry —
    /// the same frame is returned by the next call. Returns null if empty.
    pub fn pollFrameInto(self: *Session, out: []u8) ?PollCopy {
        self.mutex.lock();
        if (self.inbound.items.len == 0) {
            self.mutex.unlock();
            return null;
        }
        const head = self.inbound.items[0];
        if (head.payload.len > out.len) {
            const r = PollCopy{ .peer_id = head.peer_id, .len = head.payload.len, .copied = false };
            self.mutex.unlock();
            return r;
        }
        const f = self.inbound.orderedRemove(0);
        self.mutex.unlock();
        if (f.payload.len > 0) @memcpy(out[0..f.payload.len], f.payload);
        const r = PollCopy{ .peer_id = f.peer_id, .len = f.payload.len, .copied = true };
        self.allocator.free(f.payload);
        return r;
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

    /// Takes ownership of `conn`: on any error the connection is closed here
    /// and the caller must not touch it again.
    fn addPeer(self: *Session, conn: transport.Connection) !void {
        const p = self.allocator.create(Peer) catch |err| {
            var dead = conn;
            dead.close();
            return err;
        };
        self.mutex.lock();
        p.* = .{
            .id = self.next_peer_id,
            .conn = conn,
        };
        self.next_peer_id += 1;
        self.peers.append(self.allocator, p) catch |err| {
            self.mutex.unlock();
            p.conn.close();
            self.allocator.destroy(p);
            return err;
        };
        self.events.append(self.allocator, .{
            .kind = .peer_connected,
            .peer_id = p.id,
        }) catch {};
        self.mutex.unlock();

        p.thread = std.Thread.spawn(.{}, readerLoop, .{ self, p }) catch |err| {
            // Unregister the peer: with no reader thread nothing services the
            // socket, and leaving it listed would make deinit close a stale
            // fd a second time.
            self.mutex.lock();
            for (self.peers.items, 0..) |it, i| {
                if (it == p) {
                    _ = self.peers.orderedRemove(i);
                    break;
                }
            }
            self.mutex.unlock();
            p.conn.close();
            self.allocator.destroy(p);
            return err;
        };
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
            const conn = self.listener.?.accept() catch return;
            // addPeer owns conn and closes it on failure.
            self.addPeer(conn) catch continue;
        }
    }

    fn readerLoop(self: *Session, p: *Peer) void {
        // Reader exit is the single place a live peer's socket is released.
        // Take the write lock so no writer is mid-send on the fd when it
        // closes; cross-thread teardown uses shutdownBoth() to get us here.
        defer {
            p.write_mutex.lock();
            p.conn.close();
            p.write_mutex.unlock();
        }
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
            const n = p.conn.read(buf[pos..]) catch
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
        self.inbound.append(self.allocator, .{ .peer_id = peer_id, .payload = buf }) catch {
            self.allocator.free(buf);
            return;
        };
    }

    fn markDead(self: *Session, p: *Peer, err: anyerror) void {
        // Errors are soft here — peer goes away, session keeps running.
        _ = &err;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (p.dead) return;
        p.dead = true;
        // Unblock the reader thread (it owns the close); without this a
        // write-side failure would leave the reader parked in read() and the
        // fd held until deinit — host sessions are long-lived, so every
        // disconnect would leak a socket.
        p.conn.shutdownBoth();
        if (!self.shutting_down) {
            self.events.append(self.allocator, .{
                .kind = .peer_disconnected,
                .peer_id = p.id,
            }) catch {};
        }
    }
};

// --- tests ----------------------------------------------------------------

const testing = std.testing;

test "host + peer exchange frames" {
    var host = try Session.initHost(testing.allocator, 0);
    defer host.deinit();

    const port = host.boundPort();
    var peer = try Session.initPeer(testing.allocator, "127.0.0.1", port);
    defer peer.deinit();

    // Wait for host to register the new peer.
    var waited: usize = 0;
    while (host.peerCount() == 0 and waited < 200) : (waited += 1) {
        runtime.sleep(5 * runtime.ns_per_ms);
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
        runtime.sleep(5 * runtime.ns_per_ms);
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
        runtime.sleep(5 * runtime.ns_per_ms);
    } else return error.TestUnexpectedResult;
}

test "host can send to one peer without broadcasting to another" {
    var host = try Session.initHost(testing.allocator, 0);
    defer host.deinit();

    const port = host.boundPort();
    var peer_one = try Session.initPeer(testing.allocator, "127.0.0.1", port);
    defer peer_one.deinit();
    var peer_two = try Session.initPeer(testing.allocator, "127.0.0.1", port);
    defer peer_two.deinit();

    var waited: usize = 0;
    while (host.peerCount() < 2 and waited < 400) : (waited += 1) {
        runtime.sleep(5 * runtime.ns_per_ms);
    }
    try testing.expectEqual(@as(usize, 2), host.peerCount());

    var first_id: ?u32 = null;
    var second_id: ?u32 = null;
    waited = 0;
    while ((first_id == null or second_id == null) and waited < 400) : (waited += 1) {
        if (host.pollEvent()) |ev| {
            if (ev.kind == .peer_connected) {
                if (first_id == null) {
                    first_id = ev.peer_id;
                } else if (second_id == null and ev.peer_id != first_id.?) {
                    second_id = ev.peer_id;
                }
            }
            continue;
        }
        runtime.sleep(5 * runtime.ns_per_ms);
    }

    const target_id = first_id orelse return error.TestUnexpectedResult;
    _ = second_id orelse return error.TestUnexpectedResult;

    try host.sendTo(target_id, "private payload");

    var saw_private_count: usize = 0;
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (peer_one.pollFrame()) |f| {
            defer peer_one.freeFrame(f);
            if (std.mem.eql(u8, f.payload, "private payload")) {
                saw_private_count += 1;
            }
        }
        if (peer_two.pollFrame()) |f| {
            defer peer_two.freeFrame(f);
            if (std.mem.eql(u8, f.payload, "private payload")) {
                saw_private_count += 1;
            }
        }
        if (saw_private_count > 0) break;
        runtime.sleep(5 * runtime.ns_per_ms);
    }

    try testing.expectEqual(@as(usize, 1), saw_private_count);
}
