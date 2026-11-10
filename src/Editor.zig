//! Editor state and key handling, with no terminal or file I/O: keys go in,
//! the buffer, cursor and view change.
//!
//! Normal and visual mode follow Vim's grammar: [count] [operator [count]]
//! words. An operator (d, y, c, >, <) acts on the text a motion moves over,
//! or in visual mode on the selection.
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
const History = @import("History.zig");
const words = @import("editor/words.zig");
const cmdline = @import("editor/cmdline.zig");
const normal = @import("editor/normal.zig");
const motions = @import("editor/motions.zig");
const operators = @import("editor/operators.zig");
const visual = @import("editor/visual.zig");
const insert = @import("editor/insert.zig");
const Settings = @import("editor/settings.zig").Settings;
const help_page = @import("editor/help.zig");
const pages = @import("editor/page.zig");
const prevChar = text.prevChar;
const displayCol = text.displayCol;

const Editor = @This();

gpa: Allocator,
buffer: Buffer,
/// Byte offset of the cursor in the buffer.
cursor: usize = 0,
/// Display column that up/down movement aims for, kept across short lines.
want_col: usize = 0,
mode: Mode = .normal,
history: History = .{},
/// Number of edits made so far; tells `.` whether a command changed anything.
edits: usize = 0,
/// First visible line and display column.
top: usize = 0,
left: usize = 0,
/// Text rows on screen as of the last `scrollToCursor`; sizes Ctrl-D/U.
view_rows: usize = 0,
/// Scratch copy of one line.
line_buf: std.ArrayList(u8) = .empty,
/// File name the buffer is saved to; empty if it has none yet.
name: std.ArrayList(u8) = .empty,
/// Text typed on the command line.
command: std.ArrayList(u8) = .empty,
command_kind: CommandKind = .ex,
/// The mode to return to when the command line closes.
command_return: Mode = .normal,
/// Shown in place of the status bar until the next key.
message: Message = .{},
/// Count, operator and pending character argument typed so far.
pending: Pending = .{},
/// The unnamed register: what y, d, c and x put away and p pastes.
register: Register = .{},
/// Text yanked since the caller last took it, for the system clipboard.
/// Copied at the yank, since later keys in the same read may change the
/// register before the caller gets to it.
clipboard: std.ArrayList(u8) = .empty,
clipboard_pending: bool = false,
/// The last f, t, F or T, for ; and ,.
last_find: ?struct { kind: words.FindKind, target: u21 } = null,
/// The last search, for n and N.
last_search: std.ArrayList(u8) = .empty,
last_search_forward: bool = true,
/// The other end of the selection in visual mode.
visual_anchor: usize = 0,
visual_kind: VisualKind = .char,
dot: Dot = .{},
/// The file exists but can't be written; shown as [RO], and the first change
/// warns that saving will fail.
readonly: bool = false,
warned_readonly: bool = false,
/// The file uses Windows line endings (\r\n); the buffer holds plain lines
/// and saving puts the \r back.
crlf: bool = false,
/// Where the cursor was left after inserting a new line's indentation
/// automatically. While it's still there (nothing typed), leaving insert
/// mode or pressing Enter again removes that indentation.
autoindent_at: ?usize = null,
settings: Settings = .{},
/// A page open over the text (help, settings): it gets the keys and is
/// what's shown (see page.zig).
page: ?*Editor = null,
/// This editor is such a page.
is_page: bool = false,
/// This editor is the help page: nothing may change its text.
view_only: bool = false,
/// \settings was typed: the next action is `open_settings`.
settings_requested: bool = false,
/// Ctrl-Z was pressed; `handleKey` returns `.suspend`.
suspend_requested: bool = false,
/// The last key's command couldn't run (a motion with nowhere to go, or a
/// missing f/t target). Ends a `.` replay early.
failed: bool = false,
/// Set while typing after a block I, A or c; replicated on Escape.
block_insert: ?struct {
    first_line: usize,
    last_line: usize,
    col: usize,
    /// Where typing started on the first line.
    start: usize,
    /// Pad short lines out to `col` (A) instead of skipping them (I, c).
    pad: bool,
    /// After $: append at each line's end.
    to_end: bool = false,
    /// Lines in the text when typing started. If typing joined or split
    /// lines, the text isn't copied to the other lines.
    line_count: usize,
} = null,

