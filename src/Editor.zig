//! Editor state and key handling, with no terminal or file I/O: keys go in,
//! the buffer, cursor and view change.
//!
//! Normal and visual mode follow Vim's grammar: [count] [operator [count]]
//! motion. An operator (d, y, c, >, <) acts on the text a motion moves over,
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
const motion = @import("motion.zig");
const nextChar = motion.nextChar;
const prevChar = motion.prevChar;
const displayCol = motion.displayCol;
const byteAtCol = motion.byteAtCol;
const firstNonBlank = motion.firstNonBlank;

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
/// Set by a yank so the caller can copy the register to the system clipboard.
clipboard_pending: bool = false,
/// The last f, t, F or T, for ; and ,.
last_find: ?struct { kind: motion.FindKind, target: u21 } = null,
/// The last search, for n and N.
last_search: std.ArrayList(u8) = .empty,
last_search_forward: bool = true,
/// The other end of the selection in visual mode.
visual_anchor: usize = 0,
visual_kind: VisualKind = .char,
dot: Dot = .{},

pub const Mode = enum { normal, insert, command, visual };
pub const VisualKind = enum { char, line, block };
pub const CommandKind = enum { ex, search_forward, search_backward };

pub const Message = struct {
    buf: [256]u8 = undefined,
    len: usize = 0,
    is_error: bool = false,

    pub fn text(m: *const Message) []const u8 {
        return m.buf[0..m.len];
    }
};

pub const Register = struct {
    text: std.ArrayList(u8) = .empty,
    /// Line registers hold whole lines, each ending in a newline. Block
    /// registers hold the rows of a rectangle separated by newlines.
    kind: enum { char, line, block } = .char,
};

const Op = enum { delete, yank, change, indent, outdent };

const Pending = struct {
    count: usize = 0,
    op: ?Op = null,
    /// A count typed after the operator, as in d3w.
    op_count: usize = 0,
    wait: Wait = .none,

    /// Keys that need a following key: g (gg), f/t/F/T (a character), r (a character).
    const Wait = union(enum) { none, g, find: motion.FindKind, replace };

    fn isEmpty(p: Pending) bool {
        return p.count == 0 and p.op == null and p.wait == .none;
    }
};

/// Keys for `.`: those of the command in progress, and of the last command
/// that changed the text.
const Dot = struct {
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
    write: struct { path: []const u8, then_quit: bool },
};

pub fn init(gpa: Allocator, buffer: Buffer, name: []const u8) !Editor {
    var self: Editor = .{ .gpa = gpa, .buffer = buffer };
    try self.name.appendSlice(gpa, name);
    return self;
}

pub fn deinit(self: *Editor) void {
    const gpa = self.gpa;
    self.buffer.deinit();
    self.history.deinit(gpa);
    self.line_buf.deinit(gpa);
    self.name.deinit(gpa);
    self.command.deinit(gpa);
    self.register.text.deinit(gpa);
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
    const written = std.fmt.bufPrint(&self.message.buf, fmt, args) catch |err| switch (err) {
        error.NoSpaceLeft => self.message.buf[0..],
    };
    self.message.len = written.len;
    self.message.is_error = is_error;
}

/// Called after a successful `write` action.
pub fn wrote(self: *Editor, path: []const u8) void {
    self.history.markSaved();
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
    return self.posOf(self.cursor);
}

fn posOf(self: *Editor, offset: usize) !Pos {
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
            const cols = try self.blockColumns();
            return .{ .kind = .block, .first_line = pa.line, .last_line = pb.line, .start_col = cols.start, .end_col = cols.end };
        },
    }
}

/// Columns a character at `offset` takes (at least 1, also at a line end).
fn cellWidthAt(self: *Editor, offset: usize) !usize {
    const p = try self.posOf(offset);
    const s = try self.lineText(p.line);
    if (p.byte >= s.len) return 1;
    return @max(1, text.cellWidth(text.decode(s[p.byte..]).cp, p.col));
}

pub fn handleKey(self: *Editor, key: Key) Allocator.Error!Action {
    self.message.len = 0;

    if (!self.dot.replaying) {
        if (self.mode == .normal and self.pending.isEmpty()) {
            self.dot.recording.clearRetainingCapacity();
            self.dot.excluded = false;
            self.dot.edits_at_start = self.edits;
        }
        try self.dot.recording.append(self.gpa, key);
    }

    const action: Action = switch (self.mode) {
        .normal, .visual => blk: {
            try self.normalKey(key);
            break :blk .none;
        },
        .insert => blk: {
            try self.insertKey(key);
            break :blk .none;
        },
        .command => try self.commandKey(key),
    };

    // Everything since the last commit is one undo step, except that a trip
    // through insert mode stays open until it ends.
    if (self.mode != .insert) try self.history.commit(self.gpa);

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

/// Inserts into the buffer, recording the edit for undo.
fn insertBytes(self: *Editor, pos: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    try self.history.record(self.gpa, self.cursor, .insert, pos, bytes);
    try self.buffer.insert(pos, bytes);
    self.edits += 1;
}

/// Deletes from the buffer, recording the deleted bytes for undo.
fn deleteBytes(self: *Editor, pos: usize, n: usize) !void {
    if (n == 0) return;
    const removed = try self.gpa.alloc(u8, n);
    defer self.gpa.free(removed);
    self.buffer.read(pos, removed);
    try self.history.record(self.gpa, self.cursor, .delete, pos, removed);
    try self.buffer.delete(pos, n);
    self.edits += 1;
}

fn undo(self: *Editor) !void {
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

fn redo(self: *Editor) !void {
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

// ---------------------------------------------------------------------------
// Command line

fn openCommandLine(self: *Editor, kind: CommandKind) void {
    self.command_return = self.mode;
    self.mode = .command;
    self.command_kind = kind;
    self.command.clearRetainingCapacity();
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
                self.closeCommandLine();
            } else {
                self.command.shrinkRetainingCapacity(text.prevStart(self.command.items, self.command.items.len));
            }
        },
        .escape => self.closeCommandLine(),
        .enter => {
            self.mode = self.command_return;
            switch (self.command_kind) {
                .ex => return self.runCommand(),
                .search_forward, .search_backward => try self.runSearch(),
            }
        },
        else => {},
    }
    return .none;
}

