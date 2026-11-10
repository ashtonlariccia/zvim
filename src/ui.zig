//! Frame rendering. Draws a full frame into a writer; the caller flushes.
//!
//! Terminals don't all agree on how wide a character is (combining marks,
//! emoji and "ambiguous" characters vary). Every row is positioned explicitly,
//! and after any non-ASCII character the cursor is moved to the column zvim
//! expects, so a disagreement stays within that one character instead of
//! shifting the rest of the line or spilling onto the next row.
//!
//! Writing the last column of a row leaves the cursor *on* that column (the
//! terminal wraps only when the next character arrives). Erasing to the end
//! of the row from there would erase that last character, so rows are only
//! erased when they end short of the right edge.

const std = @import("std");
const Size = @import("term.zig").Size;
const Buffer = @import("Buffer.zig");
const text = @import("text.zig");

const sync_begin = "\x1b[?2026h"; // synchronized output: no tearing mid-frame
const sync_end = "\x1b[?2026l";
const reverse = "\x1b[7m";
const reset = "\x1b[m";
const red = "\x1b[31m";
const dim = "\x1b[90m"; // grey: line numbers other than the cursor's
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";

/// What to show.
pub const View = struct {
    buffer: *const Buffer,
    /// Shown in the status line.
    name: []const u8,
    /// First visible line (0-based).
    top: usize,
    /// First visible display column (0-based); scrolls long lines sideways.
    left: usize = 0,
    /// Cursor line and display column (0-based).
    cursor: Cursor = .{},
    cursor_shape: CursorShape = .block,
    /// Shown after the name, e.g. "-- INSERT --".
    mode: []const u8 = "",
    /// Unsaved changes, shown as [+].
    modified: bool = false,
    /// Windows line endings, shown as [CRLF].
    crlf: bool = false,
    /// The file can't be written, shown as [RO].
    readonly: bool = false,
    /// When set, the bottom row is a command line showing ':' and this text,
    /// with the cursor at its end.
    command: ?[]const u8 = null,
    /// When set (and not in command mode), shown instead of the status bar.
    message: ?Message = null,
    /// Shown before the command text: ':' or a search's '/' or '?'.
    command_prefix: u8 = ':',
    /// The visual selection, drawn in reverse video.
    selection: ?Selection = null,
    /// Line numbers down the left.
    numbers: Numbers = .none,
};

pub const Numbers = enum {
    none,
    /// Each line's own number.
    absolute,
    /// Each line's distance from the cursor's line.
    relative,
    /// Distances, with the cursor's line showing its own number.
    both,
};

/// Screen columns taken by line numbers: room for the largest number (at
/// least 3 digits) and a space.
fn gutterWidth(numbers: Numbers, line_count: usize) usize {
    if (numbers == .none) return 0;
    var digits: usize = 1;
    var n = line_count;
    while (n >= 10) : (n /= 10) digits += 1;
    return @max(3, digits) + 1;
}

pub const Selection = struct {
    kind: enum { char, line, block },
    first_line: usize,
    last_line: usize,
    /// Char: display column where the selection starts on the first line and
    /// ends (exclusive) on the last. Block: the column range on every line.
    start_col: usize = 0,
    end_col: usize = 0,

    fn highlight(s: Selection, line: usize) Highlight {
        if (line < s.first_line or line > s.last_line) return .{};
        const all = std.math.maxInt(usize);
        return switch (s.kind) {
            .line => .{ .from = 0, .to = all, .line_end = true },
            .block => .{ .from = s.start_col, .to = s.end_col },
            .char => .{
                .from = if (line == s.first_line) s.start_col else 0,
                .to = if (line == s.last_line) s.end_col else all,
                .line_end = line != s.last_line,
                .end_if_covered = true,
            },
        };
    }
};

/// Display columns of a line drawn in reverse video.
const Highlight = struct {
    from: usize = 0,
    to: usize = 0,
    /// Show a selected line break as one reversed cell after the text.
    line_end: bool = false,
    /// Show that cell also when the range covers the end of the line.
    end_if_covered: bool = false,

    fn covers(h: Highlight, col: usize) bool {
        return col >= h.from and col < h.to;
    }
};

