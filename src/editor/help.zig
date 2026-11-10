//! `\help`: the help page, shown in place of the text until q or Escape.
//!
//! The page is an editor of its own over the help text, one that refuses
//! changes (`Editor.view_only`): moving, searching, selecting and yanking
//! all work as usual, and what is yanked lands in the real editor's register.

const std = @import("std");
const Editor = @import("../Editor.zig");
const Buffer = @import("../Buffer.zig");
const Key = @import("../keys.zig").Key;

pub const name = "zvim help";
const hint = "q or Esc closes this page";
pub const refusal = "The help page can't be changed (q or Esc closes it)";

pub const text =
    \\zvim help                                        (q or Esc closes this)
    \\
    \\zvim uses Vim's keys and : commands. Its own commands come after \, a
    \\key Vim leaves unused. This page covers only what is zvim's own.
    \\
    \\COMMANDS
    \\  \help                 this page
    \\  \set                  show every setting
    \\  \set name             turn a setting on       \set expandtab
    \\  \set noname           turn it off             \set noexpandtab
    \\  \set name=4           give it a number        \set shiftwidth=4
    \\  \set name?            show one setting
    \\
    \\SETTINGS                 (short name, default)
    \\  ignorecase   ic  on   searches ignore case...
    \\  smartcase    scs on   ...unless the search has a capital letter
    \\  autoindent   ai  on   new lines copy the indentation of the line above
    \\  expandtab    et  off  Tab and > insert spaces instead of a tab
    \\  shiftwidth   sw  8    how many spaces that is
    \\  tabstop      ts  8    how wide a tab looks
    \\
    \\SETTINGS FILE
    \\  ~/.config/zvim/zvimrc (or $XDG_CONFIG_HOME/zvim/zvimrc) is read at
    \\  startup: the same commands, one per line, with or without the \.
    \\    " a comment
    \\    set expandtab shiftwidth=4
    \\  Without the file zvim uses the defaults above. zvim -c ignores it.
    \\
    \\WHAT ZVIM DOES BY ITSELF
    \\  Clipboard     every yank also goes to the system clipboard, where the
    \\                terminal allows it (also over SSH)
    \\  Pasting       text pasted from the terminal goes in as it is, in any
    \\                mode, without being indented or run as keys
    \\  Recovery      after a crash or a lost connection, unsaved text is in
    \\                name.zvim-recover next to the file (or in /tmp)
    \\  Read-only     [RO] in the status bar; :w is refused, :w! overwrites
    \\  Changed file  :w is refused if the file changed on disk since it was
    \\                read; :w! overwrites, :e! reloads
    \\  Line endings  Windows (CRLF) files stay that way: [CRLF]
    \\  This page     move, search, select and yank here as in any file
    \\
    \\DIFFERENT FROM VIM
    \\  Settings are \set, not :set, and there are only the ones above.
    \\  / and ? search for plain text, not patterns.
    \\  One file at a time; :e reloads it, it doesn't open another.
    \\  One register: no "a, and no macros, marks, :s, windows or tabs.
    \\  Files are read as UTF-8.
    \\
;

pub fn open(ed: *Editor) !void {
    if (ed.help != null or ed.view_only) return;
    const gpa = ed.gpa;
    const page = try gpa.create(Editor);
    errdefer gpa.destroy(page);
    var buffer: Buffer = try .init(gpa, text);
    errdefer buffer.deinit();
    page.* = try .init(gpa, buffer, name);
    page.view_only = true;
    page.readonly = true;
    page.settings = ed.settings;
    page.view_rows = ed.view_rows;
    page.setMessage(false, hint, .{});
    ed.help = page;
}

pub fn close(ed: *Editor) void {
    const page = ed.help orelse return;
    ed.help = null;
    page.deinit();
    ed.gpa.destroy(page);
}

/// A key while the help page is open: q or Escape in normal mode (and :q)
/// close it; anything else goes to the page.
pub fn key(ed: *Editor, k: Key) !Editor.Action {
    const page = ed.help.?;
    if (page.mode == .normal and page.pending.isEmpty()) {
        if (k == .escape or (k == .char and k.char == 'q')) {
            close(ed);
            return .none;
        }
    }
    switch (try page.handleKey(k)) {
        .none => {},
        .quit => close(ed),
        .@"suspend" => return .@"suspend",
        .write, .reload => page.setMessage(true, refusal, .{}),
    }
    // Something yanked on the page is for use in the text.
    if (ed.help != null and page.clipboard_pending) {
        page.clipboard_pending = false;
        std.mem.swap(Editor.Register, &ed.register, &page.register);
        std.mem.swap(std.ArrayList(u8), &ed.clipboard, &page.clipboard);
        ed.clipboard_pending = true;
    }
    return .none;
}

const testing = std.testing;
const h = @import("testing.zig");

test "\\help opens the help page; q, Escape and :q close it" {
    var e = try h.testEditor("abc\n");
    defer e.deinit();
    for ([_][]const u8{ "q", "\x1b", ":q\r" }) |closing| {
        try h.typeKeys(&e, "\\help\r");
        try testing.expect(e.help != null);
        try testing.expectEqualStrings(name, e.help.?.name.items);
        try h.typeKeys(&e, "jjw");
        try h.expectCursor(e.help.?, 2, 5);
        try h.expectCursor(&e, 0, 0); // the text underneath is untouched
        try h.typeKeys(&e, closing);
        try testing.expect(e.help == null);
    }
    try h.typeKeys(&e, "x");
    try h.expectText(&e, "bc\n");
}

test "the help page can be searched, selected and yanked from, into the text" {
    var e = try h.testEditor("abc\n");
    defer e.deinit();
    try h.typeKeys(&e, "\\help\r/SETTINGS FILE\rvey");
    try testing.expect(e.clipboard_pending);
    try testing.expectEqualStrings("SETTINGS", e.clipboard.items);
    try h.typeKeys(&e, "v");
    try h.typeThenEscape(&e, ""); // Escape leaves visual mode first...
    try testing.expect(e.help != null);
    try h.typeThenEscape(&e, ""); // ...then closes the page
    try testing.expect(e.help == null);
    try h.typeKeys(&e, "P");
    try h.expectText(&e, "SETTINGSabc\n");
}

test "the help page can't be changed" {
    var e = try h.testEditor("abc\n");
    defer e.deinit();
    try h.typeKeys(&e, "\\help\r");
    const page = e.help.?;
    for ([_][]const u8{ "x", "dd", "dw", "i", "A", "o", "cw", "rz", "p", "J", ">>", "u", ".", "vd", "Vc", "\x16jI", "3x", "\\help\r", ":w out\r", ":e!\r" }) |keys| {
        try h.typeKeys(&e, keys);
        try testing.expect(page.message.is_error or std.mem.eql(u8, keys, "\\help\r"));
        try h.typeThenEscape(page, "");
        try testing.expectEqual(Editor.Mode.normal, page.mode);
        try h.expectText(page, text);
        try testing.expect(!page.isModified());
    }
    _ = try e.handleKey(.{ .paste = "pasted" });
    try h.expectText(page, text);
    try h.expectText(&e, "abc\n");
}

test "the help page fits in 80 columns" {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try testing.expect(line.len <= 78);
}
