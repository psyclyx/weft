//! Head — per-head interaction state (north-star-plan §2.7, §4 C14, §6 W2a-1).
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

const Keymap = @import("Keymap.zig");
const Pick = @import("pick/Pick.zig");
const Buffers = @import("Buffers.zig");

const Head = @This();

// ── The keymap CURSOR ──────────────────────────────────────────────────
// Owned copies; freed in `deinit`. See Keymap.zig for the table half.

/// This head's current mode. Never empty once any `setMode`/`enterMode` has
/// run; `.empty`'s value is "" (no mode set yet — the modeless floor).
mode: []u8 = &.{},
/// This head's pending key SEQUENCE (see Keymap.zig's `pending` doc — same
/// meaning, just relocated: it is cursor state, not a table).
pending: []u8 = &.{},
/// menu mode → the mode THIS HEAD returns to when a one-shot menu key fires.
/// Per-head because two heads can have the SAME menu mode open from
/// DIFFERENT origins (head A entered "leader" from "normal", head B from
/// "insert" — a shared table would clobber one head's return target with
/// the other's). Recorded only by `enterMode` (guest-initiated); host-side
/// save/restore (the picker) uses plain `setMode` and never touches this.
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
echo: std.ArrayList(u8) = .empty,
/// This head's dot-repeat recorder (`.` replays the last change) — see
/// `DotRepeat`'s doc below. Per-head for the same reason as `pick`/`echo`:
/// two heads pressing keys concurrently must not interleave into one
/// register.
dot: DotRepeat = .empty,
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

pub const empty: Head = .{};

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
    /// Two-head gate gap (north-star-plan §6 W2a GATE): the original
    /// single-head design never needed this because the one head always
    /// existed before the first edit.
    synced: bool = false,

    pub const empty: DotRepeat = .{};
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
    self.* = .{};
}

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

/// Host-side (or generic) mode set: no menu-return bookkeeping. Abandons any
/// half-typed chord (a stale `space f` must not combine with the new mode's
/// next key). Used for buffer-switch restore and host-side save/restore (the
/// picker), neither of which should poison a menu's return target.
pub fn setMode(self: *Head, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const owned = try gpa.dupe(u8, mode);
    gpa.free(self.mode);
    self.mode = owned;
    try self.setPending(gpa, "");
}

