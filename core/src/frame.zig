//! Wire protocol: one-byte tag, big-endian integers, length-prefixed blobs.
//!
//! All frames share header: `tag:u8 | payload`. Decoding returns a tagged
//! union; encoding writes into a caller-provided buffer or allocates.
//!
//! FsDelta/FsSnapshot payloads are encoded/decoded structurally on the Swift
//! side; zig treats them as opaque payload blobs while still preserving the
//! shared tag assignments and transport framing.

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
    // --- collaborative editor frames (0x10..0x15) -------------------------
    // Tags start at 0x10 to leave room above the core session frames.
    /// Host announces an editor is open with initial file contents.
    editor_open = 0x10,
    /// Single CRDT op transported verbatim (see crdt.encodeOp format).
    editor_op = 0x11,
    /// Per-user caret + selection anchors, encoded as optional CrdtIds.
    editor_presence = 0x12,
    /// Peer requests the host save the editor buffer to disk.
    editor_save = 0x13,
    /// Host confirms a save and publishes the new revision number.
    editor_saved = 0x14,
    /// Host broadcasts editor teardown (after arbitration).
    editor_close = 0x15,
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

pub const FsDelta = struct {
    /// Encoded/decoded on the Swift side; zig treats the payload as opaque.
    payload: []const u8,
};

pub const FsSnapshot = struct {
    /// Encoded/decoded on the Swift side; zig treats the payload as opaque.
    payload: []const u8,
};

pub const CursorPos = struct {
    user_id: UserId,
    col: u16,
    row: u16,
};

pub const ModeChange = struct {
    mode: Mode,
};

/// Stable cursor anchor id matching the `client:u32 clock:u32` pair used by
/// `crdt.Id`. Declared here to avoid a direct dependency on `crdt.zig` from
/// the wire layer (keeps the codec and the CRDT module decoupled).
pub const CrdtId = struct {
    client: u32,
    clock: u32,
};

pub const EditorOpen = struct {
    doc_id: u64,
    /// UTF-8 path relative to the shared root; borrowed from input buffer.
    path: []const u8,
    /// Initial UTF-8 snapshot; borrowed from input buffer.
    snapshot: []const u8,
};

pub const EditorOp = struct {
    doc_id: u64,
    /// Opaque CRDT op bytes (see `crdt.encodeOp`).
    op_bytes: []const u8,
};

pub const EditorPresence = struct {
    doc_id: u64,
    user_id: u32,
    /// Caret anchor; null means "head" (before the first item).
    anchor: ?CrdtId,
    /// Selection anchor (other end of the selection); null = no selection.
    selection_anchor: ?CrdtId,
};

pub const EditorSave = struct {
    doc_id: u64,
};

pub const EditorSaved = struct {
    doc_id: u64,
    rev: u32,
};

pub const EditorClose = struct {
    doc_id: u64,
};

