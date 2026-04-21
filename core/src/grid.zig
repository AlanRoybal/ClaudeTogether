//! Terminal cell grid. Applies parser events to mutate cells + cursor.
//!
//! Covered:
//! - Cell stores codepoint + fg + bg + attrs + width (1 = normal, 2 = lead of
//!   wide char, 0 = trailing half of a wide char / zero-width).
//! - Cursor moves: CUP/HVP, CUU/CUD/CUF/CUB, CHA, CNL/CPL.
//! - Erase: ED (0/1/2), EL (0/1/2).
//! - SGR: reset, bold, italic, underline, reverse, dim, 16-color, 256-color,
//!   truecolor, defaults.
//! - C0 executes: LF/VT/FF, CR, BS, BEL, HT.
//! - Save/restore cursor: CSI s/u, ESC 7/8 (DECSC/DECRC — via term.zig).
//! - Private-mode switches (CSI ?h / ?l): 47, 1047, 1048, 1049 (alt screen).
//! - Scrollback ring buffer (~10K rows) for the primary buffer.
//!
//! Not yet: scrolling regions (DECSTBM), tab stops beyond 8-col fixed.

const std = @import("std");
const vt = @import("vt.zig");
const utf8 = @import("utf8.zig");

pub const Attrs = packed struct(u16) {
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    dim: bool = false,
    _pad: u11 = 0,
};

pub const Cell = extern struct {
    codepoint: u32 = ' ',
    fg: u32 = DEFAULT_FG,
    bg: u32 = DEFAULT_BG,
    attrs: u16 = 0,
    width: u8 = 1,
    _pad: u8 = 0,
};

pub const DEFAULT_FG: u32 = 0xCCCCCC;
pub const DEFAULT_BG: u32 = 0x000000;

pub const SCROLLBACK_ROWS: u32 = 10_000;

const PALETTE_16 = [_]u32{
    0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
    0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
};

const CursorState = struct {
    x: u16 = 0,
    y: u16 = 0,
    sgr_attrs: u16 = 0,
    sgr_fg: u32 = DEFAULT_FG,
    sgr_bg: u32 = DEFAULT_BG,
};

/// Ring buffer of full rows evicted off the top of the primary screen.
/// Cleared on resize (simpler than reflow).
const Scrollback = struct {
    alloc: std.mem.Allocator,
    cols: u16 = 0,
    capacity: u32 = 0,
    buf: []Cell = &.{},
    head: u32 = 0,
    count: u32 = 0,

    fn init(alloc: std.mem.Allocator, cols: u16, capacity: u32) !Scrollback {
        const buf = try alloc.alloc(Cell, @as(usize, capacity) * @as(usize, cols));
        return .{ .alloc = alloc, .cols = cols, .capacity = capacity, .buf = buf };
    }

    fn deinit(self: *Scrollback) void {
        self.alloc.free(self.buf);
    }

    fn reshape(self: *Scrollback, cols: u16) !void {
        self.alloc.free(self.buf);
        self.buf = try self.alloc.alloc(Cell, @as(usize, self.capacity) * @as(usize, cols));
        self.cols = cols;
        self.head = 0;
        self.count = 0;
    }

    fn pushRow(self: *Scrollback, row: []const Cell) void {
        std.debug.assert(row.len == self.cols);
        const slot_start: usize = @as(usize, self.head) * @as(usize, self.cols);
        @memcpy(self.buf[slot_start..][0..self.cols], row);
        self.head = (self.head + 1) % self.capacity;
        if (self.count < self.capacity) self.count += 1;
    }
};

