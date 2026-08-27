//! Buffers — the workspace's open-entry set. An entry is a display name, a
//! buffer-local keymap mode (vim state per buffer, saved/restored on focus
//! switch), an optional tool identity, an opaque frontend slot where the shell
//! hangs per-buffer providers (syntax, LSP, collab) — core never looks inside
//! it — and, only when it holds TEXT, an `Editor` (document + cursor + undo +
//! backing). A semantic/tool entry carries none: it has no document to edit,
//! so text operations on it are refused at `command.Context`'s edit door
//! rather than absorbed by an empty stand-in document.
//!
//! A live buffer has a compact `Id` (slot index) and a generation-checked
//! `Ref`. Use `Id` only while synchronously addressing the current set; use
//! `Ref` whenever identity crosses time (async work, queued UI actions). Slots
//! are reused, so an `Id` alone cannot distinguish a closed buffer from its
//! replacement. Buffers are heap-allocated, therefore `*Buffer`/`*Editor`
//! pointers survive list growth while the buffer remains live. Exactly one
//! buffer is active; the set never goes empty (closing the last buffer replaces
//! it with a scratch). Policy — dirty-close prompts, dedupe on open — lives
//! with callers; this is mechanism.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const semantic = @import("weft_semantic");
const Editor = @import("Editor.zig");
const Keymap = @import("Keymap.zig");
const Head = @import("Head.zig");
const task = @import("task.zig");

const Buffers = @This();

pool: *task.Pool,
user_agent: []u8,
slots: std.ArrayList(?*Buffer) = .empty,
/// Monotonic identity component assigned on creation. Zero is reserved so a
/// default/zeroed `Ref` can never accidentally resolve.
next_generation: u64 = 1,
active_id: Id = 0,
/// The buffer active before the current one — where `buffer-back` returns (so
/// leaving a tool lands you where you came from, not a fresh scratch). Updated
/// on every `switchTo`, so it toggles between the two most recent buffers.
prev_id: Id = 0,
/// The mode a FRESH buffer (no saved mode) starts in — the config's base
/// editing mode ("normal"/"helix-normal"), captured once after config load.
/// A fresh buffer NEVER inherits the current keymap mode: that let a tool
/// buffer's mode (dired/git) leak into a file opened from it. Captured from
/// the base — never from a buffer switch — so no tool mode can pollute it.
default_mode: []u8 = &.{},

pub const Id = u32;

/// Stable buffer identity for work that outlives the synchronous call which
/// selected the buffer. Resolving fails after close, including when the same
/// numeric slot has since been reused.
pub const Ref = struct {
    id: Id,
    generation: u64,
};

