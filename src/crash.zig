//! Last-resort protection for unsaved work. If zvim panics, or its session
//! ends under it (the terminal or SSH connection closes, or it's sent
//! SIGTERM), unsaved changes are written to a recovery file next to the file
//! (`notes.txt` -> `notes.txt.zvim-recover`) and the terminal is put back the
//! way it was.
//!
//! This runs when something has already gone wrong, so it allocates nothing
//! and writes with plain system calls.

const std = @import("std");
const posix = std.posix;
const sys = posix.system;
const Editor = @import("Editor.zig");
const Buffer = @import("Buffer.zig");
const Terminal = @import("term.zig").Terminal;

pub const suffix = ".zvim-recover";
/// Used for a buffer that has no file name yet.
const unnamed = "untitled";

pub const PathBuffer = [std.Io.Dir.max_path_bytes + 32]u8;

var editor: ?*Editor = null;
var terminal: ?*Terminal = null;
var handling: std.atomic.Value(bool) = .init(false);

/// Registers what to save and restore if zvim crashes.
pub fn install(ed: *Editor, term: *Terminal) void {
    editor = ed;
    terminal = term;
}

pub fn uninstall() void {
    editor = null;
    terminal = null;
}

/// The panic handler (see `panic` in main.zig): restores the terminal, saves
/// unsaved changes, then reports the crash as usual.
pub fn panic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    // A second panic while handling the first goes straight to the report.
    if (!handling.swap(true, .seq_cst)) {
        if (terminal) |t| t.deinit();
        if (editor) |ed| {
            var buf: PathBuffer = undefined;
            if (saveRecovery(ed, &buf)) |path| {
                std.debug.print("zvim crashed. Unsaved changes were saved to {s}\n", .{path});
            } else if (ed.isModified()) {
                std.debug.print("zvim crashed, and couldn't save the unsaved changes.\n", .{});
            }
        }
    }
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// The recovery file for a buffer named `name`.
pub fn recoveryPath(buf: *PathBuffer, name: []const u8) ?[:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}{s}", .{ if (name.len > 0) name else unnamed, suffix }, 0) catch null;
}

/// Writes the buffer to its recovery file if it has unsaved changes, falling
/// back to /tmp if the file's directory isn't writable. Returns the path
/// written, or null if there was nothing to save or it couldn't be saved.
pub fn saveRecovery(ed: *Editor, buf: *PathBuffer) ?[]const u8 {
    if (!ed.isModified()) return null;
    if (recoveryPath(buf, ed.name.items)) |path| {
        if (writeFile(path, &ed.buffer)) return path;
    }
    const base = std.fs.path.basename(if (ed.name.items.len > 0) ed.name.items else unnamed);
    const tmp = std.fmt.bufPrintSentinel(buf, "/tmp/{s}{s}", .{ base, suffix }, 0) catch return null;
    if (writeFile(tmp, &ed.buffer)) return tmp;
    return null;
}

/// Writes the buffer's text to `path`, readable only by its owner (it may
/// hold anything the user was editing).
fn writeFile(path: [:0]const u8, buffer: *const Buffer) bool {
    const flags: posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true };
    const rc = sys.open(path.ptr, flags, 0o600);
    if (posix.errno(rc) != .SUCCESS) return false;
    const fd: posix.fd_t = @intCast(rc);
    defer _ = sys.close(fd);
    var it = buffer.chunks();
    while (it.next()) |chunk| {
        var rest = chunk;
        while (rest.len > 0) {
            const n = sys.write(fd, rest.ptr, rest.len);
            switch (posix.errno(n)) {
                .SUCCESS => rest = rest[@intCast(n)..],
                .INTR => continue,
                else => return false,
            }
        }
    }
    return true;
}

const testing = std.testing;

test "unsaved changes are written next to the file; nothing when unmodified" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var name_buf: [256]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, ".zig-cache/tmp/{s}/notes.txt", .{tmp.sub_path});

    var ed: Editor = try .init(testing.allocator, try .init(testing.allocator, "hello\n"), name);
    defer ed.deinit();
    var buf: PathBuffer = undefined;
    try testing.expectEqual(@as(?[]const u8, null), saveRecovery(&ed, &buf));

    _ = try ed.handleKey(.{ .char = 'x' });
    const path = saveRecovery(&ed, &buf).?;
    try testing.expect(std.mem.endsWith(u8, path, "notes.txt.zvim-recover"));
    const saved = try tmp.dir.readFileAlloc(testing.io, "notes.txt.zvim-recover", testing.allocator, .unlimited);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("ello\n", saved);

    const st = try tmp.dir.statFile(testing.io, "notes.txt.zvim-recover", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), st.permissions.toMode() & 0o777);
}

test "an unwritable directory falls back to /tmp" {
    var ed: Editor = try .init(testing.allocator, try .init(testing.allocator, "x"), "/nonexistent-dir/zvim-crash-test.txt");
    defer ed.deinit();
    _ = try ed.handleKey(.{ .char = 'x' });
    var buf: PathBuffer = undefined;
    const path = saveRecovery(&ed, &buf).?;
    try testing.expectEqualStrings("/tmp/zvim-crash-test.txt.zvim-recover", path);
    const saved = try std.Io.Dir.cwd().readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(saved);
    try testing.expectEqualStrings("", saved);
    try std.Io.Dir.cwd().deleteFile(testing.io, path);
}
