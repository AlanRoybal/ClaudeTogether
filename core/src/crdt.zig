//! Shared-input CRDT: RGA-style sequence of UTF-32 codepoints keyed by
//! (client, lamport). One instance represents a single shared prompt line.
//!
//! Model:
//!   - Each inserted codepoint becomes an Item with a globally unique Id and
//!     an `after` pointer to the Id it was inserted after (or null for the
//!     head of the line).
//!   - Concurrent inserts at the same `after` position are ordered by Id
//!     descending (later/larger client wins tiebreak), matching Yjs/YATA.
//!   - Deletes are tombstones; the item stays in the sequence so remote
//!     inserts that reference it still resolve.
//!
//! Scope: intentionally minimal for a command-input line. Not suitable for
//! large documents — operations are O(n) in number of items.

const std = @import("std");
const testing = std.testing;

pub const Id = struct {
    client: u32,
    clock: u32,

    pub fn eql(a: Id, b: Id) bool {
        return a.client == b.client and a.clock == b.clock;
    }

    /// Total order: higher clock first; tiebreak by higher client id.
    pub fn greaterThan(a: Id, b: Id) bool {
        if (a.clock != b.clock) return a.clock > b.clock;
        return a.client > b.client;
    }
};

pub const Item = struct {
    id: Id,
    after: ?Id, // null = inserted at head
    codepoint: u32,
    deleted: bool,
};

pub const OpKind = enum(u8) { insert = 0, delete = 1 };

/// Wire-format op emitted by local edits, consumed by `apply` on remotes.
/// Binary layout (big-endian) — see encode/decode below:
///   kind:u8
///   id.client:u32  id.clock:u32
///   if insert:
///     has_after:u8  (0 = null, 1 = present)
///     if has_after: after.client:u32  after.clock:u32
///     codepoint:u32
pub const Op = union(OpKind) {
    insert: struct {
        id: Id,
        after: ?Id,
        codepoint: u32,
    },
    delete: struct { id: Id },
};

