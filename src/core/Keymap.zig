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
const BindingFacet = @import("weft_input").BindingFacet;

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
const GroupEntry = struct { name: []u8, priority: i32, owner: []u8 };

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
/// declares one COMMITS TEXT — insert-flavored modes name `edit.insert-text`, a
/// picker names its query-append command. Never inherited (see
/// `commitCommand`): a mode that does not declare one cannot commit,
/// whatever it inherits BINDINGS from.
commit_commands: std.StringArrayHashMapUnmanaged([]u8) = .empty,
/// `mode\x00tag` → the mode carries that tag. ONE set for every property a
/// mode can have, because they were three identical sets before this
/// (`menu_modes`, `sticky_menus`, `resting_modes`) and a fourth property would
/// have been a fourth. A tag is DATA: core defines no vocabulary beyond the
/// three names below that its own lookup wiring needs, and a plugin can invent
/// a tag and read it back without core learning anything.
///
/// What each tag means is the reader's business, not this file's:
///   `menu`    — a prefix menu (leader/chord table). which-key lists it; the
///               fallback chain into `menu` → `menu-nav` is wired by `tagMode`.
///               WHICH mode a head returns to on leaving is head-scoped state
///               (two heads can enter one menu from different origins) — see
///               `Head.menu_return`.
///   `sticky`  — stays open after a leaf key instead of auto-popping (the
///               flag-accumulating transients: git's push/fetch option popups).
///   `resting` — a mode a buffer SETTLES in: the base editing mode and each
///               tool projection. `baseMode` stops at the first of these in a
///               fallback chain, so leaving a buffer remembers its resting mode
///               instead of overshooting to `default` and stranding a revisited
///               file in a mode with no editing keys.
mode_tags: std.StringArrayHashMapUnmanaged(void) = .empty,
/// `(mode, prefix)` → the display name for an implicit chord group. This is
/// presentation metadata, but it follows the same tier/owner rules as a bind
/// so imported defaults cannot overwrite a config author's label.
group_names: std.StringArrayHashMapUnmanaged(GroupEntry) = .empty,
/// `mode\x00facet` → the mode a key is looked up in while the head is in
/// `mode` and the entry has that facet (`BindingFacet`). A grammar's
/// declaration, like `parents`: vim says its `normal` binds through
/// `normal-source` in a document, helix says `helix-normal` binds through
/// `helix-source`. Core pairs the facet with the mode and names neither.
variants: std.StringArrayHashMapUnmanaged([]u8) = .empty,

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
    for (self.mode_tags.keys()) |k| gpa.free(k);
    self.mode_tags.deinit(gpa);
    for (self.group_names.keys(), self.group_names.values()) |k, v| {
        gpa.free(k);
        gpa.free(v.name);
        gpa.free(v.owner);
    }
    self.group_names.deinit(gpa);
    for (self.variants.keys(), self.variants.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    self.variants.deinit(gpa);
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

/// Name an implicit chord group. `prefix` is the complete key sequence that
/// opens it (`SPC f`, not just `f`). The name is display-only; dispatch still
/// follows the actual chord table. A lower tier cannot replace a higher one.
pub fn setGroupName(self: *Keymap, gpa: Allocator, mode: []const u8, prefix: []const u8, name: []const u8, priority: i32, owner: []const u8) Allocator.Error!void {
    var keybuf: [512]u8 = undefined;
    const group_key = groupKey(&keybuf, mode, prefix) orelse return;
    if (self.group_names.get(group_key)) |current| if (priority < current.priority) return;
    const gop = try self.group_names.getOrPut(gpa, group_key);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.name);
        gpa.free(gop.value_ptr.owner);
    } else {
        gop.key_ptr.* = try gpa.dupe(u8, group_key);
    }
    gop.value_ptr.* = .{
        .name = try gpa.dupe(u8, name),
        .priority = priority,
        .owner = try gpa.dupe(u8, owner),
    };
}

