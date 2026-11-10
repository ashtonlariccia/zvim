//! Undo history: a linear list of groups of edits.
//!
//! Every change to the buffer is recorded as an insert or delete of some
//! bytes at a position. Edits accumulate in `pending` until `commit` closes
//! them into one group, so one command (or one trip through insert mode)
//! undoes in one step. Undoing and then making a new change drops the undone
//! groups.

const std = @import("std");
const Allocator = std.mem.Allocator;

const History = @This();

groups: std.ArrayList(Group) = .empty,
/// Groups [0, applied) are in effect; the rest can be redone.
applied: usize = 0,
pending: std.ArrayList(Edit) = .empty,
/// Cursor position before the first pending edit.
pending_cursor: usize = 0,
next_id: u32 = 1,
/// Id of the newest applied group when the buffer was last saved (0: none).
saved_id: u32 = 0,

pub const Edit = struct {
    kind: enum { insert, delete },
    pos: usize,
    text: []u8,
};

pub const Group = struct {
    id: u32,
    edits: []Edit,
    /// Where the cursor was before the group's edits.
    cursor: usize,
};

pub fn deinit(self: *History, gpa: Allocator) void {
    for (self.groups.items) |g| freeEdits(gpa, g.edits);
    self.groups.deinit(gpa);
    for (self.pending.items) |e| gpa.free(e.text);
    self.pending.deinit(gpa);
    self.* = undefined;
}

/// Records an edit that is about to be or has just been applied.
pub fn record(self: *History, gpa: Allocator, cursor: usize, kind: @FieldType(Edit, "kind"), pos: usize, text: []const u8) !void {
    if (self.pending.items.len == 0) self.pending_cursor = cursor;
    if (self.pending.items.len > 0) {
        const last = &self.pending.items[self.pending.items.len - 1];
        if (last.kind == .insert and kind == .insert and last.pos + last.text.len == pos) {
            // Typing: extend the previous insert.
            const grown = try gpa.realloc(last.text, last.text.len + text.len);
            @memcpy(grown[last.text.len..], text);
            last.text = grown;
            return;
        }
        if (last.kind == .insert and kind == .delete and pos >= last.pos and
            pos + text.len == last.pos + last.text.len)
        {
            // Backspacing over just-typed text: shrink the insert.
            const keep = last.text.len - text.len;
            if (keep == 0) {
                gpa.free(last.text);
                _ = self.pending.pop();
            } else {
                last.text = try gpa.realloc(last.text, keep);
            }
            return;
        }
    }
    const copy = try gpa.dupe(u8, text);
    errdefer gpa.free(copy);
    try self.pending.append(gpa, .{ .kind = kind, .pos = pos, .text = copy });
}

/// Closes the pending edits into one undoable group.
pub fn commit(self: *History, gpa: Allocator) !void {
    if (self.pending.items.len == 0) return;
    try self.groups.ensureUnusedCapacity(gpa, 1);
    for (self.groups.items[self.applied..]) |g| freeEdits(gpa, g.edits);
    self.groups.shrinkRetainingCapacity(self.applied);
    const edits = try self.pending.toOwnedSlice(gpa);
    self.groups.appendAssumeCapacity(.{ .id = self.next_id, .edits = edits, .cursor = self.pending_cursor });
    self.next_id += 1;
    self.applied += 1;
}

/// The group to undo, or null at the oldest change. The caller reverts its
/// edits in reverse order.
pub fn undo(self: *History) ?*const Group {
    if (self.applied == 0) return null;
    self.applied -= 1;
    return &self.groups.items[self.applied];
}

/// The group to redo, or null at the newest change. The caller reapplies
/// its edits in order.
pub fn redo(self: *History) ?*const Group {
    if (self.applied == self.groups.items.len) return null;
    self.applied += 1;
    return &self.groups.items[self.applied - 1];
}

fn currentId(self: *const History) u32 {
    return if (self.applied == 0) 0 else self.groups.items[self.applied - 1].id;
}

/// Whether the buffer differs from what was last saved (or loaded).
pub fn isModified(self: *const History) bool {
    return self.pending.items.len > 0 or self.currentId() != self.saved_id;
}

pub fn markSaved(self: *History) void {
    self.saved_id = self.currentId();
}

fn freeEdits(gpa: Allocator, edits: []Edit) void {
    for (edits) |e| gpa.free(e.text);
    gpa.free(edits);
}

const testing = std.testing;

test "typing and backspacing merge into one insert" {
    const gpa = testing.allocator;
    var h: History = .{};
    defer h.deinit(gpa);
    try h.record(gpa, 0, .insert, 5, "a");
    try h.record(gpa, 0, .insert, 6, "b");
    try h.record(gpa, 0, .insert, 7, "c");
    try h.record(gpa, 0, .delete, 7, "c");
    try testing.expectEqual(@as(usize, 1), h.pending.items.len);
    try testing.expectEqualStrings("ab", h.pending.items[0].text);
    try h.record(gpa, 0, .delete, 5, "ab");
    try testing.expectEqual(@as(usize, 0), h.pending.items.len);
}

test "modified tracks the saved point through undo and redo" {
    const gpa = testing.allocator;
    var h: History = .{};
    defer h.deinit(gpa);
    try testing.expect(!h.isModified());
    try h.record(gpa, 0, .insert, 0, "x");
    try testing.expect(h.isModified());
    try h.commit(gpa);
    h.markSaved();
    try testing.expect(!h.isModified());
    _ = h.undo();
    try testing.expect(h.isModified());
    _ = h.redo();
    try testing.expect(!h.isModified());
    try testing.expect(h.redo() == null);
}

test "a new change after undo drops the redo history" {
    const gpa = testing.allocator;
    var h: History = .{};
    defer h.deinit(gpa);
    try h.record(gpa, 0, .insert, 0, "1");
    try h.commit(gpa);
    try h.record(gpa, 1, .insert, 1, "2");
    try h.commit(gpa);
    h.markSaved();
    _ = h.undo();
    try h.record(gpa, 1, .insert, 1, "3");
    try h.commit(gpa);
    try testing.expect(h.redo() == null);
    try testing.expectEqual(@as(usize, 2), h.groups.items.len);
    try testing.expect(h.isModified()); // the saved state was dropped
}
