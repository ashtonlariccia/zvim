//! Insert mode keys, and text pasted into the terminal.

const std = @import("std");
const Editor = @import("../Editor.zig");
const Key = @import("../keys.zig").Key;
const text = @import("../text.zig");
const nextChar = text.nextChar;
const prevChar = text.prevChar;
const normal = @import("normal.zig");
const motions = @import("motions.zig");
const visual = @import("visual.zig");

/// Text pasted into the terminal: inserted at the cursor in insert mode,
/// before the cursor in normal and visual mode (as one undo step), and onto
/// the command line up to its first line break.
pub fn pasteText(ed: *Editor, raw: []const u8) !void {
    // Terminals send line breaks as \r; normalize \r\n and \r to \n.
    var pasted: std.ArrayList(u8) = .empty;
    defer pasted.deinit(ed.gpa);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\r') {
            try pasted.append(ed.gpa, '\n');
            if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1;
        } else try pasted.append(ed.gpa, raw[i]);
    }
    if (pasted.items.len == 0) return;

    switch (ed.mode) {
        .insert => try ed.insertAtCursor(pasted.items),
        .command => {
            const line_end = std.mem.indexOfScalar(u8, pasted.items, '\n') orelse pasted.items.len;
            try ed.command.appendSlice(ed.gpa, pasted.items[0..line_end]);
        },
        .normal, .visual => {
            ed.pending = .{};
            ed.mode = .insert;
            try ed.insertAtCursor(pasted.items);
            ed.mode = .normal;
            // On the last pasted character, like leaving insert mode.
            const p = ed.toPos(ed.cursor);
            if (p.byte > 0) ed.cursor -= p.byte - prevChar(try ed.lineText(p.line), p.byte);
            try ed.clampCursor();
        },
    }
}

pub fn insertKey(ed: *Editor, key: Key) !void {
    switch (key) {
        .char => |c| {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &bytes) catch return;
            try ed.insertAtCursor(bytes[0..n]);
        },
        .enter => try ed.insertAtCursor("\n"),
        .tab => try ed.insertAtCursor("\t"),
        .backspace => try deleteBeforeCursor(ed),
        .delete => try deleteUnderCursor(ed),
        .escape => {
            if (ed.block_insert != null) {
                // The cursor goes back to the block's top-left corner.
                try visual.finishBlockInsert(ed);
            } else {
                // Like Vim, leaving insert mode steps back onto the last typed character.
                const p = ed.toPos(ed.cursor);
                if (p.byte > 0) ed.cursor -= p.byte - prevChar(try ed.lineText(p.line), p.byte);
            }
            ed.mode = .normal;
            try ed.clampCursor();
        },
        else => if (motions.motionFor(key)) |m| {
            if (m == .left or m == .right or m == .down or m == .up or m == .line_start or m == .line_end) {
                if (try motions.motionTarget(ed, m, 1, false, null)) |target| try motions.moveTo(ed, target);
            }
        },
    }
}

/// Deletes the character under the cursor. In insert mode at the end of a
/// line, joins the next line onto this one instead.
pub fn deleteUnderCursor(ed: *Editor) !void {
    const pos = try ed.cursorPos();
    const s = try ed.lineText(pos.line);
    if (pos.byte < s.len) {
        try ed.deleteBytes(ed.cursor, nextChar(s, pos.byte) - pos.byte);
    } else if (pos.line + 1 < ed.buffer.visibleLineCount()) {
        try ed.deleteBytes(ed.cursor, 1);
    } else return;
    try ed.clampCursor();
}

/// Deletes the character before the cursor, or at the start of a line joins
/// it onto the previous one.
pub fn deleteBeforeCursor(ed: *Editor) !void {
    const pos = try ed.cursorPos();
    if (pos.byte > 0) {
        const s = try ed.lineText(pos.line);
        const n = pos.byte - prevChar(s, pos.byte);
        ed.cursor -= n;
        try ed.deleteBytes(ed.cursor, n);
    } else if (pos.line > 0) {
        ed.cursor -= 1;
        try ed.deleteBytes(ed.cursor, 1);
    } else return;
    try ed.updateWantCol();
}

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const typeThenEscape = h.typeThenEscape;
const expectCursor = h.expectCursor;
const expectText = h.expectText;

test "i inserts before the cursor; Escape steps back onto the last typed character" {
    var e = try testEditor("world\n");
    defer e.deinit();
    try typeThenEscape(&e, "ihello ");
    try expectText(&e, "hello world\n");
    try expectCursor(&e, 0, 5);
    try testing.expect(e.isModified());
    try testing.expectEqual(Editor.Mode.normal, e.mode);
}

