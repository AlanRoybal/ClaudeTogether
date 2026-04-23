const std = @import("std");
const pty = @import("pty.zig");
const session_mod = @import("session.zig");
const bore_mod = @import("bore.zig");

// Process-wide allocator for C-ABI objects. Using the general-purpose
// allocator so leaks show up in Debug builds.
var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
fn gpa() std.mem.Allocator {
    return gpa_instance.allocator();
}

// Last-error slot so callers can read a human-readable reason after a
// NULL / -1 return from the C ABI. Thread-safe via a single mutex.
var last_error_mutex: std.Thread.Mutex = .{};
var last_error_buf: [256]u8 = undefined;
var last_error_len: usize = 0;

fn setLastError(comptime fmt: []const u8, args: anytype) void {
    last_error_mutex.lock();
    defer last_error_mutex.unlock();
    const written = std.fmt.bufPrint(&last_error_buf, fmt, args) catch {
        last_error_len = 0;
        return;
    };
    last_error_len = written.len;
}

/// Copies the most recent error message into `out` (NOT NUL-terminated) and
/// returns its length. Returns 0 if no error has been recorded.
export fn ct_last_error(out: [*]u8, cap: usize) usize {
    last_error_mutex.lock();
    defer last_error_mutex.unlock();
    const n = @min(cap, last_error_len);
    if (n > 0) @memcpy(out[0..n], last_error_buf[0..n]);
    return last_error_len;
}

// Pull in term module so its `export fn`s are included in the static lib.
comptime {
    _ = @import("term.zig");
}

// Test-only modules (no C ABI exports yet). `_ = @import(...)` ensures
// `zig build test` picks up their `test` blocks.
test {
    _ = @import("frame.zig");
    _ = @import("crdt.zig");
    _ = @import("bore.zig");
    _ = @import("transport.zig");
    _ = @import("session.zig");
}

export fn ct_hello(buf: [*]u8, len: usize) c_int {
    const msg = "core says: ok";
    if (len < msg.len) return -1;
    @memcpy(buf[0..msg.len], msg);
    return @intCast(msg.len);
}

export fn ct_version() c_int {
    return 1;
}

/// Spawn argv[0] under a PTY. argv must be a NULL-terminated array of
/// C strings (execvp style). cwd may be null.
/// On success, writes master fd into *out_fd and child pid into *out_pid.
/// Returns 0 on success, -1 on error.
export fn ct_pty_spawn(
    argv: [*c]const [*c]const u8,
    cwd: ?[*:0]const u8,
    cols: u16,
    rows: u16,
    out_fd: *c_int,
    out_pid: *c_int,
) c_int {
    const r = pty.spawn(argv, cwd, cols, rows);
    if (r.fd < 0) return -1;
    out_fd.* = r.fd;
    out_pid.* = r.pid;
    return 0;
}

export fn ct_pty_resize(fd: c_int, cols: u16, rows: u16) c_int {
    return pty.resize(fd, cols, rows);
}

/// Returns 1 if the PTY slave side is currently in raw mode
/// (ICANON cleared — interactive apps like vim), 0 if in line mode.
export fn ct_pty_is_raw(fd: c_int) c_int {
    return if (pty.isRaw(fd)) 1 else 0;
}

export fn ct_pty_kill(pid: c_int) void {
    pty.kill(pid);
}

// ---- Session (Phase 3) --------------------------------------------------

/// Create a host session listening on `port` (0 = OS-assigned).
/// Returns an opaque pointer or NULL on error.
export fn ct_session_new_host(port: u16) ?*anyopaque {
    const s = session_mod.Session.initHost(gpa(), port) catch |err| {
        setLastError("host listen on port {d} failed: {s}", .{ port, @errorName(err) });
        return null;
    };
    return @ptrCast(s);
}

/// Create a peer session connected to `host:port`. `host` is a
/// null-terminated C string (IP literal or DNS name).
export fn ct_session_new_peer(host: [*:0]const u8, port: u16) ?*anyopaque {
    const host_slice = std.mem.span(host);
    const s = session_mod.Session.initPeer(gpa(), host_slice, port) catch |err| {
        setLastError("connect {s}:{d} failed: {s}", .{ host_slice, port, @errorName(err) });
        return null;
    };
    return @ptrCast(s);
}

export fn ct_session_free(handle: ?*anyopaque) void {
    const s: *session_mod.Session = @ptrCast(@alignCast(handle orelse return));
    s.deinit();
}

/// Returns the bound port for a host session (0 for a peer).
export fn ct_session_port(handle: ?*anyopaque) u16 {
    const s: *session_mod.Session = @ptrCast(@alignCast(handle orelse return 0));
    return s.boundPort();
}

