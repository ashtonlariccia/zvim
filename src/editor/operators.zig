//! Operators on ranges and lines (d, y, c, >, <), the register, p/P, J and r.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("../Editor.zig");
const Key = @import("../keys.zig").Key;
const text = @import("../text.zig");
const nextChar = text.nextChar;
const firstNonBlank = text.firstNonBlank;
const normal = @import("normal.zig");
const motions = @import("motions.zig");
const visual = @import("visual.zig");

pub fn applyOperator(ed: *Editor, op: Editor.Op, target: motions.Target) !void {
    const a = @min(ed.cursor, target.pos);
    var b = @max(ed.cursor, target.pos);
    if (target.kind == .linewise or op == .indent or op == .outdent) {
        return operateLines(ed, op, ed.buffer.lineOf(a), ed.buffer.lineOf(b));
    }
    switch (target.kind) {
        .inclusive => b = try afterChar(ed, b),
        .exclusive => {
            // Ending at the very start of a later line stops at the end of
            // the line before it, so the line break isn't included.
            const lb = ed.buffer.lineOf(b);
            if (b > a and lb > ed.buffer.lineOf(a) and b == ed.buffer.lineStart(lb)) {
                b = ed.lineEnd(lb - 1);
            }
        },
        .linewise => unreachable,
    }
    try operateChars(ed, op, a, b);
}

/// Offset just past the character at `offset` (past the newline at a line end).
pub fn afterChar(ed: *Editor, offset: usize) !usize {
    if (offset >= ed.buffer.len) return ed.buffer.len;
    const p = ed.toPos(offset);
    const s = try ed.lineText(p.line);
    if (p.byte < s.len) return offset + nextChar(s, p.byte) - p.byte;
    return offset + 1;
}

/// Applies `op` to the bytes [a, b).
pub fn operateChars(ed: *Editor, op: Editor.Op, a: usize, b: usize) !void {
    try setRegister(ed, .char, a, b);
    switch (op) {
        .yank => {
            try ed.yanked();
            ed.cursor = a;
            try ed.clampCursor();
        },
        .delete => {
            try ed.deleteBytes(a, b - a);
            ed.cursor = a;
            try ed.clampCursor();
        },
        .change => {
            try ed.deleteBytes(a, b - a);
            ed.cursor = a;
            ed.mode = .insert;
            try ed.updateWantCol();
        },
        .indent, .outdent => unreachable,
    }
}

/// Applies `op` to whole lines `first` through `last` (clamped to the text).
pub fn operateLines(ed: *Editor, op: Editor.Op, first: usize, last_wanted: usize) !void {
    const lines = ed.buffer.visibleLineCount();
    const last = @min(last_wanted, lines - 1);
    const n = last - first + 1;
    const start = ed.buffer.lineStart(first);
    const end = if (last + 1 < lines) ed.buffer.lineStart(last + 1) else ed.buffer.len;
    switch (op) {
        .yank => {
            try setLineRegister(ed, start, end);
            try ed.yanked();
            if (ed.buffer.lineOf(ed.cursor) != first) {
                const s = try ed.lineText(first);
                ed.cursor = start + ed.wantByte(s);
            }
            if (n > 2) ed.setMessage(false, "{d} lines yanked", .{n});
        },
        .delete => {
            try setLineRegister(ed, start, end);
            try ed.deleteLines(start, end - start);
            ed.cursor = try ed.firstNonBlankOf(@min(first, ed.buffer.visibleLineCount() - 1));
            try ed.clampCursor();
            if (n > 2) ed.setMessage(false, "{d} fewer lines", .{n});
        },
        .change => {
            // Like Vim with autoindent, the first line's indentation stays.
            try setLineRegister(ed, start, end);
            const indent = if (ed.settings.autoindent) firstNonBlank(try ed.lineText(first)) else 0;
            try ed.deleteBytes(start + indent, ed.lineEnd(last) - start - indent);
            ed.cursor = start + indent;
            ed.autoindent_at = if (indent > 0) ed.cursor else null;
            ed.mode = .insert;
            try ed.updateWantCol();
        },
        .indent, .outdent => {
            for (first..last + 1) |line| {
                const s = try ed.lineText(line);
                const line_start = ed.buffer.lineStart(line);
                if (op == .indent) {
                    if (s.len > 0) try ed.insertBytes(line_start, indentUnit(ed));
                } else {
                    var k: usize = 0;
                    if (s.len > 0 and s[0] == '\t') {
                        k = 1;
                    } else while (k < s.len and k < indentUnitWidth(ed) and s[k] == ' ') k += 1;
                    try ed.deleteBytes(line_start, k);
                }
            }
            ed.cursor = try ed.firstNonBlankOf(first);
            try ed.clampCursor();
            if (n > 2) ed.setMessage(false, "{d} lines {s}ed 1 time", .{ n, if (op == .indent) ">" else "<" });
        },
    }
}