pub const Sequence = struct {
    const snapshot_client: u32 = 0;
    const encoded_snapshot_magic = "CTDS";
    const encoded_snapshot_version: u8 = 1;
    const encoded_snapshot_header_len: usize = 4 + 1 + 4;
    const encoded_snapshot_item_len: usize = 8 + 1 + 8 + 4 + 1;

    allocator: std.mem.Allocator,
    client: u32,
    clock: u32 = 0,
    /// Items in visible / walk order. Tombstones included.
    items: std.ArrayList(Item),

    pub fn init(allocator: std.mem.Allocator, client: u32) Sequence {
        return .{
            .allocator = allocator,
            .client = client,
            .items = .empty,
        };
    }

    pub fn deinit(self: *Sequence) void {
        self.items.deinit(self.allocator);
    }

    /// Number of live (non-tombstone) codepoints.
    pub fn len(self: *const Sequence) usize {
        var n: usize = 0;
        for (self.items.items) |it| {
            if (!it.deleted) n += 1;
        }
        return n;
    }

    /// Materialize into a UTF-8 string. Caller owns returned slice.
    pub fn toUtf8(self: *const Sequence, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var tmp: [4]u8 = undefined;
        for (self.items.items) |it| {
            if (it.deleted) continue;
            // Items are sanitized on apply, but never trust stored state to
            // the point of a panic: map anything invalid to U+FFFD here too.
            const cp: u21 = std.math.cast(u21, it.codepoint) orelse 0xFFFD;
            const n = std.unicode.utf8Encode(cp, &tmp) catch
                std.unicode.utf8Encode(0xFFFD, &tmp) catch unreachable;
            try out.appendSlice(allocator, tmp[0..n]);
        }
        return out.toOwnedSlice(allocator);
    }

    /// Insert `codepoint` before the visible item at `visible_pos` (0 = head,
    /// len() = end). Returns the generated op. Caller is expected to ship
    /// the op to peers via `encodeOp`.
    pub fn localInsert(self: *Sequence, visible_pos: usize, codepoint: u32) !Op {
        const after_id = self.idBeforeVisiblePos(visible_pos);
        self.clock += 1;
        const new_id = Id{ .client = self.client, .clock = self.clock };
        const op = Op{ .insert = .{
            .id = new_id,
            .after = after_id,
            .codepoint = codepoint,
        } };
        try self.applyInsert(new_id, after_id, codepoint);
        return op;
    }

    /// Delete the visible item at `visible_pos` (0-based, live items only).
    /// No-op if out of range.
    pub fn localDelete(self: *Sequence, visible_pos: usize) !?Op {
        const idx = self.rawIndexOfVisiblePos(visible_pos) orelse return null;
        const target = self.items.items[idx].id;
        self.items.items[idx].deleted = true;
        return Op{ .delete = .{ .id = target } };
    }

    /// Apply a remote op idempotently. Returns true if state changed.
    pub fn apply(self: *Sequence, op: Op) !bool {
        switch (op) {
            .insert => |i| {
                // idempotent: ignore if id already present
                for (self.items.items) |it| {
                    if (Id.eql(it.id, i.id)) return false;
                }
                // advance local clock so subsequent local ops are > any seen id
                if (i.id.clock > self.clock) self.clock = i.id.clock;
                // A hostile peer can ship any u32 as a codepoint (surrogates,
                // > U+10FFFF). Substitute U+FFFD instead of rejecting so the
                // item id stays in the sequence and later ops anchored to it
                // still resolve; the substitution is deterministic, so all
                // replicas converge.
                try self.applyInsert(i.id, i.after, sanitizeCodepoint(i.codepoint));
                return true;
            },
            .delete => |d| {
                for (self.items.items) |*it| {
                    if (Id.eql(it.id, d.id)) {
                        if (it.deleted) return false;
                        it.deleted = true;
                        return true;
                    }
                }
                return false;
            },
        }
    }

    /// Remove all items (live and tombstones). Called after a commit/enter.
    pub fn clear(self: *Sequence) void {
        self.items.clearRetainingCapacity();
    }

    pub fn isEncodedSnapshot(bytes: []const u8) bool {
        return bytes.len >= encoded_snapshot_magic.len + 1 and
            std.mem.eql(u8, bytes[0..encoded_snapshot_magic.len], encoded_snapshot_magic) and
            bytes[encoded_snapshot_magic.len] == encoded_snapshot_version;
    }

    pub fn encodedSnapshotLen(self: *const Sequence) usize {
        return encoded_snapshot_header_len +
            self.items.items.len * encoded_snapshot_item_len;
    }

    /// Serialize the full CRDT item list, including tombstones and item ids.
    /// This is used for editor-open/join snapshots after live edits already
    /// exist; plain UTF-8 snapshots cannot preserve anchors for late joiners.
    pub fn encodeSnapshot(self: *const Sequence, out: []u8) !usize {
        const required = self.encodedSnapshotLen();
        if (out.len < required) return error.BufferTooSmall;

        var pos: usize = 0;
        @memcpy(out[pos..][0..encoded_snapshot_magic.len], encoded_snapshot_magic);
        pos += encoded_snapshot_magic.len;
        out[pos] = encoded_snapshot_version;
        pos += 1;
        std.mem.writeInt(u32, out[pos..][0..4], @intCast(self.items.items.len), .big);
        pos += 4;

        for (self.items.items) |item| {
            std.mem.writeInt(u32, out[pos..][0..4], item.id.client, .big);
            pos += 4;
            std.mem.writeInt(u32, out[pos..][0..4], item.id.clock, .big);
            pos += 4;
            if (item.after) |after| {
                out[pos] = 1;
                pos += 1;
                std.mem.writeInt(u32, out[pos..][0..4], after.client, .big);
                pos += 4;
                std.mem.writeInt(u32, out[pos..][0..4], after.clock, .big);
                pos += 4;
            } else {
                out[pos] = 0;
                pos += 1;
                std.mem.writeInt(u32, out[pos..][0..4], 0, .big);
                pos += 4;
                std.mem.writeInt(u32, out[pos..][0..4], 0, .big);
                pos += 4;
            }
            std.mem.writeInt(u32, out[pos..][0..4], item.codepoint, .big);
            pos += 4;
            out[pos] = if (item.deleted) 1 else 0;
            pos += 1;
        }

        return pos;
    }

    /// Replace the sequence with a full CRDT snapshot produced by
    /// `encodeSnapshot`.
    pub fn loadEncodedSnapshot(self: *Sequence, bytes: []const u8) !void {
        if (!isEncodedSnapshot(bytes)) return error.InvalidSnapshot;
        var pos: usize = encoded_snapshot_magic.len + 1;
        const count = try readSnapshotU32(bytes, &pos);
        const required = encoded_snapshot_header_len +
            @as(usize, count) * encoded_snapshot_item_len;
        if (bytes.len != required) return error.Truncated;

        var next: std.ArrayList(Item) = .empty;
        errdefer next.deinit(self.allocator);
        try next.ensureTotalCapacity(self.allocator, @intCast(count));

        var max_clock: u32 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const id = Id{
                .client = try readSnapshotU32(bytes, &pos),
                .clock = try readSnapshotU32(bytes, &pos),
            };
            const has_after = try readSnapshotU8(bytes, &pos);
            const after_client = try readSnapshotU32(bytes, &pos);
            const after_clock = try readSnapshotU32(bytes, &pos);
            const codepoint = try readSnapshotU32(bytes, &pos);
            const deleted_byte = try readSnapshotU8(bytes, &pos);

            const after: ?Id = switch (has_after) {
                0 => null,
                1 => Id{ .client = after_client, .clock = after_clock },
                else => return error.InvalidSnapshot,
            };
            const deleted = switch (deleted_byte) {
                0 => false,
                1 => true,
                else => return error.InvalidSnapshot,
            };

            for (next.items) |existing| {
                if (Id.eql(existing.id, id)) return error.InvalidSnapshot;
            }
            // Sanitize invalid/surrogate/out-of-range codepoints to U+FFFD
            // rather than rejecting the whole snapshot — this matches apply(),
            // so the same hostile value converges identically whether it
            // arrives as a live op or inside a join snapshot.
            const safe_cp = sanitizeCodepoint(codepoint);

            if (id.clock > max_clock) max_clock = id.clock;
            next.appendAssumeCapacity(.{
                .id = id,
                .after = after,
                .codepoint = safe_cp,
                .deleted = deleted,
            });
        }

        self.items.deinit(self.allocator);
        self.items = next;
        self.clock = max_clock;
    }

    /// Bulk-insert the UTF-8-decoded codepoints of `s` at the end of the
    /// sequence. Snapshot-loaded items always use the reserved
    /// `snapshot_client` so every replica derives the same ids for the same
    /// initial file contents; that keeps stable cursor anchors meaningful
    /// across peers before any live edits happen. Existing items are
    /// preserved; insertions land after the current last live item.
    pub fn loadFromString(self: *Sequence, s: []const u8) !void {
        var next_snapshot_clock = self.maxClockForClient(snapshot_client) + 1;
        var view = try std.unicode.Utf8View.init(s);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const after_id = self.idBeforeVisiblePos(self.len());
            const new_id = Id{
                .client = snapshot_client,
                .clock = next_snapshot_clock,
            };
            next_snapshot_clock += 1;
            if (new_id.clock > self.clock) self.clock = new_id.clock;
            try self.applyInsert(new_id, after_id, cp);
        }
    }

    /// Return the `Id` of the live item at visible offset `visible_pos`
    /// (0-based, live items only), or null if `visible_pos >= len()`.
    /// Used as a cursor anchor ("my caret sits on this character").
    pub fn idAtVisiblePos(self: *const Sequence, visible_pos: usize) ?Id {
        var live: usize = 0;
        for (self.items.items) |it| {
            if (it.deleted) continue;
            if (live == visible_pos) return it.id;
            live += 1;
        }
        return null;
    }

    /// Find the item with `id` and return its visible offset among live
    /// items. If the item is a tombstone, returns the visible offset of the
    /// next live item after it (or `len()` if none follow). Returns null
    /// only if the `id` is not in the sequence at all.
    pub fn visiblePosOfId(self: *const Sequence, id: Id) ?usize {
        var live: usize = 0;
        var found_idx: ?usize = null;
        for (self.items.items, 0..) |it, i| {
            if (Id.eql(it.id, id)) {
                found_idx = i;
                break;
            }
            if (!it.deleted) live += 1;
        }
        if (found_idx == null) return null;
        const idx = found_idx.?;
        const item = self.items.items[idx];
        if (!item.deleted) return live;
        // Tombstone: walk forward to the next live item.
        var j = idx + 1;
        while (j < self.items.items.len) : (j += 1) {
            if (!self.items.items[j].deleted) return live;
        }
        return live; // equals len() — no live item follows.
    }

    // --- internals --------------------------------------------------------

    fn applyInsert(self: *Sequence, id: Id, after: ?Id, cp: u32) !void {
        // Start position: right after the item with id = after, or 0 if head.
        var idx: usize = 0;
        if (after) |a| {
            if (self.indexOfId(a)) |found| {
                idx = found + 1;
            } else {
                // Reference is unknown — insert at end as a safe fallback.
                // (Normal operation: peer sent this op after the referenced
                // item, so we have it. Out-of-order arrival falls here.)
                idx = self.items.items.len;
            }
        }
        // RGA tiebreak: while the item at idx is a concurrent sibling (same
        // `after`) with id > new id, skip it — together with its entire
        // subtree, since its children sit between it and the next sibling in
        // document order. Skipping only the sibling itself would drop the new
        // item inside that sibling's subtree and replicas would diverge.
        while (idx < self.items.items.len) {
            const cur = self.items.items[idx];
            const same_origin = sameOptId(cur.after, after);
            if (same_origin and Id.greaterThan(cur.id, id)) {
                idx = self.subtreeEnd(idx);
            } else break;
        }
        try self.items.insert(self.allocator, idx, .{
            .id = id,
            .after = after,
            .codepoint = cp,
            .deleted = false,
        });
    }

    /// Index one past the subtree rooted at `root_idx`. Document order is a
    /// depth-first traversal of the origin tree, so a subtree is a contiguous
    /// run: walk forward while each item's origin lies inside the run.
    fn subtreeEnd(self: *const Sequence, root_idx: usize) usize {
        var end = root_idx + 1;
        outer: while (end < self.items.items.len) : (end += 1) {
            const a = self.items.items[end].after orelse break;
            var j = root_idx;
            while (j < end) : (j += 1) {
                if (Id.eql(self.items.items[j].id, a)) continue :outer;
            }
            break;
        }
        return end;
    }

    fn sameOptId(a: ?Id, b: ?Id) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return Id.eql(a.?, b.?);
    }

    fn indexOfId(self: *const Sequence, id: Id) ?usize {
        for (self.items.items, 0..) |it, i| {
            if (Id.eql(it.id, id)) return i;
        }
        return null;
    }

    fn maxClockForClient(self: *const Sequence, client: u32) u32 {
        var max_clock: u32 = 0;
        for (self.items.items) |it| {
            if (it.id.client == client and it.id.clock > max_clock) {
                max_clock = it.id.clock;
            }
        }
        return max_clock;
    }

    /// Id of the live item just before `visible_pos`, or null if at head.
    fn idBeforeVisiblePos(self: *const Sequence, visible_pos: usize) ?Id {
        if (visible_pos == 0) return null;
        var live: usize = 0;
        for (self.items.items) |it| {
            if (it.deleted) continue;
            live += 1;
            if (live == visible_pos) return it.id;
        }
        // past end → anchor to last live item (or null if empty)
        var last: ?Id = null;
        for (self.items.items) |it| {
            if (!it.deleted) last = it.id;
        }
        return last;
    }

    fn rawIndexOfVisiblePos(self: *const Sequence, visible_pos: usize) ?usize {
        var live: usize = 0;
        for (self.items.items, 0..) |it, i| {
            if (it.deleted) continue;
            if (live == visible_pos) return i;
            live += 1;
        }
        return null;
    }
};

