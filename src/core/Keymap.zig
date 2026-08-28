//! Keymap — modal key → NAME-LIST tables (a plain command binding is a
//! one-entry list; a fallback list of intentions is the general case,
//! doc/configuration.md §5.2). The keymap never resolves a list — it hands
//! it whole to dispatch. Pure string domain: a
//! keyspec is `[C-][M-][S-]<xkb keysym name>`. Shift usually lives in
//! the keysym (`a` vs `A`); the explicit `S-` is only for keys with no
//! shifted keysym — `S-Return`, `S-Tab` (specials keep their names —
//! `Escape`, `Tab`, `Return`).
//! The platform layer translates its events into keyspecs; the keymap
//! neither knows xkb nor the commands it names (late binding — a bind
//! may name a command a plugin provides later).
//!
//! Modes are the vim enabler: bindings live per mode; mode SWITCHING is
//! itself just a command.
//!
//! THE SPLIT (doc/contextual-workspace-architecture.md §7): this struct used to
//! ALSO hold the mutable CURSOR into these tables — `mode` (which mode is
//! current), `pending` (the half-typed chord), `menu_return` (per-menu
//! return targets), and the which-key render scratch. That made "current
//! mode" a process-global: two heads attached to one system would have had
//! to share it. It has all moved to `Head.zig`. What stays here is
//! everything that describes what a mode IS — TABLE properties, shared by
//! every head looking at this system: the key→command bindings themselves,
//! fallback chains, and the menu/sticky/locked/resting declarations. Every
//! method below that used to read `self.mode` now takes the mode as an
//! explicit parameter and is a PURE function of `(tables, mode, key)` — see
//! `Head.zig`'s methods (`lookup`, `feed`, `setModeRaw`, `enterModeRaw`, …),
//! which hold a head's position and call into these pure lookups to move it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Keymap = @This();

/// A key's winning binding + the (priority, owner) that won it. Layering
/// ([FIX 9]): a bind only takes the slot when its priority ≥ the incumbent's,
/// so the resolved keymap is a pure function of the declaration set — never
/// load-order-dependent. Precedence tiers: core defaults (−100) < plugins (0)
/// < user config (100).
/// `commands` is the authored fallback ARM LIST (doc/configuration.md §5.2,
/// architecture §10.2), resolved first-applicable at dispatch. A plain
/// command binding is a one-entry list — one representation, no second
/// shape for the single case.
const BindEntry = struct { commands: [][]const u8, priority: i32, owner: []u8 };
const Bindings = std.StringArrayHashMapUnmanaged(BindEntry);

pub const prio_core = -100;
pub const prio_plugin = 0;
/// A `weft.use(name)`-imported manifest's rung (doc/configuration.md §7 C11):
/// strictly between `prio_plugin` and `prio_config`, so `defaults.js`'s
/// binds always lose to `config.js`'s own later binds — by TIER, not by
/// which one happened to be applied last (the old load-order-dependent
/// contract `manifest.zig`'s doc comment replaces). See
/// `manifest.keymapPriorityForTier`.
pub const prio_imported = 50;
pub const prio_config = 100;

/// Ceiling on one binding's authored arm list (`manifest.maxBindCommands`,
/// the config shim's `WEFT_BIND_MAX_CMDS`) — a fallback chain is a handful
/// of arms, never an unbounded program.
pub const max_bind_commands = 8;