test "a appends after the cursor, A at the end of the line, I at the first non-blank" {
    var e = try testEditor("  ac\n");
    defer e.deinit();
    try typeThenEscape(&e, "llab"); // cursor on 'a', append 'b' after it
    try expectText(&e, "  abc\n");
    try typeThenEscape(&e, "A!");
    try expectText(&e, "  abc!\n");
    try typeThenEscape(&e, "I>");
    try expectText(&e, "  >abc!\n");
    try expectCursor(&e, 0, 2);
}

test "Enter splits the line, Backspace joins it back" {
    var e = try testEditor("abcd\n");
    defer e.deinit();
    try typeKeys(&e, "lli\r");
    try expectText(&e, "ab\ncd\n");
    try expectCursor(&e, 1, 0);
    try typeKeys(&e, "\x7f");
    try expectText(&e, "abcd\n");
    try expectCursor(&e, 0, 2);
    try typeKeys(&e, "\x7f\x7f\x7f"); // a third Backspace at the start of the file does nothing
    try expectText(&e, "cd\n");
}

test "o and O open lines below and above" {
    var e = try testEditor("one\ntwo\n");
    defer e.deinit();
    try typeThenEscape(&e, "oone and a half");
    try expectText(&e, "one\none and a half\ntwo\n");
    try typeThenEscape(&e, "Gkk"); // (G does nothing yet) move to line 0
    try typeThenEscape(&e, "Ozero");
    try expectText(&e, "zero\none\none and a half\ntwo\n");
    try expectCursor(&e, 0, 3);
}

test "o on the last line of text without a final newline makes a real line" {
    var e = try testEditor("abc");
    defer e.deinit();
    try typeKeys(&e, "o");
    try expectCursor(&e, 1, 0);
    try testing.expectEqual(@as(usize, 2), e.buffer.visibleLineCount());
    try typeThenEscape(&e, "d");
    try expectText(&e, "abc\nd\n");
}

test "typing into an empty buffer and pressing Enter at the end" {
    var e = try testEditor("");
    defer e.deinit();
    try typeKeys(&e, "ihi\rthere");
    try expectText(&e, "hi\nthere\n");
    try expectCursor(&e, 1, 5);
}

test "Delete in insert mode joins the next line, but not past the last line" {
    var e = try testEditor("ab\ncd\n");
    defer e.deinit();
    try typeKeys(&e, "A\x1b[3~");
    try expectText(&e, "abcd\n");
    // Deletes "c" and "d", then stops: the final newline isn't a line to join.
    try typeKeys(&e, "\x1b[3~\x1b[3~\x1b[3~");
    try expectText(&e, "ab\n");
}

test "multibyte characters are typed and deleted whole" {
    var e = try testEditor("e\u{301}\n");
    defer e.deinit();
    try typeKeys(&e, "x");
    try expectText(&e, "\n");
    try typeKeys(&e, "i中é");
    try expectText(&e, "中é\n");
    try typeKeys(&e, "\x7f");
    try expectText(&e, "中\n");
    try typeKeys(&e, "\t");
    try expectText(&e, "中\t\n");
    try testing.expectEqual(@as(usize, 8), (try e.cursorPos()).col);
}

test "in insert mode the cursor can sit after the last character" {
    var e = try testEditor("ab\nlonger\n");
    defer e.deinit();
    try typeKeys(&e, "jAx");
    try expectCursor(&e, 1, 7);
    try typeKeys(&e, "\x1b[A"); // up: past the end of "ab"
    try expectCursor(&e, 0, 2);
    _ = try e.handleKey(.escape);
    try expectCursor(&e, 0, 1);
}

test "pasted text is inserted literally in every mode" {
    var e = try testEditor("ab\n");
    defer e.deinit();
    _ = try e.handleKey(.{ .paste = "dd:q\r\nx" }); // normal mode: not run as commands
    try expectText(&e, "dd:q\nxab\n");
    try expectCursor(&e, 1, 0);
    try typeKeys(&e, "u");
    try expectText(&e, "ab\n"); // one undo step

    try typeKeys(&e, "A");
    _ = try e.handleKey(.{ .paste = "\tz" });
    try typeKeys(&e, "!");
    try expectText(&e, "ab\tz!\n");

    _ = try e.handleKey(.escape);
    try typeKeys(&e, ":");
    _ = try e.handleKey(.{ .paste = "w name\rignored" });
    try testing.expectEqualStrings("w name", e.command.items);
}
