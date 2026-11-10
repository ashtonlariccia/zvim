//! Frame rendering. Draws a full frame into a writer; the caller flushes.
//!
//! Terminals don't all agree on how wide a character is (combining marks,
//! emoji and "ambiguous" characters vary). Every row is positioned and cleared
//! explicitly, and after any non-ASCII character the cursor is moved to the
//! column zvim expects, so a disagreement stays within that one character
//! instead of shifting the rest of the line or spilling onto the next row.

const std = @import("std");
const Size = @import("term.zig").Size;
const Buffer = @import("Buffer.zig");
const text = @import("text.zig");

const sync_begin = "\x1b[?2026h"; // synchronized output: no tearing mid-frame
const sync_end = "\x1b[?2026l";

const tab_width = 8;

/// What to show.
pub const View = struct {
    buffer: *const Buffer,
    /// Shown in the status line.
    name: []const u8,
    /// First visible line (0-based).
    top: usize,
};

/// Draws the visible lines of the buffer, with `~` past the end of the text,
/// and a status line in the bottom row.
pub fn draw(w: *std.Io.Writer, size: Size, view: View) !void {
    try w.writeAll(sync_begin);
    defer w.writeAll(sync_end) catch {};

    const cols: usize = size.cols;
    const text_rows: usize = if (size.rows >= 2) size.rows - 1 else size.rows;
    const lines = view.buffer.visibleLineCount();

    for (0..text_rows) |r| {
        try w.print("\x1b[{d};1H", .{r + 1});
        const line = view.top + r;
        if (line < lines) {
            try drawLine(w, view.buffer, line, cols);
        } else {
            try w.writeAll("~");
        }
        try w.writeAll("\x1b[K");
    }

    if (size.rows >= 2) {
        try w.print("\x1b[{d};1H", .{size.rows});
        try drawStatus(w, view, lines, cols);
        try w.writeAll("\x1b[K");
    }
}

/// File name on the left, line position on the right; the name is left out
/// when both don't fit.
fn drawStatus(w: *std.Io.Writer, view: View, lines: usize, cols: usize) !void {
    var pos_buf: [48]u8 = undefined;
    const pos = try std.fmt.bufPrint(&pos_buf, "{d}/{d}", .{ view.top + 1, lines });
    const name = if (view.name.len > 0) view.name else "[new]";

    const name_cols = try drawText(null, name, cols);
    if (name_cols + 2 + pos.len <= cols) {
        _ = try drawText(w, name, name_cols);
        try w.splatByteAll(' ', cols - name_cols - pos.len);
    } else if (pos.len <= cols) {
        try w.splatByteAll(' ', cols - pos.len);
    } else return;
    try w.writeAll(pos);
}

/// Draws as much of `line` as fits in `cols` columns.
fn drawLine(w: *std.Io.Writer, buffer: *const Buffer, line: usize, cols: usize) !void {
    // Gather the start of the line; even all-wide characters need at most
    // 4 bytes per column, so this covers every visible column.
    var scratch: [4096]u8 = undefined;
    var n: usize = 0;
    var it = buffer.chunksFrom(buffer.lineStart(line));
    gather: while (it.next()) |chunk| {
        for (chunk) |c| {
            if (c == '\n' or n == scratch.len) break :gather;
            scratch[n] = c;
            n += 1;
        }
    }
    _ = try drawText(w, scratch[0..n], cols);
}

