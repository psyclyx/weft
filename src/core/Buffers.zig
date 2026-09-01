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
const projection_mod = @import("projection.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const semantic = @import("weft_semantic");
const Editor = @import("Editor.zig");
const Posture = @import("weft_input").Posture;
const Keymap = @import("Keymap.zig");
const Head = @import("Head.zig");
const task = @import("task.zig");
pub const Place = @import("place.zig").Place;

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
/// buffer's mode (files/git) leak into a file opened from it. Captured from
/// the base — never from a buffer switch — so no tool mode can pollute it.
default_mode: []u8 = &.{},
/// The mode the loaded GRAMMAR rests in for each posture (§10.4), as the
/// grammar itself declared it (`weft.restingPosture`). This is the whole
/// answer to "what does a structural entry rest in": the entry declares its
/// posture, the grammar declares what that posture means in its own
/// vocabulary, and core pairs them — no core-baked mode name, no grammar
/// asking what tool it is looking at. Empty = undeclared, which falls back
/// through `restingModeFor`.
posture_modes: std.EnumArray(Posture, []u8) = .initFill(&.{}),

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
    /// The plugin projection this entry represents (`files`, `files`), or
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
    /// between operations. An editable projection (mini.files files) is simply
    /// NOT read-only and takes `edit`.
    read_only: bool = false,
    /// The buffer-local semantic cursor, restored when the buffer is selected
    /// again.
    semantic_focus: Head.SemanticFocus = .empty,
    /// The shell's per-buffer attachments (providers); opaque to core.
    frontend: ?*anyopaque = null,
    /// The posture this entry's presentation owner DECLARED (§10.4), or null
    /// to take the derivation. Set through `declarePosture`.
    declared_posture: ?Posture = null,
    /// WHERE this entry's effects run (`doc/place.md`). Buffer-local for the
    /// same reason `mode` and `semantic_focus` are, and for the reason Emacs
    /// makes `default-directory` buffer-local: a tool entry produced inside a
    /// project belongs to that project for its whole life, not to whatever the
    /// user happens to be looking at when its output lands.
    ///
    /// Set at creation by `insert` (see its inheritance rule) and replaceable
    /// through `setPlace`. Defaults to the degenerate `.process` instance, so
    /// an entry that nobody has placed behaves exactly as everything did
    /// before this field existed.
    place: Place = .process,
    /// The node tree this entry IS, when a plugin projects one over it
    /// (`core/projection.zig`). Owned HERE, not by the plugin that built it,
    /// because a projection is a property of the ENTRY: it is what the rows
    /// on screen mean, and it has to outlive a plugin reload the same way the
    /// text does. `owner` inside it is what stops a second plugin driving it.
    projection: ?*projection_mod.View = null,
    /// The declaration a `capture` declaration displaced — what break-out
    /// restores. Meaningless unless `declared_posture == .capture`, which is
    /// why capture can never be a one-way door.
    pre_capture: ?Posture = null,

    /// WHAT the focused row is, when this entry is a projection: the `role`
    /// its producer gave the node under point. Empty otherwise.
    ///
    /// A method on the ENTRY because two fact builders need it —
    /// `intent.factsFor` and `Ctx.capture`, which build the same facts twice
    /// through different code. That duplication predates this and is not fixed
    /// here; what is avoided is making it a THIRD place that has to agree
    /// about what a role is.
    pub fn focusedRole(self: *Buffer) []const u8 {
        const view = self.projection orelse return "";
        const ed = self.textEditor() orelse return "";
        // `subjectAt`, not `nodeAt`: a role is what a verb ACTS ON, so point
        // inside a hunk's body names the hunk. See that method's doc.
        const node = view.subjectAt(ed.cursorOffset()) orelse return "";
        return node.role;
    }

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

    /// How this entry rests under input (`input.Posture`, §10.4). DERIVED
    /// from what the entry can do — an entry that takes interactive text
    /// edits is `text`, one that cannot (a semantic view, a produced
    /// read-only projection) is `structural` — unless its presentation owner
    /// declared otherwise. `field_focused` is the head's question (an
    /// editable field owns the commits while it holds focus), so the entry
    /// answers it per head rather than remembering a foreign cursor.
    pub fn posture(self: *const Buffer, field_focused: bool) Posture {
        const derived: Posture = if (self.editor != null and !self.read_only) .text else .structural;
        const declared = self.declared_posture orelse derived;
        return if (declared == .structural and field_focused) .field else declared;
    }

    /// DECLARE this entry's posture, overriding the derivation. Declaring
    /// `capture` stacks the displaced declaration for `breakOutOfCapture`;
    /// declaring anything else drops that stack (there is nothing to break
    /// out of).
    pub fn declarePosture(self: *Buffer, p: Posture) void {
        if (p == .capture) {
            if (self.declared_posture != .capture) self.pre_capture = self.declared_posture;
        } else {
            self.pre_capture = null;
        }
        self.declared_posture = p;
    }

    /// Leave `capture` for the declaration it displaced. Returns whether this
    /// entry was capturing at all — the grammar's break-out chord is always
    /// bound, so it is pressed far more often than it applies.
    pub fn breakOutOfCapture(self: *Buffer) bool {
        if (self.declared_posture != .capture) return false;
        self.declared_posture = self.pre_capture;
        self.pre_capture = null;
        return true;
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
    for (&self.posture_modes.values) |mode| gpa.free(mode);
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

/// DECLARE the mode the loaded grammar rests in for `posture` (§10.4).
/// Idempotent and order-independent: the last declaration for a posture is
/// the grammar's answer, and no other posture is touched.
pub fn setRestingFor(self: *Buffers, gpa: Allocator, posture: Posture, mode: []const u8) Error!void {
    const owned = try gpa.dupe(u8, mode);
    const slot = self.posture_modes.getPtr(posture);
    gpa.free(slot.*);
    slot.* = owned;
}

/// Where an entry of `posture` rests. `field` and `capture` rest exactly
/// where `structural` does — a field scopes commits, it does not change what
/// the entry rests in, and a capture break-out must land somewhere the
/// grammar still answers keys. `text` falls back to `default_mode`, the base
/// editing mode captured after config load.
pub fn restingModeFor(self: *const Buffers, posture: Posture) []const u8 {
    const declared = self.posture_modes.get(posture);
    if (declared.len > 0) return declared;
    if (posture != .text) {
        const structural = self.posture_modes.get(.structural);
        if (structural.len > 0) return structural;
    }
    return self.default_mode;
}

fn destroyBuffer(self: *Buffers, gpa: Allocator, b: *Buffer) void {
    _ = self;
    if (b.textEditor()) |ed| ed.deinit(gpa);
    if (b.projection) |view| {
        view.deinit();
        gpa.destroy(view);
    }
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

/// Re-place an entry (`doc/place.md` §2.1). Creation-time inheritance is right
/// only until something re-targets the entry: a tool entry reused for a second
/// project — `*grep*` run again from elsewhere — is about the new place from
/// that moment on, and the producer filling it is the only party that knows.
/// A no-op for an id that is not live, so a late producer cannot resurrect a
/// closed entry's state.
pub fn setPlace(self: *Buffers, id: Id, p: Place) void {
    const b = self.get(id) orelse return;
    b.place = p;
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
    // A new entry starts where the entry that produced it is (`doc/place.md`
    // §2.1) — so `*grep*` belongs to the project grep was run in, and keeps
    // belonging to it after focus moves on.
    //
    // This deliberately does NOT repeat `default_mode`'s mistake one field up.
    // Inheriting the MODE let a tool's interaction state leak into a file
    // opened from it, because a mode means something different in the entry it
    // came from. A place does not: an effect produced inside a project is
    // about that project wherever it is displayed. The two fields differ in
    // kind, so they differ in policy.
    //
    // PROVISIONAL for path-backed entries: once the detection provider lands
    // (doc/place.md wave 5), an entry with a backing path takes its place FROM
    // THAT PATH and this inherited value is replaced via `setPlace`. Until
    // then nothing reads `place`, so the provisional value is inert.
    const inherited: Place = if (self.get(self.active_id)) |cur| cur.place else .process;
    b.* = .{
        .id = id,
        .generation = generation,
        .editor = editor,
        .name = owned_name,
        .tool = owned_tool,
        .place = inherited,
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
/// outgoing mode: that is what let a tool buffer's mode (files/git) stick
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
        // …and a chain that never REACHES a resting mode (vim's `insert`
        // falls back to the modeless floor, not to `normal`) resolves through
        // the posture pairing instead of stranding the entry in the floor
        // mode — the mode-leak class pointed the other way. A keymap that
        // declares no resting modes has no opinion here, so its base-mode
        // answer stands unaltered.
        const resting = if (!keymap.hasRestingModes() or keymap.isRestingMode(base))
            base
        else
            self.restingModeFor(old.posture(old.semantic_focus.field != null));
        const held = try gpa.dupe(u8, resting);
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
    } else {
        // A fresh entry DECLARES its resting mode rather than leaving it
        // empty — so exiting a transient sub-mode always has a mode to
        // return to, with no core-baked "normal". WHICH mode is the posture
        // pairing (§10.4): the entry declares how it rests, the grammar
        // declared what that posture means, so a structural entry can never
        // be stamped with the text editing base. This is the mode-leak
        // class's remaining half — the founding bug's mirror image.
        const resting = self.restingModeFor(target.posture(head.semantic_focus.field != null));
        if (resting.len > 0) {
            try head.setModeRaw(gpa, resting);
            target.mode = try gpa.dupe(u8, resting);
        }
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

test "buffers: a new entry starts where the entry that produced it is" {
    const t = std.testing;
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try init(gpa, pool, "user"); // one scratch (id 0)
    defer bufs.deinit(gpa);
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    var head: Head = .empty;
    defer head.deinit(gpa);

    // A fresh set has nothing placed: the degenerate instance, not a null.
    try t.expect(bufs.active().place.isProcess());

    const project: Place = .{ .container = .{
        .locus = .here,
        .ref = .{ .authority = .here, .slot = 7, .generation = 1 },
        .revision = 1,
    } };
    const code = try bufs.create(gpa, "code.zig");
    bufs.setPlace(code, project);
    try bufs.switchTo(gpa, code, &head, &km);

    // The tool entry this entry produces is about the SAME place...
    const grep = try bufs.create(gpa, "*grep*");
    try t.expect(bufs.get(grep).?.place.eql(project));

    // ...and stays about it after focus moves somewhere else entirely. This is
    // the property that retires the "last detected root" global: a tool entry
    // never has to ask what is focused now.
    try bufs.switchTo(gpa, 0, &head, &km);
    try t.expect(bufs.get(grep).?.place.eql(project));
    try t.expect(bufs.active().place.isProcess());
}

test "buffers: setPlace re-targets a reused tool entry, and ignores a dead id" {
    const t = std.testing;
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try init(gpa, pool, "user");
    defer bufs.deinit(gpa);

    const a: Place = .{ .container = .{
        .locus = .here,
        .ref = .{ .authority = .here, .slot = 1, .generation = 1 },
        .revision = 1,
    } };
    const b: Place = .{ .container = .{
        .locus = .here,
        .ref = .{ .authority = .here, .slot = 2, .generation = 1 },
        .revision = 1,
    } };

    const grep = try bufs.create(gpa, "*grep*");
    bufs.setPlace(grep, a);
    try t.expect(bufs.get(grep).?.place.eql(a));
    // Re-running the tool from another project re-targets the same entry.
    bufs.setPlace(grep, b);
    try t.expect(bufs.get(grep).?.place.eql(b));

    // A producer landing after the entry is gone must not resurrect anything.
    const dead: Id = @intCast(bufs.slots.items.len + 5);
    bufs.setPlace(dead, a); // no panic, no effect
}
