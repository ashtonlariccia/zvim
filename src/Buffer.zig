//! Text buffer as a piece table.
//!
//! The text is never edited in place. `original` holds the text the buffer was
//! created with and is never modified; inserted text is appended to `add`. The
//! document is the concatenation of `pieces`, each a span of one of the two.
//! Pieces are a flat list for now: finding a position is linear in the number
//! of edits, not the size of the text.
//!
//! Each piece also records how many newlines it contains, so finding a line
//! only scans the text of the one piece the line starts in.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Buffer = @This();

gpa: Allocator,
original: []const u8,
add: std.ArrayList(u8) = .empty,
pieces: std.ArrayList(Piece) = .empty,
len: usize,
/// Total newlines in the text; the line count is one more.
newlines: usize,

const Piece = struct {
    src: enum { original, add },
    start: usize,
    len: usize,
    newlines: usize,
};

/// Creates a buffer holding a copy of `text`.
pub fn init(gpa: Allocator, text: []const u8) !Buffer {
    const original = try gpa.dupe(u8, text);
    errdefer gpa.free(original);
    return initOwned(gpa, original);
}

/// Creates a buffer that takes ownership of `text`, which must have been
/// allocated with `gpa`. On error the caller still owns `text`.
pub fn initOwned(gpa: Allocator, text: []const u8) !Buffer {
    const newlines = countNewlines(text);
    var self: Buffer = .{ .gpa = gpa, .original = text, .len = text.len, .newlines = newlines };
    if (text.len > 0) try self.pieces.append(gpa, .{
        .src = .original,
        .start = 0,
        .len = text.len,
        .newlines = newlines,
    });
    return self;
}

pub fn deinit(self: *Buffer) void {
    self.gpa.free(self.original);
    self.add.deinit(self.gpa);
    self.pieces.deinit(self.gpa);
    self.* = undefined;
}

/// Inserts `bytes` so that they start at byte offset `pos`.
pub fn insert(self: *Buffer, pos: usize, bytes: []const u8) !void {
    assert(pos <= self.len);
    if (bytes.len == 0) return;

    const add_start = self.add.items.len;
    try self.add.appendSlice(self.gpa, bytes);
    errdefer self.add.shrinkRetainingCapacity(add_start);

    const newlines = countNewlines(bytes);
    const loc = self.locate(pos);
    const new: Piece = .{ .src = .add, .start = add_start, .len = bytes.len, .newlines = newlines };
    if (loc.offset == 0) {
        // Typing appends to the add buffer right after the previous insert,
        // so a run of keystrokes grows one piece instead of making many.
        const prev = if (loc.index > 0) &self.pieces.items[loc.index - 1] else null;
        if (prev != null and prev.?.src == .add and prev.?.start + prev.?.len == add_start) {
            prev.?.len += bytes.len;
            prev.?.newlines += newlines;
        } else {
            try self.pieces.insert(self.gpa, loc.index, new);
        }
    } else {
        const halves = self.split(self.pieces.items[loc.index], loc.offset);
        try self.pieces.replaceRange(self.gpa, loc.index, 1, &.{ halves[0], new, halves[1] });
    }
    self.len += bytes.len;
    self.newlines += newlines;
}

/// Removes `n` bytes starting at byte offset `pos`.
pub fn delete(self: *Buffer, pos: usize, n: usize) !void {
    assert(pos + n <= self.len);
    if (n == 0) return;

    const first = self.locate(pos);
    const last = self.locate(pos + n);

    // Whatever survives of the first and last pieces replaces everything between.
    var keep: [2]Piece = undefined;
    var kept: usize = 0;
    if (first.offset > 0) {
        keep[kept] = self.split(self.pieces.items[first.index], first.offset)[0];
        kept += 1;
    }
    var end = last.index;
    if (last.offset > 0) {
        keep[kept] = self.split(self.pieces.items[last.index], last.offset)[1];
        kept += 1;
        end += 1;
    }

    var removed_newlines: usize = 0;
    for (self.pieces.items[first.index..end]) |p| removed_newlines += p.newlines;
    for (keep[0..kept]) |p| removed_newlines -= p.newlines;

    try self.pieces.replaceRange(self.gpa, first.index, end - first.index, keep[0..kept]);
    self.len -= n;
    self.newlines -= removed_newlines;
}

