//! TCP listener + client with length-prefixed binary framing. Each frame on
//! the wire is `u32 length (big-endian) | payload`; payload is opaque here
//! and carries a `frame.zig`-encoded message in practice.
//!
//! Implemented directly on the libc BSD socket API. Zig 0.16 removed the
//! `std.posix` socket wrappers and moved blocking networking under the new
//! `std.Io` interface; we link libc anyway (for forkpty etc.) so calling the
//! socket syscalls directly keeps the exact blocking-read framing semantics
//! the session layer relies on, with no `Io` plumbing.

const std = @import("std");
const runtime = @import("runtime.zig");

const c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("netinet/tcp.h");
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("unistd.h");
    @cInclude("string.h");
});

/// Hard ceiling on a single frame's payload. Guards against malicious or
/// corrupt peers sending huge length prefixes.
pub const max_frame_bytes: u32 = 16 * 1024 * 1024;

pub const Error = error{
    FrameTooLarge,
    PeerClosed,
    ReadFailed,
    WriteFailed,
    SocketFailed,
    BindFailed,
    ListenFailed,
    ConnectFailed,
};

/// Wraps a connected TCP socket with framed I/O. Owns the underlying fd;
/// calling `close` is idempotent.
pub const Connection = struct {
    fd: c_int,
    closed: bool = false,

    pub fn close(self: *Connection) void {
        if (self.closed) return;
        self.closed = true;
        _ = c.close(self.fd);
    }

    /// Raw read of up to `buf.len` bytes. Returns the number read (0 = EOF).
    pub fn read(self: *Connection, buf: []u8) !usize {
        const n = c.read(self.fd, buf.ptr, buf.len);
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }

    /// Send one framed message. Blocking.
    pub fn sendFrame(self: *Connection, payload: []const u8) !void {
        if (payload.len > max_frame_bytes) return error.FrameTooLarge;
        var header: [4]u8 = undefined;
        std.mem.writeInt(u32, &header, @intCast(payload.len), .big);
        try writeAll(self.fd, &header);
        if (payload.len > 0) {
            try writeAll(self.fd, payload);
        }
    }

    /// Read one framed message into `out`. Returns a slice of `out` with the
    /// payload bytes. If the peer closed cleanly before any header bytes are
    /// received, returns `error.PeerClosed` so callers can distinguish EOF
    /// from truncation.
    pub fn recvFrame(self: *Connection, out: []u8) ![]u8 {
        var header: [4]u8 = undefined;
        try readExact(self.fd, &header, true);
        const n = std.mem.readInt(u32, &header, .big);
        if (n > max_frame_bytes) return error.FrameTooLarge;
        if (n > out.len) return error.FrameTooLarge;
        if (n == 0) return out[0..0];
        try readExact(self.fd, out[0..n], false);
        return out[0..n];
    }
};

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return error.WriteFailed;
        off += @intCast(n);
    }
}

/// Fully read `buf.len` bytes. `allow_eof_at_start` lets callers distinguish
/// clean EOF (peer closed between frames) from mid-frame truncation.
fn readExact(fd: c_int, buf: []u8, allow_eof_at_start: bool) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = c.read(fd, buf.ptr + pos, buf.len - pos);
        if (n < 0) return error.ReadFailed;
        if (n == 0) {
            if (pos == 0 and allow_eof_at_start) return error.PeerClosed;
            return error.ReadFailed;
        }
        pos += @intCast(n);
    }
}

/// Listening server socket. Single-threaded accept loop — callers spawn a
/// thread per accepted connection.
pub const Listener = struct {
    fd: c_int,

    /// Bind to 127.0.0.1:`port`. Pass `0` to let the OS pick; inspect
    /// `boundPort()` afterward.
    pub fn listen(port: u16) !Listener {
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);

        var one: c_int = 1;
        _ = c.setsockopt(
            fd,
            c.SOL_SOCKET,
            c.SO_REUSEADDR,
            &one,
            @sizeOf(c_int),
        );

        var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
        addr.sin_family = c.AF_INET;
        addr.sin_port = c.htons(port);
        _ = c.inet_pton(c.AF_INET, "127.0.0.1", &addr.sin_addr);

        if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.struct_sockaddr_in)) != 0)
            return error.BindFailed;
        if (c.listen(fd, 128) != 0) return error.ListenFailed;

        return .{ .fd = fd };
    }

    pub fn boundPort(self: *const Listener) u16 {
        var addr: c.struct_sockaddr_in = std.mem.zeroes(c.struct_sockaddr_in);
        var len: c.socklen_t = @sizeOf(c.struct_sockaddr_in);
        if (c.getsockname(self.fd, @ptrCast(&addr), &len) != 0) return 0;
        return c.ntohs(addr.sin_port);
    }

    pub fn accept(self: *Listener) !Connection {
        const cfd = c.accept(self.fd, null, null);
        if (cfd < 0) return error.ConnectFailed;
        setNoDelay(cfd);
        return .{ .fd = cfd };
    }

    pub fn close(self: *Listener) void {
        _ = c.close(self.fd);
    }
};

/// Connect to a `host:port` TCP endpoint. `host` may be an IPv4/IPv6 literal
/// or DNS name (resolved synchronously via getaddrinfo).
pub fn connect(allocator: std.mem.Allocator, host: []const u8, port: u16) !Connection {
    const host_z = try allocator.dupeZ(u8, host);
    defer allocator.free(host_z);
    var port_buf: [8]u8 = undefined;
    const port_z = try std.fmt.bufPrintZ(&port_buf, "{d}", .{port});

    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_family = c.AF_UNSPEC;
    hints.ai_socktype = c.SOCK_STREAM;

    var res: ?*c.struct_addrinfo = null;
    if (c.getaddrinfo(host_z.ptr, port_z.ptr, &hints, &res) != 0)
        return error.ConnectFailed;
    defer if (res) |r| c.freeaddrinfo(r);

    var it = res;
    while (it) |ai| : (it = ai.ai_next) {
        const fd = c.socket(ai.ai_family, ai.ai_socktype, ai.ai_protocol);
        if (fd < 0) continue;
        if (c.connect(fd, ai.ai_addr, ai.ai_addrlen) == 0) {
            setNoDelay(fd);
            return .{ .fd = fd };
        }
        _ = c.close(fd);
    }
    return error.ConnectFailed;
}

/// Disable Nagle's algorithm so single-keystroke frames and other small
/// interactive messages leave the socket immediately. Best-effort.
fn setNoDelay(fd: c_int) void {
    var one: c_int = 1;
    _ = c.setsockopt(fd, c.IPPROTO_TCP, c.TCP_NODELAY, &one, @sizeOf(c_int));
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

test "loopback sockets have TCP_NODELAY enabled" {
    var listener = try Listener.listen(0);
    defer listener.close();
    const port = listener.boundPort();

    const Runner = struct {
        fn clientThread(p: u16) void {
            var conn = connect(testing.allocator, "127.0.0.1", p) catch return;
            // Keep socket alive until parent has inspected its server side.
            runtime.sleep(50 * runtime.ns_per_ms);
            conn.close();
        }
    };

    const t = try std.Thread.spawn(.{}, Runner.clientThread, .{port});
    defer t.join();

    var server_conn = try listener.accept();
    defer server_conn.close();

    var val: c_int = 0;
    var len: c.socklen_t = @sizeOf(c_int);
    const rc = c.getsockopt(
        server_conn.fd,
        c.IPPROTO_TCP,
        c.TCP_NODELAY,
        @ptrCast(&val),
        &len,
    );
    try testing.expect(rc == 0);
    try testing.expect(val != 0);
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
