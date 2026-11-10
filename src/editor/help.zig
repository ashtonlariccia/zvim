//! `\help`: a page of help shown in place of the text until a key closes it.

const std = @import("std");
const Editor = @import("../Editor.zig");
const Key = @import("../keys.zig").Key;

pub const name = "zvim help";
pub const hint = "j/k or arrows scroll, g/G top/bottom, any other key closes";

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

pub const line_count = blk: {
    @setEvalBranchQuota(text.len * 2);
    var n: usize = 0;
    for (text) |c| n += @intFromBool(c == '\n');
    break :blk n;
};

/// A key while the help page is open: scroll, or close.
pub fn key(ed: *Editor, k: Key) void {
    const top = ed.help.?;
    const page = @max(ed.view_rows, 2);
    const last = line_count -| ed.view_rows;
    const new: usize = switch (k) {
        .down, .enter => top + 1,
        .up => top -| 1,
        .char => |c| switch (c) {
            'j' => top + 1,
            'k' => top -| 1,
            ' ' => top + page - 1,
            'g' => 0,
            'G' => last,
            else => return close(ed),
        },
        .ctrl => |c| switch (c) {
            'd' => top + page / 2,
            'u' => top -| page / 2,
            'f' => top + page - 1,
            'b' => top -| (page - 1),
            else => return close(ed),
        },
        else => return close(ed),
    };
    ed.help = @min(new, last);
}

fn close(ed: *Editor) void {
    ed.help = null;
}

const testing = std.testing;
const h = @import("testing.zig");

test "\\help opens the help page; keys scroll it, any other key closes it" {
    var e = try h.testEditor("abc\n");
    defer e.deinit();
    e.view_rows = 10;
    try h.typeKeys(&e, "\\help\r");
    try testing.expectEqual(@as(?usize, 0), e.help);
    try h.typeKeys(&e, "jj");
    try testing.expectEqual(@as(?usize, 2), e.help);
    try h.typeKeys(&e, "kkk");
    try testing.expectEqual(@as(?usize, 0), e.help);
    try h.typeKeys(&e, "G");
    try testing.expectEqual(@as(?usize, line_count - 10), e.help);
    try h.typeKeys(&e, "j \x04"); // can't scroll past the end
    try testing.expectEqual(@as(?usize, line_count - 10), e.help);
    try h.typeKeys(&e, "g");
    try testing.expectEqual(@as(?usize, 0), e.help);

    try h.typeKeys(&e, "x"); // closes, and is not run as a command
    try testing.expectEqual(@as(?usize, null), e.help);
    try h.expectText(&e, "abc\n");
    try h.typeKeys(&e, "x");
    try h.expectText(&e, "bc\n");
}

test "the help page fits in 80 columns" {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| try testing.expect(line.len <= 78);
}
