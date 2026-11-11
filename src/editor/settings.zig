//! Settings, and the settings file that sets them, read at startup:
//! `set` lines, each turning settings on or off or giving them a number.
//!
//!     " a comment
//!     set expandtab shiftwidth=4    turn on, give a value
//!     set noautoindent              turn off

const std = @import("std");
const Editor = @import("../Editor.zig");
const text = @import("../text.zig");
const syntax_ = @import("../syntax.zig");

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
    /// Line numbers down the left: each line's own...
    number: bool = false,
    /// ...or its distance from the cursor's line, which shows its own.
    relativenumber: bool = false,
    /// Shade the cursor's line, in `cursorline_color`.
    cursorline: bool = true,
    /// How long a message stays in the bottom row before the status bar
    /// comes back, in milliseconds; 0 keeps it until the next key.
    messagetime: usize = 1000,
    /// Brackets and quotes typed in insert mode come in pairs (see
    /// autoclose.zig).
    autoclose: bool = false,
    /// Colour files by the language files in syntax/ (see syntax.zig).
    syntax: bool = true,
    /// Set by `color` lines, not `set`.
    colors: syntax_.Colors = syntax_.default_colors,
    /// The cursor line's background; set by `color cursorline`.
    cursorline_color: syntax_.Color = .{ .rgb = .{ 0x30, 0x30, 0x30 } },
};

pub const max_width = 32;

const Option = enum {
    ignorecase,
    smartcase,
    autoindent,
    expandtab,
    tabstop,
    shiftwidth,
    number,
    relativenumber,
    cursorline,
    messagetime,
    autoclose,
    syntax,

    const short = [_][]const u8{ "ic", "scs", "ai", "et", "ts", "sw", "nu", "rnu", "cul", "mt", "ac", "syn" };

    /// For the settings file and --help.
    const about = [_][]const u8{
        "Searches ignore case...",
        "...unless the search has a capital letter in it",
        "New lines copy the indentation of the line above",
        "Tab and > insert spaces instead of a tab",
        "How wide a tab looks on screen (1 to 32)",
        "How many spaces expandtab inserts (1 to 32)",
        "Line numbers down the left...",
        "...or each line's distance from the cursor",
        "Shade the cursor's line",
        "How long messages show, in ms (0: until a key)",
        "Typed brackets and quotes come in pairs",
        "Colour files by the language files in syntax/",
    };

    /// The numbers a number setting takes.
    fn range(option: Option) [2]usize {
        return switch (option) {
            .messagetime => .{ 0, 60_000 },
            else => .{ 1, max_width },
        };
    }

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
        .number => .{ .flag = &settings.number },
        .relativenumber => .{ .flag = &settings.relativenumber },
        .cursorline => .{ .flag = &settings.cursorline },
        .messagetime => .{ .number = &settings.messagetime },
        .autoclose => .{ .flag = &settings.autoclose },
        .syntax => .{ .flag = &settings.syntax },
    };
}

/// Applies the settings file: `set` and `color` lines. Blank lines and anything from a " on are
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
        else if (std.mem.eql(u8, command, "color"))
            color(ed, words.rest())
        else blk: {
            ed.setMessage(true, "only set and color lines work here: {s}", .{line});
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

/// The arguments of a `color` line: groups, then the colour they get.
fn color(ed: *Editor, args: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, args, '"') orelse args.len;
    var words: [16][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, args[0..end], " \t");
    while (it.next()) |word| : (n += 1) {
        if (n == words.len) break;
        words[n] = word;
    }
    if (n < 2) {
        ed.setMessage(true, "color needs groups and a colour: color keyword type magenta", .{});
        return false;
    }
    const value = syntax_.Color.parse(words[n - 1]) orelse {
        ed.setMessage(true, "not a colour: {s} (a name like green or brightblue, #rrggbb, or none)", .{words[n - 1]});
        return false;
    };
    for (words[0 .. n - 1]) |name| if (!isCursorline(name) and std.meta.stringToEnum(syntax_.Group, name) == null) {
        ed.setMessage(true, "not a group: {s} (comment string number keyword type constant function todo cursorline)", .{name});
        return false;
    };
    for (words[0 .. n - 1]) |name| {
        if (isCursorline(name)) {
            ed.settings.cursorline_color = value;
        } else ed.settings.colors.set(std.meta.stringToEnum(syntax_.Group, name).?, value);
    }
    return true;
}

