//! Visual mode: v, V and Ctrl-V selections, operators on them, and block
//! insert and paste.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("../Editor.zig");
const text = @import("../text.zig");
const nextChar = text.nextChar;
const displayCol = text.displayCol;
const byteAtCol = text.byteAtCol;
const motions = @import("motions.zig");
const operators = @import("operators.zig");
const insert = @import("insert.zig");

pub fn toggleVisual(ed: *Editor, kind: Editor.VisualKind) !void {
    if (ed.mode == .visual) {
        if (ed.visual_kind == kind) return leaveVisual(ed);
        ed.visual_kind = kind;
        return;
    }
    ed.mode = .visual;
    ed.visual_kind = kind;
    ed.visual_anchor = ed.cursor;
}

pub fn leaveVisual(ed: *Editor) !void {
    ed.mode = .normal;
    try ed.clampCursor();
}

/// An operator on the selection.
pub fn visualOperator(ed: *Editor, op: Editor.Op) !void {
    const a = @min(ed.visual_anchor, ed.cursor);
    const b = @max(ed.visual_anchor, ed.cursor);
    ed.mode = .normal;
    switch (ed.visual_kind) {
        .char => {
            if (op == .indent or op == .outdent) {
                return operators.operateLines(ed, op, ed.buffer.lineOf(a), ed.buffer.lineOf(b));
            }
            try operators.operateChars(ed, op, a, try operators.afterChar(ed, b));
        },
        .line => try operators.operateLines(ed, op, ed.buffer.lineOf(a), ed.buffer.lineOf(b)),
        .block => try blockOperator(ed, op),
    }
}

/// p in visual mode: replaces the selection with the register; the replaced
/// text goes into the register.
pub fn pasteOverSelection(ed: *Editor) Allocator.Error!void {
    if (ed.register.text.items.len == 0) return leaveVisual(ed);
    const saved_text = try ed.gpa.dupe(u8, ed.register.text.items);
    defer ed.gpa.free(saved_text);
    const saved_kind = ed.register.kind;
    const kind = ed.visual_kind;
    const start = @min(ed.visual_anchor, ed.cursor);
    const at_end = kind == .line and ed.buffer.lineOf(@max(ed.visual_anchor, ed.cursor)) + 1 >= ed.buffer.visibleLineCount();
    try visualOperator(ed, .delete);
    const replaced = try ed.gpa.dupe(u8, ed.register.text.items);
    defer ed.gpa.free(replaced);
    const replaced_kind = ed.register.kind;

    ed.register.text.clearRetainingCapacity();
    try ed.register.text.appendSlice(ed.gpa, saved_text);
    ed.register.kind = saved_kind;
    // Deleting up to the end of a line, or the last lines, leaves the cursor
    // before where the selection was, so the text goes after it.
    const after = if (kind == .line) at_end and saved_kind == .line else ed.cursor != start;
    try operators.paste(ed, !after, 1);

    ed.register.text.clearRetainingCapacity();
    try ed.register.text.appendSlice(ed.gpa, replaced);
    ed.register.kind = replaced_kind;
}

pub const Block = struct {
    first_line: usize,
    last_line: usize,
    start_col: usize,
    /// Exclusive; maxInt after $ (every line to its end).
    end_col: usize,
};

pub fn blockColumns(ed: *Editor) !struct { start: usize, end: usize } {
    const a = try ed.posOf(ed.visual_anchor);
    const c = try ed.posOf(ed.cursor);
    const end = if (ed.want_col == std.math.maxInt(usize))
        std.math.maxInt(usize)
    else
        @max(a.col + try ed.cellWidthAt(ed.visual_anchor), c.col + try ed.cellWidthAt(ed.cursor));
    return .{ .start = @min(a.col, c.col), .end = end };
}