pub const Message = struct { text: []const u8, is_error: bool };

pub const Cursor = struct { line: usize = 0, col: usize = 0 };

pub const CursorShape = enum {
    block,
    bar,

    fn sequence(shape: CursorShape) []const u8 {
        return switch (shape) {
            .block => "\x1b[2 q",
            .bar => "\x1b[6 q",
        };
    }
};

/// Draws the visible lines of the buffer, with `~` past the end of the text,
/// a status bar in the bottom row, and the cursor.
pub fn draw(w: *std.Io.Writer, size: Size, view: View) !void {
    try w.writeAll(sync_begin ++ hide_cursor);
    defer w.writeAll(sync_end) catch {};

    const cols: usize = size.cols;
    const lines = view.buffer.visibleLineCount();
    const gutter = textGutter(size, view.numbers, lines);

    for (0..textRows(size)) |r| {
        try w.print("\x1b[{d};1H", .{r + 1});
        const line = view.top + r;
        var used: usize = 0;
        if (line < lines) {
            if (gutter > 0) {
                const here = line == view.cursor.line;
                const number = switch (view.numbers) {
                    .none => unreachable,
                    .absolute => line + 1,
                    .relative => if (line > view.cursor.line) line - view.cursor.line else view.cursor.line - line,
                    .both => if (here) line + 1 else if (line > view.cursor.line) line - view.cursor.line else view.cursor.line - line,
                };
                if (!here) try w.writeAll(dim);
                try w.print("{d: >[1]} ", .{ number, gutter - 1 });
                if (!here) try w.writeAll(reset);
            }
            var chars = lineChars(view.buffer, line);
            const hl: Highlight = if (view.selection) |sel| sel.highlight(line) else .{};
            used = gutter + try drawCharsHighlighted(w, &chars, view.left, cols - gutter, hl, gutter);
        } else if (cols > 0) {
            try w.writeAll("~");
            used = 1;
        }
        if (used < cols) try w.writeAll("\x1b[K");
    }

    if (size.rows >= 2) {
        try w.print("\x1b[{d};1H", .{size.rows});
        if (view.command) |command| {
            // ':' and the text, scrolled so the cursor after them stays visible.
            var chars: SliceChars = .{ .bytes = command };
            const width = 1 + try drawChars(null, &chars, 0, std.math.maxInt(usize));
            const hidden = (width + 1) -| cols; // columns scrolled off the left
            const colon: usize = if (hidden == 0) 1 else 0;
            if (colon == 1) try w.writeAll(&.{view.command_prefix});
            chars = .{ .bytes = command };
            const used = colon + try drawChars(w, &chars, hidden -| 1, cols - colon);
            if (used < cols) try w.writeAll("\x1b[K");
            try w.print("\x1b[{d};{d}H", .{ size.rows, width - hidden + 1 });
            try w.writeAll(CursorShape.bar.sequence());
            try w.writeAll(show_cursor);
            return;
        } else if (view.message) |message| {
            var chars: SliceChars = .{ .bytes = message.text };
            if (message.is_error) try w.writeAll(red);
            const used = try drawChars(w, &chars, 0, cols);
            if (message.is_error) try w.writeAll(reset);
            if (used < cols) try w.writeAll("\x1b[K");
        } else {
            try drawStatus(w, size, view);
        }
    }

    // Show the cursor only when it is on screen.
    const c = view.cursor;
    if (c.line >= view.top and c.line - view.top < textRows(size) and
        c.col >= view.left and c.col - view.left < cols - gutter)
    {
        try w.print("\x1b[{d};{d}H", .{ c.line - view.top + 1, gutter + c.col - view.left + 1 });
        try w.writeAll(view.cursor_shape.sequence());
        try w.writeAll(show_cursor);
    }
}

/// Screen columns taken by line numbers, if the window is wide enough to
/// show them and some text.
fn textGutter(size: Size, numbers: Numbers, line_count: usize) usize {
    const gutter = gutterWidth(numbers, line_count);
    return if (gutter < size.cols) gutter else 0;
}

