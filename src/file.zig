//! Loading a buffer from disk and saving it back.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");

/// Reads `path` into a new buffer. A file that doesn't exist yet opens as an
/// empty buffer, so it gets created on the first save.
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Buffer {
    const text = dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return Buffer.init(gpa, ""),
        else => return err,
    };
    errdefer gpa.free(text);
    return Buffer.initOwned(gpa, text);
}

/// Writes the buffer to `path` without ever leaving a half-written file: the
/// text goes to a temporary file that is then renamed over the original. If
/// `path` is a symlink, the file it points to is replaced, not the link, and
/// an existing file keeps its permissions.
pub fn save(buffer: *const Buffer, io: Io, dir: Io.Dir, path: []const u8) !void {
    var target_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const target = if (dir.realPathFile(io, path, &target_buf)) |n|
        target_buf[0..n]
    else |err| switch (err) {
        error.FileNotFound => path,
        else => return err,
    };
    const permissions = if (dir.statFile(io, target, .{})) |st|
        st.permissions
    else |err| switch (err) {
        error.FileNotFound => Io.File.Permissions.default_file,
        else => return err,
    };

    var atomic = try dir.createFileAtomic(io, target, .{ .permissions = permissions, .replace = true });
    defer atomic.deinit(io);

    var write_buf: [64 * 1024]u8 = undefined;
    var fw = atomic.file.writer(io, &write_buf);
    var it = buffer.chunks();
    while (it.next()) |chunk| try fw.interface.writeAll(chunk);
    try fw.interface.flush();
    try atomic.replace(io);
}

const testing = std.testing;

fn expectFile(dir: Io.Dir, path: []const u8, expected: []const u8) !void {
    const got = try dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "load, edit and save round trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "hello\nworld\n" });

    var b = try load(testing.allocator, testing.io, tmp.dir, "a.txt");
    defer b.deinit();
    try testing.expectEqual(@as(usize, 3), b.lineCount());
    try b.insert(6, "big ");
    try save(&b, testing.io, tmp.dir, "a.txt");
    try expectFile(tmp.dir, "a.txt", "hello\nbig world\n");
}

test "missing file loads empty and is created on save" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var b = try load(testing.allocator, testing.io, tmp.dir, "new.txt");
    defer b.deinit();
    try testing.expectEqual(@as(usize, 0), b.len);
    try b.insert(0, "fresh\n");
    try save(&b, testing.io, tmp.dir, "new.txt");
    try expectFile(tmp.dir, "new.txt", "fresh\n");
}

test "saving through a symlink replaces the target and keeps the link" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.txt", .data = "old" });
    try tmp.dir.symLink(testing.io, "real.txt", "link.txt", .{});

    var b = try load(testing.allocator, testing.io, tmp.dir, "link.txt");
    defer b.deinit();
    try b.insert(3, " and new");
    try save(&b, testing.io, tmp.dir, "link.txt");

    try expectFile(tmp.dir, "real.txt", "old and new");
    var link_buf: [64]u8 = undefined;
    const n = try tmp.dir.readLink(testing.io, "link.txt", &link_buf);
    try testing.expectEqualStrings("real.txt", link_buf[0..n]);
}

test "saving keeps the file's permissions" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "run.sh", .data = "echo hi\n" });
    try tmp.dir.setFilePermissions(testing.io, "run.sh", .fromMode(0o755), .{});

    var b = try load(testing.allocator, testing.io, tmp.dir, "run.sh");
    defer b.deinit();
    try save(&b, testing.io, tmp.dir, "run.sh");

    const st = try tmp.dir.statFile(testing.io, "run.sh", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), st.permissions.toMode() & 0o777);
}