modes: std.StringArrayHashMapUnmanaged(Bindings) = .empty,
/// mode → parent mode: `lookup` walks the chain (vim's visual falls
/// back to normal falls back to default).
parents: std.StringArrayHashMapUnmanaged([]u8) = .empty,
/// mode → command a TEXT COMMIT runs in it (one string arg). A mode that
/// declares one COMMITS TEXT — insert-flavored modes name `insert-text`, a
/// picker names its query-append command. Never inherited (see
/// `commitCommand`): a mode that does not declare one cannot commit,
/// whatever it inherits BINDINGS from.
commit_commands: std.StringArrayHashMapUnmanaged([]u8) = .empty,
/// Modes the config declared as prefix menus (leader/chord tables) — the
/// which-key hint shows their bindings. Policy lives in config; this is
/// just the mechanism that remembers the declaration. WHICH mode a given
/// head should return to when it leaves one of these is head-scoped state
/// (two heads can enter the same menu from different origins) — see
/// `Head.menu_return`.
menu_modes: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Menu modes that STAY OPEN after a leaf key (the one-shot auto-pop is
/// suppressed) — flag-accumulating transients (git's push/fetch option
/// popups): toggle keys mutate state and re-render while the menu persists;
/// only an explicit mode change (execute, or Escape → the return target)
/// leaves. A subset of `menu_modes`, so which-key still lists the keys.
sticky_menus: std.StringArrayHashMapUnmanaged(void) = .empty,

/// Modes a buffer can REST in — the base editing mode (`normal`) and each tool
/// projection (`files`, `grep`, `output`, `emacs`, `helix-normal`, a git status/
/// diff/log view). `baseMode` stops at the first of these in a mode's fallback
/// chain, so leaving a buffer remembers its resting mode rather than overshooting
/// to the root `default` (which would strand a revisited file in a mode with no
/// editing keys). Transient modes (visual/insert/op-pending/…) are NOT declared,
/// so they resolve through to their base editing mode.
resting_modes: std.StringArrayHashMapUnmanaged(void) = .empty,

pub const empty: Keymap = .{};

pub fn deinit(self: *Keymap, gpa: Allocator) void {
    for (self.modes.keys(), self.modes.values()) |mode_name, *bindings| {
        gpa.free(mode_name);
        for (bindings.keys(), bindings.values()) |k, v| {
            gpa.free(k);
            freeArms(gpa, v.commands);
            gpa.free(v.owner);
        }
        bindings.deinit(gpa);
    }
    self.modes.deinit(gpa);
    for (self.parents.keys(), self.parents.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    self.parents.deinit(gpa);
    for (self.commit_commands.keys(), self.commit_commands.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    self.commit_commands.deinit(gpa);
    for (self.menu_modes.keys()) |k| gpa.free(k);
    self.menu_modes.deinit(gpa);
    for (self.sticky_menus.keys()) |k| gpa.free(k);
    self.sticky_menus.deinit(gpa);
    for (self.resting_modes.keys()) |k| gpa.free(k);
    self.resting_modes.deinit(gpa);
    self.* = .{};
}

/// Bind `keyspec` to `command` in `mode` at `priority`, owned by `owner`
/// (the binder — a plugin name, "config", or "core"). The binding takes the
/// slot only when its priority ≥ the current holder's, so a higher tier
/// (config > plugin > core) always wins regardless of bind order. An
/// equal-priority bind from a *different* owner is a collision — surfaced as a
/// warning; last one wins.
pub fn bind(self: *Keymap, gpa: Allocator, mode: []const u8, key_in: []const u8, command: []const u8, priority: i32, owner: []const u8) Allocator.Error!void {
    return self.bindArms(gpa, mode, key_in, &.{command}, priority, owner);
}

/// Bind an authored fallback ARM LIST (doc/configuration.md §5.2) — the
/// general form; `bind` is its one-entry case. The keymap never resolves the
/// list: it carries it whole to dispatch, which resolves first-applicable
/// against the catalog (architecture §10.2).
pub fn bindArms(self: *Keymap, gpa: Allocator, mode: []const u8, key_in: []const u8, commands: []const []const u8, priority: i32, owner: []const u8) Allocator.Error!void {
    std.debug.assert(commands.len > 0);
    var kbuf: [256]u8 = undefined;
    const key = normalizeKey(&kbuf, key_in);
    const gop = try self.modes.getOrPut(gpa, mode);
    if (!gop.found_existing) {
        gop.key_ptr.* = try gpa.dupe(u8, mode);
        gop.value_ptr.* = .empty;
    }
    const bgop = try gop.value_ptr.getOrPut(gpa, key);
    if (bgop.found_existing) {
        const cur = bgop.value_ptr.*;
        if (priority < cur.priority) return; // a lower tier can't shadow a higher one
        if (priority == cur.priority and !std.mem.eql(u8, cur.owner, owner))
            std.log.warn("keymap: '{s}' in mode '{s}' bound by both '{s}' and '{s}' at priority {d}", .{ key, mode, cur.owner, owner, priority });
        freeArms(gpa, cur.commands);
        gpa.free(cur.owner);
    } else {
        bgop.key_ptr.* = try gpa.dupe(u8, key);
    }
    bgop.value_ptr.* = .{
        .commands = try dupeArms(gpa, commands),
        .priority = priority,
        .owner = try gpa.dupe(u8, owner),
    };
}

fn dupeArms(gpa: Allocator, commands: []const []const u8) Allocator.Error![][]const u8 {
    const out = try gpa.alloc([]const u8, commands.len);
    errdefer gpa.free(out);
    var n: usize = 0;
    errdefer for (out[0..n]) |c| gpa.free(c);
    for (commands, 0..) |c, i| {
        out[i] = try gpa.dupe(u8, c);
        n += 1;
    }
    return out;
}

fn freeArms(gpa: Allocator, commands: [][]const u8) void {
    for (commands) |c| gpa.free(c);
    gpa.free(commands);
}

/// Remove the binding at `mode`/`key` IFF it is currently owned by `owner`
/// (else a no-op — never steal a slot a different, or since-rebound, owner
/// holds). Used by `manifest.zig`'s reconcile teardown (doc/cwa-prior-docs-audit.md §5):
/// a bind declared by a PREVIOUS config manifest but absent from the
/// reloaded one must not leave a ghost binding behind. Frees the entry's
/// owned strings on removal.
pub fn unbind(self: *Keymap, gpa: Allocator, mode: []const u8, key_in: []const u8, owner: []const u8) void {
    var kbuf: [256]u8 = undefined;
    const key = normalizeKey(&kbuf, key_in);
    const bindings = self.modes.getPtr(mode) orelse return;
    const entry = bindings.get(key) orelse return;
    if (!std.mem.eql(u8, entry.owner, owner)) return;
    if (bindings.fetchSwapRemove(key)) |removed| {
        gpa.free(removed.key);
        freeArms(gpa, removed.value.commands);
        gpa.free(removed.value.owner);
    }
}

/// The reserved layer consulted under EVERY mode, after its own fallback
/// chain — so a truly universal key (which-key on F1, the C-w window prefix)
/// works everywhere without being duplicated into each mode (or leaking a whole
/// mode's bindings in via a fallback). A mode still overrides a global key by
/// binding it locally; global is never a fallback target, only the final check.
pub const global_mode = "global";

/// The command bound to `keyspec` in `mode` or its fallback chain, then the
/// `global` layer, if any. Pure function of `(tables, mode, key)` — a head
/// calls this with its own current mode (see `Head.lookup`).
pub fn lookup(self: *const Keymap, mode: []const u8, key: []const u8) ?[]const u8 {
    const arms = self.lookupArms(mode, key) orelse return null;
    return arms[0];
}

/// `lookup`'s general form: the whole authored fallback list. Callers that
/// only DISPLAY a binding (which-key, tests) want `lookup`'s first arm;
/// dispatch wants this.
pub fn lookupArms(self: *const Keymap, mode: []const u8, key: []const u8) ?[]const []const u8 {
    const entry = self.find(mode, key) orelse return null;
    return entry.commands;
}

/// The winning entry for `key` under `mode`: the mode's own table, its
/// fallback chain, then the `global` layer — the ONE walk every lookup here
/// makes.
fn find(self: *const Keymap, mode: []const u8, key: []const u8) ?BindEntry {
    var m: []const u8 = mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (self.modes.getPtr(m)) |bindings| {
            if (bindings.get(key)) |entry| return entry;
        }
        m = self.parents.get(m) orelse break;
    }
    // Universal fallback: `global` binds apply under every mode.
    if (self.modes.getPtr(global_mode)) |bindings| {
        if (bindings.get(key)) |entry| return entry;
    }
    return null;
}

/// What feeding a key produced (see `Head.feed`).
pub const Feed = union(enum) {
    run: []const []const u8, // a full sequence resolved — its authored arm list (borrowed)
    pending, // extended the pending chord — which-key shows its completions
    unbound, // a lone key the grammar does not bind — it may still COMMIT text
    none, // a dead-end chord — reset, nothing to do
};

/// The command a full SEQUENCE resolves to, in `mode`: its own table, its
/// fallback chain, then `global`. A single-key seq gets global's universal
/// binds; a multi-key chord effectively won't (global holds single keys), so
/// a global key never fires MID-sequence — `SPC C-w` is the chord
/// `space C-w`, not global `C-w`. (This is why menus-as-sequences dissolve
/// the "global is too global" problem.) Called by `Head.feed` with the
/// head's own mode + pending-extended candidate.
pub fn resolveExact(self: *const Keymap, mode: []const u8, seq: []const u8) ?[]const u8 {
    const arms = self.resolveExactArms(mode, seq) orelse return null;
    return arms[0];
}

/// `resolveExact`'s general form — the whole authored arm list, which is
/// what `Head.feed` hands dispatch.
pub fn resolveExactArms(self: *const Keymap, mode: []const u8, seq: []const u8) ?[]const []const u8 {
    const entry = self.find(mode, seq) orelse return null;
    return entry.commands;
}

/// Whether `seq` is a strict PREFIX of some bound sequence in `mode`, its
/// fallback chain, or `global` (more keys would complete a chord). Global IS
/// consulted so a UNIVERSAL chord (`C-w s` window commands, bound in global) is
/// reachable from every mode — this does NOT re-widen "global too global",
/// because a match requires the WHOLE `seq` to be a literal prefix of a global
/// key: mid-chord `space C-w` never matches global's `C-w …` (they don't share a
/// start), so a global key only ever begins a sequence, never continues one.
pub fn isPrefix(self: *const Keymap, mode: []const u8, seq: []const u8) bool {
    var m: []const u8 = mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (self.modes.getPtr(m)) |b| if (prefixIn(b, seq)) return true;
        m = self.parents.get(m) orelse break;
    }
    if (self.modes.getPtr(global_mode)) |b| if (prefixIn(b, seq)) return true;
    return false;
}

fn prefixIn(b: *const Bindings, seq: []const u8) bool {
    for (b.keys()) |k| {
        if (k.len > seq.len and std.mem.startsWith(u8, k, seq) and k[seq.len] == ' ') return true;
    }
    return false;
}

/// Make `mode` inherit `parent`'s bindings (chain-walked at lookup).
pub fn setFallback(self: *Keymap, gpa: Allocator, mode: []const u8, parent: []const u8) Allocator.Error!void {
    const gop = try self.parents.getOrPut(gpa, mode);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try gpa.dupe(u8, mode);
    }
    gop.value_ptr.* = try gpa.dupe(u8, parent);
}

