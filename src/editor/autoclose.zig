//! The autoclose setting: brackets and quotes typed in insert mode come in
//! pairs, with the cursor between.
//!
//!     (  [  {  "  '    insert the pair, if what follows is a blank, the end
//!                      of the line or a closing bracket
//!     )  ]  }  "  '    step over the same character if it's next
//!     Backspace        between an empty pair, deletes both
//!     Enter            between a pair, puts the closer on its own line:
//!
//!                          int main(void) {
//!                              |
//!                          }

const std = @import("std");
const Editor = @import("../Editor.zig");
const operators = @import("operators.zig");

fn closerOf(c: u8) ?u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        '\'' => '\'',
        else => null,
    };
}

fn isCloser(c: u8) bool {
    return c == ')' or c == ']' or c == '}';
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// The bytes before and after the cursor on its line.
fn around(ed: *Editor) !struct { before: []const u8, after: []const u8 } {
    const p = ed.toPos(ed.cursor);
    const s = try ed.lineText(p.line);
    return .{ .before = s[0..p.byte], .after = s[p.byte..] };
}

fn active(ed: *const Editor) bool {
    return ed.settings.autoclose and ed.block_insert == null;
}

/// Typing `c`. Returns false if autoclose has nothing to do with it.
pub fn typed(ed: *Editor, char: u21) !bool {
    if (!active(ed) or char > 0x7f) return false;
    const c: u8 = @intCast(char);
    const a = try around(ed);
    const next: ?u8 = if (a.after.len > 0) a.after[0] else null;
    const prev: ?u8 = if (a.before.len > 0) a.before[a.before.len - 1] else null;
    const quote = c == '"' or c == '\'';

    // A closer that's already there: step over it.
    if ((isCloser(c) or quote) and next == c) {
        ed.cursor += 1;
        try ed.updateWantCol();
        return true;
    }
    const closer = closerOf(c) orelse return false;
    const room = next == null or next.? == ' ' or next.? == '\t' or isCloser(next.?);
    if (!room) return false;
    // A quote after a word is an apostrophe (don't) or ends something.
    if (quote and prev != null and isWordChar(prev.?)) return false;
    try ed.insertAtCursor(&.{ c, closer });
    ed.cursor -= 1;
    try ed.updateWantCol();
    return true;
}

/// Whether the cursor is between an empty pair, like (|).
fn betweenPair(ed: *Editor) !bool {
    const a = try around(ed);
    if (a.before.len == 0 or a.after.len == 0) return false;
    const closer = closerOf(a.before[a.before.len - 1]) orelse return false;
    return a.after[0] == closer;
}

/// Backspace. Returns false if autoclose has nothing to do with it.
pub fn backspace(ed: *Editor) !bool {
    if (!active(ed) or !try betweenPair(ed)) return false;
    ed.cursor -= 1;
    try ed.deleteBytes(ed.cursor, 2);
    try ed.updateWantCol();
    return true;
}

/// Enter. Returns false if autoclose has nothing to do with it.
pub fn enter(ed: *Editor) !bool {
    if (!active(ed) or !try betweenPair(ed)) return false;
    const a = try around(ed);
    const c = a.before[a.before.len - 1];
    if (c == '"' or c == '\'') return false;

    var buf: [256]u8 = undefined;
    const indent = try ed.indentOf(ed.toPos(ed.cursor).line, std.math.maxInt(usize), &buf);
    try ed.insertAtCursor("\n");
    try ed.insertAtCursor(indent);
    try ed.insertAtCursor(operators.indentUnit(ed));
    const inside = ed.cursor;
    try ed.insertAtCursor("\n");
    try ed.insertAtCursor(indent);
    ed.cursor = inside;
    try ed.updateWantCol();
    // Left without typing anything, the inner line drops its blanks.
    ed.autoindent_at = inside;
    return true;
}

const testing = std.testing;
const h = @import("testing.zig");

fn testEditor(content: []const u8) !Editor {
    var e = try h.testEditor(content);
    e.settings.autoclose = true;
    return e;
}

test "brackets and quotes come in pairs, and closers are stepped over" {
    var e = try testEditor("");
    defer e.deinit();
    try h.typeThenEscape(&e, "iif (a[0] == \"x\") {}");
    try h.expectText(&e, "if (a[0] == \"x\") {}");
    try h.typeThenEscape(&e, "ofoo(bar(");
    try h.expectText(&e, "if (a[0] == \"x\") {}\nfoo(bar())\n");
}

test "no pair before a word, and no quote pair after one" {
    var e = try testEditor("word\n");
    defer e.deinit();
    try h.typeThenEscape(&e, "i(");
    try h.expectText(&e, "(word\n");
    try h.typeThenEscape(&e, "o'don't' \"it's\"");
    try h.expectText(&e, "(word\n'don't' \"it's\"\n");
}

test "Backspace in an empty pair deletes both" {
    var e = try testEditor("");
    defer e.deinit();
    try h.typeThenEscape(&e, "a([\"\x7f\x7f\x7fx");
    try h.expectText(&e, "x");
}

test "Enter between braces puts the closer on its own line, the cursor indented" {
    var e = try testEditor("");
    defer e.deinit();
    try h.typeKeys(&e, "iint main(void) {\rreturn 0;");
    try h.expectText(&e, "int main(void) {\n\treturn 0;\n}");
    _ = try e.handleKey(.escape);
    try h.typeKeys(&e, "u");
    try h.expectText(&e, "");

    // Nested, with spaces; leaving the inner line empty leaves no blanks.
    e.settings.expandtab = true;
    try h.typeThenEscape(&e, "i    if (x) {\r");
    try h.expectText(&e, "    if (x) {\n\n    }");
}

test "off: nothing is added" {
    var e = try h.testEditor("");
    defer e.deinit();
    try h.typeThenEscape(&e, "i(\"{\r");
    try h.expectText(&e, "(\"{\n\n");
}

test "block insert types plainly" {
    var e = try testEditor("ab\nab\n");
    defer e.deinit();
    try h.typeThenEscape(&e, "\x16jI(");
    try h.expectText(&e, "(ab\n(ab\n");
}

test ". repeats an insert with pairs" {
    var e = try testEditor("x\ny\n");
    defer e.deinit();
    try h.typeThenEscape(&e, "A(1");
    try h.typeKeys(&e, "j.");
    try h.expectText(&e, "x(1)\ny(1)\n");
}