pub const Grid = struct {
    alloc: std.mem.Allocator,
    cols: u16,
    rows: u16,

    primary: []Cell,
    alt: []Cell, // always allocated alongside primary for simplicity
    cells: []Cell, // aliases one of the above
    using_alt: bool = false,

    cursor_x: u16 = 0,
    cursor_y: u16 = 0,
    sgr_attrs: u16 = 0,
    sgr_fg: u32 = DEFAULT_FG,
    sgr_bg: u32 = DEFAULT_BG,
    saved: CursorState = .{},

    scrollback: Scrollback,

    epoch: u32 = 1,

    pub fn init(alloc: std.mem.Allocator, cols: u16, rows: u16) !Grid {
        const sz: usize = @as(usize, cols) * @as(usize, rows);
        const primary = try alloc.alloc(Cell, sz);
        errdefer alloc.free(primary);
        const alt = try alloc.alloc(Cell, sz);
        errdefer alloc.free(alt);
        for (primary) |*c| c.* = .{};
        for (alt) |*c| c.* = .{};
        const sb = try Scrollback.init(alloc, cols, SCROLLBACK_ROWS);
        return .{
            .alloc = alloc,
            .cols = cols,
            .rows = rows,
            .primary = primary,
            .alt = alt,
            .cells = primary,
            .scrollback = sb,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.alloc.free(self.primary);
        self.alloc.free(self.alt);
        self.scrollback.deinit();
    }

    pub fn resize(self: *Grid, cols: u16, rows: u16) !void {
        if (cols == self.cols and rows == self.rows) return;
        const sz: usize = @as(usize, cols) * @as(usize, rows);
        const new_primary = try self.alloc.alloc(Cell, sz);
        errdefer self.alloc.free(new_primary);
        const new_alt = try self.alloc.alloc(Cell, sz);
        errdefer self.alloc.free(new_alt);
        for (new_primary) |*c| c.* = .{};
        for (new_alt) |*c| c.* = .{};

        const copy_cols = @min(cols, self.cols);
        const copy_rows = @min(rows, self.rows);
        var y: u16 = 0;
        while (y < copy_rows) : (y += 1) {
            @memcpy(
                new_primary[@as(usize, y) * cols ..][0..copy_cols],
                self.primary[@as(usize, y) * self.cols ..][0..copy_cols],
            );
            @memcpy(
                new_alt[@as(usize, y) * cols ..][0..copy_cols],
                self.alt[@as(usize, y) * self.cols ..][0..copy_cols],
            );
        }

        self.alloc.free(self.primary);
        self.alloc.free(self.alt);
        self.primary = new_primary;
        self.alt = new_alt;
        self.cells = if (self.using_alt) self.alt else self.primary;
        self.cols = cols;
        self.rows = rows;
        try self.scrollback.reshape(cols);
        if (self.cursor_x >= cols) self.cursor_x = cols - 1;
        if (self.cursor_y >= rows) self.cursor_y = rows - 1;
        self.epoch +%= 1;
    }

    pub fn apply(self: *Grid, ev: vt.Event) void {
        switch (ev) {
            .print => |b| self.putCodepoint(b),
            .execute => |b| self.execute(b),
            .csi => |c| self.csi(c),
            .osc => |_| {},
            .esc => |b| self.escFinal(b),
        }
    }

    /// Place one Unicode codepoint at the cursor, honoring display width.
    pub fn putCodepoint(self: *Grid, cp: u32) void {
        const w = utf8.width(cp);
        if (w == 0) {
            // Ignore combining / zero-width — not composed onto previous cell
            // yet. Good enough for MVP.
            return;
        }
        if (self.cursor_x + w > self.cols) {
            self.cursor_x = 0;
            self.lineFeed();
        }
        const idx = self.cellIdx(self.cursor_x, self.cursor_y);
        const fg = if (self.isReverse()) self.sgr_bg else self.sgr_fg;
        const bg = if (self.isReverse()) self.sgr_fg else self.sgr_bg;
        self.cells[idx] = .{
            .codepoint = cp,
            .fg = fg,
            .bg = bg,
            .attrs = self.sgr_attrs,
            .width = w,
        };
        if (w == 2) {
            // Trailing half: renderer should treat width=0 as "skip; the
            // previous cell spans this column".
            self.cells[idx + 1] = .{
                .codepoint = 0,
                .fg = fg,
                .bg = bg,
                .attrs = self.sgr_attrs,
                .width = 0,
            };
        }
        self.cursor_x += w;
        self.epoch +%= 1;
    }

    fn execute(self: *Grid, b: u8) void {
        switch (b) {
            0x07 => {}, // BEL
            0x08 => { // BS
                if (self.cursor_x > 0) self.cursor_x -= 1;
            },
            0x09 => { // HT — 8-col tab stops
                const next = (self.cursor_x / 8 + 1) * 8;
                self.cursor_x = @min(@as(u16, @intCast(next)), self.cols - 1);
            },
            0x0A, 0x0B, 0x0C => self.lineFeed(),
            0x0D => self.cursor_x = 0,
            else => {},
        }
        self.epoch +%= 1;
    }

    fn escFinal(self: *Grid, b: u8) void {
        switch (b) {
            '7' => self.saveCursor(), // DECSC
            '8' => self.restoreCursor(), // DECRC
            else => {},
        }
    }

    fn lineFeed(self: *Grid) void {
        if (self.cursor_y + 1 < self.rows) {
            self.cursor_y += 1;
        } else {
            self.scrollUp(1);
        }
    }

    fn scrollUp(self: *Grid, n: u16) void {
        const amt = @min(n, self.rows);
        const cols = self.cols;
        // Evict top `amt` rows into scrollback (primary only).
        if (!self.using_alt) {
            var y: u16 = 0;
            while (y < amt) : (y += 1) {
                const row_start: usize = @as(usize, y) * @as(usize, cols);
                self.scrollback.pushRow(self.cells[row_start .. row_start + cols]);
            }
        }
        const src = self.cells[@as(usize, amt) * cols ..];
        const keep = (self.rows - amt) * cols;
        std.mem.copyForwards(Cell, self.cells[0..keep], src[0..keep]);
        for (self.cells[keep..]) |*c| c.* = .{ .bg = self.sgr_bg };
    }

    fn csi(self: *Grid, c: vt.Csi) void {
        defer self.epoch +%= 1;
        if (c.private == '?') {
            self.privateMode(c);
            return;
        }
        switch (c.final) {
            'A' => self.moveCursor(0, -@as(i32, c.get(0, 1))),
            'B' => self.moveCursor(0, c.get(0, 1)),
            'C' => self.moveCursor(c.get(0, 1), 0),
            'D' => self.moveCursor(-@as(i32, c.get(0, 1)), 0),
            'E' => {
                self.cursor_x = 0;
                self.moveCursor(0, c.get(0, 1));
            },
            'F' => {
                self.cursor_x = 0;
                self.moveCursor(0, -@as(i32, c.get(0, 1)));
            },
            'G' => {
                self.cursor_x = @intCast(@max(0, @min(@as(i32, self.cols) - 1, c.get(0, 1) - 1)));
            },
            'H', 'f' => {
                const row = @max(1, c.get(0, 1));
                const col = @max(1, c.get(1, 1));
                self.cursor_y = @intCast(@min(@as(i32, self.rows) - 1, row - 1));
                self.cursor_x = @intCast(@min(@as(i32, self.cols) - 1, col - 1));
            },
            'J' => self.eraseDisplay(@intCast(@max(0, c.get(0, 0)))),
            'K' => self.eraseLine(@intCast(@max(0, c.get(0, 0)))),
            'm' => self.sgr(c),
            's' => self.saveCursor(),
            'u' => self.restoreCursor(),
            else => {},
        }
    }

    fn privateMode(self: *Grid, c: vt.Csi) void {
        const set = c.final == 'h';
        const reset_ = c.final == 'l';
        if (!set and !reset_) return;
        var i: usize = 0;
        while (i < c.param_count) : (i += 1) {
            const p = c.params[i];
            switch (p) {
                47 => self.switchScreen(set),
                1047 => {
                    if (!set) self.clearActive();
                    self.switchScreen(set);
                },
                1048 => {
                    if (set) self.saveCursor() else self.restoreCursor();
                },
                1049 => {
                    if (set) {
                        self.saveCursor();
                        self.switchScreen(true);
                        self.clearActive();
                    } else {
                        self.switchScreen(false);
                        self.restoreCursor();
                    }
                },
                else => {},
            }
        }
    }

    fn switchScreen(self: *Grid, to_alt: bool) void {
        if (to_alt == self.using_alt) return;
        self.using_alt = to_alt;
        self.cells = if (to_alt) self.alt else self.primary;
    }

    fn clearActive(self: *Grid) void {
        for (self.cells) |*c| c.* = .{ .bg = self.sgr_bg };
    }

    fn saveCursor(self: *Grid) void {
        self.saved = .{
            .x = self.cursor_x,
            .y = self.cursor_y,
            .sgr_attrs = self.sgr_attrs,
            .sgr_fg = self.sgr_fg,
            .sgr_bg = self.sgr_bg,
        };
    }

    fn restoreCursor(self: *Grid) void {
        self.cursor_x = @min(self.saved.x, self.cols - 1);
        self.cursor_y = @min(self.saved.y, self.rows - 1);
        self.sgr_attrs = self.saved.sgr_attrs;
        self.sgr_fg = self.saved.sgr_fg;
        self.sgr_bg = self.saved.sgr_bg;
    }

    fn moveCursor(self: *Grid, dx: i32, dy: i32) void {
        const nx = @as(i32, self.cursor_x) + dx;
        const ny = @as(i32, self.cursor_y) + dy;
        self.cursor_x = @intCast(@max(0, @min(@as(i32, self.cols) - 1, nx)));
        self.cursor_y = @intCast(@max(0, @min(@as(i32, self.rows) - 1, ny)));
    }

    fn eraseDisplay(self: *Grid, mode: u8) void {
        switch (mode) {
            0 => {
                const start = self.cellIdx(self.cursor_x, self.cursor_y);
                for (self.cells[start..]) |*c| c.* = .{ .bg = self.sgr_bg };
            },
            1 => {
                const end = self.cellIdx(self.cursor_x, self.cursor_y) + 1;
                for (self.cells[0..end]) |*c| c.* = .{ .bg = self.sgr_bg };
            },
            2, 3 => {
                for (self.cells) |*c| c.* = .{ .bg = self.sgr_bg };
            },
            else => {},
        }
    }

    fn eraseLine(self: *Grid, mode: u8) void {
        const row_start = @as(usize, self.cursor_y) * self.cols;
        const row = self.cells[row_start .. row_start + self.cols];
        switch (mode) {
            0 => for (row[self.cursor_x..]) |*c| {
                c.* = .{ .bg = self.sgr_bg };
            },
            1 => for (row[0 .. self.cursor_x + 1]) |*c| {
                c.* = .{ .bg = self.sgr_bg };
            },
            2 => for (row) |*c| {
                c.* = .{ .bg = self.sgr_bg };
            },
            else => {},
        }
    }

    fn sgr(self: *Grid, c: vt.Csi) void {
        if (c.param_count == 0) {
            self.sgrReset();
            return;
        }
        var i: usize = 0;
        while (i < c.param_count) : (i += 1) {
            const p = c.params[i];
            switch (p) {
                -1, 0 => self.sgrReset(),
                1 => setAttrBit(&self.sgr_attrs, 0, true),
                3 => setAttrBit(&self.sgr_attrs, 1, true),
                4 => setAttrBit(&self.sgr_attrs, 2, true),
                7 => setAttrBit(&self.sgr_attrs, 3, true),
                2 => setAttrBit(&self.sgr_attrs, 4, true),
                22 => {
                    setAttrBit(&self.sgr_attrs, 0, false);
                    setAttrBit(&self.sgr_attrs, 4, false);
                },
                23 => setAttrBit(&self.sgr_attrs, 1, false),
                24 => setAttrBit(&self.sgr_attrs, 2, false),
                27 => setAttrBit(&self.sgr_attrs, 3, false),
                30...37 => self.sgr_fg = PALETTE_16[@as(usize, @intCast(p - 30))],
                40...47 => self.sgr_bg = PALETTE_16[@as(usize, @intCast(p - 40))],
                90...97 => self.sgr_fg = PALETTE_16[@as(usize, @intCast(p - 90 + 8))],
                100...107 => self.sgr_bg = PALETTE_16[@as(usize, @intCast(p - 100 + 8))],
                39 => self.sgr_fg = DEFAULT_FG,
                49 => self.sgr_bg = DEFAULT_BG,
                38 => {
                    if (i + 1 < c.param_count and c.params[i + 1] == 5 and i + 2 < c.param_count) {
                        self.sgr_fg = xterm256(@intCast(@max(0, c.params[i + 2])));
                        i += 2;
                    } else if (i + 1 < c.param_count and c.params[i + 1] == 2 and i + 4 < c.param_count) {
                        self.sgr_fg = rgb(
                            @intCast(@max(0, c.params[i + 2])),
                            @intCast(@max(0, c.params[i + 3])),
                            @intCast(@max(0, c.params[i + 4])),
                        );
                        i += 4;
                    }
                },
                48 => {
                    if (i + 1 < c.param_count and c.params[i + 1] == 5 and i + 2 < c.param_count) {
                        self.sgr_bg = xterm256(@intCast(@max(0, c.params[i + 2])));
                        i += 2;
                    } else if (i + 1 < c.param_count and c.params[i + 1] == 2 and i + 4 < c.param_count) {
                        self.sgr_bg = rgb(
                            @intCast(@max(0, c.params[i + 2])),
                            @intCast(@max(0, c.params[i + 3])),
                            @intCast(@max(0, c.params[i + 4])),
                        );
                        i += 4;
                    }
                },
                else => {},
            }
        }
    }

    fn sgrReset(self: *Grid) void {
        self.sgr_attrs = 0;
        self.sgr_fg = DEFAULT_FG;
        self.sgr_bg = DEFAULT_BG;
    }

    fn cellIdx(self: *const Grid, x: u16, y: u16) usize {
        return @as(usize, y) * self.cols + x;
    }

    fn isReverse(self: *const Grid) bool {
        return (self.sgr_attrs & (1 << 3)) != 0;
    }

    // ----- Scrollback access (read-only) -----

    pub fn scrollbackLen(self: *const Grid) u32 {
        return self.scrollback.count;
    }

    /// Copy up to `num_rows` scrollback rows into `out`, starting at
    /// `start_row` (0 = oldest). Returns rows copied.
    pub fn copyScrollback(self: *const Grid, start_row: u32, num_rows: u32, out: []Cell) u32 {
        const sb = &self.scrollback;
        if (start_row >= sb.count) return 0;
        const avail = sb.count - start_row;
        const want = @min(num_rows, avail);
        const max_by_out: u32 = @intCast(out.len / sb.cols);
        const n = @min(want, max_by_out);
        const oldest = if (sb.count < sb.capacity) 0 else sb.head;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const src_row = (oldest + start_row + i) % sb.capacity;
            const src_start: usize = @as(usize, src_row) * @as(usize, sb.cols);
            const dst_start: usize = @as(usize, i) * @as(usize, sb.cols);
            @memcpy(
                out[dst_start .. dst_start + sb.cols],
                sb.buf[src_start .. src_start + sb.cols],
            );
        }
        return n;
    }
};

