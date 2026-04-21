//! UTF-8 byte-stream decoder + a coarse East Asian Wide width table.
//!
//! Decoder follows the WHATWG UTF-8 decoder state machine closely enough to
//! reject overlong, surrogate, and out-of-range sequences; invalid bytes
//! yield U+FFFD so the stream can't desynchronize.

const std = @import("std");

pub const REPLACEMENT: u32 = 0xFFFD;

pub const Decoder = struct {
    bytes_needed: u3 = 0,
    codepoint: u32 = 0,
    lower_bound: u8 = 0x80,
    upper_bound: u8 = 0xBF,

    pub fn init() Decoder {
        return .{};
    }

    fn reset(self: *Decoder) void {
        self.bytes_needed = 0;
        self.codepoint = 0;
        self.lower_bound = 0x80;
        self.upper_bound = 0xBF;
    }

    /// Feed one byte. Returns a codepoint if one just completed, else null.
    /// On invalid input, emits REPLACEMENT and resets state.
    pub fn push(self: *Decoder, b: u8) ?u32 {
        if (self.bytes_needed == 0) {
            if (b <= 0x7F) return b;
            if (b >= 0xC2 and b <= 0xDF) {
                self.bytes_needed = 1;
                self.codepoint = b & 0x1F;
                return null;
            }
            if (b >= 0xE0 and b <= 0xEF) {
                self.bytes_needed = 2;
                self.codepoint = b & 0x0F;
                if (b == 0xE0) self.lower_bound = 0xA0;
                if (b == 0xED) self.upper_bound = 0x9F;
                return null;
            }
            if (b >= 0xF0 and b <= 0xF4) {
                self.bytes_needed = 3;
                self.codepoint = b & 0x07;
                if (b == 0xF0) self.lower_bound = 0x90;
                if (b == 0xF4) self.upper_bound = 0x8F;
                return null;
            }
            return REPLACEMENT;
        }
        if (b < self.lower_bound or b > self.upper_bound) {
            self.reset();
            return REPLACEMENT;
        }
        self.lower_bound = 0x80;
        self.upper_bound = 0xBF;
        self.codepoint = (self.codepoint << 6) | (b & 0x3F);
        self.bytes_needed -= 1;
        if (self.bytes_needed == 0) {
            const cp = self.codepoint;
            self.codepoint = 0;
            return cp;
        }
        return null;
    }
};

/// Returns display width in cells: 0 for combining/zero-width, 2 for East
/// Asian Wide / emoji, else 1. Coarse — a handful of ranges, not a full
/// Unicode table, but covers the common cases a terminal encounters.
pub fn width(cp: u32) u8 {
    if (cp == 0) return 0;
    if (cp < 0x20 or (cp >= 0x7F and cp < 0xA0)) return 0;

    // Combining marks + zero-width ranges.
    if ((cp >= 0x0300 and cp <= 0x036F) or
        (cp >= 0x0483 and cp <= 0x0489) or
        (cp >= 0x200B and cp <= 0x200F) or
        (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x2060 and cp <= 0x206F) or
        cp == 0xFEFF) return 0;

    // East Asian Wide / Fullwidth / CJK / emoji.
    if ((cp >= 0x1100 and cp <= 0x115F) or
        (cp >= 0x2E80 and cp <= 0x303E) or
        (cp >= 0x3041 and cp <= 0x33FF) or
        (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xA000 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or
        (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFE30 and cp <= 0xFE4F) or
        (cp >= 0xFF00 and cp <= 0xFF60) or
        (cp >= 0xFFE0 and cp <= 0xFFE6) or
        (cp >= 0x1F300 and cp <= 0x1FAFF) or
        (cp >= 0x20000 and cp <= 0x3FFFD)) return 2;

    return 1;
}

test "decode ascii" {
    var d = Decoder.init();
    try std.testing.expectEqual(@as(?u32, 'A'), d.push('A'));
}

test "decode 2-byte sequence" {
    var d = Decoder.init();
    // é = U+00E9 = 0xC3 0xA9
    try std.testing.expectEqual(@as(?u32, null), d.push(0xC3));
    try std.testing.expectEqual(@as(?u32, 0xE9), d.push(0xA9));
}

test "decode 3-byte sequence" {
    var d = Decoder.init();
    // 漢 = U+6F22 = 0xE6 0xBC 0xA2
    try std.testing.expectEqual(@as(?u32, null), d.push(0xE6));
    try std.testing.expectEqual(@as(?u32, null), d.push(0xBC));
    try std.testing.expectEqual(@as(?u32, 0x6F22), d.push(0xA2));
}

test "decode 4-byte sequence (emoji)" {
    var d = Decoder.init();
    // 😀 = U+1F600 = 0xF0 0x9F 0x98 0x80
    try std.testing.expectEqual(@as(?u32, null), d.push(0xF0));
    try std.testing.expectEqual(@as(?u32, null), d.push(0x9F));
    try std.testing.expectEqual(@as(?u32, null), d.push(0x98));
    try std.testing.expectEqual(@as(?u32, 0x1F600), d.push(0x80));
}

test "invalid lead byte yields replacement" {
    var d = Decoder.init();
    try std.testing.expectEqual(@as(?u32, REPLACEMENT), d.push(0xFF));
}

test "overlong E0 80 80 rejected" {
    var d = Decoder.init();
    try std.testing.expectEqual(@as(?u32, null), d.push(0xE0));
    try std.testing.expectEqual(@as(?u32, REPLACEMENT), d.push(0x80));
}

test "width" {
    try std.testing.expectEqual(@as(u8, 1), width('A'));
    try std.testing.expectEqual(@as(u8, 2), width(0x6F22)); // CJK
    try std.testing.expectEqual(@as(u8, 2), width(0x1F600)); // emoji
    try std.testing.expectEqual(@as(u8, 0), width(0x0301)); // combining acute
}
