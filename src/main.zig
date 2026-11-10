const std = @import("std");
const Terminal = @import("term.zig").Terminal;
const ui = @import("ui.zig");
const file = @import("file.zig");
const Editor = @import("Editor.zig");
const Decoder = @import("keys.zig").Decoder;
const crash = @import("crash.zig");
const settings = @import("editor/settings.zig");
const build_options = @import("build_options");

/// On a crash, save unsaved changes and restore the terminal first.
pub const panic = std.debug.FullPanic(crash.panic);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var path: []const u8 = "";
    // +N opens at line N, + at the last line.
    var start_line: ?usize = null;
    var clean = false;
    var open_settings = false;
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
        if (std.mem.eql(u8, arg, "--clean") or std.mem.eql(u8, arg, "-c")) {
            clean = true;
        } else if (std.mem.eql(u8, arg, "--settings") or std.mem.eql(u8, arg, "-s")) {
            open_settings = true;
        } else if (arg.len > 0 and arg[0] == '+') {
            start_line = if (arg.len == 1) std.math.maxInt(usize) else std.fmt.parseInt(usize, arg[1..], 10) catch
                fatal("not a line number: {s}", .{arg});
        } else if (path.len == 0) {
            path = arg;
        } else fatal(short_usage, .{});
    }
    if (open_settings) {
        if (path.len > 0) fatal(short_usage, .{});
        path = settingsPath(init) orelse fatal("no home directory to keep settings in", .{});
        try createSettingsFile(init, path);
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
    if (!clean) loadSettings(init, &editor);
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

/// Applies the settings file, if there is one: $XDG_CONFIG_HOME/zvim/zvimrc,
/// or ~/.config/zvim/zvimrc.
fn loadSettings(init: std.process.Init, editor: *Editor) void {
    const arena = init.arena.allocator();
    const path = settingsPath(init) orelse return;
    const contents = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(max_settings_bytes)) catch |err| {
        if (err != error.FileNotFound) editor.setMessage(true, "cannot read {s}: {s}", .{ path, @errorName(err) });
        return;
    };
    settings.load(editor, contents);
}

/// For zvim -s: when there's no settings file yet, writes one listing
/// every setting at its default.
fn createSettingsFile(init: std.process.Init, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(init.io, dir) catch |err|
        fatal("cannot create {s}: {s}", .{ dir, @errorName(err) });
    var out: std.Io.Writer.Allocating = .init(init.arena.allocator());
    try settings.template(&out.writer);
    cwd.writeFile(init.io, .{ .sub_path = path, .data = out.written(), .flags = .{ .exclusive = true } }) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => fatal("cannot create {s}: {s}", .{ path, @errorName(err) }),
    };
}

/// A settings file larger than this isn't read.
const max_settings_bytes = 1 << 20;