/// The RESTING mode a buffer in `mode` should be remembered as: the root of the
/// fallback chain (`visual`/`insert`/`op-pending` fall back to `normal`, so
/// their base is `normal`; `git`/`files` have no parent, so they are their own
/// base). This reuses the fallback declarations config already makes for key
/// lookup — no separate "which modes are transient" bookkeeping. A menu mode has
/// no parents, so it returns itself; callers skip menus explicitly.
pub fn baseMode(self: *const Keymap, mode: []const u8) []const u8 {
    var cur = mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        // A menu is its OWN base (a buffer is never remembered as a menu — the
        // caller skips it). Stop here rather than walking into the `menu-nav`
        // base a menu now falls back to for its navigation keys, which would
        // wrongly make a menu's base a non-menu and get captured.
        if (self.isMenuMode(cur)) return cur;
        // A RESTING mode is a buffer's base: `normal` and each tool projection
        // (files/grep/output/git). Stop here so a transient mode (visual/
        // insert) resolves to its editing base while a tool buffer keeps its own
        // mode — WITHOUT overshooting `normal`→`default` to the root, which would
        // strand a revisited file in the editing-less `default` mode.
        if (self.isRestingMode(cur)) return cur;
        cur = self.parents.get(cur) orelse return cur;
    }
    return cur;
}

/// DECLARE that `mode` commits text, running `cmd` on each commit — `null`
/// withdraws the declaration. This is the whole of a mode's text posture:
/// no default, and no inheritance to opt out of.
pub fn setCommitCommand(self: *Keymap, gpa: Allocator, mode: []const u8, cmd: ?[]const u8) Allocator.Error!void {
    const c = cmd orelse {
        if (self.commit_commands.fetchSwapRemove(mode)) |old| {
            gpa.free(old.key);
            gpa.free(old.value);
        }
        return;
    };
    const gop = try self.commit_commands.getOrPut(gpa, mode);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try gpa.dupe(u8, mode);
    }
    gop.value_ptr.* = try gpa.dupe(u8, c);
}

/// The command a `TextCommit` runs in `mode`, or null when the mode does not
/// commit text. Deliberately NOT chain-walked, unlike `lookup`: a fallback
/// chain carries BINDINGS, never the authority to commit text. So a
/// structural mode cannot leak insertion by inheriting from an editing base,
/// and no plugin has to remember to opt out. Called by `Head.commitCommand`
/// with the head's own current mode.
pub fn commitCommand(self: *const Keymap, mode: []const u8) ?[]const u8 {
    return self.commit_commands.get(mode);
}