/// One level of indentation: a tab, or `shiftwidth` spaces with `expandtab`.
pub fn indentUnit(ed: *const Editor) []const u8 {
    return if (ed.settings.expandtab) Editor.blanks[0..ed.settings.shiftwidth] else "\t";
}

fn indentUnitWidth(ed: *const Editor) usize {
    return if (ed.settings.expandtab) ed.settings.shiftwidth else text.tab_width;
}

pub fn setRegister(ed: *Editor, kind: @FieldType(Editor.Register, "kind"), a: usize, b: usize) !void {
    try ed.register.text.resize(ed.gpa, b - a);
    ed.buffer.read(a, ed.register.text.items);
    ed.register.kind = kind;
}

/// Puts lines [start, end) in the register, making sure they end in a newline.
pub fn setLineRegister(ed: *Editor, start: usize, end: usize) !void {
    try setRegister(ed, .line, start, end);
    const t = ed.register.text.items;
    if (t.len == 0 or t[t.len - 1] != '\n') try ed.register.text.append(ed.gpa, '\n');
}

/// p and P: pastes the register `n` times after or before the cursor (or,
/// for lines, below or above the cursor's line).
pub fn paste(ed: *Editor, before: bool, n: usize) Allocator.Error!void {
    if (ed.mode == .visual) return visual.pasteOverSelection(ed);
    if (ed.register.text.items.len == 0) return;
    const reg = try ed.gpa.dupe(u8, ed.register.text.items);
    defer ed.gpa.free(reg);
    switch (ed.register.kind) {
        .char => {
            const p = ed.toPos(ed.cursor);
            const s = try ed.lineText(p.line);
            const pos = if (before or s.len == 0) ed.cursor else ed.cursor + nextChar(s, p.byte) - p.byte;
            ed.cursor = pos;
            for (0..n) |_| try ed.insertAtCursor(reg);
            // On the last pasted character; at the start of multi-line text.
            if (std.mem.indexOfScalar(u8, reg, '\n') != null) {
                ed.cursor = pos;
            } else {
                ed.cursor -= reg.len - text.prevStart(reg, reg.len);
            }
            try ed.clampCursor();
        },
        .line => {
            const line = ed.buffer.lineOf(ed.cursor);
            const lines = ed.buffer.visibleLineCount();
            var first_new = line;
            if (before) {
                const pos = ed.buffer.lineStart(line);
                for (0..n) |_| try ed.insertBytes(pos, reg);
            } else if (line + 1 < lines) {
                const pos = ed.buffer.lineStart(line + 1);
                for (0..n) |_| try ed.insertBytes(pos, reg);
                first_new = line + 1;
            } else {
                // Below the last line: make sure it ends in a newline first.
                if (!ed.endsWithNewline()) try ed.insertBytes(ed.buffer.len, "\n");
                for (0..n) |_| try ed.insertBytes(ed.buffer.len, reg);
                first_new = line + 1;
            }
            ed.cursor = try ed.firstNonBlankOf(first_new);
            try ed.clampCursor();
            const added = n * std.mem.count(u8, reg, "\n");
            if (added > 2) ed.setMessage(false, "{d} more lines", .{added});
        },
        .block => try visual.pasteBlock(ed, reg, before, n),
    }
}

/// J: joins `n` lines (at least two) into one, with a space between where
/// needed and the next line's indent removed.
pub fn joinLines(ed: *Editor, n_wanted: usize) !void {
    var first = ed.buffer.lineOf(ed.cursor);
    var n = @max(n_wanted, 2);
    if (ed.mode == .visual) {
        const a = ed.buffer.lineOf(@min(ed.visual_anchor, ed.cursor));
        const b = ed.buffer.lineOf(@max(ed.visual_anchor, ed.cursor));
        first = a;
        n = @max(b - a + 1, 2);
        ed.mode = .normal;
    }
    const lines = ed.buffer.visibleLineCount();
    if (first + 1 >= lines) return;
    const joins = @min(n - 1, lines - 1 - first);
    var join_at: usize = 0;
    for (0..joins) |_| {
        const cur = try ed.gpa.dupe(u8, try ed.lineText(first));
        defer ed.gpa.free(cur);
        const next = try ed.lineText(first + 1);
        const indent = firstNonBlank(next);
        const rest_empty = indent == next.len;
        const needs_space = !rest_empty and cur.len > 0 and
            !text.isBlank(cur[cur.len - 1]) and next[indent] != ')';
        join_at = ed.lineEnd(first);
        try ed.deleteBytes(join_at, 1 + indent);
        if (needs_space) try ed.insertBytes(join_at, " ");
    }
    ed.cursor = join_at;
    try ed.clampCursor();
}