/// Map anything that is not a valid Unicode scalar value to U+FFFD.
fn sanitizeCodepoint(cp: u32) u32 {
    if (cp > 0x10FFFF) return 0xFFFD;
    if (cp >= 0xD800 and cp <= 0xDFFF) return 0xFFFD;
    return cp;
}

fn readSnapshotU8(bytes: []const u8, pos: *usize) !u8 {
    if (pos.* + 1 > bytes.len) return error.Truncated;
    const value = bytes[pos.*];
    pos.* += 1;
    return value;
}

fn readSnapshotU32(bytes: []const u8, pos: *usize) !u32 {
    if (pos.* + 4 > bytes.len) return error.Truncated;
    const value = std.mem.readInt(u32, bytes[pos.*..][0..4], .big);
    pos.* += 4;
    return value;
}

// --- op wire encoding -----------------------------------------------------

pub fn encodeOp(op: Op, out: []u8) !usize {
    if (out.len < 1) return error.BufferTooSmall;
    out[0] = @intFromEnum(@as(OpKind, op));
    var pos: usize = 1;
    switch (op) {
        .insert => |i| {
            if (out.len < pos + 4 + 4 + 1) return error.BufferTooSmall;
            std.mem.writeInt(u32, out[pos..][0..4], i.id.client, .big);
            pos += 4;
            std.mem.writeInt(u32, out[pos..][0..4], i.id.clock, .big);
            pos += 4;
            out[pos] = if (i.after == null) 0 else 1;
            pos += 1;
            if (i.after) |a| {
                if (out.len < pos + 8) return error.BufferTooSmall;
                std.mem.writeInt(u32, out[pos..][0..4], a.client, .big);
                pos += 4;
                std.mem.writeInt(u32, out[pos..][0..4], a.clock, .big);
                pos += 4;
            }
            if (out.len < pos + 4) return error.BufferTooSmall;
            std.mem.writeInt(u32, out[pos..][0..4], i.codepoint, .big);
            pos += 4;
        },
        .delete => |d| {
            if (out.len < pos + 8) return error.BufferTooSmall;
            std.mem.writeInt(u32, out[pos..][0..4], d.id.client, .big);
            pos += 4;
            std.mem.writeInt(u32, out[pos..][0..4], d.id.clock, .big);
            pos += 4;
        },
    }
    return pos;
}