/// One enumerated binding: its display key, its FIRST arm (what a plain
/// command binding shows), and the whole authored arm list — which an explain
/// UI hands back to the resolver to say what the key would actually do.
/// Keymap-owned; valid until the next mutation.
pub const Binding = struct {
    key: []const u8,
    command: []const u8,
    arms: []const []const u8 = &.{},
};

/// The reserved layer for which-key NAVIGATION keys (paginate the hint) — the
/// META keys that act on the which-key overlay WITHOUT being part of the chord
/// you're typing. STRUCTURE only — the actual key BINDINGS are config data
/// (`defaults.js` binds `menu-nav`), so nav is uniform + rebindable and no
/// plugin/config re-wires it. Mid-chord, dispatch consults this via `navCommand`
/// before feeding the key into the sequence: a nav key pages the hint and leaves
/// `pending` intact; anything else extends (or ends) the chord as usual. (It's
/// also the fallback base a legacy menu MODE inherits — same keys, both worlds.)
pub const menu_nav_mode = "menu-nav";

/// The command bound to `key` in the which-key NAV layer (`menu-nav`'s own
/// table), or null. Dispatch runs this while a chord is `pending` so a nav key
/// (page down/up) acts on the hint instead of dead-ending the sequence.
pub fn navCommand(self: *const Keymap, key: []const u8) ?[]const u8 {
    const b = self.modes.getPtr(menu_nav_mode) orelse return null;
    return if (b.get(key)) |e| e.commands[0] else null;
}

/// Declare `mode` a prefix menu (config policy — the leader/chord tables).
/// which-key shows its bindings while it is active. A menu with no fallback of
/// its own inherits `menu-nav` (its nav keys) — so every menu paginates + pops
/// a level for free, without each config wiring it.
pub fn markMenuMode(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const gop = try self.menu_modes.getOrPut(gpa, mode);
    if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, mode);
    if (!std.mem.eql(u8, mode, menu_nav_mode) and !self.parents.contains(mode))
        try self.setFallback(gpa, mode, menu_nav_mode);
}

/// Whether `mode` was declared a prefix menu (see `markMenuMode`).
pub fn isMenuMode(self: *const Keymap, mode: []const u8) bool {
    return self.menu_modes.contains(mode);
}

/// Declare `mode` a STICKY menu: it stays open after a leaf key instead of
/// auto-popping to its return target (flag-accumulating transients). Implies
/// menu-mode, so which-key still lists its keys.
pub fn markStickyMenu(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    try self.markMenuMode(gpa, mode);
    const gop = try self.sticky_menus.getOrPut(gpa, mode);
    if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, mode);
}

/// Whether `mode` stays open after a leaf key (see `markStickyMenu`).
pub fn isStickyMenu(self: *const Keymap, mode: []const u8) bool {
    return self.sticky_menus.contains(mode);
}

/// Declare `mode` a RESTING mode — a mode a buffer settles in (see `resting_modes`
/// + `baseMode`). Idempotent.
pub fn markRestingMode(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const gop = try self.resting_modes.getOrPut(gpa, mode);
    if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, mode);
}

/// Whether `mode` is one explicitly declared a resting mode.
pub fn isRestingMode(self: *const Keymap, mode: []const u8) bool {
    return self.resting_modes.contains(mode);
}

/// Append `mode`'s own bindings (key → command) to `out`, in bind order.
/// For which-key: a leaf menu mode's whole table.
pub fn ownBindings(self: *const Keymap, gpa: Allocator, mode: []const u8, out: *std.ArrayList(Binding)) Allocator.Error!void {
    const b = self.modes.getPtr(mode) orelse return;
    for (b.keys(), b.values()) |k, v| try out.append(gpa, .{ .key = k, .command = v.commands[0], .arms = v.commands });
}

/// Number of bindings in `mode`'s own table (for which-key enumeration via the
/// membrane — the guest reads them by index without a host allocation).
pub fn bindingCount(self: *const Keymap, mode: []const u8) usize {
    const b = self.modes.getPtr(mode) orelse return 0;
    return b.count();
}

/// The `i`-th binding of `mode` (bind order), borrowed — valid until the next
/// keymap mutation. Null for an out-of-range index or unknown mode.
pub fn bindingAt(self: *const Keymap, mode: []const u8, i: usize) ?Binding {
    const b = self.modes.getPtr(mode) orelse return null;
    if (i >= b.count()) return null;
    return .{ .key = b.keys()[i], .command = b.values()[i].commands[0] };
}

/// Build the RESOLVED set of bindings AVAILABLE in `mode` into `out`/
/// `out_group` (a HEAD's own scratch — see `Head.resolveBindings`) and
/// return the count: the mode's own table, then each fallback parent, then
/// `global` — the FIRST binding of a key wins (a nearer mode's local override),
/// so each key appears once. This is "what can I press here", the same key set
/// `lookup` would resolve — so which-key shows the whole reachable context
/// (files's nav keys AND the editing keys it inherits), not just one mode's own
/// table. Read back with the head's `resolvedAt`; both are valid until the next
/// keymap mutation (the guest enumerates synchronously during its `on_menu`).
pub fn resolveBindingsInto(self: *const Keymap, gpa: Allocator, mode: []const u8, out: *std.ArrayList(Binding), out_group: *std.ArrayList(bool)) Allocator.Error!usize {
    out.clearRetainingCapacity();
    out_group.clearRetainingCapacity();
    var m: []const u8 = mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        try self.addResolvedInto(gpa, m, out, out_group);
        m = self.parents.get(m) orelse break;
    }
    try self.addResolvedInto(gpa, global_mode, out, out_group);
    return out.items.len;
}

