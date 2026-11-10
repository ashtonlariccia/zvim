//! Motions: which key moves where, and moving the cursor or handing the
//! range to a pending operator.

const std = @import("std");
const Editor = @import("../Editor.zig");
const Key = @import("../keys.zig").Key;
const text = @import("../text.zig");
const words = @import("words.zig");
const nextChar = text.nextChar;
const prevChar = text.prevChar;
const byteAtCol = text.byteAtCol;
const firstNonBlank = text.firstNonBlank;
const cmdline = @import("cmdline.zig");
const operators = @import("operators.zig");

pub const Motion = union(enum) {
    left,
    right,
    down,
    up,
    /// Down to the first non-blank (Enter).
    down_first_non_blank,
    line_start,
    first_non_blank,
    line_end,
    word_forward: bool,
    word_end: bool,
    word_backward: bool,
    file_start,
    file_end,
    half_page_down,
    half_page_up,
    find: struct { kind: words.FindKind, target: u21, repeat: bool },
    /// ; (false) and , (true).
    repeat_find: bool,
    /// n (false) and N (true).
    search_next: bool,
};

pub fn motionFor(key: Key) ?Motion {
    return switch (key) {
        .char => |c| switch (c) {
            'h' => .left,
            'l', ' ' => .right,
            'j' => .down,
            'k' => .up,
            '0' => .line_start,
            '^' => .first_non_blank,
            '$' => .line_end,
            'w' => .{ .word_forward = false },
            'W' => .{ .word_forward = true },
            'e' => .{ .word_end = false },
            'E' => .{ .word_end = true },
            'b' => .{ .word_backward = false },
            'B' => .{ .word_backward = true },
            'G' => .file_end,
            ';' => .{ .repeat_find = false },
            ',' => .{ .repeat_find = true },
            'n' => .{ .search_next = false },
            'N' => .{ .search_next = true },
            '+' => .down_first_non_blank,
            else => null,
        },
        .left, .backspace => .left,
        .right => .right,
        .down => .down,
        .up => .up,
        .enter => .down_first_non_blank,
        .home => .line_start,
        .end => .line_end,
        .ctrl => |c| switch (c) {
            'd' => .half_page_down,
            'u' => .half_page_up,
            else => null,
        },
        else => null,
    };
}

pub const Target = struct {
    pos: usize,
    kind: enum { exclusive, inclusive, linewise },
    /// How the column j/k aim for changes: to the new column, unchanged, or
    /// to the end of every line ($).
    want: enum { update, keep, end } = .update,
};

/// Lines of the buffer, for the word motions in `words`.
pub const Lines = struct {
    ed: *Editor,
    pub fn count(lines: Lines) usize {
        return lines.ed.buffer.visibleLineCount();
    }
    pub fn get(lines: Lines, line: usize) ![]const u8 {
        return lines.ed.lineText(line);
    }
};

/// Runs a motion with the pending count: moves the cursor, or applies the
/// pending operator to the text moved over.
pub fn doMotion(ed: *Editor, m: Motion) !void {
    const p = ed.pending;
    ed.pending = .{};
    const count = @max(p.count, 1) * @max(p.op_count, 1);
    const has_count = p.count > 0 or p.op_count > 0;
    const target = (try motionTarget(ed, m, count, has_count, p.op)) orelse {
        ed.failed = true;
        return;
    };
    if (p.op) |op| return operators.applyOperator(ed, op, target);
    try moveTo(ed, target);
}

pub fn moveTo(ed: *Editor, target: Target) !void {
    const line = ed.buffer.lineOf(target.pos);
    const start = ed.buffer.lineStart(line);
    const s = try ed.lineText(line);
    ed.cursor = start + @min(target.pos - start, ed.maxByte(s));
    switch (target.want) {
        .update => try ed.updateWantCol(),
        .keep => {},
        .end => ed.want_col = std.math.maxInt(usize),
    }
}