/// Screen columns left for text.
pub fn textCols(size: Size, numbers: Numbers, line_count: usize) usize {
    return size.cols - textGutter(size, numbers, line_count);
}

pub fn textRows(size: Size) usize {
    return if (size.rows >= 2) size.rows - 1 else size.rows;
}

/// File name and mode on the left, dimensions and cursor position on the
/// right, in reverse video across the whole row. When space is short the
/// right side shrinks first; the left side goes only if even that won't fit.
fn drawStatus(w: *std.Io.Writer, size: Size, view: View) !void {
    const cols: usize = size.cols;

    // The right side shrinks in stages until it fits.
    var bufs: [3][96]u8 = undefined;
    const stages = [_][]const u8{
        try std.fmt.bufPrint(&bufs[0], "{d}x{d}  Ln {d}  Col {d}", .{ size.cols, size.rows, view.cursor.line + 1, view.cursor.col + 1 }),
        try std.fmt.bufPrint(&bufs[1], "Ln {d}  Col {d}", .{ view.cursor.line + 1, view.cursor.col + 1 }),
        try std.fmt.bufPrint(&bufs[2], "Ln {d}", .{view.cursor.line + 1}),
    };
    var name_buf: [std.Io.Dir.max_path_bytes + 32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}{s}{s}{s}{s}", .{
        if (view.name.len > 0) view.name else "[new]",
        if (view.modified) " [+]" else "",
        if (view.readonly) " [RO]" else "",
        if (view.crlf) " [CRLF]" else "",
        if (view.mode.len > 0) "  " else "",
        view.mode,
    }) catch view.name;
    var name_chars: SliceChars = .{ .bytes = name };
    const name_cols = try drawChars(null, &name_chars, 0, cols);

    var show_name = false;
    var right: []const u8 = "";
    for (stages) |stage| if (1 + name_cols + 1 + stage.len + 1 <= cols) {
        show_name = true;
        right = stage;
        break;
    };
    if (!show_name) for (stages) |stage| if (stage.len <= cols) {
        right = stage;
        break;
    };
    const right_pad: usize = if (right.len < cols) 1 else 0;

    try w.writeAll(reverse);
    var used: usize = 0;
    if (show_name) {
        try w.writeAll(" ");
        name_chars = .{ .bytes = name };
        used = 1 + try drawChars(w, &name_chars, 0, name_cols);
    }
    try w.splatByteAll(' ', cols - used - right.len - right_pad);
    try w.writeAll(right);
    try w.splatByteAll(' ', right_pad);
    try w.writeAll(reset);
}

/// A decoded character along with its bytes.
const Glyph = struct {
    cp: u21,
    len: u3,
    bytes: [4]u8,

    fn raw(g: *const Glyph) []const u8 {
        return g.bytes[0..g.len];
    }
};

/// Characters of a byte slice.
const SliceChars = struct {
    bytes: []const u8,
    i: usize = 0,

    fn next(it: *SliceChars) ?Glyph {
        if (it.i >= it.bytes.len) return null;
        const ch = text.decode(it.bytes[it.i..]);
        var g: Glyph = .{ .cp = ch.cp, .len = ch.len, .bytes = undefined };
        @memcpy(g.bytes[0..ch.len], it.bytes[it.i..][0..ch.len]);
        it.i += ch.len;
        return g;
    }
};

/// Characters of one buffer line, read straight from the piece table. A
/// character split across two pieces is reassembled through a small window.
const BufferChars = struct {
    chunks: Buffer.ChunkIterator,
    cur: []const u8 = "",
    window: [4]u8 = undefined,
    window_len: usize = 0,

    fn next(it: *BufferChars) ?Glyph {
        while (it.window_len < 4) {
            if (it.cur.len == 0) it.cur = it.chunks.next() orelse break;
            it.window[it.window_len] = it.cur[0];
            it.window_len += 1;
            it.cur = it.cur[1..];
        }
        if (it.window_len == 0) return null;
        const ch = text.decode(it.window[0..it.window_len]);
        if (ch.cp == '\n') return null;
        const g: Glyph = .{ .cp = ch.cp, .len = ch.len, .bytes = it.window };
        std.mem.copyForwards(u8, &it.window, it.window[ch.len..it.window_len]);
        it.window_len -= ch.len;
        return g;
    }
};

