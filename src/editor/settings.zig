//! The editor's settings, with their values fixed here for now.

const std = @import("std");

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
    relativenumber: bool = true,
    /// Shade the cursor's line.
    cursorline: bool = true,
    /// How long a message stays in the bottom row before the status bar
    /// comes back, in milliseconds; 0 keeps it until the next key.
    messagetime: usize = 1250,
    /// Brackets and quotes typed in insert mode come in pairs (see
    /// autoclose.zig).
    autoclose: bool = true,
};

pub const max_width = 32;

const testing = std.testing;
const h = @import("testing.zig");
const testEditor = h.testEditor;
const typeKeys = h.typeKeys;
const typeThenEscape = h.typeThenEscape;
const expectCursor = h.expectCursor;
const expectText = h.expectText;

test "expandtab: Tab and > insert spaces to the next stop, < removes them" {
    var e = try testEditor("ab\n");
    defer e.deinit();
    e.settings.expandtab = true;
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
    e.settings.autoindent = false;
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

    e.settings.smartcase = false;
    try typeKeys(&e, "gg/FOO\r");
    try expectCursor(&e, 1, 0);
    e.settings.ignorecase = false;
    try typeKeys(&e, "gg/foo\r");
    try expectCursor(&e, 2, 0);
}
