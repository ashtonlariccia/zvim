//! Decoding terminal input bytes into keys.

const std = @import("std");
const text = @import("text.zig");

pub const Key = union(enum) {
    /// A printable character (never a control character).
    char: u21,
    /// Ctrl plus a letter or symbol, given as the lowercase/plain byte ('a' for Ctrl-A).
    ctrl: u8,
    escape,
    enter,
    backspace,
    tab,
    delete,
    up,
    down,
    left,
    right,
    home,
    end,
};

/// Splits one read's worth of input into keys. An escape byte followed by
/// more bytes in the same read starts an escape sequence (terminals send these
/// in one write); a lone escape byte is the Escape key.
pub const Decoder = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn next(d: *Decoder) ?Key {
        while (d.i < d.bytes.len) {
            const rest = d.bytes[d.i..];
            const b = rest[0];
            switch (b) {
                0x1b => {
                    if (isSequenceStart(rest)) {
                        const seq = sequenceLen(rest);
                        d.i += seq;
                        return sequenceKey(rest[0..seq]) orelse continue;
                    }
                    d.i += 1;
                    return .escape;
                },
                '\r', '\n' => {
                    d.i += 1;
                    return .enter;
                },
                0x7f, 0x08 => {
                    d.i += 1;
                    return .backspace;
                },
                '\t' => {
                    d.i += 1;
                    return .tab;
                },
                0x00...0x07, 0x0b, 0x0c, 0x0e...0x1a, 0x1c...0x1f => {
                    d.i += 1;
                    return .{ .ctrl = b | 0x60 };
                },
                else => {
                    const ch = text.decode(rest);
                    d.i += ch.len;
                    if (ch.cp == text.replacement and !std.mem.startsWith(u8, rest, "\u{FFFD}")) continue;
                    if (ch.cp >= 0x80 and ch.cp < 0xa0) continue;
                    return .{ .char = ch.cp };
                },
            }
        }
        return null;
    }

    /// ESC [ always starts a sequence. ESC O only does when a key code
    /// follows; otherwise it is Escape then a typed 'O' (e.g. leaving insert
    /// mode and opening a line above in quick succession).
    fn isSequenceStart(s: []const u8) bool {
        if (s.len < 2) return false;
        if (s[1] == '[') return true;
        return s[1] == 'O' and s.len >= 3 and std.mem.indexOfScalar(u8, "ABCDHFPQRS", s[2]) != null;
    }

    /// Length of the escape sequence at the start of `s` (which begins ESC [ or ESC O).
    fn sequenceLen(s: []const u8) usize {
        if (s[1] == 'O') return @min(s.len, 3);
        var j: usize = 2;
        // CSI: parameter and intermediate bytes, then one final byte.
        while (j < s.len and (s[j] < 0x40 or s[j] > 0x7e)) j += 1;
        return @min(j + 1, s.len);
    }

    fn sequenceKey(seq: []const u8) ?Key {
        if (seq.len < 3) return null;
        const final = seq[seq.len - 1];
        const params = seq[2 .. seq.len - 1];
        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '~' => if (std.mem.eql(u8, params, "3"))
                .delete
            else if (std.mem.eql(u8, params, "1") or std.mem.eql(u8, params, "7"))
                .home
            else if (std.mem.eql(u8, params, "4") or std.mem.eql(u8, params, "8"))
                .end
            else
                null,
            else => null,
        };
    }
};

const testing = std.testing;

fn expectKeys(input: []const u8, expected: []const Key) !void {
    var d: Decoder = .{ .bytes = input };
    for (expected) |e| try testing.expectEqual(e, d.next().?);
    try testing.expectEqual(@as(?Key, null), d.next());
}

test "plain and multibyte characters" {
    try expectKeys("aé中", &.{ .{ .char = 'a' }, .{ .char = 'é' }, .{ .char = '中' } });
}

test "control keys" {
    try expectKeys("\r\x7f\t\x03\x1a", &.{ .enter, .backspace, .tab, .{ .ctrl = 'c' }, .{ .ctrl = 'z' } });
}

test "lone escape versus escape sequences" {
    try expectKeys("\x1b", &.{.escape});
    try expectKeys("\x1b[A\x1b[B\x1b[C\x1b[D", &.{ .up, .down, .right, .left });
    try expectKeys("\x1bOA\x1b[H\x1b[F\x1b[3~", &.{ .up, .home, .end, .delete });
    try expectKeys("x\x1b", &.{ .{ .char = 'x' }, .escape });
    try expectKeys("\x1bOx", &.{ .escape, .{ .char = 'O' }, .{ .char = 'x' } });
    try expectKeys("\x1bO", &.{ .escape, .{ .char = 'O' } });
}

test "unknown sequences and invalid bytes are dropped" {
    try expectKeys("\x1b[1;5Pa\xffb", &.{ .{ .char = 'a' }, .{ .char = 'b' } });
}
