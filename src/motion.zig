//! Cursor motions over lines of text, independent of the editor.
//!
//! Lines are read through any `lines` value with `count() usize` and
//! `get(line) ![]const u8` (a slice valid until the next `get`), so motions
//! work on the piece table in the editor and on plain slices in tests.
//! Positions are a line and a byte offset in it; byte == line length is the
//! end of the line (on its newline, or the end of the text on the last line).

const std = @import("std");
const text = @import("text.zig");

pub const Pos = struct { line: usize, byte: usize };

/// Combining marks belong to the character before them.
pub fn isMark(cp: u21) bool {
    return text.cellWidth(cp, 0) == 0;
}

/// Start of the character after the one at `i` (a character includes its
/// combining marks).
pub fn nextChar(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + text.decode(s[i..]).len;
    while (j < s.len and isMark(text.decode(s[j..]).cp)) j += text.decode(s[j..]).len;
    return j;
}

/// Start of the character before `i`.
pub fn prevChar(s: []const u8, i: usize) usize {
    var j = text.prevStart(s, i);
    while (j > 0 and isMark(text.decode(s[j..]).cp)) j = text.prevStart(s, j);
    return j;
}

/// Display column where byte `i` of line `s` starts.
pub fn displayCol(s: []const u8, i: usize) usize {
    var col: usize = 0;
    var j: usize = 0;
    while (j < i) {
        const ch = text.decode(s[j..]);
        col += text.cellWidth(ch.cp, col);
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
            const ch = text.decode(s[j..]);
            col += text.cellWidth(ch.cp, col);
            j += ch.len;
        }
        if (col > want) return i;
        i = next;
    }
    return s.len;
}

/// Byte offset of the first character that isn't a space or tab.
pub fn firstNonBlank(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return i;
}

/// Character classes for word motions: blanks (and line ends) separate
/// words; letters, digits, '_' and non-ASCII characters form words;
/// other ASCII punctuation forms words of its own. For WORD motions
/// (`big`), everything that isn't blank is one class.
fn class(cp: u21, big: bool) u2 {
    if (cp == ' ' or cp == '\t' or cp == '\n') return 0;
    if (big) return 1;
    if (cp >= 0x80 or cp == '_' or std.ascii.isAlphanumeric(@intCast(cp))) return 2;
    return 1;
}

/// Walks characters across lines. The end of each line counts as a '\n'
/// character; the end of the last line is the end of the text.
fn Scanner(comptime Lines: type) type {
    return struct {
        lines: Lines,
        pos: Pos,
        line_text: []const u8,

        const Self = @This();

        fn init(lines: Lines, pos: Pos) !Self {
            return .{ .lines = lines, .pos = pos, .line_text = try lines.get(pos.line) };
        }

        fn char(self: *const Self) u21 {
            if (self.pos.byte >= self.line_text.len) return '\n';
            return text.decode(self.line_text[self.pos.byte..]).cp;
        }

        fn cls(self: *const Self, big: bool) u2 {
            return class(self.char(), big);
        }

        fn onEmptyLine(self: *const Self) bool {
            return self.line_text.len == 0;
        }

        fn moveTo(self: *Self, pos: Pos) !void {
            if (pos.line != self.pos.line) self.line_text = try self.lines.get(pos.line);
            self.pos = pos;
        }

        fn forward(self: *Self) !bool {
            if (self.pos.byte < self.line_text.len) {
                self.pos.byte = nextChar(self.line_text, self.pos.byte);
                return true;
            }
            if (self.pos.line + 1 >= self.lines.count()) return false;
            try self.moveTo(.{ .line = self.pos.line + 1, .byte = 0 });
            return true;
        }

        fn backward(self: *Self) !bool {
            if (self.pos.byte > 0) {
                self.pos.byte = prevChar(self.line_text, @min(self.pos.byte, self.line_text.len));
                return true;
            }
            if (self.pos.line == 0) return false;
            const prev = try self.lines.get(self.pos.line - 1);
            self.line_text = prev;
            self.pos = .{ .line = self.pos.line - 1, .byte = prev.len };
            return true;
        }
    };
}

