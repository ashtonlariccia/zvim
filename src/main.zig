const std = @import("std");
const Terminal = @import("term.zig").Terminal;
const ui = @import("ui.zig");
const file = @import("file.zig");
const Editor = @import("Editor.zig");
const Decoder = @import("keys.zig").Decoder;
const crash = @import("crash.zig");
const build_options = @import("build_options");

/// On a crash, save unsaved changes and restore the terminal first.
pub const panic = std.debug.FullPanic(crash.panic);

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
    noteRecoveryFile(&editor, init.io, path);

    // `run` restores the terminal when it returns; anything but a normal
    // quit then saves unsaved changes to a recovery file.
    const end = run(init, &editor) catch |err| {
        var buf: crash.PathBuffer = undefined;
        if (crash.saveRecovery(&editor, &buf)) |saved| {
            std.debug.print("zvim: {s}. Unsaved changes were saved to {s}\n", .{ @errorName(err), saved });
        }
        return err;
    };
    if (end == .hangup) {
        var buf: crash.PathBuffer = undefined;
        if (crash.saveRecovery(&editor, &buf)) |saved| {
            std.debug.print("zvim: the session ended. Unsaved changes were saved to {s}\n", .{saved});
        }
        std.process.exit(1);
    }
}

/// Tells the user, in the status line, if a crash left a recovery file for
/// this file.
fn noteRecoveryFile(editor: *Editor, io: std.Io, path: []const u8) void {
    var buf: crash.PathBuffer = undefined;
    const recovery = crash.recoveryPath(&buf, path) orelse return;
    std.Io.Dir.cwd().access(io, recovery, .{}) catch return;
    editor.setMessage(true, "{s} exists: unsaved changes from a crash", .{recovery});
}

fn run(init: std.process.Init, editor: *Editor) !enum { quit, hangup } {
    var term = try Terminal.init();
    defer term.deinit();
    crash.install(editor, &term);
    defer crash.uninstall();

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;

    var size = Terminal.size();
    var in_buf: [4096]u8 = undefined;
    var in_paste = false;
    while (true) {
        if (editor.clipboard_pending) {
            editor.clipboard_pending = false;
            try copyToClipboard(init.gpa, out, editor.clipboard.items);
        }
        try editor.scrollToCursor(ui.textRows(size), size.cols);
        const pos = try editor.cursorPos();
        const selection: ?ui.Selection = if (try editor.selection()) |sel| .{
            .kind = switch (sel.kind) {
                .char => .char,
                .line => .line,
                .block => .block,
            },
            .first_line = sel.first_line,
            .last_line = sel.last_line,
            .start_col = sel.start_col,
            .end_col = sel.end_col,
        } else null;
        try ui.draw(out, size, .{
            .buffer = &editor.buffer,
            .name = editor.name.items,
            .top = editor.top,
            .left = editor.left,
            .cursor = .{ .line = pos.line, .col = pos.col },
            .cursor_shape = if (editor.mode == .insert) .bar else .block,
            .mode = modeLabel(editor),
            .modified = editor.isModified(),
            .command = if (editor.mode == .command) editor.command.items else null,
            .command_prefix = switch (editor.command_kind) {
                .ex => ':',
                .search_forward => '/',
                .search_backward => '?',
            },
            .selection = selection,
            .message = if (editor.message.len > 0)
                .{ .text = editor.message.text(), .is_error = editor.message.is_error }
            else
                null,
        });
        try out.flush();

        switch (try term.next(&in_buf)) {
            .resize => size = Terminal.size(),
            .hangup => return .hangup,
            .input => |bytes| {
                var keys: Decoder = .{ .bytes = bytes, .in_paste = in_paste };
                defer in_paste = keys.in_paste;
                while (keys.next()) |key| {
                    if (build_options.test_crash and key == .ctrl and key.ctrl == 0x7c) {
                        @panic("test crash (Ctrl-\\ in a -Dtest-crash build)");
                    }
                    switch (try editor.handleKey(key)) {
                        .none => {},
                        .quit => return .quit,
                        .write => |write| {
                            file.save(&editor.buffer, init.io, .cwd(), write.path) catch |err| {
                                editor.writeFailed(write.path, err);
                                continue;
                            };
                            editor.wrote(write.path);
                            if (write.then_quit) return .quit;
                        },
                    }
                }
            },
        }
    }
}

/// Puts `text` on the system clipboard with OSC 52, which terminals such as
/// wezterm, kitty and iTerm2 support, also over SSH.
fn copyToClipboard(gpa: std.mem.Allocator, out: *std.Io.Writer, text: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const encoded = try gpa.alloc(u8, encoder.calcSize(text.len));
    defer gpa.free(encoded);
    try out.writeAll("\x1b]52;c;");
    try out.writeAll(encoder.encode(encoded, text));
    try out.writeAll("\x07");
}

fn modeLabel(editor: *const Editor) []const u8 {
    const mode = if (editor.mode == .command) editor.command_return else editor.mode;
    return switch (mode) {
        .insert => "-- INSERT --",
        .visual => switch (editor.visual_kind) {
            .char => "-- VISUAL --",
            .line => "-- VISUAL LINE --",
            .block => "-- VISUAL BLOCK --",
        },
        else => "",
    };
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
    _ = @import("crash.zig");
    _ = @import("editor/words.zig");
}
