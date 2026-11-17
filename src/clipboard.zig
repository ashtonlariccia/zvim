//! The system clipboard. Yanks are copied to it; "+p and "+P paste from it.
//!
//! Copying goes through the terminal (OSC 52), which works locally and over
//! SSH alike. Inside tmux it goes through `tmux load-buffer -w` instead:
//! tmux ignores OSC 52 from programs unless set-clipboard is on, but passes
//! its own buffers on to the terminal.
//!
//! Reading is less uniform, since most terminals don't let programs read the
//! clipboard, or ask first. Locally, a clipboard tool reads it (wl-paste,
//! xclip or xsel, pbpaste); over SSH, or without one, tmux's buffer when in
//! tmux, and otherwise the terminal is asked over OSC 52. Its answer comes
//! back later with the keyboard input (see `keys.zig`).

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Yanks bigger than this stay in zvim: some terminals drop longer OSC 52
/// sequences, or cut them short.
pub const max_copy = 100 * 1024;

/// The most read from the clipboard.
pub const max_read = 16 * 1024 * 1024;

/// How long a clipboard tool, or the terminal, gets to answer.
pub const timeout_ms = 2000;

/// Where zvim runs, from its environment.
pub const Place = struct {
    ssh: bool,
    tmux: bool,
    wayland: bool,
    x11: bool,

    pub fn of(env: *const std.process.Environ.Map) Place {
        return .{
            .ssh = env.get("SSH_TTY") != null or env.get("SSH_CONNECTION") != null,
            .tmux = env.get("TMUX") != null,
            .wayland = env.get("WAYLAND_DISPLAY") != null,
            .x11 = env.get("DISPLAY") != null,
        };
    }
};

pub const CopyResult = enum { copied, too_big };

/// Puts `text` on the system clipboard, unless it's over `max_copy`.
pub fn copy(gpa: Allocator, io: Io, place: Place, out: *Io.Writer, text: []const u8) !CopyResult {
    if (text.len > max_copy) return .too_big;
    if (place.tmux and pipeTo(io, &.{ "tmux", "load-buffer", "-w", "-" }, text)) return .copied;
    try writeOsc52(gpa, out, text);
    return .copied;
}

/// OSC 52: the terminal puts the base64-encoded text on its clipboard.
fn writeOsc52(gpa: Allocator, out: *Io.Writer, text: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    const encoded = try gpa.alloc(u8, encoder.calcSize(text.len));
    defer gpa.free(encoded);
    try out.writeAll("\x1b]52;c;");
    try out.writeAll(encoder.encode(encoded, text));
    try out.writeAll("\x07");
}

/// Runs `argv` with `text` as its input. False if it couldn't run or failed.
fn pipeTo(io: Io, argv: []const []const u8, text: []const u8) bool {
    var child = std.process.spawn(io, .{ .argv = argv, .stdin = .pipe, .stdout = .ignore, .stderr = .ignore }) catch return false;
    const written = if (child.stdin.?.writeStreamingAll(io, text)) true else |_| false;
    child.stdin.?.close(io);
    child.stdin = null;
    const term = child.wait(io) catch return false;
    return written and term.success();
}

pub const ReadResult = union(enum) {
    /// The clipboard's text, owned by the caller, line breaks as \n.
    text: []u8,
    /// The terminal was asked; its answer comes with the input, to hand to
    /// `decodeReply`.
    asked,
};

/// Reads the system clipboard, or asks the terminal for it.
pub fn read(gpa: Allocator, io: Io, place: Place, out: *Io.Writer) !ReadResult {
    if (!place.ssh) {
        const tools: []const []const []const u8 = if (builtin.os.tag == .macos)
            &.{&.{"pbpaste"}}
        else if (place.wayland)
            &.{&.{ "wl-paste", "--no-newline" }}
        else if (place.x11)
            &.{ &.{ "xclip", "-selection", "clipboard", "-o" }, &.{ "xsel", "-bo" } }
        else
            &.{};
        for (tools) |argv| if (try runTool(gpa, io, argv)) |t| return .{ .text = t };
    }
    if (place.tmux) if (try runTool(gpa, io, &.{ "tmux", "save-buffer", "-" })) |t| return .{ .text = t };
    try out.writeAll("\x1b]52;c;?\x07");
    return .asked;
}

/// The output of a clipboard tool, or null if it isn't there or failed (as
/// wl-paste does on an empty clipboard).
fn runTool(gpa: Allocator, io: Io, argv: []const []const u8) !?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_read),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return null,
    };
    gpa.free(result.stderr);
    if (!result.term.success()) {
        gpa.free(result.stdout);
        return null;
    }
    return try normalize(gpa, result.stdout);
}

/// The text in the terminal's answer, `52;c;<base64>` (the part of the OSC
/// sequence after `ESC ]`), owned by the caller; null if it isn't one.
pub fn decodeReply(gpa: Allocator, reply: []const u8) !?[]u8 {
    if (!std.mem.startsWith(u8, reply, "52;")) return null;
    const semi = std.mem.indexOfScalarPos(u8, reply, 3, ';') orelse return null;
    const encoded = reply[semi + 1 ..];
    const decoder = std.base64.standard.Decoder;
    const size = decoder.calcSizeForSlice(encoded) catch return null;
    const decoded = try gpa.alloc(u8, size);
    decoder.decode(decoded, encoded) catch {
        gpa.free(decoded);
        return null;
    };
    return try normalize(gpa, decoded);
}

/// Turns \r\n and lone \r into \n, shrinking `bytes` (owned, from `gpa`).
fn normalize(gpa: Allocator, bytes: []u8) ![]u8 {
    var j: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) : (i += 1) {
        if (bytes[i] == '\r') {
            bytes[j] = '\n';
            if (i + 1 < bytes.len and bytes[i + 1] == '\n') i += 1;
        } else bytes[j] = bytes[i];
        j += 1;
    }
    return gpa.realloc(bytes, j);
}

const testing = std.testing;

test "the terminal's clipboard answer is decoded, line breaks as \\n" {
    const got = (try decodeReply(testing.allocator, "52;c;b25lDQp0d28=")).?; // "one\r\ntwo"
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("one\ntwo", got);
    try testing.expectEqual(@as(?[]u8, null), try decodeReply(testing.allocator, "52;c;!!!"));
    try testing.expectEqual(@as(?[]u8, null), try decodeReply(testing.allocator, "11;rgb:0/0/0"));
}

test "a yank over the cap isn't sent" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const big = try testing.allocator.alloc(u8, max_copy + 1);
    defer testing.allocator.free(big);
    const place: Place = .{ .ssh = true, .tmux = false, .wayland = false, .x11 = false };
    try testing.expectEqual(CopyResult.too_big, try copy(testing.allocator, testing.io, place, &w, big));
    try testing.expectEqual(@as(usize, 0), w.buffered().len);
    try testing.expectEqual(CopyResult.copied, try copy(testing.allocator, testing.io, place, &w, "hi"));
    try testing.expectEqualStrings("\x1b]52;c;aGk=\x07", w.buffered());
}