pub const Mode = enum { normal, insert, command, visual };

/// Enough spaces for any indentation setting.
pub const blanks: [@import("editor/settings.zig").max_width]u8 = @splat(' ');

pub const VisualKind = enum { char, line, block };

/// `zvim` is the \ command line, for zvim's own commands (see settings.zig).
pub const CommandKind = enum { ex, zvim, search_forward, search_backward };

pub const Message = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    is_error: bool = false,

    pub fn text(m: *const Message) []const u8 {
        return m.buf[0..m.len];
    }

    /// Too long a message is cut short.
    pub fn set(m: *Message, is_error: bool, comptime fmt: []const u8, args: anytype) void {
        const written = std.fmt.bufPrint(&m.buf, fmt, args) catch |err| switch (err) {
            error.NoSpaceLeft => m.buf[0..],
        };
        m.len = written.len;
        m.is_error = is_error;
    }
};

pub const Register = struct {
    text: std.ArrayList(u8) = .empty,
    /// Line registers hold whole lines, each ending in a newline. Block
    /// registers hold the rows of a rectangle separated by newlines.
    kind: enum { char, line, block } = .char,
};

pub const Op = enum { delete, yank, change, indent, outdent };

pub const Pending = struct {
    count: usize = 0,
    op: ?Op = null,
    /// A count typed after the operator, as in d3w.
    op_count: usize = 0,
    wait: Wait = .none,

    /// Keys waiting for one more: g (gg), f/t/F/T (a character), r (a
    /// character), and i/a after an operator or in visual mode (an object).
    pub const Wait = union(enum) { none, g, find: words.FindKind, replace, object: Around };
    pub const Around = enum { inside, around };

    pub fn isEmpty(p: Pending) bool {
        return p.count == 0 and p.op == null and p.wait == .none;
    }
};

/// Keys for `.`: those of the command in progress, and of the last command
/// that changed the text.
pub const Dot = struct {
    recording: std.ArrayList(Key) = .empty,
    last: std.ArrayList(Key) = .empty,
    /// The command in progress never becomes the last change (u, Ctrl-R, ., :).
    excluded: bool = false,
    edits_at_start: usize = 0,
    replaying: bool = false,
};

/// What the caller has to do after a key, since the editor does no I/O.
pub const Action = union(enum) {
    none,
    quit,
    /// Save the buffer to `path`, then report back with `wrote` or `writeFailed`.
    write: struct {
        path: []const u8,
        then_quit: bool,
        /// :w! — write even over a read-only file or one changed on disk.
        force: bool = false,
    },
    /// Ctrl-Z: stop zvim as a shell job until it's continued.
    @"suspend",
    /// Load the file at `path` again and hand it to `reloaded`.
    reload: []const u8,
    /// \settings: read the settings file and hand it to `settings.openPage`.
    open_settings,
};

pub fn init(gpa: Allocator, buffer: Buffer, name: []const u8) !Editor {
    var self: Editor = .{ .gpa = gpa, .buffer = buffer };
    try self.name.appendSlice(gpa, name);
    return self;
}

pub fn deinit(self: *Editor) void {
    pages.close(self);
    const gpa = self.gpa;
    self.buffer.deinit();
    self.history.deinit(gpa);
    self.line_buf.deinit(gpa);
    self.name.deinit(gpa);
    self.command.deinit(gpa);
    self.register.text.deinit(gpa);
    self.clipboard.deinit(gpa);
    self.last_search.deinit(gpa);
    self.dot.recording.deinit(gpa);
    self.dot.last.deinit(gpa);
    self.* = undefined;
}

/// Whether the buffer differs from what was loaded or last saved.
pub fn isModified(self: *const Editor) bool {
    return self.history.isModified();
}

/// Shows a message until the next key.
pub fn setMessage(self: *Editor, is_error: bool, comptime fmt: []const u8, args: anytype) void {
    self.message.set(is_error, fmt, args);
}

/// Called after a successful `write` action.
pub fn wrote(self: *Editor, path: []const u8) void {
    self.history.markSaved();
    const lines = self.buffer.visibleLineCount();
    const bytes = self.buffer.len + if (self.crlf) self.buffer.newlines else 0;
    self.setMessage(false, "\"{s}\" {s}{d}L, {d}B written", .{ path, if (self.crlf) "[dos] " else "", lines, bytes });
}

