//! Editor state and key handling, with no terminal or file I/O: keys go in,
//! the buffer, cursor and view change.
//!
//! Lines are what the user sees: a newline at the very end of the text ends
//! the last line rather than starting another (see `Buffer.visibleLineCount`).
//! The cursor moves by characters, where a character includes any combining
//! marks that follow it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");
const Key = @import("keys.zig").Key;
const text = @import("text.zig");

const Editor = @This();

gpa: Allocator,
buffer: Buffer,
/// Byte offset of the cursor in the buffer.
cursor: usize = 0,
/// Display column that up/down movement aims for, kept across short lines.
want_col: usize = 0,
mode: Mode = .normal,
/// First visible line and display column.
top: usize = 0,
left: usize = 0,
/// Scratch copy of the cursor's line.
line_buf: std.ArrayList(u8) = .empty,

pub const Mode = enum { normal, insert };

pub fn init(gpa: Allocator, buffer: Buffer) Editor {
    return .{ .gpa = gpa, .buffer = buffer };
}

pub fn deinit(self: *Editor) void {
    self.buffer.deinit();
    self.line_buf.deinit(self.gpa);
    self.* = undefined;
}

pub const Pos = struct {
    line: usize,
    /// Byte offset within the line.
    byte: usize,
    /// Display column.
    col: usize,
};

/// The cursor's line, byte offset in the line and display column.
pub fn cursorPos(self: *Editor) !Pos {
    const line = self.buffer.lineOf(self.cursor);
    const byte = self.cursor - self.buffer.lineStart(line);
    const s = try self.lineText(line);
    return .{ .line = line, .byte = byte, .col = displayCol(s, byte) };
}

pub fn handleKey(self: *Editor, key: Key) !void {
    switch (key) {
        .char => |c| switch (c) {
            'h' => try self.moveLeft(),
            'l' => try self.moveRight(),
            'j' => try self.moveVertical(.down),
            'k' => try self.moveVertical(.up),
            '0' => try self.moveLineStart(),
            '$' => try self.moveLineEnd(),
            else => {},
        },
        .left => try self.moveLeft(),
        .right => try self.moveRight(),
        .down => try self.moveVertical(.down),
        .up => try self.moveVertical(.up),
        .home => try self.moveLineStart(),
        .end => try self.moveLineEnd(),
        else => {},
    }
}

/// Scrolls the view so the cursor is inside a `rows` by `cols` area.
pub fn scrollToCursor(self: *Editor, rows: usize, cols: usize) !void {
    const pos = try self.cursorPos();
    if (pos.line < self.top) self.top = pos.line;
    if (rows > 0 and pos.line >= self.top + rows) self.top = pos.line - rows + 1;

    const s = try self.lineText(pos.line);
    const cell = if (pos.byte < s.len) @max(1, text.cellWidth(text.decode(s[pos.byte..]).cp, pos.col)) else 1;
    if (pos.col < self.left) self.left = pos.col;
    if (cols > 0 and pos.col + cell > self.left + cols) self.left = pos.col + cell -| cols;
}

fn moveLeft(self: *Editor) !void {
    const pos = try self.cursorPos();
    const s = try self.lineText(pos.line);
    if (pos.byte == 0) return;
    const byte = prevChar(s, pos.byte);
    self.cursor -= pos.byte - byte;
    self.want_col = displayCol(s, byte);
}

fn moveRight(self: *Editor) !void {
    const pos = try self.cursorPos();
    const s = try self.lineText(pos.line);
    const byte = nextChar(s, pos.byte);
    if (byte > self.maxByte(s)) return;
    self.cursor += byte - pos.byte;
    self.want_col = displayCol(s, byte);
}

fn moveVertical(self: *Editor, dir: enum { up, down }) !void {
    const line = self.buffer.lineOf(self.cursor);
    const target = switch (dir) {
        .up => if (line == 0) return else line - 1,
        .down => if (line + 1 >= self.buffer.visibleLineCount()) return else line + 1,
    };
    const s = try self.lineText(target);
    self.cursor = self.buffer.lineStart(target) + @min(byteAtCol(s, self.want_col), self.maxByte(s));
}

fn moveLineStart(self: *Editor) !void {
    self.cursor = self.buffer.lineStart(self.buffer.lineOf(self.cursor));
    self.want_col = 0;
}

fn moveLineEnd(self: *Editor) !void {
    const line = self.buffer.lineOf(self.cursor);
    const s = try self.lineText(line);
    self.cursor = self.buffer.lineStart(line) + self.maxByte(s);
    self.want_col = std.math.maxInt(usize);
}

/// The furthest byte offset the cursor may take in line `s`: on the last
/// character in normal mode, after it in insert mode.
fn maxByte(self: *const Editor, s: []const u8) usize {
    return switch (self.mode) {
        .normal => if (s.len == 0) 0 else prevChar(s, s.len),
        .insert => s.len,
    };
}

/// Byte offset of the newline ending `line`, or the end of the text.
fn lineEnd(self: *const Editor, line: usize) usize {
    if (line + 1 < self.buffer.lineCount()) return self.buffer.lineStart(line + 1) - 1;
    return self.buffer.len;
}

/// The text of `line` without its newline. Valid until the next call.
fn lineText(self: *Editor, line: usize) ![]const u8 {
    const start = self.buffer.lineStart(line);
    const end = self.lineEnd(line);
    try self.line_buf.resize(self.gpa, end - start);
    var it = self.buffer.chunksFrom(start);
    var n: usize = 0;
    while (n < end - start) {
        const chunk = it.next().?;
        const take = @min(chunk.len, end - start - n);
        @memcpy(self.line_buf.items[n..][0..take], chunk[0..take]);
        n += take;
    }
    return self.line_buf.items;
}

/// Combining marks belong to the character before them.
fn isMark(cp: u21) bool {
    return text.cellWidth(cp, 0) == 0;
}

/// Start of the character after the one at `i`.
fn nextChar(s: []const u8, i: usize) usize {
    if (i >= s.len) return s.len;
    var j = i + text.decode(s[i..]).len;
    while (j < s.len and isMark(text.decode(s[j..]).cp)) j += text.decode(s[j..]).len;
    return j;
}

/// Start of the character before `i`.
fn prevChar(s: []const u8, i: usize) usize {
    var j = text.prevStart(s, i);
    while (j > 0 and isMark(text.decode(s[j..]).cp)) j = text.prevStart(s, j);
    return j;
}

/// Display column where byte `i` of line `s` starts.
fn displayCol(s: []const u8, i: usize) usize {
    var col: usize = 0;
    var j: usize = 0;
    while (j < i) {
        col += text.cellWidth(text.decode(s[j..]).cp, col);
        j += text.decode(s[j..]).len;
    }
    return col;
}

/// Byte offset of the character covering display column `want`, or the end
/// of the line if it is shorter.
fn byteAtCol(s: []const u8, want: usize) usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const next = nextChar(s, i);
        col += displayCol(s[i..next], next - i);
        if (col > want) return i;
        i = next;
    }
    return s.len;
}

const testing = std.testing;
const Decoder = @import("keys.zig").Decoder;

fn testEditor(content: []const u8) !Editor {
    return .init(testing.allocator, try .init(testing.allocator, content));
}

fn typeKeys(e: *Editor, input: []const u8) !void {
    var d: Decoder = .{ .bytes = input };
    while (d.next()) |key| try e.handleKey(key);
}

fn expectCursor(e: *Editor, line: usize, byte: usize) !void {
    const pos = try e.cursorPos();
    try testing.expectEqual(line, pos.line);
    try testing.expectEqual(byte, pos.byte);
}

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
