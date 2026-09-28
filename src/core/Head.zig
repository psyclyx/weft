//! Head — per-head interaction state (doc/contextual-workspace-architecture.md §7).
//! A head is a platform attachment (window+input); heads and systems have
//! independent lifetimes. TWO heads on one system must not share a keymap
//! mode, a pending chord, a pick session, or an echo line — this struct is
//! the value that makes that true BY CONSTRUCTION: there is no process-global
//! mode/pending/pick/echo left anywhere for two heads to collide on. Each
//! head owns its own `Head` value; `command.Context.head` is the single door
//! core code uses to reach any of it.
//!
//! THE SPLIT (see Keymap.zig's module doc for the full rationale): Keymap
//! owns the TABLES — mode→key→command bindings, fallback chains, menu/
//! locked/resting/sticky declarations — system-scoped, shared by every head
//! looking at this system. Head owns the CURSOR into those tables: which mode
//! this head is in, its half-typed chord, its menu return-target stack, and
//! its which-key render scratch. Every Keymap method that used to read/write
//! `self.mode`/`self.pending` now takes the mode explicitly and is a pure
//! function of (tables, mode-string, key) — see Keymap.zig. Head's methods
//! below are the mutating half: they hold the position and call into
//! Keymap's pure lookups to move it.
//!
//! Also first-class here: the Pick machine (a head's live picker — two heads
//! must be able to have two different pickers open at once) and the echo
//! line (a head's transient status-line message — moved from
//! `src/app/session.zig`, which used to own it directly; the session now
//! just holds a `Head`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const semantic = @import("weft_semantic");
const view_runtime = @import("weft_view_runtime");

const Keymap = @import("Keymap.zig");
const Pick = @import("pick/Pick.zig");
const Buffers = @import("Buffers.zig");

const Head = @This();

// ── The keymap CURSOR ──────────────────────────────────────────────────
// Owned copies; freed in `deinit`. See Keymap.zig for the table half.

/// This head's current mode. Never empty once any `setModeRaw`/
/// `enterModeRaw` (or, on the dispatch path, `Ctx.setMode`/`Ctx.enterMode`)
/// has run; `.empty`'s value is "" (no mode set yet — the modeless floor).
mode: []u8 = &.{},
/// This head's pending key SEQUENCE (see Keymap.zig's `pending` doc — same
/// meaning, just relocated: it is cursor state, not a table).
pending: []u8 = &.{},
/// menu mode → the mode THIS HEAD returns to when a one-shot menu key fires.
/// Per-head because two heads can have the SAME menu mode open from
/// DIFFERENT origins (head A entered "leader" from "normal", head B from
/// "insert" — a shared table would clobber one head's return target with
/// the other's). Recorded only by `enterModeRaw` (reached from
/// `Ctx.enterMode`, guest-initiated); host-side save/restore (the picker)
/// uses plain `setModeRaw` and never touches this.
menu_return: std.StringArrayHashMapUnmanaged([]u8) = .empty,
/// Scratch for `resolveBindings`/`completions` (which-key rendering) —
/// per-head so two heads rendering which-key in the same tick never
/// stomp each other's result. Borrowed slices into the Keymap's tables,
/// valid until the next keymap mutation.
resolved: std.ArrayList(Keymap.Binding) = .empty,
resolved_group: std.ArrayList(bool) = .empty,

// ── This head's live interaction sessions ──────────────────────────────

/// This head's pick session (prompt/query/filtered/acceptor/…) — a second
/// head has its own, entirely independent picker.
pick: Pick = .empty,
/// This head's transient status-line message.
echo: Echo = .{},
/// The selection of the scene this head shows (doc/model.md §2.6): the
/// focused row — a stable view/node/field path, never a text cursor — is its
/// PRIMARY extent; rows marked beside it are its others. One model with the
/// text selections an `Editor` holds (`selection.zig`), which dispatch maps
/// commands over the same way.
scene_selection: SceneSelection = .empty,
/// Type-ahead over the focused scene's rows: the prefix being typed
/// (`type_ahead.zig`, doc/chrome.md §5.2).
type_ahead: @import("type_ahead.zig").State = .{},
/// Dialogs, pickers, and popups are nested semantic interactions local to
/// this head. Their bindings are resolved here before any global keymap help.
interactions: view_runtime.interaction.Stack = .empty,
/// Exact semantic container used to resolve relative effects for this head.
/// This is deliberately not process-global cwd state. Only the target handle
/// and descriptor revision are retained, so no provider-owned path/location
/// bytes escape an action callback.
working_target: ?WorkingTarget = null,
/// This head's dot-repeat recorder (`.` replays the last change) — see
/// `DotRepeat`'s doc below. Per-head for the same reason as `pick`/`echo`:
/// two heads pressing keys concurrently must not interleave into one
/// register.
dot: DotRepeat = .empty,
/// This head's jumplist (`jumplist.zig`): where it has been, anchored so the
/// positions survive edits. Per-head like `dot` — another head's search must
/// never become this head's C-o.
jumps: @import("jumplist.zig").JumpList = .empty,
/// This head's macro registers and recorder (`Macros` below). Per-head for
/// the same reason `dot` is: a macro is a recording of one head's keys.
macros: Macros = .empty,
/// This head's view of the system clipboard (`clipboard.zig`). Per-head
/// because a head is a platform attachment, and the clipboard is the
/// platform's: two heads on two machines copy into two desktops.
clipboard: @import("clipboard.zig") = .empty,
/// This head's window-layout FOCUS — a generation-checked HANDLE into a
/// shared `window_layout.Layout`'s pane slot table, NOT a raw pointer.
/// `pane` indexes the layout's slot table; `gen` is that slot's generation
/// as of this handle's last validation. Plain data (two `u32`s) — `Head` is
/// core and must not depend on `gfx/window_layout.zig`, but a pair of
/// integers needs no type erasure to avoid that (no `anyopaque`, unlike an
/// earlier version of this field). The LAYOUT (the split tree) is
/// session-scoped, shared by every head looking at it, and its structural
/// ops (split/close) can free or relocate a node a DIFFERENT head is
/// pointing at — a raw pointer would go stale silently and dereferencing it
/// is undefined behavior; a handle can be VALIDATED instead. `0`/`0` is not
/// a special "unset" sentinel: it validates through the exact same check as
/// any other handle (and correctly falls through to recovery if slot 0's
/// generation has since moved on). See `window_layout.zig`'s module doc and
/// its `headFocus`/`setHeadFocus` — the only functions that interpret these
/// two numbers, and the only place a stale handle is detected and recovered.
focused_pane: u32 = 0,
focused_pane_gen: u32 = 0,

/// The byte range this head's focused pane showed in its last built frame,
/// and the entry it showed it for (`wl_view_range`). Written by the frame
/// build — only the layout knows what is visible after scrolling and folds —
/// and read by a guest that must act on what the user can SEE (a jump label,
/// a visible-range search). Null before the first frame and while the pane
/// holds no text. A reader checks `entry` against the entry it is asking
/// about; offsets are clamped to that entry's length, since an edit can
/// land between the frame and the read.
view_range: ?ViewRange = null,

