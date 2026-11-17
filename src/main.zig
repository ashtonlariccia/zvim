const std = @import("std");
const Terminal = @import("term.zig").Terminal;
const ui = @import("ui.zig");
const file = @import("file.zig");
const Editor = @import("Editor.zig");
const Decoder = @import("keys.zig").Decoder;
const crash = @import("crash.zig");
const clipboard = @import("clipboard.zig");
const build_options = @import("build_options");

/// On a crash, save unsaved changes and restore the terminal first.
pub const panic = std.debug.FullPanic(crash.panic);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var path: []const u8 = "";
    // +N opens at line N, + at the last line.
    var start_line: ?usize = null;
    for (args[1..]) |arg| {
        const help_flag = std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
        const version_flag = std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v");
        if (help_flag or version_flag) {
            var buf: [1024]u8 = undefined;
            var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buf);
            if (help_flag) try writeUsage(&stdout.interface) else try stdout.interface.print("zvim {s}\n", .{build_options.version});
            try stdout.interface.flush();
            return;
        }
        if (arg.len > 0 and arg[0] == '+') {
            start_line = if (arg.len == 1) std.math.maxInt(usize) else std.fmt.parseInt(usize, arg[1..], 10) catch
                fatal("not a line number: {s}", .{arg});
        } else if (arg.len > 1 and arg[0] == '-') {
            fatal("unknown option: {s} (a file starting with - opens as ./{s})", .{ arg, arg });
        } else if (path.len == 0) {
            path = arg;
        } else fatal(short_usage, .{});
    }

    const loaded: file.Loaded = if (path.len > 0)
        file.load(init.gpa, init.io, .cwd(), path) catch |err|
            fatal("cannot open {s}: {s}", .{ path, @errorName(err) })
    else
        .{ .buffer = try @import("Buffer.zig").init(init.gpa, ""), .crlf = false };
    var editor: Editor = try .init(init.gpa, loaded.buffer, path);
    defer editor.deinit();
    editor.crlf = loaded.crlf;
    editor.readonly = isReadOnly(init.io, path);
    if (start_line) |n| try editor.goToLine(n);
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

