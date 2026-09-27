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
const BindingFacet = @import("weft_input").BindingFacet;
const Keymap = @import("Keymap.zig");
const Head = @import("Head.zig");
const jumplist = @import("jumplist.zig");
const Document = @import("Document.zig");
pub const DocStore = @import("DocStore.zig");
const kv_file = @import("kv_file.zig");
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
/// The status chip plugins publish (`weft.status`) and background refusals
/// are announced on — this system's, beside its entries, so a second system
/// in the process never shows this one's chip.
status: @import("status_feed.zig").Feed = .{},
/// Documents whose entries closed, newest last (doc/model.md §2.2). An entry
/// is a local OPENING of a designation, so closing the entry is not deleting
/// what it opened: a scratch document — which has no file to be reopened
/// from — is parked here, whole, so `weft://here/doc/<id>` (a jumplist entry,
/// an embed, a viewport's subject) can open it again. Bounded: past
/// `parked_cap` the oldest moves on to `documents`, serialized.
parked: std.ArrayList(*Buffer) = .empty,
/// Where a scratch document goes past the parked bound, and what outlives
/// the process (`DocStore`). Always present; memory-only unless a
/// `DocumentFile` binds it to disk. `revive` answers from here when the
/// document is not parked, so a closed scratch comes back by the same route
/// whichever tier holds it. Past `DocStore.doc_cap` the oldest record is
/// released for good, and a designation naming it is refused as gone rather
/// than answered with something else.
documents: DocStore = .{},
/// The plugin whose code is running right now, or empty for the user and
/// core: what a new entry's `creator` is stamped with. A bracket the plugin
/// host sets around every call into a guest (`actAs`), so an entry a guest
/// makes — by `buffer-create`, `open`, a door that spawns — is that guest's,
/// however it came to be made. Borrowed for the bracket's duration.
acting: []const u8 = "",
/// Generations of entries closed since the last `drainClosed` — what the
/// context store retracts entry-scoped values by (`core/context.zig`).
/// Buffers knows nothing of the store; it only says who is gone.
closed: std.ArrayList(u64) = .empty,

