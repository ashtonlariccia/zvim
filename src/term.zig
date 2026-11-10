//! Raw terminal I/O: raw mode, alternate screen, window size, and an event
//! wait that wakes on either keyboard input or a window resize (SIGWINCH).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = posix.system;

pub const Size = struct { rows: u16, cols: u16 };

pub const Event = union(enum) {
    input: []const u8,
    resize,
};

const stdin = posix.STDIN_FILENO;
const stdout = posix.STDOUT_FILENO;

const enter_seq = "\x1b[?1049h\x1b[?25l\x1b[?2004h"; // alternate screen, hide cursor, bracketed paste
const leave_seq = "\x1b[?2004l\x1b[0 q\x1b[?25h\x1b[?1049l"; // no bracketed paste, default cursor shape, show cursor, main screen

/// Self-pipe: the SIGWINCH handler writes a byte here so poll() wakes up.
var resize_pipe: [2]posix.fd_t = .{ -1, -1 };

fn onWinch(_: posix.SIG) callconv(.c) void {
    _ = sys.write(resize_pipe[1], "!", 1);
}

pub const Terminal = struct {
    original: posix.termios,

    pub fn init() !Terminal {
        const original = try posix.tcgetattr(stdin);

        var raw = original;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@backingInt(posix.V.MIN)] = 1;
        raw.cc[@backingInt(posix.V.TIME)] = 0;
        try posix.tcsetattr(stdin, .FLUSH, raw);
        errdefer posix.tcsetattr(stdin, .FLUSH, original) catch {};

        try openResizePipe();
        var act: posix.Sigaction = .{
            .handler = .{ .handler = onWinch },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(.WINCH, &act, null);

        writeAll(enter_seq);
        return .{ .original = original };
    }

    pub fn deinit(self: *Terminal) void {
        var act: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        posix.sigaction(.WINCH, &act, null);
        for (&resize_pipe) |*fd| {
            _ = sys.close(fd.*);
            fd.* = -1;
        }
        writeAll(leave_seq);
        posix.tcsetattr(stdin, .FLUSH, self.original) catch {};
    }

    pub fn size() Size {
        var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const rc = if (builtin.link_libc)
            std.c.ioctl(stdout, @bitCast(@as(u32, posix.T.IOCGWINSZ)), &ws)
        else
            sys.ioctl(stdout, posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (posix.errno(rc) != .SUCCESS or ws.row == 0 or ws.col == 0)
            return .{ .rows = 24, .cols = 80 };
        return .{ .rows = ws.row, .cols = ws.col };
    }

    /// Blocks until there is keyboard input or the window was resized.
    /// Input bytes are read into `buf`; resizes take priority.
    pub fn next(_: *Terminal, buf: []u8) !Event {
        var fds = [_]posix.pollfd{
            .{ .fd = resize_pipe[0], .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = stdin, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, -1);

        if (fds[0].revents & posix.POLL.IN != 0) {
            // Drain so several queued resizes collapse into one redraw.
            var drain: [64]u8 = undefined;
            while (true) _ = posix.read(resize_pipe[0], &drain) catch break;
            return .resize;
        }
        const n = try posix.read(stdin, buf);
        return .{ .input = buf[0..n] };
    }
};

fn openResizePipe() !void {
    switch (posix.errno(sys.pipe(&resize_pipe))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    for (resize_pipe) |fd| {
        const flags = sys.fcntl(fd, posix.F.GETFL, @as(usize, 0));
        const nonblock: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        _ = sys.fcntl(fd, posix.F.SETFL, @as(usize, @intCast(flags)) | nonblock);
    }
}

/// Unbuffered write straight to stdout, used for mode switches.
fn writeAll(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = sys.write(stdout, rest.ptr, rest.len);
        switch (posix.errno(rc)) {
            .SUCCESS => rest = rest[@intCast(rc)..],
            .INTR, .AGAIN => continue,
            else => return,
        }
    }
}
