const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;
const Buffer = @import("buffer.zig").Buffer;
const Editor = @import("editor.zig").Editor;
const Tree = @import("tree.zig").Tree;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    if (args.len > 2) {
        try std.io.getStdErr().writeAll("usage: zvim [file|dir]\n");
        std.process.exit(1);
    }

    const arg: []const u8 = if (args.len == 2) args[1] else "";
    const is_dir = arg.len > 0 and blk: {
        var d = std.fs.cwd().openDir(arg, .{}) catch break :blk false;
        d.close();
        break :blk true;
    };

    var tree = try Tree.init(alloc, if (is_dir) arg else ".");
    defer tree.deinit();

    var term = try Terminal.init();
    defer term.deinit();

    const buf = try Buffer.load(alloc, if (is_dir) "" else arg);
    var ed = try Editor.init(alloc, &term, buf);
    defer ed.deinit();
    ed.tree = &tree;
    if (is_dir) {
        ed.tree_visible = true;
        ed.focus = .tree;
    }

    while (!ed.quit) {
        try ed.render();
        try ed.handleKey(try term.readKey());
    }
}
