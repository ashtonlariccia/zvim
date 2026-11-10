//! Normal and visual mode keys: counts, operator keys, the commands that
//! take at most a count, and `.` repeat.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Editor = @import("../Editor.zig");
const Key = @import("../keys.zig").Key;
const text = @import("../text.zig");
const words = @import("words.zig");
const nextChar = text.nextChar;
const prevChar = text.prevChar;
const firstNonBlank = text.firstNonBlank;
const cmdline = @import("cmdline.zig");
const motions = @import("motions.zig");
const operators = @import("operators.zig");
const visual = @import("visual.zig");
const textobjects = @import("textobjects.zig");

pub fn keyChar(key: Key) ?u21 {
    return switch (key) {
        .char => |c| c,
        .tab => '\t',
        else => null,
    };
}

/// Whether `key`, where a command can start, is one that changes the text:
/// what the help page refuses. Moving, yanking, selecting and `:` are left.
fn changesText(ed: *const Editor, key: Key) bool {
    const in_visual = ed.mode == .visual;
    return switch (key) {
        .delete => true,
        .ctrl => |c| c == 'r',
        .char => |c| switch (c) {
            'd', 'c', '>', '<', 'r', 'x', 'X', 's', 'S', 'D', 'C', 'p', 'P', 'J', 'u', '.', 'I', 'A' => true,
            // In visual mode (and after y) these are text objects or "other end".
            'i', 'a' => !in_visual and ed.pending.op == null,
            'o', 'O' => !in_visual,
            else => false,
        },
        else => false,
    };
}

