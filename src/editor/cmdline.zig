//! The command line: `:` commands, `\` commands (zvim's own, see
//! settings.zig) and `/` `?` searches.

const std = @import("std");
const Editor = @import("../Editor.zig");
const Key = @import("../keys.zig").Key;
const text = @import("../text.zig");
const normal = @import("normal.zig");
const motions = @import("motions.zig");
const settings = @import("settings.zig");

const no_file_name = "E32: No file name";
const unsaved_changes = "E37: No write since last change (add ! to override)";

pub fn openCommandLine(ed: *Editor, kind: Editor.CommandKind) void {
    ed.command_return = ed.mode;
    ed.mode = .command;
    ed.command_kind = kind;
    ed.command.clearRetainingCapacity();
}

pub fn commandKey(ed: *Editor, key: Key) !Editor.Action {
    switch (key) {
        .char => |c| {
            var bytes: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &bytes) catch return .none;
            try ed.command.appendSlice(ed.gpa, bytes[0..n]);
        },
        .tab => try ed.command.append(ed.gpa, '\t'),
        .backspace => {
            if (ed.command.items.len == 0) {
                closeCommandLine(ed);
            } else {
                ed.command.shrinkRetainingCapacity(text.prevStart(ed.command.items, ed.command.items.len));
            }
        },
        .escape => closeCommandLine(ed),
        .enter => {
            ed.mode = ed.command_return;
            switch (ed.command_kind) {
                .ex => return runCommand(ed),
                .zvim => _ = try settings.runLine(ed, ed.command.items),
                .search_forward, .search_backward => try runSearch(ed),
            }
        },
        else => {},
    }
    return .none;
}

pub fn closeCommandLine(ed: *Editor) void {
    ed.mode = ed.command_return;
    ed.pending = .{};
}

/// Runs the command line: w, q, wq, x (each optionally with !, and w/wq/x
/// with a file name), e, or a line number.
pub fn runCommand(ed: *Editor) !Editor.Action {
    const line = std.mem.trim(u8, ed.command.items, " \t");
    var name_end: usize = 0;
    while (name_end < line.len and std.ascii.isAlphabetic(line[name_end])) name_end += 1;
    const cmd = line[0..name_end];
    var rest = line[name_end..];
    const bang = rest.len > 0 and rest[0] == '!';
    if (bang) rest = rest[1..];
    const arg = std.mem.trim(u8, rest, " \t");

    if (line.len == 0) return .none;

    // :42 and :$ go to a line.
    if (std.mem.eql(u8, line, "$")) {
        try ed.goToLine(std.math.maxInt(usize));
        return .none;
    }
    if (std.ascii.isDigit(line[0])) {
        const n = std.fmt.parseInt(usize, line, 10) catch std.math.maxInt(usize);
        try ed.goToLine(n);
        return .none;
    }

    // :e reloads the file from disk; :e! even with unsaved changes.
    if (std.mem.eql(u8, cmd, "e") or std.mem.eql(u8, cmd, "edit")) {
        if (arg.len > 0) {
            ed.setMessage(true, "zvim edits one file at a time for now; quit and open {s}", .{arg});
            return .none;
        }
        if (ed.name.items.len == 0) {
            ed.setMessage(true, no_file_name, .{});
            return .none;
        }
        if (ed.isModified() and !bang) {
            ed.setMessage(true, unsaved_changes, .{});
            return .none;
        }
        return .{ .reload = ed.name.items };
    }

    const write = std.mem.eql(u8, cmd, "w");
    const write_quit = std.mem.eql(u8, cmd, "wq") or std.mem.eql(u8, cmd, "x");
    if (write or write_quit) {
        if (arg.len > 0 and ed.name.items.len == 0) {
            try ed.name.appendSlice(ed.gpa, arg);
        }
        const path = if (arg.len > 0) arg else ed.name.items;
        if (path.len == 0) {
            ed.setMessage(true, no_file_name, .{});
            return .none;
        }
        // Saving replaces the file through its directory, which could
        // overwrite a read-only file; like Vim, that takes a !.
        if (ed.readonly and !bang and std.mem.eql(u8, path, ed.name.items)) {
            ed.setMessage(true, "E45: File is read-only (add ! to override)", .{});
            return .none;
        }
        // Like Vim, a file always ends with a newline when written.
        if (ed.buffer.len > 0 and !ed.endsWithNewline()) try ed.insertBytes(ed.buffer.len, "\n");
        return .{ .write = .{ .path = path, .then_quit = write_quit, .force = bang } };
    }
    if (std.mem.eql(u8, cmd, "q") and arg.len == 0) {
        if (ed.isModified() and !bang) {
            ed.setMessage(true, unsaved_changes, .{});
            return .none;
        }
        return .quit;
    }
    ed.setMessage(true, "E492: Not an editor command: {s}", .{line});
    return .none;
}

/// Enter on a / or ? command line: search for the typed text (or the last
/// search when empty), as a motion, so it also works after an operator.
pub fn runSearch(ed: *Editor) !void {
    if (ed.command.items.len > 0) {
        ed.last_search.clearRetainingCapacity();
        try ed.last_search.appendSlice(ed.gpa, ed.command.items);
    }
    ed.last_search_forward = ed.command_kind == .search_forward;
    try motions.doMotion(ed, .{ .search_next = false });
}