fn lineChars(buffer: *const Buffer, line: usize) BufferChars {
    return .{ .chunks = buffer.chunksFrom(buffer.lineStart(line)) };
}

/// Writes the characters from `chars` that fall within display columns
/// [left, left + max_cols) as terminal-safe text, starting at screen column 1,
/// and returns the screen columns used. A character cut by either edge is
/// shown as blanks. With a null writer it only measures.
fn drawChars(w: ?*std.Io.Writer, chars: anytype, left: usize, max_cols: usize) !usize {
    return drawCharsHighlighted(w, chars, left, max_cols, .{}, 0);
}

/// `drawChars` with the columns in `hl` in reverse video, starting `origin`
/// columns from the left edge of the screen.
fn drawCharsHighlighted(w: ?*std.Io.Writer, chars: anytype, left: usize, max_cols: usize, hl: Highlight, origin: usize) !usize {
    const right = left + max_cols;
    var col: usize = 0; // display column in the line
    var used: usize = 0; // screen columns written
    // Set after a character whose width the terminal might see differently;
    // the cursor is re-synced before the next character that takes space.
    var resync = false;
    var drew_prev = false;
    var reversed = false;
    defer if (reversed) if (w) |out| out.writeAll(reset) catch {};
    const ended = while (chars.next()) |g| {
        if (col >= right) break false;
        const cw = text.cellWidth(g.cp, col);
        if (cw == 0) {
            // Combining mark: attaches to the previous character if it's shown.
            if (drew_prev) {
                if (w) |out| try out.writeAll(g.raw());
                resync = true;
            }
            continue;
        }
        const start = col;
        const end = col + cw;
        col = end;
        drew_prev = false;
        if (end <= left) continue;

        if (start < left or end > right) {
            // Cut by an edge. A tab is just spaces anyway; a wide or ^X
            // character at the right edge isn't shown at all.
            if (end > right and g.cp != '\t') break false;
            const vis_start = @max(start, left);
            const vis_end = @min(end, right);
            if (w) |out| {
                try setReverse(out, &reversed, hl.covers(start));
                if (resync) try out.print("\x1b[{d}G", .{origin + vis_start - left + 1});
                try out.splatByteAll(' ', vis_end - vis_start);
            }
            used = vis_end - left;
            resync = false;
            continue;
        }

        if (w) |out| {
            try setReverse(out, &reversed, hl.covers(start));
            if (resync) try out.print("\x1b[{d}G", .{origin + start - left + 1});
            if (g.cp == '\t') {
                try out.splatByteAll(' ', cw);
            } else if (g.cp < 0x20 or g.cp == 0x7f) {
                // Control characters would act on the terminal; show them as ^X.
                try out.writeAll(&.{ '^', @as(u8, @intCast(g.cp)) ^ 0x40 });
            } else if (text.isUnprintable(g.cp)) {
                try out.writeAll("\u{FFFD}");
            } else {
                try out.writeAll(g.raw());
            }
        }
        used = end - left;
        resync = g.cp >= 0x80;
        drew_prev = true;
    } else true;

    // A selected line break shows as one reversed cell after the text.
    if (ended and (hl.line_end or (hl.end_if_covered and hl.covers(col))) and col >= left and col < right) {
        if (w) |out| {
            try setReverse(out, &reversed, true);
            if (resync) try out.print("\x1b[{d}G", .{origin + col - left + 1});
            try out.writeAll(" ");
        }
        used = col - left + 1;
    }
    return used;
}

fn setReverse(out: *std.Io.Writer, on: *bool, want: bool) !void {
    if (on.* == want) return;
    try out.writeAll(if (want) reverse else reset);
    on.* = want;
}

/// A terminal model for tests: replays cursor movement and text from `out`
/// onto a grid. `termWidth` is the terminal's idea of character widths, which
/// may differ from zvim's. It follows xterm's last-column rule: writing the
/// last column leaves the cursor on it with a wrap pending; the next character
/// wraps to the next row, while cursor movement or erase cancels the wrap.
/// Scrolling off the bottom is an error. A wide character fills its first
/// cell and marks the second with 0; combining marks are dropped.
fn renderToGrid(
    out: []const u8,
    comptime rows: usize,
    comptime cols: usize,
    termWidth: *const fn (u21) u2,
) ![rows][cols]u21 {
    return (try renderToGridAttrs(out, rows, cols, termWidth)).chars;
}