pub fn currentBlock(ed: *Editor) !Block {
    const cols = try blockColumns(ed);
    const la = ed.buffer.lineOf(ed.visual_anchor);
    const lc = ed.buffer.lineOf(ed.cursor);
    return .{ .first_line = @min(la, lc), .last_line = @max(la, lc), .start_col = cols.start, .end_col = cols.end };
}

/// The bytes of line `s` inside the block's columns: every character that
/// overlaps them.
pub fn blockBytes(s: []const u8, block: Block) struct { start: usize, end: usize } {
    const start = byteAtCol(s, block.start_col);
    if (start >= s.len) return .{ .start = s.len, .end = s.len };
    const end = if (block.end_col == std.math.maxInt(usize)) s.len else nextChar(s, byteAtCol(s, block.end_col - 1));
    return .{ .start = start, .end = @max(start, end) };
}

pub fn blockOperator(ed: *Editor, op: Editor.Op) !void {
    const block = try currentBlock(ed);
    if (op == .indent or op == .outdent) return operators.operateLines(ed, op, block.first_line, block.last_line);

    // The register gets the rows of the rectangle.
    ed.register.text.clearRetainingCapacity();
    for (block.first_line..block.last_line + 1) |line| {
        const s = try ed.lineText(line);
        const r = blockBytes(s, block);
        if (line > block.first_line) try ed.register.text.append(ed.gpa, '\n');
        try ed.register.text.appendSlice(ed.gpa, s[r.start..r.end]);
    }
    ed.register.kind = .block;

    if (op != .yank) {
        // Bottom up, so earlier lines' offsets stay valid.
        var line = block.last_line + 1;
        while (line > block.first_line) {
            line -= 1;
            const s = try ed.lineText(line);
            const r = blockBytes(s, block);
            try ed.deleteBytes(ed.buffer.lineStart(line) + r.start, r.end - r.start);
        }
    } else {
        ed.clipboard_pending = true;
    }

    const s = try ed.lineText(block.first_line);
    ed.cursor = ed.buffer.lineStart(block.first_line) + byteAtCol(s, block.start_col);
    if (op == .change) {
        ed.block_insert = .{
            .first_line = block.first_line,
            .last_line = block.last_line,
            .col = block.start_col,
            .start = ed.cursor,
            .pad = false,
        };
        ed.mode = .insert;
        try ed.updateWantCol();
    } else {
        try ed.clampCursor();
    }
}

/// I and A on a block: type once, and on Escape the text is inserted on
/// every line of the block, at its left edge (I) or right edge (A).
pub fn blockInsert(ed: *Editor, append: bool) !void {
    if (ed.visual_kind != .block) return; // I and A only apply to blocks
    const block = try currentBlock(ed);
    const to_end = block.end_col == std.math.maxInt(usize);
    const col = if (append) block.end_col else block.start_col;
    ed.mode = .insert;

    const line_start = ed.buffer.lineStart(block.first_line);
    const s = try ed.lineText(block.first_line);
    if (append and to_end) {
        ed.cursor = line_start + s.len;
    } else if (append and displayCol(s, s.len) < col) {
        try ed.insertBytesPadding(block.first_line, col);
        ed.cursor = ed.lineEnd(block.first_line);
    } else {
        ed.cursor = line_start + byteAtCol(s, col);
    }
    ed.block_insert = .{
        .first_line = block.first_line,
        .last_line = block.last_line,
        .col = col,
        .start = ed.cursor,
        .pad = append,
        .to_end = append and to_end,
    };
    try ed.updateWantCol();
}