/// How many keys this head has dispatched, the one being dispatched included
/// (`wl_key_serial`). Bumped once per key at the top of dispatch — a pointer
/// gesture is a key here too; a bare modifier is not. What a guest compares
/// to ask "is this the very next key after mine?" — Emacs's transient map,
/// without core holding a keymap that knows it is one.
key_serial: u32 = 0,

/// What the last undo step this head began ran, as `step.zig` identifies it
/// (mode and command) — how a `run` mode knows the next keystroke continues
/// the same run. Zero before the first.
step_last: u64 = 0,

/// This head's pointer facts: the gesture being dispatched and what is under
/// the pointer (`pointer.zig`). Per-head because the pointer is: another
/// head's click must never move this head's drag origin.
pointer: @import("pointer.zig").Gesture = .{},

/// The placement HINT the open in flight carries (§9.4), consumed by the
/// next layout phase. Per-head for the same reason `focused_pane` is: two
/// heads activating a row at once must not read each other's intent. It is
/// deliberately a REQUEST, not a pane — an opener states what it wants
/// ("the primary pane"), the policy decides which pane that is, and the
/// layout is the only thing that moves anything. `null` between opens; an
/// open the shell declines clears it rather than leaving it to fire against
/// whatever happens next.
placement: ?@import("placement.zig").Request = null,

/// This head's transient/menu stack — the DURABLE record `Ctx.
/// pushTransient`/`TransientHandle.deinit` push and pop. Distinct from
/// `menu_return` above (guest `enterModeRaw` bookkeeping, keyed by mode name,
/// no push/pop discipline): this is an explicit LIFO stack a caller must
/// pop in order, so an out-of-order or missing pop is DETECTABLE
/// (`hasOpenTransients`) rather than silently corrupting which mode a
/// later pop lands on. See `ctx.zig`'s module doc ("Paired transients") and
/// `TransientFrame`'s doc below.
transient_stack: std.ArrayList(TransientFrame) = .empty,

/// This head's catalog context clock (`catalog.Context`'s caller-owned
/// half — see that struct's doc). `key` names the focused entry/viewport a
/// snapshot is cached under; `revision` is the clock a rebuild keys on.
catalog_clock: CatalogClock = .{},

/// Where this head's PRIMARY focus last was: the last pane it focused whose
/// viewport is a `focus_source` (a text pane, never a docked companion), and
/// the entry that pane showed. Recorded by the layout phase, and the ONLY
/// input the primary context (`context.zig`) reads focus from — so a companion
/// viewport taking focus moves nothing any follower can observe. A toolbar or
/// sidebar that takes focus leaves this on the editor, so the offers it
/// enumerates (`intent.Where.primary`) still describe the editor rather than
/// itself. Null until the first layout phase; offer readers fall back to the
/// active entry, and the primary context is empty.
primary_focus: ?PrimaryFocus = null,
/// The catalog clock for the primary context when it is NOT the active one —
/// its own cache key, so describing the editor from a sidebar never evicts
/// the snapshot the next keypress in the sidebar reads.
primary_clock: CatalogClock = .{},

pub const PrimaryFocus = struct {
    /// A `window_layout` pane slot id, plain data for the reason
    /// `focused_pane` is.
    pane: u32,
    /// The `Buffers.Id` that pane shows. A raw slot, not a `Buffers.Ref` or
    /// a designation, and knowingly so: it is not state that outlives the
    /// entry — the layout phase re-reads it from the pane every frame
    /// (`window_cmds`), and the pane itself holds the same raw id — so a
    /// closed entry's reused slot is corrected within the frame that reuses
    /// it. It becomes a `Ref` when panes hold refs.
    entry: u32,
};

pub const empty: Head = .{};

/// The caller-owned half of `catalog.Context`, DERIVED rather than pushed:
/// `observe` folds this head's focus/scene inputs into one signature and
/// bumps `revision` when it moves. Deriving it at the one place resolution
/// happens is why no focus or scene chokepoint can be missed — there is no
/// second site that must remember to bump.
///
/// `key` mixes a process-unique head id with the focused entry, so two heads
/// on one system never share a cached snapshot and a freed head's cache
/// entry can never be inherited by a later head at the same address.
pub const CatalogClock = struct {
    key: u64 = 0,
    revision: u64 = 0,
    signature: u64 = 0,
    id: u64 = 0,

    var next_id: std.atomic.Value(u64) = .init(1);

    pub fn observe(self: *CatalogClock, entry: u64, signature: u64) void {
        if (self.id == 0) self.id = next_id.fetchAdd(1, .monotonic);
        const key = std.hash.Wyhash.hash(self.id, std.mem.asBytes(&entry));
        if (self.revision != 0 and self.key == key and self.signature == signature) return;
        self.key = key;
        self.signature = signature;
        self.revision += 1;
    }
};

/// See `Head.view_range`.
pub const ViewRange = struct {
    entry: Buffers.Ref,
    start: usize,
    end: usize,
};

pub const WorkingTarget = struct {
    target: semantic.target.Ref,
    revision: u64,

    pub fn located(self: WorkingTarget) semantic.target.Located {
        return .{ .target = self.target, .revision = self.revision };
    }
};

