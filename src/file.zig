//! Loading a buffer from disk and saving it back.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Buffer = @import("Buffer.zig");

pub const Loaded = struct {
    buffer: Buffer,
    /// Every line ended in \r\n (Windows style). The buffer holds the lines
    /// without the \r; pass this to `save` to write them back that way.
    crlf: bool,
};

/// Reads `path` into a new buffer. A file that doesn't exist yet opens as an
/// empty buffer, so it gets created on the first save.
pub fn load(gpa: Allocator, io: Io, dir: Io.Dir, path: []const u8) !Loaded {
    var text = dir.readFileAlloc(io, path, gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{ .buffer = try Buffer.init(gpa, ""), .crlf = false },
        else => return err,
    };
    errdefer gpa.free(text);
    const crlf = if (stripCrlf(text)) |len| blk: {
        text = try gpa.realloc(text, len);
        break :blk true;
    } else false;
    return .{ .buffer = try Buffer.initOwned(gpa, text), .crlf = crlf };
}

/// If every newline in `text` follows a \r, removes those \r in place and
/// returns the new length. Text with no newlines, or that mixes line endings,
/// is left alone.
fn stripCrlf(text: []u8) ?usize {
    var newlines: usize = 0;
    for (text, 0..) |c, i| {
        if (c != '\n') continue;
        if (i == 0 or text[i - 1] != '\r') return null;
        newlines += 1;
    }
    if (newlines == 0) return null;
    var j: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\r' and i + 1 < text.len and text[i + 1] == '\n') continue;
        text[j] = c;
        j += 1;
    }
    return j;
}

/// Writes the buffer to `path` without ever leaving a half-written file: the
/// text goes to a temporary file that is then renamed over the original. If
/// `path` is a symlink, the file it points to is replaced, not the link, and
/// an existing file keeps its permissions. With `crlf`, lines end in \r\n.
pub fn save(buffer: *const Buffer, io: Io, dir: Io.Dir, path: []const u8, crlf: bool) !void {
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
    while (it.next()) |chunk| {
        if (!crlf) {
            try fw.interface.writeAll(chunk);
            continue;
        }
        var lines = std.mem.splitScalar(u8, chunk, '\n');
        var first = true;
        while (lines.next()) |part| {
            if (!first) try fw.interface.writeAll("\r\n");
            try fw.interface.writeAll(part);
            first = false;
        }
    }
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

    var b = (try load(testing.allocator, testing.io, tmp.dir, "a.txt")).buffer;
    defer b.deinit();
    try testing.expectEqual(@as(usize, 3), b.lineCount());
    try b.insert(6, "big ");
    try save(&b, testing.io, tmp.dir, "a.txt", false);
    try expectFile(tmp.dir, "a.txt", "hello\nbig world\n");
}

test "missing file loads empty and is created on save" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var b = (try load(testing.allocator, testing.io, tmp.dir, "new.txt")).buffer;
    defer b.deinit();
    try testing.expectEqual(@as(usize, 0), b.len);
    try b.insert(0, "fresh\n");
    try save(&b, testing.io, tmp.dir, "new.txt", false);
    try expectFile(tmp.dir, "new.txt", "fresh\n");
}

test "saving through a symlink replaces the target and keeps the link" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "real.txt", .data = "old" });
    try tmp.dir.symLink(testing.io, "real.txt", "link.txt", .{});

    var b = (try load(testing.allocator, testing.io, tmp.dir, "link.txt")).buffer;
    defer b.deinit();
    try b.insert(3, " and new");
    try save(&b, testing.io, tmp.dir, "link.txt", false);

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

    var b = (try load(testing.allocator, testing.io, tmp.dir, "run.sh")).buffer;
    defer b.deinit();
    try save(&b, testing.io, tmp.dir, "run.sh", false);

    const st = try tmp.dir.statFile(testing.io, "run.sh", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o755), st.permissions.toMode() & 0o777);
}

test "Windows line endings load as plain lines and save back as \\r\\n" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "w.txt", .data = "one\r\ntwo\r\n" });
    const loaded = try load(testing.allocator, testing.io, tmp.dir, "w.txt");
    var b = loaded.buffer;
    defer b.deinit();
    try testing.expect(loaded.crlf);
    try testing.expectEqual(@as(usize, 2), b.visibleLineCount());
    try b.insert(4, "1.5\n");
    try save(&b, testing.io, tmp.dir, "w.txt", true);
    try expectFile(tmp.dir, "w.txt", "one\r\n1.5\r\ntwo\r\n");
}

test "mixed line endings are left alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "m.txt", .data = "a\r\nb\nc\r\n" });
    const loaded = try load(testing.allocator, testing.io, tmp.dir, "m.txt");
    var b = loaded.buffer;
    defer b.deinit();
    try testing.expect(!loaded.crlf);
    try testing.expectEqual(@as(usize, 8), b.len); // unchanged, \r included
}