pub fn normalKey(ed: *Editor, key: Key) !void {
    switch (ed.pending.wait) {
        .none => {},
        .g => {
            ed.pending.wait = .none;
            if (key == .char and key.char == 'g') return motions.doMotion(ed, .file_start);
            ed.pending = .{};
            ed.failed = true;
            return;
        },
        .find => |kind| {
            ed.pending.wait = .none;
            const target = keyChar(key) orelse {
                ed.pending = .{};
                ed.failed = true;
                return;
            };
            ed.last_find = .{ .kind = kind, .target = target };
            return motions.doMotion(ed, .{ .find = .{ .kind = kind, .target = target, .repeat = false } });
        },
        .replace => {
            ed.pending.wait = .none;
            return operators.replaceChars(ed, key);
        },
        .object => |around| {
            ed.pending.wait = .none;
            return applyObject(ed, key, around == .around);
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

    if (ed.view_only and changesText(ed, key)) {
        _ = ed.refuseChange();
        return;
    }
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
            // After an operator or in visual mode, i and a start a text
            // object (diw, va"); otherwise they enter insert mode.
            'i', 'a' => if (ed.pending.op != null or ed.mode == .visual) {
                return waitFor(ed, .{ .object = if (c == 'i') .inside else .around });
            },
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
        // An operator followed by something that isn't a motion: cancelled.
        ed.pending = .{};
        ed.failed = true;
        return;
    }
    ed.pending = .{};
    const n = @max(count, 1);
    switch (key) {
        .escape => if (in_visual) try visual.leaveVisual(ed),
        .delete => try shortcut(ed, .delete, .right, count),
        .ctrl => |c| switch (c) {
            // Like u, not in visual mode: the text would change under the selection.
            'r' => if (!in_visual) {
                ed.dot.excluded = true;
                for (0..n) |_| try ed.redo();
            },
            'v' => try visual.toggleVisual(ed, .block),
            'z' => ed.suspend_requested = true,
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
            // zvim's own commands; a key Vim leaves unused.
            '\\' => if (ed.is_page) {
                ed.setMessage(true, "\\ commands work in your file, not on this page (:q goes back)", .{});
            } else if (!in_visual) {
                ed.dot.excluded = true;
                cmdline.openCommandLine(ed, .zvim);
            },
            else => {},
        },
        else => {},
    }
    if (ed.mode == .insert) try ed.updateWantCol();
}

/// The object after i or a: applies the pending operator to it, or in visual
/// mode selects it.
fn applyObject(ed: *Editor, key: Key, around: bool) !void {
    const p = ed.pending;
    ed.pending = .{};
    const count = @max(p.count, 1) * @max(p.op_count, 1);
    const object_key = keyChar(key) orelse {
        ed.failed = true;
        return;
    };
    const range = (try textobjects.find(ed, object_key, around, count)) orelse {
        ed.failed = true;
        return;
    };

    if (ed.mode == .visual) {
        switch (range) {
            .chars => |r| {
                if (r.end == r.start) {
                    ed.failed = true;
                    return;
                }
                ed.visual_anchor = r.start;
                ed.cursor = try lastCharBefore(ed, r.end);
                if (ed.visual_kind != .char) ed.visual_kind = .char;
            },
            .lines => |r| {
                ed.visual_anchor = ed.buffer.lineStart(r.first);
                ed.cursor = ed.buffer.lineStart(r.last);
                ed.visual_kind = .line;
            },
        }
        return ed.updateWantCol();
    }

    const op = p.op orelse return;
    switch (range) {
        .lines => |r| try operators.operateLines(ed, op, r.first, r.last),
        .chars => |r| {
            if (op == .indent or op == .outdent) {
                return operators.operateLines(ed, op, ed.buffer.lineOf(r.start), ed.buffer.lineOf(@max(r.start, r.end -| 1)));
            }
            // Only c can act on nothing (ci( between empty brackets).
            if (r.end == r.start and op != .change) {
                ed.failed = true;
                return;
            }
            try operators.operateChars(ed, op, r.start, r.end);
        },
    }
}

/// Start of the character that ends just before `end`.
fn lastCharBefore(ed: *Editor, end: usize) !usize {
    const p = ed.toPos(end);
    if (p.byte == 0) return end - 1; // the newline ending the line before
    return end - (p.byte - prevChar(try ed.lineText(p.line), p.byte));
}

pub fn waitFor(ed: *Editor, wait: Editor.Pending.Wait) void {
    ed.pending.wait = wait;
}

/// An operator key: in visual mode it acts on the selection; doubled (dd,
/// yy, cc, >>, <<) it acts on [count] lines; otherwise it waits for a motion.
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

/// x, X, s, D, C: an operator with a fixed motion. In visual mode they act on
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

/// o and O: a new line below or above, with the current line's indentation.
pub fn openLine(ed: *Editor, above: bool) !void {
    const line = ed.buffer.lineOf(ed.cursor);
    var buf: [256]u8 = undefined;
    const indent = try ed.indentOf(line, if (ed.settings.autoindent) std.math.maxInt(usize) else 0, &buf);
    if (above) {
        ed.cursor = ed.buffer.lineStart(line);
        try ed.insertAtCursor("\n");
        ed.cursor -= 1;
    } else {
        ed.cursor = ed.lineEnd(line);
        try ed.insertAtCursor("\n");
    }
    try ed.insertAtCursor(indent);
    ed.autoindent_at = if (indent.len > 0) ed.cursor else null;
    ed.mode = .insert;
}

/// `.`: replays the keys of the last change, with `count` replacing its count.
pub fn repeatLastChange(ed: *Editor, count: usize) Allocator.Error!void {
    ed.dot.excluded = true;
    // A replay that reaches a `.` (say, typed text that ran as commands after
    // a failed motion) would otherwise replay itself forever.
    if (ed.dot.replaying or ed.dot.last.items.len == 0) return;
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
    // Like Vim, a command that fails ends the replay, so the rest of the
    // keys (e.g. text meant for insert mode) don't run as commands.
    for (keys[start..]) |k| {
        _ = try ed.handleKey(k);
        if (ed.failed) break;
    }
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

test ". stops replaying when a command fails, and never replays itself" {
    var e = try testEditor("a.b\nxyz\n");
    defer e.deinit();
    // cT. from "b" changes ".", then the insert types text containing ".".
    try typeKeys(&e, "$cT.");
    try typeThenEscape(&e, "k.x");
    try expectText(&e, "a.k.xb\nxyz\n");
    // On the next line there is no "." to go back to: the replay stops
    // instead of running "k.x" as commands (where "." would recurse).
    try typeKeys(&e, "j$.");
    try expectText(&e, "a.k.xb\nxyz\n");
    try typeKeys(&e, "2.");
    try expectText(&e, "a.k.xb\nxyz\n");
}

test "Ctrl-Z asks the caller to suspend, and isn't what . repeats" {
    var e = try testEditor("abc\n");
    defer e.deinit();
    try typeKeys(&e, "x");
    try testing.expectEqual(Editor.Action.@"suspend", try e.handleKey(.{ .ctrl = 'z' }));
    try typeKeys(&e, ".");
    try expectText(&e, "c\n");
}

test "Ctrl-C leaves insert and visual mode, cancels commands, and says how to quit" {
    var e = try testEditor("abc\n");
    defer e.deinit();
    try typeKeys(&e, "ix\x03");
    try testing.expectEqual(Editor.Mode.normal, e.mode);
    try expectText(&e, "xabc\n");
    try typeKeys(&e, "v\x03");
    try testing.expectEqual(Editor.Mode.normal, e.mode);
    try typeKeys(&e, ":q\x03");
    try testing.expectEqual(Editor.Mode.normal, e.mode);
    try typeKeys(&e, "d\x03x"); // the d is cancelled; x still works
    try expectText(&e, "abc\n");
    try typeKeys(&e, "\x03");
    try testing.expectEqualStrings("Type :q! and press Enter to quit without saving", e.message.text());
}
