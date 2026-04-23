//! Wire protocol: one-byte tag, big-endian integers, length-prefixed blobs.
//!
//! All frames share header: `tag:u8 | payload`. Decoding returns a tagged
//! union; encoding writes into a caller-provided buffer or allocates.
//!
//! Phase 3 frames + Phase 4 FsDelta are implemented. FsSnapshot (0x05) is
//! currently unused — peers receive their initial state as a sequence of
//! FsDelta frames instead of a single batched snapshot, which keeps the
//! transport layer's per-frame size cap (16 MB) comfortable for large trees.

const std = @import("std");

pub const Tag = enum(u8) {
    pty_output = 0x01,
    input_op = 0x02,
    input_commit = 0x03,
    fs_delta = 0x04,
    fs_snapshot = 0x05,
    cursor_pos = 0x06,
    hello = 0x07,
    mode_change = 0x08,
    /// Host broadcasts the full session roster whenever it changes.
    roster = 0x09,
    /// Lightweight keepalive frame to keep idle tunnels/sockets warm.
    heartbeat = 0x0A,
};

pub const Role = enum(u8) {
    creator = 0,
    peer = 1,
};

pub const Mode = enum(u8) {
    line = 0,
    raw = 1,
};

pub const UserId = [16]u8;

pub const Hello = struct {
    user_id: UserId,
    role: Role,
    /// 0x00RRGGBB
    color: u32,
    /// UTF-8, not null-terminated. Lifetime is caller-owned (decode borrows
    /// from the input buffer).
    name: []const u8,
};

pub const PtyOutput = struct {
    data: []const u8,
};

pub const InputOp = struct {
    /// Opaque CRDT operation bytes; see crdt.zig for encoding.
    op: []const u8,
};

pub const InputCommit = struct {
    user_id: UserId,
};

pub const CursorPos = struct {
    user_id: UserId,
    col: u16,
    row: u16,
};

pub const ModeChange = struct {
    mode: Mode,
};

pub const FsDeltaOp = enum(u8) {
    /// Create or overwrite a file at `path` with `content`.
    upsert = 0,
    /// Remove the file at `path`. `content` is empty, `mtime_ns` is ignored.
    delete = 1,
};

/// One-way filesystem change from host to peers (Phase 4). Paths are
/// forward-slash-separated, UTF-8, and relative to the session root.
/// `mtime_ns` is nanoseconds since Unix epoch (signed — pre-1970 permitted
/// but uncommon in practice).
pub const FsDelta = struct {
    op: FsDeltaOp,
    path: []const u8,
    mtime_ns: i64,
    content: []const u8,
};

pub const Frame = union(Tag) {
    pty_output: PtyOutput,
    input_op: InputOp,
    input_commit: InputCommit,
    fs_delta: FsDelta,
    fs_snapshot: void,
    cursor_pos: CursorPos,
    hello: Hello,
    mode_change: ModeChange,
    /// Encoded/decoded on the Swift side (FrameCodec); zig treats these as
    /// opaque bytes passing through the transport layer.
    roster: void,
    heartbeat: void,
};

pub const DecodeError = error{
    Truncated,
    UnknownTag,
    InvalidEnum,
    NotImplemented,
};

pub const EncodeError = error{
    BufferTooSmall,
};