pub const Frame = union(Tag) {
    pty_output: PtyOutput,
    input_op: InputOp,
    input_commit: InputCommit,
    /// Encoded/decoded on the Swift side (FrameCodec); zig treats these as
    /// opaque bytes passing through the transport layer.
    fs_delta: FsDelta,
    /// Encoded/decoded on the Swift side (FrameCodec); zig treats these as
    /// opaque bytes passing through the transport layer.
    fs_snapshot: FsSnapshot,
    cursor_pos: CursorPos,
    hello: Hello,
    mode_change: ModeChange,
    /// Encoded/decoded on the Swift side (FrameCodec); zig treats these as
    /// opaque bytes passing through the transport layer.
    roster: void,
    heartbeat: void,
    editor_open: EditorOpen,
    editor_op: EditorOp,
    editor_presence: EditorPresence,
    editor_save: EditorSave,
    editor_saved: EditorSaved,
    editor_close: EditorClose,
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

    fn readU64(self: *Reader) !u64 {
        if (self.remaining() < 8) return error.Truncated;
        const v = std.mem.readInt(u64, self.buf[self.pos..][0..8], .big);
        self.pos += 8;
        return v;
    }

    fn readOptCrdtId(self: *Reader) !?CrdtId {
        const has = try self.readU8();
        if (has == 0) return null;
        if (has != 1) return error.InvalidEnum;
        const client = try self.readU32();
        const clock = try self.readU32();
        return CrdtId{ .client = client, .clock = clock };
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
        .heartbeat => Frame{ .heartbeat = {} },
        .editor_open => blk: {
            const doc_id = try r.readU64();
            const path_len = try r.readU16();
            const path = try r.readBytes(path_len);
            const snap_len = try r.readU32();
            const snapshot = try r.readBytes(snap_len);
            break :blk Frame{ .editor_open = .{
                .doc_id = doc_id,
                .path = path,
                .snapshot = snapshot,
            } };
        },
        .editor_op => blk: {
            const doc_id = try r.readU64();
            const n = try r.readU32();
            const op_bytes = try r.readBytes(n);
            break :blk Frame{ .editor_op = .{
                .doc_id = doc_id,
                .op_bytes = op_bytes,
            } };
        },
        .editor_presence => blk: {
            const doc_id = try r.readU64();
            const user_id = try r.readU32();
            const anchor = try r.readOptCrdtId();
            const sel = try r.readOptCrdtId();
            break :blk Frame{ .editor_presence = .{
                .doc_id = doc_id,
                .user_id = user_id,
                .anchor = anchor,
                .selection_anchor = sel,
            } };
        },
        .editor_save => blk: {
            const doc_id = try r.readU64();
            break :blk Frame{ .editor_save = .{ .doc_id = doc_id } };
        },
        .editor_saved => blk: {
            const doc_id = try r.readU64();
            const rev = try r.readU32();
            break :blk Frame{ .editor_saved = .{ .doc_id = doc_id, .rev = rev } };
        },
        .editor_close => blk: {
            const doc_id = try r.readU64();
            break :blk Frame{ .editor_close = .{ .doc_id = doc_id } };
        },
        .fs_delta => blk: {
            const payload = try r.readBytes(r.remaining());
            break :blk Frame{ .fs_delta = .{ .payload = payload } };
        },
        .fs_snapshot => blk: {
            const payload = try r.readBytes(r.remaining());
            break :blk Frame{ .fs_snapshot = .{ .payload = payload } };
        },
        .roster => error.NotImplemented,
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

    fn writeU64(self: *Writer, v: u64) !void {
        if (self.remaining() < 8) return error.BufferTooSmall;
        std.mem.writeInt(u64, self.buf[self.pos..][0..8], v, .big);
        self.pos += 8;
    }

    fn writeOptCrdtId(self: *Writer, v: ?CrdtId) !void {
        if (v) |id| {
            try self.writeU8(1);
            try self.writeU32(id.client);
            try self.writeU32(id.clock);
        } else {
            try self.writeU8(0);
        }
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
        .heartbeat => {},
        .editor_open => |p| {
            try w.writeU64(p.doc_id);
            try w.writeU16(@intCast(p.path.len));
            try w.writeBytes(p.path);
            try w.writeU32(@intCast(p.snapshot.len));
            try w.writeBytes(p.snapshot);
        },
        .editor_op => |p| {
            try w.writeU64(p.doc_id);
            try w.writeU32(@intCast(p.op_bytes.len));
            try w.writeBytes(p.op_bytes);
        },
        .editor_presence => |p| {
            try w.writeU64(p.doc_id);
            try w.writeU32(p.user_id);
            try w.writeOptCrdtId(p.anchor);
            try w.writeOptCrdtId(p.selection_anchor);
        },
        .editor_save => |p| try w.writeU64(p.doc_id),
        .editor_saved => |p| {
            try w.writeU64(p.doc_id);
            try w.writeU32(p.rev);
        },
        .editor_close => |p| try w.writeU64(p.doc_id),
        .fs_delta => |p| try w.writeBytes(p.payload),
        .fs_snapshot => |p| try w.writeBytes(p.payload),
        .roster => return error.BufferTooSmall, // NYI
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
        .heartbeat => 1,
        .editor_open => |p| 1 + 8 + 2 + p.path.len + 4 + p.snapshot.len,
        .editor_op => |p| 1 + 8 + 4 + p.op_bytes.len,
        // doc_id + user_id + two optional CrdtIds (each: 1 tag + up to 8 body)
        .editor_presence => 1 + 8 + 4 + (1 + 8) + (1 + 8),
        .editor_save => 1 + 8,
        .editor_saved => 1 + 8 + 4,
        .editor_close => 1 + 8,
        .fs_delta => |p| 1 + p.payload.len,
        .fs_snapshot => |p| 1 + p.payload.len,
        .roster => 1,
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

test "truncated input errors" {
    const short = [_]u8{ @intFromEnum(Tag.hello), 0, 0 };
    try std.testing.expectError(error.Truncated, decode(&short));
}

test "unknown tag errors" {
    const bad = [_]u8{0xFF};
    try std.testing.expectError(error.UnknownTag, decode(&bad));
}

test "editor_open roundtrip" {
    const snap = "hello\nworld\n";
    const frame = Frame{ .editor_open = .{
        .doc_id = 0x0102030405060708,
        .path = "src/foo.txt",
        .snapshot = snap,
    } };
    var buf: [128]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), decoded.editor_open.doc_id);
    try std.testing.expectEqualStrings("src/foo.txt", decoded.editor_open.path);
    try std.testing.expectEqualStrings(snap, decoded.editor_open.snapshot);
}

test "editor_op roundtrip" {
    const op = [_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE };
    const frame = Frame{ .editor_op = .{
        .doc_id = 42,
        .op_bytes = &op,
    } };
    var buf: [64]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 42), decoded.editor_op.doc_id);
    try std.testing.expectEqualSlices(u8, &op, decoded.editor_op.op_bytes);
}