/// A scene's selection (doc/model.md §2.6): extents of rows in one view. The
/// PRIMARY extent is the focus — the path to the focused row (and field) —
/// grown from `anchor` when a row range is being made (`selection.start` then a
/// move: `V j` in a listing). The `others` are rows marked beside it (a
/// C-click): each its own extent, from its anchor row to its head row in
/// the view's focus order. The text twin is `Editor.selections`; both
/// answer `selection.Extent`s, and dispatch maps a command over either.
pub const SceneSelection = struct {
    view: ?semantic.view.Ref = null,
    nodes: std.ArrayList(semantic.scene.NodeId) = .empty,
    /// The field being EDITED — a text extent inside the focused row
    /// (doc/chrome.md §5.2) — and the text it held when the edit began,
    /// which cancelling restores. Null while the focus is the row itself: a
    /// row whose leaf happens to be a field is not a field being edited, so
    /// the `field` posture, the field caret and field input all read this,
    /// never the shape of the focus path. ONE value, so no field is edited
    /// without its origin, and an edit ends in one assignment that nothing
    /// fallible precedes (`scene_edit.commit`/`cancel`). Whether the edit is
    /// a BEGUN one — taking printable input itself, committing when the
    /// focus leaves its row — is the head's granularity
    /// (`scene_edit.begun`); under `text` the grammar's modes drive it.
    /// Where the focus LANDS decides it (`scene_edit.land`).
    edit: ?Edit = null,
    /// Where `Edit.origin` lives, kept between edits. Read only through
    /// `edit`.
    origin_storage: std.ArrayList(u8) = .empty,
    /// A one-shot row anchor used when an action temporarily focuses a
    /// secondary, non-focusable node in this same view. It is head-local so
    /// another head can navigate the same view independently.
    navigation_anchor: ?semantic.scene.NodeId = null,
    /// Extend focused-field movements from the selection anchor.
    selection_mark: bool = false,
    /// Where the primary extent's row range starts, while one is being made;
    /// null is the one focused row.
    anchor: ?semantic.scene.NodeId = null,
    /// The other extents, in no particular order (the view's focus order
    /// sorts them when they are read). Always in `view`.
    others: std.ArrayList(Rows) = .empty,

    /// One extent of rows: from `anchor` to `head`, both focusable nodes.
    pub const Rows = struct { anchor: semantic.scene.NodeId, head: semantic.scene.NodeId };

    pub const empty: SceneSelection = .{};

    /// One edit: the field and the text it began from.
    pub const Edit = struct {
        field: semantic.scene.FieldRef,
        /// The field's text when the edit began — what cancelling restores.
        /// Borrowed from `origin_storage`, valid until the next edit starts.
        origin: []const u8,
    };

    pub fn deinit(self: *SceneSelection, gpa: Allocator) void {
        self.nodes.deinit(gpa);
        self.others.deinit(gpa);
        self.origin_storage.deinit(gpa);
        self.* = .{};
    }

    /// Start editing `field`, which held `origin` as the edit began. Any
    /// edit before it is over first, so a failed start leaves none.
    pub fn startEdit(self: *SceneSelection, gpa: Allocator, field: semantic.scene.FieldRef, origin: []const u8) Allocator.Error!void {
        self.edit = null;
        self.origin_storage.clearRetainingCapacity();
        try self.origin_storage.appendSlice(gpa, origin);
        self.edit = .{ .field = field, .origin = self.origin_storage.items };
    }

    /// Focus `next`. Within the same view the extents stay — a move grows a
    /// range from its anchor, and marked rows stay marked; in another view
    /// they mean nothing, and go.
    pub fn set(self: *SceneSelection, gpa: Allocator, next: semantic.focus.Path) Allocator.Error!void {
        try self.nodes.ensureTotalCapacity(gpa, next.nodes.len);
        const same_view = if (self.view) |v| v.eql(next.view) else false;
        self.nodes.clearRetainingCapacity();
        self.nodes.appendSliceAssumeCapacity(next.nodes);
        self.view = next.view;
        // An edit belongs to its field: a path naming another (or none) ends
        // it. A path naming a new field starts nothing — an edit needs its
        // origin, which `startEdit` is handed (`scene_edit.land`).
        if (self.edit) |edit| if (!sameField(edit.field, next.field)) {
            self.edit = null;
        };
        self.navigation_anchor = null;
        self.selection_mark = false;
        if (!same_view) self.collapse();
    }

    pub fn clear(self: *SceneSelection) void {
        self.view = null;
        self.nodes.clearRetainingCapacity();
        self.edit = null;
        self.navigation_anchor = null;
        self.selection_mark = false;
        self.collapse();
    }

    /// Back to the one focused row: no range, no marks.
    pub fn collapse(self: *SceneSelection) void {
        self.anchor = null;
        self.others.clearRetainingCapacity();
    }

    /// The focused row — the primary extent's head.
    pub fn head(self: *const SceneSelection) ?semantic.scene.NodeId {
        return if (self.nodes.items.len == 0) null else self.nodes.items[self.nodes.items.len - 1];
    }

    /// How many extents: the focus, and every marked extent beside it.
    pub fn extentCount(self: *const SceneSelection) usize {
        if (self.view == null) return 0;
        return 1 + self.others.items.len;
    }

    /// The primary extent, as rows.
    pub fn primaryRows(self: *const SceneSelection) ?Rows {
        const h = self.head() orelse return null;
        return .{ .anchor = self.anchor orelse h, .head = h };
    }

    /// Replace this focus with an owned copy of another head/buffer focus.
    /// Buffer switches use this to save and restore semantic tools with the
    /// same lifetime rules as cursor/mode state; the scene itself remains in
    /// the semantic view registry.
    pub fn copyFrom(self: *SceneSelection, gpa: Allocator, other: *const SceneSelection) Allocator.Error!void {
        try self.nodes.ensureTotalCapacity(gpa, other.nodes.items.len);
        try self.others.ensureTotalCapacity(gpa, other.others.items.len);
        self.nodes.clearRetainingCapacity();
        self.nodes.appendSliceAssumeCapacity(other.nodes.items);
        self.others.clearRetainingCapacity();
        self.others.appendSliceAssumeCapacity(other.others.items);
        self.view = other.view;
        if (other.edit) |edit| try self.startEdit(gpa, edit.field, edit.origin) else {
            self.edit = null;
        }
        self.navigation_anchor = other.navigation_anchor;
        self.selection_mark = other.selection_mark;
        self.anchor = other.anchor;
    }

    fn sameField(a: ?semantic.scene.FieldRef, b: ?semantic.scene.FieldRef) bool {
        const x = a orelse return b == null;
        const y = b orelse return false;
        return x.eql(y);
    }

    pub fn setNavigationAnchor(self: *SceneSelection, anchor: ?semantic.scene.NodeId) void {
        self.navigation_anchor = anchor;
    }

    pub fn path(self: *const SceneSelection) ?semantic.focus.Path {
        return .{
            .view = self.view orelse return null,
            .nodes = self.nodes.items,
            .field = if (self.edit) |edit| edit.field else null,
        };
    }
};

/// One live "paired transient" push (`ctx.zig`'s `Ctx.pushTransient`) —
/// doc/cwa-prior-docs-audit.md §5's "transient/menu modes are structurally paired
/// (`ctx.push(transient)` returns a value whose going-out-of-scope IS the
/// pop)". `mode` is what this frame entered; `return_to` is the mode to
/// restore on pop, captured at push time (so nested pushes each remember
/// their OWN prior mode, not a shared global "previous").
pub const TransientFrame = struct {
    mode: []u8,
    return_to: []u8,
};

/// One recorded keystroke of a dot-repeat change: the keyspec plus the
/// printable text it inserted (fixed-size — a dot-repeat change is a few
/// keys, not a novel). Storage only; see `dispatch.zig`'s dot-repeat section
/// (`dotRecord`/`dotBoundary`/`replayDot`) for what fills and drains it —
/// that logic needs `command.Context` (buffers/editor/keymap), which `Head`
/// must not depend on (it would invert the core/app dependency), so it stays
/// app-side and reaches in through this struct's public fields, exactly like
/// `Keymap`'s pure functions reach into `Head.mode`/`Head.pending`.
pub const KeyPress = struct {
    spec: [24]u8 = undefined,
    slen: u8 = 0,
    text: [8]u8 = undefined,
    tlen: u8 = 0,
};

/// A change longer than this stops recording (degrade, don't clip mid-replay).
pub const dot_cap = 256;

