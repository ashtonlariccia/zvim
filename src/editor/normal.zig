//! Normal and visual mode keys: counts, operator keys, the commands that
//! take at most a count, and `.` repeat.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("../Editor.zig");
const Key = @import("../keys.zig").Key;
const text = @import("../text.zig");
const words = @import("words.zig");
const nextChar = text.nextChar;
const firstNonBlank = text.firstNonBlank;
const cmdline = @import("cmdline.zig");
const motions = @import("motions.zig");
const operators = @import("operators.zig");
const visual = @import("visual.zig");

pub fn keyChar(key: Key) ?u21 {
    return switch (key) {
        .char => |c| c,
        .tab => '\t',
        else => null,
    };
}

pub fn normalKey(ed: *Editor, key: Key) !void {
    switch (ed.pending.wait) {
        .none => {},
        .g => {
            ed.pending.wait = .none;
            if (key == .char and key.char == 'g') return motions.doMotion(ed, .file_start);
            ed.pending = .{};
            return;
        },
        .find => |kind| {
            ed.pending.wait = .none;
            const target = keyChar(key) orelse {
                ed.pending = .{};
                return;
            };
            ed.last_find = .{ .kind = kind, .target = target };
            return motions.doMotion(ed, .{ .find = .{ .kind = kind, .target = target, .repeat = false } });
        },
        .replace => {
            ed.pending.wait = .none;
            return operators.replaceChars(ed, key);
        },
    }

    if (key == .char) {
        const c = key.char;
        const counting = if (ed.pending.op != null) ed.pending.op_count else ed.pending.count;
        if ((c >= '1' and c <= '9') or (c == '0' and counting > 0)) {
            const field = if (ed.pending.op != null) &ed.pending.op_count else &ed.pending.count;
            field.* = field.* *| 10 +| (c - '0');
            return;
        }
    }

    if (motions.motionFor(key)) |m| return motions.doMotion(ed, m);

    switch (key) {
        .char => |c| switch (c) {
            'd' => return operatorKey(ed, .delete),
            'y' => return operatorKey(ed, .yank),
            'c' => return operatorKey(ed, .change),
            '>' => return operatorKey(ed, .indent),
            '<' => return operatorKey(ed, .outdent),
            'g' => {
                ed.pending.wait = .g;
                return;
            },
            'f' => return waitFor(ed, .{ .find = .to }),
            't' => return waitFor(ed, .{ .find = .till }),
            'F' => return waitFor(ed, .{ .find = .back_to }),
            'T' => return waitFor(ed, .{ .find = .back_till }),
            'r' => return waitFor(ed, .replace),
            // Search keeps the count and operator: d/foo deletes up to foo.
            '/' => return cmdline.openCommandLine(ed, .search_forward),
            '?' => return cmdline.openCommandLine(ed, .search_backward),
            else => {},
        },
        else => {},
    }

    // The rest take at most a count.
    const count = ed.pending.count;
    const in_visual = ed.mode == .visual;
    if (ed.pending.op != null) {
        ed.pending = .{};
        return;
    }
    ed.pending = .{};
    const n = @max(count, 1);
    switch (key) {
        .escape => if (in_visual) try visual.leaveVisual(ed),
        .delete => try shortcut(ed, .delete, .right, count),
        .ctrl => |c| switch (c) {
            'r' => {
                ed.dot.excluded = true;
                for (0..n) |_| try ed.redo();
            },
            'v' => try visual.toggleVisual(ed, .block),
            else => {},
        },
        .char => |c| switch (c) {
            'x' => try shortcut(ed, .delete, .right, count),
            'X' => try shortcut(ed, .delete, .left, count),
            's' => try shortcut(ed, .change, .right, count),
            'D' => try shortcut(ed, .delete, .line_end, count),
            'C' => try shortcut(ed, .change, .line_end, count),
            'S' => try lineShortcut(ed, .change, n),
            'Y' => try lineShortcut(ed, .yank, n),
            'p' => try operators.paste(ed, false, n),
            'P' => try operators.paste(ed, true, n),
            'J' => try operators.joinLines(ed, n),
            'u' => if (!in_visual) {
                ed.dot.excluded = true;
                for (0..n) |_| try ed.undo();
            },
            '.' => if (!in_visual) try repeatLastChange(ed, count),
            'v' => try visual.toggleVisual(ed, .char),
            'V' => try visual.toggleVisual(ed, .line),
            'o' => if (in_visual) {
                std.mem.swap(usize, &ed.visual_anchor, &ed.cursor);
                try ed.updateWantCol();
            } else try openLine(ed, false),
            'O' => if (in_visual) {
                // In a block, O swaps to the other corner on the same line; elsewhere like o.
                try visual.swapBlockCorner(ed);
            } else try openLine(ed, true),
            'i' => if (!in_visual) {
                ed.mode = .insert;
            },
            'a' => if (!in_visual) {
                const p = try ed.cursorPos();
                const s = try ed.lineText(p.line);
                if (p.byte < s.len) ed.cursor += nextChar(s, p.byte) - p.byte;
                ed.mode = .insert;
            },
            'I' => if (in_visual) try visual.blockInsert(ed, false) else {
                const line = ed.buffer.lineOf(ed.cursor);
                ed.cursor = ed.buffer.lineStart(line) + firstNonBlank(try ed.lineText(line));
                ed.mode = .insert;
            },
            'A' => if (in_visual) try visual.blockInsert(ed, true) else {
                const line = ed.buffer.lineOf(ed.cursor);
                ed.cursor = ed.lineEnd(line);
                ed.mode = .insert;
            },
            ':' => if (!in_visual) {
                ed.dot.excluded = true;
                cmdline.openCommandLine(ed, .ex);
            },
            else => {},
        },
        else => {},
    }
    if (ed.mode == .insert) try ed.updateWantCol();
}