// --- decode ---------------------------------------------------------------

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn remaining(self: *const Reader) usize {
        return self.buf.len - self.pos;
    }

    fn readU8(self: *Reader) !u8 {
        if (self.remaining() < 1) return error.Truncated;
        const v = self.buf[self.pos];
        self.pos += 1;
        return v;
    }

    fn readU16(self: *Reader) !u16 {
        if (self.remaining() < 2) return error.Truncated;
        const v = std.mem.readInt(u16, self.buf[self.pos..][0..2], .big);
        self.pos += 2;
        return v;
    }

    fn readU32(self: *Reader) !u32 {
        if (self.remaining() < 4) return error.Truncated;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .big);
        self.pos += 4;
        return v;
    }

    fn readI64(self: *Reader) !i64 {
        if (self.remaining() < 8) return error.Truncated;
        const v = std.mem.readInt(i64, self.buf[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    fn readBytes(self: *Reader, n: usize) ![]const u8 {
        if (self.remaining() < n) return error.Truncated;
        const s = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }
};

pub fn decode(bytes: []const u8) DecodeError!Frame {
    var r = Reader{ .buf = bytes };
    const tag_byte = try r.readU8();
    const tag = std.meta.intToEnum(Tag, tag_byte) catch return error.UnknownTag;

    return switch (tag) {
        .pty_output => blk: {
            const n = try r.readU32();
            const data = try r.readBytes(n);
            break :blk Frame{ .pty_output = .{ .data = data } };
        },
        .input_op => blk: {
            const n = try r.readU32();
            const op = try r.readBytes(n);
            break :blk Frame{ .input_op = .{ .op = op } };
        },
        .input_commit => blk: {
            const id_bytes = try r.readBytes(16);
            var id: UserId = undefined;
            @memcpy(&id, id_bytes);
            break :blk Frame{ .input_commit = .{ .user_id = id } };
        },
        .cursor_pos => blk: {
            const id_bytes = try r.readBytes(16);
            var id: UserId = undefined;
            @memcpy(&id, id_bytes);
            const col = try r.readU16();
            const row = try r.readU16();
            break :blk Frame{ .cursor_pos = .{
                .user_id = id,
                .col = col,
                .row = row,
            } };
        },
        .hello => blk: {
            const id_bytes = try r.readBytes(16);
            var id: UserId = undefined;
            @memcpy(&id, id_bytes);
            const role_b = try r.readU8();
            const role = std.meta.intToEnum(Role, role_b) catch
                return error.InvalidEnum;
            const color = try r.readU32();
            const name_len = try r.readU16();
            const name = try r.readBytes(name_len);
            break :blk Frame{ .hello = .{
                .user_id = id,
                .role = role,
                .color = color,
                .name = name,
            } };
        },
        .mode_change => blk: {
            const m_b = try r.readU8();
            const mode = std.meta.intToEnum(Mode, m_b) catch
                return error.InvalidEnum;
            break :blk Frame{ .mode_change = .{ .mode = mode } };
        },
        .fs_delta => blk: {
            const op_b = try r.readU8();
            const op = std.meta.intToEnum(FsDeltaOp, op_b) catch
                return error.InvalidEnum;
            const path_len = try r.readU16();
            const path = try r.readBytes(path_len);
            const mtime_ns = try r.readI64();
            const content_len = try r.readU32();
            const content = try r.readBytes(content_len);
            break :blk Frame{ .fs_delta = .{
                .op = op,
                .path = path,
                .mtime_ns = mtime_ns,
                .content = content,
            } };
        },
        .heartbeat => Frame{ .heartbeat = {} },
        .fs_snapshot, .roster => error.NotImplemented,
    };
}

// --- encode ---------------------------------------------------------------

const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn remaining(self: *const Writer) usize {
        return self.buf.len - self.pos;
    }

    fn writeU8(self: *Writer, v: u8) !void {
        if (self.remaining() < 1) return error.BufferTooSmall;
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    fn writeU16(self: *Writer, v: u16) !void {
        if (self.remaining() < 2) return error.BufferTooSmall;
        std.mem.writeInt(u16, self.buf[self.pos..][0..2], v, .big);
        self.pos += 2;
    }

    fn writeU32(self: *Writer, v: u32) !void {
        if (self.remaining() < 4) return error.BufferTooSmall;
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .big);
        self.pos += 4;
    }

    fn writeI64(self: *Writer, v: i64) !void {
        if (self.remaining() < 8) return error.BufferTooSmall;
        std.mem.writeInt(i64, self.buf[self.pos..][0..8], v, .big);
        self.pos += 8;
    }

    fn writeBytes(self: *Writer, s: []const u8) !void {
        if (self.remaining() < s.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.pos .. self.pos + s.len], s);
        self.pos += s.len;
    }
};

/// Encodes `frame` into `out`. Returns number of bytes written.
pub fn encode(frame: Frame, out: []u8) EncodeError!usize {
    var w = Writer{ .buf = out };
    try w.writeU8(@intFromEnum(@as(Tag, frame)));
    switch (frame) {
        .pty_output => |p| {
            try w.writeU32(@intCast(p.data.len));
            try w.writeBytes(p.data);
        },
        .input_op => |p| {
            try w.writeU32(@intCast(p.op.len));
            try w.writeBytes(p.op);
        },
        .input_commit => |p| try w.writeBytes(&p.user_id),
        .cursor_pos => |p| {
            try w.writeBytes(&p.user_id);
            try w.writeU16(p.col);
            try w.writeU16(p.row);
        },
        .hello => |p| {
            try w.writeBytes(&p.user_id);
            try w.writeU8(@intFromEnum(p.role));
            try w.writeU32(p.color);
            try w.writeU16(@intCast(p.name.len));
            try w.writeBytes(p.name);
        },
        .mode_change => |p| try w.writeU8(@intFromEnum(p.mode)),
        .fs_delta => |p| {
            try w.writeU8(@intFromEnum(p.op));
            try w.writeU16(@intCast(p.path.len));
            try w.writeBytes(p.path);
            try w.writeI64(p.mtime_ns);
            try w.writeU32(@intCast(p.content.len));
            try w.writeBytes(p.content);
        },
        .heartbeat => {},
        .fs_snapshot, .roster => return error.BufferTooSmall, // NYI
    }
    return w.pos;
}