/// This head's dot-repeat register: the keys of the in-progress sequence
/// (`pending`) and the last completed CHANGE (`reg`), plus the bookkeeping
/// `dotBoundary` needs to tell a change from a motion from a prefix (commit
/// count / cursor offset / active buffer at the last rest point). No
/// allocations — fixed arrays — so `Head.deinit`'s `self.* = .{}` resets it
/// for free; nothing here needs its own `deinit`.
pub const DotRepeat = struct {
    pending: [dot_cap]KeyPress = undefined,
    pending_n: usize = 0,
    reg: [dot_cap]KeyPress = undefined,
    reg_n: usize = 0,
    /// True while `replayDot` is re-feeding the register — suppresses
    /// re-recording during a replay (the replayed keys must not overwrite
    /// the register they came from).
    replaying: bool = false,
    /// True for one dispatch after a replay: the repeat key itself (`.`)
    /// must not become the new recorded change.
    suppress: bool = false,
    /// Buffer commit count at the last rest point.
    commits: usize = 0,
    /// Cursor offset at the last rest point (tells a motion from a prefix).
    cursor: usize = 0,
    /// Active buffer id at the last rest point — a buffer switch resets the
    /// recorder (commit counts across buffers aren't comparable).
    buf: Buffers.Id = 0,
    /// Whether `commits`/`cursor`/`buf` have ever been synced to a real
    /// buffer. A brand-new head's first dispatch must always reset-and-sync
    /// (exactly like a buffer switch) rather than compare against these
    /// zero defaults — without this, a head that ATTACHES to a system after
    /// buffer 0 already has edits (buffer ids start at 0 — `Buffers.init`'s
    /// doc) would see `buf == 0` "match" its own unsynced default and
    /// misread the gap since its creation as one giant in-progress change.
    /// Two-head gate gap (doc/contextual-workspace-architecture.md §7): the original
    /// single-head design never needed this because the one head always
    /// existed before the first edit.
    synced: bool = false,

    pub const empty: DotRepeat = .{};
};

/// This head's keyboard macros: named registers of recorded keystrokes, the
/// recorder filling one, and the guard against a macro replaying itself.
/// Storage only, like `DotRepeat` — recording and replay go through the one
/// dispatch path (`app/dispatch.zig`'s macro section), which needs the
/// `command.Context` this struct must not depend on.
///
/// A register is named by one printable ASCII byte. Which names a grammar
/// offers (vim's `a`–`z`, helix's `@`) is the grammar's business.
pub const Macros = struct {
    pub const register_count = 128;

    /// The register being recorded into, or null.
    recording: ?u8 = null,
    /// The keys recorded so far; `stop` moves them into `regs[recording]`.
    rec: std.ArrayList(KeyPress) = .empty,
    /// `rec`'s length when the last dispatch began at rest (no pending chord).
    /// `stop` cuts back to it, so the key sequence that STOPPED the recording
    /// (vim's closing `q`, or a whole `SPC m q` chord) is not part of the
    /// macro it closes.
    rest_mark: usize = 0,
    /// How many key dispatches are on the stack. `stop` cuts back to
    /// `rest_mark` only inside one — a stop run from outside any keystroke
    /// (a script, a test) has no key of its own to drop.
    key_depth: u32 = 0,
    regs: [register_count]std.ArrayList(KeyPress) = @splat(.empty),
    /// Registers being replayed right now. Replay re-enters dispatch, so a
    /// macro can reach its own `@a` again; a register already in this set
    /// refuses to play, which bounds even mutual recursion (`a` plays `b`
    /// plays `a`) by the register count.
    playing: std.StaticBitSet(register_count) = .initEmpty(),
    /// Nonzero while any replay is running — replayed keys are not recorded
    /// into a macro being recorded (vim records the `@a`, not what it did).
    depth: u8 = 0,
    /// What `macro.play` with no register replays (vim's `@@`).
    last_played: ?u8 = null,
    last_recorded: ?u8 = null,

    pub const empty: Macros = .{};

    pub fn register(self: *Macros, name: u8) ?*std.ArrayList(KeyPress) {
        if (name < 0x21 or name >= register_count) return null; // printable, no space
        return &self.regs[name];
    }

    pub fn deinit(self: *Macros, gpa: Allocator) void {
        self.rec.deinit(gpa);
        for (&self.regs) |*r| r.deinit(gpa);
        self.* = .{};
    }
};