/// Remove a group label only when its owner still holds it. Used by manifest
/// reconciliation, just like `unbind` for the actual key binding.
pub fn unsetGroupName(self: *Keymap, gpa: Allocator, mode: []const u8, prefix: []const u8, owner: []const u8) void {
    var keybuf: [512]u8 = undefined;
    const group_key = groupKey(&keybuf, mode, prefix) orelse return;
    const entry = self.group_names.get(group_key) orelse return;
    if (!std.mem.eql(u8, entry.owner, owner)) return;
    if (self.group_names.fetchSwapRemove(group_key)) |removed| {
        gpa.free(removed.key);
        gpa.free(removed.value.name);
        gpa.free(removed.value.owner);
    }
}

/// The nearest label in the mode's fallback chain, then the universal layer.
/// The returned name is keymap-owned and remains valid until the next group
/// metadata mutation.
pub fn groupName(self: *const Keymap, mode: []const u8, prefix: []const u8) ?[]const u8 {
    var m: []const u8 = mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        var local_buf: [512]u8 = undefined;
        if (groupKey(&local_buf, m, prefix)) |local_key|
            if (self.group_names.get(local_key)) |entry| return entry.name;
        m = self.parents.get(m) orelse break;
    }
    var global_buf: [512]u8 = undefined;
    if (groupKey(&global_buf, global_mode, prefix)) |global_key|
        if (self.group_names.get(global_key)) |entry| return entry.name;
    return null;
}

fn groupKey(buf: []u8, mode: []const u8, prefix: []const u8) ?[]const u8 {
    var normalized_buf: [256]u8 = undefined;
    const normalized = normalizeKey(&normalized_buf, prefix);
    if (mode.len + 1 + normalized.len > buf.len) return null;
    @memcpy(buf[0..mode.len], mode);
    buf[mode.len] = 0;
    @memcpy(buf[mode.len + 1 ..][0..normalized.len], normalized);
    return buf[0 .. mode.len + 1 + normalized.len];
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

/// DECLARE that while the head is in `mode`, an entry with `facet` looks its
/// keys up in `variant`. The variant is an ordinary mode: what it falls back
/// to is the declarer's own `setFallback`. Re-declaring replaces.
pub fn declareVariant(self: *Keymap, gpa: Allocator, mode: []const u8, facet: BindingFacet, variant: []const u8) Allocator.Error!void {
    var buf: [256]u8 = undefined;
    const key = tagKey(&buf, mode, @tagName(facet)) orelse return;
    const gop = try self.variants.getOrPut(gpa, key);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try gpa.dupe(u8, key);
    }
    gop.value_ptr.* = try gpa.dupe(u8, variant);
}