fn closeCommandLine(self: *Editor) void {
    self.mode = self.command_return;
    self.pending = .{};
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
        if (last != '\n') try self.insertBytes(self.buffer.len, "\n");
        return .{ .write = .{ .path = path, .then_quit = write_quit } };
    }
    if (std.mem.eql(u8, cmd, "q") and arg.len == 0) {
        if (self.isModified() and !bang) {
            self.setMessage(true, "E37: No write since last change (add ! to override)", .{});
            return .none;
        }
        return .quit;
    }
    self.setMessage(true, "E492: Not an editor command: {s}", .{line});
    return .none;
}

/// Enter on a / or ? command line: search for the typed text (or the last
/// search when empty), as a motion, so it also works after an operator.
fn runSearch(self: *Editor) !void {
    if (self.command.items.len > 0) {
        self.last_search.clearRetainingCapacity();
        try self.last_search.appendSlice(self.gpa, self.command.items);
    }
    self.last_search_forward = self.command_kind == .search_forward;
    try self.doMotion(.{ .search_next = false });
}

/// Finds the next occurrence of the last search from `from`, wrapping
/// around the end of the text.
fn search(self: *Editor, from: usize, forward: bool) !?usize {
    const pattern = self.last_search.items;
    const all = try self.buffer.toOwnedSlice(self.gpa);
    defer self.gpa.free(all);
    if (forward) {
        if (from + 1 <= all.len) {
            if (std.mem.indexOfPos(u8, all, from + 1, pattern)) |i| return i;
        }
        if (std.mem.indexOf(u8, all, pattern)) |i| {
            self.setMessage(true, "search hit BOTTOM, continuing at TOP", .{});
            return i;
        }
    } else {
        var i = from;
        while (i > 0) {
            i -= 1;
            if (std.mem.startsWith(u8, all[i..], pattern)) return i;
        }
        if (std.mem.lastIndexOf(u8, all, pattern)) |j| {
            self.setMessage(true, "search hit TOP, continuing at BOTTOM", .{});
            return j;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Normal and visual mode

fn keyChar(key: Key) ?u21 {
    return switch (key) {
        .char => |c| c,
        .tab => '\t',
        else => null,
    };
}

fn normalKey(self: *Editor, key: Key) !void {
    switch (self.pending.wait) {
        .none => {},
        .g => {
            self.pending.wait = .none;
            if (key == .char and key.char == 'g') return self.doMotion(.file_start);
            self.pending = .{};
            return;
        },
        .find => |kind| {
            self.pending.wait = .none;
            const target = keyChar(key) orelse {
                self.pending = .{};
                return;
            };
            self.last_find = .{ .kind = kind, .target = target };
            return self.doMotion(.{ .find = .{ .kind = kind, .target = target, .repeat = false } });
        },
        .replace => {
            self.pending.wait = .none;
            return self.replaceChars(key);
        },
    }

    if (key == .char) {
        const c = key.char;
        const counting = if (self.pending.op != null) self.pending.op_count else self.pending.count;
        if ((c >= '1' and c <= '9') or (c == '0' and counting > 0)) {
            const field = if (self.pending.op != null) &self.pending.op_count else &self.pending.count;
            field.* = field.* *| 10 +| (c - '0');
            return;
        }
    }

    if (motionFor(key)) |m| return self.doMotion(m);

    switch (key) {
        .char => |c| switch (c) {
            'd' => return self.operatorKey(.delete),
            'y' => return self.operatorKey(.yank),
            'c' => return self.operatorKey(.change),
            '>' => return self.operatorKey(.indent),
            '<' => return self.operatorKey(.outdent),
            'g' => {
                self.pending.wait = .g;
                return;
            },
            'f' => return self.waitFor(.{ .find = .to }),
            't' => return self.waitFor(.{ .find = .till }),
            'F' => return self.waitFor(.{ .find = .back_to }),
            'T' => return self.waitFor(.{ .find = .back_till }),
            'r' => return self.waitFor(.replace),
            // Search keeps the count and operator: d/foo deletes up to foo.
            '/' => return self.openCommandLine(.search_forward),
            '?' => return self.openCommandLine(.search_backward),
            else => {},
        },
        else => {},
    }

    // The rest take at most a count.
    const count = self.pending.count;
    const visual = self.mode == .visual;
    if (self.pending.op != null) {
        self.pending = .{};
        return;
    }
    self.pending = .{};
    const n = @max(count, 1);
    switch (key) {
        .escape => if (visual) try self.leaveVisual(),
        .delete => try self.shortcut(.delete, .right, count),
        .ctrl => |c| switch (c) {
            'r' => {
                self.dot.excluded = true;
                for (0..n) |_| try self.redo();
            },
            'v' => try self.toggleVisual(.block),
            else => {},
        },
        .char => |c| switch (c) {
            'x' => try self.shortcut(.delete, .right, count),
            'X' => try self.shortcut(.delete, .left, count),
            's' => try self.shortcut(.change, .right, count),
            'D' => try self.shortcut(.delete, .line_end, count),
            'C' => try self.shortcut(.change, .line_end, count),
            'S' => try self.lineShortcut(.change, n),
            'Y' => try self.lineShortcut(.yank, n),
            'p' => try self.paste(false, n),
            'P' => try self.paste(true, n),
            'J' => try self.joinLines(n),
            'u' => if (!visual) {
                self.dot.excluded = true;
                for (0..n) |_| try self.undo();
            },
            '.' => if (!visual) try self.repeatLastChange(count),
            'v' => try self.toggleVisual(.char),
            'V' => try self.toggleVisual(.line),
            'o' => if (visual) {
                std.mem.swap(usize, &self.visual_anchor, &self.cursor);
                try self.updateWantCol();
            } else try self.openLine(false),
            'O' => if (visual) {
                // In a block, O swaps to the other corner on the same line; elsewhere like o.
                try self.swapBlockCorner();
            } else try self.openLine(true),
            'i' => if (!visual) {
                self.mode = .insert;
            },
            'a' => if (!visual) {
                const p = try self.cursorPos();
                const s = try self.lineText(p.line);
                if (p.byte < s.len) self.cursor += nextChar(s, p.byte) - p.byte;
                self.mode = .insert;
            },
            'I' => if (visual) try self.blockInsert(false) else {
                const line = self.buffer.lineOf(self.cursor);
                self.cursor = self.buffer.lineStart(line) + firstNonBlank(try self.lineText(line));
                self.mode = .insert;
            },
            'A' => if (visual) try self.blockInsert(true) else {
                const line = self.buffer.lineOf(self.cursor);
                self.cursor = self.lineEnd(line);
                self.mode = .insert;
            },
            ':' => if (!visual) {
                self.dot.excluded = true;
                self.openCommandLine(.ex);
            },
            else => {},
        },
        else => {},
    }
    if (self.mode == .insert) try self.updateWantCol();
}

fn waitFor(self: *Editor, wait: Pending.Wait) void {
    self.pending.wait = wait;
}

/// An operator key: in visual mode it acts on the selection; doubled (dd,
/// yy, cc, >>, <<) it acts on [count] lines; otherwise it waits for a motion.
fn operatorKey(self: *Editor, op: Op) !void {
    if (self.mode == .visual) {
        self.pending = .{};
        return self.visualOperator(op);
    }
    if (self.pending.op) |pending_op| {
        const p = self.pending;
        self.pending = .{};
        if (pending_op != op) return;
        const line = self.buffer.lineOf(self.cursor);
        return self.operateLines(op, line, line + @max(p.count, 1) * @max(p.op_count, 1) - 1);
    }
    self.pending.op = op;
}

/// x, X, s, D, C: an operator with a fixed motion. In visual mode they act on
/// the selection (D, C and X on whole lines).
fn shortcut(self: *Editor, op: Op, m: Motion, count: usize) !void {
    if (self.mode == .visual) {
        if (m != .right) self.visual_kind = .line;
        return self.visualOperator(op);
    }
    self.pending = .{ .count = count, .op = op };
    try self.doMotion(m);
}

/// S and Y: an operator on [count] lines (or the selected lines).
fn lineShortcut(self: *Editor, op: Op, n: usize) !void {
    if (self.mode == .visual) {
        self.visual_kind = .line;
        return self.visualOperator(op);
    }
    const line = self.buffer.lineOf(self.cursor);
    try self.operateLines(op, line, line + n - 1);
}

fn openLine(self: *Editor, above: bool) !void {
    const line = self.buffer.lineOf(self.cursor);
    if (above) {
        self.cursor = self.buffer.lineStart(line);
        try self.insertAtCursor("\n");
        self.cursor -= 1;
    } else {
        self.cursor = self.lineEnd(line);
        try self.insertAtCursor("\n");
    }
    self.mode = .insert;
}

// ---------------------------------------------------------------------------
// Motions

const Motion = union(enum) {
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
    find: struct { kind: motion.FindKind, target: u21, repeat: bool },
    /// ; (false) and , (true).
    repeat_find: bool,
    /// n (false) and N (true).
    search_next: bool,
};

fn motionFor(key: Key) ?Motion {
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

const Target = struct {
    pos: usize,
    kind: enum { exclusive, inclusive, linewise },
    /// How the column j/k aim for changes: to the new column, unchanged, or
    /// to the end of every line ($).
    want: enum { update, keep, end } = .update,
};

/// Lines of the buffer for `motion`.
const Lines = struct {
    ed: *Editor,
    pub fn count(self: Lines) usize {
        return self.ed.buffer.visibleLineCount();
    }
    pub fn get(self: Lines, line: usize) ![]const u8 {
        return self.ed.lineText(line);
    }
};

fn toOffset(self: *Editor, p: motion.Pos) usize {
    return self.buffer.lineStart(p.line) + p.byte;
}

fn toPos(self: *Editor, offset: usize) motion.Pos {
    const line = self.buffer.lineOf(offset);
    return .{ .line = line, .byte = offset - self.buffer.lineStart(line) };
}

/// Runs a motion with the pending count: moves the cursor, or applies the
/// pending operator to the text moved over.
fn doMotion(self: *Editor, m: Motion) !void {
    const p = self.pending;
    self.pending = .{};
    const count = @max(p.count, 1) * @max(p.op_count, 1);
    const has_count = p.count > 0 or p.op_count > 0;
    const target = (try self.motionTarget(m, count, has_count, p.op)) orelse return;
    if (p.op) |op| return self.applyOperator(op, target);
    try self.moveTo(target);
}

fn moveTo(self: *Editor, target: Target) !void {
    const line = self.buffer.lineOf(target.pos);
    const start = self.buffer.lineStart(line);
    const s = try self.lineText(line);
    self.cursor = start + @min(target.pos - start, self.maxByte(s));
    switch (target.want) {
        .update => try self.updateWantCol(),
        .keep => {},
        .end => self.want_col = std.math.maxInt(usize),
    }
}

/// Where motion `m` goes from the cursor, or null if it can't move.
fn motionTarget(self: *Editor, m: Motion, count: usize, has_count: bool, op: ?Op) !?Target {
    const here = self.toPos(self.cursor);
    const lines = self.buffer.visibleLineCount();
    const lv: Lines = .{ .ed = self };
    switch (m) {
        .left => {
            const s = try self.lineText(here.line);
            var b = here.byte;
            for (0..count) |_| if (b > 0) {
                b = prevChar(s, b);
            };
            if (b == here.byte) return null;
            return .{ .pos = self.cursor - (here.byte - b), .kind = .exclusive };
        },
        .right => {
            const s = try self.lineText(here.line);
            const limit = if (op != null) s.len else self.maxByte(s);
            var b = here.byte;
            for (0..count) |_| {
                const n = nextChar(s, b);
                if (n > limit or n == b) break;
                b = n;
            }
            if (b == here.byte) return null;
            return .{ .pos = self.cursor + (b - here.byte), .kind = .exclusive };
        },
        .down, .up, .down_first_non_blank => {
            const line = if (m == .up) here.line -| count else @min(here.line + count, lines - 1);
            if (line == here.line) return null;
            const s = try self.lineText(line);
            if (m == .down_first_non_blank) {
                return .{ .pos = self.buffer.lineStart(line) + firstNonBlank(s), .kind = .linewise };
            }
            const b = @min(byteAtCol(s, self.want_col), self.maxByte(s));
            return .{ .pos = self.buffer.lineStart(line) + b, .kind = .linewise, .want = .keep };
        },
        .line_start => return .{ .pos = self.buffer.lineStart(here.line), .kind = .exclusive },
        .first_non_blank => {
            const s = try self.lineText(here.line);
            return .{ .pos = self.buffer.lineStart(here.line) + firstNonBlank(s), .kind = .exclusive };
        },
        .line_end => {
            const line = @min(here.line + count - 1, lines - 1);
            const s = try self.lineText(line);
            const start = self.buffer.lineStart(line);
            if (op != null) {
                if (s.len == 0) return .{ .pos = start, .kind = .exclusive, .want = .end };
                return .{ .pos = start + prevChar(s, s.len), .kind = .inclusive, .want = .end };
            }
            return .{ .pos = start + self.maxByte(s), .kind = .inclusive, .want = .end };
        },
        .word_forward => |big| {
            if (op == .change and !try self.onBlank(here)) {
                // cw changes to the end of the word, not up to the next one.
                const p = try motion.changeWordEnd(lv, here, count, big);
                return .{ .pos = self.toOffset(p), .kind = .inclusive };
            }
            var p = here;
            var prev = here;
            for (0..count) |_| {
                prev = p;
                p = try motion.wordForward(lv, p, big);
            }
            // An operator on the last word of a line stops at the line's end
            // instead of reaching into the next line.
            if (op != null and p.line > prev.line) {
                p = .{ .line = prev.line, .byte = (try self.lineText(prev.line)).len };
            }
            if (p.line == here.line and p.byte == here.byte) return null;
            return .{ .pos = self.toOffset(p), .kind = .exclusive };
        },
        .word_end => |big| {
            var p = here;
            for (0..count) |_| p = try motion.wordEnd(lv, p, big);
            if (p.line == here.line and p.byte == here.byte) return null;
            return .{ .pos = self.toOffset(p), .kind = .inclusive };
        },
        .word_backward => |big| {
            var p = here;
            for (0..count) |_| p = try motion.wordBackward(lv, p, big);
            if (p.line == here.line and p.byte == here.byte) return null;
            return .{ .pos = self.toOffset(p), .kind = .exclusive };
        },
        .file_start, .file_end => {
            const line = if (has_count) @min(count, lines) - 1 else if (m == .file_start) 0 else lines - 1;
            const s = try self.lineText(line);
            return .{ .pos = self.buffer.lineStart(line) + firstNonBlank(s), .kind = .linewise };
        },
        .half_page_down, .half_page_up => {
            const amount = if (has_count) count else @max(1, self.view_rows / 2);
            const line = if (m == .half_page_up) here.line -| amount else @min(here.line + amount, lines - 1);
            if (line == here.line) return null;
            // The view scrolls by the same amount.
            if (m == .half_page_up) {
                self.top -|= amount;
            } else {
                self.top = @min(self.top + amount, lines - 1);
            }
            const s = try self.lineText(line);
            const b = @min(byteAtCol(s, self.want_col), self.maxByte(s));
            return .{ .pos = self.buffer.lineStart(line) + b, .kind = .linewise, .want = .keep };
        },
        .find => |f| return self.findTarget(here, f.kind, f.target, count, f.repeat),
        .repeat_find => |reverse| {
            const last = self.last_find orelse return null;
            const kind = if (reverse) last.kind.reversed() else last.kind;
            return self.findTarget(here, kind, last.target, count, true);
        },
        .search_next => |reverse| {
            if (self.last_search.items.len == 0) {
                self.setMessage(true, "E35: No previous regular expression", .{});
                return null;
            }
            const forward = self.last_search_forward != reverse;
            var pos = self.cursor;
            for (0..count) |_| {
                pos = try self.search(pos, forward) orelse {
                    self.setMessage(true, "E486: Pattern not found: {s}", .{self.last_search.items});
                    return null;
                };
            }
            return .{ .pos = pos, .kind = .exclusive };
        },
    }
}

fn findTarget(self: *Editor, here: motion.Pos, kind: motion.FindKind, target: u21, count: usize, repeat: bool) !?Target {
    const s = try self.lineText(here.line);
    const b = motion.findInLine(s, here.byte, kind, target, count, repeat) orelse return null;
    return .{
        .pos = self.buffer.lineStart(here.line) + b,
        .kind = if (kind.isForward()) .inclusive else .exclusive,
    };
}

fn onBlank(self: *Editor, p: motion.Pos) !bool {
    const s = try self.lineText(p.line);
    return p.byte >= s.len or s[p.byte] == ' ' or s[p.byte] == '\t';
}

// ---------------------------------------------------------------------------
// Operators

fn applyOperator(self: *Editor, op: Op, target: Target) !void {
    const a = @min(self.cursor, target.pos);
    var b = @max(self.cursor, target.pos);
    if (target.kind == .linewise or op == .indent or op == .outdent) {
        return self.operateLines(op, self.buffer.lineOf(a), self.buffer.lineOf(b));
    }
    switch (target.kind) {
        .inclusive => b = try self.afterChar(b),
        .exclusive => {
            // Ending at the very start of a later line stops at the end of
            // the line before it, so the line break isn't included.
            const lb = self.buffer.lineOf(b);
            if (b > a and lb > self.buffer.lineOf(a) and b == self.buffer.lineStart(lb)) {
                b = self.lineEnd(lb - 1);
            }
        },
        .linewise => unreachable,
    }
    try self.operateChars(op, a, b);
}

/// Offset just past the character at `offset` (past the newline at a line end).
fn afterChar(self: *Editor, offset: usize) !usize {
    if (offset >= self.buffer.len) return self.buffer.len;
    const p = self.toPos(offset);
    const s = try self.lineText(p.line);
    if (p.byte < s.len) return offset + nextChar(s, p.byte) - p.byte;
    return offset + 1;
}

/// Applies `op` to the bytes [a, b).
fn operateChars(self: *Editor, op: Op, a: usize, b: usize) !void {
    try self.setRegister(.char, a, b);
    switch (op) {
        .yank => {
            self.clipboard_pending = true;
            self.cursor = a;
            try self.clampCursor();
        },
        .delete => {
            try self.deleteBytes(a, b - a);
            self.cursor = a;
            try self.clampCursor();
        },
        .change => {
            try self.deleteBytes(a, b - a);
            self.cursor = a;
            self.mode = .insert;
            try self.updateWantCol();
        },
        .indent, .outdent => unreachable,
    }
}

/// Applies `op` to whole lines `first` through `last` (clamped to the text).
fn operateLines(self: *Editor, op: Op, first: usize, last_wanted: usize) !void {
    const lines = self.buffer.visibleLineCount();
    const last = @min(last_wanted, lines - 1);
    const n = last - first + 1;
    const start = self.buffer.lineStart(first);
    const end = if (last + 1 < lines) self.buffer.lineStart(last + 1) else self.buffer.len;
    switch (op) {
        .yank => {
            try self.setLineRegister(start, end);
            self.clipboard_pending = true;
            if (self.buffer.lineOf(self.cursor) != first) {
                const s = try self.lineText(first);
                self.cursor = start + @min(byteAtCol(s, self.want_col), self.maxByte(s));
            }
            if (n > 2) self.setMessage(false, "{d} lines yanked", .{n});
        },
        .delete => {
            try self.setLineRegister(start, end);
            try self.deleteBytes(start, end - start);
            const line = @min(first, self.buffer.visibleLineCount() - 1);
            self.cursor = self.buffer.lineStart(line) + firstNonBlank(try self.lineText(line));
            try self.clampCursor();
            if (n > 2) self.setMessage(false, "{d} fewer lines", .{n});
        },
        .change => {
            try self.setLineRegister(start, end);
            try self.deleteBytes(start, self.lineEnd(last) - start);
            self.cursor = start;
            self.mode = .insert;
            try self.updateWantCol();
        },
        .indent, .outdent => {
            for (first..last + 1) |line| {
                const s = try self.lineText(line);
                const line_start = self.buffer.lineStart(line);
                if (op == .indent) {
                    if (s.len > 0) try self.insertBytes(line_start, "\t");
                } else {
                    var k: usize = 0;
                    if (s.len > 0 and s[0] == '\t') {
                        k = 1;
                    } else while (k < s.len and k < text.tab_width and s[k] == ' ') k += 1;
                    try self.deleteBytes(line_start, k);
                }
            }
            self.cursor = self.buffer.lineStart(first) + firstNonBlank(try self.lineText(first));
            try self.clampCursor();
            if (n > 2) self.setMessage(false, "{d} lines {s}ed 1 time", .{ n, if (op == .indent) ">" else "<" });
        },
    }
}

fn setRegister(self: *Editor, kind: @FieldType(Register, "kind"), a: usize, b: usize) !void {
    try self.register.text.resize(self.gpa, b - a);
    self.buffer.read(a, self.register.text.items);
    self.register.kind = kind;
}

/// Puts lines [start, end) in the register, making sure they end in a newline.
fn setLineRegister(self: *Editor, start: usize, end: usize) !void {
    try self.setRegister(.line, start, end);
    const t = self.register.text.items;
    if (t.len == 0 or t[t.len - 1] != '\n') try self.register.text.append(self.gpa, '\n');
}

/// p and P: pastes the register `n` times after or before the cursor (or,
/// for lines, below or above the cursor's line).
fn paste(self: *Editor, before: bool, n: usize) Allocator.Error!void {
    if (self.mode == .visual) return self.pasteOverSelection();
    if (self.register.text.items.len == 0) return;
    const reg = try self.gpa.dupe(u8, self.register.text.items);
    defer self.gpa.free(reg);
    switch (self.register.kind) {
        .char => {
            const p = self.toPos(self.cursor);
            const s = try self.lineText(p.line);
            const pos = if (before or s.len == 0) self.cursor else self.cursor + nextChar(s, p.byte) - p.byte;
            self.cursor = pos;
            for (0..n) |_| try self.insertAtCursor(reg);
            // On the last pasted character; at the start of multi-line text.
            if (std.mem.indexOfScalar(u8, reg, '\n') != null) {
                self.cursor = pos;
            } else {
                self.cursor -= reg.len - text.prevStart(reg, reg.len);
            }
            try self.clampCursor();
        },
        .line => {
            const line = self.buffer.lineOf(self.cursor);
            const lines = self.buffer.visibleLineCount();
            var first_new = line;
            if (before) {
                const pos = self.buffer.lineStart(line);
                for (0..n) |_| try self.insertBytes(pos, reg);
            } else if (line + 1 < lines) {
                const pos = self.buffer.lineStart(line + 1);
                for (0..n) |_| try self.insertBytes(pos, reg);
                first_new = line + 1;
            } else {
                // Below the last line: make sure it ends in a newline first.
                if (!self.endsWithNewline()) try self.insertBytes(self.buffer.len, "\n");
                for (0..n) |_| try self.insertBytes(self.buffer.len, reg);
                first_new = line + 1;
            }
            self.cursor = self.buffer.lineStart(first_new) + firstNonBlank(try self.lineText(first_new));
            try self.clampCursor();
            const added = n * std.mem.count(u8, reg, "\n");
            if (added > 2) self.setMessage(false, "{d} more lines", .{added});
        },
        .block => try self.pasteBlock(reg, before, n),
    }
}

fn endsWithNewline(self: *Editor) bool {
    if (self.buffer.len == 0) return false;
    var it = self.buffer.chunksFrom(self.buffer.len - 1);
    return it.next().?[0] == '\n';
}

/// J: joins `n` lines (at least two) into one, with a space between where
/// needed and the next line's indent removed.
fn joinLines(self: *Editor, n_wanted: usize) !void {
    var first = self.buffer.lineOf(self.cursor);
    var n = @max(n_wanted, 2);
    if (self.mode == .visual) {
        const a = self.buffer.lineOf(@min(self.visual_anchor, self.cursor));
        const b = self.buffer.lineOf(@max(self.visual_anchor, self.cursor));
        first = a;
        n = @max(b - a + 1, 2);
        self.mode = .normal;
    }
    const lines = self.buffer.visibleLineCount();
    if (first + 1 >= lines) return;
    const joins = @min(n - 1, lines - 1 - first);
    var join_at: usize = 0;
    for (0..joins) |_| {
        const cur = try self.gpa.dupe(u8, try self.lineText(first));
        defer self.gpa.free(cur);
        const next = try self.lineText(first + 1);
        const indent = firstNonBlank(next);
        const rest_empty = indent == next.len;
        const needs_space = !rest_empty and cur.len > 0 and
            cur[cur.len - 1] != ' ' and cur[cur.len - 1] != '\t' and next[indent] != ')';
        join_at = self.lineEnd(first);
        try self.deleteBytes(join_at, 1 + indent);
        if (needs_space) try self.insertBytes(join_at, " ");
    }
    self.cursor = join_at;
    try self.clampCursor();
}

/// r: replaces [count] characters under the cursor with the typed one.
/// r Enter replaces them with a single line break.
fn replaceChars(self: *Editor, key: Key) !void {
    const n = @max(self.pending.count, 1);
    self.pending = .{};
    const c: u21 = if (key == .enter) '\n' else keyChar(key) orelse return;
    if (self.mode == .visual) return; // not supported on a selection
    const p = self.toPos(self.cursor);
    const s = try self.lineText(p.line);
    var end = p.byte;
    for (0..n) |_| {
        if (end >= s.len) return;
        end = nextChar(s, end);
    }
    try self.deleteBytes(self.cursor, end - p.byte);
    if (c == '\n') {
        try self.insertBytes(self.cursor, "\n");
        self.cursor += 1;
    } else {
        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(c, &bytes) catch return;
        for (0..n) |_| try self.insertBytes(self.cursor, bytes[0..len]);
        self.cursor += (n - 1) * len;
    }
    try self.clampCursor();
}

/// `.`: replays the keys of the last change, with `count` replacing its count.
fn repeatLastChange(self: *Editor, count: usize) Allocator.Error!void {
    self.dot.excluded = true;
    if (self.dot.last.items.len == 0) return;
    const keys = try self.gpa.dupe(Key, self.dot.last.items);
    defer self.gpa.free(keys);
    var start: usize = 0;
    if (count > 0) {
        while (start < keys.len and isCountKey(keys[start], start == 0)) start += 1;
    }
    self.dot.replaying = true;
    defer self.dot.replaying = false;
    if (count > 0) {
        var digits: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&digits, "{d}", .{count}) catch unreachable;
        for (s) |d| _ = try self.handleKey(.{ .char = d });
    }
    for (keys[start..]) |k| _ = try self.handleKey(k);
}

fn isCountKey(key: Key, first: bool) bool {
    if (key != .char) return false;
    return (key.char >= '1' and key.char <= '9') or (!first and key.char == '0');
}

// ---------------------------------------------------------------------------
// Visual mode

fn toggleVisual(self: *Editor, kind: VisualKind) !void {
    if (self.mode == .visual) {
        if (self.visual_kind == kind) return self.leaveVisual();
        self.visual_kind = kind;
        return;
    }
    self.mode = .visual;
    self.visual_kind = kind;
    self.visual_anchor = self.cursor;
}

fn leaveVisual(self: *Editor) !void {
    self.mode = .normal;
    try self.clampCursor();
}

/// An operator on the selection.
fn visualOperator(self: *Editor, op: Op) !void {
    const a = @min(self.visual_anchor, self.cursor);
    const b = @max(self.visual_anchor, self.cursor);
    self.mode = .normal;
    switch (self.visual_kind) {
        .char => {
            if (op == .indent or op == .outdent) {
                return self.operateLines(op, self.buffer.lineOf(a), self.buffer.lineOf(b));
            }
            try self.operateChars(op, a, try self.afterChar(b));
        },
        .line => try self.operateLines(op, self.buffer.lineOf(a), self.buffer.lineOf(b)),
        .block => try self.blockOperator(op),
    }
}

/// p in visual mode: replaces the selection with the register; the replaced
/// text goes into the register.
fn pasteOverSelection(self: *Editor) Allocator.Error!void {
    if (self.register.text.items.len == 0) return self.leaveVisual();
    const saved_text = try self.gpa.dupe(u8, self.register.text.items);
    defer self.gpa.free(saved_text);
    const saved_kind = self.register.kind;
    const kind = self.visual_kind;
    const start = @min(self.visual_anchor, self.cursor);
    const at_end = kind == .line and self.buffer.lineOf(@max(self.visual_anchor, self.cursor)) + 1 >= self.buffer.visibleLineCount();
    try self.visualOperator(.delete);
    const replaced = try self.gpa.dupe(u8, self.register.text.items);
    defer self.gpa.free(replaced);
    const replaced_kind = self.register.kind;

    self.register.text.clearRetainingCapacity();
    try self.register.text.appendSlice(self.gpa, saved_text);
    self.register.kind = saved_kind;
    // Deleting up to the end of a line, or the last lines, leaves the cursor
    // before where the selection was, so the text goes after it.
    const after = if (kind == .line) at_end and saved_kind == .line else self.cursor != start;
    try self.paste(!after, 1);

    self.register.text.clearRetainingCapacity();
    try self.register.text.appendSlice(self.gpa, replaced);
    self.register.kind = replaced_kind;
}

// Block (Ctrl-V) selections are completed in the next step.
fn blockColumns(self: *Editor) !struct { start: usize, end: usize } {
    _ = self;
    return .{ .start = 0, .end = 0 };
}
fn blockOperator(self: *Editor, op: Op) !void {
    _ = op;
    try self.leaveVisual();
}
fn blockInsert(self: *Editor, append: bool) !void {
    _ = append;
    try self.leaveVisual();
}
fn swapBlockCorner(self: *Editor) !void {
    std.mem.swap(usize, &self.visual_anchor, &self.cursor);
    try self.updateWantCol();
}
fn pasteBlock(self: *Editor, reg: []const u8, before: bool, n: usize) !void {
    _ = reg;
    _ = before;
    _ = n;
    _ = self;
}

// ---------------------------------------------------------------------------
// Insert mode

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
            const p = self.toPos(self.cursor);
            if (p.byte > 0) self.cursor -= p.byte - prevChar(try self.lineText(p.line), p.byte);
            self.mode = .normal;
            try self.clampCursor();
        },
        else => if (motionFor(key)) |m| {
            if (m == .left or m == .right or m == .down or m == .up or m == .line_start or m == .line_end) {
                if (try self.motionTarget(m, 1, false, null)) |target| try self.moveTo(target);
            }
        },
    }
}