pub const parked_cap = 16;

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
    /// The designation this entry's producer DECLARED (doc/model.md §2.2),
    /// owned, or empty — in which case it is derived (`designation.zig`): a
    /// file-backed entry is named by its file, a scratch entry by its
    /// document's minted id, a view by the target it presents. Only what a
    /// producer alone knows is declared here: a projection kind and its
    /// arguments, a live process, a peer's document. Set through
    /// `setDesignation`, whose callers check who may say what.
    designation: []u8 = &.{},
    /// Where `designationText` spells this entry's designation, so a reader
    /// that must not allocate (a fact builder) can borrow it for as long as
    /// the entry lives. Re-spelled on every ask, from the entry as it is.
    spelled: [designation_cap]u8 = undefined,
    /// The plugin projection this entry represents (`files`, `files`), or
    /// empty. An ambient fact providers scope on — a projection registers its
    /// `save` under `When{ .tool = … }` so it wins in its own entry, in any
    /// mode — and independent of whether the entry stores text.
    tool: []u8 = &.{},
    /// The plugin that made this entry (`Buffers.acting` when it was
    /// inserted), owned; empty for the user's and core's own. What says who
    /// may declare what the entry IS (`tool`, `designation`): only its
    /// maker, so no plugin can turn the user's scratch into a process whose
    /// close destroys text, or strip another plugin's entry of its name.
    creator: []u8 = &.{},
    /// Keymap mode restored when this buffer takes focus. Empty =
    /// never visited — inherits whatever mode is current.
    mode: []u8 = &.{},
    /// Interactive text edits (`Context.edit` — typing, vim operators) are
    /// refused: the buffer is a projection whose text is PRODUCED (`Context.
    /// render`), not user-editable. Not a permission on an owner — a distinction
    /// between operations. An editable projection (mini.files files) is simply
    /// NOT read-only and takes `edit`.
    read_only: bool = false,
    /// The semantic VIEW this entry.s producer publishes for it, when the
    /// entry is a text projection rather than a scene.
    ///
    /// A listing renders as text and answers actions through the same view the
    /// scene plane would have — so `view.apply`, a paste carrying the system
    /// transfer, a named register, an interaction dialog all reach it through
    /// the host plumbing that already exists, instead of each being
    /// reimplemented on the guest side of the membrane. What differs is only
    /// WHICH ROW: a scene answers from its focused node, a projection from the
    /// row under point, whose KEY is that node.
    tool_view: ?semantic.view.Ref = null,

    /// The buffer-local semantic cursor, restored when the buffer is selected
    /// again.
    scene_selection: Head.SceneSelection = .empty,
    /// Navigation within one semantic entry retains a cursor per visited view.
    view_cursors: std.ArrayList(struct { view: semantic.view.Ref, node: semantic.scene.NodeId }) = .empty,

    /// The shell's per-buffer attachments (providers); opaque to core.
    frontend: ?*anyopaque = null,
    /// Source-only key layer for named, grammar-backed documents without a
    /// local file backing (e.g. a remote shared source). File-backed entries
    /// use the same layer regardless of whether highlighting is installed.
    source_keys: bool = false,
    /// The posture this entry's presentation owner DECLARED (§10.4), or null
    /// to take the derivation. Set through `declarePosture`.
    declared_posture: ?Posture = null,
    /// WHERE this entry's effects run (`doc/place.md`). Buffer-local for the
    /// same reason `mode` and `scene_selection` are, and for the reason Emacs
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

    pub fn rememberViewCursor(self: *Buffer, gpa: Allocator, focus: *const Head.SceneSelection) Allocator.Error!void {
        const path = focus.path() orelse return;
        const node = path.leaf() orelse return;
        for (self.view_cursors.items) |*saved| {
            if (saved.view.eql(path.view)) {
                saved.node = node;
                return;
            }
        }
        try self.view_cursors.append(gpa, .{ .view = path.view, .node = node });
    }

    pub fn viewCursor(self: *const Buffer, view_ref: semantic.view.Ref) ?semantic.scene.NodeId {
        for (self.view_cursors.items) |saved| if (saved.view.eql(view_ref)) return saved.node;
        return null;
    }

    /// WHAT the focused row is, when this entry is a projection: the `role`
    /// its producer gave the node under point. Empty otherwise.
    ///
    /// A method on the ENTRY because two fact builders need it —
    /// `intent.factsFor` and `Ctx.capture`, which build the same facts twice
    /// through different code. That duplication predates this and is not fixed
    /// here; what is avoided is making it a THIRD place that has to agree
    /// about what a role is.
    /// Is point inside a row.s EDITABLE span?
    ///
    /// A listing is `structural` — rows you navigate — and the NAME in the row
    /// under point is a FIELD. That is not a contradiction: the posture is a
    /// question about where point is, and a projection answers it per row.
    /// Without this, a grammar refuses insert over a listing ("this entry takes
    /// no text") and a rename can never be typed.
    pub fn fieldAtPoint(self: *Buffer) bool {
        const view = self.projection orelse return false;
        const ed = self.textEditor() orelse return false;
        const at = ed.cursorOffset();
        for (view.nodes.items) |n| {
            const edit = n.editable orelse continue;
            if (at >= n.start + edit.start and at <= n.start + edit.end) return true;
        }
        return false;
    }

    pub fn focusedRole(self: *Buffer) []const u8 {
        const view = self.projection orelse return "";
        const ed = self.textEditor() orelse return "";
        // `subjectAt`, not `nodeAt`: a role is what a verb ACTS ON, so point
        // inside a hunk's body names the hunk. See that method's doc.
        //
        // The ROW's role, not the part's: `role` is the fact a third party
        // binds against (`.{ .role = "fs.file" }`), and a file does not stop
        // being one because point is in its permissions column. What the part
        // is remains the projection's own business — styling, and which bytes
        // are a field.
        const subject = view.subjectAt(ed.cursorOffset()) orelse return "";
        return subject.node.role;
    }

    pub fn ref(self: *const Buffer) Ref {
        return .{ .id = self.id, .generation = self.generation };
    }

    /// This entry's text editor, or null when it holds no text.
    pub fn textEditor(self: *Buffer) ?*Editor {
        if (self.editor) |*ed| return ed;
        return null;
    }

    /// Whether closing this entry would drop user edits its file backing never
    /// received. Read-only text entries are generated sinks (process output,
    /// listings, and similar), so their editor dirtiness is producer output,
    /// not user work that needs a save/close refusal.
    pub fn hasUnsavedFile(self: *Buffer, gpa: Allocator) Allocator.Error!bool {
        if (self.read_only or self.tool.len > 0) return false;
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

    /// The facet this entry's keys layer by, if any: a document binds its
    /// `source` layer, an entry that takes no text its `structural` one.
    /// Which MODE answers a facet is the grammar's declaration
    /// (`Keymap.variantFor`), never this entry's business.
    pub fn bindingFacet(self: *Buffer) ?BindingFacet {
        const document = self.source_keys or if (self.textEditor()) |ed| ed.backingPath() != null else false;
        if (document) return .source;
        if (self.posture(false) == .structural) return .structural;
        return null;
    }

    /// The mode `mode`'s keys are looked up in for this entry: the declared
    /// variant for its facet, else `mode` itself.
    pub fn bindingMode(self: *Buffer, keymap: *const Keymap, mode: []const u8) []const u8 {
        const facet = self.bindingFacet() orelse return mode;
        return keymap.variantFor(mode, facet) orelse mode;
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

    /// Declare the designation this entry represents (see `designation`).
    /// Mechanism only: the door a guest reaches this through decides which
    /// kinds it may declare. Empty returns the entry to derivation.
    pub fn setDesignation(self: *Buffer, gpa: Allocator, text: []const u8) Error!void {
        const owned = try gpa.dupe(u8, text);
        gpa.free(self.designation);
        self.designation = owned;
    }

    /// This entry's designation (`designation.of`), spelled into the entry's
    /// own storage — borrowed until the entry closes, and re-spelled by the
    /// next ask. Empty when it has none.
    pub fn designationText(self: *Buffer) []const u8 {
        return @import("designation.zig").of(self, &self.spelled) orelse "";
    }

    /// Whether this entry is a DOCUMENT and nothing else — scratch text with
    /// no file, no producer, and no declared name. Such an entry is named by
    /// its document's minted id, and its document outlives it (`park`).
    pub fn isBareDocument(self: *Buffer) bool {
        const ed = self.textEditor() orelse return false;
        return ed.backing == .none and self.tool.len == 0 and self.designation.len == 0 and !self.read_only;
    }

    /// Whether this entry's document is KEPT when nothing holds it open — a
    /// bare document with text in it. The one answer both keepers read:
    /// closing parks what this admits (`close`), and shutdown keeps what
    /// this admits (`keepDocuments`). Text, not commits: a document restored
    /// from the store starts with an empty commit log and is no less worth
    /// keeping, and one whose text was all deleted has nothing to keep.
    pub fn keepsDocument(self: *Buffer) bool {
        return self.isBareDocument() and self.textEditor().?.text().byteLen() > 0;
    }
};

pub const Error = Allocator.Error;

/// Room for any designation an entry is named by (`designation.max_len`): a
/// path at the OS limit plus scheme, authority and kind.
pub const designation_cap = std.fs.max_path_bytes + 96;

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
    for (self.parked.items) |b| self.destroyBuffer(gpa, b);
    self.parked.deinit(gpa);
    self.documents.deinit(gpa);
    self.closed.deinit(gpa);
    gpa.free(self.user_agent);
    gpa.free(self.default_mode);
    for (&self.posture_modes.values) |mode| gpa.free(mode);
    self.* = undefined;
}