/// `renderToGrid`, also recording which cells were written in reverse video.
fn renderToGridAttrs(
    out: []const u8,
    comptime rows: usize,
    comptime cols: usize,
    termWidth: *const fn (u21) u2,
) !struct { chars: [rows][cols]u21, reversed: [rows][cols]bool } {
    var grid: [rows][cols]u21 = @splat(@splat(' '));
    var rev: [rows][cols]bool = @splat(@splat(false));
    var reversed = false;
    var r: usize = 0;
    var c: usize = 0;
    var wrap_pending = false;
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == 0x1b) {
            // CSI: ESC [ params final
            var j = i + 2;
            while (out[j] < 0x40 or out[j] > 0x7e) j += 1;
            const params = out[i + 2 .. j];
            switch (out[j]) {
                'H' => {
                    var it = std.mem.splitScalar(u8, params, ';');
                    r = try std.fmt.parseInt(usize, it.next().?, 10) - 1;
                    c = try std.fmt.parseInt(usize, it.next().?, 10) - 1;
                    wrap_pending = false;
                },
                'G' => {
                    c = try std.fmt.parseInt(usize, params, 10) - 1;
                    wrap_pending = false;
                },
                'K' => {
                    for (grid[r][c..], rev[r][c..]) |*cell, *rv| {
                        cell.* = ' ';
                        rv.* = false;
                    }
                    wrap_pending = false;
                },
                'm' => reversed = std.mem.eql(u8, params, "7"),
                else => {},
            }
            i = j + 1;
            continue;
        }
        const len = try std.unicode.utf8ByteSequenceLength(out[i]);
        const cp = try std.unicode.utf8Decode(out[i .. i + len]);
        i += len;
        const cw = termWidth(cp);
        if (cw == 0) continue;
        if (wrap_pending or c + cw > cols) {
            r += 1;
            c = 0;
            wrap_pending = false;
            if (r == rows) return error.ScrolledOffScreen;
        }
        grid[r][c] = cp;
        rev[r][c] = reversed;
        if (cw == 2) {
            grid[r][c + 1] = 0;
            rev[r][c + 1] = reversed;
        }
        c += cw;
        if (c == cols) {
            c = cols - 1;
            wrap_pending = true;
        }
    }
    return .{ .chars = grid, .reversed = rev };
}

