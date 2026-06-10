//! Supervises the bundled `bore` binary, which exposes a local TCP port
//! through the community bore.pub tunnel. Parses the public URL from
//! bore's stdout/stderr and surfaces it to the caller.
//!
//! Lifecycle: callers spawn via `start`, poll `publicUrl()` until non-null
//! (or some timeout), and call `stop` on shutdown. Restart on crash is the
//! caller's responsibility — keep policy out of this module.
//!
//! Implemented on raw libc fork/exec/pipe (like `pty.zig`). Zig 0.16's
//! `std.process.Child` now requires threading a `std.Io` through spawn/wait/
//! kill and reading pipes via the new streaming `Io.File`; doing it directly
//! against libc keeps the same non-blocking polling semantics with no `Io`.

const std = @import("std");

const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("poll.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/stat.h");
});

pub const Error = error{
    SpawnFailed,
    ReadFailed,
    NotStarted,
    ProcessExited,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    pid: ?c.pid_t = null,
    /// Read ends of the child's stdout/stderr pipes (parent side).
    stdout_fd: ?c_int = null,
    stderr_fd: ?c_int = null,
    /// Parsed "bore.pub:NNNNN" once the child announces it. Owned by
    /// this supervisor (freed on stop()).
    public_url: ?[]u8 = null,
    /// Scratch buffer for incremental stdout/stderr reads while waiting for
    /// the "listening at ..." announcement.
    output_buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Supervisor {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Supervisor) void {
        self.stop();
        self.output_buf.deinit(self.allocator);
    }

    /// Spawn a tunnel process from `tool_path`.
    /// If `server` is non-empty: bore mode → `bore local <port> --to <server> [--secret <secret>]`
    /// If `server` is empty:    ngrok mode → `ngrok tcp <port>`
    pub fn start(self: *Supervisor, tool_path: []const u8, server: []const u8, local_port: u16, secret: []const u8) !void {
        if (self.pid != null) return; // already running

        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{local_port});
        defer self.allocator.free(port_str);

        // Assemble argv as borrowed slices, then NUL-terminate each for execvp.
        var args_buf: [8][]const u8 = undefined;
        var argc: usize = 0;
        args_buf[argc] = tool_path; argc += 1;
        if (server.len == 0) {
            args_buf[argc] = "tcp"; argc += 1;
            args_buf[argc] = port_str; argc += 1;
        } else {
            args_buf[argc] = "local"; argc += 1;
            args_buf[argc] = port_str; argc += 1;
            args_buf[argc] = "--to"; argc += 1;
            args_buf[argc] = server; argc += 1;
            if (secret.len > 0) {
                args_buf[argc] = "--secret"; argc += 1;
                args_buf[argc] = secret; argc += 1;
            }
        }

        // NUL-terminated argv (execvp wants a null-terminated pointer array).
        // One defer frees exactly what was duped, on success and error alike;
        // a separate errdefer would double-free once the loop completed.
        var argv: [9][*c]u8 = undefined;
        var made: usize = 0;
        defer for (0..made) |i| self.allocator.free(std.mem.span(@as([*:0]u8, @ptrCast(argv[i]))));
        for (0..argc) |i| {
            const z = try self.allocator.dupeZ(u8, args_buf[i]);
            argv[i] = @ptrCast(z.ptr);
            made += 1;
        }
        argv[argc] = null;

        var out_fds: [2]c_int = undefined;
        var err_fds: [2]c_int = undefined;
        if (c.pipe(&out_fds) != 0) return error.SpawnFailed;
        errdefer {
            _ = c.close(out_fds[0]);
            _ = c.close(out_fds[1]);
        }
        if (c.pipe(&err_fds) != 0) return error.SpawnFailed;
        errdefer {
            _ = c.close(err_fds[0]);
            _ = c.close(err_fds[1]);
        }

        const pid = c.fork();
        if (pid < 0) return error.SpawnFailed;

        if (pid == 0) {
            // child: wire pipe write ends to stdout/stderr, then exec.
            _ = c.dup2(out_fds[1], c.STDOUT_FILENO);
            _ = c.dup2(err_fds[1], c.STDERR_FILENO);
            _ = c.close(out_fds[0]);
            _ = c.close(out_fds[1]);
            _ = c.close(err_fds[0]);
            _ = c.close(err_fds[1]);
            // Don't leak the app's other fds (listening sockets, peer
            // connections, PTY masters) into the tunnel process — they would
            // keep ports bound and connections half-open for its lifetime.
            var fd: c_int = 3;
            const maxfd = c.getdtablesize();
            while (fd < maxfd) : (fd += 1) _ = c.close(fd);
            _ = c.execvp(argv[0], &argv);
            c._exit(127); // execvp returned → failed
        }

        // parent: keep read ends, close write ends.
        _ = c.close(out_fds[1]);
        _ = c.close(err_fds[1]);
        self.pid = pid;
        self.stdout_fd = out_fds[0];
        self.stderr_fd = err_fds[0];
    }

    /// Pump bore's stdout/stderr once, looking for the
    /// "listening at bore.pub:PORT" line. Returns the parsed URL if found
    /// this call. Non-blocking: reads whatever is available, parses when the
    /// line is complete. Caller should poll this until it returns non-null.
    pub fn pump(self: *Supervisor) !?[]const u8 {
        if (self.public_url) |u| return u;
        if (self.pid == null) return error.NotStarted;
        const stdout_state = try self.pumpPipe(self.stdout_fd);
        const stderr_state = try self.pumpPipe(self.stderr_fd);

        if (parsePublicUrl(self.output_buf.items)) |url| {
            self.public_url = try self.allocator.dupe(u8, url);
            return self.public_url;
        }
        if (stdout_state == .eof and stderr_state == .eof) {
            self.reap();
            return error.ProcessExited;
        }
        return null;
    }

    /// Snapshot of the bore stdout/stderr we've seen so far (diagnostic).
    pub fn debugBuffer(self: *const Supervisor) []const u8 {
        return self.output_buf.items;
    }

    pub fn publicUrl(self: *const Supervisor) ?[]const u8 {
        return self.public_url;
    }

    pub fn isRunning(self: *Supervisor) bool {
        return self.pid != null;
    }

    pub fn stop(self: *Supervisor) void {
        if (self.pid) |pid| {
            _ = c.kill(pid, c.SIGTERM);
            self.reap();
        }
        if (self.stdout_fd) |fd| {
            _ = c.close(fd);
            self.stdout_fd = null;
        }
        if (self.stderr_fd) |fd| {
            _ = c.close(fd);
            self.stderr_fd = null;
        }
        if (self.public_url) |u| {
            self.allocator.free(u);
            self.public_url = null;
        }
        self.output_buf.clearRetainingCapacity();
    }

    fn reap(self: *Supervisor) void {
        if (self.pid) |pid| {
            _ = c.waitpid(pid, null, 0);
            self.pid = null;
        }
    }

    const PipeState = enum {
        ready,
        would_block,
        eof,
    };

    fn pumpPipe(self: *Supervisor, pipe_fd: ?c_int) !PipeState {
        const fd = pipe_fd orelse return .eof;
        var tmp: [1024]u8 = undefined;
        var saw_data = false;

        while (true) {
            var pfd = c.struct_pollfd{
                .fd = fd,
                .events = c.POLLIN,
                .revents = 0,
            };
            const pr = c.poll(&pfd, 1, 0);
            if (pr <= 0) return if (saw_data) .ready else .would_block;
            if ((pfd.revents & (c.POLLIN | c.POLLHUP)) == 0)
                return if (saw_data) .ready else .would_block;

            const n = c.read(fd, &tmp, tmp.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) return if (saw_data) .ready else .eof;
            saw_data = true;
            try self.output_buf.appendSlice(self.allocator, tmp[0..@intCast(n)]);
        }
    }
};