/// On leaving insert mode after a block I, A or c: copies what was typed on
/// the first line to the other lines of the block.
pub fn finishBlockInsert(ed: *Editor) !void {
    const b = ed.block_insert orelse return;
    ed.block_insert = null;
    if (ed.cursor <= b.start or ed.buffer.lineOf(ed.cursor) != b.first_line) return;
    const typed = try ed.gpa.alloc(u8, ed.cursor - b.start);
    defer ed.gpa.free(typed);
    ed.buffer.read(b.start, typed);
    if (std.mem.indexOfScalar(u8, typed, '\n') != null) return;

    for (b.first_line + 1..b.last_line + 1) |line| {
        const s = try ed.lineText(line);
        const width = displayCol(s, s.len);
        if (b.to_end) {
            try ed.insertBytes(ed.lineEnd(line), typed);
        } else if (!b.pad and width <= b.col) {
            // A line that doesn't reach into the block: I and c skip it.
            continue;
        } else if (b.pad and width < b.col) {
            // A pads a short line out to the block's edge.
            try ed.insertBytesPadding(line, b.col);
            try ed.insertBytes(ed.lineEnd(line), typed);
        } else {
            try ed.insertBytes(ed.buffer.lineStart(line) + byteAtCol(s, b.col), typed);
        }
    }
    ed.cursor = b.start;
}

/// O in a block: moves to the other corner on the same line.
pub fn swapBlockCorner(ed: *Editor) !void {
    if (ed.visual_kind != .block) {
        std.mem.swap(usize, &ed.visual_anchor, &ed.cursor);
        return ed.updateWantCol();
    }
    const a = try ed.posOf(ed.visual_anchor);
    const c = try ed.posOf(ed.cursor);
    const new_cursor = ed.buffer.lineStart(c.line) + byteAtCol(try ed.lineText(c.line), a.col);
    const new_anchor = ed.buffer.lineStart(a.line) + byteAtCol(try ed.lineText(a.line), c.col);
    ed.cursor = new_cursor;
    ed.visual_anchor = new_anchor;
    try ed.updateWantCol();
}

