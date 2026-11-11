//! Syntax highlighting, entirely from language files in the config
//! folder's syntax/ directory, written by the user; nothing is built in.
//!
//! A language file, one directive per line (a line starting with " is a
//! comment):
//!
//!     extensions  c h                  files it's for
//!     shebang     python python3       scripts it's for, by their #! line
//!     keyword     if else while        words in a group (any group)
//!     span comment /* */               from /* to */, across lines
//!     span comment //                  from // to the end of the line
//!     span string " " escape=\ oneline must close on the same line
//!     span keyword # start             only at the start of a line
//!     span comment # alone             only at the start or after a blank
//!     prefix function @                @name
//!     suffix function !                name!
//!     numbers                          42, 0xff, 3.14
//!     functions                        a word followed by (
//!
//! Groups: comment string number keyword type constant function todo.
//! `todo` words are marked only inside comments.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");

pub const Group = enum { comment, string, number, keyword, type, constant, function, todo };

pub const Color = union(enum) {
    /// The terminal's own text colour.
    none,
    /// One of the terminal's 16 colours.
    ansi: u4,
    rgb: [3]u8,

    const names = [_][]const u8{
        "black",       "red",       "green",       "yellow",       "blue",       "magenta",       "cyan",       "white",
        "brightblack", "brightred", "brightgreen", "brightyellow", "brightblue", "brightmagenta", "brightcyan", "brightwhite",
    };

    /// A name (red, brightblue, grey), #rrggbb, or none.
    pub fn parse(s: []const u8) ?Color {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "grey") or std.mem.eql(u8, s, "gray")) return .{ .ansi = 8 };
        for (names, 0..) |name, i| if (std.mem.eql(u8, s, name)) return .{ .ansi = @intCast(i) };
        if (s.len == 7 and s[0] == '#') {
            var rgb: [3]u8 = undefined;
            for (&rgb, 0..) |*c, i| c.* = std.fmt.parseInt(u8, s[1 + 2 * i ..][0..2], 16) catch return null;
            return .{ .rgb = rgb };
        }
        return null;
    }

    pub fn format(c: Color, w: *std.Io.Writer) !void {
        switch (c) {
            .none => try w.writeAll("none"),
            .ansi => |n| try w.writeAll(names[n]),
            .rgb => |rgb| try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ rgb[0], rgb[1], rgb[2] }),
        }
    }

    /// The escape sequence that sets this as the text colour.
    pub fn sgr(c: Color, buf: *[24]u8) []const u8 {
        return c.sgrAt(buf, 0);
    }

    /// The escape sequence that sets this as the background colour.
    pub fn bgSgr(c: Color, buf: *[24]u8) []const u8 {
        return c.sgrAt(buf, 10);
    }

    /// Background codes are the text colour codes plus 10.
    fn sgrAt(c: Color, buf: *[24]u8, plus: u8) []const u8 {
        return switch (c) {
            .none => "",
            .ansi => |n| std.fmt.bufPrint(buf, "\x1b[{d}m", .{plus + if (n < 8) 30 + @as(u8, n) else 90 + @as(u8, n) - 8}) catch unreachable,
            .rgb => |rgb| std.fmt.bufPrint(buf, "\x1b[{d};2;{d};{d};{d}m", .{ 38 + plus, rgb[0], rgb[1], rgb[2] }) catch unreachable,
        };
    }
};

pub const Colors = std.enums.EnumArray(Group, Color);

pub const default_colors: Colors = .init(.{
    .comment = .{ .ansi = 8 },
    .string = .{ .ansi = 2 },
    .number = .{ .ansi = 1 },
    .keyword = .{ .ansi = 5 },
    .type = .{ .ansi = 3 },
    .constant = .{ .ansi = 1 },
    .function = .{ .ansi = 4 },
    .todo = .{ .ansi = 11 },
});

const Span = struct {
    group: Group,
    open: []const u8,
    /// Null: to the end of the line.
    close: ?[]const u8 = null,
    escape: ?u8 = null,
    /// Must close on the line it opens on, or it isn't one.
    oneline: bool = false,
    /// Only at the first non-blank of a line.
    at_start: bool = false,
    /// Only at the start of a line or after a blank.
    alone: bool = false,
};

