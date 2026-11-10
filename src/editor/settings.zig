//! zvim's own commands, typed after `\` (a key Vim leaves unused, so `:`
//! stays Vim's), and the settings file of the same commands read at startup.
//! `help` shows the help page (help.zig); `set` changes settings:
//!
//!     \set expandtab shiftwidth=4    turn on, give a value
//!     \set noexpandtab               turn off
//!     \set tabstop?                  show
//!     \set                           show them all

const std = @import("std");
const Editor = @import("../Editor.zig");
const text = @import("../text.zig");
const pages = @import("page.zig");

pub const Settings = struct {
    /// Searches ignore case...
    ignorecase: bool = true,
    /// ...unless the pattern has a capital letter in it.
    smartcase: bool = true,
    /// New lines start with the indentation of the line above.
    autoindent: bool = true,
    /// Tab and > insert spaces rather than a tab.
    expandtab: bool = false,
    /// How many spaces, with `expandtab`.
    shiftwidth: usize = 8,
    // `tabstop`, how wide a tab is on screen, is `text.tab_width`.
};

pub const max_width = 32;

const Option = enum {
    ignorecase,
    smartcase,
    autoindent,
    expandtab,
    tabstop,
    shiftwidth,

    const short = [_][]const u8{ "ic", "scs", "ai", "et", "ts", "sw" };

    /// For the settings file (see `template`).
    const about = [_][]const u8{
        "Searches ignore case...",
        "...unless the search has a capital letter in it",
        "New lines start with the indentation of the line above",
        "Tab and > insert spaces instead of a tab",
        "How wide a tab looks on screen (1 to 32)",
        "How many spaces expandtab inserts (1 to 32)",
    };

    fn find(name: []const u8) ?Option {
        for (std.enums.values(Option), short) |option, alias| {
            if (std.mem.eql(u8, name, @tagName(option)) or std.mem.eql(u8, name, alias)) return option;
        }
        return null;
    }
};

const Value = union(enum) { flag: *bool, number: *usize };

fn valueOf(ed: *Editor, option: Option) Value {
    return switch (option) {
        .ignorecase => .{ .flag = &ed.settings.ignorecase },
        .smartcase => .{ .flag = &ed.settings.smartcase },
        .autoindent => .{ .flag = &ed.settings.autoindent },
        .expandtab => .{ .flag = &ed.settings.expandtab },
        .tabstop => .{ .number = &text.tab_width },
        .shiftwidth => .{ .number = &ed.settings.shiftwidth },
    };
}

/// Runs a `\` command line. Returns false, with the reason as the editor's
/// message, if it couldn't be run.
pub fn runLine(ed: *Editor, line: []const u8) !bool {
    var words = std.mem.tokenizeAny(u8, line, " \t");
    const command = words.next() orelse return true;
    if (isSet(command)) return set(ed, words.rest());
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "h")) {
        try @import("help.zig").open(ed);
        return true;
    }
    if (std.mem.eql(u8, command, "settings")) {
        ed.settings_requested = true;
        return true;
    }
    ed.setMessage(true, "Not a zvim command: {s} (try \\help)", .{std.mem.trim(u8, line, " \t")});
    return false;
}

fn isSet(command: []const u8) bool {
    return std.mem.eql(u8, command, "set") or std.mem.eql(u8, command, "se");
}

/// Runs the arguments of a `set` command. Returns false, with the reason
/// as the editor's message, at the first one that is wrong.
pub fn set(ed: *Editor, args: []const u8) bool {
    var any = false;
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |arg| {
        if (arg[0] == '"') break; // the rest is a comment
        any = true;
        if (!setOne(ed, arg)) return false;
    }
    if (!any) showAll(ed);
    return true;
}