/// Which cells of the text rows are in reverse video, as '#' and '.'.
fn highlightMap(comptime rows: usize, comptime cols: usize, view: View) ![rows - 1][cols]u8 {
    var out: [64 * 1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try draw(&w, .{ .rows = rows, .cols = cols }, view);
    const g = try renderToGridAttrs(w.buffered(), rows, cols, &text.width);
    var map: [rows - 1][cols]u8 = undefined;
    for (0..rows - 1) |r| {
        for (0..cols) |c| map[r][c] = if (g.reversed[r][c]) '#' else '.';
    }
    return map;
}

/// Renders a frame and returns each screen row as a UTF-8 string, with
/// trailing spaces trimmed.
fn screen(
    comptime rows: usize,
    comptime cols: usize,
    view: View,
    termWidth: *const fn (u21) u2,
) ![rows][]const u8 {
    const S = struct {
        var out: [64 * 1024]u8 = undefined;
        var lines: [rows][cols * 4]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.out);
    try draw(&w, .{ .rows = rows, .cols = cols }, view);
    const grid = try renderToGrid(w.buffered(), rows, cols, termWidth);
    var result: [rows][]const u8 = undefined;
    for (grid, 0..) |line, r| {
        var n: usize = 0;
        for (line) |cp| {
            if (cp != 0) n += try std.unicode.utf8Encode(cp, S.lines[r][n..]);
        }
        result[r] = std.mem.trimEnd(u8, S.lines[r][0..n], " ");
    }
    return result;
}

const testing = std.testing;

fn expectScreen(comptime rows: usize, comptime cols: usize, view: View, expected: [rows][]const u8) !void {
    const got = try screen(rows, cols, view, &text.width);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "empty buffer shows tildes and a status bar" {
    var b: Buffer = try .init(testing.allocator, "");
    defer b.deinit();
    try expectScreen(4, 32, .{ .buffer = &b, .name = "", .top = 0 }, .{
        "",
        "~",
        "~",
        " [new]        32x4  Ln 1  Col 1",
    });
}

test "file text, clipped and scrolled" {
    var b: Buffer = try .init(testing.allocator, "first\nsecond line that is too long\nthird\n");
    defer b.deinit();
    try expectScreen(4, 32, .{ .buffer = &b, .name = "a.txt", .top = 0 }, .{
        "first",
        "second line that is too long",
        "third",
        " a.txt        32x4  Ln 1  Col 1",
    });
    try expectScreen(4, 32, .{ .buffer = &b, .name = "a.txt", .top = 2, .cursor = .{ .line = 2 } }, .{
        "third",
        "~",
        "~",
        " a.txt        32x4  Ln 3  Col 1",
    });
}

test "cursor is placed at its screen position, hidden when off screen" {
    var b: Buffer = try .init(testing.allocator, "abc\ndef\nghi\n");
    defer b.deinit();
    var buf: [4096]u8 = undefined;

    var w: std.Io.Writer = .fixed(&buf);
    try draw(&w, .{ .rows = 3, .cols = 10 }, .{ .buffer = &b, .name = "", .top = 1, .left = 1, .cursor = .{ .line = 2, .col = 2 }, .cursor_shape = .bar });
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "\x1b[2;2H\x1b[6 q" ++ show_cursor ++ sync_end));

    w = .fixed(&buf);
    try draw(&w, .{ .rows = 3, .cols = 10 }, .{ .buffer = &b, .name = "", .top = 1, .cursor = .{ .line = 0, .col = 0 } });
    try testing.expect(std.mem.indexOf(u8, w.buffered(), show_cursor) == null);
}

test "status bar shows the cursor position, unsaved changes and the mode" {
    var b: Buffer = try .init(testing.allocator, "abc\ndef\n");
    defer b.deinit();
    const view: View = .{ .buffer = &b, .name = "f", .top = 0, .cursor = .{ .line = 1, .col = 2 }, .modified = true, .mode = "-- INSERT --" };
    try expectScreen(3, 42, view, .{ "abc", "def", " f [+]  -- INSERT --    42x3  Ln 2  Col 3" });
    // Narrower: the size goes before the name and mode do.
    try expectScreen(3, 38, view, .{ "abc", "def", " f [+]  -- INSERT --      Ln 2  Col 3" });
}

test "command line and messages replace the status bar" {
    var b: Buffer = try .init(testing.allocator, "abc\n");
    defer b.deinit();
    try expectScreen(2, 20, .{ .buffer = &b, .name = "f", .top = 0, .command = "wq" }, .{ "abc", ":wq" });
    try expectScreen(2, 20, .{ .buffer = &b, .name = "f", .top = 0, .message = .{ .text = "E37: No write", .is_error = true } }, .{ "abc", "E37: No write" });

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try draw(&w, .{ .rows = 2, .cols = 20 }, .{ .buffer = &b, .name = "", .top = 0, .command = "wq" });
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "\x1b[2;4H\x1b[6 q" ++ show_cursor ++ sync_end));
}

test "a long command line scrolls to keep the cursor in view" {
    var b: Buffer = try .init(testing.allocator, "");
    defer b.deinit();
    try expectScreen(2, 8, .{ .buffer = &b, .name = "", .top = 0, .command = "w a_long_name" }, .{ "", "ng_name" });

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try draw(&w, .{ .rows = 2, .cols = 8 }, .{ .buffer = &b, .name = "", .top = 0, .command = "w a_long_name" });
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "\x1b[2;8H\x1b[6 q" ++ show_cursor ++ sync_end));
}