/// The mode `mode` binds through for `facet`, or null where nobody declared
/// one — the caller then binds `mode` itself.
pub fn variantFor(self: *const Keymap, mode: []const u8, facet: BindingFacet) ?[]const u8 {
    var buf: [256]u8 = undefined;
    const key = tagKey(&buf, mode, @tagName(facet)) orelse return null;
    return self.variants.get(key);
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
        if (self.modeHasTag(cur, tag_menu)) return cur;
        // A RESTING mode is a buffer's base: `normal` and each tool projection
        // (files/grep/output/git). Stop here so a transient mode (visual/
        // insert) resolves to its editing base while a tool buffer keeps its own
        // mode — WITHOUT overshooting `normal`→`default` to the root, which would
        // strand a revisited file in the editing-less `default` mode.
        if (self.modeHasTag(cur, tag_resting)) return cur;
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
/// plugin/config re-wires it. Mid-chord, dispatch consults this via `navBindings`
/// before feeding the key into the sequence: a nav key pages the hint and leaves
/// `pending` intact; anything else extends (or ends) the chord as usual. (It's
/// also the fallback base a legacy menu MODE inherits — same keys, both worlds.)
pub const menu_nav_mode = "menu-nav";

/// The complete binding arms for `key` in the hint navigation layer.
/// Dispatch resolves these through the same action chain as ordinary keys.
pub fn navBindings(self: *const Keymap, key: []const u8) ?[]const []const u8 {
    const b = self.modes.getPtr(menu_nav_mode) orelse return null;
    return if (b.get(key)) |e| e.commands else null;
}

/// The layer every menu inherits for keys it answers ORDINARILY — the ones
/// that end a chord rather than acting on the hint mid-flight.
///
/// Split from `menu_nav_mode` because those are two jobs, and one layer doing
/// both is a trap: `navBindings` deliberately PRESERVES `pending`, so a key that
/// is supposed to abandon the chord (Escape) silently becomes a key that pages
/// the hint and leaves you mid-chord. Core owns the chain — a menu falls back
/// to `menu`, and `menu` falls back to `menu-nav` — and owns nothing about
/// which keys ride either layer; `config/defaults.js` binds both.
pub const menu_mode = "menu";

/// The tag a MENU carries. Core knows this string for exactly one reason —
/// `tagMode` wires the `menu` → `menu-nav` fallback chain, which is structure,
/// not policy. Everything else about menus (which keys leave one, what a menu
/// looks like, whether which-key lists it) is the caller's.
pub const tag_menu = "menu";
/// A menu that stays open after a leaf key instead of auto-popping — the
/// flag-accumulating transients. Read by dispatch; core never sets it.
pub const tag_sticky = "sticky";
/// A mode a buffer SETTLES in (see `baseMode`) — the declaration that stops
/// "wrong mode in a tool buffer" jank.
pub const tag_resting = "resting";

/// Tag `mode` with a named property. Idempotent.
///
/// One set, not three. This was `menu_modes`, `sticky_menus` and
/// `resting_modes` — three `StringArrayHashMap`s, three `markX`/`isX` pairs,
/// three dupe-and-free blocks in `deinit`, all spelling the same idea. Every
/// new property of a mode meant another one, which is to say every new property
/// meant editing core. Now a tag is data: a plugin can invent one and read it
/// back, and core learns nothing.
///
/// The one behaviour that stays here is the `menu` fallback chain, because it
/// is about how LOOKUP works and lookup is core's: a menu inherits `menu`, and
/// `menu` inherits `menu-nav`. What binds on either layer is config's.
pub fn tagMode(self: *Keymap, gpa: Allocator, mode: []const u8, tag: []const u8) Allocator.Error!void {
    var buf: [256]u8 = undefined;
    const key = tagKey(&buf, mode, tag) orelse return;
    const gop = try self.mode_tags.getOrPut(gpa, key);
    if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, key);

    if (std.mem.eql(u8, tag, tag_menu)) {
        if (!self.parents.contains(menu_mode))
            try self.setFallback(gpa, menu_mode, menu_nav_mode);
        if (!std.mem.eql(u8, mode, menu_nav_mode) and !std.mem.eql(u8, mode, menu_mode) and
            !self.parents.contains(mode))
            try self.setFallback(gpa, mode, menu_mode);
    }
}

/// Whether `mode` carries `tag`.
pub fn modeHasTag(self: *const Keymap, mode: []const u8, tag: []const u8) bool {
    var buf: [256]u8 = undefined;
    const key = tagKey(&buf, mode, tag) orelse return false;
    return self.mode_tags.contains(key);
}

/// `mode\x00tag` — NUL-joined so no mode name can spell another pair (a
/// separator that cannot occur in either half is what makes the flat set safe).
fn tagKey(buf: []u8, mode: []const u8, tag: []const u8) ?[]const u8 {
    if (mode.len + 1 + tag.len > buf.len) return null;
    @memcpy(buf[0..mode.len], mode);
    buf[mode.len] = 0;
    @memcpy(buf[mode.len + 1 ..][0..tag.len], tag);
    return buf[0 .. mode.len + 1 + tag.len];
}