/// The first problem found in a language file.
pub const Problem = struct {
    line: usize = 0,
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn text(p: *const Problem) []const u8 {
        return p.buf[0..p.len];
    }

    fn set(p: *Problem, line: usize, comptime fmt: []const u8, args: anytype) void {
        if (p.len > 0) return;
        p.line = line;
        p.len = if (std.fmt.bufPrint(&p.buf, fmt, args)) |t| t.len else |_| p.buf.len;
    }
};

pub const Language = struct {
    arena: std.heap.ArenaAllocator,
    extensions: std.ArrayList([]const u8) = .empty,
    shebangs: std.ArrayList([]const u8) = .empty,
    spans: std.ArrayList(Span) = .empty,
    words: std.StringHashMapUnmanaged(Group) = .empty,
    prefix: [128]?Group = @splat(null),
    suffix: [128]?Group = @splat(null),
    numbers: bool = false,
    functions: bool = false,
    has_todo: bool = false,

    pub fn deinit(lang: *Language) void {
        lang.arena.deinit();
    }

    /// Reads a language file. Bad lines are skipped; the first is described
    /// in `problem`.
    pub fn parse(gpa: Allocator, contents: []const u8, problem: *Problem) !Language {
        var lang: Language = .{ .arena = .init(gpa) };
        errdefer lang.deinit();
        const a = lang.arena.allocator();
        const own = try a.dupe(u8, contents);

        var lines = std.mem.splitScalar(u8, own, '\n');
        var number: usize = 0;
        while (lines.next()) |raw| {
            number += 1;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '"') continue;
            var it = std.mem.tokenizeAny(u8, line, " \t");
            const directive = it.next().?;
            if (std.mem.eql(u8, directive, "extensions") or std.mem.eql(u8, directive, "extension")) {
                while (it.next()) |ext| try lang.extensions.append(a, std.mem.trimStart(u8, ext, "."));
            } else if (std.mem.eql(u8, directive, "shebang")) {
                while (it.next()) |name| try lang.shebangs.append(a, name);
            } else if (std.mem.eql(u8, directive, "numbers")) {
                lang.numbers = true;
            } else if (std.mem.eql(u8, directive, "functions")) {
                lang.functions = true;
            } else if (std.mem.eql(u8, directive, "span")) {
                const group = groupOf(it.next(), problem, number, "span comment /* */") orelse continue;
                var span: Span = .{ .group = group, .open = it.next() orelse {
                    problem.set(number, "span needs what it starts with: span comment //", .{});
                    continue;
                } };
                while (it.next()) |word| {
                    if (std.mem.eql(u8, word, "oneline")) {
                        span.oneline = true;
                    } else if (std.mem.eql(u8, word, "start")) {
                        span.at_start = true;
                    } else if (std.mem.eql(u8, word, "alone")) {
                        span.alone = true;
                    } else if (std.mem.startsWith(u8, word, "escape=") and word.len == 8) {
                        span.escape = word[7];
                    } else if (span.close == null) {
                        span.close = word;
                    } else {
                        problem.set(number, "not a span option: {s}", .{word});
                    }
                }
                try lang.spans.append(a, span);
            } else if (std.mem.eql(u8, directive, "prefix") or std.mem.eql(u8, directive, "suffix")) {
                const table = if (directive[0] == 'p') &lang.prefix else &lang.suffix;
                const group = groupOf(it.next(), problem, number, if (directive[0] == 'p') "prefix function @" else "suffix function !") orelse continue;
                for (it.next() orelse "") |c| {
                    if (c < 128) table[c] = group;
                }
            } else if (groupNamed(directive)) |group| {
                if (group == .todo) lang.has_todo = true;
                while (it.next()) |word| try lang.words.put(a, word, group);
            } else {
                problem.set(number, "unknown: {s}", .{directive});
            }
        }
        return lang;
    }

    /// Whether this language is for the file at `path`, whose first line is
    /// `first_line`.
    pub fn isFor(lang: *const Language, path: []const u8, first_line: []const u8) bool {
        const base = std.fs.path.basename(path);
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
            for (lang.extensions.items) |ext| if (std.mem.eql(u8, base[dot + 1 ..], ext)) return true;
        }
        if (!std.mem.startsWith(u8, first_line, "#!")) return false;
        // #!/bin/sh, #!/usr/bin/env python3
        var it = std.mem.tokenizeAny(u8, first_line[2..], " \t\r");
        var program = std.fs.path.basename(it.next() orelse return false);
        if (std.mem.eql(u8, program, "env")) program = it.next() orelse return false;
        for (lang.shebangs.items) |name| if (std.mem.eql(u8, program, name)) return true;
        return false;
    }
};