test "editor_presence roundtrip with anchors" {
    const frame = Frame{ .editor_presence = .{
        .doc_id = 7,
        .user_id = 0xDEADBEEF,
        .anchor = CrdtId{ .client = 3, .clock = 99 },
        .selection_anchor = CrdtId{ .client = 3, .clock = 50 },
    } };
    var buf: [64]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 7), decoded.editor_presence.doc_id);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), decoded.editor_presence.user_id);
    try std.testing.expectEqual(@as(u32, 3), decoded.editor_presence.anchor.?.client);
    try std.testing.expectEqual(@as(u32, 99), decoded.editor_presence.anchor.?.clock);
    try std.testing.expectEqual(@as(u32, 50), decoded.editor_presence.selection_anchor.?.clock);
}

test "editor_presence roundtrip with null anchors" {
    const frame = Frame{ .editor_presence = .{
        .doc_id = 1,
        .user_id = 5,
        .anchor = null,
        .selection_anchor = null,
    } };
    var buf: [64]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expect(decoded.editor_presence.anchor == null);
    try std.testing.expect(decoded.editor_presence.selection_anchor == null);
}

test "editor_save roundtrip" {
    const frame = Frame{ .editor_save = .{ .doc_id = 0xFFFF_0000_FFFF_0000 } };
    var buf: [16]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 0xFFFF_0000_FFFF_0000), decoded.editor_save.doc_id);
}

test "editor_saved roundtrip" {
    const frame = Frame{ .editor_saved = .{ .doc_id = 9, .rev = 17 } };
    var buf: [16]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 9), decoded.editor_saved.doc_id);
    try std.testing.expectEqual(@as(u32, 17), decoded.editor_saved.rev);
}

test "editor_close roundtrip" {
    const frame = Frame{ .editor_close = .{ .doc_id = 123 } };
    var buf: [16]u8 = undefined;
    const n = try encode(frame, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqual(@as(u64, 123), decoded.editor_close.doc_id);
}

test "fs_delta opaque payload roundtrip" {
    const payload = [_]u8{ 0x00, 0x01, 0xFE, 0xFF, 0x10 };
    var buf: [32]u8 = undefined;
    const n = try encode(Frame{ .fs_delta = .{ .payload = &payload } }, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqualSlices(u8, &payload, decoded.fs_delta.payload);
}

test "fs_snapshot opaque payload roundtrip" {
    const payload = [_]u8{ 0xAA, 0xBB, 0xCC };
    var buf: [16]u8 = undefined;
    const n = try encode(Frame{ .fs_snapshot = .{ .payload = &payload } }, &buf);
    const decoded = try decode(buf[0..n]);
    try std.testing.expectEqualSlices(u8, &payload, decoded.fs_snapshot.payload);
}

test "buffer too small errors" {
    const frame = Frame{ .pty_output = .{ .data = "abcdefgh" } };
    var tiny: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encode(frame, &tiny));
}