fn setOne(ed: *Editor, arg: []const u8) bool {
    const query = arg[arg.len - 1] == '?';
    const body = if (query) arg[0 .. arg.len - 1] else arg;
    const eq = std.mem.indexOfScalar(u8, body, '=');
    var name = if (eq) |i| body[0..i] else body;
    const off = Option.find(name) == null and std.mem.startsWith(u8, name, "no");
    if (off) name = name[2..];

    const option = Option.find(name) orelse {
        ed.setMessage(true, "E518: Unknown option: {s}", .{arg});
        return false;
    };
    switch (valueOf(ed, option)) {
        .flag => |flag| {
            if (eq != null) return invalid(ed, arg);
            if (query) {
                ed.setMessage(false, "{s}{s}", .{ if (flag.*) "" else "no", @tagName(option) });
            } else flag.* = !off;
        },
        .number => |number| {
            if (off) return invalid(ed, arg);
            if (query or eq == null) {
                ed.setMessage(false, "{s}={d}", .{ @tagName(option), number.* });
                return true;
            }
            const n = std.fmt.parseInt(usize, body[eq.? + 1 ..], 10) catch 0;
            if (n < 1 or n > max_width) {
                ed.setMessage(true, "E474: {s} takes a number from 1 to {d}: {s}", .{ @tagName(option), max_width, arg });
                return false;
            }
            number.* = n;
        },
    }
    return true;
}

fn invalid(ed: *Editor, arg: []const u8) bool {
    ed.setMessage(true, "E474: Invalid argument: {s}", .{arg});
    return false;
}

fn showAll(ed: *Editor) void {
    var buf: [200]u8 = undefined;
    var len: usize = 0;
    for (std.enums.values(Option)) |option| {
        const part = switch (valueOf(ed, option)) {
            .flag => |flag| std.fmt.bufPrint(buf[len..], "{s}{s}  ", .{ if (flag.*) "" else "no", @tagName(option) }),
            .number => |number| std.fmt.bufPrint(buf[len..], "{s}={d}  ", .{ @tagName(option), number.* }),
        } catch "";
        len += part.len;
    }
    ed.setMessage(false, "{s}", .{std.mem.trimEnd(u8, buf[0..len], " ")});
}

/// Applies a settings file: one `set` command per line (a leading \ is
/// fine); blank lines and anything from a " on are ignored. A bad line
/// is skipped; the first one is reported as the editor's message.
pub fn load(ed: *Editor, contents: []const u8) void {
    var first_error: Editor.Message = .{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        var line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '\\') line = line[1..];
        if (line.len == 0 or line[0] == '"') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const command = words.next().?;
        const ok = if (isSet(command))
            set(ed, words.rest())
        else blk: {
            ed.setMessage(true, "only set lines work here: {s}", .{line});
            break :blk false;
        };
        if (!ok and first_error.len == 0) {
            const reason = ed.message;
            first_error.set(true, "zvimrc line {d}: {s}", .{ number, reason.text() });
        }
    }
    ed.message = first_error;
}