/// Called after a `reload` action with the freshly loaded buffer: replaces
/// the text, starts a new undo history, and keeps the cursor's line.
pub fn reloaded(self: *Editor, buffer: Buffer) !void {
    const line = self.buffer.lineOf(self.cursor);
    self.buffer.deinit();
    self.buffer = buffer;
    self.history.deinit(self.gpa);
    self.history = .{};
    self.mode = .normal;
    self.pending = .{};
    self.block_insert = null;
    self.autoindent_at = null;
    try self.goToLine(line + 1);
    self.setMessage(false, "\"{s}\" {d}L, {d}B", .{ self.name.items, self.buffer.visibleLineCount(), self.buffer.len });
}

/// Moves to the first non-blank of 1-based line `n`, clamped to the text.
pub fn goToLine(self: *Editor, n: usize) !void {
    const line = @min(@max(n, 1), self.buffer.visibleLineCount()) - 1;
    self.cursor = self.buffer.lineStart(line) + text.firstNonBlank(try self.lineText(line));
    try self.clampCursor();
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
    return self.posOf(self.cursor);
}

pub fn posOf(self: *Editor, offset: usize) !Pos {
    const line = self.buffer.lineOf(offset);
    const byte = offset - self.buffer.lineStart(line);
    const s = try self.lineText(line);
    return .{ .line = line, .byte = byte, .col = displayCol(s, byte) };
}

/// The visual selection in screen terms, for drawing.
pub const Selection = struct {
    kind: VisualKind,
    /// First and last selected line.
    first_line: usize,
    last_line: usize,
    /// Char: display column where the selection starts on the first line and
    /// ends (exclusive) on the last. Block: the column range on every line.
    /// Unused for line selections.
    start_col: usize,
    end_col: usize,
};

pub fn selection(self: *Editor) !?Selection {
    if (self.mode != .visual and !(self.mode == .command and self.command_return == .visual)) return null;
    const a = @min(self.visual_anchor, self.cursor);
    const b = @max(self.visual_anchor, self.cursor);
    const pa = try self.posOf(a);
    const pb = try self.posOf(b);
    switch (self.visual_kind) {
        .char => return .{
            .kind = .char,
            .first_line = pa.line,
            .last_line = pb.line,
            .start_col = pa.col,
            .end_col = pb.col + try self.cellWidthAt(b),
        },
        .line => return .{ .kind = .line, .first_line = pa.line, .last_line = pb.line, .start_col = 0, .end_col = 0 },
        .block => {
            const cols = try visual.blockColumns(self);
            return .{ .kind = .block, .first_line = pa.line, .last_line = pb.line, .start_col = cols.start, .end_col = cols.end };
        },
    }
}

/// Columns a character at `offset` takes (at least 1, also at a line end).
pub fn cellWidthAt(self: *Editor, offset: usize) !usize {
    const p = try self.posOf(offset);
    const s = try self.lineText(p.line);
    if (p.byte >= s.len) return 1;
    return @max(1, text.cellWidth(text.decode(s[p.byte..]).cp, p.col));
}