/// `color cursorline` is the cursor line's background, not a group.
fn isCursorline(name: []const u8) bool {
    return std.mem.eql(u8, name, "cursorline");
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
            const min, const max = option.range();
            const n = if (off or eq == null) null else std.fmt.parseInt(usize, arg[eq.? + 1 ..], 10) catch null;
            if (n == null or n.? < min or n.? > max) {
                ed.setMessage(true, "{s} takes a number from {d} to {d}: {s}", .{ @tagName(option), min, max, arg });
                return false;
            }
            number.* = n.?;
        },
    }
    return true;
}

/// Each group with its default colour, in `fmt` (group name, colour).
pub fn writeColors(w: *std.Io.Writer, comptime fmt: []const u8) !void {
    for (std.enums.values(syntax_.Group)) |group| try w.print(fmt, .{ @tagName(group), syntax_.default_colors.get(group) });
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
        try w.print("  {s:<14} {s:<3} {s:<4} {s}\n", .{ @tagName(option), short, default, about });
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
    try testing.expectEqualStrings("zvimrc line 1: only set and color lines work here: \\set et", e.message.text());
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
        .{ "set mt=60001", "zvimrc line 1: messagetime takes a number from 0 to 60000: mt=60001" },
    }) |case| {
        load(&e, case[0]);
        try testing.expectEqualStrings(case[1], e.message.text());
    }
    try testing.expectEqualDeep(Settings{}, e.settings);
    load(&e, "set nu rnu mt=0");
    try testing.expect(e.settings.number and e.settings.relativenumber);
    try testing.expectEqual(@as(usize, 0), e.settings.messagetime);
}

test "the settings list for --help" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeList(&w);
    try testing.expectEqualStrings(
        \\  ignorecase     ic  on   Searches ignore case...
        \\  smartcase      scs on   ...unless the search has a capital letter in it
        \\  autoindent     ai  on   New lines copy the indentation of the line above
        \\  expandtab      et  off  Tab and > insert spaces instead of a tab
        \\  tabstop        ts  4    How wide a tab looks on screen (1 to 32)
        \\  shiftwidth     sw  4    How many spaces expandtab inserts (1 to 32)
        \\  number         nu  off  Line numbers down the left...
        \\  relativenumber rnu off  ...or each line's distance from the cursor
        \\  cursorline     cul on   Shade the cursor's line
        \\  messagetime    mt  1000 How long messages show, in ms (0: until a key)
        \\  autoclose      ac  off  Typed brackets and quotes come in pairs
        \\  syntax         syn on   Colour files by the language files in syntax/
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

test "color lines give one or more groups a colour" {
    var e = try testEditor("");
    defer e.deinit();
    load(&e,
        \\color keyword type #e5c07b " both
        \\color comment grey
        \\color string none
    );
    try testing.expectEqual(@as(usize, 0), e.message.len);
    const Color = syntax_.Color;
    try testing.expectEqual(Color{ .rgb = .{ 0xe5, 0xc0, 0x7b } }, e.settings.colors.get(.keyword));
    try testing.expectEqual(Color{ .rgb = .{ 0xe5, 0xc0, 0x7b } }, e.settings.colors.get(.type));
    try testing.expectEqual(Color{ .ansi = 8 }, e.settings.colors.get(.comment));
    try testing.expectEqual(Color.none, e.settings.colors.get(.string));

    load(&e, "color keyword blurple");
    try testing.expectEqualStrings("zvimrc line 1: not a colour: blurple (a name like green or brightblue, #rrggbb, or none)", e.message.text());
    load(&e, "color keywords red");
    try testing.expectEqualStrings("zvimrc line 1: not a group: keywords (comment string number keyword type constant function todo cursorline)", e.message.text());
    load(&e, "color red");
    try testing.expectEqualStrings("zvimrc line 1: color needs groups and a colour: color keyword type magenta", e.message.text());
    try testing.expectEqual(Color{ .rgb = .{ 0xe5, 0xc0, 0x7b } }, e.settings.colors.get(.keyword));
}
