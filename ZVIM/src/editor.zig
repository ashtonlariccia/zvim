const std = @import("std");
const term_mod = @import("terminal.zig");
const Terminal = term_mod.Terminal;
const Key = term_mod.Key;
const Direction = term_mod.Direction;
const Buffer = @import("buffer.zig").Buffer;
const Tree = @import("tree.zig").Tree;

pub const Editor = struct {
    alloc: std.mem.Allocator,
    term: *Terminal,
    buf: *Buffer,
    tabs: std.ArrayList(Tab),
    active: usize = 0,
    mode: Mode = .command,
    row: usize = 0,
    col: usize = 0,
    top: usize = 0,
    left: usize = 0,
    cmd: std.ArrayList(u8),
    cmd_cur: usize = 0,
    msg: []const u8 = "",
    matches: std.ArrayList(Pos),
    match_idx: usize = 0,
    searched: bool = false,
    sel_anchor: ?usize = null,
    msg_buf: [32]u8 = undefined,
    undo_stack: std.ArrayList(Snapshot),
    redo_stack: std.ArrayList(Snapshot),
    undo_pending: bool = false,
    pending: u8 = 0,
    count: usize = 0,
    yank: std.ArrayList(u8),
    last_search: std.ArrayList(u8),
    tree: ?*Tree = null,
    tree_visible: bool = false,
    tree_sel: usize = 0,
    tree_top: usize = 0,
    focus: Focus = .buffer,
    cmd_sep: u8 = ':',
    confirm_reload: bool = false,
    tab_spans: [max_tabs][2]usize = undefined,
    tab_span_n: usize = 0,
    quit: bool = false,

    const Mode = enum { command, edit, cmdline, search };
    const Focus = enum { buffer, tree };
    const Pos = struct { row: usize, col: usize };
    const max_undo = 100;
    const tree_w = 24;
    const max_tabs = 9;
    const max_tab_name = 14;

    const Tab = struct {
        buf: *Buffer,
        row: usize = 0,
        col: usize = 0,
        top: usize = 0,
        left: usize = 0,
    };

    const Snapshot = struct {
        lines: std.ArrayList(std.ArrayList(u8)),
        row: usize,
        col: usize,
        dirty: bool,

        fn deinit(self: *Snapshot) void {
            for (self.lines.items) |*l| l.deinit();
            self.lines.deinit();
        }
    };

    pub fn init(alloc: std.mem.Allocator, term: *Terminal, first: Buffer) !Editor {
        var fb = first;
        errdefer fb.deinit();
        const bp = try alloc.create(Buffer);
        errdefer alloc.destroy(bp);
        bp.* = fb;
        var tabs = std.ArrayList(Tab).init(alloc);
        errdefer tabs.deinit();
        try tabs.append(.{ .buf = bp });
        return .{
            .alloc = alloc,
            .term = term,
            .buf = bp,
            .tabs = tabs,
            .cmd = std.ArrayList(u8).init(alloc),
            .matches = std.ArrayList(Pos).init(alloc),
            .yank = std.ArrayList(u8).init(alloc),
            .last_search = std.ArrayList(u8).init(alloc),
            .undo_stack = std.ArrayList(Snapshot).init(alloc),
            .redo_stack = std.ArrayList(Snapshot).init(alloc),
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.tabs.items) |t| {
            t.buf.deinit();
            self.alloc.destroy(t.buf);
        }
        self.tabs.deinit();
        self.cmd.deinit();
        self.matches.deinit();
        self.yank.deinit();
        self.last_search.deinit();
        for (self.undo_stack.items) |*s| s.deinit();
        self.undo_stack.deinit();
        for (self.redo_stack.items) |*s| s.deinit();
        self.redo_stack.deinit();
    }

    fn takeSnapshot(self: *Editor) !Snapshot {
        return .{
            .lines = try self.buf.cloneLines(),
            .row = self.row,
            .col = self.col,
            .dirty = self.buf.dirty,
        };
    }

    fn pushUndoSnap(self: *Editor, snap: Snapshot) !void {
        try self.undo_stack.append(snap);
        if (self.undo_stack.items.len > max_undo) {
            var old = self.undo_stack.orderedRemove(0);
            old.deinit();
        }
        for (self.redo_stack.items) |*s| s.deinit();
        self.redo_stack.clearRetainingCapacity();
    }

    fn noteEdit(self: *Editor) !void {
        if (self.undo_pending) {
            self.undo_pending = false;
            try self.pushUndoSnap(try self.takeSnapshot());
        }
    }

    fn applySnapshot(self: *Editor, s: Snapshot) void {
        self.buf.setLines(s.lines);
        self.buf.dirty = s.dirty;
        self.row = @min(s.row, self.buf.lines.items.len - 1);
        self.col = @min(s.col, self.buf.lines.items[self.row].items.len);
        self.sel_anchor = null;
    }

    fn undo(self: *Editor) !void {
        if (self.undo_stack.items.len == 0) {
            self.msg = "already at oldest change";
            return;
        }
        try self.redo_stack.append(try self.takeSnapshot());
        self.applySnapshot(self.undo_stack.pop());
    }

    fn redo(self: *Editor) !void {
        if (self.redo_stack.items.len == 0) {
            self.msg = "already at newest change";
            return;
        }
        try self.undo_stack.append(try self.takeSnapshot());
        self.applySnapshot(self.redo_stack.pop());
    }

    pub fn handleKey(self: *Editor, key: Key) !void {
        switch (key) {
            .resize => return,
            .wheel => |wh| return self.wheelScroll(wh),
            .page_up => return self.pageMove(false),
            .page_down => return self.pageMove(true),
            else => {},
        }
        self.msg = "";
        if (self.confirm_reload) {
            self.confirm_reload = false;
            switch (key) {
                .char => |c| if (c == 'y') try self.forceReload(),
                else => {},
            }
            return;
        }
        const pending = self.pending;
        self.pending = 0;
        switch (self.mode) {
            .command => {
                if (self.focus == .tree and self.tree_visible) {
                    if (try self.treeKey(key)) return;
                }
                switch (key) {
                    .char => |c| {
                        if (pending == 'r') {
                            if (c >= 32 and c < 127 and self.col < self.buf.lines.items[self.row].items.len) {
                                try self.pushUndoSnap(try self.takeSnapshot());
                                self.buf.lines.items[self.row].items[self.col] = c;
                                self.buf.dirty = true;
                            }
                            return;
                        }
                        if ((c >= '1' and c <= '9') or (c == '0' and self.count > 0)) {
                            self.count = self.count * 10 + (c - '0');
                            return;
                        }
                        const raw = self.count;
                        self.count = 0;
                        try self.commandChar(c, pending, raw);
                    },
                    .arrow => |d| self.move(d),
                    .esc => {
                        self.sel_anchor = null;
                        self.count = 0;
                    },
                    .mouse => |m| {
                        if (self.barClick(m)) return;
                        if (!try self.treeMouse(m)) {
                            self.focus = .buffer;
                            if (m.drag) {
                                if (self.sel_anchor == null) self.sel_anchor = self.row;
                            } else {
                                self.sel_anchor = null;
                            }
                            self.mouseSet(m.x, m.y);
                        }
                    },
                    else => {},
                }
            },
            .edit => switch (key) {
                .esc => self.mode = .command,
                .arrow => |d| self.move(d),
                .char => |c| if (c == '\t') {
                    try self.noteEdit();
                    const line = self.buf.lines.items[self.row].items;
                    var n = 4 - (dispWidth(line, self.col) % 4);
                    while (n > 0) : (n -= 1) {
                        try self.buf.insertChar(self.row, self.col, ' ');
                        self.col += 1;
                    }
                } else if (c >= 32 and c < 127) {
                    try self.noteEdit();
                    try self.insertTyped(c);
                },
                .enter => {
                    try self.noteEdit();
                    try self.insertNewline();
                },
                .backspace => {
                    if (self.col > 0 or self.row > 0) try self.noteEdit();
                    if (self.col > 0) {
                        const line = self.buf.lines.items[self.row].items;
                        const all_ws = for (line[0..self.col]) |ch| {
                            if (ch != ' ' and ch != '\t') break false;
                        } else true;
                        if (all_ws and line[self.col - 1] == ' ') {
                            var n = (dispWidth(line, self.col) - 1) % 4 + 1;
                            while (n > 0 and self.col > 0 and
                                self.buf.lines.items[self.row].items[self.col - 1] == ' ') : (n -= 1)
                            {
                                self.buf.deleteChar(self.row, self.col - 1);
                                self.col -= 1;
                            }
                        } else {
                            if (closerFor(line[self.col - 1])) |close| {
                                if (self.col < line.len and line[self.col] == close)
                                    self.buf.deleteChar(self.row, self.col);
                            }
                            self.buf.deleteChar(self.row, self.col - 1);
                            self.col -= 1;
                        }
                    } else if (self.row > 0) {
                        const prev_len = self.buf.lines.items[self.row - 1].items.len;
                        try self.buf.joinWithPrev(self.row);
                        self.row -= 1;
                        self.col = prev_len;
                    }
                },
                .mouse => |m| {
                    if (self.barClick(m)) return;
                    if (!try self.treeMouse(m)) {
                        if (!m.drag) self.mouseSet(m.x, m.y);
                    }
                },
                else => {},
            },
            .cmdline => switch (key) {
                .esc => self.mode = .command,
                .enter => try self.execCmd(),
                .backspace => if (self.cmd_cur > 0) {
                    _ = self.cmd.orderedRemove(self.cmd_cur - 1);
                    self.cmd_cur -= 1;
                },
                .char => |c| if (c >= 32 and c < 127) {
                    try self.cmd.insert(self.cmd_cur, c);
                    self.cmd_cur += 1;
                },
                .arrow => |d| switch (d) {
                    .left => self.cmd_cur -|= 1,
                    .right => self.cmd_cur = @min(self.cmd_cur + 1, self.cmd.items.len),
                    else => {},
                },
                else => {},
            },
            .search => switch (key) {
                .esc => {
                    self.mode = .command;
                    self.searched = false;
                },
                .enter => try self.execSearch(),
                .backspace => {
                    if (self.cmd.items.len > 0) {
                        _ = self.cmd.pop();
                        self.resetSearch();
                    } else {
                        self.mode = .command;
                    }
                },
                .char => |c| if (c >= 32 and c < 127) {
                    try self.cmd.append(c);
                    self.resetSearch();
                },
                .arrow => |d| if (self.searched and self.matches.items.len > 0) {
                    const n = self.matches.items.len;
                    self.match_idx = switch (d) {
                        .right, .down => (self.match_idx + 1) % n,
                        .left, .up => (self.match_idx + n - 1) % n,
                    };
                    self.jumpToMatch();
                },
                else => {},
            },
        }
    }

    fn commandChar(self: *Editor, c: u8, pending: u8, raw: usize) !void {
        const n = @max(raw, 1);
        switch (c) {
            'i' => {
                self.mode = .edit;
                self.sel_anchor = null;
                self.undo_pending = true;
            },
            'a' => {
                self.mode = .edit;
                self.sel_anchor = null;
                self.undo_pending = true;
                if (self.col < self.buf.lines.items[self.row].items.len)
                    self.col += 1;
            },
            'A' => {
                self.mode = .edit;
                self.sel_anchor = null;
                self.undo_pending = true;
                self.col = self.buf.lines.items[self.row].items.len;
            },
            'I' => {
                self.mode = .edit;
                self.sel_anchor = null;
                self.undo_pending = true;
                const line = self.buf.lines.items[self.row].items;
                var ind: usize = 0;
                while (ind < line.len and (line[ind] == ' ' or line[ind] == '\t')) ind += 1;
                self.col = ind;
            },
            'u' => try self.undo(),
            18 => try self.redo(),
            'h' => self.moveN(.left, n),
            'j' => self.moveN(.down, n),
            'k' => self.moveN(.up, n),
            'l' => self.moveN(.right, n),
            'g' => if (pending == 'g') {
                const last = self.buf.lines.items.len - 1;
                self.row = if (raw > 0) @min(raw - 1, last) else 0;
                self.col = 0;
            } else {
                self.pending = 'g';
                self.count = raw;
            },
            'G' => {
                const last = self.buf.lines.items.len - 1;
                self.row = if (raw > 0) @min(raw - 1, last) else last;
                self.clampCol();
            },
            't' => if (pending == 'g') self.cycleTab(true),
            'T' => if (pending == 'g') self.cycleTab(false),
            '0' => self.col = 0,
            '$' => self.col = self.buf.lines.items[self.row].items.len,
            'w' => if (pending == 'c') {
                try self.changeWord();
            } else {
                var i = n;
                while (i > 0) : (i -= 1) self.wordForward();
            },
            'b' => {
                var i = n;
                while (i > 0) : (i -= 1) self.wordBackward();
            },
            '{' => {
                var i = n;
                while (i > 0) : (i -= 1) self.paraBackward();
            },
            '}' => {
                var i = n;
                while (i > 0) : (i -= 1) self.paraForward();
            },
            4 => {
                const half = @max((self.term.size().rows -| 1) / 2, 1);
                self.row = @min(self.row + half, self.buf.lines.items.len - 1);
                self.clampCol();
            },
            21 => {
                const half = @max((self.term.size().rows -| 1) / 2, 1);
                self.row = self.row -| half;
                self.clampCol();
            },
            'x' => {
                const len = self.buf.lines.items[self.row].items.len;
                if (self.col < len) {
                    try self.pushUndoSnap(try self.takeSnapshot());
                    var i = @min(n, len - self.col);
                    while (i > 0) : (i -= 1) self.buf.deleteChar(self.row, self.col);
                }
            },
            'r' => self.pending = 'r',
            'D' => {
                if (self.col < self.buf.lines.items[self.row].items.len) {
                    try self.pushUndoSnap(try self.takeSnapshot());
                    self.buf.lines.items[self.row].shrinkRetainingCapacity(self.col);
                    self.buf.dirty = true;
                }
            },
            'C' => {
                try self.pushUndoSnap(try self.takeSnapshot());
                self.undo_pending = false;
                self.buf.lines.items[self.row].shrinkRetainingCapacity(self.col);
                self.buf.dirty = true;
                self.mode = .edit;
                self.sel_anchor = null;
            },
            'c' => if (pending == 'c') {
                try self.pushUndoSnap(try self.takeSnapshot());
                self.undo_pending = false;
                self.buf.lines.items[self.row].clearRetainingCapacity();
                self.buf.dirty = true;
                self.col = 0;
                self.mode = .edit;
                self.sel_anchor = null;
            } else {
                self.pending = 'c';
                self.count = raw;
            },
            'J' => try self.joinLines(n),
            'd' => if (self.sel_anchor) |a| {
                try self.deleteLines(@min(a, self.row), @max(a, self.row));
            } else if (pending == 'd') {
                const last = self.buf.lines.items.len - 1;
                try self.deleteLines(self.row, @min(self.row + n - 1, last));
            } else {
                self.pending = 'd';
                self.count = raw;
            },
            'y' => if (self.sel_anchor) |a| {
                try self.yankLines(@min(a, self.row), @max(a, self.row));
            } else if (pending == 'y') {
                const last = self.buf.lines.items.len - 1;
                try self.yankLines(self.row, @min(self.row + n - 1, last));
            } else {
                self.pending = 'y';
                self.count = raw;
            },
            'p' => try self.paste(true, n),
            'P' => try self.paste(false, n),
            'o' => try self.openLine(true),
            'O' => try self.openLine(false),
            'n' => try self.searchNext(true),
            'N' => try self.searchNext(false),
            'v' => {
                self.sel_anchor = if (self.sel_anchor == null) self.row else null;
            },
            ':', ';', '\\' => {
                self.mode = .cmdline;
                self.cmd_sep = c;
                self.cmd.clearRetainingCapacity();
                self.cmd_cur = 0;
            },
            '\t' => if (self.tree_visible) {
                self.focus = .tree;
            },
            '/' => {
                self.mode = .search;
                self.cmd.clearRetainingCapacity();
                self.resetSearch();
                self.sel_anchor = null;
            },
            else => {},
        }
    }

    fn saveGuarded(self: *Editor) !void {
        if (self.buf.path.len == 0) {
            self.msg = "no file name";
            return;
        }
        try self.buf.save();
    }

    fn execZvimCmd(self: *Editor, c: []const u8) !void {
        if (c.len > 0 and c[0] >= '1' and c[0] <= '9') {
            try self.tabCmd(c);
        } else if (std.mem.eql(u8, c, "t")) {
            if (self.tree == null) return;
            self.tree_visible = !self.tree_visible;
            self.focus = if (self.tree_visible) .tree else .buffer;
        } else if (std.mem.eql(u8, c, "q")) {
            try self.closeTab();
        } else if (std.mem.eql(u8, c, "o") or std.mem.startsWith(u8, c, "o ")) {
            const path = std.mem.trim(u8, c[1..], " ");
            try self.treeOpen(if (path.len == 0) "." else path);
        } else if (std.mem.eql(u8, c, "fr")) {
            self.confirm_reload = true;
            self.msg = "force reload? (y)";
        } else {
            self.msg = "unknown command";
        }
    }

    fn treeOpen(self: *Editor, path: []const u8) !void {
        const t = self.tree orelse return;
        t.reroot(path) catch {
            self.msg = "cannot open directory";
            return;
        };
        self.tree_sel = 0;
        self.tree_top = 0;
        self.tree_visible = true;
        self.focus = .tree;
    }

    fn forceReload(self: *Editor) !void {
        while (self.tabs.items.len > 1) {
            var t = self.tabs.pop();
            t.buf.deinit();
            self.alloc.destroy(t.buf);
        }
        self.active = 0;
        self.buf = self.tabs.items[0].buf;
        self.replaceBuffer(try Buffer.load(self.alloc, ""));
        if (self.tree) |t| {
            t.reroot(".") catch {};
            self.tree_sel = 0;
            self.tree_top = 0;
        }
        self.tree_visible = false;
        self.focus = .buffer;
        self.mode = .command;
    }

    fn treeCd(self: *Editor, path: []const u8) !void {
        const t = self.tree orelse return;
        const target = blk: {
            if (path.len == 0)
                break :blk try self.alloc.dupe(u8, std.posix.getenv("HOME") orelse ".");
            if (std.fs.path.isAbsolute(path))
                break :blk try self.alloc.dupe(u8, path);
            break :blk try std.fs.path.resolve(self.alloc, &.{ t.root, path });
        };
        defer self.alloc.free(target);
        try self.treeOpen(target);
    }

    fn treeParent(self: *Editor) !void {
        const t = self.tree orelse return;
        const abs = std.fs.cwd().realpathAlloc(self.alloc, t.root) catch return;
        defer self.alloc.free(abs);
        const parent = std.fs.path.dirname(abs) orelse return;
        try self.treeOpen(parent);
    }

    fn paneOff(self: *Editor) usize {
        return if (self.tree_visible and self.tree != null) tree_w + 1 else 0;
    }

    fn treeKey(self: *Editor, key: Key) !bool {
        switch (key) {
            .char => |c| switch (c) {
                'j' => self.treeMove(1),
                'k' => self.treeMove(-1),
                '-' => try self.treeParent(),
                '\t' => self.focus = .buffer,
                ':', ';', '\\' => return false,
                else => {},
            },
            .arrow => |d| switch (d) {
                .down => self.treeMove(1),
                .up => self.treeMove(-1),
                else => {},
            },
            .enter => try self.treeActivate(),
            .esc => self.focus = .buffer,
            .mouse => return false,
            else => {},
        }
        return true;
    }

    fn treeMove(self: *Editor, delta: isize) void {
        const len = self.tree.?.entries.items.len;
        if (len == 0) return;
        if (delta > 0) {
            self.tree_sel = @min(self.tree_sel + 1, len - 1);
        } else {
            self.tree_sel -|= 1;
        }
    }

    fn treeActivate(self: *Editor) !void {
        const t = self.tree.?;
        if (t.entries.items.len == 0) return;
        if (t.entries.items[self.tree_sel].is_dir) {
            try t.toggle(self.tree_sel);
            return;
        }
        const full = try t.fullPath(self.tree_sel);
        defer self.alloc.free(full);
        try self.openFile(full);
    }

    fn openFile(self: *Editor, path: []const u8) !void {
        for (self.tabs.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.buf.path, path)) {
                if (i != self.active) {
                    self.saveView();
                    self.activateTab(i);
                }
                self.focus = .buffer;
                return;
            }
        }
        const fresh_scratch = self.buf.path.len == 0 and !self.buf.dirty;
        if (!fresh_scratch and self.tabs.items.len >= max_tabs) {
            self.msg = "tab limit reached";
            return;
        }
        const nb = Buffer.load(self.alloc, path) catch {
            self.msg = "cannot open file";
            return;
        };
        if (fresh_scratch) {
            self.replaceBuffer(nb);
        } else {
            const bp = self.alloc.create(Buffer) catch |err| {
                var tmp = nb;
                tmp.deinit();
                return err;
            };
            bp.* = nb;
            self.saveView();
            self.tabs.append(.{ .buf = bp }) catch |err| {
                bp.deinit();
                self.alloc.destroy(bp);
                return err;
            };
            self.activateTab(self.tabs.items.len - 1);
        }
        self.focus = .buffer;
    }

    fn anyDirty(self: *Editor) bool {
        for (self.tabs.items) |t| {
            if (t.buf.dirty) return true;
        }
        return false;
    }

    fn saveView(self: *Editor) void {
        const t = &self.tabs.items[self.active];
        t.row = self.row;
        t.col = self.col;
        t.top = self.top;
        t.left = self.left;
    }

    fn activateTab(self: *Editor, idx: usize) void {
        self.active = idx;
        const t = self.tabs.items[idx];
        self.buf = t.buf;
        self.row = @min(t.row, self.buf.lines.items.len - 1);
        self.col = @min(t.col, self.buf.lines.items[self.row].items.len);
        self.top = t.top;
        self.left = t.left;
        self.sel_anchor = null;
        self.resetSearch();
        self.clearUndo();
    }

    fn cycleTab(self: *Editor, forward: bool) void {
        const n = self.tabs.items.len;
        if (n < 2) return;
        self.saveView();
        self.activateTab(if (forward) (self.active + 1) % n else (self.active + n - 1) % n);
    }

    fn closeTab(self: *Editor) !void {
        _ = try self.closeTabAt(self.active, false);
    }

    fn closeTabAt(self: *Editor, idx: usize, force: bool) !bool {
        if (!force and self.tabs.items[idx].buf.dirty) {
            self.msg = "unsaved changes";
            return false;
        }
        var t = self.tabs.orderedRemove(idx);
        t.buf.deinit();
        self.alloc.destroy(t.buf);
        if (self.tabs.items.len == 0) {
            const bp = try self.alloc.create(Buffer);
            errdefer self.alloc.destroy(bp);
            bp.* = try Buffer.load(self.alloc, "");
            try self.tabs.append(.{ .buf = bp });
            if (self.tree != null) {
                self.tree_visible = true;
                self.focus = .tree;
            }
            self.activateTab(0);
        } else if (idx < self.active) {
            self.active -= 1;
        } else if (idx == self.active) {
            self.activateTab(@min(idx, self.tabs.items.len - 1));
        }
        return true;
    }

    fn tabCmd(self: *Editor, c: []const u8) !void {
        var i: usize = 0;
        while (i < c.len and std.ascii.isDigit(c[i])) i += 1;
        const n1 = std.fmt.parseInt(usize, c[0..i], 10) catch 0;
        var n2 = n1;
        var rest = c[i..];
        if (rest.len > 0 and rest[0] == ':') {
            var j: usize = 1;
            while (j < rest.len and std.ascii.isDigit(rest[j])) j += 1;
            n2 = std.fmt.parseInt(usize, rest[1..j], 10) catch 0;
            rest = rest[j..];
        }
        const ntabs = self.tabs.items.len;
        if (n1 == 0 or n2 == 0 or n1 > ntabs or n2 > ntabs) {
            self.msg = "no such tab";
            return;
        }
        const lo = @min(n1, n2) - 1;
        const hi = @max(n1, n2) - 1;
        if (rest.len == 0) {
            if (lo != hi) {
                self.msg = "range needs a command";
            } else if (lo != self.active) {
                self.saveView();
                self.activateTab(lo);
            }
            return;
        }
        const do_w = rest[0] == 'w';
        const do_q = std.mem.indexOfScalar(u8, rest, 'q') != null;
        const force = rest[rest.len - 1] == '!';
        const known = std.mem.eql(u8, rest, "w") or std.mem.eql(u8, rest, "q") or
            std.mem.eql(u8, rest, "q!") or std.mem.eql(u8, rest, "wq") or
            std.mem.eql(u8, rest, "wq!");
        if (!known) {
            self.msg = "unknown command";
            return;
        }
        if (do_w) {
            var k = lo;
            while (k <= hi) : (k += 1) {
                const b = self.tabs.items[k].buf;
                if (b.path.len == 0) {
                    self.msg = "no file name";
                    continue;
                }
                try b.save();
            }
        }
        if (do_q) {
            var k = hi + 1;
            while (k > lo) : (k -= 1) {
                if (!try self.closeTabAt(k - 1, force)) return;
            }
        }
    }

    fn barClick(self: *Editor, m: Key.Mouse) bool {
        if (m.drag or m.y != self.term.size().rows) return false;
        for (0..self.tab_span_n) |i| {
            if (m.x >= self.tab_spans[i][0] and m.x < self.tab_spans[i][1]) {
                if (i != self.active) {
                    self.saveView();
                    self.activateTab(i);
                }
                self.mode = .command;
                self.focus = .buffer;
                break;
            }
        }
        return true;
    }

    fn replaceBuffer(self: *Editor, nb: Buffer) void {
        self.buf.deinit();
        self.buf.* = nb;
        self.row = 0;
        self.col = 0;
        self.top = 0;
        self.left = 0;
        self.sel_anchor = null;
        self.resetSearch();
        self.clearUndo();
    }

    fn clearUndo(self: *Editor) void {
        for (self.undo_stack.items) |*s| s.deinit();
        self.undo_stack.clearRetainingCapacity();
        for (self.redo_stack.items) |*s| s.deinit();
        self.redo_stack.clearRetainingCapacity();
        self.undo_pending = false;
    }

    fn treeMouse(self: *Editor, m: Key.Mouse) !bool {
        if (!self.tree_visible or self.tree == null) return false;
        if (m.x > tree_w) return false;
        if (m.drag) return true;
        const sz = self.term.size();
        if (m.y >= sz.rows) return true;
        if (m.y < 2) return true;
        const idx = self.tree_top + m.y - 2;
        if (idx >= self.tree.?.entries.items.len) return true;
        self.mode = .command;
        if (self.focus == .tree and idx == self.tree_sel) {
            try self.treeActivate();
        } else {
            self.tree_sel = idx;
            self.focus = .tree;
        }
        return true;
    }

    fn writeTreeHeader(self: *Editor, w: anytype) !void {
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        var root = std.fs.cwd().realpath(self.tree.?.root, &pbuf) catch self.tree.?.root;
        var pre: []const u8 = "";
        if (std.posix.getenv("HOME")) |home| {
            if (std.mem.startsWith(u8, root, home)) {
                root = root[home.len..];
                pre = "~";
            }
        }
        var mid: []const u8 = "";
        var vis = pre.len + root.len;
        if (vis > tree_w) {
            mid = "…";
            root = root[root.len - (tree_w - pre.len - 1) ..];
            vis = tree_w;
        }
        try w.writeAll("\x1b[38;2;166;227;161m");
        const lpad = (tree_w - vis) / 2;
        try w.writeByteNTimes(' ', lpad);
        try w.writeAll(pre);
        try w.writeAll(mid);
        try w.writeAll(root);
        try w.writeByteNTimes(' ', tree_w - vis - lpad);
        try w.writeAll("\x1b[m\x1b[38;2;88;91;112m│\x1b[m");
    }

    fn writeTreeRow(self: *Editor, w: anytype, i: usize) !void {
        const t = self.tree.?;
        const idx = self.tree_top + i;
        if (idx < t.entries.items.len) {
            const e = t.entries.items[idx];
            if (idx == self.tree_sel) try w.writeAll("\x1b[48;2;49;50;68m");
            var used: usize = @min(@as(usize, e.depth) * 2, tree_w);
            try w.writeByteNTimes(' ', used);
            if (e.is_dir) {
                try w.writeAll("\x1b[38;2;137;180;250m");
                if (used + 2 <= tree_w) {
                    try w.writeAll(if (e.expanded) "▾ " else "▸ ");
                    used += 2;
                }
            }
            const nm = e.name();
            const shown = @min(nm.len, tree_w - used);
            try w.writeAll(nm[0..shown]);
            used += shown;
            try w.writeByteNTimes(' ', tree_w - used);
            try w.writeAll("\x1b[m");
        } else {
            try w.writeByteNTimes(' ', tree_w);
        }
        try w.writeAll("\x1b[38;2;88;91;112m│\x1b[m");
    }

    const scroll_step = 4;

    fn wheelScroll(self: *Editor, wh: Key.Wheel) void {
        if (self.tree_visible and self.tree != null and wh.x <= tree_w) {
            const len = self.tree.?.entries.items.len;
            if (len == 0) return;
            const rows = if (self.term.size().rows > 1) self.term.size().rows - 1 else 1;
            const trows = @max(rows -| 1, 1);
            self.tree_top = if (wh.up)
                self.tree_top -| scroll_step
            else
                @min(self.tree_top + scroll_step, len - 1);
            self.tree_sel = @min(@max(self.tree_sel, self.tree_top), self.tree_top + trows - 1);
            self.tree_sel = @min(self.tree_sel, len - 1);
            return;
        }
        self.viewShift(!wh.up);
    }

    fn pageMove(self: *Editor, down: bool) void {
        self.viewShift(down);
    }

    fn viewShift(self: *Editor, down: bool) void {
        const sz = self.term.size();
        const rows = if (sz.rows > 1) sz.rows - 1 else 1;
        const last = self.buf.lines.items.len - 1;
        self.top = if (down) @min(self.top + scroll_step, last) else self.top -| scroll_step;
        self.row = @min(@max(self.row, self.top), self.top + rows - 1);
        self.row = @min(self.row, last);
        self.clampCol();
    }

    fn mouseSet(self: *Editor, x: u16, y: u16) void {
        const sz = self.term.size();
        const text_rows = if (sz.rows > 1) sz.rows - 1 else 1;
        if (y < 1 or y > text_rows) return;
        const off = self.paneOff();
        if (x <= off) return;
        self.row = @min(self.top + y - 1, self.buf.lines.items.len - 1);
        const line = self.buf.lines.items[self.row].items;
        self.col = byteColForDisp(line, self.left + (x - 1 - off));
    }

    fn inSelection(self: *Editor, r: usize) bool {
        const a = self.sel_anchor orelse return false;
        return r >= @min(a, self.row) and r <= @max(a, self.row);
    }

    fn resetSearch(self: *Editor) void {
        self.matches.clearRetainingCapacity();
        self.searched = false;
    }

    fn execSearch(self: *Editor) !void {
        if (self.cmd.items.len == 0) return;
        if (!self.searched) {
            try self.scanMatches(self.cmd.items);
            self.last_search.clearRetainingCapacity();
            try self.last_search.appendSlice(self.cmd.items);
            self.searched = true;
            self.match_idx = 0;
            for (self.matches.items, 0..) |m, i| {
                if (m.row > self.row or (m.row == self.row and m.col >= self.col)) {
                    self.match_idx = i;
                    break;
                }
            }
        } else if (self.matches.items.len > 0) {
            self.match_idx = (self.match_idx + 1) % self.matches.items.len;
        }
        self.jumpToMatch();
    }

    fn jumpToMatch(self: *Editor) void {
        if (self.matches.items.len == 0) return;
        const m = self.matches.items[self.match_idx];
        self.row = m.row;
        self.col = m.col;
    }

    fn insertNewline(self: *Editor) !void {
        const line = self.buf.lines.items[self.row].items;
        var ind: usize = 0;
        while (ind < line.len and (line[ind] == ' ' or line[ind] == '\t')) ind += 1;
        ind = @min(ind, self.col);
        const prev: u8 = if (self.col > 0) line[self.col - 1] else 0;
        const next: u8 = if (self.col < line.len) line[self.col] else 0;
        const open = prev == '{' or prev == '(' or prev == '[';
        const expand = open and next == closerFor(prev).?;
        const indent = try self.alloc.dupe(u8, line[0..ind]);
        defer self.alloc.free(indent);

        try self.buf.splitLine(self.row, self.col);
        self.row += 1;
        const new_line = &self.buf.lines.items[self.row];
        try new_line.insertSlice(0, indent);
        if (open) try new_line.insertSlice(indent.len, "    ");
        self.col = indent.len;
        if (open) self.col += 4;
        if (expand) {
            try self.buf.splitLine(self.row, self.col);
            try self.buf.lines.items[self.row + 1].insertSlice(0, indent);
        }
    }

    fn insertTyped(self: *Editor, c: u8) !void {
        const line = self.buf.lines.items[self.row].items;
        const next: u8 = if (self.col < line.len) line[self.col] else 0;

        if (isCloser(c) and next == c) {
            self.col += 1;
            return;
        }
        if (closerFor(c)) |close| {
            const prev: u8 = if (self.col > 0) line[self.col - 1] else 0;
            const quote = c == '"' or c == '\'';
            const lone_quote = quote and
                (std.ascii.isAlphanumeric(prev) or std.ascii.isAlphanumeric(next));
            if (!lone_quote) {
                try self.buf.insertChar(self.row, self.col, c);
                try self.buf.insertChar(self.row, self.col + 1, close);
                self.col += 1;
                return;
            }
        }
        try self.buf.insertChar(self.row, self.col, c);
        self.col += 1;
    }

    fn execCmd(self: *Editor) !void {
        const c = self.cmd.items;
        if (self.cmd_sep == '\\') {
            const t = std.mem.trim(u8, c, " ");
            if (std.mem.eql(u8, t, "cd") or std.mem.startsWith(u8, t, "cd ")) {
                try self.treeCd(std.mem.trim(u8, t[2..], " "));
            } else {
                self.msg = "only cd is supported";
            }
            self.mode = .command;
            self.sel_anchor = null;
            return;
        }
        if (self.cmd_sep == ';') {
            try self.execZvimCmd(c);
            self.mode = .command;
            self.sel_anchor = null;
            return;
        }
        if (std.mem.eql(u8, c, "w")) {
            try self.saveGuarded();
        } else if (std.mem.eql(u8, c, "q")) {
            if (self.anyDirty()) {
                self.msg = "unsaved changes (:q! to discard)";
            } else {
                self.quit = true;
            }
        } else if (std.mem.eql(u8, c, "q!")) {
            self.quit = true;
        } else if (std.mem.eql(u8, c, "wq")) {
            try self.saveGuarded();
            if (self.buf.path.len > 0) {
                if (self.anyDirty()) {
                    self.msg = "unsaved changes in another tab";
                } else {
                    self.quit = true;
                }
            }
        } else if (std.mem.startsWith(u8, c, "s-i ")) {
            try self.substitute(c["s-i ".len..], true);
        } else if (std.mem.startsWith(u8, c, "s ")) {
            try self.substitute(c["s ".len..], false);
        } else if (std.fmt.parseInt(usize, c, 10) catch null) |ln| {
            if (ln > 0) {
                self.row = @min(ln - 1, self.buf.lines.items.len - 1);
                self.clampCol();
            }
        }
        self.mode = .command;
        self.sel_anchor = null;
    }

    fn substitute(self: *Editor, args: []const u8, insensitive: bool) !void {
        const slash = std.mem.indexOfScalar(u8, args, '/') orelse {
            self.msg = "usage: s old/new";
            return;
        };
        const old = std.mem.trim(u8, args[0..slash], " ");
        const new = std.mem.trim(u8, args[slash + 1 ..], " ");
        if (old.len == 0) {
            self.msg = "usage: s old/new";
            return;
        }
        var lo: usize = 0;
        var hi: usize = self.buf.lines.items.len - 1;
        if (self.sel_anchor) |a| {
            lo = @min(a, self.row);
            hi = @max(a, self.row);
        }
        var snap = try self.takeSnapshot();
        var count: usize = 0;
        var r = lo;
        while (r <= hi) : (r += 1) {
            const line = &self.buf.lines.items[r];
            var from: usize = 0;
            while (from + old.len <= line.items.len) {
                const rel = if (insensitive)
                    std.ascii.indexOfIgnoreCase(line.items[from..], old)
                else
                    std.mem.indexOf(u8, line.items[from..], old);
                const i = from + (rel orelse break);
                try line.replaceRange(i, old.len, new);
                from = i + new.len;
                count += 1;
            }
        }
        if (count > 0) {
            self.buf.dirty = true;
            try self.pushUndoSnap(snap);
        } else {
            snap.deinit();
        }
        self.col = @min(self.col, self.buf.lines.items[self.row].items.len);
        self.msg = std.fmt.bufPrint(&self.msg_buf, "{d} replaced", .{count}) catch "replaced";
    }

    fn copyToYank(self: *Editor, lo: usize, hi: usize) !void {
        self.yank.clearRetainingCapacity();
        var r = lo;
        while (r <= hi) : (r += 1) {
            if (r > lo) try self.yank.append('\n');
            try self.yank.appendSlice(self.buf.lines.items[r].items);
        }
    }

    fn deleteLines(self: *Editor, lo: usize, hi: usize) !void {
        try self.copyToYank(lo, hi);
        try self.pushUndoSnap(try self.takeSnapshot());
        var r = hi + 1;
        while (r > lo) : (r -= 1) {
            var removed = self.buf.lines.orderedRemove(r - 1);
            removed.deinit();
        }
        if (self.buf.lines.items.len == 0)
            try self.buf.lines.append(std.ArrayList(u8).init(self.alloc));
        self.buf.dirty = true;
        self.row = @min(lo, self.buf.lines.items.len - 1);
        self.col = @min(self.col, self.buf.lines.items[self.row].items.len);
        self.sel_anchor = null;
    }

    fn yankLines(self: *Editor, lo: usize, hi: usize) !void {
        try self.copyToYank(lo, hi);
        try self.sendOsc52();
        self.sel_anchor = null;
        const n = hi - lo + 1;
        self.msg = std.fmt.bufPrint(&self.msg_buf, "{d} line{s} yanked", .{
            n, if (n > 1) "s" else "",
        }) catch "yanked";
    }

    fn sendOsc52(self: *Editor) !void {
        const enc = std.base64.standard.Encoder;
        const b64 = try self.alloc.alloc(u8, enc.calcSize(self.yank.items.len));
        defer self.alloc.free(b64);
        _ = enc.encode(b64, self.yank.items);
        try self.term.stdout.writeAll("\x1b]52;c;");
        try self.term.stdout.writeAll(b64);
        try self.term.stdout.writeAll("\x07");
    }

    fn paste(self: *Editor, below: bool, n: usize) !void {
        if (self.yank.items.len == 0) {
            self.msg = "nothing to paste";
            return;
        }
        try self.pushUndoSnap(try self.takeSnapshot());
        var at = if (below) self.row + 1 else self.row;
        const first = at;
        var rep = n;
        while (rep > 0) : (rep -= 1) {
            var it = std.mem.splitScalar(u8, self.yank.items, '\n');
            while (it.next()) |chunk| {
                var line = std.ArrayList(u8).init(self.alloc);
                errdefer line.deinit();
                try line.appendSlice(chunk);
                try self.buf.lines.insert(at, line);
                at += 1;
            }
        }
        self.buf.dirty = true;
        self.row = first;
        self.col = 0;
    }

    fn joinLines(self: *Editor, n: usize) !void {
        if (self.row + 1 >= self.buf.lines.items.len) return;
        try self.pushUndoSnap(try self.takeSnapshot());
        var joins = @max(n, 2) - 1;
        while (joins > 0 and self.row + 1 < self.buf.lines.items.len) : (joins -= 1) {
            var next = self.buf.lines.orderedRemove(self.row + 1);
            defer next.deinit();
            const trimmed = std.mem.trimLeft(u8, next.items, " \t");
            const line = &self.buf.lines.items[self.row];
            self.col = line.items.len;
            if (line.items.len > 0 and trimmed.len > 0) try line.append(' ');
            try line.appendSlice(trimmed);
        }
        self.buf.dirty = true;
    }

    fn changeWord(self: *Editor) !void {
        try self.pushUndoSnap(try self.takeSnapshot());
        self.undo_pending = false;
        const line = &self.buf.lines.items[self.row];
        if (self.col < line.items.len) {
            const cls = charClass(line.items[self.col]);
            var end = self.col;
            while (end < line.items.len and charClass(line.items[end]) == cls) end += 1;
            try line.replaceRange(self.col, end - self.col, "");
            self.buf.dirty = true;
        }
        self.mode = .edit;
        self.sel_anchor = null;
    }

    fn paraForward(self: *Editor) void {
        const lines = self.buf.lines.items;
        var r = self.row;
        while (r + 1 < lines.len and lines[r].items.len == 0) r += 1;
        while (r + 1 < lines.len) {
            r += 1;
            if (lines[r].items.len == 0) break;
        }
        self.row = r;
        self.col = 0;
    }

    fn paraBackward(self: *Editor) void {
        const lines = self.buf.lines.items;
        var r = self.row;
        while (r > 0 and lines[r].items.len == 0) r -= 1;
        while (r > 0) {
            r -= 1;
            if (lines[r].items.len == 0) break;
        }
        self.row = r;
        self.col = 0;
    }

    fn scanMatches(self: *Editor, query: []const u8) !void {
        self.matches.clearRetainingCapacity();
        for (self.buf.lines.items, 0..) |line, row| {
            var from: usize = 0;
            while (from < line.items.len) {
                const rel = std.ascii.indexOfIgnoreCase(line.items[from..], query) orelse break;
                try self.matches.append(.{ .row = row, .col = from + rel });
                from += rel + 1;
            }
        }
    }

    fn searchNext(self: *Editor, forward: bool) !void {
        if (self.last_search.items.len == 0) {
            self.msg = "no previous search";
            return;
        }
        try self.scanMatches(self.last_search.items);
        if (self.matches.items.len == 0) {
            self.msg = "pattern not found";
            return;
        }
        if (forward) {
            self.match_idx = 0;
            for (self.matches.items, 0..) |m, i| {
                if (m.row > self.row or (m.row == self.row and m.col > self.col)) {
                    self.match_idx = i;
                    break;
                }
            }
        } else {
            self.match_idx = self.matches.items.len - 1;
            var i = self.matches.items.len;
            while (i > 0) : (i -= 1) {
                const m = self.matches.items[i - 1];
                if (m.row < self.row or (m.row == self.row and m.col < self.col)) {
                    self.match_idx = i - 1;
                    break;
                }
            }
        }
        self.jumpToMatch();
        self.msg = std.fmt.bufPrint(&self.msg_buf, "{d}/{d}", .{
            self.match_idx + 1, self.matches.items.len,
        }) catch "";
    }

    fn openLine(self: *Editor, below: bool) !void {
        try self.pushUndoSnap(try self.takeSnapshot());
        self.undo_pending = false;
        const cur = self.buf.lines.items[self.row].items;
        var ind: usize = 0;
        while (ind < cur.len and (cur[ind] == ' ' or cur[ind] == '\t')) ind += 1;
        var line = std.ArrayList(u8).init(self.alloc);
        errdefer line.deinit();
        try line.appendSlice(cur[0..ind]);
        const at = if (below) self.row + 1 else self.row;
        try self.buf.lines.insert(at, line);
        self.buf.dirty = true;
        self.row = at;
        self.col = ind;
        self.mode = .edit;
        self.sel_anchor = null;
    }

    fn wordForward(self: *Editor) void {
        const lines = self.buf.lines.items;
        var r = self.row;
        var c = self.col;
        const line = lines[r].items;
        if (c < line.len) {
            const cls = charClass(line[c]);
            if (cls != 0) {
                while (c < line.len and charClass(line[c]) == cls) c += 1;
            }
        }
        while (true) {
            const cur = lines[r].items;
            if (c >= cur.len) {
                if (r + 1 >= lines.len) {
                    c = cur.len;
                    break;
                }
                r += 1;
                c = 0;
                if (lines[r].items.len == 0) break;
                continue;
            }
            if (charClass(cur[c]) == 0) {
                c += 1;
                continue;
            }
            break;
        }
        self.row = r;
        self.col = c;
    }

    fn wordBackward(self: *Editor) void {
        const lines = self.buf.lines.items;
        var r = self.row;
        var c = self.col;
        while (true) {
            if (c == 0) {
                if (r == 0) {
                    self.col = 0;
                    return;
                }
                r -= 1;
                c = lines[r].items.len;
                if (c == 0) {
                    self.row = r;
                    self.col = 0;
                    return;
                }
                continue;
            }
            c -= 1;
            if (charClass(lines[r].items[c]) != 0) break;
        }
        const line = lines[r].items;
        const cls = charClass(line[c]);
        while (c > 0 and charClass(line[c - 1]) == cls) c -= 1;
        self.row = r;
        self.col = c;
    }

    fn moveN(self: *Editor, d: Direction, n: usize) void {
        var i = n;
        while (i > 0) : (i -= 1) self.move(d);
    }

    fn clampCol(self: *Editor) void {
        self.col = @min(self.col, self.buf.lines.items[self.row].items.len);
    }

    fn move(self: *Editor, d: Direction) void {
        const lines = self.buf.lines.items;
        switch (d) {
            .up => if (self.row > 0) {
                self.row -= 1;
            },
            .down => if (self.row + 1 < lines.len) {
                self.row += 1;
            },
            .left => if (self.col > 0) {
                self.col -= 1;
            },
            .right => if (self.col < lines[self.row].items.len) {
                self.col += 1;
            },
        }
        self.col = @min(self.col, lines[self.row].items.len);
    }

    pub fn render(self: *Editor) !void {
        const sz = self.term.size();
        const rows = if (sz.rows > 1) sz.rows - 1 else 1;
        const off = self.paneOff();
        const text_cols = sz.cols -| off;
        const cur_disp = dispWidth(self.buf.lines.items[self.row].items, self.col);
        self.scroll(rows, text_cols, cur_disp);
        if (off > 0) {
            const trows = @max(rows -| 1, 1);
            const n_entries = self.tree.?.entries.items.len;
            if (n_entries > 0 and self.tree_sel >= n_entries) self.tree_sel = n_entries - 1;
            if (self.tree_sel < self.tree_top) self.tree_top = self.tree_sel;
            if (self.tree_sel >= self.tree_top + trows) self.tree_top = self.tree_sel - trows + 1;
        }

        var frame = std.ArrayList(u8).init(self.alloc);
        defer frame.deinit();
        const w = frame.writer();
        var scratch = std.ArrayList(u8).init(self.alloc);
        defer scratch.deinit();

        try w.writeAll("\x1b[?25l\x1b[H");
        const splash = self.buf.path.len == 0 and !self.buf.dirty and
            self.buf.lines.items.len == 1 and self.buf.lines.items[0].items.len == 0;
        const splash_lines = [_][]const u8{ "zvim", "", ";t  toggle tree", ":q  quit" };
        const splash_top = rows / 2 -| 2;

        var i: usize = 0;
        while (i < rows) : (i += 1) {
            const r = self.top + i;
            if (off > 0) {
                if (i == 0) try self.writeTreeHeader(w) else try self.writeTreeRow(w, i - 1);
            }
            if (!splash and r < self.buf.lines.items.len) {
                const sel = self.inSelection(r);
                if (sel) try w.writeAll("\x1b[48;2;69;71;90m");
                scratch.clearRetainingCapacity();
                for (self.buf.lines.items[r].items) |ch| {
                    if (ch == '\t') {
                        try scratch.appendNTimes(' ', 4 - (scratch.items.len % 4));
                    } else {
                        try scratch.append(ch);
                    }
                }
                if (self.left < scratch.items.len) {
                    const end = @min(scratch.items.len, self.left + text_cols);
                    if (self.mode == .search and self.searched) {
                        try self.writeHighlighted(w, r, scratch.items, end);
                    } else {
                        try w.writeAll(scratch.items[self.left..end]);
                    }
                }
                try w.writeAll("\x1b[K");
                if (sel) try w.writeAll("\x1b[m");
            } else {
                try w.writeAll("\x1b[38;2;88;91;112m~");
                if (splash and i >= splash_top and i - splash_top < splash_lines.len) {
                    const sl = splash_lines[i - splash_top];
                    if (sl.len > 0 and sl.len + 1 < text_cols) {
                        try w.writeByteNTimes(' ', (text_cols - sl.len) / 2 - 1);
                        if (i == splash_top) try w.writeAll("\x1b[38;2;137;180;250m");
                        try w.writeAll(sl);
                    }
                }
                try w.writeAll("\x1b[m\x1b[K");
            }
            try w.writeAll("\r\n");
        }
        try self.renderStatus(w, sz.cols);

        const on_bar = self.mode == .cmdline or
            (self.mode == .search and !(self.searched and self.matches.items.len > 0));
        if (on_bar) {
            const bcol = if (self.mode == .cmdline) self.cmd_cur else self.cmd.items.len;
            try w.print("\x1b[{d};{d}H\x1b[?25h", .{ sz.rows, bcol + 2 });
        } else if (self.focus != .tree) {
            try w.print("\x1b[{d};{d}H\x1b[?25h", .{ self.row - self.top + 1, cur_disp - self.left + 1 + off });
        }

        try self.term.stdout.writeAll(frame.items);
    }

    fn writeHighlighted(self: *Editor, w: anytype, row: usize, disp: []const u8, end: usize) !void {
        const line = self.buf.lines.items[row].items;
        var pos: usize = self.left;
        for (self.matches.items, 0..) |m, mi| {
            if (m.row != row) continue;
            const ms = dispWidth(line, m.col);
            const me = ms + self.cmd.items.len;
            if (me <= pos or ms >= end) continue;
            const s = @max(ms, pos);
            const e = @min(me, end);
            try w.writeAll(disp[pos..s]);
            try w.writeAll(if (mi == self.match_idx)
                "\x1b[48;2;250;179;135m\x1b[38;2;30;30;46m"
            else
                "\x1b[48;2;249;226;175m\x1b[38;2;30;30;46m");
            try w.writeAll(disp[s..e]);
            try w.writeAll("\x1b[m");
            pos = e;
        }
        try w.writeAll(disp[pos..end]);
    }

    fn renderStatus(self: *Editor, w: anytype, cols: usize) !void {
        var pbuf: [16]u8 = undefined;
        const pos = std.fmt.bufPrint(&pbuf, "{d}:{d}", .{ self.row + 1, self.col + 1 }) catch "";
        const pos_w = @max(pos.len, 7);

        var tb = std.ArrayList(u8).init(self.alloc);
        defer tb.deinit();
        const tabs_w = try self.writeTabs(tb.writer(), cols -| (pos_w + 5));
        const tabs_start = cols -| (tabs_w + pos_w + 3);
        for (0..self.tab_span_n) |i| {
            self.tab_spans[i][0] += tabs_start;
            self.tab_spans[i][1] += tabs_start;
        }

        var left = std.ArrayList(u8).init(self.alloc);
        defer left.deinit();
        if (self.mode == .cmdline or self.mode == .search) {
            try left.append(if (self.mode == .cmdline) self.cmd_sep else '/');
            try left.appendSlice(self.cmd.items);
            if (self.mode == .search and self.searched)
                try left.writer().print("  {d}/{d}", .{
                    if (self.matches.items.len == 0) 0 else self.match_idx + 1,
                    self.matches.items.len,
                });
        } else if (self.msg.len > 0) {
            try left.appendSlice(self.msg);
        } else if (self.mode == .edit) {
            try left.appendSlice("-- INSERT --");
        } else if (self.focus == .tree) {
            try left.appendSlice("[dir]");
        } else if (self.sel_anchor != null) {
            try left.appendSlice("-- VISUAL LINE --");
        }

        try w.writeAll("\x1b[48;2;49;50;68m\x1b[38;2;137;180;250m");
        var used = @min(left.items.len, tabs_start -| 2);
        try w.writeAll(left.items[0..used]);
        while (used < tabs_start) : (used += 1) try w.writeByte(' ');
        try w.writeAll(tb.items);
        try w.writeAll("  ");
        try w.writeByteNTimes(' ', pos_w - pos.len);
        try w.writeAll(pos);
        try w.writeAll(" \x1b[m");
    }

    fn writeTabs(self: *Editor, w: anytype, avail: usize) !usize {
        var used: usize = 0;
        self.tab_span_n = 0;
        for (self.tabs.items, 0..) |t, i| {
            const nm = if (t.buf.path.len == 0) "[no name]" else std.fs.path.basename(t.buf.path);
            const shown = @min(nm.len, max_tab_name);
            const cell = 4 + shown + @as(usize, @intFromBool(shown < nm.len)) +
                @as(usize, @intFromBool(t.buf.dirty));
            if (used + cell > avail) break;
            if (i == self.active) try w.writeAll("\x1b[48;2;69;71;90m");
            try w.print("\x1b[38;2;88;91;112m {d} ", .{i + 1});
            try w.writeAll(if (i == self.active)
                "\x1b[38;2;137;180;250m"
            else
                "\x1b[38;2;108;112;134m");
            try w.writeAll(nm[0..shown]);
            if (shown < nm.len) try w.writeAll("…");
            if (t.buf.dirty) try w.writeByte('+');
            try w.writeByte(' ');
            try w.writeAll("\x1b[48;2;49;50;68m\x1b[38;2;137;180;250m");
            self.tab_spans[i] = .{ used + 1, used + cell + 1 };
            self.tab_span_n = i + 1;
            used += cell;
        }
        return used;
    }

    fn scroll(self: *Editor, rows: usize, cols: usize, cur_disp: usize) void {
        if (self.row < self.top) self.top = self.row;
        if (self.row >= self.top + rows) self.top = self.row - rows + 1;
        if (cur_disp < self.left) self.left = cur_disp;
        if (cur_disp >= self.left + cols) self.left = cur_disp - cols + 1;
    }
};

fn byteColForDisp(line: []const u8, target: usize) usize {
    var w: usize = 0;
    for (line, 0..) |ch, i| {
        if (w >= target) return i;
        w += if (ch == '\t') 4 - (w % 4) else 1;
    }
    return line.len;
}

fn dispWidth(line: []const u8, upto: usize) usize {
    var w: usize = 0;
    for (line[0..upto]) |ch| {
        w += if (ch == '\t') 4 - (w % 4) else 1;
    }
    return w;
}

fn charClass(c: u8) u8 {
    if (c == ' ' or c == '\t') return 0;
    if (std.ascii.isAlphanumeric(c) or c == '_') return 1;
    return 2;
}

fn closerFor(c: u8) ?u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        '{' => '}',
        '"' => '"',
        '\'' => '\'',
        else => null,
    };
}

fn isCloser(c: u8) bool {
    return switch (c) {
        ')', ']', '}', '"', '\'' => true,
        else => false,
    };
}