pub fn lineCount(self: *const Buffer) usize {
    return self.newlines + 1;
}

/// The number of lines as an editor shows them: a newline at the very end
/// terminates the last line instead of starting an empty one. Never 0.
pub fn visibleLineCount(self: *const Buffer) usize {
    const last = if (self.pieces.items.len == 0) return 1 else self.pieces.items[self.pieces.items.len - 1];
    const ends_with_newline = self.pieceBytes(last)[last.len - 1] == '\n';
    return if (ends_with_newline) self.newlines else self.newlines + 1;
}

/// Byte offset where 0-based `line` starts.
pub fn lineStart(self: *const Buffer, line: usize) usize {
    assert(line < self.lineCount());
    if (line == 0) return 0;
    // Line N starts right after the Nth newline.
    var start: usize = 0;
    var seen: usize = 0;
    for (self.pieces.items) |p| {
        if (seen + p.newlines >= line) {
            const bytes = self.pieceBytes(p);
            var i: usize = 0;
            while (true) : (i += 1) {
                if (bytes[i] != '\n') continue;
                seen += 1;
                if (seen == line) return start + i + 1;
            }
        }
        start += p.len;
        seen += p.newlines;
    }
    unreachable;
}

/// The 0-based line containing byte offset `pos`. The end of the text
/// belongs to the last line.
pub fn lineOf(self: *const Buffer, pos: usize) usize {
    assert(pos <= self.len);
    const loc = self.locate(pos);
    var line: usize = 0;
    for (self.pieces.items[0..loc.index]) |p| line += p.newlines;
    if (loc.offset > 0) line += countNewlines(self.pieceBytes(self.pieces.items[loc.index])[0..loc.offset]);
    return line;
}

/// Iterates over the text as a sequence of contiguous byte slices.
pub fn chunks(self: *const Buffer) ChunkIterator {
    return self.chunksFrom(0);
}

/// Like `chunks`, but starting at byte offset `pos`.
pub fn chunksFrom(self: *const Buffer, pos: usize) ChunkIterator {
    assert(pos <= self.len);
    const loc = self.locate(pos);
    return .{ .buffer = self, .index = loc.index, .offset = loc.offset };
}

pub const ChunkIterator = struct {
    buffer: *const Buffer,
    index: usize,
    /// Bytes to skip at the start of the current piece.
    offset: usize,

    pub fn next(it: *ChunkIterator) ?[]const u8 {
        if (it.index >= it.buffer.pieces.items.len) return null;
        const bytes = it.buffer.pieceBytes(it.buffer.pieces.items[it.index])[it.offset..];
        it.index += 1;
        it.offset = 0;
        return bytes;
    }
};

/// Returns the whole text as a newly allocated slice owned by the caller.
pub fn toOwnedSlice(self: *const Buffer, gpa: Allocator) ![]u8 {
    const out = try gpa.alloc(u8, self.len);
    var i: usize = 0;
    var it = self.chunks();
    while (it.next()) |chunk| {
        @memcpy(out[i..][0..chunk.len], chunk);
        i += chunk.len;
    }
    return out;
}

fn pieceBytes(self: *const Buffer, p: Piece) []const u8 {
    const src = switch (p.src) {
        .original => self.original,
        .add => self.add.items,
    };
    return src[p.start..][0..p.len];
}

