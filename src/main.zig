const std = @import("std");
const Terminal = @import("term.zig").Terminal;
const ui = @import("ui.zig");

pub fn main(init: std.process.Init) !void {
    var term = try Terminal.init();
    defer term.deinit();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;

    var size = Terminal.size();
    var in_buf: [256]u8 = undefined;
    while (true) {
        try ui.drawFrame(out, size);
        try out.flush();

        switch (try term.next(&in_buf)) {
            .resize => size = Terminal.size(),
            .input => |bytes| if (std.mem.indexOfScalar(u8, bytes, 'q') != null) return,
        }
    }
}

test {
    _ = @import("ui.zig");
    _ = @import("term.zig");
    _ = @import("Buffer.zig");
    _ = @import("text.zig");
    _ = @import("file.zig");
}