pub fn waitFor(ed: *Editor, wait: Editor.Pending.Wait) void {
    ed.pending.wait = wait;
}

/// An operator key: in visual mode it acts on the selection; doubled (dd,
/// yy, cc, >>, <<) it acts on [count] lines; otherwise it waits for a words.
pub fn operatorKey(ed: *Editor, op: Editor.Op) !void {
    if (ed.mode == .visual) {
        ed.pending = .{};
        return visual.visualOperator(ed, op);
    }
    if (ed.pending.op) |pending_op| {
        const p = ed.pending;
        ed.pending = .{};
        if (pending_op != op) return;
        const line = ed.buffer.lineOf(ed.cursor);
        return operators.operateLines(ed, op, line, line + @max(p.count, 1) * @max(p.op_count, 1) - 1);
    }
    ed.pending.op = op;
}

/// x, X, s, D, C: an operator with a fixed words. In visual mode they act on
/// the selection (D, C and X on whole lines).
pub fn shortcut(ed: *Editor, op: Editor.Op, m: motions.Motion, count: usize) !void {
    if (ed.mode == .visual) {
        if (m != .right) ed.visual_kind = .line;
        return visual.visualOperator(ed, op);
    }
    ed.pending = .{ .count = count, .op = op };
    try motions.doMotion(ed, m);
}

/// S and Y: an operator on [count] lines (or the selected lines).
pub fn lineShortcut(ed: *Editor, op: Editor.Op, n: usize) !void {
    if (ed.mode == .visual) {
        ed.visual_kind = .line;
        return visual.visualOperator(ed, op);
    }
    const line = ed.buffer.lineOf(ed.cursor);
    try operators.operateLines(ed, op, line, line + n - 1);
}

pub fn openLine(ed: *Editor, above: bool) !void {
    const line = ed.buffer.lineOf(ed.cursor);
    if (above) {
        ed.cursor = ed.buffer.lineStart(line);
        try ed.insertAtCursor("\n");
        ed.cursor -= 1;
    } else {
        ed.cursor = ed.lineEnd(line);
        try ed.insertAtCursor("\n");
    }
    ed.mode = .insert;
}

/// `.`: replays the keys of the last change, with `count` replacing its count.
pub fn repeatLastChange(ed: *Editor, count: usize) Allocator.Error!void {
    ed.dot.excluded = true;
    if (ed.dot.last.items.len == 0) return;
    const keys = try ed.gpa.dupe(Key, ed.dot.last.items);
    defer ed.gpa.free(keys);
    var start: usize = 0;
    if (count > 0) {
        while (start < keys.len and isCountKey(keys[start], start == 0)) start += 1;
    }
    ed.dot.replaying = true;
    defer ed.dot.replaying = false;
    if (count > 0) {
        var digits: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&digits, "{d}", .{count}) catch unreachable;
        for (s) |d| _ = try ed.handleKey(.{ .char = d });
    }
    for (keys[start..]) |k| _ = try ed.handleKey(k);
}

pub fn isCountKey(key: Key, first: bool) bool {
    if (key != .char) return false;
    return (key.char >= '1' and key.char <= '9') or (!first and key.char == '0');
}

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const typeThenEscape = h.typeThenEscape;
const expectText = h.expectText;

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