/// Append `mode`'s own bindings to `out`, skipping any key already present
/// (a nearer mode in the walk bound it — the override lookup honors). A binding
/// whose command names a menu mode is a GROUP (legacy menu-mode which-key).
fn addResolvedInto(self: *const Keymap, gpa: Allocator, mode: []const u8, out: *std.ArrayList(Binding), out_group: *std.ArrayList(bool)) Allocator.Error!void {
    const b = self.modes.getPtr(mode) orelse return;
    outer: for (b.keys(), b.values()) |k, v| {
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.key, k)) continue :outer;
        }
        try out.append(gpa, .{ .key = k, .command = v.commands[0], .arms = v.commands });
        try out_group.append(gpa, self.isMenuMode(v.commands[0]));
    }
}

/// Fill `out`/`out_group` (a head's own scratch) with the next-key CHOICES
/// after `prefix` in `mode` — the pending chord ("" = top level, the F1
/// peek). Scans `mode` + fallback chain (+ `global`, at top level only) for
/// bindings whose key extends `prefix` by ≥1 segment; the display key is the
/// immediate NEXT segment. Deduped by that segment (nearer mode / earlier
/// bind wins). A segment is a LEAF when `prefix seg` is itself a complete
/// binding (its command is shown); a GROUP when it only continues a chord
/// (more keys follow — shown as a "+prefix" label, `out_group` true). This
/// is what which-key renders as you type a chord: at `space`, the `f`/`g`/…
/// choices; at `space f`, the file submenu's. Read back with the head's
/// `resolvedAt`/`resolvedIsGroup`; valid until the next mutation.
pub fn completionsInto(self: *const Keymap, gpa: Allocator, mode: []const u8, prefix: []const u8, out: *std.ArrayList(Binding), out_group: *std.ArrayList(bool)) Allocator.Error!usize {
    out.clearRetainingCapacity();
    out_group.clearRetainingCapacity();
    var m: []const u8 = mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        try self.addCompletionsInto(gpa, m, prefix, out, out_group);
        m = self.parents.get(m) orelse break;
    }
    // The universal layer is consulted too, so a global chord opener (`C-w`) is
    // offered from any mode. The prefix filter keeps it honest: mid-chord
    // (`space`) global's `C-w …` keys don't start with the prefix, so nothing
    // global leaks in — a global key only ever surfaces as a top-level choice.
    try self.addCompletionsInto(gpa, global_mode, prefix, out, out_group);
    return out.items.len;
}

/// Append `mode`'s next-segment choices after `prefix` to `out`, deduped by
/// segment against what's there (a nearer mode already offered it).
fn addCompletionsInto(self: *const Keymap, gpa: Allocator, mode: []const u8, prefix: []const u8, out: *std.ArrayList(Binding), out_group: *std.ArrayList(bool)) Allocator.Error!void {
    const b = self.modes.getPtr(mode) orelse return;
    for (b.keys(), b.values()) |k, v| {
        // The remainder of `k` past `prefix ` — the part this key adds to the chord.
        const rest = if (prefix.len == 0) k else blk: {
            if (!(k.len > prefix.len and std.mem.startsWith(u8, k, prefix) and k[prefix.len] == ' ')) continue;
            break :blk k[prefix.len + 1 ..];
        };
        if (rest.len == 0) continue;
        const seg_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const seg = rest[0..seg_end];
        const is_leaf = seg_end == rest.len; // the key ends here → a runnable leaf
        for (out.items) |existing| {
            if (std.mem.eql(u8, existing.key, seg)) break; // already offered — dedup
        } else {
            // Only a LEAF carries arms: a group's label is a placeholder, and
            // the chord it opens resolves nothing yet.
            try out.append(gpa, .{
                .key = seg,
                .command = if (is_leaf) v.commands[0] else "+prefix",
                .arms = if (is_leaf) v.commands else &.{},
            });
            try out_group.append(gpa, !is_leaf);
        }
    }
}

/// Compose a keyspec from modifiers + a keysym name into `buf`. `shift`
/// is the BINDING-relevant shift only — held but not consumed to produce
/// the keysym (so `Return`+Shift → "S-Return", while `a`+Shift is the
/// keysym "A" with no S- prefix). The platform layer resolves that.
pub fn keyspec(buf: []u8, ctrl: bool, alt: bool, shift: bool, keysym_name: []const u8) []const u8 {
    var i: usize = 0;
    if (ctrl) {
        @memcpy(buf[i..][0..2], "C-");
        i += 2;
    }
    if (alt) {
        @memcpy(buf[i..][0..2], "M-");
        i += 2;
    }
    if (shift) {
        @memcpy(buf[i..][0..2], "S-");
        i += 2;
    }
    const n = @min(keysym_name.len, buf.len - i);
    @memcpy(buf[i..][0..n], keysym_name[0..n]);
    return buf[0 .. i + n];
}

// ── Keyspec normalization: the ONE translation between a human-authored config
// and the canonical xkb-keysym form the platform emits at event time. It's the
// bind-time inverse of `keyspec` (which composes the event-time spec from xkb):
// a config writes what it means — "SPC :", "C-x C-f", "M-x", "space f f" — and
// `bind` stores the canonical "space colon" / "C-x C-f" / "M-x" that `lookup`/
// `feed` match against. Idempotent on already-canonical specs, so plugins keep
// binding raw keysym names and nothing else changes. This is the whole
// translation layer; keep it here so there's exactly one. ──────────────────────

