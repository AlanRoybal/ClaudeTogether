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
    allocator: std.mem.Allocator,
    client: u32,
    clock: u32 = 0,
    /// Items in visible / walk order. Tombstones included.
    items: std.ArrayList(Item),

    pub fn init(allocator: std.mem.Allocator, client: u32) Sequence {
        return .{
            .allocator = allocator,
            .client = client,
            .items = std.ArrayList(Item).init(allocator),
        };
    }

    pub fn deinit(self: *Sequence) void {
        self.items.deinit();
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
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();
        var tmp: [4]u8 = undefined;
        for (self.items.items) |it| {
            if (it.deleted) continue;
            const n = try std.unicode.utf8Encode(
                @intCast(it.codepoint),
                &tmp,
            );
            try out.appendSlice(tmp[0..n]);
        }
        return out.toOwnedSlice();
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
                try self.applyInsert(i.id, i.after, i.codepoint);
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

    /// Bulk-insert the UTF-8-decoded codepoints of `s` at the end of the
    /// sequence. Each codepoint becomes a full CRDT `Item` authored by
    /// `self.client` with monotonically increasing clocks, so concurrent
    /// edits during/after load behave correctly. Existing items are
    /// preserved; insertions land after the current last live item.
    pub fn loadFromString(self: *Sequence, s: []const u8) !void {
        var view = try std.unicode.Utf8View.init(s);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            const after_id = self.idBeforeVisiblePos(self.len());
            self.clock += 1;
            const new_id = Id{ .client = self.client, .clock = self.clock };
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
        // RGA tiebreak: while the item at idx has the same `after` and its
        // id > new id, skip forward. This interleaves concurrent inserts at
        // the same origin in id-descending order.
        while (idx < self.items.items.len) {
            const cur = self.items.items[idx];
            const same_origin = sameOptId(cur.after, after);
            if (same_origin and Id.greaterThan(cur.id, id)) {
                idx += 1;
            } else break;
        }
        try self.items.insert(idx, .{
            .id = id,
            .after = after,
            .codepoint = cp,
            .deleted = false,
        });
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
    const kind = std.meta.intToEnum(OpKind, bytes[0]) catch return error.InvalidEnum;
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
