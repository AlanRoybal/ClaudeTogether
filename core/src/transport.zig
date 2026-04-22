//! TCP listener + client with length-prefixed binary framing. Each frame on
//! the wire is `u32 length (big-endian) | payload`; payload is opaque here
//! and carries a `frame.zig`-encoded message in practice.
//!
//! These are the low-level primitives; the C ABI layer (lib.zig) wraps a
//! worker thread around each `Connection` and feeds a queue that Swift
//! polls via `ct_poll_events`.

const std = @import("std");
const net = std.net;

/// Hard ceiling on a single frame's payload. Guards against malicious or
/// corrupt peers sending huge length prefixes.
pub const max_frame_bytes: u32 = 16 * 1024 * 1024;

pub const Error = error{
    FrameTooLarge,
    PeerClosed,
    ReadFailed,
    WriteFailed,
};

/// Wraps a connected TCP socket with framed I/O. Owns the underlying
/// `net.Stream`; calling `close` is idempotent.
pub const Connection = struct {
    stream: net.Stream,
    closed: bool = false,

    pub fn close(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close();
    }

    /// Send one framed message. Blocking.
    pub fn sendFrame(self: *Connection, payload: []const u8) !void {
        if (payload.len > max_frame_bytes) return error.FrameTooLarge;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
        self.stream.writeAll(&header) catch return error.WriteFailed;
        if (payload.len > 0) {
            self.stream.writeAll(payload) catch return error.WriteFailed;
        }
    }

    /// Read one framed message into `out`. Returns a slice of `out` with the
    /// payload bytes. If the peer closed cleanly before any header bytes are
    /// received, returns `error.PeerClosed` so callers can distinguish EOF
    /// from truncation.
    pub fn recvFrame(self: *Connection, out: []u8) ![]u8 {
        var header: [4]u8 = undefined;
        try readExact(self.stream, &header, true);
        const n = std.mem.readInt(u32, &header, .big);
        if (n > max_frame_bytes) return error.FrameTooLarge;
        if (n > out.len) return error.FrameTooLarge;
        if (n == 0) return out[0..0];
        try readExact(self.stream, out[0..n], false);
        return out[0..n];
    }
};

/// Fully read `buf.len` bytes. `allow_eof_at_start` lets callers distinguish
/// clean EOF (peer closed between frames) from mid-frame truncation.
fn readExact(stream: net.Stream, buf: []u8, allow_eof_at_start: bool) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = stream.read(buf[pos..]) catch return error.ReadFailed;
        if (n == 0) {
            if (pos == 0 and allow_eof_at_start) return error.PeerClosed;
            return error.ReadFailed;
        }
        pos += n;
    }
}

/// Listening server socket. Single-threaded accept loop — callers spawn a
/// thread per accepted connection.
pub const Listener = struct {
    server: net.Server,

    /// Bind to 127.0.0.1:`port`. Pass `0` to let the OS pick; inspect
    /// `boundPort()` afterward.
    pub fn listen(port: u16) !Listener {
        const addr = try net.Address.parseIp4("127.0.0.1", port);
        const server = try addr.listen(.{ .reuse_address = true });
        return .{ .server = server };
    }

    pub fn boundPort(self: *const Listener) u16 {
        return self.server.listen_address.getPort();
    }

    pub fn accept(self: *Listener) !Connection {
        const conn = try self.server.accept();
        return .{ .stream = conn.stream };
    }

    pub fn close(self: *Listener) void {
        self.server.deinit();
    }
};

/// Connect to a `host:port` TCP endpoint. `host` may be an IPv4/IPv6 literal
/// or DNS name (resolved synchronously).
pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Connection {
    const stream = try net.tcpConnectToHost(allocator, host, port);
    return .{ .stream = stream };
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;

test "loopback send + recv single frame" {
    var listener = try Listener.listen(0);
    defer listener.close();
    const port = listener.boundPort();

    const Runner = struct {
        fn clientThread(p: u16, ok: *bool) void {
            var conn = connect(testing.allocator, "127.0.0.1", p) catch return;
            defer conn.close();
            conn.sendFrame("hello") catch return;
            ok.* = true;
        }
    };

    var ok = false;
    const t = try std.Thread.spawn(.{}, Runner.clientThread, .{ port, &ok });

    var server_conn = try listener.accept();
    defer server_conn.close();

    var buf: [64]u8 = undefined;
    const got = try server_conn.recvFrame(&buf);
    try testing.expectEqualStrings("hello", got);

    t.join();
    try testing.expect(ok);
}

test "multiple frames preserve order" {
    var listener = try Listener.listen(0);
    defer listener.close();
    const port = listener.boundPort();

    const Runner = struct {
        fn clientThread(p: u16) void {
            var conn = connect(testing.allocator, "127.0.0.1", p) catch return;
            defer conn.close();
            conn.sendFrame("one") catch return;
            conn.sendFrame("two") catch return;
            conn.sendFrame("three") catch return;
        }
    };

    const t = try std.Thread.spawn(.{}, Runner.clientThread, .{port});
    defer t.join();

    var server_conn = try listener.accept();
    defer server_conn.close();

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("one", try server_conn.recvFrame(&buf));
    try testing.expectEqualStrings("two", try server_conn.recvFrame(&buf));
    try testing.expectEqualStrings("three", try server_conn.recvFrame(&buf));
}

test "peer close surfaces as PeerClosed" {
    var listener = try Listener.listen(0);
    defer listener.close();
    const port = listener.boundPort();

    const Runner = struct {
        fn clientThread(p: u16) void {
            var conn = connect(testing.allocator, "127.0.0.1", p) catch return;
            conn.close(); // close without sending
        }
    };

    const t = try std.Thread.spawn(.{}, Runner.clientThread, .{port});
    defer t.join();

    var server_conn = try listener.accept();
    defer server_conn.close();

    var buf: [64]u8 = undefined;
    try testing.expectError(error.PeerClosed, server_conn.recvFrame(&buf));
}

test "frame too large rejected on send" {
    var listener = try Listener.listen(0);
    defer listener.close();
    const port = listener.boundPort();

    const Runner = struct {
        fn clientThread(p: u16) void {
            var conn = connect(testing.allocator, "127.0.0.1", p) catch return;
            defer conn.close();
        }
    };
    const t = try std.Thread.spawn(.{}, Runner.clientThread, .{port});
    defer t.join();

    var server_conn = try listener.accept();
    defer server_conn.close();

    const huge = try testing.allocator.alloc(u8, max_frame_bytes + 1);
    defer testing.allocator.free(huge);
    try testing.expectError(error.FrameTooLarge, server_conn.sendFrame(huge));
}