/// Scans `output` (accumulated tunnel stdout/stderr) for a public address.
///
/// Bore:  "… listening at bore.pub:12345"
/// ngrok: "Forwarding   tcp://0.tcp.ngrok.io:12345 -> localhost:…"
///        or JSON log: …"url":"tcp://0.tcp.ngrok.io:12345"…
///
/// Returns the bare HOST:PORT token (no scheme prefix), borrowed from `output`.
pub fn parsePublicUrl(output: []const u8) ?[]const u8 {
    // bore: "listening at HOST:PORT"
    {
        const needle = "listening at ";
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, output, i, needle)) |pos| {
            const start = pos + needle.len;
            if (start >= output.len) break;
            var end = start;
            while (end < output.len and !std.ascii.isWhitespace(output[end])) end += 1;
            if (end > start) return output[start..end];
            i = start;
        }
    }
    // ngrok: "tcp://HOST:PORT" (plain output or JSON url field)
    {
        const needle = "tcp://";
        var i: usize = 0;
        while (std.mem.indexOfPos(u8, output, i, needle)) |pos| {
            const start = pos + needle.len;
            if (start >= output.len) break;
            var end = start;
            while (end < output.len and !std.ascii.isWhitespace(output[end]) and output[end] != '"') end += 1;
            const candidate = output[start..end];
            if (std.mem.indexOfScalar(u8, candidate, ':') != null and candidate.len > 0)
                return candidate;
            i = start;
        }
    }
    return null;
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;
const runtime = @import("runtime.zig");

