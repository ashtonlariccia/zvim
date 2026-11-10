const std = @import("std");
const Terminal = @import("term.zig").Terminal;
const ui = @import("ui.zig");
const file = @import("file.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 2) fatal("usage: zvim [file]", .{});
    const path: []const u8 = if (args.len == 2) args[1] else "";

    var buffer = if (path.len > 0)
        file.load(init.gpa, init.io, .cwd(), path) catch |err|
            fatal("cannot open {s}: {s}", .{ path, @errorName(err) })
    else
        try @import("Buffer.zig").init(init.gpa, "");
    defer buffer.deinit();

    var term = try Terminal.init();
    defer term.deinit();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;

    var size = Terminal.size();
    var top: usize = 0;
    var left: usize = 0;
    var in_buf: [256]u8 = undefined;
    while (true) {
        const view: ui.View = .{ .buffer = &buffer, .name = path, .top = top, .left = left };
        try ui.draw(out, size, view);
        try out.flush();

        switch (try term.next(&in_buf)) {
            .resize => size = Terminal.size(),
            .input => |bytes| for (bytes) |key| switch (key) {
                'q' => return,
                'j' => top = @min(top + 1, buffer.visibleLineCount() - 1),
                'k' => top -|= 1,
                'h' => left -|= 1,
                'l' => if (left < ui.maxLeft(size, .{ .buffer = &buffer, .name = path, .top = top })) {
                    left += 1;
                },
                else => {},
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
}