/// Splits `p` at `offset` (0 < offset < p.len). Only the shorter half is
/// scanned for newlines; the other half's count follows from the total.
fn split(self: *const Buffer, p: Piece, offset: usize) [2]Piece {
    assert(offset > 0 and offset < p.len);
    const bytes = self.pieceBytes(p);
    const left_newlines = if (offset <= p.len / 2)
        countNewlines(bytes[0..offset])
    else
        p.newlines - countNewlines(bytes[offset..]);
    return .{
        .{ .src = p.src, .start = p.start, .len = offset, .newlines = left_newlines },
        .{ .src = p.src, .start = p.start + offset, .len = p.len - offset, .newlines = p.newlines - left_newlines },
    };
}

fn countNewlines(bytes: []const u8) usize {
    return std.mem.countScalar(u8, bytes, '\n');
}

const Location = struct { index: usize, offset: usize };

/// Finds the piece containing byte `pos`. A position on a piece boundary
/// belongs to the later piece (offset 0); the end of the text is one past
/// the last piece.
fn locate(self: *const Buffer, pos: usize) Location {
    var start: usize = 0;
    for (self.pieces.items, 0..) |p, i| {
        if (pos < start + p.len) return .{ .index = i, .offset = pos - start };
        start += p.len;
    }
    return .{ .index = self.pieces.items.len, .offset = 0 };
}

const testing = std.testing;

fn expectText(b: *const Buffer, expected: []const u8) !void {
    const got = try b.toOwnedSlice(testing.allocator);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
    try testing.expectEqual(expected.len, b.len);

    // Line index agrees with a naive scan of the expected text.
    try testing.expectEqual(countNewlines(expected) + 1, b.lineCount());
    var line: usize = 0;
    try testing.expectEqual(@as(usize, 0), b.lineStart(0));
    for (expected, 0..) |c, pos| {
        try testing.expectEqual(line, b.lineOf(pos));
        if (c == '\n') {
            line += 1;
            try testing.expectEqual(pos + 1, b.lineStart(line));
        }
    }
    try testing.expectEqual(line, b.lineOf(expected.len));

    // Reading from any position yields the rest of the text.
    for (0..expected.len + 1) |pos| {
        var it = b.chunksFrom(pos);
        var at = pos;
        while (it.next()) |chunk| {
            try testing.expectEqualStrings(expected[at..][0..chunk.len], chunk);
            at += chunk.len;
        }
        try testing.expectEqual(expected.len, at);
    }
}

test "line index on a simple text" {
    var b: Buffer = try .init(testing.allocator, "one\ntwo\n\nfour");
    defer b.deinit();
    try testing.expectEqual(@as(usize, 4), b.lineCount());
    try testing.expectEqual(@as(usize, 4), b.lineStart(1));
    try testing.expectEqual(@as(usize, 8), b.lineStart(2));
    try testing.expectEqual(@as(usize, 9), b.lineStart(3));
    try testing.expectEqual(@as(usize, 3), b.lineOf(9));
    try b.insert(4, "1.5\n");
    try expectText(&b, "one\n1.5\ntwo\n\nfour");
    try b.delete(3, 8); // removes "\n1.5\ntwo"
    try expectText(&b, "one\n\nfour");
}

test "trailing newline makes an empty last line" {
    var b: Buffer = try .init(testing.allocator, "a\n");
    defer b.deinit();
    try testing.expectEqual(@as(usize, 2), b.lineCount());
    try testing.expectEqual(@as(usize, 2), b.lineStart(1));
    try testing.expectEqual(@as(usize, 1), b.lineOf(2));
}

test "visible line count ignores a final newline" {
    const cases = [_]struct { []const u8, usize }{
        .{ "", 1 },     .{ "\n", 1 },     .{ "a", 1 },     .{ "a\n", 1 },
        .{ "a\nb", 2 }, .{ "a\nb\n", 2 }, .{ "a\n\n", 2 }, .{ "\n\n", 2 },
    };
    for (cases) |case| {
        var b: Buffer = try .init(testing.allocator, case[0]);
        defer b.deinit();
        try testing.expectEqual(case[1], b.visibleLineCount());
    }
}

test "starts with the given text" {
    var b: Buffer = try .init(testing.allocator, "hello");
    defer b.deinit();
    try expectText(&b, "hello");
}

