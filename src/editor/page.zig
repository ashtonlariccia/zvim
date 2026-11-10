//! Pages: the help page and the settings file, shown in place of the text.
//!
//! A page is an editor of its own, owned by the real one (`Editor.page`).
//! While it's open it gets the keys and is what's drawn; the text underneath
//! is untouched. What is yanked on a page lands in the real editor's
//! register.

const std = @import("std");
const Editor = @import("../Editor.zig");
const Buffer = @import("../Buffer.zig");
const Key = @import("../keys.zig").Key;
const settings = @import("settings.zig");

/// Opens a page over `ed` showing `text`. Null if one is open already, or
/// `ed` is itself a page.
pub fn open(ed: *Editor, name: []const u8, text: []const u8) !?*Editor {
    if (ed.page != null or ed.is_page) return null;
    const gpa = ed.gpa;
    const page = try gpa.create(Editor);
    errdefer gpa.destroy(page);
    var buffer: Buffer = try .init(gpa, text);
    errdefer buffer.deinit();
    page.* = try .init(gpa, buffer, name);
    page.is_page = true;
    page.settings = ed.settings;
    page.view_rows = ed.view_rows;
    ed.page = page;
    return page;
}

pub fn close(ed: *Editor) void {
    const page = ed.page orelse return;
    ed.page = null;
    page.deinit();
    ed.gpa.destroy(page);
}

/// A key while a page is open. On the help page, q or Escape in normal mode
/// close it; on any page, :q does.
pub fn key(ed: *Editor, k: Key) !Editor.Action {
    const page = ed.page.?;
    if (page.view_only and page.mode == .normal and page.pending.isEmpty()) {
        if (k == .escape or (k == .char and k.char == 'q')) {
            close(ed);
            return .none;
        }
    }
    const action = try page.handleKey(k);
    // Something yanked on the page is for use in the text.
    if (page.clipboard_pending) {
        page.clipboard_pending = false;
        std.mem.swap(Editor.Register, &ed.register, &page.register);
        std.mem.swap(std.ArrayList(u8), &ed.clipboard, &page.clipboard);
        ed.clipboard_pending = true;
    }
    switch (action) {
        .none, .open_settings => {},
        .quit => close(ed),
        .@"suspend" => return .@"suspend",
        // The caller saves the page (`ed.page`), then calls `wrote`.
        .write => {
            if (!page.view_only) return action;
            _ = page.refuseChange();
        },
        .reload => page.setMessage(true, "This page can't be reloaded", .{}),
    }
    return .none;
}

/// Called after a `write` action for the page succeeded: the settings in
/// it take effect at once.
pub fn wrote(ed: *Editor, path: []const u8, then_quit: bool) !void {
    const page = ed.page.?;
    page.wrote(path);
    const contents = try page.buffer.toOwnedSlice(ed.gpa);
    defer ed.gpa.free(contents);
    settings.load(ed, contents);
    page.settings = ed.settings;
    if (ed.message.len > 0) {
        // A bad line: say so on the page, where it can be fixed.
        page.message = ed.message;
        ed.message.len = 0;
    } else if (then_quit) {
        // `path` is the page's own: it goes with the page.
        close(ed);
        ed.setMessage(false, "Settings saved and applied", .{});
    } else {
        page.setMessage(false, "Settings saved and applied", .{});
    }
}
