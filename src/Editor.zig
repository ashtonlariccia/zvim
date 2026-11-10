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
/// The buffer has changed since it was loaded or last saved.
modified: bool = false,
/// First visible line and display column.
top: usize = 0,
left: usize = 0,
/// Scratch copy of the cursor's line.
line_buf: std.ArrayList(u8) = .empty,
/// File name the buffer is saved to; empty if it has none yet.
name: std.ArrayList(u8) = .empty,
/// Text typed after ':' in command mode.
command: std.ArrayList(u8) = .empty,
/// Shown in place of the status bar until the next key.
message: Message = .{},

pub const Mode = enum { normal, insert, command };

pub const Message = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    is_error: bool = false,

    pub fn text(m: *const Message) []const u8 {
        return m.buf[0..m.len];
    }
};

/// What the caller has to do after a key, since the editor does no I/O.
pub const Action = union(enum) {
    none,
    quit,
    /// Save the buffer to `path`, then report back with `wrote` or `writeFailed`.
    write: struct { path: []const u8, then_quit: bool },
};

pub fn init(gpa: Allocator, buffer: Buffer, name: []const u8) !Editor {
    var self: Editor = .{ .gpa = gpa, .buffer = buffer };
    try self.name.appendSlice(gpa, name);
    return self;
}

pub fn deinit(self: *Editor) void {
    self.buffer.deinit();
    self.line_buf.deinit(self.gpa);
    self.name.deinit(self.gpa);
    self.command.deinit(self.gpa);
    self.* = undefined;
}

/// Shows a message until the next key.
pub fn setMessage(self: *Editor, is_error: bool, comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&self.message.buf, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => self.message.buf[0..],
    };
    self.message.len = written.len;
    self.message.is_error = is_error;
}

/// Called after a successful `write` action.
pub fn wrote(self: *Editor, path: []const u8) void {
    self.modified = false;
    self.setMessage(false, "\"{s}\" {d}L, {d}B written", .{ path, self.buffer.visibleLineCount(), self.buffer.len });
}

/// Called after a failed `write` action.
pub fn writeFailed(self: *Editor, path: []const u8, err: anyerror) void {
    self.setMessage(true, "E212: Can't write \"{s}\": {s}", .{ path, @errorName(err) });
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

pub fn handleKey(self: *Editor, key: Key) !Action {
    self.message.len = 0;
    switch (self.mode) {
        .normal => try self.normalKey(key),
        .insert => try self.insertKey(key),
        .command => return self.commandKey(key),
    }
    return .none;
}

fn commandKey(self: *Editor, key: Key) !Action {
    switch (key) {
        .char => |c| {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &bytes) catch return .none;
            try self.command.appendSlice(self.gpa, bytes[0..n]);
        },
        .tab => try self.command.append(self.gpa, '\t'),
        .backspace => {
            if (self.command.items.len == 0) {
                self.mode = .normal;
            } else {
                self.command.shrinkRetainingCapacity(text.prevStart(self.command.items, self.command.items.len));
            }
        },
        .escape => self.mode = .normal,
        .enter => {
            self.mode = .normal;
            return self.runCommand();
        },
        else => {},
    }
    return .none;
}

/// Runs the command line: w, q, wq, x, each optionally with ! and w/wq/x
/// with a file name.
fn runCommand(self: *Editor) !Action {
    const line = std.mem.trim(u8, self.command.items, " \t");
    var name_end: usize = 0;
    while (name_end < line.len and std.ascii.isAlphabetic(line[name_end])) name_end += 1;
    const cmd = line[0..name_end];
    var rest = line[name_end..];
    const bang = rest.len > 0 and rest[0] == '!';
    if (bang) rest = rest[1..];
    const arg = std.mem.trim(u8, rest, " \t");

    if (cmd.len == 0 and line.len == 0) return .none;
    const write = std.mem.eql(u8, cmd, "w");
    const write_quit = std.mem.eql(u8, cmd, "wq") or std.mem.eql(u8, cmd, "x");
    if (write or write_quit) {
        if (arg.len > 0 and self.name.items.len == 0) {
            try self.name.appendSlice(self.gpa, arg);
        }
        const path = if (arg.len > 0) arg else self.name.items;
        if (path.len == 0) {
            self.setMessage(true, "E32: No file name", .{});
            return .none;
        }
        // Like Vim, a file always ends with a newline when written.
        var tail = self.buffer.chunksFrom(self.buffer.len -| 1);
        const last = if (tail.next()) |chunk| chunk[0] else '\n';
        if (last != '\n') try self.buffer.insert(self.buffer.len, "\n");
        return .{ .write = .{ .path = path, .then_quit = write_quit } };
    }
    if (std.mem.eql(u8, cmd, "q") and arg.len == 0) {
        if (self.modified and !bang) {
            self.setMessage(true, "E37: No write since last change (add ! to override)", .{});
            return .none;
        }
        return .quit;
    }
    self.setMessage(true, "E492: Not an editor command: {s}", .{line});
    return .none;
}