/// A settings file listing every setting at its current value, for when
/// there's no file yet.
pub fn template(ed: *Editor, gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa,
        \\" zvim settings. :w saves this file and applies it; :q goes back.
        \\" Every setting is listed. "set name" turns one on, "set noname"
        \\" turns it off, "set name=4" gives it a number.
        \\
    );
    for (std.enums.values(Option), Option.about) |option, about| {
        try out.print(gpa, "\n\" {s}\n", .{about});
        switch (valueOf(ed, option)) {
            .flag => |flag| try out.print(gpa, "set {s}{s}\n", .{ if (flag.*) "" else "no", @tagName(option) }),
            .number => |number| try out.print(gpa, "set {s}={d}\n", .{ @tagName(option), number.* }),
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Opens the settings file as a page (see page.zig): `contents` is what
/// the file at `path` holds, or null if it doesn't exist yet.
pub fn openPage(ed: *Editor, path: []const u8, contents: ?[]const u8) !void {
    const generated = if (contents == null) try template(ed, ed.gpa) else null;
    defer if (generated) |g| ed.gpa.free(g);
    const page = try pages.open(ed, path, contents orelse generated.?) orelse return;
    page.setMessage(false, "{s}:w saves and applies, :q goes back", .{if (contents == null) "New settings file. " else ""});
}

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const typeThenEscape = h.typeThenEscape;
const expectCursor = h.expectCursor;
const expectText = h.expectText;
const runTyped = h.runTyped;

/// Types `\` and `command`, then Enter.
fn run(e: *Editor, command: []const u8) !void {
    try typeKeys(e, "\\");
    try typeKeys(e, command);
    try typeKeys(e, "\r");
}

test "\\set turns settings on and off, sets numbers, and shows them" {
    var e = try testEditor("");
    defer e.deinit();
    defer text.tab_width = 8;
    try run(&e, "set");
    try testing.expectEqualStrings("ignorecase  smartcase  autoindent  noexpandtab  tabstop=8  shiftwidth=8", e.message.text());
    try run(&e, "set et sw=4 noai  ts=2");
    try testing.expect(e.settings.expandtab and !e.settings.autoindent);
    try testing.expectEqual(@as(usize, 4), e.settings.shiftwidth);
    try testing.expectEqual(@as(usize, 2), text.tab_width);
    try run(&e, "set expandtab?");
    try testing.expectEqualStrings("expandtab", e.message.text());
    try run(&e, "set noexpandtab");
    try run(&e, "set et?");
    try testing.expectEqualStrings("noexpandtab", e.message.text());
    try run(&e, "set shiftwidth");
    try testing.expectEqualStrings("shiftwidth=4", e.message.text());
}

test "\\set rejects what it doesn't understand; :set is not a command" {
    var e = try testEditor("");
    defer e.deinit();
    try testing.expectEqual(Editor.Action.none, try runTyped(&e, "set et"));
    try testing.expectEqualStrings("E492: Not an editor command: set et", e.message.text());
    try testing.expect(!e.settings.expandtab);
    try run(&e, "wibble");
    try testing.expectEqualStrings("Not a zvim command: wibble (try \\help)", e.message.text());
    try run(&e, "set wibble");
    try testing.expectEqualStrings("E518: Unknown option: wibble", e.message.text());
    try run(&e, "set ts=0");
    try testing.expectEqualStrings("E474: tabstop takes a number from 1 to 32: ts=0", e.message.text());
    try run(&e, "set ts=many");
    try testing.expect(e.message.is_error);
    try run(&e, "set et=1");
    try testing.expectEqualStrings("E474: Invalid argument: et=1", e.message.text());
    try run(&e, "set nots");
    try testing.expectEqualStrings("E474: Invalid argument: nots", e.message.text());
    try testing.expectEqual(@as(usize, 8), text.tab_width);
}

test "a settings file: set lines, comments, and the first bad line reported" {
    var e = try testEditor("");
    defer e.deinit();
    load(&e,
        \\" my settings
        \\set expandtab shiftwidth=2 " two spaces
        \\
        \\  \set nosmartcase
    );
    try testing.expect(e.settings.expandtab and !e.settings.smartcase);
    try testing.expectEqual(@as(usize, 2), e.settings.shiftwidth);
    try testing.expectEqual(@as(usize, 0), e.message.len);

    load(&e, "set noet\r\nset wibble\nq!\nset sw=4\n");
    try testing.expectEqualStrings("zvimrc line 2: E518: Unknown option: wibble", e.message.text());
    try testing.expect(!e.settings.expandtab); // the good lines still apply
    try testing.expectEqual(@as(usize, 4), e.settings.shiftwidth);

    load(&e, "w out.txt\n");
    try testing.expectEqualStrings("zvimrc line 1: only set lines work here: w out.txt", e.message.text());
}

test "expandtab: Tab and > insert spaces to the next stop, < removes them" {
    var e = try testEditor("ab\n");
    defer e.deinit();
    try run(&e, "set et sw=4");
    try typeThenEscape(&e, "i\tx\t");
    try expectText(&e, "    x   ab\n");
    try typeKeys(&e, ">>");
    try expectText(&e, "        x   ab\n");
    try typeKeys(&e, "<<<<");
    try expectText(&e, "x   ab\n");
}

test "noautoindent: new lines start at the left edge" {
    var e = try testEditor("\tone\n");
    defer e.deinit();
    try run(&e, "set noai");
    try typeThenEscape(&e, "A\rtwo");
    try typeThenEscape(&e, "othree");
    try expectText(&e, "\tone\ntwo\nthree\n");
}

test "smart case: lowercase patterns match any case, a capital makes it exact" {
    var e = try testEditor("start\nFoo\nfoo\nFOO\n");
    defer e.deinit();
    try typeKeys(&e, "/foo\r");
    try expectCursor(&e, 1, 0);
    try typeKeys(&e, "nn");
    try expectCursor(&e, 3, 0);
    try typeKeys(&e, "gg/Foo\rn"); // only the one exact match
    try expectCursor(&e, 1, 0);
    try typeKeys(&e, "G?fOO\r"); // a capital: exact, and not there
    try testing.expectEqualStrings("E486: Pattern not found: fOO", e.message.text());
    try typeKeys(&e, "G?foo\r");
    try expectCursor(&e, 2, 0);

    try run(&e, "set nosmartcase");
    try typeKeys(&e, "gg/FOO\r");
    try expectCursor(&e, 1, 0);
    try run(&e, "set noignorecase");
    try typeKeys(&e, "gg/foo\r");
    try expectCursor(&e, 2, 0);
}

test "\\settings opens the settings file as a page; saving applies it" {
    var e = try testEditor("abc\n");
    defer e.deinit();
    try typeKeys(&e, "\\settings");
    try testing.expectEqual(Editor.Action.open_settings, try e.handleKey(.enter));

    // No file yet: every setting, at its current value.
    try openPage(&e, "/home/me/.config/zvim/zvimrc", null);
    const page = e.page.?;
    try h.expectText(page,
        \\" zvim settings. :w saves this file and applies it; :q goes back.
        \\" Every setting is listed. "set name" turns one on, "set noname"
        \\" turns it off, "set name=4" gives it a number.
        \\
        \\" Searches ignore case...
        \\set ignorecase
        \\
        \\" ...unless the search has a capital letter in it
        \\set smartcase
        \\
        \\" New lines start with the indentation of the line above
        \\set autoindent
        \\
        \\" Tab and > insert spaces instead of a tab
        \\set noexpandtab
        \\
        \\" How wide a tab looks on screen (1 to 32)
        \\set tabstop=8
        \\
        \\" How many spaces expandtab inserts (1 to 32)
        \\set shiftwidth=8
        \\
    );
    try testing.expect(!page.isModified());

    // Edit it: noexpandtab -> expandtab, then :w.
    try typeKeys(&e, "/noexp\rxx");
    try testing.expect(!e.settings.expandtab); // not until it's saved
    try typeKeys(&e, ":w");
    const action = try e.handleKey(.enter);
    try testing.expectEqualStrings("/home/me/.config/zvim/zvimrc", action.write.path);
    try pages.wrote(&e, action.write.path, false);
    try testing.expect(e.settings.expandtab);
    try testing.expect(e.page != null and !page.isModified());
    try testing.expectEqualStrings("Settings saved and applied", page.message.text());

    // A bad line is reported on the page; :q then goes back to the text.
    try typeThenEscape(&e, "Goset wibble");
    try typeKeys(&e, ":q\r");
    try testing.expectEqualStrings("E37: No write since last change (add ! to override)", page.message.text());
    try typeKeys(&e, ":wq");
    const wq = try e.handleKey(.enter);
    try pages.wrote(&e, wq.write.path, wq.write.then_quit);
    try testing.expectEqualStrings("zvimrc line 22: E518: Unknown option: wibble", page.message.text());
    try testing.expect(e.page != null);
    // Fixed: :wq saves, applies and goes back.
    try typeKeys(&e, "dd:wq");
    const fixed = try e.handleKey(.enter);
    try pages.wrote(&e, fixed.write.path, fixed.write.then_quit);
    try testing.expect(e.page == null);
    try testing.expectEqualStrings("Settings saved and applied", e.message.text());
    try expectText(&e, "abc\n");
}

test "an existing settings file opens as it is" {
    var e = try testEditor("");
    defer e.deinit();
    try openPage(&e, "zvimrc", "set sw=2\n");
    try h.expectText(e.page.?, "set sw=2\n");
    try typeKeys(&e, "\\"); // no \ commands on a page
    try testing.expect(e.page.?.message.is_error);
    try testing.expectEqual(Editor.Mode.normal, e.page.?.mode);
}
