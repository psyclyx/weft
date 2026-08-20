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
/// The buffer active before the current one — where `buffer-back` returns (so
/// leaving a tool lands you where you came from, not a fresh scratch). Updated
/// on every `switchTo`, so it toggles between the two most recent buffers.
prev_id: Id = 0,
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

/// The buffer with display `name`, if any.
pub fn findByName(self: *const Buffers, name: []const u8) ?Id {
    var it = self.iterator();
    while (it.next()) |b| if (std.mem.eql(u8, b.name, name)) return b.id;
    return null;
}

/// The buffer named `name`, creating an empty one if absent — returning its
/// STABLE `Id`. The handle a streamed/async producer (repl/net/proc output)
/// captures once, instead of re-scanning by name every delivery: buffer ids are
/// stable across list growth, so a rename or a second same-named buffer can't
/// misroute output (a plain name scan can). A caller that must react to
/// creation (mark read-only) should `findByName` + `create` itself.
pub fn ensureNamed(self: *Buffers, gpa: Allocator, name: []const u8) Error!Id {
    return self.findByName(name) orelse try self.create(gpa, name);
}

/// Focus `id`: the outgoing buffer saves the current keymap mode; the incoming
/// buffer's mode is restored (its saved mode, or — when it's fresh — the base
/// `default_mode`). A fresh buffer does NOT inherit the outgoing mode: that is
/// what let a tool buffer's mode (dired/magit) stick when you opened a file
/// from it. The mode a buffer shows is always determined by the buffer.
pub fn switchTo(self: *Buffers, gpa: Allocator, id: Id, keymap: *Keymap) Error!void {
    const target = self.get(id) orelse return;
    if (id == self.active_id) return;
    const old = self.active();
    // Remember the buffer's RESTING mode — the base of the current mode's
    // fallback chain, not the transient mode itself. So leaving mid-`visual`
    // (or `insert`, or `op-pending`) remembers `normal`, and a switch made from
    // inside a menu (`SPC g g` runs git-status while `leader-git` is active) is
    // skipped rather than stamping the buffer with a menu mode. No per-mode
    // bookkeeping — it reuses the fallback declarations config already makes.
    const base = keymap.baseMode(keymap.currentMode());
    if (!keymap.isMenuMode(base)) {
        const held = try gpa.dupe(u8, base);
        gpa.free(old.mode);
        old.mode = held;
    }
    self.prev_id = self.active_id;
    if (target.mode.len > 0) {
        try keymap.setMode(gpa, target.mode);
    } else if (self.default_mode.len > 0) {
        try keymap.setMode(gpa, self.default_mode);
    }
    self.active_id = id;
}

/// Switch to the buffer active before this one (where a tool's `q` returns).
/// Falls back to any other live buffer, then to a fresh scratch — so it always
/// leaves the current buffer even if the previous one was closed. GENERIC: a
/// tool binds `q` here and thinks no further about where "back" is.
pub fn back(self: *Buffers, gpa: Allocator, keymap: *Keymap) Error!void {
    if (self.prev_id != self.active_id and self.get(self.prev_id) != null)
        return self.switchTo(gpa, self.prev_id, keymap);
    // No valid previous: land on the lowest-id other live buffer, if any.
    for (self.slots.items, 0..) |slot, i| {
        if (slot != null and i != self.active_id) return self.switchTo(gpa, @intCast(i), keymap);
    }
    // Nothing else exists — open a scratch.
    const id = try self.create(gpa, "*scratch*");
    try self.switchTo(gpa, id, keymap);
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

test "buffers: switchTo remembers the base mode + skips menus; back returns" {
    const t = std.testing;
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try init(gpa, pool, "user"); // one scratch (id 0)
    defer bufs.deinit(gpa);
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.setFallback(gpa, "visual", "normal"); // visual's base is normal
    try km.markMenuMode(gpa, "leader-git");

    const code = try bufs.create(gpa, "code.zig");
    const magit = try bufs.create(gpa, "*magit*");

    try km.setMode(gpa, "normal");
    try bufs.switchTo(gpa, code, &km);

    // Leaving `code` mid-VISUAL remembers its BASE mode (normal), not visual.
    try km.setMode(gpa, "visual");
    try bufs.switchTo(gpa, magit, &km);
    try t.expectEqualStrings("normal", bufs.get(code).?.mode);

    // Leaving `magit` in magit mode remembers magit.
    try km.setMode(gpa, "magit");
    try bufs.switchTo(gpa, code, &km);
    try t.expectEqualStrings("magit", bufs.get(magit).?.mode);

    // A switch made from inside a MENU (git-status while `leader-git` is up)
    // must NOT stamp the buffer being left with the menu mode.
    try km.setMode(gpa, "leader-git");
    try bufs.switchTo(gpa, magit, &km); // restores magit's own mode
    try t.expectEqualStrings("normal", bufs.get(code).?.mode); // still normal, not leader-git
    try t.expectEqualStrings("magit", km.currentMode());

    // `back` returns to the previous buffer (code), in its base mode (normal).
    try bufs.back(gpa, &km);
    try t.expectEqual(code, bufs.active_id);
    try t.expectEqualStrings("normal", km.currentMode());
}

test "buffers: ensureNamed finds-or-creates by name; the Id is stable" {
    const t = std.testing;
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try init(gpa, pool, "user"); // one *scratch* (id 0)
    defer bufs.deinit(gpa);

    try t.expectEqual(@as(?Id, null), bufs.findByName("*repl*"));
    const id = try bufs.ensureNamed(gpa, "*repl*"); // creates
    try t.expectEqual(id, bufs.findByName("*repl*").?);
    try t.expectEqual(id, try bufs.ensureNamed(gpa, "*repl*")); // idempotent — same Id
    // The stable handle resolves the same buffer regardless of what else opens.
    _ = try bufs.create(gpa, "other.zig");
    try t.expectEqualStrings("*repl*", bufs.get(id).?.name);
}

test {
    std.testing.refAllDecls(@This());
}