fn expectHighlight(comptime rows: usize, comptime cols: usize, view: View, expected: [rows - 1]*const [cols]u8) !void {
    const map = try highlightMap(rows, cols, view);
    for (expected, map) |e, m| try testing.expectEqualStrings(e, &m);
}

test "character selection: partial first and last lines, line breaks in between" {
    var b: Buffer = try .init(testing.allocator, "abcd\n\nefgh\n");
    defer b.deinit();
    const sel: Selection = .{ .kind = .char, .first_line = 0, .last_line = 2, .start_col = 2, .end_col = 2 };
    try expectHighlight(4, 6, .{ .buffer = &b, .name = "", .top = 0, .selection = sel }, .{
        "..###.", // "cd" and the line break
        "#.....", // an empty line inside the selection
        "##....", // "ef"
    });
}

test "line and block selections" {
    var b: Buffer = try .init(testing.allocator, "abcd\nab\nabcdef\n");
    defer b.deinit();
    try expectHighlight(4, 8, .{ .buffer = &b, .name = "", .top = 0, .selection = .{ .kind = .line, .first_line = 1, .last_line = 2 } }, .{
        "........",
        "###.....",
        "#######.",
    });
    try expectHighlight(4, 8, .{ .buffer = &b, .name = "", .top = 0, .selection = .{ .kind = .block, .first_line = 0, .last_line = 2, .start_col = 1, .end_col = 3 } }, .{
        ".##.....",
        ".#......", // short line: only what's there
        ".##.....",
    });
}

test "a selection ending on an empty last line shows its cell" {
    var b: Buffer = try .init(testing.allocator, "ab\n\n");
    defer b.deinit();
    const sel: Selection = .{ .kind = .char, .first_line = 0, .last_line = 1, .start_col = 1, .end_col = 1 };
    try expectHighlight(3, 4, .{ .buffer = &b, .name = "", .top = 0, .selection = sel }, .{ ".##.", "#..." });
}

test "a line that exactly fills the row keeps its last character" {
    var b: Buffer = try .init(testing.allocator, "abcdef\nxy");
    defer b.deinit();
    try expectScreen(3, 6, .{ .buffer = &b, .name = "", .top = 0 }, .{ "abcdef", "xy", " Ln 1" });
}

test "status bar fills the row exactly and drops what doesn't fit" {
    var b: Buffer = try .init(testing.allocator, "x");
    defer b.deinit();
    try expectScreen(2, 30, .{ .buffer = &b, .name = "name.txt", .top = 0 }, .{
        "x",
        " name.txt   30x2  Ln 1  Col 1",
    });
    try expectScreen(2, 22, .{ .buffer = &b, .name = "name.txt", .top = 0 }, .{
        "x",
        " name.txt Ln 1  Col 1",
    });
    try expectScreen(2, 16, .{ .buffer = &b, .name = "name.txt", .top = 0 }, .{
        "x",
        " name.txt  Ln 1",
    });
    try expectScreen(2, 8, .{ .buffer = &b, .name = "name.txt", .top = 0 }, .{
        "x",
        "   Ln 1",
    });
    try expectScreen(2, 3, .{ .buffer = &b, .name = "name.txt", .top = 0 }, .{ "x", "" });
}

test "tabs, control characters, invalid bytes and wide characters" {
    var b: Buffer = try .init(testing.allocator, "a\tb\n\x1b[2J\x7f\n\xff\xfeok\n中文x\n\u{301}e\u{301}");
    defer b.deinit();
    try expectScreen(6, 12, .{ .buffer = &b, .name = "", .top = 0 }, .{
        "a   b",
        "^[[2J^?",
        "\u{FFFD}\u{FFFD}ok",
        "中文x",
        "e",
        " [new] Ln 1",
    });
}

test "a wide character that would straddle the edge is left out" {
    var b: Buffer = try .init(testing.allocator, "abc中");
    defer b.deinit();
    try expectScreen(2, 4, .{ .buffer = &b, .name = "", .top = 0 }, .{ "abc", "Ln 1" });
}

