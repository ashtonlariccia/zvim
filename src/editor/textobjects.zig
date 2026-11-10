//! Text objects: `i`/`a` + an object key after an operator or in visual mode
//! (diw, ci", ya(, vip). `i` is the inside, `a` includes the delimiters or
//! the surrounding space.

const std = @import("std");
const Editor = @import("../Editor.zig");
const text = @import("../text.zig");
const words = @import("words.zig");
const nextChar = text.nextChar;
const prevChar = text.prevChar;
const isBlank = text.isBlank;

pub const Range = union(enum) {
    /// Bytes [start, end).
    chars: struct { start: usize, end: usize },
    /// Whole lines first through last.
    lines: struct { first: usize, last: usize },
};

/// The range of object `key` (w, W, ", ', `, ( ) b, [ ], { } B, < >, p)
/// around the cursor, or null if there is none.
pub fn find(ed: *Editor, key: u21, around: bool, count: usize) !?Range {
    return switch (key) {
        'w' => word(ed, around, false),
        'W' => word(ed, around, true),
        '"', '\'', '`' => quoted(ed, @intCast(key), around),
        '(', ')', 'b' => bracketed(ed, '(', ')', around, count),
        '[', ']' => bracketed(ed, '[', ']', around, count),
        '{', '}', 'B' => bracketed(ed, '{', '}', around, count),
        '<', '>' => bracketed(ed, '<', '>', around, count),
        'p' => paragraph(ed, around),
        else => null,
    };
}

fn classAt(s: []const u8, i: usize, big: bool) u2 {
    return words.class(text.decode(s[i..]).cp, big);
}

/// iw: the word, run of punctuation or run of blanks under the cursor.
/// aw: a word plus the blanks after it (or before it, if none follow); on
/// blanks, the blanks plus the word after them.
fn word(ed: *Editor, around: bool, big: bool) !?Range {
    const here = ed.toPos(ed.cursor);
    const s = try ed.lineText(here.line);
    if (s.len == 0) return null;
    const b = @min(here.byte, prevChar(s, s.len));
    const c = classAt(s, b, big);

    var start = b;
    while (start > 0 and classAt(s, prevChar(s, start), big) == c) start = prevChar(s, start);
    var end = nextChar(s, b);
    while (end < s.len and classAt(s, end, big) == c) end = nextChar(s, end);

    if (around) {
        if (c == 0) {
            // Blanks, then the word after them.
            if (end < s.len) {
                const c2 = classAt(s, end, big);
                while (end < s.len and classAt(s, end, big) == c2) end = nextChar(s, end);
            }
        } else if (end < s.len and isBlank(s[end])) {
            while (end < s.len and isBlank(s[end])) end += 1;
        } else {
            while (start > 0 and isBlank(s[start - 1])) start -= 1;
        }
    }
    const line_start = ed.buffer.lineStart(here.line);
    return .{ .chars = .{ .start = line_start + start, .end = line_start + end } };
}

/// i" a" (and ' and `): the quoted text on the cursor's line. On a quote,
/// whether it opens or closes is decided by counting quotes from the start
/// of the line; before any quoted text, the next one on the line is used.
/// Quotes escaped with a backslash don't count. a" includes the quotes and
/// the blanks after them (or before them, if none follow).
fn quoted(ed: *Editor, q: u8, around: bool) !?Range {
    const here = ed.toPos(ed.cursor);
    const s = try ed.lineText(here.line);

    var quotes: [256]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < quotes.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == q) {
            quotes[n] = i;
            n += 1;
        }
    }

    var pair: ?[2]usize = null;
    for (0..n) |k| {
        if (quotes[k] == here.byte) {
            // On a quote: pair it by its position among the line's quotes.
            if (k % 2 == 0 and k + 1 < n) pair = .{ quotes[k], quotes[k + 1] };
            if (k % 2 == 1) pair = .{ quotes[k - 1], quotes[k] };
            break;
        }
    }
    if (pair == null) {
        var k: usize = 0;
        while (k + 1 < n) : (k += 2) {
            if (quotes[k + 1] > here.byte) {
                pair = .{ quotes[k], quotes[k + 1] };
                break;
            }
        }
    }
    const p = pair orelse return null;

    var start = p[0] + 1;
    var end = p[1];
    if (around) {
        start = p[0];
        end = p[1] + 1;
        if (end < s.len and isBlank(s[end])) {
            while (end < s.len and isBlank(s[end])) end += 1;
        } else {
            while (start > 0 and isBlank(s[start - 1])) start -= 1;
        }
    }
    const line_start = ed.buffer.lineStart(here.line);
    return .{ .chars = .{ .start = line_start + start, .end = line_start + end } };
}

