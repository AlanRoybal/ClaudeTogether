const std = @import("std");
const c = @cImport({
    @cInclude("util.h");
    @cInclude("termios.h");
    @cInclude("sys/ioctl.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("errno.h");
    @cInclude("stdlib.h");
    @cInclude("sys/wait.h");
});

pub const SpawnResult = extern struct {
    fd: c_int,
    pid: c_int,
};

pub fn spawn(
    argv: [*c]const [*c]const u8,
    cwd: ?[*:0]const u8,
    cols: u16,
    rows: u16,
) SpawnResult {
    var master_fd: c_int = -1;
    var ws: c.struct_winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };

    const pid = c.forkpty(&master_fd, null, null, &ws);
    if (pid < 0) return .{ .fd = -1, .pid = -1 };

    if (pid == 0) {
        // child
        if (cwd) |path| _ = c.chdir(path);
        _ = c.setenv("TERM", "xterm-256color", 1);
        _ = c.setenv("COLORTERM", "truecolor", 1);
        const execv_argv: [*c][*c]u8 = @ptrCast(@constCast(argv));
        _ = c.execvp(argv[0], execv_argv);
        // if execvp returns, it failed; _exit so the fork doesn't run the
        // parent's inherited atexit handlers
        c._exit(127);
    }

    // parent: make master non-blocking
    const flags = c.fcntl(master_fd, c.F_GETFL, @as(c_int, 0));
    _ = c.fcntl(master_fd, c.F_SETFL, flags | c.O_NONBLOCK);

    return .{ .fd = master_fd, .pid = pid };
}

pub fn resize(fd: c_int, cols: u16, rows: u16) c_int {
    var ws: c.struct_winsize = .{
        .ws_row = rows,
        .ws_col = cols,
        .ws_xpixel = 0,
        .ws_ypixel = 0,
    };
    return c.ioctl(fd, c.TIOCSWINSZ, &ws);
}

pub fn isRaw(fd: c_int) bool {
    var t: c.struct_termios = undefined;
    if (c.tcgetattr(fd, &t) != 0) return false;
    // Line mode = ICANON set; raw/cbreak = ICANON cleared.
    return (t.c_lflag & c.ICANON) == 0;
}

pub fn kill(pid: c_int) void {
    _ = c.kill(pid, c.SIGTERM);
    // Reap asynchronously: nothing else ever waits on PTY children, so
    // without this every closed tab leaves a zombie for the app's lifetime.
    // A detached thread blocks in waitpid until the child actually exits.
    const t = std.Thread.spawn(.{}, reap, .{pid}) catch {
        // Thread spawn failed (resource exhaustion): block briefly to reap
        // rather than WNOHANG, which would return before the child exits and
        // leak a zombie. We already sent SIGTERM, so the child exits promptly.
        _ = c.waitpid(pid, null, 0);
        return;
    };
    t.detach();
}

fn reap(pid: c_int) void {
    _ = c.waitpid(pid, null, 0);
}