test "scrolling sideways" {
    var b: Buffer = try .init(testing.allocator, "0123456789\n中文字\na\tb\nshort");
    defer b.deinit();
    try expectScreen(5, 6, .{ .buffer = &b, .name = "", .top = 0, .left = 3 }, .{
        "345678",
        " 字", // 文 is cut by the left edge: its visible half is blank
        " b", // the tab's remaining columns are blanks
        "rt",
        " Ln 1",
    });
}

test "lines longer than any copy buffer show their end" {
    const gpa = testing.allocator;
    const long = try gpa.alloc(u8, 10_000);
    defer gpa.free(long);
    @memset(long, 'a');
    @memcpy(long[long.len - 3 ..], "END");
    var b: Buffer = try .init(gpa, long);
    defer b.deinit();
    try expectScreen(2, 10, .{ .buffer = &b, .name = "", .top = 0, .left = 9_990 }, .{ "aaaaaaaEND", "     Ln 1" });
}

test "line numbers: own, relative, or both, in a gutter as wide as needed" {
    var b: Buffer = try .init(testing.allocator, "a\tb\n中x\nthree\n");
    defer b.deinit();
    const view: View = .{ .buffer = &b, .name = "", .top = 0, .cursor = .{ .line = 1, .col = 2 }, .numbers = .absolute };
    try expectScreen(5, 12, view, .{ "  1 a   b", "  2 中x", "  3 three", "~", " [new] Ln 2" });
    var relative = view;
    relative.numbers = .relative;
    try expectScreen(5, 12, relative, .{ "  1 a   b", "  0 中x", "  1 three", "~", " [new] Ln 2" });
    var both = view;
    both.numbers = .both;
    try expectScreen(5, 12, both, .{ "  1 a   b", "  2 中x", "  1 three", "~", " [new] Ln 2" });

    // The cursor and any resync after a wide character are moved past it.
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try draw(&w, .{ .rows = 5, .cols = 12 }, view);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "\x1b[7G") != null); // after 中
    try testing.expect(std.mem.endsWith(u8, w.buffered(), "\x1b[2;7H\x1b[2 q" ++ show_cursor ++ sync_end));

    // No room for numbers and text: no numbers.
    try expectScreen(2, 4, view, .{ "a", "Ln 2" });
}

test "the gutter grows with the line count" {
    try testing.expectEqual(@as(usize, 0), gutterWidth(.none, 5));
    try testing.expectEqual(@as(usize, 4), gutterWidth(.absolute, 999));
    try testing.expectEqual(@as(usize, 5), gutterWidth(.relative, 1000));
}

test "a character split across two pieces is read whole" {
    var b: Buffer = try .init(testing.allocator, "x\xe4");
    defer b.deinit();
    try b.insert(2, "\xb8\xad!"); // completes 中 across the piece boundary
    try expectScreen(2, 6, .{ .buffer = &b, .name = "", .top = 0 }, .{ "x中!", " Ln 1" });
}

/// A terminal that disagrees with zvim: combining marks take a column, emoji
/// take one column, and the em dash takes two.
fn otherTermWidth(cp: u21) u2 {
    if (cp == 0x301) return 1;
    if (cp == '😀') return 1;
    if (cp == '—') return 2;
    return text.width(cp);
}

test "width disagreements stay within their own character" {
    var b: Buffer = try .init(testing.allocator, "é—x\ne\u{301},y\n😀z\n——ab\nnext");
    defer b.deinit();
    const got = try screen(6, 4, .{ .buffer = &b, .name = "", .top = 0 }, &otherTermWidth);

    // Characters after the disagreement still land in zvim's columns.
    try testing.expectEqualStrings("é—x", got[0][0..6]); // x at col 2
    try testing.expectEqualStrings("e,y", got[1]);
    try testing.expectEqualStrings("😀 z", got[2]);
    // A row the terminal thinks is too wide doesn't spill onto the next row.
    try testing.expectEqualStrings("——ab", got[3]);
    try testing.expectEqualStrings("next", got[4]);
}

test "tiny viewport stays valid" {
    var b: Buffer = try .init(testing.allocator, "x");
    defer b.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try draw(&w, .{ .rows = 1, .cols = 1 }, .{ .buffer = &b, .name = "", .top = 0 });
    try testing.expect(std.mem.endsWith(u8, w.buffered(), sync_end));
}
