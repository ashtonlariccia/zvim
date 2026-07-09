const std = @import("std");

pub const Entry = struct {
    path: []u8, // relative to root
    depth: u16,
    is_dir: bool,
    expanded: bool = false,

    pub fn name(self: Entry) []const u8 {
        return std.fs.path.basename(self.path);
    }
};

/// A flattened view of the directory: entries appear in render order,
/// children of an expanded directory directly after it at depth + 1.
pub const Tree = struct {
    alloc: std.mem.Allocator,
    root: []u8,
    entries: std.ArrayList(Entry),

    pub fn init(alloc: std.mem.Allocator, root: []const u8) !Tree {
        var self = Tree{
            .alloc = alloc,
            .root = try alloc.dupe(u8, root),
            .entries = std.ArrayList(Entry).init(alloc),
        };
        errdefer self.deinit();
        _ = try self.scanInto("", 0, 0);
        return self;
    }

    pub fn deinit(self: *Tree) void {
        for (self.entries.items) |e| self.alloc.free(e.path);
        self.entries.deinit();
        self.alloc.free(self.root);
    }

    /// Expand or collapse the directory at idx.
    pub fn toggle(self: *Tree, idx: usize) !void {
        if (!self.entries.items[idx].is_dir) return;
        const depth = self.entries.items[idx].depth;
        if (self.entries.items[idx].expanded) {
            self.entries.items[idx].expanded = false;
            while (idx + 1 < self.entries.items.len and
                self.entries.items[idx + 1].depth > depth)
            {
                const removed = self.entries.orderedRemove(idx + 1);
                self.alloc.free(removed.path);
            }
        } else {
            _ = try self.scanInto(self.entries.items[idx].path, idx + 1, depth + 1);
            self.entries.items[idx].expanded = true;
        }
    }

    /// Replace the root; on failure the old tree is left intact.
    pub fn reroot(self: *Tree, root: []const u8) !void {
        const nt = try Tree.init(self.alloc, root);
        self.deinit();
        self.* = nt;
    }

    pub fn fullPath(self: *Tree, idx: usize) ![]u8 {
        return std.fs.path.join(self.alloc, &.{ self.root, self.entries.items[idx].path });
    }

    /// Scan root/rel and insert its entries (sorted dirs-first, dotfiles
    /// hidden) at index `at`.
    fn scanInto(self: *Tree, rel: []const u8, at: usize, depth: u16) !usize {
        const full = try std.fs.path.join(self.alloc, &.{ self.root, rel });
        defer self.alloc.free(full);
        var dir = try std.fs.cwd().openDir(full, .{ .iterate = true });
        defer dir.close();

        var tmp = std.ArrayList(Entry).init(self.alloc);
        errdefer {
            for (tmp.items) |e| self.alloc.free(e.path);
            tmp.deinit();
        }
        var it = dir.iterate();
        while (try it.next()) |de| {
            if (de.name.len == 0 or de.name[0] == '.') continue;
            const child = if (rel.len == 0)
                try self.alloc.dupe(u8, de.name)
            else
                try std.fs.path.join(self.alloc, &.{ rel, de.name });
            tmp.append(.{
                .path = child,
                .depth = depth,
                .is_dir = de.kind == .directory,
            }) catch |err| {
                self.alloc.free(child);
                return err;
            };
        }
        std.mem.sort(Entry, tmp.items, {}, less);
        try self.entries.insertSlice(at, tmp.items);
        const n = tmp.items.len;
        tmp.deinit();
        return n;
    }

    fn less(_: void, a: Entry, b: Entry) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        return std.ascii.lessThanIgnoreCase(a.name(), b.name());
    }
};