test "parsePublicUrl finds the announcement line" {
    const sample =
        "2024-01-01T00:00:00Z  INFO bore_cli::client: connected to server\n" ++
        "2024-01-01T00:00:00Z  INFO bore_cli::client: listening at bore.pub:12345\n";
    const got = parsePublicUrl(sample);
    try testing.expect(got != null);
    try testing.expectEqualStrings("bore.pub:12345", got.?);
}

test "parsePublicUrl returns null before announcement" {
    const partial = "some prelude with no url here\n";
    try testing.expect(parsePublicUrl(partial) == null);
}

test "parsePublicUrl ignores bore.pub without port digits" {
    const noise = "connecting to bore.pub (resolving)\n";
    try testing.expect(parsePublicUrl(noise) == null);
}

test "parsePublicUrl ignores control-port lines and picks announcement" {
    const two =
        "2024-01-01T00:00:00Z  INFO bore_cli::client: connected to bore.pub:7835\n" ++
        "2024-01-01T00:00:00Z  INFO bore_cli::client: listening at bore.pub:11111\n" ++
        "later line bore.pub:22222\n";
    const got = parsePublicUrl(two);
    try testing.expectEqualStrings("bore.pub:11111", got.?);
}

test "parsePublicUrl supports non-bore domains" {
    const sample =
        "2024-01-01T00:00:00Z  INFO bore_cli::client: listening at tunnel.example.com:43210\n";
    const got = parsePublicUrl(sample);
    try testing.expectEqualStrings("tunnel.example.com:43210", got.?);
}

test "parsePublicUrl parses ngrok plain-text Forwarding line" {
    const sample =
        "ngrok by @inconshreveable\n" ++
        "\n" ++
        "Forwarding                    tcp://0.tcp.ngrok.io:12345 -> localhost:5555\n";
    const got = parsePublicUrl(sample);
    try testing.expectEqualStrings("0.tcp.ngrok.io:12345", got.?);
}

test "parsePublicUrl parses ngrok JSON log url field" {
    const sample =
        \\{"level":"info","msg":"started tunnel","url":"tcp://0.tcp.us.ngrok.io:54321"}
    ++ "\n";
    const got = parsePublicUrl(sample);
    try testing.expectEqualStrings("0.tcp.us.ngrok.io:54321", got.?);
}

test "Supervisor parses public URL from stderr" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "fake-bore.sh",
        .data =
        \\#!/bin/sh
        \\printf '2024-01-01T00:00:00Z INFO bore_cli::client: listening at bore.pub:12345\n' >&2
        \\sleep 1
        ,
    });

    const script_path = try std.fs.path.join(testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "fake-bore.sh",
    });
    defer testing.allocator.free(script_path);

    // CreateFileOptions no longer carries a mode; make the script executable
    // so execvp can run it.
    const script_z = try testing.allocator.dupeZ(u8, script_path);
    defer testing.allocator.free(script_z);
    _ = c.chmod(script_z.ptr, 0o755);

    var sup = Supervisor.init(testing.allocator);
    defer sup.deinit();
    try sup.start(script_path, "bore.pub", 43210, "");

    for (0..50) |_| {
        if (try sup.pump()) |url| {
            try testing.expectEqualStrings("bore.pub:12345", url);
            return;
        }
        runtime.sleep(10 * runtime.ns_per_ms);
    }

    return error.TestUnexpectedResult;
}

test "Supervisor reports process exit after stderr-only failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "fake-bore.sh",
        .data =
        \\#!/bin/sh
        \\printf 'Error: bore failed to connect\n' >&2
        \\exit 1
        ,
    });

    const script_path = try std.fs.path.join(testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "fake-bore.sh",
    });
    defer testing.allocator.free(script_path);

    // CreateFileOptions no longer carries a mode; make the script executable
    // so execvp can run it.
    const script_z = try testing.allocator.dupeZ(u8, script_path);
    defer testing.allocator.free(script_z);
    _ = c.chmod(script_z.ptr, 0o755);

    var sup = Supervisor.init(testing.allocator);
    defer sup.deinit();
    try sup.start(script_path, "bore.pub", 43210, "");

    for (0..50) |_| {
        const url = sup.pump() catch |err| {
            try testing.expectEqual(err, error.ProcessExited);
            try testing.expect(std.mem.indexOf(u8, sup.debugBuffer(), "bore failed to connect") != null);
            return;
        };
        try testing.expect(url == null);
        runtime.sleep(10 * runtime.ns_per_ms);
    }

    return error.TestUnexpectedResult;
}