pub fn deinit(self: *Head, gpa: Allocator) void {
    gpa.free(self.mode);
    gpa.free(self.pending);
    for (self.menu_return.keys(), self.menu_return.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    self.menu_return.deinit(gpa);
    self.resolved.deinit(gpa);
    self.resolved_group.deinit(gpa);
    self.pick.deinit(gpa);
    self.echo.deinit(gpa);
    self.scene_selection.deinit(gpa);
    self.interactions.deinit(gpa);
    for (self.transient_stack.items) |frame| {
        gpa.free(frame.mode);
        gpa.free(frame.return_to);
    }
    self.transient_stack.deinit(gpa);
    self.jumps.deinit(gpa);
    self.macros.deinit(gpa);
    self.clipboard.deinit(gpa);
    self.* = .{};
}

/// A head's one-line message. There is one way to write it: `say`, which
/// replaces what it says and counts the saying, so a reader tells a message
/// said again from one still standing — the frame shows a message for
/// `editor/echo-ms` from its saying, and a second "no hover" is a second
/// saying though its text is the first's. There is no append: a message is
/// composed first and said whole, so no writer can change the text without
/// the count. `text` and `sayings` are the reads; `private` is theirs alone.
pub const Echo = struct {
    private: struct {
        text: std.ArrayList(u8) = .empty,
        said: u64 = 0,
    } = .{},

    /// Say `msg` (empty says nothing, and still counts): the line becomes it.
    pub fn say(self: *Echo, gpa: Allocator, msg: []const u8) Allocator.Error!void {
        self.private.said +%= 1;
        self.private.text.clearRetainingCapacity();
        try self.private.text.appendSlice(gpa, msg);
    }

    /// What it says now. Borrowed until the next `say`.
    pub fn text(self: *const Echo) []const u8 {
        return self.private.text.items;
    }

    /// Sayings so far.
    pub fn sayings(self: *const Echo) u64 {
        return self.private.said;
    }

    pub fn deinit(self: *Echo, gpa: Allocator) void {
        self.private.text.deinit(gpa);
        self.* = .{};
    }
};

/// Set the pending sequence (owned copy); "" clears it (no allocation).
pub fn setPending(self: *Head, gpa: Allocator, seq: []const u8) Allocator.Error!void {
    if (seq.len == 0) {
        gpa.free(self.pending);
        self.pending = &.{};
        return;
    }
    const owned = try gpa.dupe(u8, seq);
    gpa.free(self.pending);
    self.pending = owned;
}

/// Drop the last keyspec of the pending chord (Backspace mid-sequence).
pub fn popPending(self: *Head, gpa: Allocator) Allocator.Error!void {
    if (self.pending.len == 0) return;
    const cut = std.mem.lastIndexOfScalar(u8, self.pending, ' ') orelse {
        try self.setPending(gpa, "");
        return;
    };
    try self.setPending(gpa, self.pending[0..cut]);
}

pub fn currentMode(self: *const Head) []const u8 {
    return self.mode;
}

/// **MECHANISM, not policy (task #19 item 3 — doc/cwa-prior-docs-audit.md §5
/// "Mode changes — REVISED").** Host-side (or generic) mode set: no
/// menu-return bookkeeping. Abandons any half-typed chord (a stale
/// `space f` must not combine with the new mode's next key). Used for
/// buffer.switch restore and host-side save/restore (the picker), neither
/// of which should poison a menu's return target — and, RAW, by
/// `Ctx.setMode` itself, the ONE place a `*command.Context`-holding caller
/// should reach this from. Named `setModeRaw` (not plain `setMode`)
/// PRECISELY so a stray `head.setMode(...)` in new dispatch-path code fails
/// to COMPILE instead of silently bypassing the door — see `ctx.zig`'s
/// module doc for the door itself and which call sites legitimately stay
/// on this raw entry (`Buffers.switchTo`, `System.attachHead`/
/// `detachHead`, `Pick`'s own save/restore, install-time bootstrap, and
/// tests that exercise `Head` directly with no `command.Context` in scope).
pub fn setModeRaw(self: *Head, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const owned = try gpa.dupe(u8, mode);
    self.setModeRawOwned(gpa, owned);
}

/// The commit half of `setModeRaw`: consume a caller-owned mode string and
/// replace the current mode without allocating. A state machine which must
/// prepare a transition transactionally (the picker close path) duplicates
/// its destination first, then uses this after its own fallible work is done.
/// This remains RAW mechanism with the same narrow call-site rules as
/// `setModeRaw`; ordinary dispatch code goes through `Ctx.setMode`.
pub fn setModeRawOwned(self: *Head, gpa: Allocator, owned_mode: []u8) void {
    gpa.free(self.mode);
    self.mode = owned_mode;
    gpa.free(self.pending);
    self.pending = &.{};
}

/// **MECHANISM, not policy** — see `setModeRaw`'s doc; same naming
/// rationale (`enterModeRaw`, not plain `enterMode`, so `Ctx.enterMode` is
/// the only spelling that compiles from ordinary dispatch-path code).
/// Guest-initiated mode set. Identical to `setModeRaw`, except that
/// entering a *menu* mode (per `km`'s tables) records THIS HEAD's return
/// target — the root non-menu mode it came from — so a one-shot menu key
/// can pop back (see `menuReturn`). Only guests route through here (via
/// `Ctx.enterMode`); host-side mode save/restore uses plain `setModeRaw`,
/// so a restore-into-a-menu never records a bogus return target.
pub fn enterModeRaw(self: *Head, gpa: Allocator, km: *const Keymap, mode: []const u8) Allocator.Error!void {
    if (km.modeHasTag(mode, "menu") and !std.mem.eql(u8, self.mode, mode)) {
        // If we came from another menu, inherit *its* return target so a chain
        // of menus collapses to a single hop back to the root non-menu mode;
        // otherwise return to exactly where we were.
        const root = self.menuReturn(self.mode) orelse self.mode;
        const owned_root = try gpa.dupe(u8, root); // dupe before setModeRaw frees self.mode
        errdefer gpa.free(owned_root);
        const gop = try self.menu_return.getOrPut(gpa, mode);
        if (gop.found_existing) {
            gpa.free(gop.value_ptr.*);
        } else {
            errdefer _ = self.menu_return.swapRemove(mode);
            gop.key_ptr.* = try gpa.dupe(u8, mode);
        }
        gop.value_ptr.* = owned_root;
    }
    try self.setModeRaw(gpa, mode);
}

/// The mode THIS HEAD should pop `mode` back to (the root non-menu mode it
/// entered `mode` from), or null if `mode` isn't a menu this head has a
/// recorded return target for.
pub fn menuReturn(self: *const Head, mode: []const u8) ?[]const u8 {
    return self.menu_return.get(mode);
}

/// Push a paired transient scope: remember the CURRENT mode as this frame's
/// return target, enter `mode` (via `enterModeRaw`, so menu-return bookkeeping
/// still applies), and return the new frame's stack depth — the token
/// `popTransientMode` verifies before restoring. See `ctx.zig`'s
/// `Ctx.pushTransient` (the intended caller) and this struct's
/// `transient_stack` doc.
/// A real, enforced cap on simultaneously open transients (review F2: the
/// capacity limit belongs HERE, at push time — "a real limit surfaced at
/// push time, not capture time" — not as a silent drop deep inside
/// `ctx.zig`'s scope-capture bookkeeping). `ctx.zig`'s `max_scopes` budgets
/// exactly `max_open_transients` transient slots on top of the 6 fixed
/// scopes, so a `Ctx.capture` can never overflow from a LEGITIMATELY
/// pushed transient stack — see that module's `ScopeList.append` doc for
/// the belt-and-suspenders behavior if this invariant is ever broken by a
/// future change instead.
pub const max_open_transients: usize = 6;
pub const TransientPushError = error{TooManyOpenTransients};

pub fn pushTransientMode(self: *Head, gpa: Allocator, km: *const Keymap, mode: []const u8) (Allocator.Error || TransientPushError)!usize {
    if (self.transient_stack.items.len >= max_open_transients) {
        std.log.warn("head: refusing to open a {d}th nested transient/menu ('{s}') — pop one first", .{ self.transient_stack.items.len + 1, mode });
        return error.TooManyOpenTransients;
    }
    const ret = try gpa.dupe(u8, self.mode);
    errdefer gpa.free(ret);
    const held = try gpa.dupe(u8, mode);
    errdefer gpa.free(held);
    try self.transient_stack.append(gpa, .{ .mode = held, .return_to = ret });
    errdefer _ = self.transient_stack.pop();
    try self.enterModeRaw(gpa, km, mode);
    return self.transient_stack.items.len - 1;
}

/// Pop a transient pushed by `pushTransientMode`, restoring its recorded
/// return mode — but ONLY if `depth` names the current TOP of the stack
/// (LIFO). A stale or out-of-order `depth` (something else was pushed on
/// top and never popped) is refused with `error.OutOfOrder` rather than
/// restoring the wrong frame's target; an empty stack (already popped, or
/// never pushed) is `error.Empty`. Both are non-fatal for the caller to
/// log-and-continue (`TransientHandle.deinit` does exactly that) — the
/// POINT is that the mode never silently lands somewhere the pusher didn't
/// intend.
pub const TransientPopError = error{ OutOfOrder, Empty };
pub fn popTransientMode(self: *Head, gpa: Allocator, depth: usize) (Allocator.Error || TransientPopError)!void {
    if (self.transient_stack.items.len == 0) return error.Empty;
    if (depth != self.transient_stack.items.len - 1) return error.OutOfOrder;
    const frame = self.transient_stack.pop().?;
    defer {
        gpa.free(frame.mode);
        gpa.free(frame.return_to);
    }
    try self.setModeRaw(gpa, frame.return_to);
}

/// Whether this head has a transient pushed but never popped — the
/// leak-detecting query doc/contextual-workspace-architecture.md §7 gate (d) asks for ("a
/// transient/menu push cannot outlive its scope ... else runtime-paired
/// with a leak-detecting test").
pub fn hasOpenTransients(self: *const Head) bool {
    return self.transient_stack.items.len != 0;
}

/// Pop the transient at `depth` LIKE `popTransientMode` (same LIFO check,
/// same errors), but WITHOUT restoring its recorded `return_to` — for a
/// caller that already knows `self.mode` was changed some OTHER way (task
/// #19 item 2: a leaf command's own guest `weft.setMode`, mid-menu, that
/// exits somewhere other than the recorded return target) and a restore
/// here would stomp that deliberate choice. The frame still has to come off
/// the stack — leaving it would be exactly the silent leak this whole
/// mechanism exists to make loud instead of (`ctx.zig`'s "Paired
/// transients"): its memory is freed and `hasOpenTransients` stops
/// reporting it, just without touching `self.mode`.
pub fn popTransientDiscard(self: *Head, gpa: Allocator, depth: usize) TransientPopError!void {
    if (self.transient_stack.items.len == 0) return error.Empty;
    if (depth != self.transient_stack.items.len - 1) return error.OutOfOrder;
    const frame = self.transient_stack.pop().?;
    gpa.free(frame.mode);
    gpa.free(frame.return_to);
}

/// Discard EVERY open transient without restoring anything — for a caller
/// about to overwrite `self.mode` wholesale through a path that has never
/// gone through `pushTransientMode`/`popTransientMode` (`Buffers.switchTo`'s
/// resting-mode restore, `Pick.openWith`'s save/restore — both bypass the
/// keymap dispatch site entirely, same as they did before transients
/// existed). Whatever `self.mode` becomes right after this call is the
/// caller's own decision; any transient frame recorded against the mode
/// being left behind is now meaningless (it named a scope in the buffer/
/// interaction the head is LEAVING), so there is nothing honest left to pop
/// it INTO — this is the buffer.switch/pick-open counterpart of
/// `popTransientDiscard`, generalized to "all of them, unconditionally"
/// rather than "the one on top, if it matches." See those callers' doc
/// comments for why a plain overwrite (not a pop) has always been legacy's
/// own behavior here — this just keeps the stack from silently outliving
/// the scope it described.
pub fn dropAllTransients(self: *Head, gpa: Allocator) void {
    for (self.transient_stack.items) |frame| {
        gpa.free(frame.mode);
        gpa.free(frame.return_to);
    }
    self.transient_stack.clearRetainingCapacity();
}

/// The command bound to `key` in this head's current mode (chain-walked),
/// then the `global` layer — see `Keymap.lookup`.
pub fn lookup(self: *const Head, km: *const Keymap, key: []const u8) ?[]const u8 {
    return km.lookup(self.mode, key);
}

/// The command a text commit runs in this head's current mode, or null when
/// the mode does not commit text — see `Keymap.commitCommand`.
pub fn commitCommand(self: *const Head, km: *const Keymap) ?[]const u8 {
    return km.commitCommand(self.mode);
}

/// Feed one keyspec through THIS HEAD's pending sequence — see
/// `Keymap.Feed`/the module doc on chords. Mutates `self.pending`; a `.run`
/// arm list borrows `km` — use it before any rebind.
pub fn feed(self: *Head, gpa: Allocator, km: *const Keymap, key: []const u8) Allocator.Error!Keymap.Feed {
    return self.feedInMode(gpa, km, self.mode, key);
}

pub fn feedInMode(self: *Head, gpa: Allocator, km: *const Keymap, mode: []const u8, key: []const u8) Allocator.Error!Keymap.Feed {
    const at_top = self.pending.len == 0;
    const cand = if (at_top) key else try std.fmt.allocPrint(gpa, "{s} {s}", .{ self.pending, key });
    defer if (!at_top) gpa.free(cand);

    if (km.resolveExactArms(mode, cand)) |arms| {
        try self.setPending(gpa, "");
        return .{ .run = arms };
    }
    if (km.isPrefix(mode, cand)) {
        try self.setPending(gpa, cand);
        return .pending;
    }
    try self.setPending(gpa, "");
    return if (at_top) .unbound else .none;
}

/// Build the RESOLVED set of bindings available in `mode` into this head's
/// `resolved`/`resolved_group` scratch — see `Keymap.resolveBindingsInto`.
pub fn resolveBindings(self: *Head, gpa: Allocator, km: *const Keymap, mode: []const u8) Allocator.Error!usize {
    return km.resolveBindingsInto(gpa, mode, &self.resolved, &self.resolved_group);
}

/// Fill this head's `resolved`/`resolved_group` scratch with the next-key
/// choices after `prefix` in this head's CURRENT mode — see
/// `Keymap.completionsInto`.
pub fn completions(self: *Head, gpa: Allocator, km: *const Keymap, prefix: []const u8) Allocator.Error!usize {
    return self.completionsInMode(gpa, km, self.mode, prefix);
}

pub fn completionsInMode(self: *Head, gpa: Allocator, km: *const Keymap, mode: []const u8, prefix: []const u8) Allocator.Error!usize {
    return km.completionsInto(gpa, mode, prefix, &self.resolved, &self.resolved_group);
}

/// The `i`-th resolved binding from the last `resolveBindings`/`completions`.
pub fn resolvedAt(self: *const Head, i: usize) ?Keymap.Binding {
    if (i >= self.resolved.items.len) return null;
    return self.resolved.items[i];
}

/// Whether the `i`-th resolved entry is a GROUP — see `Keymap.resolveBindingsInto`.
pub fn resolvedIsGroup(self: *const Head, i: usize) bool {
    if (i >= self.resolved_group.items.len) return false;
    return self.resolved_group.items[i];
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "head: every message written to the echo is a saying the frame counts" {
    const gpa = t.allocator;
    var echo: Echo = .{};
    defer echo.deinit(gpa);
    try echo.say(gpa, "saved");
    const first = echo.sayings();
    try echo.say(gpa, "saved");
    try t.expect(echo.sayings() != first);
    try t.expectEqualStrings("saved", echo.text());
    try echo.say(gpa, "");
    try t.expectEqualStrings("", echo.text());
}

test "head: setMode/feed/pending are per-head — Keymap holds only tables" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.bind(gpa, "normal", "i", "enter-insert", Keymap.prio_plugin, "vim");
    try km.bind(gpa, "normal", "space f f", "files.find", Keymap.prio_plugin, "vim");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setModeRaw(gpa, "normal");
    try t.expectEqualStrings("enter-insert", h.lookup(&km, "i").?);

    try t.expect((try h.feed(gpa, &km, "space")) == .pending);
    try t.expectEqualStrings("space", h.pending);
    try t.expect((try h.feed(gpa, &km, "f")) == .pending);
    {
        const r = try h.feed(gpa, &km, "f");
        try t.expect(r == .run);
        try t.expectEqualStrings("files.find", r.run[0]);
    }
    try t.expectEqual(@as(usize, 0), h.pending.len);
}

test "head: prefix sequences — a chord resolves; a menu is a prefix, not a mode" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    // A leader tree as SEQUENCES (no leader-* mode): SPC f f -> files.find, etc.
    try km.bind(gpa, "normal", "space f f", "files.find", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "space g g", "git.status", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "i", "vim.insert", Keymap.prio_config, "vim");
    try km.bind(gpa, "global", "C-w", "window-thing", Keymap.prio_config, "cfg");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setModeRaw(gpa, "normal");

    // A single bound key runs immediately.
    {
        const r = try h.feed(gpa, &km, "i");
        try t.expect(r == .run);
        try t.expectEqualStrings("vim.insert", r.run[0]);
        try t.expectEqual(@as(usize, 0), h.pending.len);
    }
    // SPC is a prefix -> pending; f -> still pending; f -> completes -> run.
    try t.expect((try h.feed(gpa, &km, "space")) == .pending);
    try t.expectEqualStrings("space", h.pending);
    try t.expect((try h.feed(gpa, &km, "f")) == .pending);
    try t.expectEqualStrings("space f", h.pending);
    {
        const r = try h.feed(gpa, &km, "f");
        try t.expect(r == .run);
        try t.expectEqualStrings("files.find", r.run[0]);
        try t.expectEqual(@as(usize, 0), h.pending.len);
    }
    // The "global is too global" fix falls out: SPC then C-w is the CHORD
    // `space C-w` (unbound) — NOT the global C-w. It resets, doesn't fire it.
    try t.expect((try h.feed(gpa, &km, "space")) == .pending);
    try t.expect((try h.feed(gpa, &km, "C-w")) == .none);
    try t.expectEqual(@as(usize, 0), h.pending.len);
    // C-w at the TOP (no pending) still hits global.
    {
        const r = try h.feed(gpa, &km, "C-w");
        try t.expect(r == .run);
        try t.expectEqualStrings("window-thing", r.run[0]);
    }
    // A lone key the grammar does not bind is `unbound` — the caller decides
    // whether it commits text; the keymap never says "insert this".
    try t.expect((try h.feed(gpa, &km, "x")) == .unbound);

    // Backspace pops one chord level.
    try t.expect((try h.feed(gpa, &km, "space")) == .pending);
    try t.expect((try h.feed(gpa, &km, "f")) == .pending);
    try h.popPending(gpa);
    try t.expectEqualStrings("space", h.pending);
}