/// Inserts `bytes` at the cursor and moves the cursor past them.
fn insertAtCursor(self: *Editor, bytes: []const u8) !void {
    // At the very end of text without a final newline, a newline would only
    // terminate the last line; a second one makes the new, empty line real.
    const ends_line = self.cursor == self.buffer.len and bytes[bytes.len - 1] == '\n';
    try self.insertBytes(self.cursor, bytes);
    if (ends_line) try self.insertBytes(self.cursor + bytes.len, "\n");
    self.cursor += bytes.len;
    try self.updateWantCol();
}

/// Deletes the character under the cursor. In insert mode at the end of a
/// line, joins the next line onto this one instead.
fn deleteUnderCursor(self: *Editor) !void {
    const pos = try self.cursorPos();
    const s = try self.lineText(pos.line);
    if (pos.byte < s.len) {
        try self.deleteBytes(self.cursor, nextChar(s, pos.byte) - pos.byte);
    } else if (pos.line + 1 < self.buffer.visibleLineCount()) {
        try self.deleteBytes(self.cursor, 1);
    } else return;
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
        try self.deleteBytes(self.cursor, n);
    } else if (pos.line > 0) {
        self.cursor -= 1;
        try self.deleteBytes(self.cursor, 1);
    } else return;
    try self.updateWantCol();
}