/// Writes `bytes` as terminal-safe text in at most `max_cols` columns,
/// starting at screen column 1, and returns the columns used. With a null
/// writer it only measures.
fn drawText(w: ?*std.Io.Writer, bytes: []const u8, max_cols: usize) !usize {
    var col: usize = 0;
    // Set after a character whose width the terminal might see differently;
    // the cursor is re-synced before the next character that takes space.
    var resync = false;
    var i: usize = 0;
    while (i < bytes.len and col < max_cols) {
        const ch = text.decode(bytes[i..]);
        const raw = bytes[i..][0..ch.len];
        i += ch.len;

        const cw: usize = if (ch.cp == '\t')
            tab_width - col % tab_width
        else if (ch.cp < 0x20 or ch.cp == 0x7f)
            2
        else if (ch.cp == text.replacement or (ch.cp >= 0x80 and ch.cp < 0xa0))
            1
        else
            text.width(ch.cp);

        if (cw == 0) {
            // Combining mark: attaches to the previous character, if any.
            if (col == 0) continue;
            if (w) |out| try out.writeAll(raw);
            resync = true;
            continue;
        }
        if (col + cw > max_cols) {
            if (ch.cp != '\t') break;
        }
        const used = @min(cw, max_cols - col);

        if (w) |out| {
            if (resync) try out.print("\x1b[{d}G", .{col + 1});
            if (ch.cp == '\t') {
                try out.splatByteAll(' ', used);
            } else if (ch.cp < 0x20 or ch.cp == 0x7f) {
                // Control characters would act on the terminal; show them as ^X.
                try out.writeAll(&.{ '^', @as(u8, @intCast(ch.cp)) ^ 0x40 });
            } else if (ch.cp == text.replacement or (ch.cp >= 0x80 and ch.cp < 0xa0)) {
                try out.writeAll("\u{FFFD}");
            } else {
                try out.writeAll(raw);
            }
        }
        resync = ch.cp >= 0x80;
        col += used;
    }
    return col;
}

/// A minimal terminal model for tests: replays cursor movement and text from
/// `out` onto a grid. `termWidth` is the terminal's idea of character widths,
/// which may differ from zvim's. Like a real terminal, text that reaches the
/// right edge wraps onto the next row. A wide character fills its first cell
/// and marks the second with 0; combining marks are dropped.
fn renderToGrid(
    out: []const u8,
    comptime rows: usize,
    comptime cols: usize,
    termWidth: *const fn (u21) u2,
) ![rows][cols]u21 {
    var grid: [rows][cols]u21 = @splat(@splat(' '));
    var r: usize = 0;
    var c: usize = 0;
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
                },
                'G' => c = try std.fmt.parseInt(usize, params, 10) - 1,
                'K' => for (grid[r][@min(c, cols)..]) |*cell| {
                    cell.* = ' ';
                },
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
        if (c + cw > cols) {
            r += 1;
            c = 0;
        }
        grid[r][c] = cp;
        if (cw == 2) grid[r][c + 1] = 0;
        c += cw;
    }
    return grid;
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

test "empty buffer shows tildes and a status line" {
    var b: Buffer = try .init(testing.allocator, "");
    defer b.deinit();
    try expectScreen(4, 20, .{ .buffer = &b, .name = "", .top = 0 }, .{
        "",
        "~",
        "~",
        "[new]            1/1",
    });
}

test "file text, clipped and scrolled" {
    var b: Buffer = try .init(testing.allocator, "first\nsecond line that is too long\nthird\n");
    defer b.deinit();
    try expectScreen(4, 20, .{ .buffer = &b, .name = "a.txt", .top = 0 }, .{
        "first",
        "second line that is",
        "third",
        "a.txt            1/3",
    });
    try expectScreen(4, 20, .{ .buffer = &b, .name = "a.txt", .top = 2 }, .{
        "third",
        "~",
        "~",
        "a.txt            3/3",
    });
}

test "status line drops the name when it doesn't fit" {
    var b: Buffer = try .init(testing.allocator, "x");
    defer b.deinit();
    try expectScreen(2, 10, .{ .buffer = &b, .name = "a_long_name.txt", .top = 0 }, .{
        "x",
        "       1/1",
    });
}

test "tabs, control characters, invalid bytes and wide characters" {
    var b: Buffer = try .init(testing.allocator, "a\tb\n\x1b[2J\x7f\n\xff\xfeok\n中文x\n\u{301}e\u{301}");
    defer b.deinit();
    try expectScreen(6, 12, .{ .buffer = &b, .name = "t", .top = 0 }, .{
        "a       b",
        "^[[2J^?",
        "\u{FFFD}\u{FFFD}ok",
        "中文x",
        "e",
        "t        1/5",
    });
}

test "a wide character that would straddle the edge is left out" {
    var b: Buffer = try .init(testing.allocator, "abc中");
    defer b.deinit();
    try expectScreen(2, 4, .{ .buffer = &b, .name = "", .top = 0 }, .{ "abc", " 1/1" });
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