/// Reads the file at `path` back in, replacing the buffer.
fn reload(io: std.Io, editor: *Editor, path: []const u8, disk: *?DiskStamp) !void {
    const fresh = file.load(editor.gpa, io, .cwd(), path) catch |err| {
        editor.setMessage(true, "E484: Can't read {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    try editor.reloaded(fresh.buffer);
    disk.* = DiskStamp.of(io, path);
    editor.crlf = fresh.crlf;
    editor.readonly = isReadOnly(io, path);
}

/// On getting the focus back: if something else changed the file, reload
/// it when there's nothing unsaved to lose, or warn once when there is.
fn checkDisk(io: std.Io, editor: *Editor, disk: *?DiskStamp, warned: *?DiskStamp) !void {
    const path = editor.name.items;
    if (path.len == 0 or disk.* == null) return;
    const now = DiskStamp.of(io, path);
    if (DiskStamp.eql(disk.*, now) or DiskStamp.eql(warned.*, now)) return;
    if (now == null) {
        editor.setMessage(true, "W13: {s} was deleted on disk (:w to write it again)", .{path});
    } else if (editor.isModified()) {
        editor.setMessage(true, "W12: {s} changed on disk, and you have unsaved changes (:e! to reload, :w! to overwrite)", .{path});
    } else {
        try reload(io, editor, path, disk);
        editor.setMessage(false, "\"{s}\" changed on disk: reloaded", .{path});
        return;
    }
    warned.* = now;
}

/// Whether `path` exists but can't be written by this user.
fn isReadOnly(io: std.Io, path: []const u8) bool {
    if (path.len == 0) return false;
    std.Io.Dir.cwd().access(io, path, .{ .write = true }) catch |err| return switch (err) {
        error.FileNotFound => false,
        else => true,
    };
    return false;
}

/// Tells the user, in the status line, if a crash left a recovery file for
/// this file.
fn noteRecoveryFile(editor: *Editor, io: std.Io, path: []const u8) void {
    var buf: crash.PathBuffer = undefined;
    const recovery = crash.recoveryPath(&buf, path) orelse return;
    std.Io.Dir.cwd().access(io, recovery, .{}) catch return;
    editor.setMessage(true, "{s} exists: unsaved changes from a crash", .{recovery});
}

/// What the file on disk looked like when zvim last read or wrote it, to
/// notice when something else changes it.
const DiskStamp = struct {
    mtime: i96,
    size: u64,

    fn of(io: std.Io, path: []const u8) ?DiskStamp {
        if (path.len == 0) return null;
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
        return .{ .mtime = st.mtime.nanoseconds, .size = st.size };
    }

    fn eql(a: ?DiskStamp, b: ?DiskStamp) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return x.mtime == y.mtime and x.size == y.size;
    }
};

fn run(init: std.process.Init, editor: *Editor) !enum { quit, hangup } {
    var term = try Terminal.init();
    defer term.deinit();
    crash.install(editor, &term);
    defer crash.uninstall();
    var disk = DiskStamp.of(init.io, editor.name.items);

    var out_buf: [16 * 1024]u8 = undefined;
    var out_file: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &out_buf);
    const out = &out_file.interface;

    var size = Terminal.size();
    // What's on the screen, so each frame sends only what changed.
    var frame: ui.Frame = .init(init.gpa);
    defer frame.deinit();
    var in_buf: [4096]u8 = undefined;
    // Bytes of a key that may still be arriving (see `Decoder.final`) wait
    // at the start of `in_buf` for the rest, for up to `key_wait_ms`.
    var pending: usize = 0;
    var in_paste = false;
    var in_osc = false;
    // A reply from the terminal in an OSC sequence, as it comes in.
    var osc: std.ArrayList(u8) = .empty;
    defer osc.deinit(init.gpa);
    const place: clipboard.Place = .of(init.environ_map);
    // A "+p waiting for the terminal to answer with the clipboard, and
    // when to give up on it.
    var clipboard_wait: ?struct { request: Editor.ClipboardPaste, until: i64 } = null;
    // The terminal speaks the kitty keyboard protocol: Escape comes as a
    // sequence, so a lone escape byte is always the start of one.
    var keyboard_protocol = false;
    // The disk version last warned about, so the warning isn't repeated
    // each time the window gets the focus.
    var warned: ?DiskStamp = null;
    // When the message in the bottom row gives way to the status bar again.
    var message_until = messageDeadline(init.io, editor);
    while (true) {
        const nu = editor.settings.number;
        const rnu = editor.settings.relativenumber;
        const numbers: ui.Numbers = if (rnu) .relative else if (nu) .absolute else .none;
        try editor.scrollToCursor(ui.textRows(size), ui.textCols(size, numbers, editor.buffer.visibleLineCount()));
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
        if (editor.redraw_requested) {
            editor.redraw_requested = false;
            frame.invalidate();
        }
        try ui.drawFrame(out, size, .{
            .buffer = &editor.buffer,
            .name = editor.name.items,
            .top = editor.top,
            .left = editor.left,
            .cursor = .{ .line = pos.line, .col = pos.col },
            .cursor_shape = if (editor.mode == .insert) .bar else .block,
            .mode = modeLabel(editor),
            .modified = editor.isModified(),
            .crlf = editor.crlf,
            .readonly = editor.readonly,
            .command = if (editor.mode == .command) editor.command.items else null,
            .command_prefix = switch (editor.command_kind) {
                .ex => ':',
                .search_forward => '/',
                .search_backward => '?',
            },
            .selection = selection,
            .numbers = numbers,
            .cursorline = editor.settings.cursorline,
            .message = if (editor.message.len > 0)
                .{ .text = editor.message.text(), .is_error = editor.message.is_error }
            else
                null,
        }, &frame);
        try out.flush();

        const now = std.Io.Timestamp.now(init.io, .awake).toMilliseconds();
        const until = earliest(message_until, if (clipboard_wait) |w| w.until else null);
        const wait: ?i32 = if (pending > 0)
            (if (keyboard_protocol) sequence_wait_ms else key_wait_ms)
        else if (until) |u|
            @intCast(std.math.clamp(u - now, 0, std.math.maxInt(i32)))
        else
            null;
        const event = try term.next(in_buf[pending..], wait);
        var input: []const u8, var final = switch (event) {
            .resize => {
                size = Terminal.size();
                frame.invalidate(); // terminals may reflow or clear on resize
                continue;
            },
            .hangup => return .hangup,
            .timeout => if (pending == 0) {
                const later = std.Io.Timestamp.now(init.io, .awake).toMilliseconds();
                if (clipboard_wait != null and later >= clipboard_wait.?.until) {
                    clipboard_wait = null;
                    editor.setMessage(true, "No answer from the terminal: it may not let programs read the clipboard (OSC 52)", .{});
                    message_until = messageDeadline(init.io, editor);
                } else if (message_until != null and later >= message_until.?) {
                    editor.message.len = 0;
                    message_until = null;
                }
                continue;
            } else .{ in_buf[0..pending], true },
            .input => |bytes| .{ in_buf[0 .. pending + bytes.len], false },
        };
        var focus_in = false;
        while (true) {
            var keys: Decoder = .{ .bytes = input, .in_paste = in_paste, .in_osc = in_osc, .final = final };
            while (keys.next()) |key| {
                if (key == .osc) {
                    if (osc.items.len < 2 * clipboard.max_read) try osc.appendSlice(init.gpa, key.osc.bytes);
                    if (!key.osc.done) continue;
                    defer osc.clearRetainingCapacity();
                    const w = clipboard_wait orelse continue;
                    const clip = try clipboard.decodeReply(init.gpa, osc.items) orelse continue;
                    defer init.gpa.free(clip);
                    clipboard_wait = null;
                    try editor.pasteClipboard(clip, w.request);
                    continue;
                }
                if (build_options.test_crash and key == .ctrl and key.ctrl == 0x7c) {
                    @panic("test crash (Ctrl-\\ in a -Dtest-crash build)");
                }
                switch (try editor.handleKey(key)) {
                    .none => {},
                    .quit => return .quit,
                    .reload => |reload_path| try reload(init.io, editor, reload_path, &disk),
                    .paste_clipboard => |request| switch (try clipboard.read(init.gpa, init.io, place, out)) {
                        .text => |clip| {
                            defer init.gpa.free(clip);
                            try editor.pasteClipboard(clip, request);
                        },
                        .asked => clipboard_wait = .{
                            .request = request,
                            .until = std.Io.Timestamp.now(init.io, .awake).toMilliseconds() + clipboard.timeout_ms,
                        },
                    },
                    .@"suspend" => {
                        term.suspendProcess();
                        size = Terminal.size();
                        frame.invalidate();
                    },
                    .write => |write| {
                        // Don't silently overwrite changes made by something else.
                        const own_file = std.mem.eql(u8, write.path, editor.name.items);
                        if (own_file and !write.force and disk != null and
                            !DiskStamp.eql(disk, DiskStamp.of(init.io, write.path)))
                        {
                            editor.setMessage(true, "W12: {s} changed on disk since it was read (:w! to overwrite, :e! to reload)", .{write.path});
                            continue;
                        }
                        file.save(&editor.buffer, init.io, .cwd(), write.path, editor.crlf) catch |err| {
                            editor.writeFailed(write.path, err);
                            continue;
                        };
                        editor.wrote(write.path);
                        if (own_file) disk = DiskStamp.of(init.io, write.path);
                        if (write.then_quit) return .quit;
                    },
                }
            }
            in_paste = keys.in_paste;
            in_osc = keys.in_osc;
            keyboard_protocol = keyboard_protocol or keys.keyboard_protocol;
            focus_in = focus_in or keys.focus_in;
            const left = keys.leftover();
            // Something that long isn't a key on its way: decode it as is.
            if (left.len > 32 and !final) {
                input = left;
                final = true;
                continue;
            }
            std.mem.copyForwards(u8, in_buf[0..left.len], left);
            pending = left.len;
            break;
        }
        if (focus_in) try checkDisk(init.io, editor, &disk, &warned);
        if (editor.clipboard_pending) {
            editor.clipboard_pending = false;
            const text = editor.clipboard.items;
            if (try clipboard.copy(init.gpa, init.io, place, out, text) == .too_big) {
                editor.setMessage(true, "Yanked {d} KB: too big for the system clipboard (max {d} KB), kept in zvim only", .{ text.len / 1024, clipboard.max_copy / 1024 });
            }
        }
        // Each key clears the message; one there now is new.
        message_until = messageDeadline(init.io, editor);
    }
}