// ---------------------------------------------------------------------------
// Cursor and view

/// Keeps the cursor within its line after an edit or mode change.
fn clampCursor(self: *Editor) !void {
    self.cursor = @min(self.cursor, self.buffer.len);
    const line = @min(self.buffer.lineOf(self.cursor), self.buffer.visibleLineCount() - 1);
    const start = self.buffer.lineStart(line);
    const s = try self.lineText(line);
    self.cursor = start + @min(self.cursor -| start, self.maxByte(s));
    try self.updateWantCol();
}

fn updateWantCol(self: *Editor) !void {
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
fn maxByte(self: *const Editor, s: []const u8) usize {
    return switch (self.mode) {
        .normal, .command, .visual => if (s.len == 0) 0 else prevChar(s, s.len),
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
    self.buffer.read(start, self.line_buf.items);
    return self.line_buf.items;
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
    try testing.expect(e.isModified());
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
    try testing.expect(!e.isModified());
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

fn expectRegister(e: *Editor, kind: @FieldType(Register, "kind"), expected: []const u8) !void {
    try testing.expectEqual(kind, e.register.kind);
    try testing.expectEqualStrings(expected, e.register.text.items);
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

test "search with / and ?, n and N, wrapping around" {
    var e = try testEditor("foo bar\nbaz foo\nfoo\n");
    defer e.deinit();
    try typeKeys(&e, "/foo\r");
    try expectCursor(&e, 1, 4);
    try typeKeys(&e, "n");
    try expectCursor(&e, 2, 0);
    try typeKeys(&e, "n");
    try expectCursor(&e, 0, 0);
    try testing.expectEqualStrings("search hit BOTTOM, continuing at TOP", e.message.text());
    try typeKeys(&e, "N");
    try expectCursor(&e, 2, 0);
    try typeKeys(&e, "?ba\r");
    try expectCursor(&e, 1, 0);
    try typeKeys(&e, "/nope\r");
    try expectCursor(&e, 1, 0);
    try testing.expectEqualStrings("E486: Pattern not found: nope", e.message.text());
}

test "search as the motion of an operator" {
    var e = try testEditor("delete up to here: keep\n");
    defer e.deinit();
    try typeKeys(&e, "d/keep\r");
    try expectText(&e, "keep\n");
}

test ". repeats the last change, with a new count" {
    var e = try testEditor("a b c d e f\n");
    defer e.deinit();
    try typeKeys(&e, "dw");
    try typeKeys(&e, ".");
    try expectText(&e, "c d e f\n");
    try typeKeys(&e, "2.");
    try expectText(&e, "e f\n");
    try typeThenEscape(&e, "A!");
    try typeKeys(&e, "j."); // no line below: j fails, but . still appends
    try expectText(&e, "e f!!\n");
    try typeKeys(&e, "u");
    try expectText(&e, "e f!\n");
}

test ". does not repeat motions, undo or yanks" {
    var e = try testEditor("abc\n");
    defer e.deinit();
    try typeKeys(&e, "x");
    try typeKeys(&e, "lyyu"); // u undoes the x
    try typeKeys(&e, ".");
    try expectText(&e, "bc\n");
}

test "visual mode: v selects characters, y d c act on them" {
    var e = try testEditor("hello world\n");
    defer e.deinit();
    try typeKeys(&e, "vey");
    try expectRegister(&e, .char, "hello");
    try testing.expectEqual(Mode.normal, e.mode);
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
    try testing.expectEqual(Mode.normal, e.mode);
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