/// Whether ANY mode carries `tag`. A keymap with no `resting` declaration has
/// no opinion about where an entry rests, so a caller keeps its own answer
/// rather than substituting one this table never made — and the same question
/// is worth asking of any tag, so it is asked generically.
pub fn anyModeHasTag(self: *const Keymap, tag: []const u8) bool {
    for (self.mode_tags.keys()) |k| {
        const sep = std.mem.indexOfScalar(u8, k, 0) orelse continue;
        if (std.mem.eql(u8, k[sep + 1 ..], tag)) return true;
    }
    return false;
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
        try out_group.append(gpa, self.modeHasTag(v.commands[0], tag_menu));
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
            var full_prefix_buf: [256]u8 = undefined;
            const full_prefix = if (prefix.len == 0)
                seg
            else
                std.fmt.bufPrint(&full_prefix_buf, "{s} {s}", .{ prefix, seg }) catch "";
            const group_label = if (is_leaf) null else self.groupName(mode, full_prefix);
            try out.append(gpa, .{
                .key = seg,
                .command = if (is_leaf) v.commands[0] else group_label orelse "+prefix",
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
/// token: leading `C-`/`M-`/`S-` modifier prefixes are re-emitted in the
/// `C-M-S-` order `keyspec` composes at event time (so `S-C-x` and `C-S-x`
/// bind the same key), then the base maps via `baseName`. Falls back to the
/// raw input if it doesn't fit.
///
/// Pointer gestures (`mouse-1`, `S-double-mouse-1`, `C-wheel-up`, …; the
/// grammar is `pointer.zig`'s) are ordinary bases here: they carry no
/// punctuation or alias, so they pass through with their modifiers ordered.
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
        var mods: [3]bool = .{ false, false, false };
        while (base.len >= 2 and base[1] == '-' and (base[0] == 'C' or base[0] == 'M' or base[0] == 'S')) {
            mods[std.mem.indexOfScalar(u8, "CMS", base[0]).?] = true;
            base = base[2..];
        }
        for (mods, "CMS") |on, m| if (on) {
            if (w + 2 > buf.len) return key;
            buf[w] = m;
            buf[w + 1] = '-';
            w += 2;
        };
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
    try km.bind(gpa, "normal", "C-s", "file.save", prio_plugin, "vim");
    try km.bind(gpa, "insert", "Escape", "enter-normal", prio_plugin, "vim");

    try t.expectEqualStrings("enter-insert", km.lookup("normal", "i").?);
    try t.expectEqualStrings("file.save", km.lookup("normal", "C-s").?);
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
    try a.bind(gpa, "default", "j", "cursor.down", prio_core, "core");
    try a.bind(gpa, "default", "j", "motions.down", prio_plugin, "vim");
    try a.bind(gpa, "default", "j", "my-thing", prio_config, "config");
    try t.expectEqualStrings("my-thing", a.lookup("default", "j").?);

    // Same binds in the OPPOSITE order resolve identically — a lower tier can
    // never displace a higher one, so the result is a pure function of the set.
    var b: Keymap = .empty;
    defer b.deinit(gpa);
    try b.bind(gpa, "default", "j", "my-thing", prio_config, "config");
    try b.bind(gpa, "default", "j", "motions.down", prio_plugin, "vim");
    try b.bind(gpa, "default", "j", "cursor.down", prio_core, "core");
    try t.expectEqualStrings("my-thing", b.lookup("default", "j").?);
}

test "keymap: unbind removes only if the owner still matches; no-op otherwise" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.bind(gpa, "normal", "j", "cursor.down", prio_imported, "import:defaults");
    try t.expectEqualStrings("cursor.down", km.lookup("normal", "j").?);

    // A different owner can't steal-then-unbind the slot out from under it.
    km.unbind(gpa, "normal", "j", "someone-else");
    try t.expectEqualStrings("cursor.down", km.lookup("normal", "j").?);

    // A higher tier has since taken the slot — unbinding the ORIGINAL owner
    // must not remove the newer binding.
    try km.bind(gpa, "normal", "j", "my-thing", prio_config, "config");
    km.unbind(gpa, "normal", "j", "import:defaults");
    try t.expectEqualStrings("my-thing", km.lookup("normal", "j").?);

    // The rightful owner unbinds cleanly.
    try km.bind(gpa, "normal", "k", "cursor.up", prio_imported, "import:defaults");
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
    try km.bind(gpa, "leader", "f", "files.find", prio_plugin, "vim");
    try km.bind(gpa, "leader", "c", "collab", prio_plugin, "vim");

    // which-key shows only for modes the config declared as menus.
    try t.expect(!km.modeHasTag("leader", tag_menu)); // not declared yet
    try km.tagMode(gpa, "leader", tag_menu);
    try t.expect(km.modeHasTag("leader", tag_menu));
    try t.expect(!km.modeHasTag("normal", tag_menu)); // never declared
    try t.expect(!km.modeHasTag("nope", tag_menu));

    var hints: std.ArrayList(Binding) = .empty;
    defer hints.deinit(gpa);
    try km.ownBindings(gpa, "leader", &hints);
    try t.expectEqual(@as(usize, 2), hints.items.len);
    try t.expectEqualStrings("f", hints.items[0].key);
    try t.expectEqualStrings("files.find", hints.items[0].command);
}

test "keymap: sticky menus stay open (implies menu-mode)" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try t.expect(!km.modeHasTag("git-flag-menu", tag_sticky));
    try km.tagMode(gpa, "git-flag-menu", tag_sticky);
    try t.expect(km.modeHasTag("git-flag-menu", tag_sticky));
    // Tags are INDEPENDENT. `markStickyMenu` used to imply menu-ness from
    // inside the keymap; that implication is the declarer's opinion, so it now
    // lives at the door that declares a sticky menu (`hStickyMenu` tags both).
    try t.expect(!km.modeHasTag("git-flag-menu", tag_menu));
    // A plain menu isn't sticky — it still one-shot auto-pops.
    try km.tagMode(gpa, "leader", tag_menu);
    try t.expect(!km.modeHasTag("leader", tag_sticky));
}