pub fn handleKey(self: *Editor, key: Key) Allocator.Error!Action {
    self.message.len = 0;
    self.failed = false;

    if (self.page != null) return pages.key(self, key);

    if (!self.dot.replaying) {
        if (self.mode == .normal and self.pending.isEmpty()) {
            self.dot.recording.clearRetainingCapacity();
            self.dot.excluded = false;
            self.dot.edits_at_start = self.edits;
        }
        try self.dot.recording.append(self.gpa, key);
    }

    if (key == .paste) {
        if (self.view_only) return self.refuseChange();
        try insert.pasteText(self, key.paste);
        // `.` can't replay a paste (its text isn't kept), so it repeats the
        // change before instead.
        self.dot.excluded = true;
        if (self.mode != .insert) try self.history.commit(self.gpa);
        return .none;
    }

    // Ctrl-C: like Escape in insert mode, on the command line and in visual
    // mode; in normal mode, a reminder of how to quit.
    if (key == .ctrl and key.ctrl == 'c') {
        if (self.mode == .normal and self.pending.isEmpty()) {
            self.setMessage(false, "Type :q! and press Enter to quit without saving", .{});
            return .none;
        }
        return self.handleKey(.escape);
    }

    const action: Action = switch (self.mode) {
        .normal, .visual => blk: {
            try normal.normalKey(self, key);
            break :blk .none;
        },
        .insert => blk: {
            try insert.insertKey(self, key);
            break :blk .none;
        },
        .command => try cmdline.commandKey(self, key),
    };

    // Everything since the last commit is one undo step, except that a trip
    // through insert mode stays open until it ends.
    if (self.mode != .insert) try self.history.commit(self.gpa);

    if (self.readonly and !self.warned_readonly and self.isModified()) {
        self.warned_readonly = true;
        self.setMessage(true, "W10: Warning: Changing a readonly file", .{});
    }

    if (self.settings_requested) {
        self.settings_requested = false;
        return .open_settings;
    }
    if (self.suspend_requested) {
        self.suspend_requested = false;
        self.dot.excluded = true;
        return .@"suspend";
    }

    // A finished command that changed the text is what `.` repeats.
    if (!self.dot.replaying and self.mode == .normal and self.pending.isEmpty() and
        !self.dot.excluded and self.edits != self.dot.edits_at_start)
    {
        self.dot.last.clearRetainingCapacity();
        try self.dot.last.appendSlice(self.gpa, self.dot.recording.items);
        self.dot.edits_at_start = self.edits;
    }
    return action;
}

// ---------------------------------------------------------------------------
// Editing primitives and cursor helpers, shared by the modules in editor/.
// Every change to the buffer goes through insertBytes and deleteBytes so it
// can be undone and so `.` can tell whether a command changed anything.

/// Inserts into the buffer, recording the edit for undo.
pub fn insertBytes(self: *Editor, pos: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    try self.history.record(self.gpa, self.cursor, .insert, pos, bytes);
    try self.buffer.insert(pos, bytes);
    self.edits += 1;
}

/// Deletes characters from the buffer, recording the deleted bytes for undo.
/// The last line never disappears this way: a final newline is kept, and
/// emptying the last line of text without one keeps it as an empty line
/// (otherwise the newline before it would end the text, and the line would
/// be gone). Deleting whole lines uses `deleteLines` instead.
pub fn deleteBytes(self: *Editor, pos: usize, n_wanted: usize) !void {
    var n = n_wanted;
    // A final newline belongs to the last line; deleting characters keeps it.
    if (n > 0 and pos + n == self.buffer.len and self.endsWithNewline()) n -= 1;
    if (n == 0) return;
    const empties_last_line = pos + n == self.buffer.len and pos > 0 and
        !self.endsWithNewline() and self.byteAt(pos - 1) == '\n';
    try self.deleteLines(pos, n);
    if (empties_last_line) try self.insertBytes(self.buffer.len, "\n");
}

/// Deletes from the buffer exactly, recording the deleted bytes for undo.
pub fn deleteLines(self: *Editor, pos: usize, n: usize) !void {
    if (n == 0) return;
    const removed = try self.gpa.alloc(u8, n);
    defer self.gpa.free(removed);
    self.buffer.read(pos, removed);
    try self.history.record(self.gpa, self.cursor, .delete, pos, removed);
    try self.buffer.delete(pos, n);
    self.edits += 1;
}

pub fn undo(self: *Editor) !void {
    try self.history.commit(self.gpa);
    const group = self.history.undo() orelse {
        self.setMessage(false, "Already at oldest change", .{});
        return;
    };
    var i = group.edits.len;
    while (i > 0) {
        i -= 1;
        const e = group.edits[i];
        switch (e.kind) {
            .insert => try self.buffer.delete(e.pos, e.text.len),
            .delete => try self.buffer.insert(e.pos, e.text),
        }
    }
    // Like Vim, the cursor goes to where the undone change starts.
    var first = group.cursor;
    for (group.edits) |e| first = @min(first, e.pos);
    self.cursor = @min(first, self.buffer.len);
    try self.clampCursor();
    self.setMessage(false, "Undid change #{d}", .{group.id});
}