test "head: completions — chord next-keys, leaf vs group, deduped, global at top" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    // A leader tree as sequences: SPC f {f,r}, SPC g g; a plain top-level key.
    try km.bind(gpa, "normal", "space f f", "files.find", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "space f r", "recent-files", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "space g g", "git.status", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "i", "vim.insert", Keymap.prio_config, "vim");
    try km.bind(gpa, "global", "C-w", "window-thing", Keymap.prio_config, "cfg");
    try km.setGroupName(gpa, "normal", "SPC", "leader", Keymap.prio_config, "cfg");
    try km.setGroupName(gpa, "normal", "SPC f", "files", Keymap.prio_config, "cfg");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setModeRaw(gpa, "normal");

    // Top level (empty prefix): the first segments, deduped. The three `space …`
    // binds collapse to ONE `space` group; `i` is a leaf; global `C-w` shows at
    // the top → {space, i, C-w} = 3.
    try t.expectEqual(@as(usize, 3), try h.completions(gpa, &km, ""));
    // Build a name→(cmd,group) view to assert regardless of order.
    const Found = struct {
        fn get(head: *Head, key: []const u8) ?Keymap.Binding {
            var i: usize = 0;
            while (i < head.resolved.items.len) : (i += 1) {
                if (std.mem.eql(u8, head.resolved.items[i].key, key)) return head.resolved.items[i];
            }
            return null;
        }
        fn group(head: *Head, key: []const u8) bool {
            var i: usize = 0;
            while (i < head.resolved.items.len) : (i += 1) {
                if (std.mem.eql(u8, head.resolved.items[i].key, key)) return head.resolvedIsGroup(i);
            }
            return false;
        }
    };
    _ = try h.completions(gpa, &km, "");
    try t.expect(Found.get(&h, "space") != null);
    try t.expect(Found.group(&h, "space")); // continues a chord → group
    try t.expectEqualStrings("leader", Found.get(&h, "space").?.command);
    try t.expectEqualStrings("vim.insert", Found.get(&h, "i").?.command);
    try t.expect(!Found.group(&h, "i")); // runnable leaf
    try t.expectEqualStrings("window-thing", Found.get(&h, "C-w").?.command); // global at top
    // `space f f` and `space f r` collapse to ONE `space` group at the top.
    var space_count: usize = 0;
    for (h.resolved.items) |b| {
        if (std.mem.eql(u8, b.key, "space")) space_count += 1;
    }
    try t.expectEqual(@as(usize, 1), space_count);

    // After `space`: the file/git submenu keys `f` (group) and `g` (leaf-ish
    // group — `space g g`). Global does NOT appear mid-chord.
    {
        _ = try h.completions(gpa, &km, "space");
        try t.expect(Found.get(&h, "f") != null);
        try t.expect(Found.group(&h, "f")); // space f {f,r} → still a group
        try t.expectEqualStrings("files", Found.get(&h, "f").?.command);
        try t.expect(Found.get(&h, "g") != null);
        try t.expectEqual(@as(?Keymap.Binding, null), Found.get(&h, "C-w")); // no global mid-chord
    }
    // After `space f`: the two leaves `f`→files.find, `r`→recent-files.
    {
        const n = try h.completions(gpa, &km, "space f");
        try t.expectEqual(@as(usize, 2), n);
        try t.expectEqualStrings("files.find", Found.get(&h, "f").?.command);
        try t.expect(!Found.group(&h, "f")); // a leaf now
        try t.expectEqualStrings("recent-files", Found.get(&h, "r").?.command);
    }
}