/// Where motion `m` goes from the cursor, or null if it can't move.
pub fn motionTarget(ed: *Editor, m: Motion, count: usize, has_count: bool, op: ?Editor.Op) !?Target {
    const here = ed.toPos(ed.cursor);
    const lines = ed.buffer.visibleLineCount();
    const lv: Lines = .{ .ed = ed };
    switch (m) {
        .left => {
            const s = try ed.lineText(here.line);
            var b = here.byte;
            for (0..count) |_| if (b > 0) {
                b = prevChar(s, b);
            };
            if (b == here.byte) return null;
            return .{ .pos = ed.cursor - (here.byte - b), .kind = .exclusive };
        },
        .right => {
            const s = try ed.lineText(here.line);
            const limit = if (op != null) s.len else ed.maxByte(s);
            var b = here.byte;
            for (0..count) |_| {
                const n = nextChar(s, b);
                if (n > limit or n == b) break;
                b = n;
            }
            if (b == here.byte) return null;
            return .{ .pos = ed.cursor + (b - here.byte), .kind = .exclusive };
        },
        .down, .up, .down_first_non_blank => {
            const line = if (m == .up) here.line -| count else @min(here.line + count, lines - 1);
            if (line == here.line) return null;
            const s = try ed.lineText(line);
            if (m == .down_first_non_blank) {
                return .{ .pos = ed.buffer.lineStart(line) + firstNonBlank(s), .kind = .linewise };
            }
            const b = @min(byteAtCol(s, ed.want_col), ed.maxByte(s));
            return .{ .pos = ed.buffer.lineStart(line) + b, .kind = .linewise, .want = .keep };
        },
        .line_start => return .{ .pos = ed.buffer.lineStart(here.line), .kind = .exclusive },
        .first_non_blank => {
            const s = try ed.lineText(here.line);
            return .{ .pos = ed.buffer.lineStart(here.line) + firstNonBlank(s), .kind = .exclusive };
        },
        .line_end => {
            const line = @min(here.line + count - 1, lines - 1);
            const s = try ed.lineText(line);
            const start = ed.buffer.lineStart(line);
            if (op != null) {
                if (s.len == 0) return .{ .pos = start, .kind = .exclusive, .want = .end };
                return .{ .pos = start + prevChar(s, s.len), .kind = .inclusive, .want = .end };
            }
            return .{ .pos = start + ed.maxByte(s), .kind = .inclusive, .want = .end };
        },
        .word_forward => |big| {
            if (op == .change and !try onBlank(ed, here)) {
                // cw changes to the end of the word, not up to the next one.
                const p = try words.changeWordEnd(lv, here, count, big);
                return .{ .pos = ed.toOffset(p), .kind = .inclusive };
            }
            var p = here;
            var prev = here;
            for (0..count) |_| {
                prev = p;
                p = try words.wordForward(lv, p, big);
            }
            // An operator on the last word of a line stops at the line's end
            // instead of reaching into the next line.
            if (op != null and p.line > prev.line) {
                p = .{ .line = prev.line, .byte = (try ed.lineText(prev.line)).len };
            }
            if (p.line == here.line and p.byte == here.byte) return null;
            return .{ .pos = ed.toOffset(p), .kind = .exclusive };
        },
        .word_end => |big| {
            var p = here;
            for (0..count) |_| p = try words.wordEnd(lv, p, big);
            if (p.line == here.line and p.byte == here.byte) return null;
            return .{ .pos = ed.toOffset(p), .kind = .inclusive };
        },
        .word_backward => |big| {
            var p = here;
            for (0..count) |_| p = try words.wordBackward(lv, p, big);
            if (p.line == here.line and p.byte == here.byte) return null;
            return .{ .pos = ed.toOffset(p), .kind = .exclusive };
        },
        .file_start, .file_end => {
            const line = if (has_count) @min(count, lines) - 1 else if (m == .file_start) 0 else lines - 1;
            const s = try ed.lineText(line);
            return .{ .pos = ed.buffer.lineStart(line) + firstNonBlank(s), .kind = .linewise };
        },
        .half_page_down, .half_page_up => {
            const amount = if (has_count) count else @max(1, ed.view_rows / 2);
            const line = if (m == .half_page_up) here.line -| amount else @min(here.line + amount, lines - 1);
            if (line == here.line) return null;
            // The view scrolls by the same amount.
            if (m == .half_page_up) {
                ed.top -|= amount;
            } else {
                ed.top = @min(ed.top + amount, lines - 1);
            }
            const s = try ed.lineText(line);
            const b = @min(byteAtCol(s, ed.want_col), ed.maxByte(s));
            return .{ .pos = ed.buffer.lineStart(line) + b, .kind = .linewise, .want = .keep };
        },
        .find => |f| return findTarget(ed, here, f.kind, f.target, count, f.repeat),
        .repeat_find => |reverse| {
            const last = ed.last_find orelse return null;
            const kind = if (reverse) last.kind.reversed() else last.kind;
            return findTarget(ed, here, kind, last.target, count, true);
        },
        .search_next => |reverse| {
            if (ed.last_search.items.len == 0) {
                ed.setMessage(true, "E35: No previous regular expression", .{});
                return null;
            }
            const forward = ed.last_search_forward != reverse;
            var pos = ed.cursor;
            for (0..count) |_| {
                pos = try cmdline.search(ed, pos, forward) orelse {
                    ed.setMessage(true, "E486: Pattern not found: {s}", .{ed.last_search.items});
                    return null;
                };
            }
            return .{ .pos = pos, .kind = .exclusive };
        },
    }
}

