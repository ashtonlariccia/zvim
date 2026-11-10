//! Raw terminal I/O: raw mode, alternate screen, window size, and an event
//! wait that wakes on keyboard input, a window resize (SIGWINCH), or the
//! session ending (SIGHUP when the terminal or SSH connection goes away,
//! SIGTERM when asked to quit).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const sys = posix.system;

pub const Size = struct { rows: u16, cols: u16 };

pub const Event = union(enum) {
    input: []const u8,
    resize,
    /// The terminal is gone or zvim was told to quit.
    hangup,
};

const stdin = posix.STDIN_FILENO;
const stdout = posix.STDOUT_FILENO;

const enter_seq = "\x1b[?1049h\x1b[?25l\x1b[?2004h"; // alternate screen, hide cursor, bracketed paste
const leave_seq = "\x1b[?2004l\x1b[0 q\x1b[?25h\x1b[?1049l"; // no bracketed paste, default cursor shape, show cursor, main screen

/// Self-pipe: signal handlers write a byte here so poll() wakes up. 'w' for
/// a resize, 'q' for a hangup or termination.
var signal_pipe: [2]posix.fd_t = .{ -1, -1 };

const handled_signals = [_]posix.SIG{ .WINCH, .HUP, .TERM };

fn onSignal(sig: posix.SIG) callconv(.c) void {
    const byte: []const u8 = if (sig == .WINCH) "w" else "q";
    _ = sys.write(signal_pipe[1], byte.ptr, 1);
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

        try openSignalPipe();
        var act: posix.Sigaction = .{
            .handler = .{ .handler = onSignal },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        for (handled_signals) |sig| posix.sigaction(sig, &act, null);

        writeAll(enter_seq);
        return .{ .original = original };
    }

    pub fn deinit(self: *Terminal) void {
        var act: posix.Sigaction = .{
            .handler = .{ .handler = posix.SIG.DFL },
            .mask = posix.sigemptyset(),
            .flags = 0,
        };
        for (handled_signals) |sig| posix.sigaction(sig, &act, null);
        for (&signal_pipe) |*fd| {
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

    /// Blocks until there is keyboard input, the window was resized, or the
    /// session is ending. Input bytes are read into `buf`; signals take
    /// priority.
    pub fn next(_: *Terminal, buf: []u8) !Event {
        var fds = [_]posix.pollfd{
            .{ .fd = signal_pipe[0], .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = stdin, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = try posix.poll(&fds, -1);

        if (fds[0].revents & posix.POLL.IN != 0) {
            // Drain, so several queued resizes collapse into one redraw.
            var hangup = false;
            var drain: [64]u8 = undefined;
            while (true) {
                const n = posix.read(signal_pipe[0], &drain) catch break;
                if (n == 0) break;
                if (std.mem.indexOfScalar(u8, drain[0..n], 'q') != null) hangup = true;
            }
            return if (hangup) .hangup else .resize;
        }
        // End of input: the terminal went away without a signal reaching us.
        const n = posix.read(stdin, buf) catch return .hangup;
        if (n == 0) return .hangup;
        return .{ .input = buf[0..n] };
    }
};

fn openSignalPipe() !void {
    switch (posix.errno(sys.pipe(&signal_pipe))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
    for (signal_pipe) |fd| {
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
