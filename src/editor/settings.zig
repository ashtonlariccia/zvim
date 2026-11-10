//! Settings, and the settings file that sets them, read at startup:
//! `set` lines, each turning settings on or off or giving them a number.
//!
//!     " a comment
//!     set expandtab shiftwidth=4    turn on, give a value
//!     set noautoindent              turn off

const std = @import("std");
const Editor = @import("../Editor.zig");
const text = @import("../text.zig");

pub const Settings = struct {
    /// Searches ignore case...
    ignorecase: bool = true,
    /// ...unless the pattern has a capital letter in it.
    smartcase: bool = true,
    /// New lines start with the indentation of the line above.
    autoindent: bool = true,
    /// Tab and > insert spaces rather than a tab.
    expandtab: bool = false,
    /// How wide a tab is on screen; drawing reads it as `text.tab_width`.
    tabstop: usize = 4,
    /// How many spaces, with `expandtab`.
    shiftwidth: usize = 4,
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

    /// For the settings file and --help.
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

fn valueOf(settings: *Settings, option: Option) Value {
    return switch (option) {
        .ignorecase => .{ .flag = &settings.ignorecase },
        .smartcase => .{ .flag = &settings.smartcase },
        .autoindent => .{ .flag = &settings.autoindent },
        .expandtab => .{ .flag = &settings.expandtab },
        .tabstop => .{ .number = &settings.tabstop },
        .shiftwidth => .{ .number = &settings.shiftwidth },
    };
}

/// Applies the settings file. Blank lines and anything from a " on are
/// ignored. A bad line is skipped; the first one is reported as the
/// editor's message.
pub fn load(ed: *Editor, contents: []const u8) void {
    var first_error: Editor.Message = .{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '"') continue;
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const command = words.next().?;
        const ok = if (std.mem.eql(u8, command, "set"))
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
    text.tab_width = ed.settings.tabstop;
}

/// The arguments of a `set` line. Returns false, with the reason as the
/// editor's message, at the first one that is wrong.
fn set(ed: *Editor, args: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, args, " \t");
    while (it.next()) |arg| {
        if (arg[0] == '"') break; // the rest is a comment
        if (!setOne(ed, arg)) return false;
    }
    return true;
}

fn setOne(ed: *Editor, arg: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, arg, '=');
    var name = if (eq) |i| arg[0..i] else arg;
    const off = Option.find(name) == null and std.mem.startsWith(u8, name, "no");
    if (off) name = name[2..];

    const option = Option.find(name) orelse {
        ed.setMessage(true, "unknown setting: {s}", .{arg});
        return false;
    };
    switch (valueOf(&ed.settings, option)) {
        .flag => |flag| {
            if (eq != null) {
                ed.setMessage(true, "{s} is on or off, not a number: {s}", .{ @tagName(option), arg });
                return false;
            }
            flag.* = !off;
        },
        .number => |number| {
            const n = if (off or eq == null) 0 else std.fmt.parseInt(usize, arg[eq.? + 1 ..], 10) catch 0;
            if (n < 1 or n > max_width) {
                ed.setMessage(true, "{s} takes a number from 1 to {d}: {s}", .{ @tagName(option), max_width, arg });
                return false;
            }
            number.* = n;
        },
    }
    return true;
}

/// A settings file listing every setting at its default, explained: what
/// zvim -s starts from when there's no file yet.
pub fn template(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\" zvim settings, read when zvim starts. These are the defaults.
        \\" "set name" turns a setting on, "set noname" turns it off,
        \\" "set name=4" gives it a number. " starts a comment.
        \\
    );
    var defaults: Settings = .{};
    for (std.enums.values(Option), Option.about) |option, about| {
        try w.print("\n\" {s}\n", .{about});
        switch (valueOf(&defaults, option)) {
            .flag => |flag| try w.print("set {s}{s}\n", .{ if (flag.*) "" else "no", @tagName(option) }),
            .number => |number| try w.print("set {s}={d}\n", .{ @tagName(option), number.* }),
        }
    }
}