fn settingsPath(init: std.process.Init) ?[]const u8 {
    const arena = init.arena.allocator();
    const env = init.environ_map;
    const xdg = env.get("XDG_CONFIG_HOME") orelse "";
    return if (xdg.len > 0)
        std.fs.path.join(arena, &.{ xdg, "zvim", "zvimrc" }) catch null
    else
        std.fs.path.join(arena, &.{ env.get("HOME") orelse return null, ".config", "zvim", "zvimrc" }) catch null;
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
    var in_buf: [4096]u8 = undefined;
    // Bytes of a key that may still be arriving (see `Decoder.final`) wait
    // at the start of `in_buf` for the rest, for up to `key_wait_ms`.
    var pending: usize = 0;
    var in_paste = false;
    // When the message in the bottom row gives way to the status bar again.
    var message_until = messageDeadline(init.io, editor);
    while (true) {
        if (editor.clipboard_pending) {
            editor.clipboard_pending = false;
            try copyToClipboard(init.gpa, out, editor.clipboard.items);
        }
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
        try ui.draw(out, size, .{
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
            .message = if (editor.message.len > 0)
                .{ .text = editor.message.text(), .is_error = editor.message.is_error }
            else
                null,
        });
        try out.flush();

        const wait: ?i32 = if (pending > 0)
            key_wait_ms
        else if (message_until) |until|
            @intCast(std.math.clamp(until - std.Io.Timestamp.now(init.io, .awake).toMilliseconds(), 0, std.math.maxInt(i32)))
        else
            null;
        const event = try term.next(in_buf[pending..], wait);
        var input: []const u8, var final = switch (event) {
            .resize => {
                size = Terminal.size();
                continue;
            },
            .hangup => return .hangup,
            .timeout => if (pending == 0) {
                editor.message.len = 0;
                message_until = null;
                continue;
            } else .{ in_buf[0..pending], true },
            .input => |bytes| .{ in_buf[0 .. pending + bytes.len], false },
        };
        while (true) {
            var keys: Decoder = .{ .bytes = input, .in_paste = in_paste, .final = final };
            while (keys.next()) |key| {
                if (build_options.test_crash and key == .ctrl and key.ctrl == 0x7c) {
                    @panic("test crash (Ctrl-\\ in a -Dtest-crash build)");
                }
                switch (try editor.handleKey(key)) {
                    .none => {},
                    .quit => return .quit,
                    .reload => |reload_path| {
                        const fresh = file.load(init.gpa, init.io, .cwd(), reload_path) catch |err| {
                            editor.setMessage(true, "E484: Can't read {s}: {s}", .{ reload_path, @errorName(err) });
                            continue;
                        };
                        try editor.reloaded(fresh.buffer);
                        disk = DiskStamp.of(init.io, reload_path);
                        editor.crlf = fresh.crlf;
                        editor.readonly = isReadOnly(init.io, reload_path);
                    },
                    .@"suspend" => {
                        term.suspendProcess();
                        size = Terminal.size();
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
        // Each key clears the message; one there now is new.
        message_until = messageDeadline(init.io, editor);
    }
}

const short_usage = "usage: zvim [-c] [+line] [file], or zvim -s";

fn writeUsage(w: *std.Io.Writer) !void {
    try w.writeAll(
        \\usage: zvim [-c] [+line] [file]
        \\       zvim -s
        \\
        \\A small Vim-like editor. Opens `file` (created on the first :w if it
        \\doesn't exist), or an empty buffer. Keys work like Vim's: i to type,
        \\Esc to stop, :w to save, :q to quit, :q! to quit without saving.
        \\
        \\  +N              start at line N (+ alone: the last line)
        \\  -c, --clean     ignore the settings file: the defaults below
        \\  -s, --settings  edit the settings file (made, with every setting
        \\                  at its default, if there isn't one)
        \\  -h, --help      show this help
        \\  -v, --version   show the version
        \\
        \\SETTINGS                    (short name, default)
        \\
    );
    try settings.writeList(w);
    try w.writeAll(
        \\
        \\  With relativenumber, the cursor's line shows its own number.
        \\
        \\  They're read at startup from ~/.config/zvim/zvimrc (or
        \\  $XDG_CONFIG_HOME/zvim/zvimrc): set lines, any number of settings
        \\  on each.
        \\    " a comment
        \\    set expandtab shiftwidth=4
        \\    set noautoindent
        \\  Without the file zvim uses the defaults. A bad line is skipped and
        \\  reported when zvim starts.
        \\
        \\WHAT ZVIM DOES BY ITSELF
        \\  Clipboard     every yank also goes to the system clipboard, where the
        \\                terminal allows it (also over SSH)
        \\  Pasting       text pasted from the terminal goes in as it is, in any
        \\                mode, without being indented or run as keys
        \\  Recovery      after a crash or a lost connection, unsaved text is in
        \\                file.zvim-recover next to the file (or in /tmp)
        \\  Read-only     [RO] in the status bar; :w is refused, :w! overwrites
        \\  Changed file  :w is refused if the file changed on disk since it was
        \\                read; :w! overwrites, :e! reloads
        \\  Line endings  Windows (CRLF) files stay that way: [CRLF]
        \\
        \\DIFFERENT FROM VIM
        \\  Settings live only in the settings file: there's no :set, and there
        \\  are only the ones above.
        \\  / and ? search for plain text, not patterns.
        \\  One file at a time; :e reloads it, it doesn't open another.
        \\  One register: no "a, and no macros, marks, :s, windows or tabs.
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
/// it's complete. A lone Escape takes this long to register.
const key_wait_ms = 50;

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