/// i( a( and the other brackets: the text between the `count`th enclosing
/// pair, which may span lines and nest. a( includes the brackets. When the
/// brackets are on their own lines (a block), i( is the whole lines between.
fn bracketed(ed: *Editor, open_c: u8, close_c: u8, around: bool, count: usize) !?Range {
    const all = try ed.buffer.toOwnedSlice(ed.gpa);
    defer ed.gpa.free(all);
    if (all.len == 0) return null;

    var open: usize = undefined;
    var from = @min(ed.cursor, all.len - 1);
    for (0..count) |level| {
        // On a bracket of this kind, that's the innermost pair.
        if (level == 0 and all[from] == open_c) {
            open = from;
        } else {
            open = matchBackward(all, from, open_c, close_c) orelse return null;
        }
        from = open;
    }
    const close = matchForward(all, open, open_c, close_c) orelse return null;

    if (around) return .{ .chars = .{ .start = open, .end = close + 1 } };

    // A block: the opening bracket ends its line and the closing one starts
    // its line (after indentation). Then the inside is whole lines.
    var k = close;
    while (k > open and isBlank(all[k - 1])) k -= 1;
    if (open + 1 < all.len and all[open + 1] == '\n' and k > open and all[k - 1] == '\n') {
        const first = ed.buffer.lineOf(open) + 1;
        const last = ed.buffer.lineOf(close) - 1;
        if (first <= last) return .{ .lines = .{ .first = first, .last = last } };
        return .{ .chars = .{ .start = open + 1, .end = open + 1 } };
    }
    return .{ .chars = .{ .start = open + 1, .end = close } };
}