/// The group a directive names, or null with the problem described.
fn groupOf(word: ?[]const u8, problem: *Problem, line: usize, example: []const u8) ?Group {
    const name = word orelse {
        problem.set(line, "needs a group: {s}", .{example});
        return null;
    };
    return groupNamed(name) orelse {
        problem.set(line, "not a group: {s} (comment string number keyword type constant function todo)", .{name});
        return null;
    };
}

fn groupNamed(name: []const u8) ?Group {
    return std.meta.stringToEnum(Group, name);
}

pub fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// A stretch of a line in a group's colour; byte offsets in the line.
pub const Run = struct { start: usize, end: usize, group: Group };

/// Where a line starts: outside any span (0), or inside span n - 1.
const State = u16;

/// Scans one line that starts in `state`, adding its coloured runs to
/// `runs` if given, and returns the state the next line starts in.
fn scanLine(lang: *const Language, s: []const u8, state: State, runs: ?*std.ArrayList(Run), gpa: Allocator) !State {
    var i: usize = 0;
    if (state > 0) {
        const span = lang.spans.items[state - 1];
        const end = closeOf(span, s, 0) orelse {
            try emit(lang, runs, gpa, s, 0, s.len, span.group);
            return state;
        };
        try emit(lang, runs, gpa, s, 0, end, span.group);
        i = end;
    }
    const first_non_blank = for (s, 0..) |c, k| {
        if (c != ' ' and c != '\t') break k;
    } else s.len;

    outer: while (i < s.len) {
        const c = s[i];
        const after_word = i > 0 and isWordChar(s[i - 1]);
        for (lang.spans.items, 0..) |span, k| {
            if (!std.mem.startsWith(u8, s[i..], span.open)) continue;
            if (span.at_start and i != first_non_blank) continue;
            if (span.alone and i > 0 and s[i - 1] != ' ' and s[i - 1] != '\t') continue;
            const close = span.close orelse {
                try emit(lang, runs, gpa, s, i, s.len, span.group);
                return 0;
            };
            _ = close;
            if (closeOf(span, s, i + span.open.len)) |end| {
                try emit(lang, runs, gpa, s, i, end, span.group);
                i = end;
                continue :outer;
            }
            if (span.oneline) continue;
            try emit(lang, runs, gpa, s, i, s.len, span.group);
            return @intCast(k + 1);
        }
        if (c < 128 and lang.prefix[c] != null and !after_word and i + 1 < s.len and isWordChar(s[i + 1])) {
            const end = wordEnd(s, i + 1);
            try emit(lang, runs, gpa, s, i, end, lang.prefix[c].?);
            i = end;
            continue;
        }
        if (isWordChar(c) and !after_word) {
            const end = wordEnd(s, i);
            if (std.ascii.isDigit(c)) {
                var e = i;
                while (e < s.len and (isWordChar(s[e]) or (s[e] == '.' and !std.mem.startsWith(u8, s[e..], "..")))) e += 1;
                if (lang.numbers) try emit(lang, runs, gpa, s, i, e, .number);
                i = e;
                continue;
            }
            if (lang.words.get(s[i..end])) |group| {
                if (group != .todo) try emit(lang, runs, gpa, s, i, end, group);
            } else if (end < s.len and s[end] < 128 and lang.suffix[s[end]] != null and
                !(end + 1 < s.len and s[end + 1] == '='))
            {
                try emit(lang, runs, gpa, s, i, end + 1, lang.suffix[s[end]].?);
                i = end + 1;
                continue;
            } else if (lang.functions and end < s.len and s[end] == '(') {
                try emit(lang, runs, gpa, s, i, end, .function);
            }
            i = end;
            continue;
        }
        i += 1;
    }
    return 0;
}

fn wordEnd(s: []const u8, from: usize) usize {
    var e = from;
    while (e < s.len and isWordChar(s[e])) e += 1;
    return e;
}

/// Where `span` closes in `s`, searching from `from`: the offset after its
/// closing text, or null if it doesn't close on this line.
fn closeOf(span: Span, s: []const u8, from: usize) ?usize {
    const close = span.close orelse return null;
    var j = from;
    while (j < s.len) {
        if (span.escape != null and s[j] == span.escape.?) {
            j += 2;
            continue;
        }
        if (std.mem.startsWith(u8, s[j..], close)) return j + close.len;
        j += 1;
    }
    return null;
}