/// `w` / `W`: start of the next word. Stops at empty lines; past the last
/// word it goes to the end of the text.
pub fn wordForward(lines: anytype, from: Pos, big: bool) !Pos {
    var sc = try Scanner(@TypeOf(lines)).init(lines, from);
    const start_class = sc.cls(big);
    if (start_class != 0) {
        while (sc.cls(big) == start_class) if (!try sc.forward()) return sc.pos;
    }
    while (true) {
        if (sc.onEmptyLine() and sc.pos.line != from.line) return sc.pos;
        if (sc.cls(big) != 0) return sc.pos;
        if (!try sc.forward()) return sc.pos;
    }
}

/// `e` / `E`: end of the current or next word. Skips empty lines.
pub fn wordEnd(lines: anytype, from: Pos, big: bool) !Pos {
    var sc = try Scanner(@TypeOf(lines)).init(lines, from);
    if (!try sc.forward()) return sc.pos;
    while (sc.cls(big) == 0) if (!try sc.forward()) return sc.pos;
    const c = sc.cls(big);
    while (true) {
        const here = sc.pos;
        if (!try sc.forward() or sc.cls(big) != c) {
            try sc.moveTo(here);
            return here;
        }
    }
}

/// `b` / `B`: start of the current or previous word. Stops at empty lines.
pub fn wordBackward(lines: anytype, from: Pos, big: bool) !Pos {
    var sc = try Scanner(@TypeOf(lines)).init(lines, from);
    if (!try sc.backward()) return sc.pos;
    while (true) {
        if (sc.onEmptyLine() and sc.pos.line != from.line) return sc.pos;
        if (sc.cls(big) != 0) break;
        if (!try sc.backward()) return sc.pos;
    }
    const c = sc.cls(big);
    while (true) {
        const here = sc.pos;
        if (!try sc.backward() or sc.cls(big) != c) {
            try sc.moveTo(here);
            return here;
        }
    }
}

/// `cw` / `cW`: like `e`, except that on the last character of a word it
/// stays put, so only that character changes.
pub fn changeWordEnd(lines: anytype, from: Pos, count: usize, big: bool) !Pos {
    var sc = try Scanner(@TypeOf(lines)).init(lines, from);
    const c = sc.cls(big);
    var p = from;
    if (try sc.forward() and sc.cls(big) == c) p = try wordEnd(lines, from, big);
    for (1..count) |_| p = try wordEnd(lines, p, big);
    return p;
}

pub const FindKind = enum {
    /// f: onto the next occurrence.
    to,
    /// t: just before the next occurrence.
    till,
    /// F: onto the previous occurrence.
    back_to,
    /// T: just after the previous occurrence.
    back_till,

    pub fn reversed(k: FindKind) FindKind {
        return switch (k) {
            .to => .back_to,
            .till => .back_till,
            .back_to => .to,
            .back_till => .till,
        };
    }

    pub fn isForward(k: FindKind) bool {
        return k == .to or k == .till;
    }
};

/// `f` `t` `F` `T`: the byte offset in line `s` of the `count`th occurrence
/// of `target` from byte `from`, or null if there aren't that many.
/// `repeat` is true for `;` and `,`: a `t` that would stay put (the target
/// is right next to the cursor) moves on to the next occurrence.
pub fn findInLine(s: []const u8, from: usize, kind: FindKind, target: u21, count: usize, repeat: bool) ?usize {
    var i = from;
    var found: usize = 0;
    var last: usize = from;
    if (kind.isForward()) {
        if (repeat and kind == .till and i < s.len) i = nextChar(s, i);
        while (i < s.len) {
            i = nextChar(s, i);
            if (i >= s.len) break;
            if (text.decode(s[i..]).cp == target) {
                found += 1;
                last = i;
                if (found == count) return if (kind == .till) prevChar(s, last) else last;
            }
        }
    } else {
        if (repeat and kind == .back_till and i > 0) i = prevChar(s, i);
        while (i > 0) {
            i = prevChar(s, i);
            if (text.decode(s[i..]).cp == target) {
                found += 1;
                last = i;
                if (found == count) return if (kind == .back_till) nextChar(s, last) else last;
            }
        }
    }
    return null;
}

const testing = std.testing;

/// Lines from a slice of strings, for tests.
const TestLines = struct {
    items: []const []const u8,
    fn count(self: TestLines) usize {
        return self.items.len;
    }
    fn get(self: TestLines, line: usize) ![]const u8 {
        return self.items[line];
    }
};

fn expectPos(expected: Pos, got: Pos) !void {
    try testing.expectEqual(expected.line, got.line);
    try testing.expectEqual(expected.byte, got.byte);
}