/// The generations closed since the last drain, handed over and forgotten.
/// Borrowed until the next `close`.
pub fn drainClosed(self: *Buffers) []const u64 {
    const gone = self.closed.items;
    self.closed.items.len = 0;
    return gone;
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
    b.scene_selection.deinit(gpa);
    b.view_cursors.deinit(gpa);
    gpa.free(b.name);
    gpa.free(b.tool);
    gpa.free(b.creator);
    gpa.free(b.designation);
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

/// Run the code of plugin `name` (a bracket: entries created meanwhile are
/// its). Answers what was acting, for the caller to put back with `actAs`.
pub fn actAs(self: *Buffers, name: []const u8) []const u8 {
    const was = self.acting;
    self.acting = name;
    return was;
}

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
    const owned_creator = try gpa.dupe(u8, self.acting);
    errdefer gpa.free(owned_creator);

    const id = try self.freeSlot(gpa);
    const generation = self.mintGeneration();
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
        .creator = owned_creator,
        .place = inherited,
    };
    self.slots.items[id] = b;
    return id;
}

/// The lowest free slot, else a new one at the end (left null for the caller
/// to fill before anything else runs).
fn freeSlot(self: *Buffers, gpa: Allocator) Error!Id {
    for (self.slots.items, 0..) |slot, i| {
        if (slot == null) return @intCast(i);
    }
    try self.slots.append(gpa, null);
    return @intCast(self.slots.items.len - 1);
}

