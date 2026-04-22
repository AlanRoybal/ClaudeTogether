//! Supervises the bundled `bore` binary, which exposes a local TCP port
//! through the community bore.pub tunnel. Parses the public URL from
//! bore's stdout and surfaces it to the caller.
//!
//! Lifecycle: callers spawn via `start`, poll `publicUrl()` until non-null
//! (or some timeout), and call `stop` on shutdown. Restart on crash is the
//! caller's responsibility — keep policy out of this module.

const std = @import("std");

pub const Error = error{
    SpawnFailed,
    ReadFailed,
    NotStarted,
};

pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    child: ?std.process.Child = null,
    /// Parsed "bore.pub:NNNNN" once the child announces it. Owned by
    /// this supervisor (freed on stop()).
    public_url: ?[]u8 = null,
    /// Scratch buffer for incremental stdout reads while waiting for the
    /// "listening at ..." line.
    stdout_buf: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) Supervisor {
        return .{
            .allocator = allocator,
            .stdout_buf = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Supervisor) void {
        self.stop();
        self.stdout_buf.deinit();
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
        self.child = child;
    }

    /// Pump bore's stdout once, looking for the "listening at bore.pub:PORT"
    /// line. Returns the parsed URL if found this call. Non-blocking style:
    /// reads whatever is available, parses when the line is complete. Caller
    /// should poll this until it returns non-null.
    pub fn pump(self: *Supervisor) !?[]const u8 {
        if (self.public_url) |u| return u;
        const child = &(self.child orelse return error.NotStarted);
        const stdout = child.stdout orelse return error.ReadFailed;

        var tmp: [1024]u8 = undefined;
        const n = stdout.read(&tmp) catch |err| switch (err) {
            error.WouldBlock => return null,
            else => return error.ReadFailed,
        };
        if (n == 0) return null;
        try self.stdout_buf.appendSlice(tmp[0..n]);

        if (parsePublicUrl(self.stdout_buf.items)) |url| {
            self.public_url = try self.allocator.dupe(u8, url);
            return self.public_url;
        }
        return null;
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
        self.stdout_buf.clearRetainingCapacity();
    }
};

/// Scans `output` (accumulated bore stdout) for the announcement line and
/// returns a borrowed slice pointing at "bore.pub:NNNNN", or null.
///
/// Bore prints lines like:
///   2024-01-01T00:00:00Z  INFO bore_cli::client: listening at bore.pub:12345
pub fn parsePublicUrl(output: []const u8) ?[]const u8 {
    const needle = "bore.pub:";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, output, i, needle)) |start| {
        // Require a digit immediately after the colon.
        const after = start + needle.len;
        if (after >= output.len or !std.ascii.isDigit(output[after])) {
            i = after;
            continue;
        }
        var end = after;
        while (end < output.len and std.ascii.isDigit(output[end])) end += 1;
        return output[start..end];
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

test "parsePublicUrl picks first numeric match" {
    const two =
        "listening at bore.pub:11111\n" ++
        "later line bore.pub:22222\n";
    const got = parsePublicUrl(two);
    try testing.expectEqualStrings("bore.pub:11111", got.?);
}