/// r: replaces [count] characters under the cursor with the typed one.
/// r Enter replaces them with a single line break.
pub fn replaceChars(ed: *Editor, key: Key) !void {
    const n = @max(ed.pending.count, 1);
    ed.pending = .{};
    const c: u21 = if (key == .enter) '\n' else normal.keyChar(key) orelse return;
    if (ed.mode == .visual) return; // not supported on a selection
    const p = ed.toPos(ed.cursor);
    const s = try ed.lineText(p.line);
    var end = p.byte;
    for (0..n) |_| {
        if (end >= s.len) return;
        end = nextChar(s, end);
    }
    try ed.deleteBytes(ed.cursor, end - p.byte);
    if (c == '\n') {
        try ed.insertBytes(ed.cursor, "\n");
        ed.cursor += 1;
    } else {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &bytes) catch return;
        for (0..n) |_| try ed.insertBytes(ed.cursor, bytes[0..len]);
        ed.cursor += (n - 1) * len;
    }
    try ed.clampCursor();
}

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const typeThenEscape = h.typeThenEscape;
const expectCursor = h.expectCursor;
const expectText = h.expectText;
const expectRegister = h.expectRegister;

test "x deletes the character under the cursor and stays on the line" {
    var e = try testEditor("abc\n\nz\n");
    defer e.deinit();
    try typeKeys(&e, "$x");
    try expectText(&e, "ab\n\nz\n");
    try expectCursor(&e, 0, 1); // back onto the new last character
    try typeKeys(&e, "xxx");
    try expectText(&e, "\n\nz\n");
    try typeKeys(&e, "jx"); // nothing to delete on an empty line
    try expectText(&e, "\n\nz\n");
}

test "dw, de, db, d$, d0 and counts" {
    var e = try testEditor("one two three four\n");
    defer e.deinit();
    try typeKeys(&e, "dw");
    try expectText(&e, "two three four\n");
    try expectRegister(&e, .char, "one ");
    try typeKeys(&e, "de");
    try expectText(&e, " three four\n");
    try typeKeys(&e, "w2dw");
    try expectText(&e, " \n");
    try typeKeys(&e, "u$db");
    try expectText(&e, " three r\n"); // db from the last character keeps that character
    try typeKeys(&e, "u0wd$");
    try expectText(&e, " \n");
    try typeKeys(&e, "u$d0");
    try expectText(&e, "r\n");
}

test "dw on the last word of a line doesn't join the next line" {
    var e = try testEditor("foo bar\n  baz\n");
    defer e.deinit();
    try typeKeys(&e, "wdw");
    try expectText(&e, "foo \n  baz\n");
}

test "cw changes to the end of the word, cc changes the line" {
    var e = try testEditor("hello world\nsecond\n");
    defer e.deinit();
    try typeThenEscape(&e, "cwhi");
    try expectText(&e, "hi world\nsecond\n");
    try typeThenEscape(&e, "jccnew");
    try expectText(&e, "hi world\nnew\n");
    try expectRegister(&e, .line, "second\n");
    try typeThenEscape(&e, "k$cwD"); // on a word's last character: just that character
    try expectText(&e, "hi worlD\nnew\n");
}

test "dd, yy, p and P with lines" {
    var e = try testEditor("1\n2\n3\n4\n");
    defer e.deinit();
    try typeKeys(&e, "dd");
    try expectText(&e, "2\n3\n4\n");
    try expectRegister(&e, .line, "1\n");
    try typeKeys(&e, "p");
    try expectText(&e, "2\n1\n3\n4\n");
    try expectCursor(&e, 1, 0);
    try typeKeys(&e, "2yyGp");
    try expectText(&e, "2\n1\n3\n4\n1\n3\n");
    try typeKeys(&e, "ggP");
    try expectText(&e, "1\n3\n2\n1\n3\n4\n1\n3\n");
    try typeKeys(&e, "G3dd"); // more than remain: deletes to the end
    try expectText(&e, "1\n3\n2\n1\n3\n4\n1\n");
    try expectCursor(&e, 6, 0);
}