/// The X11/xkb keysym NAME for an ASCII punctuation byte (`:` → "colon"), or null
/// for alphanumerics (whose keysym name is the character itself). A frozen table
/// — these keysym names don't change — so no xkb dependency leaks into core.
fn punctName(c: u8) ?[]const u8 {
    return switch (c) {
        '!' => "exclam",
        '"' => "quotedbl",
        '#' => "numbersign",
        '$' => "dollar",
        '%' => "percent",
        '&' => "ampersand",
        '\'' => "apostrophe",
        '(' => "parenleft",
        ')' => "parenright",
        '*' => "asterisk",
        '+' => "plus",
        ',' => "comma",
        '-' => "minus",
        '.' => "period",
        '/' => "slash",
        ':' => "colon",
        ';' => "semicolon",
        '<' => "less",
        '=' => "equal",
        '>' => "greater",
        '?' => "question",
        '@' => "at",
        '[' => "bracketleft",
        '\\' => "backslash",
        ']' => "bracketright",
        '^' => "asciicircum",
        '_' => "underscore",
        '`' => "grave",
        '{' => "braceleft",
        '|' => "bar",
        '}' => "braceright",
        '~' => "asciitilde",
        ' ' => "space",
        else => null,
    };
}

/// The canonical keysym name for one token's BASE (after modifier stripping):
/// an emacs-style alias for a non-printable special, a single ASCII punctuation
/// char via `punctName`, else the base verbatim (a keysym name or an alnum char,
/// which already equals its name).
fn baseName(base: []const u8) []const u8 {
    const aliases = [_][2][]const u8{
        .{ "SPC", "space" },  .{ "TAB", "Tab" },       .{ "RET", "Return" },
        .{ "ESC", "Escape" }, .{ "DEL", "BackSpace" },
    };
    for (aliases) |a| if (std.mem.eql(u8, base, a[0])) return a[1];
    if (base.len == 1) if (punctName(base[0])) |n| return n;
    return base;
}

/// The ASCII punctuation byte for a keysym NAME ("colon" → `:`), or null — the
/// inverse of `punctName`, by scanning the frozen table (no second table to keep
/// in sync). Starts at '!' so it never returns the space char (that displays as
/// the "SPC" alias, not a literal blank).
fn punctChar(name: []const u8) ?u8 {
    var c: u8 = '!';
    while (c < 127) : (c += 1) {
        if (punctName(c)) |n| if (std.mem.eql(u8, n, name)) return c;
    }
    return null;
}

/// The DISPLAY form of a canonical keyspec — the inverse of `normalizeKey`, so
/// which-key shows a binding in the SAME notation a config writes it ("SPC :",
/// not "space colon"). Per token: modifier prefixes pass through; `space` → SPC,
/// an ASCII-punctuation keysym name → its char, else the name verbatim (`f`,
/// `Escape`, `F1`). Display only — logic always uses the canonical form.
pub fn displayKey(self: *const Keymap, buf: []u8, key: []const u8) []const u8 {
    _ = self;
    var w: usize = 0;
    var it = std.mem.splitScalar(u8, key, ' ');
    var first = true;
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        if (!first) {
            if (w >= buf.len) return key;
            buf[w] = ' ';
            w += 1;
        }
        first = false;
        var base = tok;
        while (base.len >= 2 and base[1] == '-' and (base[0] == 'C' or base[0] == 'M' or base[0] == 'S')) {
            if (w + 2 > buf.len) return key;
            buf[w] = base[0];
            buf[w + 1] = '-';
            w += 2;
            base = base[2..];
        }
        if (std.mem.eql(u8, base, "space")) {
            if (w + 3 > buf.len) return key;
            @memcpy(buf[w..][0..3], "SPC");
            w += 3;
        } else if (punctChar(base)) |c| {
            if (w >= buf.len) return key;
            buf[w] = c;
            w += 1;
        } else {
            if (w + base.len > buf.len) return key;
            @memcpy(buf[w..][0..base.len], base);
            w += base.len;
        }
    }
    return buf[0..w];
}

/// Canonicalize a human keyspec (or space-joined sequence) into `buf`. Per
/// token: leading `C-`/`M-`/`S-` modifier prefixes pass through unchanged, then
/// the base maps via `baseName`. Falls back to the raw input if it doesn't fit.
pub fn normalizeKey(buf: []u8, key: []const u8) []const u8 {
    var w: usize = 0;
    var it = std.mem.splitScalar(u8, key, ' ');
    var first = true;
    while (it.next()) |tok| {
        if (tok.len == 0) continue; // tolerate stray/doubled spaces
        if (!first) {
            if (w >= buf.len) return key;
            buf[w] = ' ';
            w += 1;
        }
        first = false;
        var base = tok;
        while (base.len >= 2 and base[1] == '-' and (base[0] == 'C' or base[0] == 'M' or base[0] == 'S')) {
            if (w + 2 > buf.len) return key;
            buf[w] = base[0];
            buf[w + 1] = '-';
            w += 2;
            base = base[2..];
        }
        const name = baseName(base);
        if (w + name.len > buf.len) return key;
        @memcpy(buf[w..][0..name.len], name);
        w += name.len;
    }
    return buf[0..w];
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "keymap: modal binding, rebinding, keyspec composition" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.bind(gpa, "normal", "i", "enter-insert", prio_plugin, "vim");
    try km.bind(gpa, "normal", "C-s", "save", prio_plugin, "vim");
    try km.bind(gpa, "insert", "Escape", "enter-normal", prio_plugin, "vim");

    try t.expectEqualStrings("enter-insert", km.lookup("normal", "i").?);
    try t.expectEqualStrings("save", km.lookup("normal", "C-s").?);
    try t.expectEqual(@as(?[]const u8, null), km.lookup("normal", "Escape"));

    try t.expectEqualStrings("enter-normal", km.lookup("insert", "Escape").?);
    try t.expectEqual(@as(?[]const u8, null), km.lookup("insert", "i"));

    // Same-owner rebinding replaces.
    try km.bind(gpa, "insert", "Escape", "custom-escape", prio_plugin, "vim");
    try t.expectEqualStrings("custom-escape", km.lookup("insert", "Escape").?);

    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("C-M-x", keyspec(&buf, true, true, false, "x"));
    try t.expectEqualStrings("Escape", keyspec(&buf, false, false, false, "Escape"));
    try t.expectEqualStrings("S-Return", keyspec(&buf, false, false, true, "Return"));
    try t.expectEqualStrings("C-M-S-Tab", keyspec(&buf, true, true, true, "Tab"));
}