/// Conservative upper bound for encoding `frame`.
pub fn encodedLen(frame: Frame) usize {
    return switch (frame) {
        .pty_output => |p| 1 + 4 + p.data.len,
        .input_op => |p| 1 + 4 + p.op.len,
        .input_commit => 1 + 16,
        .cursor_pos => 1 + 16 + 2 + 2,
        .hello => |p| 1 + 16 + 1 + 4 + 2 + p.name.len,
        .mode_change => 1 + 1,
        .fs_delta => |p| 1 + 1 + 2 + p.path.len + 8 + 4 + p.content.len,
        .heartbeat => 1,
        .fs_snapshot, .roster => 1,
    };
}

// --- tests ----------------------------------------------------------------

test "hello roundtrip" {
    const id: UserId = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const original = Frame{ .hello = .{
        .user_id = id,
        .role = .creator,
        .color = 0xFF8800,
        .name = "alice",
    } };

    var buf: [64]u8 = undefined;
    const n = try encode(original, &buf);
    const decoded = try decode(buf[0..n]);

    try std.testing.expectEqualSlices(u8, &id, &decoded.hello.user_id);
    try std.testing.expectEqual(Role.creator, decoded.hello.role);
    try std.testing.expectEqual(@as(u32, 0xFF8800), decoded.hello.color);
    try std.testing.expectEqualStrings("alice", decoded.hello.name);
}

test "pty_output roundtrip" {
    const payload = "hello, world\n";
    const frame = Frame{ .pty_output = .{ .data = payload } };
    var buf: [64]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqualStrings(payload, decoded.pty_output.data);
}

test "cursor_pos roundtrip" {
    const id: UserId = .{ 0xDE, 0xAD, 0xBE, 0xEF } ++ [_]u8{0} ** 12;
    const frame = Frame{ .cursor_pos = .{
        .user_id = id,
        .col = 42,
        .row = 7,
    } };
    var buf: [32]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(@as(u16, 42), decoded.cursor_pos.col);
    try std.testing.expectEqual(@as(u16, 7), decoded.cursor_pos.row);
    try std.testing.expectEqualSlices(u8, &id, &decoded.cursor_pos.user_id);
}

test "mode_change roundtrip" {
    var buf: [8]u8 = undefined;
    const n = try encode(Frame{ .mode_change = .{ .mode = .raw } }, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(Mode.raw, decoded.mode_change.mode);
}

test "heartbeat roundtrip" {
    var buf: [8]u8 = undefined;
    const n = try encode(Frame{ .heartbeat = {} }, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(Tag.heartbeat, @as(Tag, decoded));
}

test "input_commit roundtrip" {
    const id: UserId = [_]u8{0xAA} ** 16;
    var buf: [32]u8 = undefined;
    const n = try encode(Frame{ .input_commit = .{ .user_id = id } }, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqualSlices(u8, &id, &decoded.input_commit.user_id);
}

test "input_op roundtrip" {
    const op = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var buf: [32]u8 = undefined;
    const n = try encode(Frame{ .input_op = .{ .op = &op } }, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqualSlices(u8, &op, decoded.input_op.op);
}

test "fs_delta upsert roundtrip" {
    const content = "fn main() void {}\n";
    const frame = Frame{ .fs_delta = .{
        .op = .upsert,
        .path = "src/main.zig",
        .mtime_ns = 1_714_000_000_123_456_789,
        .content = content,
    } };
    var buf: [128]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(FsDeltaOp.upsert, decoded.fs_delta.op);
    try std.testing.expectEqualStrings("src/main.zig", decoded.fs_delta.path);
    try std.testing.expectEqual(
        @as(i64, 1_714_000_000_123_456_789),
        decoded.fs_delta.mtime_ns);
    try std.testing.expectEqualStrings(content, decoded.fs_delta.content);
}

test "fs_delta delete roundtrip" {
    const frame = Frame{ .fs_delta = .{
        .op = .delete,
        .path = "old/gone.txt",
        .mtime_ns = 0,
        .content = "",
    } };
    var buf: [64]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(FsDeltaOp.delete, decoded.fs_delta.op);
    try std.testing.expectEqualStrings("old/gone.txt", decoded.fs_delta.path);
    try std.testing.expectEqual(@as(usize, 0), decoded.fs_delta.content.len);
}

test "fs_delta rejects unknown op byte" {
    // tag=0x04, op=0x7F (invalid), path_len=0, mtime=0, content_len=0
    const bad = [_]u8{ 0x04, 0x7F, 0, 0 } ++ [_]u8{0} ** 8 ++ [_]u8{ 0, 0, 0, 0 };
    try std.testing.expectError(error.InvalidEnum, decode(&bad));
}

test "truncated input errors" {
    const short = [_]u8{ @intFromEnum(Tag.hello), 0, 0 };
    try std.testing.expectError(error.Truncated, decode(&short));
}

test "unknown tag errors" {
    const bad = [_]u8{0xFF};
    try std.testing.expectError(error.UnknownTag, decode(&bad));
}

test "buffer too small errors" {
    const frame = Frame{ .pty_output = .{ .data = "abcdefgh" } };
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encode(frame, &tiny));
}