pub fn decodeOp(bytes: []const u8) !Op {
    if (bytes.len < 1) return error.Truncated;
    const kind = std.enums.fromInt(OpKind, bytes[0]) orelse return error.InvalidEnum;
    var pos: usize = 1;
    switch (kind) {
        .insert => {
            if (bytes.len < pos + 8 + 1 + 4) return error.Truncated;
            const client = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            pos += 4;
            const clock = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            pos += 4;
            const has_after = bytes[pos];
            pos += 1;
            var after: ?Id = null;
            if (has_after == 1) {
                if (bytes.len < pos + 8) return error.Truncated;
                const ac = std.mem.readInt(u32, bytes[pos..][0..4], .big);
                pos += 4;
                const al = std.mem.readInt(u32, bytes[pos..][0..4], .big);
                pos += 4;
                after = Id{ .client = ac, .clock = al };
            }
            if (bytes.len < pos + 4) return error.Truncated;
            const cp = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            return Op{ .insert = .{
                .id = .{ .client = client, .clock = clock },
                .after = after,
                .codepoint = cp,
            } };
        },
        .delete => {
            if (bytes.len < pos + 8) return error.Truncated;
            const client = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            pos += 4;
            const clock = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            return Op{ .delete = .{
                .id = .{ .client = client, .clock = clock },
            } };
        },
    }
}

