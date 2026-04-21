//! Minimal VT500-style escape-sequence parser.
//!
//! Covers what we need for line-mode shells and the common TUI apps:
//! CSI sequences (cursor, erase, SGR), OSC strings (titles, hyperlinks),
//! and the C0 control bytes. Not covered yet: DCS, SOS/PM/APC, complex
//! intermediate bytes beyond one. UTF-8 multibyte handling is coarse
//! (continuation bytes are printed as-is and combined in term.zig).

const std = @import("std");

pub const State = enum(u8) {
    ground,
    escape,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
};

pub const MAX_PARAMS: usize = 16;
pub const MAX_OSC: usize = 512;

pub const Csi = struct {
    params: [MAX_PARAMS]i32 = [_]i32{-1} ** MAX_PARAMS,
    param_count: u8 = 0,
    intermediate: u8 = 0,
    final: u8 = 0,
    private: u8 = 0,

    pub fn get(self: *const Csi, idx: usize, default: i32) i32 {
        if (idx >= self.param_count) return default;
        const v = self.params[idx];
        return if (v < 0) default else v;
    }
};

pub const Event = union(enum) {
    print: u8, // single byte (ASCII or UTF-8 continuation; term.zig reassembles)
    execute: u8,
    csi: Csi,
    osc: []const u8,
    esc: u8,
};

pub const Parser = struct {
    state: State = .ground,
    csi: Csi = .{},
    osc_buf: [MAX_OSC]u8 = undefined,
    osc_len: usize = 0,
    esc_intermediate: u8 = 0,

    pub fn init() Parser {
        return .{};
    }

    /// Feed one byte; returns an event if the byte finalized one.
    /// `print` and `execute` events are emitted immediately; CSI/OSC/ESC
    /// only on their terminator.
    pub fn feed(self: *Parser, b: u8) ?Event {
        switch (self.state) {
            .ground => return self.ground(b),
            .escape => return self.escape(b),
            .csi_entry, .csi_param, .csi_intermediate => return self.feedCsi(b),
            .csi_ignore => return self.feedCsiIgnore(b),
            .osc_string => return self.feedOsc(b),
        }
    }

    fn ground(self: *Parser, b: u8) ?Event {
        if (b == 0x1B) {
            self.state = .escape;
            self.esc_intermediate = 0;
            return null;
        }
        if (isC0(b)) return .{ .execute = b };
        return .{ .print = b };
    }

    fn escape(self: *Parser, b: u8) ?Event {
        switch (b) {
            '[' => {
                self.csi = .{};
                self.state = .csi_entry;
                return null;
            },
            ']' => {
                self.osc_len = 0;
                self.state = .osc_string;
                return null;
            },
            0x20...0x2F => {
                self.esc_intermediate = b;
                return null;
            },
            // 0x30..0x7E excluding '[' (0x5B) and ']' (0x5D), which are handled above.
            0x30...0x5A, 0x5C, 0x5E...0x7E => {
                self.state = .ground;
                return .{ .esc = b };
            },
            else => {
                self.state = .ground;
                return null;
            },
        }
    }

    fn feedCsi(self: *Parser, b: u8) ?Event {
        switch (b) {
            0x30...0x39 => { // 0-9
                if (self.state == .csi_entry) self.state = .csi_param;
                self.appendDigit(b);
                return null;
            },
            ';' => {
                if (self.state == .csi_entry) self.state = .csi_param;
                self.bumpParam();
                return null;
            },
            '<', '=', '>', '?' => {
                if (self.state == .csi_entry) {
                    self.csi.private = b;
                    self.state = .csi_param;
                }
                return null;
            },
            0x20...0x2F => {
                self.csi.intermediate = b;
                self.state = .csi_intermediate;
                return null;
            },
            0x40...0x7E => {
                self.csi.final = b;
                // finalize last param if pending
                if (self.csi.param_count == 0 and self.csi.params[0] != -1) {
                    self.csi.param_count = 1;
                } else if (self.csi.param_count > 0 and
                    self.csi.params[self.csi.param_count] != -1)
                {
                    self.csi.param_count += 1;
                }
                const out: Event = .{ .csi = self.csi };
                self.state = .ground;
                return out;
            },
            else => {
                self.state = .csi_ignore;
                return null;
            },
        }
    }

    fn feedCsiIgnore(self: *Parser, b: u8) ?Event {
        if (b >= 0x40 and b <= 0x7E) self.state = .ground;
        return null;
    }

    fn feedOsc(self: *Parser, b: u8) ?Event {
        if (b == 0x07) {
            // BEL terminator
            const slice = self.osc_buf[0..self.osc_len];
            self.state = .ground;
            return .{ .osc = slice };
        }
        if (b == 0x1B) {
            // ST sequence: ESC \ ; discard the trailing \
            // Simpler: treat as terminator immediately, then swallow the \
            const slice = self.osc_buf[0..self.osc_len];
            self.state = .ground; // next char (\) will be ignored by ESC handler
            return .{ .osc = slice };
        }
        if (self.osc_len < MAX_OSC) {
            self.osc_buf[self.osc_len] = b;
            self.osc_len += 1;
        }
        return null;
    }

    fn appendDigit(self: *Parser, b: u8) void {
        const idx = self.csi.param_count;
        if (idx >= MAX_PARAMS) return;
        var cur = self.csi.params[idx];
        if (cur < 0) cur = 0;
        cur = cur * 10 + @as(i32, b - '0');
        self.csi.params[idx] = cur;
    }

    fn bumpParam(self: *Parser) void {
        if (self.csi.param_count + 1 < MAX_PARAMS) {
            self.csi.param_count += 1;
            self.csi.params[self.csi.param_count] = -1;
        }
    }
};

fn isC0(b: u8) bool {
    return b < 0x20 or b == 0x7F;
}

test "csi cursor up" {
    var p = Parser.init();
    const input = "\x1b[3A";
    var ev: ?Event = null;
    for (input) |b| {
        if (p.feed(b)) |e| ev = e;
    }
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .csi => |c| {
            try std.testing.expectEqual(@as(u8, 'A'), c.final);
            try std.testing.expectEqual(@as(i32, 3), c.get(0, 1));
        },
        else => unreachable,
    }
}

test "sgr multiple params" {
    var p = Parser.init();
    const input = "\x1b[1;31m";
    var ev: ?Event = null;
    for (input) |b| {
        if (p.feed(b)) |e| ev = e;
    }
    switch (ev.?) {
        .csi => |c| {
            try std.testing.expectEqual(@as(u8, 'm'), c.final);
            try std.testing.expectEqual(@as(u8, 2), c.param_count);
            try std.testing.expectEqual(@as(i32, 1), c.get(0, 0));
            try std.testing.expectEqual(@as(i32, 31), c.get(1, 0));
        },
        else => unreachable,
    }
}

test "plain text is print events" {
    var p = Parser.init();
    var count: usize = 0;
    for ("hi") |b| {
        if (p.feed(b)) |e| switch (e) {
            .print => count += 1,
            else => {},
        };
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
