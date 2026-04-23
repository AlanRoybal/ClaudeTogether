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
//! - Region + screen editing: DECSTBM, IL/DL, ICH/DCH/ECH, SU/SD.
//! - Scrollback ring buffer (~10K rows) for the primary buffer.
//!
//! Not yet: tab stops beyond 8-col fixed.

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
    scroll_top: u16 = 0,
    scroll_bottom: u16 = 0,

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
            .scroll_bottom = rows - 1,
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
        const old_cols = self.cols;
        const old_rows = self.rows;
        const sz: usize = @as(usize, cols) * @as(usize, rows);
        const new_primary = try self.alloc.alloc(Cell, sz);
        errdefer self.alloc.free(new_primary);
        const new_alt = try self.alloc.alloc(Cell, sz);
        errdefer self.alloc.free(new_alt);
        for (new_primary) |*c| c.* = .{};
        for (new_alt) |*c| c.* = .{};

        if (!self.using_alt and cols == old_cols and rows < old_rows) {
            var y: u16 = 0;
            while (y < old_rows - rows) : (y += 1) {
                const row_start: usize = @as(usize, y) * @as(usize, old_cols);
                self.scrollback.pushRow(self.primary[row_start .. row_start + old_cols]);
            }
        }

        const primary_shift = copyResizedBuffer(
            new_primary,
            self.primary,
            old_cols,
            old_rows,
            cols,
            rows,
            true,
        );
        _ = copyResizedBuffer(
            new_alt,
            self.alt,
            old_cols,
            old_rows,
            cols,
            rows,
            false,
        );

        self.alloc.free(self.primary);
        self.alloc.free(self.alt);
        self.primary = new_primary;
        self.alt = new_alt;
        self.cells = if (self.using_alt) self.alt else self.primary;
        self.cols = cols;
        self.rows = rows;
        if (cols != old_cols) {
            try self.scrollback.reshape(cols);
        }
        self.cursor_x = @min(self.cursor_x, cols - 1);
        self.cursor_y = shiftClampedRow(self.cursor_y, primary_shift, rows);
        self.saved.x = @min(self.saved.x, cols - 1);
        self.saved.y = @min(self.saved.y, rows - 1);
        self.scroll_top = 0;
        self.scroll_bottom = rows - 1;
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
            'D' => self.lineFeed(), // IND
            'E' => {
                self.cursor_x = 0;
                self.lineFeed();
            }, // NEL
            'M' => self.reverseIndex(), // RI
            else => {},
        }
    }

    fn lineFeed(self: *Grid) void {
        if (self.cursor_y == self.scroll_bottom) {
            self.scrollUpRegion(self.scroll_top, self.scroll_bottom, 1);
        } else if (self.cursor_y + 1 < self.rows) {
            self.cursor_y += 1;
        }
    }

    fn reverseIndex(self: *Grid) void {
        if (self.cursor_y == self.scroll_top) {
            self.scrollDownRegion(self.scroll_top, self.scroll_bottom, 1);
        } else if (self.cursor_y > 0) {
            self.cursor_y -= 1;
        }
    }

    fn scrollUp(self: *Grid, n: u16) void {
        self.scrollUpRegion(0, self.rows - 1, n);
    }

    fn scrollUpRegion(self: *Grid, top: u16, bottom: u16, n: u16) void {
        if (top > bottom or bottom >= self.rows) return;
        const height = bottom - top + 1;
        const amt = @min(n, height);
        if (amt == 0) return;
        const cols = self.cols;
        // Evict top rows into scrollback only when the primary viewport itself
        // scrolls, not for nested scroll regions inside TUIs.
        if (!self.using_alt and top == 0 and bottom + 1 == self.rows) {
            var y: u16 = 0;
            while (y < amt) : (y += 1) {
                const row_start: usize = @as(usize, top + y) * @as(usize, cols);
                self.scrollback.pushRow(self.cells[row_start .. row_start + cols]);
            }
        }
        const region_start: usize = @as(usize, top) * @as(usize, cols);
        const src_start: usize = @as(usize, top + amt) * @as(usize, cols);
        const keep_rows = height - amt;
        const keep_cells = @as(usize, keep_rows) * @as(usize, cols);
        std.mem.copyForwards(
            Cell,
            self.cells[region_start .. region_start + keep_cells],
            self.cells[src_start .. src_start + keep_cells],
        );
        self.clearRows(bottom + 1 - amt, amt);
    }

    fn scrollDownRegion(self: *Grid, top: u16, bottom: u16, n: u16) void {
        if (top > bottom or bottom >= self.rows) return;
        const height = bottom - top + 1;
        const amt = @min(n, height);
        if (amt == 0) return;
        const cols = self.cols;
        const dst_start: usize = @as(usize, top + amt) * @as(usize, cols);
        const src_start: usize = @as(usize, top) * @as(usize, cols);
        const keep_rows = height - amt;
        const keep_cells = @as(usize, keep_rows) * @as(usize, cols);
        std.mem.copyBackwards(
            Cell,
            self.cells[dst_start .. dst_start + keep_cells],
            self.cells[src_start .. src_start + keep_cells],
        );
        self.clearRows(top, amt);
    }

    fn csi(self: *Grid, c: vt.Csi) void {
        defer self.epoch +%= 1;
        if (c.private == '?') {
            self.privateMode(c);
            return;
        }
        switch (c.final) {
            '@' => self.insertBlankChars(@intCast(@max(1, c.get(0, 1)))),
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
            'L' => self.insertLines(@intCast(@max(1, c.get(0, 1)))),
            'M' => self.deleteLines(@intCast(@max(1, c.get(0, 1)))),
            'P' => self.deleteChars(@intCast(@max(1, c.get(0, 1)))),
            'S' => self.scrollUpRegion(self.scroll_top, self.scroll_bottom, @intCast(@max(1, c.get(0, 1)))),
            'T' => self.scrollDownRegion(self.scroll_top, self.scroll_bottom, @intCast(@max(1, c.get(0, 1)))),
            'X' => self.eraseChars(@intCast(@max(1, c.get(0, 1)))),
            'd' => {
                const row = @max(1, c.get(0, 1));
                self.cursor_y = @intCast(@min(@as(i32, self.rows) - 1, row - 1));
            },
            'e' => self.moveCursor(0, c.get(0, 1)),
            'm' => self.sgr(c),
            'r' => self.setScrollRegion(
                @intCast(@max(1, c.get(0, 1))),
                @intCast(@max(1, c.get(1, @as(i32, self.rows)))),
            ),
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
        self.scroll_top = 0;
        self.scroll_bottom = self.rows - 1;
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

    fn setScrollRegion(self: *Grid, top_1: u16, bottom_1: u16) void {
        const top = top_1 - 1;
        const bottom = bottom_1 - 1;
        if (top >= bottom or bottom >= self.rows) {
            self.scroll_top = 0;
            self.scroll_bottom = self.rows - 1;
        } else {
            self.scroll_top = top;
            self.scroll_bottom = bottom;
        }
        self.cursor_x = 0;
        self.cursor_y = 0;
    }

    fn insertLines(self: *Grid, n: u16) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const amt = @min(n, self.scroll_bottom - self.cursor_y + 1);
        const cols = self.cols;
        const dst_start: usize = @as(usize, self.cursor_y + amt) * @as(usize, cols);
        const src_start: usize = @as(usize, self.cursor_y) * @as(usize, cols);
        const keep_rows = self.scroll_bottom - self.cursor_y + 1 - amt;
        const keep_cells = @as(usize, keep_rows) * @as(usize, cols);
        std.mem.copyBackwards(
            Cell,
            self.cells[dst_start .. dst_start + keep_cells],
            self.cells[src_start .. src_start + keep_cells],
        );
        self.clearRows(self.cursor_y, amt);
    }

    fn deleteLines(self: *Grid, n: u16) void {
        if (self.cursor_y < self.scroll_top or self.cursor_y > self.scroll_bottom) return;
        const amt = @min(n, self.scroll_bottom - self.cursor_y + 1);
        const cols = self.cols;
        const dst_start: usize = @as(usize, self.cursor_y) * @as(usize, cols);
        const src_start: usize = @as(usize, self.cursor_y + amt) * @as(usize, cols);
        const keep_rows = self.scroll_bottom - self.cursor_y + 1 - amt;
        const keep_cells = @as(usize, keep_rows) * @as(usize, cols);
        std.mem.copyForwards(
            Cell,
            self.cells[dst_start .. dst_start + keep_cells],
            self.cells[src_start .. src_start + keep_cells],
        );
        self.clearRows(self.scroll_bottom + 1 - amt, amt);
    }

    fn insertBlankChars(self: *Grid, n: u16) void {
        const row = self.rowSlice(self.cursor_y);
        const amt = @min(n, self.cols - self.cursor_x);
        const start = @as(usize, self.cursor_x);
        const keep = @as(usize, self.cols - self.cursor_x - amt);
        std.mem.copyBackwards(
            Cell,
            row[start + amt .. start + amt + keep],
            row[start .. start + keep],
        );
        self.clearRange(row, self.cursor_x, self.cursor_x + amt);
    }

    fn deleteChars(self: *Grid, n: u16) void {
        const row = self.rowSlice(self.cursor_y);
        const amt = @min(n, self.cols - self.cursor_x);
        const start = @as(usize, self.cursor_x);
        const keep = @as(usize, self.cols - self.cursor_x - amt);
        std.mem.copyForwards(
            Cell,
            row[start .. start + keep],
            row[start + amt .. start + amt + keep],
        );
        self.clearRange(row, self.cols - amt, self.cols);
    }

    fn eraseChars(self: *Grid, n: u16) void {
        const row = self.rowSlice(self.cursor_y);
        const end = @min(self.cols, self.cursor_x + n);
        self.clearRange(row, self.cursor_x, end);
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

    fn rowSlice(self: *Grid, y: u16) []Cell {
        const row_start = @as(usize, y) * @as(usize, self.cols);
        return self.cells[row_start .. row_start + self.cols];
    }

    fn clearRows(self: *Grid, top: u16, count: u16) void {
        var y = top;
        while (y < top + count) : (y += 1) {
            self.clearRange(self.rowSlice(y), 0, self.cols);
        }
    }

    fn clearRange(self: *Grid, row: []Cell, start: u16, end: u16) void {
        for (row[start..end]) |*c| c.* = self.blankCell();
    }

    fn blankCell(self: *Grid) Cell {
        return .{ .bg = self.sgr_bg };
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

fn copyResizedBuffer(
    dst: []Cell,
    src: []const Cell,
    old_cols: u16,
    old_rows: u16,
    new_cols: u16,
    new_rows: u16,
    preserve_bottom: bool,
) i32 {
    const copy_cols = @min(new_cols, old_cols);
    const copy_rows = @min(new_rows, old_rows);
    // Preserve the bottom edge only when rows are removed. When rows are added
    // (the common initial window-size sync path), keep existing content pinned
    // to the top so the shell prompt does not appear to "fall" toward center.
    const preserve_bottom_rows = preserve_bottom and new_rows < old_rows;
    const src_row0: u16 = if (preserve_bottom_rows and old_rows > copy_rows)
        old_rows - copy_rows
    else
        0;
    const dst_row0: u16 = if (preserve_bottom_rows and new_rows > copy_rows)
        new_rows - copy_rows
    else
        0;
    var y: u16 = 0;
    while (y < copy_rows) : (y += 1) {
        const src_row = src_row0 + y;
        const dst_row = dst_row0 + y;
        @memcpy(
            dst[@as(usize, dst_row) * @as(usize, new_cols) ..][0..copy_cols],
            src[@as(usize, src_row) * @as(usize, old_cols) ..][0..copy_cols],
        );
    }
    return @as(i32, dst_row0) - @as(i32, src_row0);
}

fn shiftClampedRow(row: u16, delta: i32, max_rows: u16) u16 {
    const shifted = @as(i32, row) + delta;
    return @intCast(@max(0, @min(@as(i32, max_rows) - 1, shifted)));
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

test "resize keeps bottom rows of primary buffer" {
    var g = try Grid.init(std.testing.allocator, 4, 4);
    defer g.deinit();
    var row: u16 = 0;
    while (row < g.rows) : (row += 1) {
        g.cursor_x = 0;
        g.cursor_y = row;
        g.putCodepoint(@as(u32, 'A') + row);
    }
    g.cursor_y = 3;
    try g.resize(4, 2);
    try std.testing.expectEqual(@as(u32, 'C'), g.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'D'), g.cells[4].codepoint);
    try std.testing.expectEqual(@as(u16, 1), g.cursor_y);
}

test "resize growth keeps existing content top-anchored" {
    var g = try Grid.init(std.testing.allocator, 4, 2);
    defer g.deinit();
    g.cursor_x = 0;
    g.cursor_y = 0;
    g.putCodepoint('A');
    g.cursor_x = 0;
    g.cursor_y = 1;
    g.putCodepoint('B');
    try g.resize(4, 4);
    try std.testing.expectEqual(@as(u32, 'A'), g.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'B'), g.cells[4].codepoint);
    try std.testing.expectEqual(@as(u32, ' '), g.cells[8].codepoint);
    try std.testing.expectEqual(@as(u16, 1), g.cursor_y);
}

test "DECSTBM scrolls only inside region" {
    var g = try Grid.init(std.testing.allocator, 3, 4);
    defer g.deinit();
    var row: u16 = 0;
    while (row < g.rows) : (row += 1) {
        g.cursor_x = 0;
        g.cursor_y = row;
        g.putCodepoint(@as(u32, 'A') + row);
    }
    var set = vt.Csi{ .final = 'r', .param_count = 2 };
    set.params[0] = 2;
    set.params[1] = 3;
    g.apply(.{ .csi = set });
    g.cursor_x = 0;
    g.cursor_y = 2;
    g.apply(.{ .execute = 0x0A });
    try std.testing.expectEqual(@as(u32, 'A'), g.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'C'), g.cells[3].codepoint);
    try std.testing.expectEqual(@as(u32, ' '), g.cells[6].codepoint);
    try std.testing.expectEqual(@as(u32, 'D'), g.cells[9].codepoint);
}

test "insert and delete chars edit the active row" {
    var g = try Grid.init(std.testing.allocator, 5, 1);
    defer g.deinit();
    for ("abcd") |ch| g.putCodepoint(ch);
    g.cursor_x = 1;
    var insert = vt.Csi{ .final = '@', .param_count = 1 };
    insert.params[0] = 1;
    g.apply(.{ .csi = insert });
    try std.testing.expectEqual(@as(u32, 'a'), g.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, ' '), g.cells[1].codepoint);
    try std.testing.expectEqual(@as(u32, 'b'), g.cells[2].codepoint);

    var delete = vt.Csi{ .final = 'P', .param_count = 1 };
    delete.params[0] = 2;
    g.apply(.{ .csi = delete });
    try std.testing.expectEqual(@as(u32, 'a'), g.cells[0].codepoint);
    try std.testing.expectEqual(@as(u32, 'c'), g.cells[1].codepoint);
    try std.testing.expectEqual(@as(u32, 'd'), g.cells[2].codepoint);
}
