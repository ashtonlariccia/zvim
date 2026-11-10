//! Frame rendering. Draws a full frame into a writer; the caller flushes.

const std = @import("std");
const Size = @import("term.zig").Size;

const sync_begin = "\x1b[?2026h"; // synchronized output: no tearing mid-frame
const sync_end = "\x1b[?2026l";

/// Draws a border around the whole viewport with the current size in the top edge.
pub fn drawFrame(w: *std.Io.Writer, size: Size) !void {
    try w.writeAll(sync_begin ++ "\x1b[H\x1b[2J");
    defer w.writeAll(sync_end) catch {};
    if (size.rows < 2 or size.cols < 2) return;

    const inner: usize = size.cols - 2;

    // Top edge, with a centered " zvim RxC " label when it fits.
    var label_buf: [32]u8 = undefined;
    const label = try std.fmt.bufPrint(&label_buf, " zvim {d}x{d} ", .{ size.cols, size.rows });
    try w.writeAll("\x1b[1;1H┌");
    if (label.len <= inner) {
        const left = (inner - label.len) / 2;
        try w.splatBytesAll("─", left);
        try w.writeAll(label);
        try w.splatBytesAll("─", inner - left - label.len);
    } else {
        try w.splatBytesAll("─", inner);
    }
    try w.writeAll("┐");

    // Sides. Positioning explicitly avoids depending on autowrap behavior.
    var row: usize = 2;
    while (row < size.rows) : (row += 1) {
        try w.print("\x1b[{d};1H│\x1b[{d};{d}H│", .{ row, row, size.cols });
    }

    // Bottom edge.
    try w.print("\x1b[{d};1H└", .{size.rows});
    try w.splatBytesAll("─", inner);
    try w.writeAll("┘");
}

/// Replays the cursor-positioning and text in `out` onto a grid of codepoints,
/// so tests can assert on what the terminal would show.
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
        grid[r][c] = try std.unicode.utf8Decode(out[i .. i + len]);
        c += 1;
        i += len;
    }
    return grid;
}

test "frame borders fill the viewport exactly" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try drawFrame(&w, .{ .rows = 4, .cols = 20 });

    const grid = try renderToGrid(w.buffered(), 4, 20);
    var lines: [4][80]u8 = undefined;
    var got: [4][]const u8 = undefined;
    for (grid, 0..) |line, r| {
        var n: usize = 0;
        for (line) |cp| n += try std.unicode.utf8Encode(cp, lines[r][n..]);
        got[r] = lines[r][0..n];
    }
    try std.testing.expectEqualStrings("┌─── zvim 20x4 ────┐", got[0]);
    try std.testing.expectEqualStrings("│                  │", got[1]);
    try std.testing.expectEqualStrings("│                  │", got[2]);
    try std.testing.expectEqualStrings("└──────────────────┘", got[3]);
}

test "label is dropped when the viewport is too narrow" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try drawFrame(&w, .{ .rows = 2, .cols = 6 });
    const grid = try renderToGrid(w.buffered(), 2, 6);
    try std.testing.expectEqual(@as(u21, '┌'), grid[0][0]);
    try std.testing.expectEqual(@as(u21, '─'), grid[0][1]);
    try std.testing.expectEqual(@as(u21, '┘'), grid[1][5]);
}

test "tiny viewport draws nothing but stays valid" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try drawFrame(&w, .{ .rows = 1, .cols = 1 });
    try std.testing.expect(std.mem.endsWith(u8, w.buffered(), sync_end));
}