/// Adds a run; in a comment, `todo` words get runs of their own.
fn emit(lang: *const Language, runs: ?*std.ArrayList(Run), gpa: Allocator, s: []const u8, start: usize, end: usize, group: Group) !void {
    const list = runs orelse return;
    if (start >= end) return;
    if (group != .comment or !lang.has_todo) return list.append(gpa, .{ .start = start, .end = end, .group = group });
    var from = start;
    var i = start;
    while (i < end) {
        if (!isWordChar(s[i]) or (i > start and isWordChar(s[i - 1]))) {
            i += 1;
            continue;
        }
        const e = @min(wordEnd(s, i), end);
        if (lang.words.get(s[i..e]) == .todo) {
            if (from < i) try list.append(gpa, .{ .start = from, .end = i, .group = .comment });
            try list.append(gpa, .{ .start = i, .end = e, .group = .todo });
            from = e;
        }
        i = e;
    }
    if (from < end) try list.append(gpa, .{ .start = from, .end = end, .group = .comment });
}

/// Colours the lines of a buffer in one language. Remembers the state each
/// line starts in, so only the lines from an edit on are scanned again.
pub const Highlighter = struct {
    gpa: Allocator,
    lang: Language,
    /// `states[n]`: the state line n starts in.
    states: std.ArrayList(State) = .empty,
    line_text: std.ArrayList(u8) = .empty,
    runs: std.ArrayList(Run) = .empty,

    pub fn init(gpa: Allocator, lang: Language) Highlighter {
        return .{ .gpa = gpa, .lang = lang };
    }

    pub fn deinit(h: *Highlighter) void {
        h.lang.deinit();
        h.states.deinit(h.gpa);
        h.line_text.deinit(h.gpa);
        h.runs.deinit(h.gpa);
    }

    /// Forgets what an edit to `buffer` since the last call may have changed.
    pub fn sync(h: *Highlighter, buffer: *Buffer) void {
        if (buffer.changed_from == std.math.maxInt(usize)) return;
        const line = buffer.lineOf(@min(buffer.changed_from, buffer.len));
        // The state a line starts in depends only on the lines above it.
        h.states.shrinkRetainingCapacity(@min(h.states.items.len, line + 1));
        buffer.changed_from = std.math.maxInt(usize);
    }

    fn readLine(h: *Highlighter, buffer: *const Buffer, line: usize) ![]const u8 {
        const start = buffer.lineStart(line);
        const end = if (line + 1 < buffer.lineCount()) buffer.lineStart(line + 1) - 1 else buffer.len;
        try h.line_text.resize(h.gpa, end - start);
        buffer.read(start, h.line_text.items);
        return h.line_text.items;
    }

    /// The coloured runs of `line`, until the next call.
    pub fn lineRuns(h: *Highlighter, buffer: *const Buffer, line: usize) ![]const Run {
        if (h.states.items.len == 0) try h.states.append(h.gpa, 0);
        while (h.states.items.len <= line) {
            const n = h.states.items.len - 1;
            const next = try scanLine(&h.lang, try h.readLine(buffer, n), h.states.items[n], null, h.gpa);
            try h.states.append(h.gpa, next);
        }
        h.runs.clearRetainingCapacity();
        _ = try scanLine(&h.lang, try h.readLine(buffer, line), h.states.items[line], &h.runs, h.gpa);
        return h.runs.items;
    }
};

const testing = std.testing;

fn expectRuns(lang: *const Language, line: []const u8, state: State, expected: []const u8) !State {
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(testing.allocator);
    const next = try scanLine(lang, line, state, &runs, testing.allocator);
    // Each byte shown as the first letter of its group, or . for none.
    var got: [128]u8 = @splat('.');
    for (runs.items) |r| for (r.start..r.end) |i| {
        got[i] = switch (r.group) {
            .function => 'f',
            .todo => 'T',
            else => @tagName(r.group)[0],
        };
    };
    try testing.expectEqualStrings(expected, got[0..line.len]);
    return next;
}

