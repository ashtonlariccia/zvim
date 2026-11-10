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
    \\zvim: a small Vim-like editor
    \\
    \\THE BASICS
    \\  i            start typing (insert mode); Esc goes back to normal mode
    \\  :w  :q  :wq  save, quit, both            :q!  quit without saving
    \\  u  Ctrl-R    undo, redo                  .    repeat the last change
    \\  \help        this page                   \set settings (see below)
    \\
    \\MOVING
    \\  h j k l      left, down, up, right (or the arrow keys)
    \\  w b e        next word, back a word, end of word (W B E: by blanks)
    \\  0 ^ $        start of line, first non-blank, end of line
    \\  gg G  5G     first line, last line, line 5 (also :5 and :$)
    \\  f t F T + c  to / before the next (previous) c on the line;  ; ,  repeat
    \\  Ctrl-D/U     half a screen down / up
    \\  /text ?text  search forward / backward (plain text);  n N  next, previous
    \\
    \\CHANGING
    \\  i a I A      insert before / after the cursor, at line start / end
    \\  o O          open a line below / above
    \\  d y c        delete, yank (copy), change + a motion: dw  y$  c2w  d/foo
    \\  dd yy cc     ...the whole line;  > <  indent, outdent (>> <<)
    \\  x X s S D C Y  the usual shortcuts
    \\  p P          paste after / before         J  join lines
    \\  r + c        replace the character with c
    \\  3j 2dw 5x    a count before anything repeats it
    \\
    \\TEXT OBJECTS (after an operator, or in visual mode)
    \\  iw aw        a word            i" a" i' a' i` a`   inside / around quotes
    \\  i( a( i[ a[ i{ a{ i< a<   inside / around brackets     ip ap  paragraph
    \\  e.g. diw  ci"  ya(  vip
    \\
    \\SELECTING
    \\  v V Ctrl-V   select characters, lines, a block; move to extend
    \\  o            jump to the other end of the selection
    \\  y d c > < J p   act on the selection      I A  type on every block line
    \\
    \\FILES
    \\  :w name      save under a name            :w!  overwrite regardless
    \\  :e  :e!      reload from disk (:e! drops unsaved changes)
    \\  Ctrl-Z       suspend zvim; fg in the shell comes back
    \\  [RO] read-only file   [CRLF] Windows line endings   [+] unsaved changes
    \\  Yanks also go to the system clipboard where the terminal allows it.
    \\  After a crash or lost connection, unsaved text is in name.zvim-recover.
    \\
    \\SETTINGS
    \\  \set                       show them all
    \\  \set expandtab             Tab and > insert spaces...
    \\  \set shiftwidth=4          ...this many
    \\  \set noexpandtab           no- turns one off
    \\  \set tabstop=4             how wide a tab looks
    \\  \set noautoindent          new lines don't copy the indentation above
    \\  \set noignorecase          searches match case exactly
    \\  \set nosmartcase           /Foo also finds foo (with ignorecase)
    \\  To keep settings, put the same lines, without the \, in
    \\  ~/.config/zvim/zvimrc. zvim -c starts without that file.
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
        try h.expectCursor(e.help.?, 2, 4);
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
    try h.typeKeys(&e, "\\help\r/THE BASICS\rvey");
    try testing.expect(e.clipboard_pending);
    try testing.expectEqualStrings("THE", e.clipboard.items);
    try h.typeKeys(&e, "v");
    try h.typeThenEscape(&e, ""); // Escape leaves visual mode first...
    try testing.expect(e.help != null);
    try h.typeThenEscape(&e, ""); // ...then closes the page
    try testing.expect(e.help == null);
    try h.typeKeys(&e, "P");
    try h.expectText(&e, "THEabc\n");
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