fn setAttrBit(a: *u16, bit: u4, on: bool) void {
    const mask: u16 = @as(u16, 1) << bit;
    if (on) a.* |= mask else a.* &= ~mask;
}

fn xterm256(n: u8) u32 {
    if (n < 16) return PALETTE_16[n];
    if (n >= 232) {
        const v: u32 = 8 + 10 * @as(u32, n - 232);
        return (v << 16) | (v << 8) | v;
    }
    const base = n - 16;
    const r_idx: u32 = base / 36;
    const g_idx: u32 = (base / 6) % 6;
    const b_idx: u32 = base % 6;
    const steps = [_]u32{ 0, 95, 135, 175, 215, 255 };
    return (steps[r_idx] << 16) | (steps[g_idx] << 8) | steps[b_idx];
}

fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

test "print puts a cell and advances cursor" {
    var g = try Grid.init(std.testing.allocator, 10, 5);
    defer g.deinit();
    g.apply(.{ .print = 'A' });
    try std.testing.expectEqual(@as(u32, 'A'), g.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 1), g.cursor_x);
}

test "CR + LF moves to next line col 0" {
    var g = try Grid.init(std.testing.allocator, 10, 5);
    defer g.deinit();
    g.apply(.{ .print = 'A' });
    g.apply(.{ .execute = 0x0D });
    g.apply(.{ .execute = 0x0A });
    try std.testing.expectEqual(@as(u16, 0), g.cursor_x);
    try std.testing.expectEqual(@as(u16, 1), g.cursor_y);
}