// --- tests ----------------------------------------------------------------

test "single user insert + delete" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();

    _ = try s.localInsert(0, 'h');
    _ = try s.localInsert(1, 'i');
    const got = try s.toUtf8(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hi", got);

    _ = try s.localDelete(0);
    const got2 = try s.toUtf8(testing.allocator);
    defer testing.allocator.free(got2);
    try testing.expectEqualStrings("i", got2);
}

test "two users converge on disjoint inserts" {
    var a = Sequence.init(testing.allocator, 1);
    defer a.deinit();
    var b = Sequence.init(testing.allocator, 2);
    defer b.deinit();

    // Shared starting state: "ab"
    const op1 = try a.localInsert(0, 'a');
    const op2 = try a.localInsert(1, 'b');
    _ = try b.apply(op1);
    _ = try b.apply(op2);

    // A inserts X between a and b. B inserts Y at end.
    const opA = try a.localInsert(1, 'X');
    const opB = try b.localInsert(2, 'Y');
    _ = try b.apply(opA);
    _ = try a.apply(opB);

    const sA = try a.toUtf8(testing.allocator);
    defer testing.allocator.free(sA);
    const sB = try b.toUtf8(testing.allocator);
    defer testing.allocator.free(sB);
    try testing.expectEqualStrings(sA, sB);
    try testing.expectEqualStrings("aXbY", sA);
}