pub const Buffer = struct {
    id: Id,
    generation: u64,
    /// Text storage and text-editing state — present only for entries that
    /// HOLD text. Null for a semantic view, whose content is its tool's
    /// presentation. Reach it through `textEditor`.
    editor: ?Editor,
    /// Display name (path basename, tool name, or "*scratch*").
    name: []u8,
    /// The plugin projection this entry represents (`dired`, `files`), or
    /// empty. An ambient fact providers scope on — a projection registers its
    /// `save` under `When{ .tool = … }` so it wins in its own entry, in any
    /// mode — and independent of whether the entry stores text.
    tool: []u8 = &.{},
    /// Keymap mode restored when this buffer takes focus. Empty =
    /// never visited — inherits whatever mode is current.
    mode: []u8 = &.{},
    /// Interactive text edits (`Context.edit` — typing, vim operators) are
    /// refused: the buffer is a projection whose text is PRODUCED (`Context.
    /// render`), not user-editable. Not a permission on an owner — a distinction
    /// between operations. An editable projection (mini.files dired) is simply
    /// NOT read-only and takes `edit`.
    read_only: bool = false,
    /// The buffer-local semantic cursor, restored when the buffer is selected
    /// again.
    semantic_focus: Head.SemanticFocus = .empty,
    /// The shell's per-buffer attachments (providers); opaque to core.
    frontend: ?*anyopaque = null,

    pub fn ref(self: *const Buffer) Ref {
        return .{ .id = self.id, .generation = self.generation };
    }

    /// This entry's text editor, or null when it holds no text.
    pub fn textEditor(self: *Buffer) ?*Editor {
        if (self.editor) |*ed| return ed;
        return null;
    }

    /// Whether closing this entry would drop edits its file backing never
    /// received. A projection has no file to write (`save`/`save-as` say so
    /// too), so its text cannot be "unsaved" in that sense — what its content
    /// is worth is the authoring tool's question, asked its own way.
    pub fn hasUnsavedFile(self: *Buffer, gpa: Allocator) Allocator.Error!bool {
        if (self.tool.len > 0) return false;
        const ed = self.textEditor() orelse return false;
        return ed.isDirty(gpa);
    }

    /// Name the projection this entry represents. Idempotent.
    pub fn setTool(self: *Buffer, gpa: Allocator, name: []const u8) Error!void {
        const owned = try gpa.dupe(u8, name);
        gpa.free(self.tool);
        self.tool = owned;
    }
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
    if (b.textEditor()) |ed| ed.deinit(gpa);
    b.semantic_focus.deinit(gpa);
    gpa.free(b.name);
    gpa.free(b.tool);
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

/// Resolve a stable identity captured earlier. A closed buffer and a new
/// buffer occupying its old slot are deliberately different identities.
pub fn resolve(self: *const Buffers, ref: Ref) ?*Buffer {
    const b = self.get(ref.id) orelse return null;
    if (ref.generation == 0 or b.generation != ref.generation) return null;
    return b;
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

/// Create a text buffer (no backing yet — callers open/adopt on its editor,
/// or leave it scratch). Does not focus it.
pub fn create(self: *Buffers, gpa: Allocator, name: []const u8) Error!Id {
    var editor = try Editor.init(gpa, self.pool, self.user_agent);
    errdefer editor.deinit(gpa);
    return self.insert(gpa, name, editor, "");
}

/// Create an entry with NO text: a semantic view of `tool`, whose content is
/// that tool's presentation rather than a document. Does not focus it.
pub fn createView(self: *Buffers, gpa: Allocator, name: []const u8, tool: []const u8) Error!Id {
    return self.insert(gpa, name, null, tool);
}

fn insert(self: *Buffers, gpa: Allocator, name: []const u8, editor: ?Editor, tool: []const u8) Error!Id {
    const b = try gpa.create(Buffer);
    errdefer gpa.destroy(b);
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const owned_tool = try gpa.dupe(u8, tool);
    errdefer gpa.free(owned_tool);

    // Reuse the lowest free slot, else append.
    const id: Id = blk: {
        for (self.slots.items, 0..) |slot, i| {
            if (slot == null) break :blk @intCast(i);
        }
        try self.slots.append(gpa, null);
        break :blk @intCast(self.slots.items.len - 1);
    };
    const generation = self.next_generation;
    self.next_generation +%= 1;
    if (self.next_generation == 0) self.next_generation = 1;
    b.* = .{
        .id = id,
        .generation = generation,
        .editor = editor,
        .name = owned_name,
        .tool = owned_tool,
    };
    self.slots.items[id] = b;
    return id;
}

/// The buffer already backed by `path`, if any (dedupe on open).
pub fn findByPath(self: *const Buffers, path: []const u8) ?Id {
    var it = self.iterator();
    while (it.next()) |b| {
        const ed = b.textEditor() orelse continue;
        if (ed.backingPath()) |p| {
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
/// live-set `Id`. Work that targets one exact buffer rather than the logical
/// name captures `Buffer.ref` instead (see `resolveSink`). A caller that must
/// react to creation (mark read-only) should `findByName` + `create` itself.
pub fn ensureNamed(self: *Buffers, gpa: Allocator, name: []const u8) Error!Id {
    return self.findByName(name) orelse try self.create(gpa, name);
}

/// A live stream's sink: the entry `held` captured, or — once that entry has
/// been closed — a fresh one under `name`, re-captured into `held`. Streams
/// (repl/net output) are name-ADDRESSED but identity-HELD, so no rename, slot
/// reuse, or second same-named buffer can steal a drain mid-session.
pub fn resolveSink(self: *Buffers, gpa: Allocator, held: *?Ref, name: []const u8) ?*Buffer {
    if (held.*) |ref| if (self.resolve(ref)) |b| return b;
    const b = self.get(self.ensureNamed(gpa, name) catch return null) orelse return null;
    held.* = b.ref();
    return b;
}

/// Focus `id`: the outgoing buffer saves `head`'s current keymap mode; the
/// incoming buffer's mode is restored INTO `head` (its saved mode, or — when
/// it's fresh — the base `default_mode`). A fresh buffer does NOT inherit the
/// outgoing mode: that is what let a tool buffer's mode (dired/git) stick
/// when you opened a file from it. The mode a buffer shows is always
/// determined by the buffer; WHICH head sees that mode is `head` — the saved
/// mode itself stays a buffer property (system-scoped), only the active
/// cursor being restored into is per-head (doc/contextual-workspace-architecture.md §7).
pub fn switchTo(self: *Buffers, gpa: Allocator, id: Id, head: *Head, keymap: *const Keymap) Error!void {
    const target = self.get(id) orelse return;
    if (id == self.active_id) return;
    const old = self.active();
    // Semantic focus is buffer-local, just like the saved keymap posture.
    // Save before leaving and restore the incoming buffer's cursor. This also
    // guarantees a text buffer never inherits a tool's editable field.
    try old.semantic_focus.copyFrom(gpa, &head.semantic_focus);
    try head.semantic_focus.copyFrom(gpa, &target.semantic_focus);
    // Remember the buffer's RESTING mode — the base of the current mode's
    // fallback chain, not the transient mode itself. So leaving mid-`visual`
    // (or `insert`, or `op-pending`) remembers `normal`, and a switch made from
    // inside a menu (`SPC g g` runs git-status while `leader-git` is active) is
    // skipped rather than stamping the buffer with a menu mode. No per-mode
    // bookkeeping — it reuses the fallback declarations config already makes.
    const base = keymap.baseMode(head.currentMode());
    if (!keymap.isMenuMode(base)) {
        const held = try gpa.dupe(u8, base);
        gpa.free(old.mode);
        old.mode = held;
    }
    // A buffer switch bypasses the keymap dispatch site entirely (this
    // function's own doc, and Keymap.zig's locked-mode doc) — `head.mode` is
    // about to be overwritten directly below, not popped through
    // `Head.popTransientMode`. Any transient/menu frame still open (task
    // #19 item 2: dispatch.zig's paired-transient menu push) named a return
    // target in the buffer being LEFT, which this switch is discarding
    // anyway — so there is nothing left to restore it into. Drop it now
    // rather than let it outlive the scope it described (`hasOpenTransients`
    // would otherwise keep reporting a menu that, from here on, no key can
    // ever reach again — the exact silent leak the pairing exists to kill).
    head.dropAllTransients(gpa);
    self.prev_id = self.active_id;
    // mechanism-not-policy (task #19 item 3): this is the buffer-switch
    // resting-mode RESTORE, `switchTo`'s own nuanced semantics (see this
    // function's module doc) — no `*command.Context` to capture a `Ctx`
    // from at this layer, and the door doesn't model "restore mode X
    // because THIS buffer remembers it" anyway. Raw mechanism entry
    // (`Head.setModeRaw`), by design.
    if (target.mode.len > 0) {
        try head.setModeRaw(gpa, target.mode);
    } else if (self.default_mode.len > 0) {
        // A fresh buffer DECLARES its resting mode (the config's base editing
        // mode) rather than leaving it empty — so exiting a transient sub-mode
        // always has a mode to return to, with no core-baked "normal".
        try head.setModeRaw(gpa, self.default_mode);
        target.mode = try gpa.dupe(u8, self.default_mode);
    }
    self.active_id = id;
}

/// Turn the view currently focused on `head` into (or reattach it to) a
/// workspace entry, then focus it. The caller supplies presentation policy
/// (display name and tool fact); semantic identity provides deduplication.
/// The entry carries NO editor — it presents the view, it does not store text.
pub fn attachFocusedSemanticView(
    self: *Buffers,
    gpa: Allocator,
    head: *Head,
    keymap: *const Keymap,
    name: []const u8,
    tool: []const u8,
) Error!Id {
    const view = head.semantic_focus.view orelse return self.active_id;
    var id: ?Id = null;
    var it = self.iterator();
    while (it.next()) |buffer| {
        if (buffer.semantic_focus.view) |candidate| if (candidate.eql(view)) {
            id = buffer.id;
            break;
        };
    }
    const target_id = id orelse try self.createView(gpa, name, tool);
    const target = self.get(target_id).?;
    // Capture the just-opened path on its destination before switchTo saves
    // the outgoing buffer. Then clear the head so the outgoing buffer records
    // no foreign semantic cursor.
    try target.semantic_focus.copyFrom(gpa, &head.semantic_focus);
    if (target_id == self.active_id) return target_id;
    head.semantic_focus.clear();
    try self.switchTo(gpa, target_id, head, keymap);
    return target_id;
}

/// Switch to the buffer active before this one (where a tool's `q` returns).
/// Falls back to any other live buffer, then to a fresh scratch — so it always
/// leaves the current buffer even if the previous one was closed. GENERIC: a
/// tool binds `q` here and thinks no further about where "back" is.
pub fn back(self: *Buffers, gpa: Allocator, head: *Head, keymap: *const Keymap) Error!void {
    if (self.prev_id != self.active_id and self.get(self.prev_id) != null)
        return self.switchTo(gpa, self.prev_id, head, keymap);
    // No valid previous: land on the lowest-id other live buffer, if any.
    for (self.slots.items, 0..) |slot, i| {
        if (slot != null and i != self.active_id) return self.switchTo(gpa, @intCast(i), head, keymap);
    }
    // Nothing else exists — open a scratch.
    const id = try self.create(gpa, "*scratch*");
    try self.switchTo(gpa, id, head, keymap);
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
pub fn close(self: *Buffers, gpa: Allocator, id: Id, head: *Head, keymap: *const Keymap) Error!void {
    const b = self.get(id) orelse return;
    if (self.count() == 1) {
        const fresh = try self.create(gpa, "*scratch*");
        try self.switchTo(gpa, fresh, head, keymap);
    } else if (id == self.active_id) {
        try self.switchTo(gpa, self.nextId(), head, keymap);
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
    var head: Head = .empty;
    defer head.deinit(gpa);

    const code = try bufs.create(gpa, "code.zig");
    const git = try bufs.create(gpa, "*git*");

    try head.setModeRaw(gpa, "normal");
    try bufs.switchTo(gpa, code, &head, &km);

    // Leaving `code` mid-VISUAL remembers its BASE mode (normal), not visual.
    try head.setModeRaw(gpa, "visual");
    try bufs.switchTo(gpa, git, &head, &km);
    try t.expectEqualStrings("normal", bufs.get(code).?.mode);

    // Leaving `git` in git mode remembers git.
    try head.setModeRaw(gpa, "git");
    try bufs.switchTo(gpa, code, &head, &km);
    try t.expectEqualStrings("git", bufs.get(git).?.mode);

    // A switch made from inside a MENU (git-status while `leader-git` is up)
    // must NOT stamp the buffer being left with the menu mode.
    try head.setModeRaw(gpa, "leader-git");
    try bufs.switchTo(gpa, git, &head, &km); // restores git's own mode
    try t.expectEqualStrings("normal", bufs.get(code).?.mode); // still normal, not leader-git
    try t.expectEqualStrings("git", head.currentMode());

    // `back` returns to the previous buffer (code), in its base mode (normal).
    try bufs.back(gpa, &head, &km);
    try t.expectEqual(code, bufs.active_id);
    try t.expectEqualStrings("normal", head.currentMode());
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

test "buffers: attaching a focused view makes an entry with no editor" {
    const t = std.testing;
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try init(gpa, pool, "user");
    defer bufs.deinit(gpa);
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    var head: Head = .empty;
    defer head.deinit(gpa);

    const view: semantic.view.Ref = .{ .authority = .here, .slot = 1, .generation = 7 };
    try head.semantic_focus.set(gpa, .{ .view = view, .nodes = &.{} });
    const id = try bufs.attachFocusedSemanticView(gpa, &head, &km, "files: /tmp", "files");

    const entry = bufs.get(id).?;
    try t.expect(entry.textEditor() == null);
    try t.expectEqualStrings("files", entry.tool);
    // A scratch entry, by contrast, holds text.
    try t.expect(bufs.get(0).?.textEditor() != null);

    // Re-attaching the same view reuses the entry rather than opening a second.
    try head.semantic_focus.set(gpa, .{ .view = view, .nodes = &.{} });
    try t.expectEqual(id, try bufs.attachFocusedSemanticView(gpa, &head, &km, "files: /tmp", "files"));
}

test "buffers: Ref rejects a closed generation when its slot is reused" {
    const t = std.testing;
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try init(gpa, pool, "user");
    defer bufs.deinit(gpa);
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    var head: Head = .empty;
    defer head.deinit(gpa);

    const first_id = try bufs.create(gpa, "first");
    const first_ref = bufs.get(first_id).?.ref();
    try t.expect(bufs.resolve(first_ref) == bufs.get(first_id).?);

    // The non-active slot is immediately reusable, but not the identity.
    try bufs.close(gpa, first_id, &head, &km);
    try t.expect(bufs.resolve(first_ref) == null);
    const replacement_id = try bufs.create(gpa, "replacement");
    const replacement_ref = bufs.get(replacement_id).?.ref();
    try t.expectEqual(first_id, replacement_id);
    try t.expect(first_ref.generation != replacement_ref.generation);
    try t.expect(bufs.resolve(first_ref) == null);
    try t.expect(bufs.resolve(replacement_ref) == bufs.get(replacement_id).?);
}

test {
    std.testing.refAllDecls(@This());
}