pub fn findTarget(ed: *Editor, here: words.Pos, kind: words.FindKind, target: u21, count: usize, repeat: bool) !?Target {
    const s = try ed.lineText(here.line);
    const b = words.findInLine(s, here.byte, kind, target, count, repeat) orelse return null;
    return .{
        .pos = ed.buffer.lineStart(here.line) + b,
        .kind = if (kind.isForward()) .inclusive else .exclusive,
    };
}

pub fn onBlank(ed: *Editor, p: words.Pos) !bool {
    const s = try ed.lineText(p.line);
    return p.byte >= s.len or s[p.byte] == ' ' or s[p.byte] == '\t';
}

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const expectCursor = h.expectCursor;

test "h and l stay within the line, on its last character" {
    var e = try testEditor("abc\nde\n");
    defer e.deinit();
    try typeKeys(&e, "h");
    try expectCursor(&e, 0, 0);
    try typeKeys(&e, "llll");
    try expectCursor(&e, 0, 2);
    try typeKeys(&e, "h");
    try expectCursor(&e, 0, 1);
}

test "j and k keep the wanted column across short lines" {
    var e = try testEditor("long line\nab\n\nanother long\n");
    defer e.deinit();
    try typeKeys(&e, "llllll"); // col 6
    try typeKeys(&e, "j");
    try expectCursor(&e, 1, 1); // clamped to "b"
    try typeKeys(&e, "j");
    try expectCursor(&e, 2, 0); // empty line
    try typeKeys(&e, "j");
    try expectCursor(&e, 3, 6); // back to col 6
    try typeKeys(&e, "jjj"); // no line 4: the final newline ends line 3
    try expectCursor(&e, 3, 6);
    try typeKeys(&e, "kkkkk");
    try expectCursor(&e, 0, 6);
}

test "0 and $ and the wanted column after $" {
    var e = try testEditor("abcdef\nxy\nlonger line\n");
    defer e.deinit();
    try typeKeys(&e, "$");
    try expectCursor(&e, 0, 5);
    try typeKeys(&e, "j");
    try expectCursor(&e, 1, 1);
    try typeKeys(&e, "j"); // $ sticks to the end of each line
    try expectCursor(&e, 2, 10);
    try typeKeys(&e, "0");
    try expectCursor(&e, 2, 0);
}

test "moving over multibyte, wide and combining characters" {
    var e = try testEditor("aé中e\u{301}x\n1234567\n");
    defer e.deinit();
    try typeKeys(&e, "l");
    try expectCursor(&e, 0, 1); // é
    try typeKeys(&e, "l");
    try expectCursor(&e, 0, 3); // 中
    try typeKeys(&e, "l");
    try expectCursor(&e, 0, 6); // e + combining accent is one character
    try typeKeys(&e, "l");
    try expectCursor(&e, 0, 9); // x
    try testing.expectEqual(@as(usize, 5), (try e.cursorPos()).col);
    try typeKeys(&e, "h");
    try expectCursor(&e, 0, 6);
    try typeKeys(&e, "h");
    try expectCursor(&e, 0, 3);
    // 中 covers columns 2-3; moving down lands on column 2.
    try typeKeys(&e, "j");
    try expectCursor(&e, 1, 2);
    try typeKeys(&e, "lk"); // column 3 is the second half of 中
    try expectCursor(&e, 0, 3);
}

test "tabs: cursor sits on the tab, columns count to the tab stop" {
    var e = try testEditor("\tx\n0123456789\n");
    defer e.deinit();
    try typeKeys(&e, "l");
    try expectCursor(&e, 0, 1);
    try testing.expectEqual(@as(usize, 8), (try e.cursorPos()).col);
    try typeKeys(&e, "j");
    try expectCursor(&e, 1, 8);
    try typeKeys(&e, "hhhk"); // column 5 is inside the tab
    try expectCursor(&e, 0, 0);
}