test "head: menu return targets are per-head, not shared via the table" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.tagMode(gpa, "leader", "menu");

    var a: Head = .empty;
    defer a.deinit(gpa);
    var b: Head = .empty;
    defer b.deinit(gpa);

    try a.setModeRaw(gpa, "normal");
    try a.enterModeRaw(gpa, &km, "leader");
    try t.expectEqualStrings("normal", a.menuReturn("leader").?);

    try b.setModeRaw(gpa, "insert");
    try b.enterModeRaw(gpa, &km, "leader");
    try t.expectEqualStrings("insert", b.menuReturn("leader").?);

    // Each head's return target is untouched by the other's entry — the whole
    // point: a shared `menu_return` table would have let `b`'s entry clobber
    // `a`'s (both keyed by the same mode name "leader").
    try t.expectEqualStrings("normal", a.menuReturn("leader").?);
}

test "head: menu return targets — guest entry records, nesting collapses to root" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.tagMode(gpa, "leader", "menu");
    try km.tagMode(gpa, "leader-file", "menu");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setModeRaw(gpa, "normal");

    // Guest enters leader from normal → return target is normal.
    try h.enterModeRaw(gpa, &km, "leader");
    try t.expectEqualStrings("leader", h.currentMode());
    try t.expectEqualStrings("normal", h.menuReturn("leader").?);

    // Nested: enter leader-file from leader → collapses to the root (normal),
    // not one hop back to leader.
    try h.enterModeRaw(gpa, &km, "leader-file");
    try t.expectEqualStrings("normal", h.menuReturn("leader-file").?);

    // A non-menu mode has no return target.
    try t.expectEqual(@as(?[]const u8, null), h.menuReturn("normal"));
}

