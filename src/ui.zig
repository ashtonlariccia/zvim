//! Frame rendering. Draws a full frame into a writer; the caller flushes.

const std = @import("std");
const Size = @import("term.zig").Size;
const Buffer = @import("Buffer.zig");
const text = @import("text.zig");

const sync_begin = "\x1b[?2026h"; // synchronized output: no tearing mid-frame
const sync_end = "\x1b[?2026l";

const tab_width = 8;

/// What to show inside the border.
pub const View = struct {
    buffer: *const Buffer,
    /// Shown in the bottom edge.
    name: []const u8,
    /// First visible line (0-based).
    top: usize,
};

/// Draws a border around the whole viewport and the visible lines of the
/// buffer inside it. Lines past the end of the text show `~`.
pub fn draw(w: *std.Io.Writer, size: Size, view: View) !void {
    try w.writeAll(sync_begin ++ "\x1b[H\x1b[2J");
    defer w.writeAll(sync_end) catch {};
    if (size.rows < 2 or size.cols < 2) return;

    const inner: usize = size.cols - 2;
    var label_buf: [64]u8 = undefined;

    try w.writeAll("\x1b[1;1H");
    const size_label = try std.fmt.bufPrint(&label_buf, " zvim {d}x{d} ", .{ size.cols, size.rows });
    try drawEdge(w, "┌", size_label, "┐", inner);

    var row: usize = 2;
    while (row < size.rows) : (row += 1) {
        try w.print("\x1b[{d};1H│", .{row});
        const line = view.top + row - 2;
        if (line < view.buffer.visibleLineCount()) {
            try drawLine(w, view.buffer, line, inner);
        } else if (inner > 0) {
            try w.writeAll("~");
        }
        try w.print("\x1b[{d};{d}H│", .{ row, size.cols });
    }

    try w.print("\x1b[{d};1H", .{size.rows});
    const pos_label = try std.fmt.bufPrint(&label_buf, "  {d}/{d} ", .{ view.top + 1, view.buffer.visibleLineCount() });
    var name_buf: [256]u8 = undefined;
    const name = if (view.name.len > 0) view.name else "[new]";
    const bottom = std.fmt.bufPrint(&name_buf, " {s}{s}", .{ name, pos_label }) catch pos_label;
    try drawEdge(w, "└", bottom, "┘", inner);
}

/// One border edge: corners, with `label` centered when it fits.
fn drawEdge(w: *std.Io.Writer, left: []const u8, label: []const u8, right: []const u8, inner: usize) !void {
    try w.writeAll(left);
    const label_cols = try drawText(null, label, inner + 1);
    if (label_cols <= inner) {
        const before = (inner - label_cols) / 2;
        try w.splatBytesAll("─", before);
        _ = try drawText(w, label, label_cols);
        try w.splatBytesAll("─", inner - before - label_cols);
    } else {
        try w.splatBytesAll("─", inner);
    }
    try w.writeAll(right);
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

/// Writes `bytes` as terminal-safe text in at most `max_cols` columns and
/// returns the columns used. With a null writer it only measures.
fn drawText(w: ?*std.Io.Writer, bytes: []const u8, max_cols: usize) !usize {
    var col: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const ch = text.decode(bytes[i..]);
        const raw = bytes[i..][0..ch.len];
        i += ch.len;

        if (ch.cp == '\t') {
            const spaces = @min(tab_width - col % tab_width, max_cols - col);
            if (w) |out| try out.splatByteAll(' ', spaces);
            col += spaces;
        } else if (ch.cp < 0x20 or ch.cp == 0x7f) {
            // Control characters would act on the terminal; show them as ^X.
            if (col + 2 > max_cols) break;
            if (w) |out| try out.writeAll(&.{ '^', @as(u8, @intCast(ch.cp)) ^ 0x40 });
            col += 2;
        } else if (ch.cp == text.replacement or (ch.cp >= 0x80 and ch.cp < 0xa0)) {
            if (col + 1 > max_cols) break;
            if (w) |out| try out.writeAll("\u{FFFD}");
            col += 1;
        } else {
            const cw = text.width(ch.cp);
            if (cw == 0 and col == 0) continue; // nothing to combine with
            if (col + cw > max_cols) break;
            if (w) |out| try out.writeAll(raw);
            col += cw;
        }
        if (col >= max_cols) break;
    }
    return col;
}