fn mintGeneration(self: *Buffers) u64 {
    const generation = self.next_generation;
    self.next_generation +%= 1;
    if (self.next_generation == 0) self.next_generation = 1;
    return generation;
}

/// Keep a closing entry's document (see `parked`). The entry is gone — its
/// slot is free and every `Ref` to it is dead — but the `Buffer` holding the
/// document is kept whole, so its anchors (a jumplist's remembered spots)
/// still resolve when it is reopened.
///
/// Past `parked_cap` the oldest parked document moves on to `documents`,
/// serialized; `head`'s jumps into it settle into offsets first, since the
/// anchors they hold die with this instance of it.
fn park(self: *Buffers, gpa: Allocator, b: *Buffer, head: *Head) Error!void {
    try self.parked.ensureUnusedCapacity(gpa, 1);
    if (self.parked.items.len >= parked_cap) {
        const oldest = self.parked.items[0];
        const ed = oldest.textEditor().?;
        try self.documents.put(gpa, oldest.name, &ed.doc);
        _ = self.parked.orderedRemove(0);
        jumplist.settle(&head.jumps, &ed.doc);
        self.destroyBuffer(gpa, oldest);
    }
    self.parked.appendAssumeCapacity(b);
}

/// Open the closed document `doc` again as a live entry, under a fresh
/// identity (a new slot and generation: nothing that held the closed entry
/// resolves to this one). Does not focus it. Parked first — that is the
/// document itself, anchors and all — else restored from `documents`
/// (`DocStore.take`: its record is consumed, so the document lives in
/// exactly one place at a time), as the user's entry, whoever is acting.
/// Null when neither holds it — never kept, or released past both bounds.
pub fn revive(self: *Buffers, gpa: Allocator, doc: Document.Id) Error!?Id {
    for (self.parked.items, 0..) |b, i| {
        const ed = b.textEditor() orelse continue;
        if (!ed.doc.id.eql(doc)) continue;
        const id = try self.freeSlot(gpa);
        _ = self.parked.orderedRemove(i);
        b.id = id;
        b.generation = self.mintGeneration();
        self.slots.items[id] = b;
        return id;
    }
    var restored = (try self.documents.take(gpa, self.user_agent, doc)) orelse return null;
    defer gpa.free(restored.name);
    errdefer restored.doc.deinit(gpa);
    var editor = try Editor.around(gpa, self.pool, &restored.doc);
    errdefer editor.deinit(gpa);
    // A document someone kept is the user's, not whichever plugin's code
    // happens to be running the `open` that brings it back.
    const was = self.actAs("");
    defer _ = self.actAs(was);
    return try self.insert(gpa, restored.name, editor, "");
}