test "a language file colours words, spans, numbers and calls" {
    var problem: Problem = .{};
    var lang = try Language.parse(testing.allocator,
        \\" a C-like language
        \\extensions  x .y
        \\keyword     if return
        \\type        int
        \\constant    NULL
        \\todo        TODO
        \\span comment //
        \\span comment /* */
        \\span string " " escape=\ oneline
        \\span keyword # start
        \\prefix function @
        \\suffix function !
        \\numbers
        \\functions
    , &problem);
    defer lang.deinit();
    try testing.expectEqual(@as(usize, 0), problem.len);

    _ = try expectRuns(&lang, "if (f(x)) return 0x1F;", 0, "kk..f.....kkkkkk.nnnn.");
    _ = try expectRuns(&lang, "int a = \"q\\\"x\"; // TODO: y", 0, "ttt.....ssssss..cccTTTTccc");
    _ = try expectRuns(&lang, "  #define X @b m! m!=", 0, "..kkkkkkkkkkkkkkkkkkk");
    _ = try expectRuns(&lang, "x = @b + m! + m != a#b", 0, "....ff...ff...........");
    _ = try expectRuns(&lang, "\"open and 1..2 NULLs", 0, "..........n..n......");
    // A block comment carries on to the next line.
    const next = try expectRuns(&lang, "a /* b", 0, "..cccc");
    try testing.expect(next != 0);
    try testing.expectEqual(@as(State, 0), try expectRuns(&lang, "c */ int", next, "cccc.ttt"));
}

test "bad lines are reported, the rest still apply" {
    var problem: Problem = .{};
    var lang = try Language.parse(testing.allocator, "keyword if\nkeywrd x\nspan\nspan commant /* */\n", &problem);
    defer lang.deinit();
    try testing.expectEqual(@as(usize, 2), problem.line);
    try testing.expectEqualStrings("unknown: keywrd", problem.text());
    try testing.expectEqual(Group.keyword, lang.words.get("if").?);
    for ([_][2][]const u8{
        .{ "span", "needs a group: span comment /* */" },
        .{ "span commant /* */", "not a group: commant (comment string number keyword type constant function todo)" },
        .{ "suffix", "needs a group: suffix function !" },
        .{ "span string \" \" twice over", "not a span option: twice" },
    }) |case| {
        var p: Problem = .{};
        var l = try Language.parse(testing.allocator, case[0], &p);
        l.deinit();
        try testing.expectEqualStrings(case[1], p.text());
    }
}

test "a language is picked by extension or #! line" {
    var problem: Problem = .{};
    var lang = try Language.parse(testing.allocator, "extension py\nshebang python3\n", &problem);
    defer lang.deinit();
    try testing.expect(lang.isFor("dir.d/a.py", ""));
    try testing.expect(!lang.isFor("a.pyc", ""));
    try testing.expect(lang.isFor("script", "#!/usr/bin/env python3"));
    try testing.expect(lang.isFor("script", "#!/usr/bin/python3 -u"));
    try testing.expect(!lang.isFor("script", "#!/bin/sh"));
}

test "colours: names, #rrggbb and none" {
    try testing.expectEqual(Color{ .ansi = 12 }, Color.parse("brightblue").?);
    try testing.expectEqual(Color{ .rgb = .{ 0xe5, 0xc0, 0x7b } }, Color.parse("#e5c07b").?);
    try testing.expectEqual(Color.none, Color.parse("none").?);
    try testing.expect(Color.parse("#e5c07") == null and Color.parse("blurple") == null);
    var buf: [24]u8 = undefined;
    try testing.expectEqualStrings("\x1b[94m", Color.sgr(.{ .ansi = 12 }, &buf));
    try testing.expectEqualStrings("\x1b[38;2;229;192;123m", Color.sgr(.{ .rgb = .{ 0xe5, 0xc0, 0x7b } }, &buf));
}

test "the highlighter rescans only from an edit down" {
    var problem: Problem = .{};
    const lang = try Language.parse(testing.allocator, "span comment /* */\n", &problem);
    var h: Highlighter = .init(testing.allocator, lang);
    defer h.deinit();
    var b: Buffer = try .init(testing.allocator, "a\n/* b\nc */\nd\n");
    defer b.deinit();
    h.sync(&b);
    try testing.expectEqual(@as(usize, 1), (try h.lineRuns(&b, 2)).len);
    try testing.expectEqual(@as(usize, 0), (try h.lineRuns(&b, 3)).len);
    try b.delete(2, 2); // "/* b" -> " b"
    h.sync(&b);
    try testing.expectEqual(@as(usize, 2), h.states.items.len);
    try testing.expectEqual(@as(usize, 0), (try h.lineRuns(&b, 2)).len);
}