test "keymap: the global layer applies under every mode, overridable locally" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    // F1 bound only in the global layer (config's which-key key).
    try km.bind(gpa, Keymap.global_mode, "F1", "which-key.show", prio_plugin, "cfg");
    try km.bind(gpa, "normal", "i", "insert", prio_plugin, "vim");

    // In normal (which has no F1 of its own) F1 falls through to global.
    try t.expectEqualStrings("which-key.show", km.lookup("normal", "F1").?);
    // In a standalone tool mode with NO fallback chain, F1 still works —
    // that's the whole point (before, tool modes were islands).
    try t.expectEqualStrings("which-key.show", km.lookup("tool", "F1").?);
    // A mode still overrides a global key by binding it locally.
    try km.bind(gpa, "tool", "F1", "tool-help", prio_plugin, "tool");
    try t.expectEqualStrings("tool-help", km.lookup("tool", "F1").?);
}

test "keymap: a menu inherits the menu-nav base for nav keys; baseMode stops at the menu" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    // The nav base's keys are config data (here: Backspace pops a level).
    try km.bind(gpa, Keymap.menu_nav_mode, "BackSpace", "mode.leave-menu", prio_config, "cfg");
    try km.bind(gpa, Keymap.menu_nav_mode, "PageDown", "which-key.page-down", prio_config, "cfg");

    // Declaring a menu auto-wires it to inherit menu-nav (no per-config wiring),
    // so its nav keys resolve through the fallback — but its OWN keys still win.
    try km.tagMode(gpa, "leader", tag_menu);
    try km.bind(gpa, "leader", "f", "leader-file", prio_config, "cfg");
    try t.expectEqualStrings("leader-file", km.lookup("leader", "f").?); // own key
    try t.expectEqualStrings("mode.leave-menu", km.lookup("leader", "BackSpace").?); // inherited nav
    try t.expectEqualStrings("which-key.page-down", km.lookup("leader", "PageDown").?);

    // baseMode stops at the menu (a buffer is never remembered as a menu, nor as
    // the menu-nav base it falls back to) — so switchTo's menu-skip stays correct.
    try t.expectEqualStrings("leader", km.baseMode("leader"));
    try t.expect(!km.parents.contains(Keymap.menu_nav_mode)); // the base itself has no fallback

    // A menu that already has its own fallback is left alone (not re-wired).
    try km.setFallback(gpa, "leader-git", "leader");
    try km.tagMode(gpa, "leader-git", tag_menu);
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
    try km.bind(gpa, "normal", "SPC :", "palette.open", prio_config, "cfg");
    try t.expectEqualStrings("palette.open", km.lookup("normal", "space colon").?);

    // displayKey is the inverse — which-key shows the config's notation back.
    try t.expectEqualStrings("SPC :", km.displayKey(&buf, "space colon"));
    try t.expectEqualStrings("SPC f f", km.displayKey(&buf, "space f f"));
    try t.expectEqualStrings("C-x C-f", km.displayKey(&buf, "C-x C-f"));
    try t.expectEqualStrings(":", km.displayKey(&buf, "colon")); // a lone segment
    try t.expectEqualStrings("f", km.displayKey(&buf, "f"));
    try t.expectEqualStrings("Escape", km.displayKey(&buf, "Escape"));
}