/// Keep every document worth keeping (`Buffer.keepsDocument`) in
/// `documents`: the parked ones oldest first, then every open one, so the
/// open ones are the newest records and the bound evicts what was closed
/// longest ago first. Records already there that nothing reopened this run
/// stay, older than all of these. The shutdown half of `DocumentFile`; the
/// entries themselves are left as they are.
pub fn keepDocuments(self: *Buffers, gpa: Allocator) Error!void {
    for (self.parked.items) |b| try self.documents.put(gpa, b.name, &b.textEditor().?.doc);
    var it = self.iterator();
    while (it.next()) |b| {
        if (b.keepsDocument()) try self.documents.put(gpa, b.name, &b.textEditor().?.doc);
    }
}

/// The document store bound to its file for a run — `kv_file.Binding` over
/// `documents_file`, with the one step only Buffers can take put in front of
/// the save. `open` LOADS the records (only: nothing is reopened; weft has no
/// session restore, so a kept document comes back when its designation is
/// opened). `close` KEEPS every open and parked document (`keepDocuments`)
/// and then SAVES — one handle, so an embedder cannot write the store without
/// first putting this run's documents in it. Must close while `buffers` is
/// still alive.
pub const DocumentFile = struct {
    gpa: Allocator,
    buffers: *Buffers,
    file: kv_file.Binding,

    pub fn open(gpa: Allocator, buffers: *Buffers) DocumentFile {
        return openIn(gpa, buffers, kv_file.stateDir(gpa));
    }

    /// `open` with the directory handed in (owned; null = persistence off),
    /// as `kv_file.Binding.openIn`.
    pub fn openIn(gpa: Allocator, buffers: *Buffers, dir: ?[]u8) DocumentFile {
        const file = kv_file.Binding.openIn(gpa, &buffers.documents.records, dir, kv_file.documents_file);
        buffers.documents.settle(gpa);
        return .{ .gpa = gpa, .buffers = buffers, .file = file };
    }

    pub fn close(self: *DocumentFile) void {
        self.buffers.keepDocuments(self.gpa) catch |e|
            std.log.warn("documents: could not keep this run's documents ({t}) — saving what is held", .{e});
        self.file.close();
        self.* = undefined;
    }
};

/// Document `doc` wherever it is held — a live entry or the parked store —
/// or null once it has been released. What an anchor into a document needs:
/// the document, not whether anything has it open right now.
pub fn documentById(self: *const Buffers, doc: Document.Id) ?*Document {
    if (self.findByDocument(doc)) |id| return &self.get(id).?.textEditor().?.doc;
    for (self.parked.items) |b| {
        const ed = b.textEditor() orelse continue;
        if (ed.doc.id.eql(doc)) return &ed.doc;
    }
    return null;
}

/// The live entry holding document `doc`, if any.
pub fn findByDocument(self: *const Buffers, doc: Document.Id) ?Id {
    var it = self.iterator();
    while (it.next()) |b| {
        const ed = b.textEditor() orelse continue;
        if (ed.doc.id.eql(doc)) return b.id;
    }
    return null;
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
    // Moving between entries is a jump, and only here does core see every
    // one: remember where this head was (`jumplist.zig`). Travel along the
    // list itself, and a borrow that puts the head back (`withEntry`,
    // `quietly`), is muted there.
    try jumplist.pushHere(&head.jumps, gpa, self);
    // Semantic focus is buffer-local, just like the saved keymap posture.
    // Save before leaving and restore the incoming buffer's cursor. This also
    // guarantees a text buffer never inherits a tool's editable field.
    try old.scene_selection.copyFrom(gpa, &head.scene_selection);
    try head.scene_selection.copyFrom(gpa, &target.scene_selection);
    // Remember the buffer's RESTING mode — the base of the current mode's
    // fallback chain, not the transient mode itself. So leaving mid-`visual`
    // (or `insert`, or `op-pending`) remembers `normal`, and a switch made from
    // inside a menu (`SPC g g` runs git-status while `leader-git` is active) is
    // skipped rather than stamping the buffer with a menu mode. No per-mode
    // bookkeeping — it reuses the fallback declarations config already makes.
    const base = keymap.baseMode(head.currentMode());
    if (!keymap.modeHasTag(base, "menu")) {
        // …and a chain that never REACHES a resting mode (vim's `insert`
        // falls back to the modeless floor, not to `normal`) resolves through
        // the posture pairing instead of stranding the entry in the floor
        // mode — the mode-leak class pointed the other way. A keymap that
        // declares no resting modes has no opinion here, so its base-mode
        // answer stands unaltered.
        const resting = if (!keymap.anyModeHasTag("resting") or keymap.modeHasTag(base, "resting"))
            base
        else
            self.restingModeFor(old.posture(old.scene_selection.field != null));
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
        const resting = self.restingModeFor(target.posture(head.scene_selection.field != null));
        if (resting.len > 0) {
            try head.setModeRaw(gpa, resting);
            target.mode = try gpa.dupe(u8, resting);
        }
    }
    self.active_id = id;
}