test "CUP moves cursor" {
    var g = try Grid.init(std.testing.allocator, 10, 5);
    defer g.deinit();
    var csi_ev = vt.Csi{ .final = 'H', .param_count = 2 };
    csi_ev.params[0] = 3;
    csi_ev.params[1] = 5;
    g.apply(.{ .csi = csi_ev });
    try std.testing.expectEqual(@as(u16, 4), g.cursor_x);
    try std.testing.expectEqual(@as(u16, 2), g.cursor_y);
}

test "wide codepoint takes two cells" {
    var g = try Grid.init(std.testing.allocator, 10, 2);
    defer g.deinit();
    g.putCodepoint(0x6F22); // 漢
    try std.testing.expectEqual(@as(u8, 2), g.cells[0].width);
    try std.testing.expectEqual(@as(u8, 0), g.cells[1].width);
    try std.testing.expectEqual(@as(u16, 2), g.cursor_x);
}

test "alt screen switch preserves primary" {
    var g = try Grid.init(std.testing.allocator, 10, 3);
    defer g.deinit();
    g.putCodepoint('P');
    var enter = vt.Csi{ .final = 'h', .private = '?', .param_count = 1 };
    enter.params[0] = 1049;
    g.apply(.{ .csi = enter });
    try std.testing.expect(g.using_alt);
    try std.testing.expectEqual(@as(u32, ' '), g.cells[0].codepoint); // alt cleared
    g.putCodepoint('A');
    var leave = vt.Csi{ .final = 'l', .private = '?', .param_count = 1 };
    leave.params[0] = 1049;
    g.apply(.{ .csi = leave });
    try std.testing.expect(!g.using_alt);
    try std.testing.expectEqual(@as(u32, 'P'), g.cells[0].codepoint);
}

test "scrollback captures evicted rows" {
    var g = try Grid.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.putCodepoint('A');
    g.execute(0x0A); // LF (now row 1)
    g.execute(0x0D);
    g.putCodepoint('B');
    g.execute(0x0A); // LF (scroll, evicts "A   ")
    try std.testing.expectEqual(@as(u32, 1), g.scrollbackLen());
    var buf: [4]Cell = undefined;
    const n = g.copyScrollback(0, 1, &buf);
    try std.testing.expectEqual(@as(u32, 1), n);
    try std.testing.expectEqual(@as(u32, 'A'), buf[0].codepoint);
}

test "save/restore cursor via CSI s/u" {
    var g = try Grid.init(std.testing.allocator, 10, 5);
    defer g.deinit();
    g.cursor_x = 3;
    g.cursor_y = 2;
    const save = vt.Csi{ .final = 's', .param_count = 0 };
    g.apply(.{ .csi = save });
    g.cursor_x = 7;
    g.cursor_y = 4;
    const restore = vt.Csi{ .final = 'u', .param_count = 0 };
    g.apply(.{ .csi = restore });
    try std.testing.expectEqual(@as(u16, 3), g.cursor_x);
    try std.testing.expectEqual(@as(u16, 2), g.cursor_y);
}
