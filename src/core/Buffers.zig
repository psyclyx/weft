//! Buffers — the editor's open-buffer set. A buffer is an `Editor`
//! (document + cursor + undo + backing) plus its interaction state:
//! a buffer-local keymap mode (vim state per buffer, saved/restored on
//! focus switch), a read-only flag (tool buffers), a display name, and
//! an opaque frontend slot where the shell hangs per-buffer providers
//! (syntax, LSP, collab) — core never looks inside it.
//!
//! Identity is a stable `Id` (slot index; buffers are heap-allocated so
//! `*Buffer`/`*Editor` pointers survive list growth). Exactly one
//! buffer is active; the set never goes empty (closing the last buffer
//! replaces it with a scratch). Policy — dirty-close prompts, dedupe on
//! open — lives with callers; this is mechanism.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Editor = @import("Editor.zig");
const Keymap = @import("Keymap.zig");
const task = @import("task.zig");

const Buffers = @This();

pool: *task.Pool,
user_agent: []u8,
slots: std.ArrayList(?*Buffer) = .empty,
active_id: Id = 0,
/// The mode a FRESH buffer (no saved mode) starts in — the config's base
/// editing mode ("normal"/"helix-normal"), captured once after config load.
/// A fresh buffer NEVER inherits the current keymap mode: that let a tool
/// buffer's mode (dired/magit) leak into a file opened from it. Captured from
/// the base — never from a buffer switch — so no tool mode can pollute it.
default_mode: []u8 = &.{},

pub const Id = u32;

pub const Buffer = struct {
    id: Id,
    editor: Editor,
    /// Display name (path basename, tool name, or "*scratch*").
    name: []u8,
    /// Keymap mode restored when this buffer takes focus. Empty =
    /// never visited — inherits whatever mode is current.
    mode: []u8 = &.{},
    /// Interactive text edits (`Context.edit` — typing, vim operators) are
    /// refused: the buffer is a projection whose text is PRODUCED (`Context.
    /// render`), not user-editable. Not a permission on an owner — a distinction
    /// between operations. An editable projection (mini.files dired) is simply
    /// NOT read-only and takes `edit`.
    read_only: bool = false,
    /// The shell's per-buffer attachments (providers); opaque to core.
    frontend: ?*anyopaque = null,
};

pub const Error = Allocator.Error;

/// Starts with one active scratch buffer (id 0).
pub fn init(gpa: Allocator, pool: *task.Pool, user_agent: []const u8) Error!Buffers {
    var self: Buffers = .{
        .pool = pool,
        .user_agent = try gpa.dupe(u8, user_agent),
    };
    errdefer gpa.free(self.user_agent);
    _ = try self.create(gpa, "*scratch*");
    return self;
}

pub fn deinit(self: *Buffers, gpa: Allocator) void {
    for (self.slots.items) |slot| {
        if (slot) |b| self.destroyBuffer(gpa, b);
    }
    self.slots.deinit(gpa);
    gpa.free(self.user_agent);
    gpa.free(self.default_mode);
    self.* = undefined;
}

/// Set the base mode fresh buffers start in (the config's editing mode).
/// Called once after config load; not per-switch, so it can't be polluted
/// by a tool buffer's mode.
pub fn setDefaultMode(self: *Buffers, gpa: Allocator, mode: []const u8) Error!void {
    const owned = try gpa.dupe(u8, mode);
    gpa.free(self.default_mode);
    self.default_mode = owned;
}

fn destroyBuffer(self: *Buffers, gpa: Allocator, b: *Buffer) void {
    _ = self;
    b.editor.deinit(gpa);
    gpa.free(b.name);
    gpa.free(b.mode);
    gpa.destroy(b);
}

pub fn active(self: *const Buffers) *Buffer {
    return self.slots.items[self.active_id].?;
}

pub fn get(self: *const Buffers, id: Id) ?*Buffer {
    if (id >= self.slots.items.len) return null;
    return self.slots.items[id];
}

pub fn count(self: *const Buffers) usize {
    var n: usize = 0;
    for (self.slots.items) |s| n += @intFromBool(s != null);
    return n;
}

/// Live buffers in id order — `while (it.next()) |buf| …`.
pub fn iterator(self: *const Buffers) Iterator {
    return .{ .buffers = self };
}