/// The unmatched opening bracket before `pos`.
fn matchBackward(all: []const u8, pos: usize, open_c: u8, close_c: u8) ?usize {
    var depth: usize = 0;
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (all[i] == close_c) {
            depth += 1;
        } else if (all[i] == open_c) {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    return null;
}

/// The bracket closing the one opened at `open`.
fn matchForward(all: []const u8, open: usize, open_c: u8, close_c: u8) ?usize {
    var depth: usize = 0;
    for (all[open + 1 ..], open + 1..) |c, i| {
        if (c == open_c) {
            depth += 1;
        } else if (c == close_c) {
            if (depth == 0) return i;
            depth -= 1;
        }
    }
    return null;
}

/// ip: the run of non-blank lines (or of blank lines) around the cursor.
/// ap: a paragraph plus the blank lines after it (or before it, if none
/// follow); on blank lines, the blanks plus the paragraph after them.
fn paragraph(ed: *Editor, around: bool) !?Range {
    const lines = ed.buffer.visibleLineCount();
    const line = ed.buffer.lineOf(ed.cursor);
    const blank = try isBlankLine(ed, line);

    var first = line;
    while (first > 0 and try isBlankLine(ed, first - 1) == blank) first -= 1;
    var last = line;
    while (last + 1 < lines and try isBlankLine(ed, last + 1) == blank) last += 1;

    if (around) {
        if (last + 1 < lines) {
            // The run after this one: blank lines after text, or text after blanks.
            const next_blank = !blank;
            while (last + 1 < lines and try isBlankLine(ed, last + 1) == next_blank) last += 1;
        } else if (!blank) {
            while (first > 0 and try isBlankLine(ed, first - 1)) first -= 1;
        }
    }
    return .{ .lines = .{ .first = first, .last = last } };
}

fn isBlankLine(ed: *Editor, line: usize) !bool {
    const s = try ed.lineText(line);
    return text.firstNonBlank(s) == s.len;
}

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const typeThenEscape = h.typeThenEscape;
const expectText = h.expectText;
const expectCursor = h.expectCursor;
const expectRegister = h.expectRegister;

test "iw and aw" {
    var e = try testEditor("one two.three  four\n");
    defer e.deinit();
    try typeKeys(&e, "wdiw");
    try expectText(&e, "one .three  four\n");
    try typeKeys(&e, "u");
    try typeKeys(&e, "daw"); // no blank after "two": the blank before it goes
    try expectText(&e, "one.three  four\n");
    try typeKeys(&e, "u0daw"); // the word and the blank after it
    try expectText(&e, "two.three  four\n");
    try typeKeys(&e, "u$daw"); // last word: the blanks before it instead
    try expectText(&e, "one two.three\n");
    try typeKeys(&e, "u0wwyiw"); // punctuation is its own word
    try expectRegister(&e, .char, ".");
    try typeKeys(&e, "0ffdiW"); // WORD: only blanks separate
    try expectText(&e, "one two.three  \n");
}

test "ciw and viw" {
    var e = try testEditor("say hello there\n");
    defer e.deinit();
    try typeKeys(&e, "wl");
    try typeThenEscape(&e, "ciwbye");
    try expectText(&e, "say bye there\n");
    try typeKeys(&e, "wviwy");
    try expectRegister(&e, .char, "there");
}

test "i\" and a\" on the cursor's line" {
    var e = try testEditor("x = \"a \\\"b\\\" c\" + 'q'\n");
    defer e.deinit();
    try typeKeys(&e, "fadi\"");
    try expectText(&e, "x = \"\" + 'q'\n");
    try typeKeys(&e, "u0di\""); // before the quotes: the next quoted text on the line
    try expectText(&e, "x = \"\" + 'q'\n");
    try typeKeys(&e, "u0da\""); // with the quotes and the blank after
    try expectText(&e, "x = + 'q'\n");
    try typeKeys(&e, "u$di'");
    try expectText(&e, "x = \"a \\\"b\\\" c\" + ''\n");
}

test "on a quote, it pairs by position on the line" {
    var e = try testEditor("\"one\" \"two\"\n");
    defer e.deinit();
    try typeKeys(&e, "f\";yi\""); // the 3rd quote opens "two"
    try expectRegister(&e, .char, "two");
    try typeKeys(&e, "0f\"yi\""); // the 2nd quote closes "one"
    try expectRegister(&e, .char, "one");
}

test "i( and a( with nesting, counts and every bracket kind" {
    var e = try testEditor("f(a, g(b), [c], {d}, <e>)\n");
    defer e.deinit();
    try typeKeys(&e, "fbyi(");
    try expectRegister(&e, .char, "b");
    try typeKeys(&e, "2yi(");
    try expectRegister(&e, .char, "a, g(b), [c], {d}, <e>");
    try typeKeys(&e, "fbya)"); // (the yank moved the cursor to its start)
    try expectRegister(&e, .char, "(b)");
    try typeKeys(&e, "fcyi]");
    try expectRegister(&e, .char, "c");
    try typeKeys(&e, "fdyiB");
    try expectRegister(&e, .char, "d");
    try typeKeys(&e, "feyi<");
    try expectRegister(&e, .char, "e");
    try typeKeys(&e, "0f(ci(");
    try typeThenEscape(&e, "x");
    try expectText(&e, "f(x)\n");
}

test "i( across lines, and nothing between empty brackets" {
    var e = try testEditor("call(1,\n  2) ()\n");
    defer e.deinit();
    try typeKeys(&e, "jdib");
    try expectText(&e, "call() ()\n");
    try typeKeys(&e, "$di("); // empty: nothing to delete
    try expectText(&e, "call() ()\n");
    try typeKeys(&e, "ci(");
    try typeThenEscape(&e, "z");
    try expectText(&e, "call() (z)\n");
}

test "i{ on a block selects the lines inside" {
    var e = try testEditor("fn main() {\n    one();\n    two();\n}\n");
    defer e.deinit();
    try typeKeys(&e, "jdi{");
    try expectText(&e, "fn main() {\n}\n");
    try typeKeys(&e, "u");
    try typeKeys(&e, "ci{");
    try typeThenEscape(&e, "body();"); // the indentation stays (autoindent)
    try expectText(&e, "fn main() {\n    body();\n}\n");
    try typeKeys(&e, "ya{");
    try expectRegister(&e, .char, "{\n    body();\n}");
}

test "ip and ap" {
    var e = try testEditor("a\nb\n\n\nc\nd\n");
    defer e.deinit();
    try typeKeys(&e, "yip");
    try expectRegister(&e, .line, "a\nb\n");
    try typeKeys(&e, "dap"); // with the blank lines after
    try expectText(&e, "c\nd\n");
    try typeKeys(&e, "u");
    try typeKeys(&e, "Gdap"); // last paragraph: the blank lines before it
    try expectText(&e, "a\nb\n");
}

test "visual mode selects objects" {
    var e = try testEditor("(one two)\nx\n");
    defer e.deinit();
    try typeKeys(&e, "lvi(y");
    try expectRegister(&e, .char, "one two");
    try typeKeys(&e, "vipy");
    try expectRegister(&e, .line, "(one two)\nx\n");
}

test "> with an object indents its lines, and . repeats an object command" {
    var e = try testEditor("a\nb\n\nc\n");
    defer e.deinit();
    try typeKeys(&e, ">ip");
    try expectText(&e, "\ta\n\tb\n\nc\n");
    try typeKeys(&e, "Gdiw");
    try typeKeys(&e, "gg.");
    try expectText(&e, "\t\n\tb\n\n\n");
}

test "outside an operator, i and a still enter insert mode" {
    var e = try testEditor("xy\n");
    defer e.deinit();
    try typeThenEscape(&e, "iw");
    try expectText(&e, "wxy\n");
    try typeThenEscape(&e, "ap");
    try expectText(&e, "wpxy\n");
    try expectCursor(&e, 0, 1);
}