fn normalKey(self: *Editor, key: Key) !void {
    switch (key) {
        .char => |c| switch (c) {
            'h' => try self.moveLeft(),
            'l' => try self.moveRight(),
            'j' => try self.moveVertical(.down),
            'k' => try self.moveVertical(.up),
            '0' => try self.moveLineStart(),
            '$' => try self.moveLineEnd(),
            'x' => try self.deleteUnderCursor(),
            'i' => self.mode = .insert,
            'a' => {
                self.mode = .insert;
                try self.moveRight();
            },
            'I' => {
                self.mode = .insert;
                try self.moveFirstNonBlank();
            },
            'A' => {
                self.mode = .insert;
                try self.moveLineEnd();
            },
            'o' => {
                const line = self.buffer.lineOf(self.cursor);
                self.cursor = self.lineEnd(line);
                try self.insertAtCursor("\n");
                self.mode = .insert;
            },
            ':' => {
                self.mode = .command;
                self.command.clearRetainingCapacity();
            },
            'O' => {
                self.cursor = self.buffer.lineStart(self.buffer.lineOf(self.cursor));
                try self.insertAtCursor("\n");
                self.cursor -= 1;
                self.mode = .insert;
            },
            else => {},
        },
        .left, .backspace => try self.moveLeft(),
        .right => try self.moveRight(),
        .down => try self.moveVertical(.down),
        .up => try self.moveVertical(.up),
        .home => try self.moveLineStart(),
        .end => try self.moveLineEnd(),
        .delete => try self.deleteUnderCursor(),
        else => {},
    }
}

