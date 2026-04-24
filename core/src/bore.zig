//! Supervises the bundled `bore` binary, which exposes a local TCP port
//! through the community bore.pub tunnel. Parses the public URL from
//! bore's stdout/stderr and surfaces it to the caller.
//!
//! Lifecycle: callers spawn via `start`, poll `publicUrl()` until non-null
//! (or some timeout), and call `stop` on shutdown. Restart on crash is the
//! caller's responsibility — keep policy out of this module.

const std = @import("std");

pub const Error = error{
    SpawnFailed,
    ReadFailed,
    NotStarted,
    ProcessExited,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    child: ?std.process.Child = null,
    /// Parsed "bore.pub:NNNNN" once the child announces it. Owned by
    /// this supervisor (freed on stop()).
    public_url: ?[]u8 = null,
    /// Scratch buffer for incremental stdout/stderr reads while waiting for
    /// the "listening at ..." announcement.
    output_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Supervisor {
        return .{
            .allocator = allocator,
            .output_buf = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Supervisor) void {
        self.stop();
        self.output_buf.deinit();
    }

    /// Spawn `bore local --to bore.pub <local_port>` from `bore_path`.
    pub fn start(self: *Supervisor, bore_path: []const u8, local_port: u16) !void {
        if (self.child != null) return; // already running

        const port_str = try std.fmt.allocPrint(self.allocator, "{d}", .{local_port});
        defer self.allocator.free(port_str);

        const argv = [_][]const u8{
            bore_path,
            "local",
            "--to",
            "bore.pub",
            port_str,
        };

        var child = std.process.Child.init(&argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.stdin_behavior = .Ignore;

        child.spawn() catch return error.SpawnFailed;
        errdefer _ = child.kill() catch {};

        try setPipeNonBlocking(child.stdout orelse return error.SpawnFailed);
        try setPipeNonBlocking(child.stderr orelse return error.SpawnFailed);
        self.child = child;
    }

    /// Pump bore's stdout/stderr once, looking for the
    /// "listening at bore.pub:PORT" line. Returns the parsed URL if found
    /// this call. Non-blocking style: reads whatever is available, parses
    /// when the line is complete. Caller should poll this until it returns
    /// non-null.
    pub fn pump(self: *Supervisor) !?[]const u8 {
        if (self.public_url) |u| return u;
        const child = &(self.child orelse return error.NotStarted);
        const stdout_state = try self.pumpPipe(child.stdout);
        const stderr_state = try self.pumpPipe(child.stderr);

        if (parsePublicUrl(self.output_buf.items)) |url| {
            self.public_url = try self.allocator.dupe(u8, url);
            return self.public_url;
        }
        if (stdout_state == .eof and stderr_state == .eof) {
            _ = child.wait() catch {};
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
        const c = &(self.child orelse return false);
        _ = c;
        return true;
    }

    pub fn stop(self: *Supervisor) void {
        if (self.child) |*c| {
            _ = c.kill() catch {};
            self.child = null;
        }
        if (self.public_url) |u| {
            self.allocator.free(u);
            self.public_url = null;
        }
        self.output_buf.clearRetainingCapacity();
    }

    const PipeState = enum {
        ready,
        would_block,
        eof,
    };

    fn pumpPipe(self: *Supervisor, pipe: ?std.fs.File) !PipeState {
        const file = pipe orelse return .eof;
        var tmp: [1024]u8 = undefined;
        var saw_data = false;

        while (true) {
            const n = file.read(&tmp) catch |err| switch (err) {
                error.WouldBlock => return if (saw_data) .ready else .would_block,
                else => return error.ReadFailed,
            };
            if (n == 0) return if (saw_data) .ready else .eof;
            saw_data = true;
            try self.output_buf.appendSlice(tmp[0..n]);
        }
    }
};

fn setPipeNonBlocking(file: std.fs.File) !void {
    var flags = std.posix.fcntl(file.handle, std.posix.F.GETFL, 0) catch {
        return error.ReadFailed;
    };
    flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = std.posix.fcntl(file.handle, std.posix.F.SETFL, flags) catch {
        return error.ReadFailed;
    };
}

/// Scans `output` (accumulated bore stdout/stderr) for the announcement line
/// and returns the borrowed address token after "listening at ", or null.
///
/// Bore prints lines like:
///   2024-01-01T00:00:00Z  INFO bore_cli::client: listening at bore.pub:12345
pub fn parsePublicUrl(output: []const u8) ?[]const u8 {
    const needle = "listening at ";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, output, i, needle)) |match_start| {
        const start = match_start + needle.len;
        if (start >= output.len) return null;
        var end = start;
        while (end < output.len and !std.ascii.isWhitespace(output[end])) {
            end += 1;
        }
        if (end > start) return output[start..end];
        i = start;
    }
    return null;
}

// --- tests ----------------------------------------------------------------

const testing = std.testing;

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

test "Supervisor parses public URL from stderr" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "fake-bore.sh",
        .data =
        \\#!/bin/sh
        \\printf '2024-01-01T00:00:00Z INFO bore_cli::client: listening at bore.pub:12345\n' >&2
        \\sleep 1
        ,
        .flags = .{ .mode = 0o755 },
    });

    const script_path = try std.fs.path.join(testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "fake-bore.sh",
    });
    defer testing.allocator.free(script_path);

    var sup = Supervisor.init(testing.allocator);
    defer sup.deinit();
    try sup.start(script_path, 43210);

    for (0..50) |_| {
        if (try sup.pump()) |url| {
            try testing.expectEqualStrings("bore.pub:12345", url);
            return;
        }
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    return error.TestUnexpectedResult;
}

test "Supervisor reports process exit after stderr-only failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "fake-bore.sh",
        .data =
        \\#!/bin/sh
        \\printf 'Error: bore failed to connect\n' >&2
        \\exit 1
        ,
        .flags = .{ .mode = 0o755 },
    });

    const script_path = try std.fs.path.join(testing.allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
        "fake-bore.sh",
    });
    defer testing.allocator.free(script_path);

    var sup = Supervisor.init(testing.allocator);
    defer sup.deinit();
    try sup.start(script_path, 43210);

    for (0..50) |_| {
        const url = sup.pump() catch |err| {
            try testing.expectEqual(err, error.ProcessExited);
            try testing.expect(std.mem.indexOf(u8, sup.debugBuffer(), "bore failed to connect") != null);
            return;
        };
        try testing.expect(url == null);
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    return error.TestUnexpectedResult;
}