/// Replays the cursor positioning and text in `out` onto a grid of
/// codepoints, so tests can assert on what the terminal would show. A wide
/// character fills its first cell and leaves the second as 0.
fn renderToGrid(out: []const u8, comptime rows: usize, comptime cols: usize) ![rows][cols]u21 {
    var grid: [rows][cols]u21 = @splat(@splat(' '));
    var r: usize = 0;
    var c: usize = 0;
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] == 0x1b) {
            // CSI: ESC [ params final
            var j = i + 2;
            while (out[j] < 0x40 or out[j] > 0x7e) j += 1;
            if (out[j] == 'H') {
                const params = out[i + 2 .. j];
                if (params.len == 0) {
                    r = 0;
                    c = 0;
                } else {
                    var it = std.mem.splitScalar(u8, params, ';');
                    r = try std.fmt.parseInt(usize, it.next().?, 10) - 1;
                    c = try std.fmt.parseInt(usize, it.next().?, 10) - 1;
                }
            }
            i = j + 1;
            continue;
        }
        const len = try std.unicode.utf8ByteSequenceLength(out[i]);
        const cp = try std.unicode.utf8Decode(out[i .. i + len]);
        i += len;
        const cw = text.width(cp);
        if (cw == 0) continue;
        grid[r][c] = cp;
        if (cw == 2) grid[r][c + 1] = 0;
        c += cw;
    }
    return grid;
}

/// Renders a frame and returns each screen row as a UTF-8 string.
fn screen(comptime rows: usize, comptime cols: usize, view: View) ![rows][]const u8 {
    const S = struct {
        var out: [64 * 1024]u8 = undefined;
        var lines: [rows][cols * 4]u8 = undefined;
    };
    var w: std.Io.Writer = .fixed(&S.out);
    try draw(&w, .{ .rows = rows, .cols = cols }, view);
    const grid = try renderToGrid(w.buffered(), rows, cols);
    var result: [rows][]const u8 = undefined;
    for (grid, 0..) |line, r| {
        var n: usize = 0;
        for (line) |cp| {
            if (cp != 0) n += try std.unicode.utf8Encode(cp, S.lines[r][n..]);
        }
        result[r] = S.lines[r][0..n];
    }
    return result;
}

const testing = std.testing;

fn expectScreen(comptime rows: usize, comptime cols: usize, view: View, expected: [rows][]const u8) !void {
    const got = try screen(rows, cols, view);
    for (expected, got) |e, g| try testing.expectEqualStrings(e, g);
}

test "empty buffer shows tildes" {
    var b: Buffer = try .init(testing.allocator, "");
    defer b.deinit();
    try expectScreen(5, 20, .{ .buffer = &b, .name = "", .top = 0 }, .{
        "┌─── zvim 20x5 ────┐",
        "│                  │",
        "│~                 │",
        "│~                 │",
        "└─── [new]  1/1 ───┘",
    });
}

test "file text inside the border, clipped, scrolled" {
    var b: Buffer = try .init(testing.allocator, "first\nsecond line that is too long\nthird\n");
    defer b.deinit();
    try expectScreen(5, 20, .{ .buffer = &b, .name = "a.txt", .top = 0 }, .{
        "┌─── zvim 20x5 ────┐",
        "│first             │",
        "│second line that i│",
        "│third             │",
        "└─── a.txt  1/3 ───┘",
    });
    try expectScreen(5, 20, .{ .buffer = &b, .name = "a.txt", .top = 2 }, .{
        "┌─── zvim 20x5 ────┐",
        "│third             │",
        "│~                 │",
        "│~                 │",
        "└─── a.txt  3/3 ───┘",
    });
}

test "tabs, control characters, invalid bytes and wide characters" {
    var b: Buffer = try .init(testing.allocator, "a\tb\n\x1b[2J\x7f\n\xff\xfeok\n中文x\n\u{301}e\u{301}");
    defer b.deinit();
    try expectScreen(7, 14, .{ .buffer = &b, .name = "t", .top = 0 }, .{
        "┌ zvim 14x7 ─┐",
        "│a       b   │",
        "│^[[2J^?     │",
        "│\u{FFFD}\u{FFFD}ok        │",
        "│中文x       │",
        "│e           │",
        "└── t  1/5 ──┘",
    });
}

test "a wide character that would straddle the edge is left out" {
    var b: Buffer = try .init(testing.allocator, "abc中");
    defer b.deinit();
    try expectScreen(3, 6, .{ .buffer = &b, .name = "", .top = 0 }, .{
        "┌────┐",
        "│abc │",
        "└────┘",
    });
}

test "tiny viewport draws nothing but stays valid" {
    var b: Buffer = try .init(testing.allocator, "x");
    defer b.deinit();
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try draw(&w, .{ .rows = 1, .cols = 1 }, .{ .buffer = &b, .name = "", .top = 0 });
    try testing.expect(std.mem.endsWith(u8, w.buffered(), sync_end));
}
