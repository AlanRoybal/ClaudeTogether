const std = @import("std");
const pty = @import("pty.zig");

// Pull in term module so its `export fn`s are included in the static lib.
comptime {
    _ = @import("term.zig");
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