test "concurrent inserts at same origin converge" {
    var a = Sequence.init(testing.allocator, 1);
    defer a.deinit();
    var b = Sequence.init(testing.allocator, 2);
    defer b.deinit();

    const base = try a.localInsert(0, 'x');
    _ = try b.apply(base);

    // Both insert after 'x' at the same visible position concurrently.
    const opA = try a.localInsert(1, 'A');
    const opB = try b.localInsert(1, 'B');
    _ = try b.apply(opA);
    _ = try a.apply(opB);

    const sA = try a.toUtf8(testing.allocator);
    defer testing.allocator.free(sA);
    const sB = try b.toUtf8(testing.allocator);
    defer testing.allocator.free(sB);
    try testing.expectEqualStrings(sA, sB);
    // RGA tiebreak: higher client id wins earlier slot, so client 2 ('B')
    // precedes client 1 ('A') after 'x'.
    try testing.expectEqualStrings("xBA", sA);
}

test "delete is idempotent" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    _ = try s.localInsert(0, 'a');
    const del = try s.localDelete(0);
    try testing.expect(del != null);
    // Re-applying the same delete does not change state.
    const changed = try s.apply(del.?);
    try testing.expect(!changed);
}

test "op roundtrip" {
    const op = Op{ .insert = .{
        .id = .{ .client = 7, .clock = 42 },
        .after = .{ .client = 3, .clock = 9 },
        .codepoint = 'Z',
    } };
    var buf: [32]u8 = undefined;
    const n = try encodeOp(op, &buf);
    const got = try decodeOp(buf[0..n]);
    try testing.expectEqual(op.insert.id, got.insert.id);
    try testing.expectEqual(op.insert.after.?, got.insert.after.?);
    try testing.expectEqual(op.insert.codepoint, got.insert.codepoint);

    const delop = Op{ .delete = .{ .id = .{ .client = 5, .clock = 100 } } };
    const n2 = try encodeOp(delop, &buf);
    const got2 = try decodeOp(buf[0..n2]);
    try testing.expectEqual(delop.delete.id, got2.delete.id);
}

test "loadFromString empty" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    try s.loadFromString("");
    try testing.expectEqual(@as(usize, 0), s.len());
    const got = try s.toUtf8(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("", got);
}

test "loadFromString ascii roundtrip" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    try s.loadFromString("hello");
    const got = try s.toUtf8(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
}

test "loadFromString multibyte utf8 roundtrip" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    try s.loadFromString("héllo\nworld");
    const got = try s.toUtf8(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("héllo\nworld", got);
    // 'é' is one codepoint, so len is 11 (not 12 bytes).
    try testing.expectEqual(@as(usize, 11), s.len());
}

test "loadFromString uses replica-stable ids" {
    var a = Sequence.init(testing.allocator, 101);
    defer a.deinit();
    var b = Sequence.init(testing.allocator, 202);
    defer b.deinit();

    try a.loadFromString("hello");
    try b.loadFromString("hello");

    for (0..5) |idx| {
        try testing.expectEqual(a.idAtVisiblePos(idx).?, b.idAtVisiblePos(idx).?);
    }
}

test "encoded snapshot preserves live edit anchors for late join" {
    var host = Sequence.init(testing.allocator, 101);
    defer host.deinit();
    try host.loadFromString("abc");

    // Host has already edited before this peer joins.
    _ = try host.localInsert(1, 'H');
    const host_before = try host.toUtf8(testing.allocator);
    defer testing.allocator.free(host_before);
    try testing.expectEqualStrings("aHbc", host_before);

    const snapshot_len = host.encodedSnapshotLen();
    const snapshot = try testing.allocator.alloc(u8, snapshot_len);
    defer testing.allocator.free(snapshot);
    const n = try host.encodeSnapshot(snapshot);

    var guest = Sequence.init(testing.allocator, 202);
    defer guest.deinit();
    try guest.loadEncodedSnapshot(snapshot[0..n]);
    const guest_before = try guest.toUtf8(testing.allocator);
    defer testing.allocator.free(guest_before);
    try testing.expectEqualStrings("aHbc", guest_before);
    try testing.expectEqual(host.idAtVisiblePos(1).?, guest.idAtVisiblePos(1).?);

    // Guest inserts after the host-authored "H". If the join snapshot had
    // only been plain text, the host would not know that anchor id and the
    // insert would fall back to the end.
    const guest_op = try guest.localInsert(2, 'G');
    _ = try host.apply(guest_op);

    const host_after = try host.toUtf8(testing.allocator);
    defer testing.allocator.free(host_after);
    const guest_after = try guest.toUtf8(testing.allocator);
    defer testing.allocator.free(guest_after);
    try testing.expectEqualStrings("aHGbc", host_after);
    try testing.expectEqualStrings(host_after, guest_after);
}