test "w stops at word and punctuation boundaries" {
    const l: TestLines = .{ .items = &.{"foo.bar(baz) qux"} };
    var p: Pos = .{ .line = 0, .byte = 0 };
    const expected = [_]usize{ 3, 4, 7, 8, 11, 13, 16 };
    for (expected) |b| {
        p = try wordForward(l, p, false);
        try expectPos(.{ .line = 0, .byte = b }, p);
    }
}

test "W only splits on blanks" {
    const l: TestLines = .{ .items = &.{"foo.bar(baz) qux"} };
    try expectPos(.{ .line = 0, .byte = 13 }, try wordForward(l, .{ .line = 0, .byte = 0 }, true));
}

test "w crosses lines and stops on empty lines" {
    const l: TestLines = .{ .items = &.{ "one  ", "", "  two", "three" } };
    var p = try wordForward(l, .{ .line = 0, .byte = 0 }, false);
    try expectPos(.{ .line = 1, .byte = 0 }, p);
    p = try wordForward(l, p, false);
    try expectPos(.{ .line = 2, .byte = 2 }, p);
    p = try wordForward(l, p, false);
    try expectPos(.{ .line = 3, .byte = 0 }, p);
    p = try wordForward(l, p, false);
    try expectPos(.{ .line = 3, .byte = 5 }, p); // end of text
}

test "e goes to word ends and skips empty lines" {
    const l: TestLines = .{ .items = &.{ "ab cd.", "", "ef" } };
    var p = try wordEnd(l, .{ .line = 0, .byte = 0 }, false);
    try expectPos(.{ .line = 0, .byte = 1 }, p);
    p = try wordEnd(l, p, false);
    try expectPos(.{ .line = 0, .byte = 4 }, p);
    p = try wordEnd(l, p, false);
    try expectPos(.{ .line = 0, .byte = 5 }, p); // "." is its own word
    p = try wordEnd(l, p, false);
    try expectPos(.{ .line = 2, .byte = 1 }, p);
}

test "b goes back to word starts and stops on empty lines" {
    const l: TestLines = .{ .items = &.{ "ab cd", "", "ef gh" } };
    var p = try wordBackward(l, .{ .line = 2, .byte = 4 }, false);
    try expectPos(.{ .line = 2, .byte = 3 }, p);
    p = try wordBackward(l, p, false);
    try expectPos(.{ .line = 2, .byte = 0 }, p);
    p = try wordBackward(l, p, false);
    try expectPos(.{ .line = 1, .byte = 0 }, p);
    p = try wordBackward(l, p, false);
    try expectPos(.{ .line = 0, .byte = 3 }, p);
    p = try wordBackward(l, p, false);
    try expectPos(.{ .line = 0, .byte = 0 }, p);
    p = try wordBackward(l, p, false);
    try expectPos(.{ .line = 0, .byte = 0 }, p);
}

test "word motions treat non-ASCII letters as word characters" {
    const l: TestLines = .{ .items = &.{"café über, 中文 x"} };
    var p = try wordForward(l, .{ .line = 0, .byte = 0 }, false);
    try expectPos(.{ .line = 0, .byte = 6 }, p); // "über"
    p = try wordForward(l, p, false);
    try expectPos(.{ .line = 0, .byte = 11 }, p); // ","
    p = try wordEnd(l, p, false);
    try expectPos(.{ .line = 0, .byte = 16 }, p); // last byte-start of "中文"
}

test "f, t, F and T within a line" {
    const s = "a,b,c,d";
    try testing.expectEqual(@as(?usize, 1), findInLine(s, 0, .to, ',', 1, false));
    try testing.expectEqual(@as(?usize, 3), findInLine(s, 0, .to, ',', 2, false));
    try testing.expectEqual(@as(?usize, 0), findInLine(s, 0, .till, ',', 1, false));
    try testing.expectEqual(@as(?usize, null), findInLine(s, 0, .to, ',', 4, false));
    try testing.expectEqual(@as(?usize, 5), findInLine(s, 6, .back_to, ',', 1, false));
    try testing.expectEqual(@as(?usize, 6), findInLine(s, 6, .back_till, ',', 1, false));
    // ; after t moves past the occurrence right next to the cursor
    try testing.expectEqual(@as(?usize, 2), findInLine(s, 0, .till, ',', 1, true));
    // Multibyte targets: t stops on the character before the 2nd 中 ("b").
    try testing.expectEqual(@as(?usize, 4), findInLine("a中b中", 0, .till, '中', 2, false));
}