test "keymap: modifiers canonicalize to C-M-S- order, pointer gestures pass through" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("C-S-x", normalizeKey(&buf, "S-C-x"));
    try t.expectEqualStrings("C-M-S-Tab", normalizeKey(&buf, "S-M-C-TAB"));
    try t.expectEqualStrings("C-minus", normalizeKey(&buf, "C--"));

    // The pointer grammar (`pointer.zig`): gestures are plain bases.
    try t.expectEqualStrings("mouse-1", normalizeKey(&buf, "mouse-1"));
    try t.expectEqualStrings("S-mouse-1", normalizeKey(&buf, "S-mouse-1"));
    try t.expectEqualStrings("C-S-double-mouse-1", normalizeKey(&buf, "S-C-double-mouse-1"));
    try t.expectEqualStrings("triple-mouse-3", normalizeKey(&buf, "triple-mouse-3"));
    try t.expectEqualStrings("drag-mouse-1", normalizeKey(&buf, "drag-mouse-1"));
    try t.expectEqualStrings("C-wheel-up", normalizeKey(&buf, "C-wheel-up"));

    // And they compose exactly as the shell spells them at event time, so a
    // config's `S-C-mouse-1` answers a ctrl+shift click.
    var ev: [32]u8 = undefined;
    const spec = keyspec(&ev, true, false, true, "mouse-1");
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.bind(gpa, global_mode, "S-C-mouse-1", "pointer.extend-selection", prio_config, "cfg");
    try t.expectEqualStrings("pointer.extend-selection", km.lookup("normal", spec).?);
    // A pointer chord is a sequence like any other.
    try km.bind(gpa, "normal", "SPC mouse-3", "menu-at-point", prio_config, "cfg");
    try t.expectEqualStrings("menu-at-point", km.resolveExact("normal", "space mouse-3").?);
}

test "keymap: committing text is DECLARED per mode — bindings inherit, the declaration never does" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.bind(gpa, "insert", "C-s", "file.save", prio_core, "core");
    try km.setCommitCommand(gpa, "insert", "edit.insert-text");
    // A structural mode inheriting an insert-flavored parent's BINDINGS.
    try km.setFallback(gpa, "structural", "insert");

    try t.expectEqualStrings("file.save", km.lookup("structural", "C-s").?); // bindings inherit
    try t.expectEqualStrings("edit.insert-text", km.commitCommand("insert").?);
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

    try km.bindArms(gpa, "normal", "Return", &.{ "std.target.activate", "vim.next-line" }, prio_plugin, "vim");
    const authored = km.resolveExactArms("normal", "Return").?;
    try t.expectEqual(@as(usize, 2), authored.len);
    try t.expectEqualStrings("std.target.activate", authored[0]);
    try t.expectEqualStrings("vim.next-line", authored[1]);
    // The head is what a single-command reader sees — the keymap picks nothing.
    try t.expectEqualStrings("std.target.activate", km.lookup("normal", "Return").?);

    // Re-binding at a winning tier replaces the WHOLE list, fallbacks included.
    try km.bind(gpa, "normal", "Return", "edit.insert-newline", prio_config, "config");
    const rebound = km.resolveExactArms("normal", "Return").?;
    try t.expectEqual(@as(usize, 1), rebound.len);
    try t.expectEqualStrings("edit.insert-newline", rebound[0]);

    // A lower tier cannot shadow it.
    try km.bindArms(gpa, "normal", "Return", &.{"std.target.activate"}, prio_core, "core");
    try t.expectEqualStrings("edit.insert-newline", km.lookup("normal", "Return").?);
}