test "paste lines below a last line without a final newline" {
    var e = try testEditor("a\nb");
    defer e.deinit();
    try typeKeys(&e, "yyjp");
    try expectText(&e, "a\nb\na\n");
    try expectCursor(&e, 2, 0);
}

test "dd on the only line leaves an empty buffer" {
    var e = try testEditor("only\n");
    defer e.deinit();
    try typeKeys(&e, "dd");
    try expectText(&e, "");
    try typeKeys(&e, "p");
    try expectText(&e, "\nonly\n");
}

test "x, X, s, D, C, S and Y" {
    var e = try testEditor("abcdef\n");
    defer e.deinit();
    try typeKeys(&e, "2x");
    try expectText(&e, "cdef\n");
    try expectRegister(&e, .char, "ab");
    try typeKeys(&e, "$X");
    try expectText(&e, "cdf\n");
    try typeThenEscape(&e, "0sZ");
    try expectText(&e, "Zdf\n");
    try typeKeys(&e, "lD");
    try expectText(&e, "Z\n");
    try typeThenEscape(&e, "C!");
    try expectText(&e, "!\n");
    try typeKeys(&e, "Yp");
    try expectText(&e, "!\n!\n");
    try typeThenEscape(&e, "Snew");
    try expectText(&e, "!\nnew\n");
}

test "character paste: p after the cursor, P before, with a count" {
    var e = try testEditor("ab\n");
    defer e.deinit();
    try typeKeys(&e, "ylp");
    try expectText(&e, "aab\n");
    try expectCursor(&e, 0, 1);
    try typeKeys(&e, "$3P");
    try expectText(&e, "aaaaab\n");
    try expectCursor(&e, 0, 4);
}

test "J joins lines" {
    var e = try testEditor("one\n   two\n)\n\nlast\n");
    defer e.deinit();
    try typeKeys(&e, "J");
    try expectText(&e, "one two\n)\n\nlast\n");
    try expectCursor(&e, 0, 3);
    try typeKeys(&e, "J");
    try expectText(&e, "one two)\n\nlast\n");
    try typeKeys(&e, "3J");
    try expectText(&e, "one two) last\n");
    try typeKeys(&e, "J"); // nothing to join
    try expectText(&e, "one two) last\n");
}

test "r replaces characters" {
    var e = try testEditor("abcd\n");
    defer e.deinit();
    try typeKeys(&e, "rx");
    try expectText(&e, "xbcd\n");
    try typeKeys(&e, "l2ré");
    try expectText(&e, "xééd\n");
    try expectCursor(&e, 0, 3);
    try typeKeys(&e, "5rz"); // not enough characters: nothing
    try expectText(&e, "xééd\n");
    try typeKeys(&e, "0r\r");
    try expectText(&e, "\nééd\n");
}

test "> and < indent and outdent lines" {
    var e = try testEditor("a\n\nb\n");
    defer e.deinit();
    try typeKeys(&e, ">2j");
    try expectText(&e, "\ta\n\n\tb\n"); // empty lines stay empty
    try typeKeys(&e, "<<");
    try expectText(&e, "a\n\n\tb\n");
    try typeKeys(&e, "G>>>>");
    try expectText(&e, "a\n\n\t\t\tb\n");
}

test "emptying the last line of text without a final newline keeps the line" {
    var e = try testEditor("x\nlast");
    defer e.deinit();
    try typeKeys(&e, "jS");
    try expectCursor(&e, 1, 0);
    try typeThenEscape(&e, "new");
    try expectText(&e, "x\nnew\n");
    try typeKeys(&e, "u");
    try expectText(&e, "x\nlast");

    try typeKeys(&e, "jd$"); // a character delete of the whole line
    try testing.expectEqual(@as(usize, 2), e.buffer.visibleLineCount());
    try typeKeys(&e, "u");
    try typeKeys(&e, "jdd"); // a line delete removes it
    try expectText(&e, "x\n");
}

test "a count past the last word end changes only up to it" {
    var e = try testEditor("one\n\ntwo three\n");
    defer e.deinit();
    try typeKeys(&e, "G3cw");
    try typeThenEscape(&e, "x");
    try expectText(&e, "one\n\nx\n");
}

test "the clipboard gets the yanked text even if a later key changes the register" {
    var e = try testEditor("keep\ndrop\n");
    defer e.deinit();
    try typeKeys(&e, "yyjdd"); // as if typed faster than the screen redraws
    try testing.expect(e.clipboard_pending);
    try testing.expectEqualStrings("keep\n", e.clipboard.items);
    try expectRegister(&e, .line, "drop\n");
}