test "keymap: layering is order-independent — higher priority always wins" {
    const gpa = t.allocator;
    try t.expectEqual(true, prio_core < prio_plugin and prio_plugin < prio_config);

    // Core default, then a plugin shadows it, then user config shadows that.
    var a: Keymap = .empty;
    defer a.deinit(gpa);
    try a.bind(gpa, "default", "j", "cursor-down", prio_core, "core");
    try a.bind(gpa, "default", "j", "motion.down", prio_plugin, "vim");
    try a.bind(gpa, "default", "j", "my-thing", prio_config, "config");
    try t.expectEqualStrings("my-thing", a.lookup("default", "j").?);

    // Same binds in the OPPOSITE order resolve identically — a lower tier can
    // never displace a higher one, so the result is a pure function of the set.
    var b: Keymap = .empty;
    defer b.deinit(gpa);
    try b.bind(gpa, "default", "j", "my-thing", prio_config, "config");
    try b.bind(gpa, "default", "j", "motion.down", prio_plugin, "vim");
    try b.bind(gpa, "default", "j", "cursor-down", prio_core, "core");
    try t.expectEqualStrings("my-thing", b.lookup("default", "j").?);
}

test "keymap: unbind removes only if the owner still matches; no-op otherwise" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.bind(gpa, "normal", "j", "cursor-down", prio_imported, "import:defaults");
    try t.expectEqualStrings("cursor-down", km.lookup("normal", "j").?);

    // A different owner can't steal-then-unbind the slot out from under it.
    km.unbind(gpa, "normal", "j", "someone-else");
    try t.expectEqualStrings("cursor-down", km.lookup("normal", "j").?);

    // A higher tier has since taken the slot — unbinding the ORIGINAL owner
    // must not remove the newer binding.
    try km.bind(gpa, "normal", "j", "my-thing", prio_config, "config");
    km.unbind(gpa, "normal", "j", "import:defaults");
    try t.expectEqualStrings("my-thing", km.lookup("normal", "j").?);

    // The rightful owner unbinds cleanly.
    try km.bind(gpa, "normal", "k", "cursor-up", prio_imported, "import:defaults");
    km.unbind(gpa, "normal", "k", "import:defaults");
    try t.expectEqual(@as(?[]const u8, null), km.lookup("normal", "k"));

    // Unbinding a never-bound key, or in an unknown mode, is a harmless no-op.
    km.unbind(gpa, "normal", "z", "import:defaults");
    km.unbind(gpa, "nope", "j", "import:defaults");
}

test "keymap: menu modes are leaf prefix tables, with enumerable bindings" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.bind(gpa, "normal", "i", "insert", prio_plugin, "vim");
    try km.bind(gpa, "leader", "f", "find-file", prio_plugin, "vim");
    try km.bind(gpa, "leader", "c", "collab", prio_plugin, "vim");

    // which-key shows only for modes the config declared as menus.
    try t.expect(!km.isMenuMode("leader")); // not declared yet
    try km.markMenuMode(gpa, "leader");
    try t.expect(km.isMenuMode("leader"));
    try t.expect(!km.isMenuMode("normal")); // never declared
    try t.expect(!km.isMenuMode("nope"));

    var hints: std.ArrayList(Binding) = .empty;
    defer hints.deinit(gpa);
    try km.ownBindings(gpa, "leader", &hints);
    try t.expectEqual(@as(usize, 2), hints.items.len);
    try t.expectEqualStrings("f", hints.items[0].key);
    try t.expectEqualStrings("find-file", hints.items[0].command);
}

test "keymap: sticky menus stay open (implies menu-mode)" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try t.expect(!km.isStickyMenu("git-push-menu"));
    try km.markStickyMenu(gpa, "git-push-menu");
    try t.expect(km.isStickyMenu("git-push-menu"));
    try t.expect(km.isMenuMode("git-push-menu")); // sticky implies menu-mode
    // A plain menu isn't sticky — it still one-shot auto-pops.
    try km.markMenuMode(gpa, "leader");
    try t.expect(!km.isStickyMenu("leader"));
}

test "keymap: the global layer applies under every mode, overridable locally" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    // F1 bound only in the global layer (config's which-key key).
    try km.bind(gpa, Keymap.global_mode, "F1", "which-key-now", prio_plugin, "cfg");
    try km.bind(gpa, "normal", "i", "insert", prio_plugin, "vim");

    // In normal (which has no F1 of its own) F1 falls through to global.
    try t.expectEqualStrings("which-key-now", km.lookup("normal", "F1").?);
    // In a standalone tool mode with NO fallback chain, F1 still works —
    // that's the whole point (before, tool modes were islands).
    try t.expectEqualStrings("which-key-now", km.lookup("tool", "F1").?);
    // A mode still overrides a global key by binding it locally.
    try km.bind(gpa, "tool", "F1", "tool-help", prio_plugin, "tool");
    try t.expectEqualStrings("tool-help", km.lookup("tool", "F1").?);
}