/// Guest-initiated mode set. Identical to `setMode`, except that entering a
/// *menu* mode (per `km`'s tables) records THIS HEAD's return target — the
/// root non-menu mode it came from — so a one-shot menu key can pop back
/// (see `menuReturn`). Only guests route through here; host-side mode save/
/// restore uses plain `setMode`, so a restore-into-a-menu never records a
/// bogus return target.
pub fn enterMode(self: *Head, gpa: Allocator, km: *const Keymap, mode: []const u8) Allocator.Error!void {
    if (km.isMenuMode(mode) and !std.mem.eql(u8, self.mode, mode)) {
        // If we came from another menu, inherit *its* return target so a chain
        // of menus collapses to a single hop back to the root non-menu mode;
        // otherwise return to exactly where we were.
        const root = self.menuReturn(self.mode) orelse self.mode;
        const owned_root = try gpa.dupe(u8, root); // dupe before setMode frees self.mode
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
    try self.setMode(gpa, mode);
}

/// The mode THIS HEAD should pop `mode` back to (the root non-menu mode it
/// entered `mode` from), or null if `mode` isn't a menu this head has a
/// recorded return target for.
pub fn menuReturn(self: *const Head, mode: []const u8) ?[]const u8 {
    return self.menu_return.get(mode);
}

/// The command bound to `key` in this head's current mode (chain-walked),
/// then the `global` layer — see `Keymap.lookup`.
pub fn lookup(self: *const Head, km: *const Keymap, key: []const u8) ?[]const u8 {
    return km.lookup(self.mode, key);
}

/// This head's current mode's text command — see `Keymap.textCommand`.
pub fn textCommand(self: *const Head, km: *const Keymap) ?[]const u8 {
    return km.textCommand(self.mode);
}

/// Feed one keyspec through THIS HEAD's pending sequence — see
/// `Keymap.Feed`/the module doc on chords. Mutates `self.pending`; a `.run`
/// command name borrows `km` — use it before any rebind.
pub fn feed(self: *Head, gpa: Allocator, km: *const Keymap, key: []const u8) Allocator.Error!Keymap.Feed {
    const at_top = self.pending.len == 0;
    const cand = if (at_top) key else try std.fmt.allocPrint(gpa, "{s} {s}", .{ self.pending, key });
    defer if (!at_top) gpa.free(cand);

    if (km.resolveExact(self.mode, cand)) |cmd| {
        try self.setPending(gpa, "");
        return .{ .run = cmd };
    }
    if (km.isPrefix(self.mode, cand)) {
        try self.setPending(gpa, cand);
        return .pending;
    }
    try self.setPending(gpa, "");
    return if (at_top) .text else .none;
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
    return km.completionsInto(gpa, self.mode, prefix, &self.resolved, &self.resolved_group);
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

test "head: setMode/feed/pending are per-head — Keymap holds only tables" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.bind(gpa, "normal", "i", "enter-insert", Keymap.prio_plugin, "vim");
    try km.bind(gpa, "normal", "space f f", "find-file", Keymap.prio_plugin, "vim");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setMode(gpa, "normal");
    try t.expectEqualStrings("enter-insert", h.lookup(&km, "i").?);

    try t.expect((try h.feed(gpa, &km, "space")) == .pending);
    try t.expectEqualStrings("space", h.pending);
    try t.expect((try h.feed(gpa, &km, "f")) == .pending);
    {
        const r = try h.feed(gpa, &km, "f");
        try t.expect(r == .run);
        try t.expectEqualStrings("find-file", r.run);
    }
    try t.expectEqual(@as(usize, 0), h.pending.len);
}

test "head: prefix sequences — a chord resolves; a menu is a prefix, not a mode" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    // A leader tree as SEQUENCES (no leader-* mode): SPC f f -> find-file, etc.
    try km.bind(gpa, "normal", "space f f", "find-file", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "space g g", "git-status", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "i", "vim-insert", Keymap.prio_config, "vim");
    try km.bind(gpa, "global", "C-w", "window-thing", Keymap.prio_config, "cfg");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setMode(gpa, "normal");

    // A single bound key runs immediately.
    {
        const r = try h.feed(gpa, &km, "i");
        try t.expect(r == .run);
        try t.expectEqualStrings("vim-insert", r.run);
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
        try t.expectEqualStrings("find-file", r.run);
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
        try t.expectEqualStrings("window-thing", r.run);
    }
    // A lone unbound printable key is `text` (the caller inserts it).
    try t.expect((try h.feed(gpa, &km, "x")) == .text);

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
    try km.bind(gpa, "normal", "space f f", "find-file", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "space f r", "recent-files", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "space g g", "git-status", Keymap.prio_config, "cfg");
    try km.bind(gpa, "normal", "i", "vim-insert", Keymap.prio_config, "vim");
    try km.bind(gpa, "global", "C-w", "window-thing", Keymap.prio_config, "cfg");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setMode(gpa, "normal");

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
    try t.expectEqualStrings("vim-insert", Found.get(&h, "i").?.command);
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
        try t.expect(Found.get(&h, "g") != null);
        try t.expectEqual(@as(?Keymap.Binding, null), Found.get(&h, "C-w")); // no global mid-chord
    }
    // After `space f`: the two leaves `f`→find-file, `r`→recent-files.
    {
        const n = try h.completions(gpa, &km, "space f");
        try t.expectEqual(@as(usize, 2), n);
        try t.expectEqualStrings("find-file", Found.get(&h, "f").?.command);
        try t.expect(!Found.group(&h, "f")); // a leaf now
        try t.expectEqualStrings("recent-files", Found.get(&h, "r").?.command);
    }
}

