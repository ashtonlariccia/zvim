//! UTF-8 decoding and display width.
//!
//! Text is assumed to be UTF-8, but any byte sequence must still display and
//! move sanely: each byte that isn't part of a valid sequence is its own
//! character, shown as U+FFFD.

const std = @import("std");
const width_table = @import("width_table.zig");

pub const replacement: u21 = 0xFFFD;

pub const Char = struct {
    /// The decoded codepoint, or `replacement` for an invalid byte.
    cp: u21,
    /// Bytes this character occupies (1-4).
    len: u3,
};

/// Decodes the character at the start of `bytes`, which must not be empty.
pub fn decode(bytes: []const u8) Char {
    const len = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return .{ .cp = replacement, .len = 1 };
    if (len > bytes.len) return .{ .cp = replacement, .len = 1 };
    const cp = std.unicode.utf8Decode(bytes[0..len]) catch return .{ .cp = replacement, .len = 1 };
    return .{ .cp = cp, .len = len };
}

/// Byte offset where the character ending at `end` starts. `end` must be > 0.
pub fn prevStart(bytes: []const u8, end: usize) usize {
    // A character is at most 4 bytes: find a lead byte within reach whose
    // sequence ends exactly at `end`. Otherwise the last byte stands alone.
    var start = end - 1;
    while (start > 0 and end - start < 4 and bytes[start] & 0xC0 == 0x80) start -= 1;
    if (start + decode(bytes[start..end]).len == end) return start;
    return end - 1;
}

/// Columns a codepoint occupies on screen: 0, 1 or 2. Control characters
/// are the renderer's business and report 1 here.
pub fn width(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if (inRanges(&width_table.zero, cp)) return 0;
    if (inRanges(&width_table.wide, cp)) return 2;
    return 1;
}

/// How wide a tab is on screen (the `tabstop` setting).
pub var tab_width: usize = 4;

/// Columns `cp` takes on screen when it starts at display column `col`:
/// tabs reach the next tab stop, control characters show as ^X, and
/// unprintable characters as U+FFFD.
pub fn cellWidth(cp: u21, col: usize) usize {
    if (cp == '\t') return tab_width - col % tab_width;
    if (cp < 0x20 or cp == 0x7f) return 2;
    if (isUnprintable(cp)) return 1;
    return width(cp);
}

/// Invalid bytes and C1 control characters, which are shown as U+FFFD.
pub fn isUnprintable(cp: u21) bool {
    return cp == replacement or (cp >= 0x80 and cp < 0xa0);
}

// Characters of a line. A character here includes the combining marks that
// follow it, so the cursor never lands between a letter and its accent.

/// Combining marks belong to the character before them.
pub fn isMark(cp: u21) bool {
    return cellWidth(cp, 0) == 0;
}

/// Start of the character after the one at `i` (a character includes its
/// combining marks).
pub fn nextChar(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + decode(s[i..]).len;
    while (j < s.len and isMark(decode(s[j..]).cp)) j += decode(s[j..]).len;
    return j;
}

/// Start of the character before `i`.
pub fn prevChar(s: []const u8, i: usize) usize {
    var j = prevStart(s, i);
    while (j > 0 and isMark(decode(s[j..]).cp)) j = prevStart(s, j);
    return j;
}

/// Display column where byte `i` of line `s` starts.
pub fn displayCol(s: []const u8, i: usize) usize {
    var col: usize = 0;
    var j: usize = 0;
    while (j < i) {
        const ch = decode(s[j..]);
        col += cellWidth(ch.cp, col);
        j += ch.len;
    }
    return col;
}

/// Byte offset of the character covering display column `want`, or the end
/// of the line if it is shorter.
pub fn byteAtCol(s: []const u8, want: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const next = nextChar(s, i);
        var j = i;
        while (j < next) {
            const ch = decode(s[j..]);
            col += cellWidth(ch.cp, col);
            j += ch.len;
        }
        if (col > want) return i;
        i = next;
    }
    return s.len;
}

pub fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// Byte offset of the first character that isn't a space or tab.
pub fn firstNonBlank(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and isBlank(s[i])) i += 1;
    return i;
}

fn inRanges(ranges: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

const testing = std.testing;

test "decode valid characters" {
    try testing.expectEqual(Char{ .cp = 'a', .len = 1 }, decode("abc"));
    try testing.expectEqual(Char{ .cp = 'é', .len = 2 }, decode("é!"));
    try testing.expectEqual(Char{ .cp = '中', .len = 3 }, decode("中"));
    try testing.expectEqual(Char{ .cp = '😀', .len = 4 }, decode("😀"));
}

test "invalid bytes decode one at a time" {
    try testing.expectEqual(Char{ .cp = replacement, .len = 1 }, decode("\xff"));
    try testing.expectEqual(Char{ .cp = replacement, .len = 1 }, decode("\x80a"));
    // Truncated sequence: lead byte of a 3-byte char followed by only one byte.
    try testing.expectEqual(Char{ .cp = replacement, .len = 1 }, decode("\xe4\xb8"));
    // Overlong encoding of '/'.
    try testing.expectEqual(Char{ .cp = replacement, .len = 1 }, decode("\xc0\xaf"));
}

test "prevStart steps back over whole characters" {
    const s = "a中😀é";
    try testing.expectEqual(@as(usize, 8), prevStart(s, 10));
    try testing.expectEqual(@as(usize, 4), prevStart(s, 8));
    try testing.expectEqual(@as(usize, 1), prevStart(s, 4));
    try testing.expectEqual(@as(usize, 0), prevStart(s, 1));
}

test "prevStart treats stray continuation bytes as single characters" {
    const s = "a\x80\x80";
    try testing.expectEqual(@as(usize, 2), prevStart(s, 3));
    try testing.expectEqual(@as(usize, 1), prevStart(s, 2));
    // A truncated sequence: each byte is its own character.
    try testing.expectEqual(@as(usize, 2), prevStart("a\xe4\xb8", 3));
}

test "forward and backward stepping agree on any bytes" {
    var prng: std.Random.DefaultPrng = .init(1);
    const rand = prng.random();
    const pool = [_][]const u8{ "a", "é", "中", "😀", "\xff", "\x80", "\xe4\xb8", "\n" };
    for (0..500) |_| {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        while (n < 48) {
            const piece = pool[rand.uintLessThan(usize, pool.len)];
            @memcpy(buf[n..][0..piece.len], piece);
            n += piece.len;
        }
        const s = buf[0..n];

        var starts: [64]usize = undefined;
        var count: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (i += decode(s[i..]).len) {
            starts[count] = i;
            count += 1;
        }
        var end = s.len;
        while (count > 0) {
            count -= 1;
            end = prevStart(s, end);
            try testing.expectEqual(starts[count], end);
        }
    }
}

test "display widths" {
    try testing.expectEqual(@as(u2, 1), width('a'));
    try testing.expectEqual(@as(u2, 1), width('é'));
    try testing.expectEqual(@as(u2, 0), width(0x301)); // combining acute accent
    try testing.expectEqual(@as(u2, 0), width(0x200D)); // zero width joiner
    try testing.expectEqual(@as(u2, 2), width('中'));
    try testing.expectEqual(@as(u2, 2), width('한'));
    try testing.expectEqual(@as(u2, 2), width('😀'));
    try testing.expectEqual(@as(u2, 2), width('Ａ')); // fullwidth A
    try testing.expectEqual(@as(u2, 1), width(replacement));
}