test "keymap: a menu inherits the menu-nav base for nav keys; baseMode stops at the menu" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    // The nav base's keys are config data (here: Backspace pops a level).
    try km.bind(gpa, Keymap.menu_nav_mode, "BackSpace", "menu-escape", prio_config, "cfg");
    try km.bind(gpa, Keymap.menu_nav_mode, "PageDown", "which-key-page-down", prio_config, "cfg");

    // Declaring a menu auto-wires it to inherit menu-nav (no per-config wiring),
    // so its nav keys resolve through the fallback — but its OWN keys still win.
    try km.markMenuMode(gpa, "leader");
    try km.bind(gpa, "leader", "f", "leader-file", prio_config, "cfg");
    try t.expectEqualStrings("leader-file", km.lookup("leader", "f").?); // own key
    try t.expectEqualStrings("menu-escape", km.lookup("leader", "BackSpace").?); // inherited nav
    try t.expectEqualStrings("which-key-page-down", km.lookup("leader", "PageDown").?);

    // baseMode stops at the menu (a buffer is never remembered as a menu, nor as
    // the menu-nav base it falls back to) — so switchTo's menu-skip stays correct.
    try t.expectEqualStrings("leader", km.baseMode("leader"));
    try t.expect(!km.parents.contains(Keymap.menu_nav_mode)); // the base itself has no fallback

    // A menu that already has its own fallback is left alone (not re-wired).
    try km.setFallback(gpa, "leader-git", "leader");
    try km.markMenuMode(gpa, "leader-git");
    try t.expectEqualStrings("leader", km.parents.get("leader-git").?);
}

// Chord feeding (`feed`/`pending`), which-key resolution (`resolveBindings`/
// `completions`), and menu return-target tracking (`enterModeRaw`/
// `menuReturn`) are all HEAD cursor behavior now — see `Head.zig`'s test
// block for their coverage (including the two-head independence tests this
// split exists for).

test "keymap: keyspec normalization — config writes SPC : / C-x C-f, stores canonical" {
    var buf: [256]u8 = undefined;
    // The specials + punctuation a config would naturally write.
    try t.expectEqualStrings("space colon", normalizeKey(&buf, "SPC :"));
    try t.expectEqualStrings("space f f", normalizeKey(&buf, "SPC f f"));
    try t.expectEqualStrings("C-x C-f", normalizeKey(&buf, "C-x C-f"));
    try t.expectEqualStrings("M-x", normalizeKey(&buf, "M-x"));
    try t.expectEqualStrings("space slash", normalizeKey(&buf, "SPC /"));
    try t.expectEqualStrings("space equal", normalizeKey(&buf, "SPC ="));
    try t.expectEqualStrings("C-space", normalizeKey(&buf, "C-SPC"));
    try t.expectEqualStrings("Tab", normalizeKey(&buf, "TAB"));
    try t.expectEqualStrings("BackSpace", normalizeKey(&buf, "DEL"));
    // Idempotent on already-canonical specs (plugins bind these directly).
    try t.expectEqualStrings("space colon", normalizeKey(&buf, "space colon"));
    try t.expectEqualStrings("C-w s", normalizeKey(&buf, "C-w s"));
    try t.expectEqualStrings("S-Return", normalizeKey(&buf, "S-Return"));
    try t.expectEqualStrings("Escape", normalizeKey(&buf, "Escape"));

    // End to end: binding via the human form resolves under the canonical key
    // the platform emits at event time.
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.bind(gpa, "normal", "SPC :", "pick-commands", prio_config, "cfg");
    try t.expectEqualStrings("pick-commands", km.lookup("normal", "space colon").?);

    // displayKey is the inverse — which-key shows the config's notation back.
    try t.expectEqualStrings("SPC :", km.displayKey(&buf, "space colon"));
    try t.expectEqualStrings("SPC f f", km.displayKey(&buf, "space f f"));
    try t.expectEqualStrings("C-x C-f", km.displayKey(&buf, "C-x C-f"));
    try t.expectEqualStrings(":", km.displayKey(&buf, "colon")); // a lone segment
    try t.expectEqualStrings("f", km.displayKey(&buf, "f"));
    try t.expectEqualStrings("Escape", km.displayKey(&buf, "Escape"));
}

test "keymap: committing text is DECLARED per mode — bindings inherit, the declaration never does" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.bind(gpa, "insert", "C-s", "save", prio_core, "core");
    try km.setCommitCommand(gpa, "insert", "insert-text");
    // A structural mode inheriting an insert-flavored parent's BINDINGS.
    try km.setFallback(gpa, "structural", "insert");

    try t.expectEqualStrings("save", km.lookup("structural", "C-s").?); // bindings inherit
    try t.expectEqualStrings("insert-text", km.commitCommand("insert").?);
    try t.expect(km.commitCommand("structural") == null); // the authority does not
    try t.expect(km.commitCommand("never-declared") == null);

    // Withdrawing the declaration leaves the mode unable to commit.
    try km.setCommitCommand(gpa, "insert", null);
    try t.expect(km.commitCommand("insert") == null);
}

test "keymap: an arm list is stored whole, in authored order; a plain bind is its one-entry case" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.bindArms(gpa, "normal", "Return", &.{ "std.target.activate", "vim-open-focused" }, prio_plugin, "vim");
    const authored = km.resolveExactArms("normal", "Return").?;
    try t.expectEqual(@as(usize, 2), authored.len);
    try t.expectEqualStrings("std.target.activate", authored[0]);
    try t.expectEqualStrings("vim-open-focused", authored[1]);
    // The head is what a single-command reader sees — the keymap picks nothing.
    try t.expectEqualStrings("std.target.activate", km.lookup("normal", "Return").?);

    // Re-binding at a winning tier replaces the WHOLE list, fallbacks included.
    try km.bind(gpa, "normal", "Return", "insert-newline", prio_config, "config");
    const rebound = km.resolveExactArms("normal", "Return").?;
    try t.expectEqual(@as(usize, 1), rebound.len);
    try t.expectEqualStrings("insert-newline", rebound[0]);

    // A lower tier cannot shadow it.
    try km.bindArms(gpa, "normal", "Return", &.{"std.target.activate"}, prio_core, "core");
    try t.expectEqualStrings("insert-newline", km.lookup("normal", "Return").?);
}