test "arrow keys move like hjkl" {
    var e = try testEditor("ab\ncd\n");
    defer e.deinit();
    try typeKeys(&e, "\x1b[C\x1b[B");
    try expectCursor(&e, 1, 1);
    try typeKeys(&e, "\x1b[D\x1b[A");
    try expectCursor(&e, 0, 0);
}

test "empty buffer" {
    var e = try testEditor("");
    defer e.deinit();
    try typeKeys(&e, "hjkl0$");
    try expectCursor(&e, 0, 0);
}

test "the view follows the cursor" {
    var e = try testEditor("1\n2\n3\n4\n5\nabcdefghijklmnop\n");
    defer e.deinit();
    try typeKeys(&e, "jjjj");
    try e.scrollToCursor(3, 10);
    try testing.expectEqual(@as(usize, 2), e.top);
    try typeKeys(&e, "j$");
    try e.scrollToCursor(3, 10);
    try testing.expectEqual(@as(usize, 3), e.top);
    try testing.expectEqual(@as(usize, 6), e.left); // 'p' at column 15 is the last visible column
    try typeKeys(&e, "0kkkkk");
    try e.scrollToCursor(3, 10);
    try testing.expectEqual(@as(usize, 0), e.top);
    try testing.expectEqual(@as(usize, 0), e.left);
}

test "a wide character at the right edge scrolls fully into view" {
    var e = try testEditor("abcd中\n");
    defer e.deinit();
    try typeKeys(&e, "$");
    try e.scrollToCursor(1, 5);
    try testing.expectEqual(@as(usize, 1), e.left); // 中 at columns 4-5
}

test "counts multiply with motions" {
    var e = try testEditor("a\nb\nc\nd\ne\nf\n");
    defer e.deinit();
    try typeKeys(&e, "3j");
    try expectCursor(&e, 3, 0);
    try typeKeys(&e, "2k");
    try expectCursor(&e, 1, 0);
    try typeKeys(&e, "10j"); // as far as it goes
    try expectCursor(&e, 5, 0);
}

test "w, b, e and their WORD forms move the cursor" {
    var e = try testEditor("foo.bar baz\n  qux\n");
    defer e.deinit();
    try typeKeys(&e, "w");
    try expectCursor(&e, 0, 3);
    try typeKeys(&e, "W");
    try expectCursor(&e, 0, 8);
    try typeKeys(&e, "w");
    try expectCursor(&e, 1, 2);
    try typeKeys(&e, "b");
    try expectCursor(&e, 0, 8);
    try typeKeys(&e, "B");
    try expectCursor(&e, 0, 0);
    try typeKeys(&e, "e");
    try expectCursor(&e, 0, 2);
    try typeKeys(&e, "2e");
    try expectCursor(&e, 0, 6);
    try typeKeys(&e, "www"); // past the last word: stays on the last character
    try expectCursor(&e, 1, 4);
}

test "^, gg, G and counts on G" {
    var e = try testEditor("  one\n  two\nthree\n");
    defer e.deinit();
    try typeKeys(&e, "$^");
    try expectCursor(&e, 0, 2);
    try typeKeys(&e, "G");
    try expectCursor(&e, 2, 0);
    try typeKeys(&e, "gg");
    try expectCursor(&e, 0, 2);
    try typeKeys(&e, "2G");
    try expectCursor(&e, 1, 2);
}

test "f, t, F, T, ; and ," {
    var e = try testEditor("a,b,c,d\n");
    defer e.deinit();
    try typeKeys(&e, "f,");
    try expectCursor(&e, 0, 1);
    try typeKeys(&e, ";");
    try expectCursor(&e, 0, 3);
    try typeKeys(&e, ",");
    try expectCursor(&e, 0, 1);
    try typeKeys(&e, "$T,");
    try expectCursor(&e, 0, 6);
    try typeKeys(&e, "0t,;"); // ; after t skips the adjacent match
    try expectCursor(&e, 0, 2);
    try typeKeys(&e, "fz"); // not found: stays
    try expectCursor(&e, 0, 2);
}

test "Ctrl-D and Ctrl-U move half a screen" {
    var e = try testEditor("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n");
    defer e.deinit();
    try e.scrollToCursor(4, 10);
    try typeKeys(&e, "\x04");
    try expectCursor(&e, 2, 0);
    try typeKeys(&e, "\x04\x04\x04\x04\x04");
    try expectCursor(&e, 9, 0);
    try typeKeys(&e, "\x15");
    try expectCursor(&e, 7, 0);
}