const short_usage = "usage: zvim [+line] [file]";

fn writeUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: zvim [+line] [file]
        \\
        \\A small Vim-like editor. Opens `file` (created on the first :w if it
        \\doesn't exist), or an empty buffer. Keys work like Vim's: i to type,
        \\Esc to stop, :w to save, :q to quit, :q! to quit without saving.
        \\
        \\  +N              start at line N (+ alone: the last line)
        \\  -h, --help      show this help
        \\  -v, --version   show the version
        \\
        \\WHAT ZVIM DOES BY ITSELF
        \\  Clipboard     every yank also goes to the system clipboard, where the
        \\                terminal allows it (also over SSH; in tmux, through
        \\                tmux). Yanks over 100 KB stay in zvim. "+p and "+P
        \\                paste from it: locally with wl-paste, xclip, xsel or
        \\                pbpaste; over SSH by asking the terminal (OSC 52)
        \\  Pasting       text pasted from the terminal goes in as it is, in any
        \\                mode, without being indented or run as keys
        \\  Recovery      after a crash or a lost connection, unsaved text is in
        \\                file.zvim-recover next to the file (or in /tmp)
        \\  Read-only     [RO] in the status bar; :w is refused, :w! overwrites
        \\  Changed file  on getting the focus back, a file changed on disk is
        \\                reloaded, or with unsaved changes, you're warned; :w
        \\                is refused then: :w! overwrites, :e! reloads
        \\  Line endings  Windows (CRLF) files stay that way: [CRLF]
        \\
        \\DIFFERENT FROM VIM
        \\  / and ? search for plain text, not patterns.
        \\  One file at a time; :e reloads it, it doesn't open another.
        \\  One register (and "+ or "* to paste from the system clipboard): no
        \\  "a, and no macros, marks, :s, windows or tabs.
        \\  Files are read as UTF-8.
        \\
    );
}

/// When a message just shown should go, by the messagetime setting: null
/// for none, or one that stays until the next key.
fn messageDeadline(io: std.Io, editor: *const Editor) ?i64 {
    const ms = editor.settings.messagetime;
    if (editor.message.len == 0 or ms == 0) return null;
    return std.Io.Timestamp.now(io, .awake).toMilliseconds() + @as(i64, @intCast(ms));
}

/// How long to wait for the rest of a key whose first bytes arrived (an
/// escape sequence or UTF-8 character split across reads), before deciding
/// it's complete. In a terminal without the kitty keyboard protocol, a lone
/// Escape takes this long to register.
const key_wait_ms = 50;

/// The same, with the keyboard protocol: Escape isn't a lone byte then, so
/// it registers at once, and this only bounds the wait for a sequence
/// split across reads.
const sequence_wait_ms = 1000;

/// The earlier of two optional times.
fn earliest(a: ?i64, b: ?i64) ?i64 {
    return if (a != null and b != null) @min(a.?, b.?) else a orelse b;
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
    _ = @import("clipboard.zig");
    _ = @import("editor/words.zig");
}
