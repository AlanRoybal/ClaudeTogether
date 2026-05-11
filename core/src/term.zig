//! Opaque terminal handle that glues the VT parser to the cell grid.
//! Exposes a C ABI for Swift.

const std = @import("std");
const vt = @import("vt.zig");
const grid_mod = @import("grid.zig");
const utf8 = @import("utf8.zig");

pub const Term = struct {
    parser: vt.Parser,
    grid: grid_mod.Grid,
    decoder: utf8.Decoder,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !*Term {
        const self = try alloc.create(Term);
        self.* = .{
            .parser = vt.Parser.init(),
            .grid = try grid_mod.Grid.init(alloc, cols, rows),
            .decoder = utf8.Decoder.init(),
        };
        return self;
    }

    pub fn deinit(self: *Term, alloc: std.mem.Allocator) void {
        self.grid.deinit();
        alloc.destroy(self);
    }

    pub fn feed(self: *Term, bytes: []const u8) void {
        for (bytes) |b| {
            const ev = self.parser.feed(b) orelse continue;
            switch (ev) {
                .print => |pb| {
                    if (self.decoder.push(pb)) |cp| self.grid.putCodepoint(cp);
                },
                else => self.grid.apply(ev),
            }
        }
    }

    pub fn resize(self: *Term, cols: u16, rows: u16) !void {
        try self.grid.resize(cols, rows);
    }

    pub fn resizePreservingTop(self: *Term, cols: u16, rows: u16) !void {
        try self.grid.resizePreservingTop(cols, rows);
    }
};

// Global allocator for the Term lifecycle. Swift owns the handle pointer.
var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};

fn allocator() std.mem.Allocator {
    return gpa_state.allocator();
}

// ----- C ABI --------------------------------------------------------------

export fn ct_term_new(cols: u16, rows: u16) ?*Term {
    return Term.init(allocator(), cols, rows) catch null;
}

export fn ct_term_free(t: ?*Term) void {
    if (t) |p| p.deinit(allocator());
}

export fn ct_term_feed(t: ?*Term, bytes: [*]const u8, len: usize) void {
    if (t) |p| p.feed(bytes[0..len]);
}

export fn ct_term_resize(t: ?*Term, cols: u16, rows: u16) c_int {
    if (t) |p| {
        p.resize(cols, rows) catch return -1;
        return 0;
    }
    return -1;
}

export fn ct_term_resize_preserving_top(t: ?*Term, cols: u16, rows: u16) c_int {
    if (t) |p| {
        p.resizePreservingTop(cols, rows) catch return -1;
        return 0;
    }
    return -1;
}

/// Copy out the cell grid in row-major order.
/// `out` must have capacity >= cols*rows cells; writes min(capacity, cols*rows).
/// Returns the number of cells written.
export fn ct_term_snapshot(t: ?*Term, out: [*]grid_mod.Cell, capacity: usize) usize {
    if (t) |p| {
        const n = @min(capacity, p.grid.cells.len);
        @memcpy(out[0..n], p.grid.cells[0..n]);
        return n;
    }
    return 0;
}

export fn ct_term_scrollback_len(t: ?*Term) u32 {
    if (t) |p| return p.grid.scrollbackLen();
    return 0;
}

export fn ct_term_scrollback_snapshot(
    t: ?*Term,
    start_row: u32,
    num_rows: u32,
    out: [*]grid_mod.Cell,
    capacity: usize,
) u32 {
    if (t) |p| {
        return p.grid.copyScrollback(
            start_row,
            num_rows,
            out[0..capacity]);
    }
    return 0;
}

export fn ct_term_size(t: ?*Term, out_cols: *u16, out_rows: *u16) void {
    if (t) |p| {
        out_cols.* = p.grid.cols;
        out_rows.* = p.grid.rows;
    }
}

export fn ct_term_cursor(t: ?*Term, out_x: *u16, out_y: *u16) void {
    if (t) |p| {
        out_x.* = p.grid.cursor_x;
        out_y.* = p.grid.cursor_y;
    }
}

/// Returns 1 while the terminal is rendering its alternate screen buffer
/// (typical full-screen TUIs like vim/less), 0 otherwise.
export fn ct_term_is_using_alt(t: ?*Term) c_int {
    if (t) |p| return if (p.grid.using_alt) 1 else 0;
    return 0;
}

/// Monotonically increasing counter bumped on any grid mutation.
/// Swift should redraw when this changes.
export fn ct_term_dirty_epoch(t: ?*Term) u32 {
    if (t) |p| return p.grid.epoch;
    return 0;
}

/// Returns the active mouse-reporting bitmask. See `Grid.mouse_mode` for the
/// bit layout. 0 means the running app has not requested any mouse mode and
/// macOS mouse events should fall through to default NSView behavior.
export fn ct_term_mouse_mode(t: ?*Term) u32 {
    if (t) |p| return p.grid.mouse_mode;
    return 0;
}

/// Returns 1 when the running app has enabled bracketed paste mode (DECSET ?2004h),
/// 0 otherwise. Swift paste handlers wrap clipboard bytes in \x1b[200~ / \x1b[201~
/// when this is set.
export fn ct_term_bracketed_paste_mode(t: ?*Term) c_int {
    if (t) |p| return if (p.grid.bracketed_paste_mode) 1 else 0;
    return 0;
}

test "C ABI exposes terminal scrollback rows" {
    const testing = std.testing;
    var term = try Term.init(testing.allocator, 4, 2);
    defer term.deinit(testing.allocator);

    const bytes = "A\r\nB\r\nC\r\n";
    ct_term_feed(term, bytes.ptr, bytes.len);
    try testing.expect(ct_term_scrollback_len(term) >= 1);

    var row: [4]grid_mod.Cell = undefined;
    const copied = ct_term_scrollback_snapshot(
        term,
        0,
        1,
        row[0..].ptr,
        row.len);
    try testing.expectEqual(@as(u32, 1), copied);
    try testing.expectEqual(@as(u32, 'A'), row[0].codepoint);
}