test "idAtVisiblePos basic" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    try s.loadFromString("abc");
    const a = s.idAtVisiblePos(0).?;
    const b = s.idAtVisiblePos(1).?;
    const c = s.idAtVisiblePos(2).?;
    try testing.expect(!Id.eql(a, b));
    try testing.expect(!Id.eql(b, c));
    try testing.expect(!Id.eql(a, c));
    try testing.expect(s.idAtVisiblePos(3) == null);
}

test "visiblePosOfId after delete before" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    try s.loadFromString("abc");
    const id_b = s.idAtVisiblePos(1).?;
    _ = try s.localDelete(0); // delete 'a'
    try testing.expectEqual(@as(?usize, 0), s.visiblePosOfId(id_b));
}

test "visiblePosOfId tombstone falls back to next live" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    try s.loadFromString("abc");
    const id_b = s.idAtVisiblePos(1).?;
    _ = try s.localDelete(1); // tombstone 'b'; 'c' now at visible pos 1
    try testing.expectEqual(@as(?usize, 1), s.visiblePosOfId(id_b));
}

test "visiblePosOfId not in sequence returns null" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    try s.loadFromString("abc");
    const bogus = Id{ .client = 999, .clock = 999 };
    try testing.expect(s.visiblePosOfId(bogus) == null);
}

test "concurrent insert does not land inside a greater sibling's subtree" {
    var a = Sequence.init(testing.allocator, 1);
    defer a.deinit();
    var b = Sequence.init(testing.allocator, 2);
    defer b.deinit();

    const opX = try a.localInsert(0, 'X');
    _ = try b.apply(opX);

    // Concurrently: client 1 inserts 'A' after X; client 2 inserts 'B' after
    // X and then a child 'b' after B.
    const opA = try a.localInsert(1, 'A');
    const opB = try b.localInsert(1, 'B');
    const opB1 = try b.localInsert(2, 'b');

    // FIFO delivery per sender (the realistic star-topology order).
    _ = try a.apply(opB);
    _ = try a.apply(opB1);
    _ = try b.apply(opA);

    const sA = try a.toUtf8(testing.allocator);
    defer testing.allocator.free(sA);
    const sB = try b.toUtf8(testing.allocator);
    defer testing.allocator.free(sB);
    try testing.expectEqualStrings(sA, sB);
    // 'A' must land after B's whole subtree, never between B and b.
    try testing.expectEqualStrings("XBbA", sA);
}

test "apply sanitizes invalid codepoints instead of panicking" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    // Surrogate and out-of-range values from a hostile peer.
    _ = try s.apply(.{ .insert = .{
        .id = .{ .client = 9, .clock = 1 },
        .after = null,
        .codepoint = 0xD800,
    } });
    _ = try s.apply(.{ .insert = .{
        .id = .{ .client = 9, .clock = 2 },
        .after = .{ .client = 9, .clock = 1 },
        .codepoint = 0xFFFFFFFF,
    } });
    const got = try s.toUtf8(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("\u{FFFD}\u{FFFD}", got);
}

test "apply insert before its origin arrives falls back to end" {
    var s = Sequence.init(testing.allocator, 1);
    defer s.deinit();
    // Referenced item never applied; insert should land at end safely.
    const op = Op{ .insert = .{
        .id = .{ .client = 9, .clock = 1 },
        .after = .{ .client = 99, .clock = 99 },
        .codepoint = 'q',
    } };
    _ = try s.apply(op);
    const got = try s.toUtf8(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("q", got);
}