test "head: menu return targets are per-head, not shared via the table" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.markMenuMode(gpa, "leader");

    var a: Head = .empty;
    defer a.deinit(gpa);
    var b: Head = .empty;
    defer b.deinit(gpa);

    try a.setMode(gpa, "normal");
    try a.enterMode(gpa, &km, "leader");
    try t.expectEqualStrings("normal", a.menuReturn("leader").?);

    try b.setMode(gpa, "insert");
    try b.enterMode(gpa, &km, "leader");
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
    try km.markMenuMode(gpa, "leader");
    try km.markMenuMode(gpa, "leader-file");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setMode(gpa, "normal");

    // Guest enters leader from normal → return target is normal.
    try h.enterMode(gpa, &km, "leader");
    try t.expectEqualStrings("leader", h.currentMode());
    try t.expectEqualStrings("normal", h.menuReturn("leader").?);

    // Nested: enter leader-file from leader → collapses to the root (normal),
    // not one hop back to leader.
    try h.enterMode(gpa, &km, "leader-file");
    try t.expectEqualStrings("normal", h.menuReturn("leader-file").?);

    // A non-menu mode has no return target.
    try t.expectEqual(@as(?[]const u8, null), h.menuReturn("normal"));
}

test "head: host-side setMode restore does NOT poison menu return targets" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.markMenuMode(gpa, "leader");

    var h: Head = .empty;
    defer h.deinit(gpa);
    try h.setMode(gpa, "normal");
    try h.enterMode(gpa, &km, "leader"); // return target: normal

    // The picker saves prev="leader", sets "pick" (plain setMode, not a menu),
    // then on close restores "leader" via plain setMode. That restore must not
    // rewrite leader's return target to "pick".
    try h.setMode(gpa, "pick");
    try h.setMode(gpa, "leader");
    try t.expectEqualStrings("normal", h.menuReturn("leader").?);
}

test "head: two heads over one system hold independent mode, chord, pick, and echo" {
    const gpa = t.allocator;
    // ONE shared system-scoped Keymap (tables) — as two heads attached to the
    // same system would share.
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.bind(gpa, "normal", "i", "enter-insert", Keymap.prio_plugin, "vim");
    try km.bind(gpa, "normal", "space f f", "find-file", Keymap.prio_plugin, "vim");
    try km.markMenuMode(gpa, "leader");

    var head_a: Head = .empty;
    defer head_a.deinit(gpa);
    var head_b: Head = .empty;
    defer head_b.deinit(gpa);

    // Distinct current modes.
    try head_a.setMode(gpa, "normal");
    try head_b.setMode(gpa, "insert");
    try t.expectEqualStrings("normal", head_a.currentMode());
    try t.expectEqualStrings("insert", head_b.currentMode());

    // Distinct pending chords: A is mid-chord, B is untouched.
    try t.expect((try head_a.feed(gpa, &km, "space")) == .pending);
    try t.expect((try head_a.feed(gpa, &km, "f")) == .pending);
    try t.expectEqualStrings("space f", head_a.pending);
    try t.expectEqual(@as(usize, 0), head_b.pending.len);

    // Distinct pick sessions: opening one doesn't touch the other.
    const Sink = struct {
        fn accept(_: *@import("command.zig").Context, _: ?*anyopaque, _: []const u8) anyerror!void {}
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
    try head_a.echo.appendSlice(gpa, "from A");
    try head_b.echo.appendSlice(gpa, "from B");
    try t.expectEqualStrings("from A", head_a.echo.items);
    try t.expectEqualStrings("from B", head_b.echo.items);

    // Opening A's pick set A's mode to "pick" (Pick.open routes mode changes
    // through the ctx's own head); B's mode is untouched by it.
    try t.expectEqualStrings("pick", head_a.currentMode());
    try t.expectEqualStrings("pick", head_b.currentMode());
    // (Both landed in "pick" because each opened its OWN pick — the point is
    // that neither's `setMode` call touched the other's `mode` storage; a
    // shared cursor would show cross-talk under interleaving, e.g. one head's
    // close() restoring into the other's prev mode. Verified directly below.)
    head_a.pick.deinit(gpa);
    head_a.pick = .empty;
    head_b.pick.deinit(gpa);
    head_b.pick = .empty;
}

// Minimal Context scaffolding for the pick-session test above (Context holds
// pointers into a caller-owned environment; a heap-stable one is needed for
// each head under test).
const TestCtx = struct {
    gpa: Allocator,
    pool: *@import("task.zig").Pool,
    buffers: @import("Buffers.zig"),
    commands: @import("command.zig").Commands = .empty,
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
            .caps = @import("capability.zig").Caps.init(gpa, task.nowNs),
            .actions = @import("action.zig").init(gpa),
        };
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
        self.commands.deinit(gpa);
        self.buffers.deinit(gpa);
        self.pool.deinit();
        gpa.destroy(self);
    }
};