/// Pastes a block register as a rectangle at the cursor (p: after the
/// cursor's character), padding short lines and adding lines as needed.
pub fn pasteBlock(ed: *Editor, reg: []const u8, before: bool, n: usize) !void {
    const here = try ed.cursorPos();
    const empty_line = (try ed.lineText(here.line)).len == 0;
    const col = if (before or empty_line) here.col else here.col + try ed.cellWidthAt(ed.cursor);

    var width: usize = 0;
    var rows = std.mem.splitScalar(u8, reg, '\n');
    while (rows.next()) |row| width = @max(width, displayCol(row, row.len));

    var row_text: std.ArrayList(u8) = .empty;
    defer row_text.deinit(ed.gpa);
    rows = std.mem.splitScalar(u8, reg, '\n');
    var line = here.line;
    while (rows.next()) |row| : (line += 1) {
        if (line >= ed.buffer.visibleLineCount()) {
            if (!ed.endsWithNewline()) try ed.insertBytes(ed.buffer.len, "\n");
            try ed.insertBytes(ed.buffer.len, "\n");
        }
        const s = try ed.lineText(line);
        const at_end = displayCol(s, s.len) <= col;
        if (at_end) try ed.insertBytesPadding(line, col);

        // Rows are padded to the block's width unless nothing follows them.
        row_text.clearRetainingCapacity();
        for (0..n) |i| {
            try row_text.appendSlice(ed.gpa, row);
            const pad = width - displayCol(row, row.len);
            if (!at_end or i + 1 < n) try row_text.appendNTimes(ed.gpa, ' ', pad);
        }
        const s2 = try ed.lineText(line);
        try ed.insertBytes(ed.buffer.lineStart(line) + byteAtCol(s2, col), row_text.items);
    }
    ed.cursor = ed.buffer.lineStart(here.line) + byteAtCol(try ed.lineText(here.line), col);
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

test "visual mode: v selects characters, y d c act on them" {
    var e = try testEditor("hello world\n");
    defer e.deinit();
    try typeKeys(&e, "vey");
    try expectRegister(&e, .char, "hello");
    try testing.expectEqual(Editor.Mode.normal, e.mode);
    try typeKeys(&e, "wvlld");
    try expectText(&e, "hello ld\n");
    try typeThenEscape(&e, "0vecbye");
    try expectText(&e, "bye ld\n");
}

test "visual mode: o swaps ends, V selects lines, motions extend" {
    var e = try testEditor("1\n2\n3\n4\n");
    defer e.deinit();
    try typeKeys(&e, "jVjd");
    try expectText(&e, "1\n4\n");
    try expectRegister(&e, .line, "2\n3\n");
    try typeKeys(&e, "VGkoy"); // anchor and cursor swap; the selection is the same
    try expectRegister(&e, .line, "1\n4\n");
    try typeKeys(&e, "vjv"); // v again leaves visual mode
    try testing.expectEqual(Editor.Mode.normal, e.mode);
}

test "visual mode: p replaces the selection and > indents it" {
    var e = try testEditor("one two\n");
    defer e.deinit();
    try typeKeys(&e, "yewvep");
    try expectText(&e, "one one\n");
    try expectRegister(&e, .char, "two");
    try typeKeys(&e, "V>");
    try expectText(&e, "\tone one\n");
}

test "visual J and visual x on lines" {
    var e = try testEditor("a\nb\nc\nd\n");
    defer e.deinit();
    try typeKeys(&e, "VjjJ");
    try expectText(&e, "a b c\nd\n");
    try typeKeys(&e, "jvX");
    try expectText(&e, "a b c\n");
}

test "block selection: y and p paste a rectangle" {
    var e = try testEditor("abcd\nefgh\nijkl\n");
    defer e.deinit();
    try typeKeys(&e, "l\x16jly");
    try expectRegister(&e, .block, "bc\nfg");
    try expectCursor(&e, 0, 1);
    try typeKeys(&e, "$p");
    try expectText(&e, "abcdbc\nefghfg\nijkl\n");
    try typeKeys(&e, "u0P");
    try expectText(&e, "bcabcd\nfgefgh\nijkl\n");
}

test "block selection: d deletes the rectangle, $ extends to every line's end" {
    var e = try testEditor("abcd\nef\nijkl\n");
    defer e.deinit();
    try typeKeys(&e, "l\x16jjld");
    try expectText(&e, "ad\ne\nil\n");
    try expectRegister(&e, .block, "bc\nf\njk");
    try typeKeys(&e, "u0l\x16jj$d");
    try expectText(&e, "a\ne\ni\n");
}

test "block selection: I and A insert on every line" {
    var e = try testEditor("abc\nd\nefg\n");
    defer e.deinit();
    try typeKeys(&e, "l\x16jjI");
    try typeThenEscape(&e, "> ");
    try expectText(&e, "a> bc\nd\ne> fg\n"); // the short line is skipped
    try expectCursor(&e, 0, 1);
    try typeKeys(&e, "u");
    try expectText(&e, "abc\nd\nefg\n");
    try typeKeys(&e, "0l\x16jjA");
    try typeThenEscape(&e, "|");
    try expectText(&e, "ab|c\nd |\nef|g\n"); // A pads the short line
    try typeKeys(&e, "u0\x16jj$A");
    try typeThenEscape(&e, ";");
    try expectText(&e, "abc;\nd;\nefg;\n");
}

test "block selection: c changes every line, O moves to the other corner" {
    var e = try testEditor("abcd\nefgh\n");
    defer e.deinit();
    try typeKeys(&e, "l\x16jlO");
    try expectCursor(&e, 1, 1);
    try typeKeys(&e, "c");
    try typeThenEscape(&e, "XY");
    try expectText(&e, "aXYd\neXYh\n");
}

test "block paste past the last line adds lines" {
    var e = try testEditor("ab\ncd\nx\n");
    defer e.deinit();
    try typeKeys(&e, "\x16jy");
    try typeKeys(&e, "GP");
    try expectText(&e, "ab\ncd\nax\nc\n");
}