/// Borrow entry `id` for one call that is NOT navigation — a toolbar verb
/// acting on the editor it describes, a tab's close glyph: bring it to
/// `head`, run `f(args)`, and put the head back. Neither switch records a
/// jump, and the entry `buffer-back` returns to is left as it was, so the
/// round trip leaves no trace in the head's history. The head goes back
/// unless `f` moved it on from the borrowed entry to another live one (an
/// open the verb performed stands, and records its own jump); when `f`
/// closed the borrowed entry, it goes back all the same.
pub fn withEntry(
    self: *Buffers,
    gpa: Allocator,
    id: Id,
    head: *Head,
    keymap: *const Keymap,
    comptime f: anytype,
    args: anytype,
) Error!@typeInfo(@TypeOf(f)).@"fn".return_type.? {
    if (id == self.active_id) return @call(.auto, f, args);
    const home = self.active_id;
    const home_prev = self.prev_id;
    const borrowed = (self.get(id) orelse return @call(.auto, f, args)).ref();
    try self.switchQuietly(gpa, id, head, keymap);
    defer if (self.active_id == id or self.resolve(borrowed) == null) {
        if (self.get(home) != null) self.switchQuietly(gpa, home, head, keymap) catch {};
        if (self.active_id == home) self.prev_id = home_prev;
    };
    return @call(.auto, f, args);
}

/// Run `f(args)` with `head`'s jump recording muted: whatever entry switches
/// it makes are not navigation (a presentation into another viewport that
/// puts the head back).
pub fn quietly(head: *Head, comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    head.jumps.muted += 1;
    defer head.jumps.muted -= 1;
    return @call(.auto, f, args);
}