test "empty buffer" {
    var b: Buffer = try .init(testing.allocator, "");
    defer b.deinit();
    try expectText(&b, "");
    try b.insert(0, "abc");
    try expectText(&b, "abc");
    try b.delete(0, 3);
    try expectText(&b, "");
}

test "insert at start, middle and end" {
    var b: Buffer = try .init(testing.allocator, "ace");
    defer b.deinit();
    try b.insert(1, "b");
    try b.insert(3, "d");
    try b.insert(0, ">");
    try b.insert(6, "<");
    try expectText(&b, ">abcde<");
}

test "consecutive typing grows a single piece" {
    var b: Buffer = try .init(testing.allocator, "ab");
    defer b.deinit();
    try b.insert(1, "x");
    try b.insert(2, "y");
    try b.insert(3, "z");
    try expectText(&b, "axyzb");
    try testing.expectEqual(@as(usize, 3), b.pieces.items.len);
}

test "delete within one piece and across pieces" {
    var b: Buffer = try .init(testing.allocator, "hello world");
    defer b.deinit();
    try b.delete(1, 3); // "ho world"
    try expectText(&b, "ho world");
    try b.insert(2, "XYZ"); // "hoXYZ world"
    try b.delete(1, 6); // removes "oXYZ w"
    try expectText(&b, "horld");
    try b.delete(0, 5);
    try expectText(&b, "");
    try testing.expectEqual(@as(usize, 0), b.pieces.items.len);
}

test "matches a plain array under seeded random edits" {
    const gpa = testing.allocator;
    for (0..200) |seed| {
        var prng: std.Random.DefaultPrng = .init(seed);
        const rand = prng.random();

        var reference: std.ArrayList(u8) = .empty;
        defer reference.deinit(gpa);
        try reference.appendSlice(gpa, "the quick brown fox\njumps over\n\nthe lazy dog");

        var b: Buffer = try .init(gpa, reference.items);
        defer b.deinit();

        for (0..100) |_| {
            const pos = rand.uintAtMost(usize, reference.items.len);
            if (rand.boolean()) {
                var text: [8]u8 = undefined;
                const n = rand.uintAtMost(usize, text.len);
                for (text[0..n]) |*c| c.* = "ab\n"[rand.uintLessThan(usize, 3)];
                try b.insert(pos, text[0..n]);
                try reference.insertSlice(gpa, pos, text[0..n]);
            } else {
                const n = rand.uintAtMost(usize, reference.items.len - pos);
                try b.delete(pos, n);
                reference.replaceRangeAssumeCapacity(pos, n, &.{});
            }
            try expectText(&b, reference.items);
        }
    }
}

test "matches a plain array under fuzzed edits" {
    try testing.fuzz({}, fuzzEdits, .{});
}

fn fuzzEdits(_: void, smith: *testing.Smith) !void {
    const gpa = testing.allocator;
    var reference: std.ArrayList(u8) = .empty;
    defer reference.deinit(gpa);
    try reference.appendSlice(gpa, "the quick brown fox");

    var b: Buffer = try .init(gpa, reference.items);
    defer b.deinit();

    while (!smith.eos()) {
        switch (smith.value(enum { insert, delete })) {
            .insert => {
                var text: [8]u8 = undefined;
                const n = smith.valueRangeAtMost(u32, 0, text.len);
                smith.bytes(text[0..n]);
                const pos = smith.valueRangeAtMost(u32, 0, @intCast(reference.items.len));
                try b.insert(pos, text[0..n]);
                try reference.insertSlice(gpa, pos, text[0..n]);
            },
            .delete => {
                const pos = smith.valueRangeAtMost(u32, 0, @intCast(reference.items.len));
                const n = smith.valueRangeAtMost(u32, 0, @intCast(reference.items.len - pos));
                try b.delete(pos, n);
                reference.replaceRangeAssumeCapacity(pos, n, &.{});
            },
        }
        try expectText(&b, reference.items);
    }
}
