const std = @import("std");

pub const Buffer = struct {
    alloc: std.mem.Allocator,
    lines: std.ArrayList(std.ArrayList(u8)),
    path: []const u8,
    dirty: bool = false,

    pub fn load(alloc: std.mem.Allocator, path: []const u8) !Buffer {
        var self = Buffer{
            .alloc = alloc,
            .lines = std.ArrayList(std.ArrayList(u8)).init(alloc),
            .path = try alloc.dupe(u8, path),
        };
        errdefer self.deinit();

        if (path.len == 0) {
            try self.lines.append(std.ArrayList(u8).init(alloc));
            return self;
        }

        const data = std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                try self.lines.append(std.ArrayList(u8).init(alloc));
                return self;
            },
            else => return err,
        };
        defer alloc.free(data);

        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |chunk| {
            var line = std.ArrayList(u8).init(alloc);
            errdefer line.deinit();
            try line.appendSlice(chunk);
            try self.lines.append(line);
        }
        if (self.lines.items.len > 1 and self.lines.items[self.lines.items.len - 1].items.len == 0) {
            self.lines.items[self.lines.items.len - 1].deinit();
            _ = self.lines.pop();
        }
        return self;
    }

    pub fn deinit(self: *Buffer) void {
        for (self.lines.items) |*line| line.deinit();
        self.lines.deinit();
        self.alloc.free(self.path);
    }

    pub fn save(self: *Buffer) !void {
        const file = try std.fs.cwd().createFile(self.path, .{});
        defer file.close();
        var bw = std.io.bufferedWriter(file.writer());
        const w = bw.writer();
        for (self.lines.items) |line| {
            try w.writeAll(line.items);
            try w.writeByte('\n');
        }
        try bw.flush();
        self.dirty = false;
    }

    pub fn cloneLines(self: *Buffer) !std.ArrayList(std.ArrayList(u8)) {
        var out = std.ArrayList(std.ArrayList(u8)).init(self.alloc);
        errdefer {
            for (out.items) |*l| l.deinit();
            out.deinit();
        }
        for (self.lines.items) |line| {
            var l = std.ArrayList(u8).init(self.alloc);
            errdefer l.deinit();
            try l.appendSlice(line.items);
            try out.append(l);
        }
        return out;
    }

    pub fn setLines(self: *Buffer, new_lines: std.ArrayList(std.ArrayList(u8))) void {
        for (self.lines.items) |*line| line.deinit();
        self.lines.deinit();
        self.lines = new_lines;
    }

    pub fn insertChar(self: *Buffer, row: usize, col: usize, c: u8) !void {
        try self.lines.items[row].insert(col, c);
        self.dirty = true;
    }

    pub fn deleteChar(self: *Buffer, row: usize, col: usize) void {
        _ = self.lines.items[row].orderedRemove(col);
        self.dirty = true;
    }

    pub fn splitLine(self: *Buffer, row: usize, col: usize) !void {
        var tail = std.ArrayList(u8).init(self.alloc);
        errdefer tail.deinit();
        try tail.appendSlice(self.lines.items[row].items[col..]);
        self.lines.items[row].shrinkRetainingCapacity(col);
        try self.lines.insert(row + 1, tail);
        self.dirty = true;
    }

    pub fn joinWithPrev(self: *Buffer, row: usize) !void {
        var removed = self.lines.orderedRemove(row);
        defer removed.deinit();
        try self.lines.items[row - 1].appendSlice(removed.items);
        self.dirty = true;
    }
};
