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
    var editor: Editor = try .init(init.gpa, buffer, path);
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
            .name = editor.name.items,
            .top = editor.top,
            .left = editor.left,
            .cursor = .{ .line = pos.line, .col = pos.col },
            .cursor_shape = if (editor.mode == .insert) .bar else .block,
            .mode = if (editor.mode == .insert) "-- INSERT --" else "",
            .modified = editor.isModified(),
            .command = if (editor.mode == .command) editor.command.items else null,
            .message = if (editor.message.len > 0)
                .{ .text = editor.message.text(), .is_error = editor.message.is_error }
            else
                null,
        });
        try out.flush();

        switch (try term.next(&in_buf)) {
            .resize => size = Terminal.size(),
            .input => |bytes| {
                var keys: Decoder = .{ .bytes = bytes };
                while (keys.next()) |key| switch (try editor.handleKey(key)) {
                    .none => {},
                    .quit => return,
                    .write => |write| {
                        file.save(&editor.buffer, init.io, .cwd(), write.path) catch |err| {
                            editor.writeFailed(write.path, err);
                            continue;
                        };
                        editor.wrote(write.path);
                        if (write.then_quit) return;
                    },
                };
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
    _ = @import("History.zig");
}