fn switchQuietly(self: *Buffers, gpa: Allocator, id: Id, head: *Head, keymap: *const Keymap) Error!void {
    head.jumps.muted += 1;
    defer head.jumps.muted -= 1;
    try self.switchTo(gpa, id, head, keymap);
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
    const view = head.scene_selection.view orelse return self.active_id;
    var id: ?Id = null;
    var it = self.iterator();
    while (it.next()) |buffer| {
        if (buffer.scene_selection.view) |candidate| if (candidate.eql(view)) {
            id = buffer.id;
            break;
        };
    }
    if (id == null) {
        it = self.iterator();
        while (it.next()) |buffer| if (buffer.editor == null and buffer.viewCursor(view) != null) {
            id = buffer.id;
            break;
        };
    }
    const target_id = id orelse try self.createView(gpa, name, tool);
    const target = self.get(target_id).?;
    if (!std.mem.eql(u8, target.name, name)) {
        const renamed = try gpa.dupe(u8, name);
        gpa.free(target.name);
        target.name = renamed;
    }
    // Capture the just-opened path on its destination before switchTo saves
    // the outgoing buffer. Then give the head back the outgoing buffer's own
    // selection, so what switchTo saves there is neither a foreign cursor nor
    // nothing: a listing another listing was opened from still knows which
    // view it shows (and whether that view holds a draft).
    try target.scene_selection.copyFrom(gpa, &head.scene_selection);
    if (target_id == self.active_id) return target_id;
    try head.scene_selection.copyFrom(gpa, &self.active().scene_selection);
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

/// The live buffer before the active one, cyclically (`nextId` reversed).
pub fn prevId(self: *const Buffers) Id {
    const n = self.slots.items.len;
    var i = (self.active_id + n - 1) % n;
    while (i != self.active_id) : (i = (i + n - 1) % n) {
        if (self.slots.items[i] != null) return @intCast(i);
    }
    return self.active_id;
}

/// Close a buffer. Closing the active buffer focuses the next one;
/// closing the last replaces it with a fresh scratch. Dirty checks are
/// the caller's policy. Leaving an entry that is about to die is not
/// recorded as a jump from here: the entry's own jumps already name its
/// designation, which is what a return goes back to.
///
/// A bare document with anything in it is parked rather than destroyed (see
/// `parked`); every other entry's document dies with it, and `head`'s jumps
/// into it keep their offsets for when its designation is opened afresh.
pub fn close(self: *Buffers, gpa: Allocator, id: Id, head: *Head, keymap: *const Keymap) Error!void {
    const b = self.get(id) orelse return;
    if (self.count() == 1) {
        const fresh = try self.create(gpa, "*scratch*");
        try self.switchQuietly(gpa, fresh, head, keymap);
    } else if (id == self.active_id) {
        try self.switchQuietly(gpa, self.nextId(), head, keymap);
    }
    self.slots.items[id] = null;
    // Best effort: a generation missed here is never read again anyway
    // (generations are not reused); it only lingers until the store goes.
    self.closed.append(gpa, b.generation) catch {};
    if (b.keepsDocument()) {
        self.park(gpa, b, head) catch {
            jumplist.settle(&head.jumps, &b.textEditor().?.doc);
            self.destroyBuffer(gpa, b);
        };
        return;
    }
    if (b.textEditor()) |ed| jumplist.settle(&head.jumps, &ed.doc);
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
    try km.tagMode(gpa, "leader-git", "menu");
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
    try head.scene_selection.set(gpa, .{ .view = view, .nodes = &.{} });
    const id = try bufs.attachFocusedSemanticView(gpa, &head, &km, "files: /tmp", "files");

    const entry = bufs.get(id).?;
    try t.expect(entry.textEditor() == null);
    try t.expectEqualStrings("files", entry.tool);
    // A scratch entry, by contrast, holds text.
    try t.expect(bufs.get(0).?.textEditor() != null);

    // Re-attaching the same view reuses the entry rather than opening a second.
    try head.scene_selection.set(gpa, .{ .view = view, .nodes = &.{} });
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

test "buffers: generated read-only output is discardable even when editor-dirty" {
    const t = std.testing;
    const gpa = t.allocator;
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    var bufs = try init(gpa, pool, "user");
    defer bufs.deinit(gpa);

    const output = try bufs.create(gpa, "*run*");
    const b = bufs.get(output).?;
    try b.textEditor().?.doc.insert(gpa, 0, "generated output");
    try t.expect(try b.textEditor().?.isDirty(gpa));
    b.read_only = true;
    try t.expect(!(try b.hasUnsavedFile(gpa)));
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

test "buffers: a scratch document parked past the bound moves to the document store and revives from there" {
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

    var docs: [parked_cap + 1]Document.Id = undefined;
    for (&docs, 0..) |*doc, i| {
        const id = try bufs.create(gpa, "*note*");
        const ed = bufs.get(id).?.textEditor().?;
        var line: [16]u8 = undefined;
        try ed.insertText(gpa, try std.fmt.bufPrint(&line, "note {d}\n", .{i}));
        doc.* = ed.doc.id;
        // A jump into it, so the move to the store has anchors to settle.
        try bufs.switchTo(gpa, id, &head, &km);
        try bufs.switchTo(gpa, 0, &head, &km);
        try bufs.close(gpa, id, &head, &km);
    }
    // The first one closed is no longer parked: it is serialized, not gone.
    try t.expectEqual(@as(usize, parked_cap), bufs.parked.items.len);
    try t.expect(bufs.documentById(docs[0]) == null);
    try t.expect(bufs.documents.contains(docs[0]));

    // Reviving it restores it as a fresh, live, user-made entry, and takes it
    // out of the store — it lives in one place at a time.
    const was = bufs.actAs("some-plugin");
    const id = (try bufs.revive(gpa, docs[0])).?;
    _ = bufs.actAs(was);
    const b = bufs.get(id).?;
    try t.expect(!bufs.documents.contains(docs[0]));
    try t.expect(b.textEditor().?.doc.id.eql(docs[0]));
    try t.expectEqualStrings("*note*", b.name);
    try t.expectEqualStrings("", b.creator);
    try t.expectEqual(@as(usize, 7), b.textEditor().?.text().byteLen()); // "note 0\n"
    try t.expect(b.isBareDocument());

    // Restored with no edits since, it is still kept when closed again.
    try bufs.close(gpa, id, &head, &km);
    try t.expect(bufs.documentById(docs[0]) != null);

    // An id nothing ever kept is refused, not answered with something else.
    try t.expect((try bufs.revive(gpa, Document.mintId())) == null);
}

test "buffers: keeping this run's documents takes every parked and open scratch with text, and nothing else" {
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

    const open_doc = bufs.get(0).?.textEditor().?;
    try open_doc.insertText(gpa, "open scratch\n");
    const closed = try bufs.create(gpa, "*closed*");
    try bufs.get(closed).?.textEditor().?.insertText(gpa, "closed scratch\n");
    const closed_doc = bufs.get(closed).?.textEditor().?.doc.id;
    try bufs.close(gpa, closed, &head, &km);
    const empty = bufs.get(try bufs.create(gpa, "*empty*")).?.textEditor().?.doc.id;
    const tool = try bufs.create(gpa, "*run*");
    try bufs.get(tool).?.textEditor().?.insertText(gpa, "output\n");
    bufs.get(tool).?.read_only = true;
    const tool_doc = bufs.get(tool).?.textEditor().?.doc.id;

    try bufs.keepDocuments(gpa);
    try t.expect(bufs.documents.contains(open_doc.doc.id));
    try t.expect(bufs.documents.contains(closed_doc));
    try t.expect(!bufs.documents.contains(empty));
    try t.expect(!bufs.documents.contains(tool_doc));
}

test "buffers: the document store outlives the process — kept at close, loaded at open, reopened on demand" {
    const t = std.testing;
    const gpa = t.allocator;
    const dir = try kv_file.testDir(gpa, "documents");
    defer gpa.free(dir);
    defer kv_file.removeTestDir(gpa, dir); // LIFO: after the file below is gone
    const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, kv_file.documents_file });
    defer gpa.free(path);
    const file_mod = @import("file.zig");
    file_mod.deleteFile(gpa, path);
    defer file_mod.deleteFile(gpa, path);
    var pool = try task.Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();

    // First run: a scratch with text, open at shutdown.
    const doc = blk: {
        var bufs = try init(gpa, pool, "user");
        defer bufs.deinit(gpa);
        var binding = DocumentFile.openIn(gpa, &bufs, try gpa.dupe(u8, dir));
        const ed = bufs.get(0).?.textEditor().?;
        try ed.insertText(gpa, "survives the restart\n");
        binding.close();
        break :blk ed.doc.id;
    };
    try t.expectEqual(file_mod.Kind.file, file_mod.statKind(gpa, path));

    // Second run: the record is loaded, nothing is opened for it…
    var bufs = try init(gpa, pool, "user");
    defer bufs.deinit(gpa);
    var binding = DocumentFile.openIn(gpa, &bufs, try gpa.dupe(u8, dir));
    defer binding.close();
    try t.expectEqual(@as(usize, 1), bufs.count());
    try t.expect(bufs.documents.contains(doc));
    // …until it is asked for.
    const id = (try bufs.revive(gpa, doc)).?;
    const ed = bufs.get(id).?.textEditor().?;
    try t.expect(ed.doc.id.eql(doc));
    try t.expectEqual(@as(usize, 21), ed.text().byteLen());
    try ed.insertText(gpa, "edited ");
    try t.expect(try ed.undo(gpa, .user_driven));
}