pub fn redo(self: *Editor) !void {
    const group = self.history.redo() orelse {
        self.setMessage(false, "Already at newest change", .{});
        return;
    };
    for (group.edits) |e| switch (e.kind) {
        .insert => try self.buffer.insert(e.pos, e.text),
        .delete => try self.buffer.delete(e.pos, e.text.len),
    };
    self.cursor = @min(group.edits[0].pos, self.buffer.len);
    try self.clampCursor();
    self.setMessage(false, "Redid change #{d}", .{group.id});
}

pub fn toOffset(self: *Editor, p: words.Pos) usize {
    return self.buffer.lineStart(p.line) + p.byte;
}

pub fn toPos(self: *Editor, offset: usize) words.Pos {
    const line = self.buffer.lineOf(offset);
    return .{ .line = line, .byte = offset - self.buffer.lineStart(line) };
}

/// A key that would change the text of the help page: refused.
pub fn refuseChange(self: *Editor) Action {
    self.pending = .{};
    self.failed = true;
    self.setMessage(true, help_page.refusal, .{});
    return .none;
}

/// Called after a yank: the register goes to the system clipboard.
pub fn yanked(self: *Editor) !void {
    self.clipboard.clearRetainingCapacity();
    try self.clipboard.appendSlice(self.gpa, self.register.text.items);
    self.clipboard_pending = true;
}

