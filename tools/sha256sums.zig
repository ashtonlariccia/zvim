//! Writes SHA256SUMS for the release binaries (run by `zig build dist`):
//!
//!     sha256sums <dir> <file>...
//!
//! The output is in the format `sha256sum -c` and `shasum -a 256 -c` read.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len < 3) return error.Usage;

    var dir = try std.Io.Dir.cwd().openDir(init.io, args[1], .{});
    defer dir.close(init.io);

    var out: std.ArrayList(u8) = .empty;
    for (args[2..]) |name| {
        const data = try dir.readFileAlloc(init.io, name, gpa, .unlimited);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        try out.print(gpa, "{x}  {s}\n", .{ &digest, name });
    }
    try dir.writeFile(init.io, .{ .sub_path = "SHA256SUMS", .data = out.items });
}