/// The settings, for --help: name, short name, default, what it does.
pub fn writeList(w: *std.Io.Writer) !void {
    var defaults: Settings = .{};
    for (std.enums.values(Option), Option.short, Option.about) |option, short, about| {
        var buf: [8]u8 = undefined;
        const default = switch (valueOf(&defaults, option)) {
            .flag => |flag| if (flag.*) "on" else "off",
            .number => |number| std.fmt.bufPrint(&buf, "{d}", .{number.*}) catch unreachable,
        };
        try w.print("  {s:<11} {s:<4} {s:<4} {s}\n", .{ @tagName(option), short, default, about });
    }
}

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const typeThenEscape = h.typeThenEscape;
const expectCursor = h.expectCursor;
const expectText = h.expectText;

test "a settings file: set lines, comments, and the first bad line reported" {
    var e = try testEditor("");
    defer e.deinit();
    defer text.tab_width = (Settings{}).tabstop;
    load(&e,
        \\" my settings
        \\set expandtab shiftwidth=2 " two spaces
        \\
        \\  set nosmartcase ts=8
    );
    try testing.expect(e.settings.expandtab and !e.settings.smartcase);
    try testing.expectEqual(@as(usize, 2), e.settings.shiftwidth);
    try testing.expectEqual(@as(usize, 8), text.tab_width);
    try testing.expectEqual(@as(usize, 0), e.message.len);

    load(&e, "set noet\r\nset wibble\nq!\nset sw=4\n");
    try testing.expectEqualStrings("zvimrc line 2: unknown setting: wibble", e.message.text());
    try testing.expect(!e.settings.expandtab); // the good lines still apply
    try testing.expectEqual(@as(usize, 4), e.settings.shiftwidth);

    load(&e, "\\set et\n");
    try testing.expectEqualStrings("zvimrc line 1: only set lines work here: \\set et", e.message.text());
}

test "bad values are refused and leave the setting as it was" {
    var e = try testEditor("");
    defer e.deinit();
    for ([_][2][]const u8{
        .{ "set ts=0", "zvimrc line 1: tabstop takes a number from 1 to 32: ts=0" },
        .{ "set ts=many", "zvimrc line 1: tabstop takes a number from 1 to 32: ts=many" },
        .{ "set ts", "zvimrc line 1: tabstop takes a number from 1 to 32: ts" },
        .{ "set nots", "zvimrc line 1: tabstop takes a number from 1 to 32: nots" },
        .{ "set sw=33", "zvimrc line 1: shiftwidth takes a number from 1 to 32: sw=33" },
        .{ "set et=1", "zvimrc line 1: expandtab is on or off, not a number: et=1" },
    }) |case| {
        load(&e, case[0]);
        try testing.expectEqualStrings(case[1], e.message.text());
    }
    try testing.expectEqualDeep(Settings{}, e.settings);
}

test "the settings file zvim -s starts from lists every setting at its default" {
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try template(&w);
    try testing.expectEqualStrings(
        \\" zvim settings, read when zvim starts. These are the defaults.
        \\" "set name" turns a setting on, "set noname" turns it off,
        \\" "set name=4" gives it a number. " starts a comment.
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
        \\set tabstop=4
        \\
        \\" How many spaces expandtab inserts (1 to 32)
        \\set shiftwidth=4
        \\
    , w.buffered());
    // Loading it changes nothing.
    var e = try testEditor("");
    defer e.deinit();
    load(&e, w.buffered());
    try testing.expectEqual(@as(usize, 0), e.message.len);
    try testing.expectEqualDeep(Settings{}, e.settings);
}

test "the settings list for --help" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeList(&w);
    try testing.expectEqualStrings(
        \\  ignorecase  ic   on   Searches ignore case...
        \\  smartcase   scs  on   ...unless the search has a capital letter in it
        \\  autoindent  ai   on   New lines start with the indentation of the line above
        \\  expandtab   et   off  Tab and > insert spaces instead of a tab
        \\  tabstop     ts   4    How wide a tab looks on screen (1 to 32)
        \\  shiftwidth  sw   4    How many spaces expandtab inserts (1 to 32)
        \\
    , w.buffered());
}

test "expandtab: Tab and > insert spaces to the next stop, < removes them" {
    var e = try testEditor("ab\n");
    defer e.deinit();
    load(&e, "set et sw=4");
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
    load(&e, "set noai");
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

    load(&e, "set nosmartcase");
    try typeKeys(&e, "gg/FOO\r");
    try expectCursor(&e, 1, 0);
    load(&e, "set noignorecase");
    try typeKeys(&e, "gg/foo\r");
    try expectCursor(&e, 2, 0);
}