/// The indentation (leading blanks) of `line`, at most `max` bytes of it,
/// copied into `buf`.
pub fn indentOf(self: *Editor, line: usize, max: usize, buf: []u8) ![]const u8 {
    const s = try self.lineText(line);
    const n = @min(text.firstNonBlank(s), max, buf.len);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

/// If the cursor's line holds nothing but indentation that was inserted
/// automatically, removes it.
pub fn dropUnusedAutoindent(self: *Editor) !void {
    const at = self.autoindent_at orelse return;
    self.autoindent_at = null;
    if (at != self.cursor) return;
    const p = self.toPos(self.cursor);
    const s = try self.lineText(p.line);
    if (p.byte != s.len or text.firstNonBlank(s) != s.len or s.len == 0) return;
    self.cursor -= s.len;
    try self.deleteBytes(self.cursor, s.len);
}

pub fn byteAt(self: *Editor, pos: usize) u8 {
    var it = self.buffer.chunksFrom(pos);
    return it.next().?[0];
}

pub fn endsWithNewline(self: *Editor) bool {
    if (self.buffer.len == 0) return false;
    var it = self.buffer.chunksFrom(self.buffer.len - 1);
    return it.next().?[0] == '\n';
}

/// Pads `line` with spaces to display column `col`.
pub fn insertBytesPadding(self: *Editor, line: usize, col: usize) !void {
    const s = try self.lineText(line);
    const width = displayCol(s, s.len);
    if (width >= col) return;
    const spaces = try self.gpa.alloc(u8, col - width);
    defer self.gpa.free(spaces);
    @memset(spaces, ' ');
    try self.insertBytes(self.lineEnd(line), spaces);
}

/// Inserts `bytes` at the cursor and moves the cursor past them.
pub fn insertAtCursor(self: *Editor, bytes: []const u8) !void {
    // At the very end of text without a final newline, a newline would only
    // terminate the last line; a second one makes the new, empty line real.
    const ends_line = self.cursor == self.buffer.len and bytes[bytes.len - 1] == '\n';
    try self.insertBytes(self.cursor, bytes);
    if (ends_line) try self.insertBytes(self.cursor + bytes.len, "\n");
    self.cursor += bytes.len;
    try self.updateWantCol();
}

// ---------------------------------------------------------------------------
// Cursor and view

/// Keeps the cursor within its line after an edit or mode change.
pub fn clampCursor(self: *Editor) !void {
    self.cursor = @min(self.cursor, self.buffer.len);
    const line = @min(self.buffer.lineOf(self.cursor), self.buffer.visibleLineCount() - 1);
    const start = self.buffer.lineStart(line);
    const s = try self.lineText(line);
    self.cursor = start + @min(self.cursor -| start, self.maxByte(s));
    try self.updateWantCol();
}

pub fn updateWantCol(self: *Editor) !void {
    self.want_col = (try self.cursorPos()).col;
}

/// Scrolls the view so the cursor is inside a `rows` by `cols` area.
pub fn scrollToCursor(self: *Editor, rows: usize, cols: usize) !void {
    self.view_rows = rows;
    const pos = try self.cursorPos();
    if (pos.line < self.top) self.top = pos.line;
    if (rows > 0 and pos.line >= self.top + rows) self.top = pos.line - rows + 1;

    const cell = try self.cellWidthAt(self.cursor);
    if (pos.col < self.left) self.left = pos.col;
    if (cols > 0 and pos.col + cell > self.left + cols) self.left = pos.col + cell -| cols;
}

/// The furthest byte offset the cursor may take in line `s`: on the last
/// character in normal and visual mode, after it in insert mode.
pub fn maxByte(self: *const Editor, s: []const u8) usize {
    return switch (self.mode) {
        .normal, .command, .visual => if (s.len == 0) 0 else prevChar(s, s.len),
        .insert => s.len,
    };
}

/// Byte offset of the newline ending `line`, or the end of the text.
pub fn lineEnd(self: *const Editor, line: usize) usize {
    if (line + 1 < self.buffer.lineCount()) return self.buffer.lineStart(line + 1) - 1;
    return self.buffer.len;
}

/// The text of `line` without its newline. Valid until the next call.
pub fn lineText(self: *Editor, line: usize) ![]const u8 {
    const start = self.buffer.lineStart(line);
    const end = self.lineEnd(line);
    try self.line_buf.resize(self.gpa, end - start);
    self.buffer.read(start, self.line_buf.items);
    return self.line_buf.items;
}

const testing = std.testing;
const h = @import("editor/testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const typeThenEscape = h.typeThenEscape;
const expectCursor = h.expectCursor;
const expectText = h.expectText;

test {
    _ = cmdline;
    _ = normal;
    _ = motions;
    _ = operators;
    _ = visual;
    _ = insert;
    _ = @import("editor/textobjects.zig");
    _ = @import("editor/settings.zig");
    _ = @import("editor/help.zig");
    _ = @import("editor/page.zig");
    _ = h;
}

test "u undoes a whole insert session, Ctrl-R redoes it" {
    var e = try testEditor("world\n");
    defer e.deinit();
    try typeThenEscape(&e, "ihello\rthere ");
    try expectText(&e, "hello\nthere world\n");
    try typeKeys(&e, "u");
    try expectText(&e, "world\n");
    try expectCursor(&e, 0, 0);
    try testing.expectEqualStrings("Undid change #1", e.message.text());
    try typeKeys(&e, "u");
    try testing.expectEqualStrings("Already at oldest change", e.message.text());
    try typeKeys(&e, "\x12"); // Ctrl-R
    try expectText(&e, "hello\nthere world\n");
    try typeKeys(&e, "\x12");
    try testing.expectEqualStrings("Already at newest change", e.message.text());
}

test "each x is its own undo step" {
    var e = try testEditor("abcd\n");
    defer e.deinit();
    try typeKeys(&e, "xxx");
    try expectText(&e, "d\n");
    try typeKeys(&e, "u");
    try expectText(&e, "cd\n");
    try typeKeys(&e, "uu");
    try expectText(&e, "abcd\n");
    try testing.expect(!e.isModified());
}

test "undo back to the saved state clears the modified flag" {
    var e: Editor = try .init(testing.allocator, try .init(testing.allocator, "a\n"), "f");
    defer e.deinit();
    try typeKeys(&e, "x");
    e.wrote("f");
    try testing.expect(!e.isModified());
    try typeKeys(&e, "u");
    try testing.expect(e.isModified());
    try typeKeys(&e, "\x12");
    try testing.expect(!e.isModified());
}

test "backspace and line joins inside one insert session undo together" {
    var e = try testEditor("ab\ncd\n");
    defer e.deinit();
    try typeThenEscape(&e, "jixy\x7f\x7f\x7f\x7fz");
    // Two backspaces remove "xy", the third joins the lines, the fourth deletes "b".
    try expectText(&e, "azcd\n");
    try typeKeys(&e, "u");
    try expectText(&e, "ab\ncd\n");
}

test "o on text without a final newline undoes cleanly" {
    var e = try testEditor("abc");
    defer e.deinit();
    try typeThenEscape(&e, "onew");
    try expectText(&e, "abc\nnew\n");
    try typeKeys(&e, "u");
    try expectText(&e, "abc");
}

// Kept small so `zig build test` stays fast. To hunt for bugs, raise these
// (5000 runs of 300 keys takes about 25s) and try other seeds; set TRACE_RUN
// to a failing run to print its keys as they're typed.
const STRESS_RUNS = 300;
const STRESS_KEYS = 100;
const TRACE_RUN: ?usize = null;

fn checkInvariants(e: *Editor) !void {
    try testing.expect(e.cursor <= e.buffer.len);
    const line = e.buffer.lineOf(e.cursor);
    try testing.expect(line < e.buffer.visibleLineCount());
    const s = try e.lineText(line);
    const byte = e.cursor - e.buffer.lineStart(line);
    try testing.expect(byte <= s.len);
    if (e.mode == .normal) try testing.expect(byte == 0 or byte < s.len);
}

test "random key sequences keep the editor consistent and fully undoable" {
    try stress(false);
}

test "random key sequences never change a view-only editor (the help page)" {
    try stress(true);
}

fn stress(view_only: bool) !void {
    // Every key the editor knows, plus multi-key commands, weighted toward
    // short, common ones. Each step picks one and checks the invariants.
    const pool = [_][]const u8{
        "h",       "j",      "k",      "l",    "w",    "b",   "e",   "W",    "B",       "E",       "0",      "^",     "$",
        "gg",      "G",      "2G",     "3j",   "fa",   "t ",  "Fe",  "T.",   ";",       ",",       "x",      "X",     "s",
        "D",       "C",      "S",      "Y",    "p",    "P",   "J",   "rz",   "r\r",     "dd",      "yy",     "cc",    "dw",
        "de",      "db",     "d$",     "y$",   "cw",   ">>",  "<<",  ">j",   "u",       "\x12",    ".",      "2.",    "v",
        "V",       "\x16",   "o",      "O",    "i",    "a",   "I",   "A",    "\x1b",    "abc",     "\r",     "\t",    "\x7f",
        "é",
        "中",
        "\x1b[3~", "\x1b[A", "\x1b[C", "/a\r", "?e\r", "n",   "N",   "\x04", "\x15",    ":q\r",    ":x\r",   ":zz\r", "y",
        "d",       "c",      ">",      "<",    "3",    "jj",  "vjd", "Vjy",  "\x16jlI", "\x16jlA", "\x16jd", "vep",   "diw",
        "daw",     "ci\"",   "da(",    "yi{",  "vip",  "vaw", "dap", ">ip",  "d2i(",    "ciW",     "ya'",
    };
    const originals = [_][]const u8{
        "    indented {\n\tmore\n  }\n",
        "alpha beta\n\tgamma(delta)\n\n  epsilon é 中文\nlast line",
        "f(a, \"b(c)\", {\n  'd' [e]\n})\n",
        "one\n\ntwo three\n",
        "",
    };
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();

    for (0..STRESS_RUNS) |run| {
        const original = originals[run % originals.len];
        if (TRACE_RUN != null and TRACE_RUN.? != run) {
            for (0..STRESS_KEYS) |_| _ = rand.uintLessThan(usize, pool.len);
            continue;
        }
        var e = try testEditor(original);
        defer e.deinit();
        e.view_rows = 5;
        e.view_only = view_only;
        var picked: [STRESS_KEYS]usize = undefined;
        for (0..STRESS_KEYS) |step| {
            picked[step] = rand.uintLessThan(usize, pool.len);
            const keys = pool[picked[step]];
            var d: @import("keys.zig").Decoder = .{ .bytes = keys };
            if (TRACE_RUN != null) std.debug.print("step {d}: {f}\n", .{ step, std.zig.fmtString(keys) });
            while (d.next()) |key| {
                _ = try e.handleKey(key);
                (if (view_only and (e.isModified() or e.mode == .insert)) error.Changed else checkInvariants(&e)) catch |err| {
                    std.debug.print("keys:", .{});
                    for (picked[0 .. step + 1]) |k| std.debug.print(" {f}", .{std.zig.fmtString(pool[k])});
                    std.debug.print("\n", .{});
                    return err;
                };
            }
        }
        // Back to normal mode, then undo everything.
        _ = try e.handleKey(.escape);
        _ = try e.handleKey(.escape);
        if (view_only) {
            try expectText(&e, original);
            continue;
        }
        for (0..1000) |_| _ = try e.handleKey(.{ .char = 'u' });
        try expectText(&e, original);
    }
}
