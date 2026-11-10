const std = @import("std");
const Terminal = @import("term.zig").Terminal;
const ui = @import("ui.zig");
const file = @import("file.zig");
const Editor = @import("Editor.zig");
const Decoder = @import("keys.zig").Decoder;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) fatal("usage: zvim [file]", .{});
    const path: []const u8 = if (args.len == 2) args[1] else "";

    const buffer = if (path.len > 0)
        file.load(init.gpa, init.io, .cwd(), path) catch |err|
            fatal("cannot open {s}: {s}", .{ path, @errorName(err) })
    else
        try @import("Buffer.zig").init(init.gpa, "");
    var editor: Editor = .init(init.gpa, buffer);
    defer editor.deinit();

    var term = try Terminal.init();
    defer term.deinit();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;

    var size = Terminal.size();
    var in_buf: [256]u8 = undefined;
    while (true) {
        try editor.scrollToCursor(ui.textRows(size), size.cols);
        const pos = try editor.cursorPos();
        try ui.draw(out, size, .{
            .buffer = &editor.buffer,
            .name = path,
            .top = editor.top,
            .left = editor.left,
            .cursor = .{ .line = pos.line, .col = pos.col },
            .cursor_shape = if (editor.mode == .insert) .bar else .block,
            .mode = if (editor.mode == .insert) "-- INSERT --" else "",
            .modified = editor.modified,
        });
        try out.flush();

        switch (try term.next(&in_buf)) {
            .resize => size = Terminal.size(),
            .input => |bytes| {
                var keys: Decoder = .{ .bytes = bytes };
                while (keys.next()) |key| {
                    if (editor.mode == .normal and key == .char and key.char == 'q') return;
                    try editor.handleKey(key);
                }
            },
        }
    }
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zvim: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

test {
    _ = @import("ui.zig");
    _ = @import("term.zig");
    _ = @import("Buffer.zig");
    _ = @import("text.zig");
    _ = @import("file.zig");
    _ = @import("keys.zig");
    _ = @import("Editor.zig");
}