/// Finds the next occurrence of the last search from `from`, wrapping
/// around the end of the text. With `ignorecase`, ASCII letters match in
/// either case, unless `smartcase` is on and the pattern has a capital.
pub fn search(ed: *Editor, from: usize, forward: bool) !?usize {
    const pattern = ed.last_search.items;
    const all = try ed.buffer.toOwnedSlice(ed.gpa);
    defer ed.gpa.free(all);
    const has_capital = for (pattern) |c| {
        if (std.ascii.isUpper(c)) break true;
    } else false;
    const fold = ed.settings.ignorecase and !(ed.settings.smartcase and has_capital);
    if (forward) {
        if (from + 1 <= all.len) {
            if (indexOfPos(all, from + 1, pattern, fold)) |i| return i;
        }
        if (indexOfPos(all, 0, pattern, fold)) |i| {
            ed.setMessage(true, "search hit BOTTOM, continuing at TOP", .{});
            return i;
        }
    } else {
        if (lastIndexBefore(all, from, pattern, fold)) |i| return i;
        if (lastIndexBefore(all, all.len + 1, pattern, fold)) |i| {
            ed.setMessage(true, "search hit TOP, continuing at BOTTOM", .{});
            return i;
        }
    }
    return null;
}

fn indexOfPos(all: []const u8, start: usize, pattern: []const u8, fold: bool) ?usize {
    if (!fold) return std.mem.indexOfPos(u8, all, start, pattern);
    if (pattern.len > all.len) return null;
    for (start..all.len - pattern.len + 1) |i| {
        if (std.ascii.startsWithIgnoreCase(all[i..], pattern)) return i;
    }
    return null;
}

/// The last match that starts before `end`.
fn lastIndexBefore(all: []const u8, end: usize, pattern: []const u8, fold: bool) ?usize {
    var i = @min(end, all.len + 1);
    while (i > 0) {
        i -= 1;
        const rest = all[i..];
        if (if (fold) std.ascii.startsWithIgnoreCase(rest, pattern) else std.mem.startsWith(u8, rest, pattern)) return i;
    }
    return null;
}

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const expectCursor = h.expectCursor;
const expectText = h.expectText;
const runTyped = h.runTyped;

test ":q quits only without unsaved changes, :q! always" {
    var e = try testEditor("abc\n");
    defer e.deinit();
    try testing.expectEqual(Editor.Action.quit, try runTyped(&e, "q"));
    try typeKeys(&e, "x");
    try testing.expectEqual(Editor.Action.none, try runTyped(&e, "q"));
    try testing.expectEqualStrings("E37: No write since last change (add ! to override)", e.message.text());
    try testing.expect(e.message.is_error);
    try testing.expectEqual(Editor.Action.quit, try runTyped(&e, "q!"));
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
    try testing.expectEqual(Editor.Action.none, try runTyped(&e, "w"));
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
    try testing.expectEqual(Editor.Action.none, try runTyped(&e, "frobnicate"));
    try testing.expectEqualStrings("E492: Not an editor command: frobnicate", e.message.text());
    try typeKeys(&e, "l"); // any key clears the message
    try testing.expectEqual(@as(usize, 0), e.message.len);

    try typeKeys(&e, ":q");
    _ = try e.handleKey(.escape);
    try testing.expectEqual(Editor.Mode.normal, e.mode);
    try typeKeys(&e, ":q\x7f\x7f");
    try testing.expectEqual(Editor.Mode.normal, e.mode);
    try typeKeys(&e, "x"); // back in normal mode: deletes a character
    try expectText(&e, "ac\n");
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

test ":N and :$ go to a line; numbers past the end go to the last line" {
    var e = try testEditor("a\n  b\nc\n");
    defer e.deinit();
    _ = try runTyped(&e, "2");
    try expectCursor(&e, 1, 2);
    _ = try runTyped(&e, "$");
    try expectCursor(&e, 2, 0);
    _ = try runTyped(&e, "1");
    _ = try runTyped(&e, "99");
    try expectCursor(&e, 2, 0);
}

test ":e reloads only without unsaved changes, :e! always" {
    var e: Editor = try .init(testing.allocator, try .init(testing.allocator, "one\ntwo\n"), "f.txt");
    defer e.deinit();
    try testing.expectEqualStrings("f.txt", (try runTyped(&e, "e")).reload);
    try typeKeys(&e, "jx");
    try testing.expectEqual(Editor.Action.none, try runTyped(&e, "e"));
    try testing.expectEqualStrings("E37: No write since last change (add ! to override)", e.message.text());
    try testing.expectEqualStrings("f.txt", (try runTyped(&e, "e!")).reload);

    // The caller loads the file and hands it back.
    try e.reloaded(try .init(testing.allocator, "one\ntwo\nthree\n"));
    try expectText(&e, "one\ntwo\nthree\n");
    try expectCursor(&e, 1, 0); // same line
    try testing.expect(!e.isModified());
    try typeKeys(&e, "u"); // a fresh undo history
    try testing.expectEqualStrings("Already at oldest change", e.message.text());
}

test ":w on a read-only file needs !" {
    var e: Editor = try .init(testing.allocator, try .init(testing.allocator, "abc\n"), "ro.txt");
    defer e.deinit();
    e.readonly = true;
    try typeKeys(&e, "x");
    try testing.expectEqual(Editor.Action.none, try runTyped(&e, "w"));
    try testing.expectEqualStrings("E45: File is read-only (add ! to override)", e.message.text());
    try testing.expectEqual(Editor.Action.none, try runTyped(&e, "wq"));
    try testing.expect((try runTyped(&e, "w!")).write.force);
    try testing.expectEqualStrings("copy.txt", (try runTyped(&e, "w copy.txt")).write.path); // another file is fine
}

test "the first change to a read-only file warns once" {
    var e = try testEditor("abc\n");
    defer e.deinit();
    e.readonly = true;
    try typeKeys(&e, "l");
    try testing.expectEqual(@as(usize, 0), e.message.len);
    try typeKeys(&e, "x");
    try testing.expectEqualStrings("W10: Warning: Changing a readonly file", e.message.text());
    try typeKeys(&e, "x");
    try testing.expectEqual(@as(usize, 0), e.message.len);
}
