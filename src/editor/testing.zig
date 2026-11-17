//! Helpers for editor tests: type keys at an editor and check the result.

const std = @import("std");
const testing = std.testing;
const Editor = @import("../Editor.zig");
const Decoder = @import("../keys.zig").Decoder;

/// An editor with tabs and no autoclose, whatever the defaults are, so
/// tests don't change with them; tests of those settings turn them on.
pub fn testEditor(content: []const u8) !Editor {
    var e: Editor = try .init(testing.allocator, try .init(testing.allocator, content), "");
    e.settings.expandtab = false;
    e.settings.autoclose = false;
    return e;
}

pub fn typeKeys(e: *Editor, input: []const u8) !void {
    var d: Decoder = .{ .bytes = input };
    while (d.next()) |key| try testing.expectEqual(Editor.Action.none, try e.handleKey(key));
}

pub fn expectCursor(e: *Editor, line: usize, byte: usize) !void {
    const pos = try e.cursorPos();
    try testing.expectEqual(line, pos.line);
    try testing.expectEqual(byte, pos.byte);
}

pub fn expectText(e: *Editor, expected: []const u8) !void {
    const got = try e.buffer.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

/// Types `input`, then Escape. Escape goes separately because a byte right
/// after it in the same input would read as an escape sequence.
pub fn typeThenEscape(e: *Editor, input: []const u8) !void {
    try typeKeys(e, input);
    _ = try e.handleKey(.escape);
}

/// Types `:` and `command`, presses Enter, and returns the resulting action.
pub fn runTyped(e: *Editor, command: []const u8) !Editor.Action {
    try typeKeys(e, ":");
    try typeKeys(e, command);
    return e.handleKey(.enter);
}

pub fn expectRegister(e: *Editor, kind: @FieldType(Editor.Register, "kind"), expected: []const u8) !void {
    try testing.expectEqual(kind, e.register.kind);
    try testing.expectEqualStrings(expected, e.register.text.items);
}
