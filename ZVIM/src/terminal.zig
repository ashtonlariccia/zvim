const std = @import("std");

pub const Direction = enum { up, down, left, right };

pub const Key = union(enum) {
    char: u8,
    arrow: Direction,
    mouse: Mouse,
    wheel: Wheel,
    resize,
    page_up,
    page_down,
    esc,
    enter,
    backspace,

    pub const Mouse = struct { x: u16, y: u16, drag: bool };
    pub const Wheel = struct { x: u16, y: u16, up: bool };
};

var winch_fds: [2]std.posix.fd_t = .{ -1, -1 };

fn onWinch(_: c_int) callconv(.C) void {
    _ = std.posix.system.write(winch_fds[1], "r", 1);
}

pub const Terminal = struct {
    stdin: std.fs.File,
    stdout: std.fs.File,
    orig: std.posix.termios,

    pub fn init() !Terminal {
        const stdin = std.io.getStdIn();
        const stdout = std.io.getStdOut();
        const orig = try std.posix.tcgetattr(stdin.handle);

        var raw = orig;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        try std.posix.tcsetattr(stdin.handle, .FLUSH, raw);

        winch_fds = try std.posix.pipe2(.{ .NONBLOCK = true });
        try std.posix.sigaction(std.posix.SIG.WINCH, &.{
            .handler = .{ .handler = onWinch },
            .mask = std.posix.empty_sigset,
            .flags = std.posix.SA.RESTART,
        }, null);

        try stdout.writeAll("\x1b[?1049h\x1b[?1002h\x1b[?1006h\x1b[H");
        return .{ .stdin = stdin, .stdout = stdout, .orig = orig };
    }

    pub fn deinit(self: *Terminal) void {
        self.stdout.writeAll("\x1b[?1006l\x1b[?1002l\x1b[?1049l") catch {};
        std.posix.tcsetattr(self.stdin.handle, .FLUSH, self.orig) catch {};
        std.posix.close(winch_fds[0]);
        std.posix.close(winch_fds[1]);
    }

    pub fn size(self: *Terminal) struct { rows: usize, cols: usize } {
        var ws: std.posix.winsize = undefined;
        const rc = std.posix.system.ioctl(self.stdout.handle, std.posix.T.IOCGWINSZ, @intFromPtr(&ws));
        if (std.posix.errno(rc) == .SUCCESS and ws.ws_col > 0)
            return .{ .rows = ws.ws_row, .cols = ws.ws_col };
        return .{ .rows = 24, .cols = 80 };
    }

    pub fn readKey(self: *Terminal) !Key {
        while (true) {
            var pfds = [_]std.posix.pollfd{
                .{ .fd = self.stdin.handle, .events = std.posix.POLL.IN, .revents = 0 },
                .{ .fd = winch_fds[0], .events = std.posix.POLL.IN, .revents = 0 },
            };
            _ = try std.posix.poll(&pfds, -1);
            if (pfds[1].revents != 0) {
                var drain: [16]u8 = undefined;
                _ = std.posix.read(winch_fds[0], &drain) catch 0;
                return .resize;
            }
            if (pfds[0].revents == 0) continue;
            var b: [1]u8 = undefined;
            if (try self.stdin.read(&b) != 1) return .esc;
            if (b[0] != '\x1b') {
                return switch (b[0]) {
                    '\r', '\n' => .enter,
                    8, 127 => .backspace,
                    else => .{ .char = b[0] },
                };
            }
            if (!self.inputPending()) return .esc;
            if (try self.stdin.read(&b) != 1 or b[0] != '[') return .esc;
            if (try self.stdin.read(&b) != 1) return .esc;
            switch (b[0]) {
                'A' => return .{ .arrow = .up },
                'B' => return .{ .arrow = .down },
                'C' => return .{ .arrow = .right },
                'D' => return .{ .arrow = .left },
                '5', '6' => {
                    const dir = b[0];
                    if (try self.stdin.read(&b) != 1 or b[0] != '~') return .esc;
                    return if (dir == '5') .page_up else .page_down;
                },
                '<' => if (try self.readMouse()) |k| return k,
                else => return .esc,
            }
        }
    }

    fn readMouse(self: *Terminal) !?Key {
        var buf: [24]u8 = undefined;
        var n: usize = 0;
        var fin: u8 = 0;
        while (n < buf.len) {
            var ch: [1]u8 = undefined;
            if (try self.stdin.read(&ch) != 1) return null;
            if (ch[0] == 'M' or ch[0] == 'm') {
                fin = ch[0];
                break;
            }
            buf[n] = ch[0];
            n += 1;
        }
        if (fin != 'M') return null;
        var it = std.mem.splitScalar(u8, buf[0..n], ';');
        const btn = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
        const x = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
        const y = std.fmt.parseInt(u16, it.next() orelse return null, 10) catch return null;
        return switch (btn) {
            0 => .{ .mouse = .{ .x = x, .y = y, .drag = false } },
            32 => .{ .mouse = .{ .x = x, .y = y, .drag = true } },
            64, 65 => .{ .wheel = .{ .x = x, .y = y, .up = btn == 64 } },
            else => null,
        };
    }

    fn inputPending(self: *Terminal) bool {
        var fds = [_]std.posix.pollfd{.{ .fd = self.stdin.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&fds, 10) catch return false;
        return n > 0;
    }
};