export fn ct_session_peer_count(handle: ?*anyopaque) u32 {
    const s: *session_mod.Session = @ptrCast(@alignCast(handle orelse return 0));
    return @intCast(s.peerCount());
}

/// Pop the next lifecycle event. Writes kind (0 = connected, 1 = disconnected)
/// to `*out_kind` and peer id to `*out_peer_id`, returns 1. Returns 0 if no
/// events pending.
export fn ct_session_poll_event(
    handle: ?*anyopaque,
    out_kind: *u8,
    out_peer_id: *u32,
) c_int {
    const s: *session_mod.Session = @ptrCast(@alignCast(handle orelse return 0));
    const ev = s.pollEvent() orelse return 0;
    out_kind.* = @intFromEnum(ev.kind);
    out_peer_id.* = ev.peer_id;
    return 1;
}

/// Broadcast `len` bytes to all connected peers. Returns 0 on success, -1
/// on error.
export fn ct_session_broadcast(
    handle: ?*anyopaque,
    bytes: [*]const u8,
    len: usize,
) c_int {
    const s: *session_mod.Session = @ptrCast(@alignCast(handle orelse return -1));
    s.broadcast(bytes[0..len]) catch return -1;
    return 0;
}

/// Pop the next inbound frame. If one is available, copies up to `cap`
/// bytes into `out`, writes the sending peer id into `*out_peer_id`, and
/// returns the frame length (may exceed `cap` — caller should treat
/// `ret > cap` as "buffer too small"). Returns 0 if queue empty.
export fn ct_session_poll(
    handle: ?*anyopaque,
    out: [*]u8,
    cap: usize,
    out_peer_id: *u32,
) isize {
    const s: *session_mod.Session = @ptrCast(@alignCast(handle orelse return 0));
    const frame = s.pollFrame() orelse return 0;
    defer s.freeFrame(frame);
    out_peer_id.* = frame.peer_id;
    const n = @min(frame.payload.len, cap);
    if (n > 0) @memcpy(out[0..n], frame.payload[0..n]);
    return @intCast(frame.payload.len);
}

// ---- Bore supervisor ----------------------------------------------------

export fn ct_bore_new() ?*anyopaque {
    const sup = gpa().create(bore_mod.Supervisor) catch return null;
    sup.* = bore_mod.Supervisor.init(gpa());
    return @ptrCast(sup);
}

export fn ct_bore_free(handle: ?*anyopaque) void {
    const sup: *bore_mod.Supervisor =
        @ptrCast(@alignCast(handle orelse return));
    sup.deinit();
    gpa().destroy(sup);
}

/// Spawn `bore local --to bore.pub <port>` using `bore_path` (NUL-terminated).
/// Returns 0 on success, -1 on error.
export fn ct_bore_start(
    handle: ?*anyopaque,
    bore_path: [*:0]const u8,
    port: u16,
) c_int {
    const sup: *bore_mod.Supervisor =
        @ptrCast(@alignCast(handle orelse return -1));
    sup.start(std.mem.span(bore_path), port) catch return -1;
    return 0;
}

/// Poll once. If a public URL is now available, copies up to `cap` bytes
/// (NOT null-terminated) into `out` and returns the URL length. Returns 0
/// if not ready yet, -1 on error.
export fn ct_bore_pump(
    handle: ?*anyopaque,
    out: [*]u8,
    cap: usize,
) isize {
    const sup: *bore_mod.Supervisor =
        @ptrCast(@alignCast(handle orelse return -1));
    const url_opt = sup.pump() catch return -1;
    const url = url_opt orelse return 0;
    const n = @min(url.len, cap);
    if (n > 0) @memcpy(out[0..n], url[0..n]);
    return @intCast(url.len);
}

/// Copy the bore stdout/stderr scratch buffer for diagnostics. Returns the
/// total buffered length (may exceed `cap`).
export fn ct_bore_debug(
    handle: ?*anyopaque,
    out: [*]u8,
    cap: usize,
) isize {
    const sup: *bore_mod.Supervisor =
        @ptrCast(@alignCast(handle orelse return -1));
    const buf = sup.debugBuffer();
    const n = @min(buf.len, cap);
    if (n > 0) @memcpy(out[0..n], buf[0..n]);
    return @intCast(buf.len);
}

export fn ct_bore_stop(handle: ?*anyopaque) void {
    const sup: *bore_mod.Supervisor =
        @ptrCast(@alignCast(handle orelse return));
    sup.stop();
}