test "head: host-side setMode restore does NOT poison menu return targets" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.tagMode(gpa, "leader", "menu");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setModeRaw(gpa, "normal");
    try h.enterModeRaw(gpa, &km, "leader"); // return target: normal

    // The picker saves prev="leader", sets "pick" (plain setMode, not a menu),
    // then on close restores "leader" via plain setMode. That restore must not
    // rewrite leader's return target to "pick".
    try h.setModeRaw(gpa, "pick");
    try h.setModeRaw(gpa, "leader");
    try t.expectEqualStrings("normal", h.menuReturn("leader").?);
}

test "head: two heads over one system hold independent mode, chord, pick, and echo" {
    const gpa = t.allocator;
    // ONE shared system-scoped Keymap (tables) — as two heads attached to the
    // same system would share.
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.bind(gpa, "normal", "i", "enter-insert", Keymap.prio_plugin, "vim");
    try km.bind(gpa, "normal", "space f f", "files.find", Keymap.prio_plugin, "vim");
    try km.tagMode(gpa, "leader", "menu");

    var head_a: Head = .empty;
    defer head_a.deinit(gpa);
    var head_b: Head = .empty;
    defer head_b.deinit(gpa);

    // Distinct current modes.
    try head_a.setModeRaw(gpa, "normal");
    try head_b.setModeRaw(gpa, "insert");
    try t.expectEqualStrings("normal", head_a.currentMode());
    try t.expectEqualStrings("insert", head_b.currentMode());

    // Distinct pending chords: A is mid-chord, B is untouched.
    try t.expect((try head_a.feed(gpa, &km, "space")) == .pending);
    try t.expect((try head_a.feed(gpa, &km, "f")) == .pending);
    try t.expectEqualStrings("space f", head_a.pending);
    try t.expectEqual(@as(usize, 0), head_b.pending.len);

    // Distinct pick sessions: opening one doesn't touch the other.
    const Sink = struct {
        fn accept(_: *@import("command.zig").Context, _: ?*anyopaque, _: @import("pick.zig").Outcome) anyerror!void {}
    };
    var ctx_a = try TestCtx.init(gpa, &head_a, &km);
    defer ctx_a.deinit();
    var ctx_b = try TestCtx.init(gpa, &head_b, &km);
    defer ctx_b.deinit();
    try head_a.pick.open(&ctx_a.ctx, "a-prompt", &.{.{ .text = "apple" }}, .{ .handler = Sink.accept });
    try t.expect(head_a.pick.active);
    try t.expect(!head_b.pick.active);
    try head_b.pick.open(&ctx_b.ctx, "b-prompt", &.{.{ .text = "banana" }}, .{ .handler = Sink.accept });
    try t.expect(head_a.pick.active);
    try t.expect(head_b.pick.active);
    try t.expectEqualStrings("a-prompt", head_a.pick.prompt);
    try t.expectEqualStrings("b-prompt", head_b.pick.prompt);

    // Distinct echo lines.
    try head_a.echo.say(gpa, "from A");
    try head_b.echo.say(gpa, "from B");
    try t.expectEqualStrings("from A", head_a.echo.text());
    try t.expectEqualStrings("from B", head_b.echo.text());

    // Opening A's pick set A's mode to "pick" (Pick.open routes mode changes
    // through the ctx's own head); B's mode is untouched by it.
    try t.expectEqualStrings("pick", head_a.currentMode());
    try t.expectEqualStrings("pick", head_b.currentMode());
    // (Both landed in "pick" because each opened its OWN pick — the point is
    // that neither's `setMode` call touched the other's `mode` storage; a
    // shared cursor would show cross-talk under interleaving, e.g. one head's
    // close() restoring into the other's prev mode. Verified directly below.)
    try head_a.pick.dismiss(&ctx_a.ctx);
    try head_b.pick.dismiss(&ctx_b.ctx);
}

test "head: semantic focus and interaction scopes are independent" {
    const gpa = t.allocator;
    var a: Head = .empty;
    defer a.deinit(gpa);
    var b: Head = .empty;
    defer b.deinit(gpa);

    const view_ref: semantic.view.Ref = .{ .authority = .here, .slot = 7, .generation = 2 };
    const field_ref: semantic.scene.FieldRef = .{ .authority = .here, .slot = 3, .generation = 4 };
    const nodes = [_]semantic.scene.NodeId{ @enumFromInt(11), @enumFromInt(12) };
    try a.scene_selection.set(gpa, .{ .view = view_ref, .nodes = &nodes });
    try a.scene_selection.startEdit(gpa, field_ref, "");
    try t.expectEqual(@as(usize, 2), a.scene_selection.path().?.nodes.len);
    try t.expect(b.scene_selection.path() == null);

    const definition: semantic.interaction.Definition = .{
        .role = .dialog,
        .view = view_ref,
        .root = @enumFromInt(20),
        .actions = &.{.{ .id = "apply", .label = "Apply" }},
        .bindings = &.{.{ .input = "y", .action = "apply" }},
    };
    _ = try a.interactions.open(gpa, definition);
    try t.expectEqualStrings("apply", a.interactions.actionForInput("y").?.id);
    try t.expect(b.interactions.actionForInput("y") == null);
}

// Minimal Context scaffolding for the pick-session test above (Context holds
// pointers into a caller-owned environment; a heap-stable one is needed for
// each head under test).
const TestCtx = struct {
    gpa: Allocator,
    pool: *@import("task.zig").Pool,
    buffers: @import("Buffers.zig"),
    commands: @import("command.zig").Commands = .empty,
    /// The ONE shared Container `caps`/`actions` bind into (task #19).
    container: @import("container.zig").Container = undefined,
    caps: @import("capability.zig").Caps,
    actions: @import("action.zig"),
    quit: bool = false,
    ctx: @import("command.zig").Context = undefined,

    /// `km` is BORROWED — the whole point is two heads sharing one
    /// system-scoped Keymap (tables) while each gets its own `Head`.
    fn init(gpa: Allocator, head: *Head, km: *Keymap) !*TestCtx {
        const task = @import("task.zig");
        const pool = try task.Pool.init(gpa, .{ .threads = 1 });
        const self = try gpa.create(TestCtx);
        self.* = .{
            .gpa = gpa,
            .pool = pool,
            .buffers = try @import("Buffers.zig").init(gpa, pool, "user"),
            .container = @import("container.zig").Container.init(gpa),
            .caps = undefined,
            .actions = undefined,
        };
        self.caps = @import("capability.zig").Caps.init(gpa, task.nowNs, &self.container);
        self.actions = @import("action.zig").init(gpa, &self.container);
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = km,
            .actions = &self.actions,
            .caps = &self.caps,
            .quit = &self.quit,
            .head = head,
        };
        return self;
    }

    fn deinit(self: *TestCtx) void {
        const gpa = self.gpa;
        self.actions.deinit();
        self.caps.deinit();
        self.container.deinit();
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
        gpa.destroy(self);
    }
};
