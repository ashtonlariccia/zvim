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
    /// Text pasted into the terminal (bracketed paste), to insert literally.
    /// Points into the input buffer.
    paste: []const u8,
    /// Part of a reply from the terminal in an OSC sequence (`ESC ] ...`,
    /// such as the clipboard's contents), without the `ESC ]`; `done` on the
    /// last part. Never typed: for whoever asked. Points into the input buffer.
    osc: struct { bytes: []const u8, done: bool },
};

const paste_begin = "\x1b[200~";
const paste_end = "\x1b[201~";

/// Splits one read's worth of input into keys. An escape byte followed by
/// more bytes in the same read starts an escape sequence (terminals send these
/// in one write); a lone escape byte is the Escape key.
///
/// Terminals with the kitty keyboard protocol (see term.zig) send Escape,
/// and Ctrl or Alt with a key, as `CSI code ; modifiers u`. These decode to
/// the same keys as the plain bytes other terminals send.
pub const Decoder = struct {
    bytes: []const u8,
    i: usize = 0,
    /// Inside an OSC reply; carried over from one read to the next, like
    /// `in_paste`.
    in_osc: bool = false,
    /// A key still to return: the second of the two keys Alt-x makes.
    queued: ?Key = null,
    /// Set on seeing the terminal's answer to the keyboard protocol query:
    /// it's on, so Escape never comes as a lone escape byte.
    keyboard_protocol: bool = false,
    /// Set when the terminal says its window got the focus back (`CSI I`,
    /// with focus reporting on; see term.zig). Losing it (`CSI O`) is ignored.
    focus_in: bool = false,
    /// Inside a bracketed paste. Carry it over from one read to the next,
    /// since a long paste can span several.
    in_paste: bool = false,
    /// False when more input may still arrive (the bytes are one read's worth).
    /// Then an incomplete escape sequence, UTF-8 character or paste marker at
    /// the end is left undecoded, in `leftover`, to be completed by the next
    /// read; over a network, one key's bytes can arrive in two reads. With
    /// `final` true (no more input came in time), they're decoded as they are.
    final: bool = true,

    /// Bytes not decoded yet: an incomplete sequence at the end of the input.
    pub fn leftover(d: *const Decoder) []const u8 {
        return d.bytes[d.i..];
    }

    pub fn next(d: *Decoder) ?Key {
        if (d.queued) |key| {
            d.queued = null;
            return key;
        }
        while (d.i < d.bytes.len) {
            const rest = d.bytes[d.i..];
            if (d.in_paste) {
                const end = std.mem.indexOf(u8, rest, paste_end);
                var pasted_len = end orelse rest.len;
                // Keep back what could be the start of a split end marker.
                if (end == null and !d.final) pasted_len -= partialSuffix(rest, paste_end);
                const pasted = rest[0..pasted_len];
                if (end == null and pasted_len < rest.len) {
                    d.i += pasted_len;
                    if (pasted.len > 0) return .{ .paste = pasted };
                    return null;
                }
                d.i += if (end) |e| e + paste_end.len else rest.len;
                if (end != null) d.in_paste = false;
                if (pasted.len > 0) return .{ .paste = pasted };
                continue;
            }
            if (d.in_osc) {
                // It ends with BEL or ST (ESC \\).
                const bel = std.mem.indexOfScalar(u8, rest, 0x07);
                const st = std.mem.indexOf(u8, rest, "\x1b\\");
                const end: ?usize = if (bel != null and st != null) @min(bel.?, st.?) else bel orelse st;
                if (end) |e| {
                    d.i += e + @as(usize, if (rest[e] == 0x07) 1 else 2);
                    d.in_osc = false;
                    return .{ .osc = .{ .bytes = rest[0..e], .done = true } };
                }
                // Keep back a final ESC that may start the ST.
                const n = rest.len - @intFromBool(!d.final and rest[rest.len - 1] == 0x1b);
                d.i += n;
                if (n > 0) return .{ .osc = .{ .bytes = rest[0..n], .done = false } };
                return null;
            }
            if (std.mem.startsWith(u8, rest, "\x1b]")) {
                d.i += 2;
                d.in_osc = true;
                continue;
            }
            if (std.mem.startsWith(u8, rest, paste_begin)) {
                d.i += paste_begin.len;
                d.in_paste = true;
                continue;
            }
            if (!d.final and incomplete(rest)) return null;
            const b = rest[0];
            switch (b) {
                0x1b => {
                    if (isSequenceStart(rest)) {
                        const seq = sequenceLen(rest);
                        d.i += seq;
                        if (std.mem.eql(u8, rest[0..seq], "\x1b[I")) {
                            d.focus_in = true;
                            continue;
                        }
                        if (isProtocolReply(rest[0..seq])) {
                            d.keyboard_protocol = true;
                            continue;
                        }
                        if (rest[seq - 1] == 'u') return d.protocolKey(rest[2 .. seq - 1]) orelse continue;
                        return sequenceKey(rest[0..seq]) orelse continue;
                    }
                    d.i += 1;
                    return .escape;
                },
                0x00...0x1a, 0x1c...0x1f, 0x7f => {
                    d.i += 1;
                    return controlKey(b);
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

    /// The key a control byte is: Enter, Tab, Backspace or Ctrl-something.
    fn controlKey(b: u8) Key {
        return switch (b) {
            '\r', '\n' => .enter,
            '\t' => .tab,
            0x7f, 0x08 => .backspace,
            0x1b => .escape,
            else => .{ .ctrl = b | 0x60 },
        };
    }

    /// `CSI ? flags u`: the terminal's answer when asked which keyboard
    /// protocol flags are on.
    fn isProtocolReply(seq: []const u8) bool {
        return seq.len >= 4 and seq[2] == '?' and seq[seq.len - 1] == 'u';
    }

    /// A key in the kitty keyboard protocol, from the parameters of
    /// `CSI code[:alternates] [; modifiers[:event]] u`. Ctrl-x becomes the
    /// control byte it would otherwise be, and Alt-x becomes Escape then x,
    /// as other terminals send it. Keys zvim has no use for give null.
    fn protocolKey(d: *Decoder, params: []const u8) ?Key {
        var fields = std.mem.splitScalar(u8, params, ';');
        const code_field = fields.next().?;
        const code_text = code_field[0 .. std.mem.indexOfScalar(u8, code_field, ':') orelse code_field.len];
        const code = std.fmt.parseInt(u21, code_text, 10) catch return null;
        const mods_field = fields.next() orelse "1";
        const mods_text = mods_field[0 .. std.mem.indexOfScalar(u8, mods_field, ':') orelse mods_field.len];
        const mods = (std.fmt.parseInt(u8, mods_text, 10) catch 1) -| 1;
        const alt = mods & 2 != 0;
        const ctrl = mods & 4 != 0;

        const key: Key = switch (code) {
            27 => .escape,
            13 => .enter,
            9 => .tab,
            127, 8 => .backspace,
            0x20...0x7e => if (ctrl)
                controlKey(@intCast(code & 0x1f))
            else
                .{ .char = code },
            0xa0...0xdfff, 0xf900...0x10ffff => if (ctrl) return null else .{ .char = code },
            else => return null, // function keys, keypad, modifiers alone
        };
        if (!alt) return key;
        d.queued = key;
        return .escape;
    }

    /// Whether `s` is the beginning of a key whose remaining bytes may still
    /// be on their way: a lone ESC, ESC [ without its final byte, ESC O
    /// without its key, or a UTF-8 character missing continuation bytes.
    fn incomplete(s: []const u8) bool {
        if (s[0] == 0x1b) {
            if (s.len == 1) return true;
            if (s[1] == ']') return false;
            if (s[1] == '[') {
                for (s[2..]) |c| if (c >= 0x40 and c <= 0x7e) return false;
                return true;
            }
            return s[1] == 'O' and s.len == 2;
        }
        const need = std.unicode.utf8ByteSequenceLength(s[0]) catch return false;
        if (need <= s.len) return false;
        for (s[1..]) |c| if (c & 0xC0 != 0x80) return false;
        return true;
    }

    /// Length of the longest suffix of `s` that is a proper prefix of `marker`.
    fn partialSuffix(s: []const u8, marker: []const u8) usize {
        var n = @min(s.len, marker.len - 1);
        while (n > 0) : (n -= 1) {
            if (std.mem.eql(u8, s[s.len - n ..], marker[0..n])) return n;
        }
        return 0;
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
    for (expected) |e| {
        const got = d.next().?;
        if (e == .paste) {
            try testing.expectEqualStrings(e.paste, got.paste);
        } else {
            try testing.expectEqual(e, got);
        }
    }
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

test "kitty keyboard protocol keys decode like the plain bytes" {
    try expectKeys("\x1b[27u\x1b[97;5u\x1b[92;5u\x1b[105;5u\x1b[91;5u", &.{ .escape, .{ .ctrl = 'a' }, .{ .ctrl = '|' }, .tab, .escape });
    try expectKeys("\x1b[106;3u\x1b[13;2u\x1b[127;5u", &.{ .escape, .{ .char = 'j' }, .enter, .backspace });
    try expectKeys("\x1b[97:65;6ux\x1b[57399u\x1b[1;5A", &.{ .{ .ctrl = 'a' }, .{ .char = 'x' }, .up });
}

test "the keyboard protocol reply is noted, not typed" {
    var d: Decoder = .{ .bytes = "\x1b[?1uj" };
    try testing.expectEqual(Key{ .char = 'j' }, d.next().?);
    try testing.expect(d.keyboard_protocol);
}

test "focus reports are noted, not typed" {
    var d: Decoder = .{ .bytes = "\x1b[O\x1b[Ij" };
    try testing.expectEqual(Key{ .char = 'j' }, d.next().?);
    try testing.expect(d.focus_in);
}

test "an OSC reply comes through whole or in parts, never as keys" {
    var d: Decoder = .{ .bytes = "\x1b]52;c;aGk=\x07j" };
    const k = d.next().?;
    try testing.expectEqualStrings("52;c;aGk=", k.osc.bytes);
    try testing.expect(k.osc.done);
    try testing.expectEqual(Key{ .char = 'j' }, d.next().?);

    var d1: Decoder = .{ .bytes = "\x1b]52;c;aG\x1b", .final = false };
    const a = d1.next().?;
    try testing.expectEqualStrings("52;c;aG", a.osc.bytes);
    try testing.expect(!a.osc.done and d1.in_osc);
    try testing.expectEqual(@as(?Key, null), d1.next());
    try testing.expectEqualStrings("\x1b", d1.leftover());
    var d2: Decoder = .{ .bytes = "\x1b\\x", .in_osc = true };
    const b = d2.next().?;
    try testing.expect(b.osc.done and b.osc.bytes.len == 0);
    try testing.expectEqual(Key{ .char = 'x' }, d2.next().?);
}

test "bracketed paste comes through as literal text" {
    try expectKeys("x\x1b[200~dd\x1b[A\r:q\x1b[201~y", &.{
        .{ .char = 'x' },
        .{ .paste = "dd\x1b[A\r:q" },
        .{ .char = 'y' },
    });
}

test "a paste spanning two reads" {
    var d: Decoder = .{ .bytes = "\x1b[200~first half" };
    try testing.expectEqualStrings("first half", d.next().?.paste);
    try testing.expect(d.in_paste);
    var d2: Decoder = .{ .bytes = " second\x1b[201~j", .in_paste = d.in_paste };
    try testing.expectEqualStrings(" second", d2.next().?.paste);
    try testing.expectEqual(Key{ .char = 'j' }, d2.next().?);
}

fn decodeAll(d: *Decoder, out: []Key) []Key {
    var n: usize = 0;
    while (d.next()) |k| : (n += 1) out[n] = k;
    return out[0..n];
}

test "an arrow key split across two reads" {
    var keys: [8]Key = undefined;
    var d: Decoder = .{ .bytes = "x\x1b[", .final = false };
    try testing.expectEqualSlices(Key, &.{.{ .char = 'x' }}, decodeAll(&d, &keys));
    try testing.expectEqualStrings("\x1b[", d.leftover());
    var d2: Decoder = .{ .bytes = "\x1b[A", .final = false };
    try testing.expectEqualSlices(Key, &.{.up}, decodeAll(&d2, &keys));
    try testing.expectEqualStrings("", d2.leftover());
}

test "a lone escape waits, then decodes as Escape when no more input comes" {
    var keys: [8]Key = undefined;
    var d: Decoder = .{ .bytes = "\x1b", .final = false };
    try testing.expectEqual(@as(usize, 0), decodeAll(&d, &keys).len);
    var d2: Decoder = .{ .bytes = d.leftover() };
    try testing.expectEqualSlices(Key, &.{.escape}, decodeAll(&d2, &keys));
    // ESC O waits too, since it may be the start of an arrow key.
    var d3: Decoder = .{ .bytes = "\x1bO", .final = false };
    try testing.expectEqual(@as(usize, 0), decodeAll(&d3, &keys).len);
}

test "a multibyte character split across reads" {
    var keys: [8]Key = undefined;
    var d: Decoder = .{ .bytes = "a\xe4\xb8", .final = false };
    try testing.expectEqualSlices(Key, &.{.{ .char = 'a' }}, decodeAll(&d, &keys));
    try testing.expectEqualStrings("\xe4\xb8", d.leftover());
    var d2: Decoder = .{ .bytes = "\xe4\xb8\xad", .final = false };
    try testing.expectEqualSlices(Key, &.{.{ .char = '中' }}, decodeAll(&d2, &keys));
    // An invalid byte isn't waited on.
    var d3: Decoder = .{ .bytes = "\xe4z", .final = false };
    try testing.expectEqualSlices(Key, &.{.{ .char = 'z' }}, decodeAll(&d3, &keys));
}

test "the end of a paste split across reads" {
    var d: Decoder = .{ .bytes = "\x1b[200~text\x1b[20", .final = false };
    try testing.expectEqualStrings("text", d.next().?.paste);
    try testing.expectEqual(@as(?Key, null), d.next());
    try testing.expectEqualStrings("\x1b[20", d.leftover());
    var d2: Decoder = .{ .bytes = "\x1b[201~j", .in_paste = d.in_paste, .final = false };
    try testing.expectEqual(Key{ .char = 'j' }, d2.next().?);
}