pub const Iterator = struct {
    buffers: *const Buffers,
    next_id: usize = 0,

    pub fn next(self: *Iterator) ?*Buffer {
        while (self.next_id < self.buffers.slots.items.len) {
            const slot = self.buffers.slots.items[self.next_id];
            self.next_id += 1;
            if (slot) |b| return b;
        }
        return null;
    }
};

/// Create an empty buffer (no backing yet — callers open/adopt on its
/// editor, or leave it scratch). Does not focus it.
pub fn create(self: *Buffers, gpa: Allocator, name: []const u8) Error!Id {
    const b = try gpa.create(Buffer);
    errdefer gpa.destroy(b);
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    var editor = try Editor.init(gpa, self.pool, self.user_agent);
    errdefer editor.deinit(gpa);

    // Reuse the lowest free slot, else append.
    const id: Id = blk: {
        for (self.slots.items, 0..) |slot, i| {
            if (slot == null) break :blk @intCast(i);
        }
        try self.slots.append(gpa, null);
        break :blk @intCast(self.slots.items.len - 1);
    };
    b.* = .{ .id = id, .editor = editor, .name = owned_name };
    self.slots.items[id] = b;
    return id;
}

/// The buffer already backed by `path`, if any (dedupe on open).
pub fn findByPath(self: *const Buffers, path: []const u8) ?Id {
    var it = self.iterator();
    while (it.next()) |b| {
        if (b.editor.backingPath()) |p| {
            if (std.mem.eql(u8, p, path)) return b.id;
        }
    }
    return null;
}

/// Focus `id`: the outgoing buffer saves the current keymap mode; the incoming
/// buffer's mode is restored (its saved mode, or — when it's fresh — the base
/// `default_mode`). A fresh buffer does NOT inherit the outgoing mode: that is
/// what let a tool buffer's mode (dired/magit) stick when you opened a file
/// from it. The mode a buffer shows is always determined by the buffer.
/// Keep the active buffer's resting mode in sync with the keymap — called each
/// frame. A buffer's mode is INTRINSIC (magit is always magit, a code file is
/// normal), so it must follow the buffer into any split, not be captured only
/// on switch-away (which left it stale: a tool buffer set its mode via
/// `setMode`, but `.mode` wasn't updated until you switched away, so opening it
/// in another split restored the wrong — usually `normal` — mode, exposing
/// text-editing operators on a projection). Transient MENU modes (leader/…) are
/// skipped so returning to a buffer never lands you back in a menu.
pub fn captureActiveMode(self: *Buffers, gpa: Allocator, keymap: *const Keymap) Error!void {
    const mode = keymap.currentMode();
    if (keymap.isMenuMode(mode)) return;
    const b = self.active();
    if (std.mem.eql(u8, b.mode, mode)) return;
    const owned = try gpa.dupe(u8, mode);
    gpa.free(b.mode);
    b.mode = owned;
}

pub fn switchTo(self: *Buffers, gpa: Allocator, id: Id, keymap: *Keymap) Error!void {
    const target = self.get(id) orelse return;
    if (id == self.active_id) return;
    const old = self.active();
    const held = try gpa.dupe(u8, keymap.currentMode());
    gpa.free(old.mode);
    old.mode = held;
    if (target.mode.len > 0) {
        try keymap.setMode(gpa, target.mode);
    } else if (self.default_mode.len > 0) {
        try keymap.setMode(gpa, self.default_mode);
    }
    self.active_id = id;
}

/// Next live buffer after the active one (cyclic) — `buffer-next`.
pub fn nextId(self: *const Buffers) Id {
    const n = self.slots.items.len;
    var i = (self.active_id + 1) % n;
    while (i != self.active_id) : (i = (i + 1) % n) {
        if (self.slots.items[i] != null) return @intCast(i);
    }
    return self.active_id;
}

/// Close a buffer. Closing the active buffer focuses the next one;
/// closing the last replaces it with a fresh scratch. Dirty checks are
/// the caller's policy.
pub fn close(self: *Buffers, gpa: Allocator, id: Id, keymap: *Keymap) Error!void {
    const b = self.get(id) orelse return;
    if (self.count() == 1) {
        const fresh = try self.create(gpa, "*scratch*");
        try self.switchTo(gpa, fresh, keymap);
    } else if (id == self.active_id) {
        try self.switchTo(gpa, self.nextId(), keymap);
    }
    self.slots.items[id] = null;
    self.destroyBuffer(gpa, b);
}

test {
    std.testing.refAllDecls(@This());
}