fn insertKey(self: *Editor, key: Key) !void {
    switch (key) {
        .char => |c| {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &bytes) catch return;
            try self.insertAtCursor(bytes[0..n]);
        },
        .enter => try self.insertAtCursor("\n"),
        .tab => try self.insertAtCursor("\t"),
        .backspace => try self.deleteBeforeCursor(),
        .delete => try self.deleteUnderCursor(),
        .escape => {
            // Like Vim, leaving insert mode steps back onto the last typed character.
            try self.moveLeft();
            self.mode = .normal;
            try self.clampCursor();
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

/// Inserts `bytes` at the cursor and moves the cursor past them.
fn insertAtCursor(self: *Editor, bytes: []const u8) !void {
    // At the very end of text without a final newline, a newline would only
    // terminate the last line; a second one makes the new, empty line real.
    const ends_line = self.cursor == self.buffer.len and bytes[bytes.len - 1] == '\n';
    try self.buffer.insert(self.cursor, bytes);
    if (ends_line) try self.buffer.insert(self.cursor + bytes.len, "\n");
    self.cursor += bytes.len;
    self.modified = true;
    try self.updateWantCol();
}

/// Deletes the character under the cursor. In insert mode at the end of a
/// line, joins the next line onto this one instead.
fn deleteUnderCursor(self: *Editor) !void {
    const pos = try self.cursorPos();
    const s = try self.lineText(pos.line);
    if (pos.byte < s.len) {
        try self.buffer.delete(self.cursor, nextChar(s, pos.byte) - pos.byte);
    } else if (self.mode == .insert and pos.line + 1 < self.buffer.visibleLineCount()) {
        try self.buffer.delete(self.cursor, 1);
    } else return;
    self.modified = true;
    try self.clampCursor();
}

/// Deletes the character before the cursor, or at the start of a line joins
/// it onto the previous one.
fn deleteBeforeCursor(self: *Editor) !void {
    const pos = try self.cursorPos();
    if (pos.byte > 0) {
        const s = try self.lineText(pos.line);
        const n = pos.byte - prevChar(s, pos.byte);
        self.cursor -= n;
        try self.buffer.delete(self.cursor, n);
    } else if (pos.line > 0) {
        self.cursor -= 1;
        try self.buffer.delete(self.cursor, 1);
    } else return;
    self.modified = true;
    try self.updateWantCol();
}

/// Keeps the cursor within its line after an edit or mode change.
fn clampCursor(self: *Editor) !void {
    const line = self.buffer.lineOf(self.cursor);
    const start = self.buffer.lineStart(line);
    const s = try self.lineText(line);
    self.cursor = start + @min(self.cursor - start, self.maxByte(s));
    try self.updateWantCol();
}

fn updateWantCol(self: *Editor) !void {
    self.want_col = (try self.cursorPos()).col;
}

fn moveFirstNonBlank(self: *Editor) !void {
    const line = self.buffer.lineOf(self.cursor);
    const s = try self.lineText(line);
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    self.cursor = self.buffer.lineStart(line) + @min(i, self.maxByte(s));
    try self.updateWantCol();
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
        .normal, .command => if (s.len == 0) 0 else prevChar(s, s.len),
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
    return .init(testing.allocator, try .init(testing.allocator, content), "");
}

fn typeKeys(e: *Editor, input: []const u8) !void {
    var d: Decoder = .{ .bytes = input };
    while (d.next()) |key| try testing.expectEqual(Action.none, try e.handleKey(key));
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

fn expectText(e: *Editor, expected: []const u8) !void {
    const got = try e.buffer.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// Types `input`, then Escape. Escape goes separately because a byte right
/// after it in the same input would read as an escape sequence.
fn typeThenEscape(e: *Editor, input: []const u8) !void {
    try typeKeys(e, input);
    _ = try e.handleKey(.escape);
}

test "i inserts before the cursor; Escape steps back onto the last typed character" {
    var e = try testEditor("world\n");
    defer e.deinit();
    try typeThenEscape(&e, "ihello ");
    try expectText(&e, "hello world\n");
    try expectCursor(&e, 0, 5);
    try testing.expect(e.modified);
    try testing.expectEqual(Mode.normal, e.mode);
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

/// Types `:` and `command`, presses Enter, and returns the resulting action.
fn runTyped(e: *Editor, command: []const u8) !Action {
    try typeKeys(e, ":");
    try typeKeys(e, command);
    return e.handleKey(.enter);
}

test ":q quits only without unsaved changes, :q! always" {
    var e = try testEditor("abc\n");
    defer e.deinit();
    try testing.expectEqual(Action.quit, try runTyped(&e, "q"));
    try typeKeys(&e, "x");
    try testing.expectEqual(Action.none, try runTyped(&e, "q"));
    try testing.expectEqualStrings("E37: No write since last change (add ! to override)", e.message.text());
    try testing.expect(e.message.is_error);
    try testing.expectEqual(Action.quit, try runTyped(&e, "q!"));
}

test ":w writes to the buffer's name; :w name and :wq" {
    var e: Editor = try .init(testing.allocator, try .init(testing.allocator, "abc\n"), "f.txt");
    defer e.deinit();
    const w = try runTyped(&e, "w");
    try testing.expectEqualStrings("f.txt", w.write.path);
    try testing.expect(!w.write.then_quit);
    e.wrote(w.write.path);
    try testing.expect(!e.modified);
    try testing.expectEqualStrings("\"f.txt\" 1L, 4B written", e.message.text());

    const other = try runTyped(&e, "w  other.txt ");
    try testing.expectEqualStrings("other.txt", other.write.path);
    try testing.expectEqualStrings("f.txt", e.name.items); // the buffer keeps its name

    try testing.expect((try runTyped(&e, "wq")).write.then_quit);
    try testing.expect((try runTyped(&e, "x")).write.then_quit);
}

test ":w without any name asks for one; :w name gives the buffer that name" {
    var e = try testEditor("");
    defer e.deinit();
    try testing.expectEqual(Action.none, try runTyped(&e, "w"));
    try testing.expectEqualStrings("E32: No file name", e.message.text());
    try testing.expectEqualStrings("new.txt", (try runTyped(&e, "w new.txt")).write.path);
    try testing.expectEqualStrings("new.txt", e.name.items);
}

test "writing adds a final newline when the text lacks one" {
    var e = try testEditor("no newline");
    defer e.deinit();
    _ = try runTyped(&e, "w x");
    try expectText(&e, "no newline\n");
    var empty = try testEditor("");
    defer empty.deinit();
    _ = try runTyped(&empty, "w y");
    try expectText(&empty, ""); // an empty file stays empty
}

test "unknown commands, Escape and Backspace on an empty command line" {
    var e = try testEditor("abc\n");
    defer e.deinit();
    try testing.expectEqual(Action.none, try runTyped(&e, "frobnicate"));
    try testing.expectEqualStrings("E492: Not an editor command: frobnicate", e.message.text());
    try typeKeys(&e, "l"); // any key clears the message
    try testing.expectEqual(@as(usize, 0), e.message.len);

    try typeKeys(&e, ":q");
    _ = try e.handleKey(.escape);
    try testing.expectEqual(Mode.normal, e.mode);
    try typeKeys(&e, ":q\x7f\x7f");
    try testing.expectEqual(Mode.normal, e.mode);
    try typeKeys(&e, "x"); // back in normal mode: deletes a character
    try expectText(&e, "ac\n");
}
