//! Keymap — modal key → command-name tables. Pure string domain: a
//! keyspec is `[C-][M-][S-]<xkb keysym name>`. Shift usually lives in
//! the keysym (`a` vs `A`); the explicit `S-` is only for keys with no
//! shifted keysym — `S-Return`, `S-Tab` (specials keep their names —
//! `Escape`, `Tab`, `Return`).
//! The platform layer translates its events into keyspecs; the keymap
//! neither knows xkb nor the commands it names (late binding — a bind
//! may name a command a plugin provides later).
//!
//! Modes are the vim enabler: bindings live per mode, `mode` selects
//! the active table, and mode switching is itself just a command.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Keymap = @This();

/// A key's winning binding + the (priority, owner) that won it. Layering
/// ([FIX 9]): a bind only takes the slot when its priority ≥ the incumbent's,
/// so the resolved keymap is a pure function of the declaration set — never
/// load-order-dependent. Precedence tiers: core defaults (−100) < plugins (0)
/// < user config (100).
const BindEntry = struct { command: []u8, priority: i32, owner: []u8 };
const Bindings = std.StringArrayHashMapUnmanaged(BindEntry);

pub const prio_core = -100;
pub const prio_plugin = 0;
pub const prio_config = 100;

modes: std.StringArrayHashMapUnmanaged(Bindings) = .empty,
mode: []u8 = &.{},
/// The pending key SEQUENCE (keyspecs joined by spaces) — the chord you're
/// partway through: `space f` while `space f f` → find-file is being typed.
/// Empty at rest. A binding's KEY is a whole sequence (a single key is a
/// one-element sequence), so a "menu" is just a prefix of longer sequences —
/// NOT a mode. `feed` drives it; which-key shows the completions of the pending
/// prefix. Cleared on a completed binding, a dead end, Escape, or a mode/buffer
/// switch.
pending: []u8 = &.{},
/// Scratch for `resolveBindings`/`completions` — the deduplicated set of
/// bindings (or chord completions) reachable in a mode. Borrowed slices into
/// `modes`, valid until the next keymap mutation. Rebuilt each call (which-key
/// render). `resolved_group` parallels it: whether each entry opens a submenu /
/// continues a chord (a GROUP) rather than being a runnable LEAF.
resolved: std.ArrayList(Binding) = .empty,
resolved_group: std.ArrayList(bool) = .empty,
/// mode → parent mode: `lookup` walks the chain (vim's visual falls
/// back to normal falls back to default).
parents: std.StringArrayHashMapUnmanaged([]u8) = .empty,
/// mode → command run for unbound printable input (one string arg).
/// Unset modes swallow text — vim's normal mode is exactly "no text
/// command"; insert-flavored modes set "insert-text"; a picker sets
/// its query-append command.
text_commands: std.StringArrayHashMapUnmanaged([]u8) = .empty,
/// Modes the config declared as prefix menus (leader/chord tables) — the
/// which-key hint shows their bindings. Policy lives in config; this is
/// just the mechanism that remembers the declaration.
menu_modes: std.StringArrayHashMapUnmanaged(void) = .empty,
/// menu mode → the mode to return to when a one-shot menu key fires. Distinct
/// from `parents` (the key-lookup fallback chain): a menu's return target is
/// where the *modal posture* goes after the menu closes, not where its unbound
/// keys fall through. Recorded only on GUEST-initiated menu entry (`enterMode`),
/// never on host-side save/restore (the picker), so the picker can't poison it.
/// Already resolved to the root non-menu mode at record time, so nested menus
/// (leader→leader-file) collapse to one hop back to normal.
menu_return: std.StringArrayHashMapUnmanaged([]u8) = .empty,
/// Menu modes that STAY OPEN after a leaf key (the one-shot auto-pop is
/// suppressed) — flag-accumulating transients (magit's push/fetch option
/// popups): toggle keys mutate state and re-render while the menu persists;
/// only an explicit mode change (execute, or Escape → the return target)
/// leaves. A subset of `menu_modes`, so which-key still lists the keys.
sticky_menus: std.StringArrayHashMapUnmanaged(void) = .empty,
/// Modes a READ-ONLY projection pins itself to (magit, a git diff/log view): a
/// `setMode` out of a locked mode is refused unless it targets a MENU (transient)
/// or the same mode — so you can never land in a generic editing mode (`normal`)
/// inside a projection, its keys dead. Buffer-SWITCH mode changes bypass the gate
/// (they go through Buffers.switchTo, not the guest/builtin setMode door).
locked_modes: std.StringArrayHashMapUnmanaged(void) = .empty,

/// Modes a buffer can REST in — the base editing mode (`normal`) and each tool
/// projection (`dired`, `grep`, `output`, `emacs`, `helix-normal`). `baseMode`
/// stops at the first of these in a mode's fallback chain, so leaving a buffer
/// remembers its resting mode rather than overshooting to the root `default`
/// (which would strand a revisited file in a mode with no editing keys). Locked
/// modes are implicitly resting. Transient modes (visual/insert/op-pending/…) are
/// NOT declared, so they resolve through to their base editing mode.
resting_modes: std.StringArrayHashMapUnmanaged(void) = .empty,

pub const empty: Keymap = .{};

pub fn deinit(self: *Keymap, gpa: Allocator) void {
    for (self.modes.keys(), self.modes.values()) |mode_name, *bindings| {
        gpa.free(mode_name);
        for (bindings.keys(), bindings.values()) |k, v| {
            gpa.free(k);
            gpa.free(v.command);
            gpa.free(v.owner);
        }
        bindings.deinit(gpa);
    }
    self.modes.deinit(gpa);
    self.resolved.deinit(gpa);
    self.resolved_group.deinit(gpa);
    for (self.parents.keys(), self.parents.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    self.parents.deinit(gpa);
    for (self.text_commands.keys(), self.text_commands.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    self.text_commands.deinit(gpa);
    for (self.menu_modes.keys()) |k| gpa.free(k);
    self.menu_modes.deinit(gpa);
    for (self.sticky_menus.keys()) |k| gpa.free(k);
    self.sticky_menus.deinit(gpa);
    for (self.locked_modes.keys()) |k| gpa.free(k);
    self.locked_modes.deinit(gpa);
    for (self.resting_modes.keys()) |k| gpa.free(k);
    self.resting_modes.deinit(gpa);
    for (self.menu_return.keys(), self.menu_return.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    self.menu_return.deinit(gpa);
    gpa.free(self.mode);
    gpa.free(self.pending);
    self.* = .{};
}

/// Bind `keyspec` to `command` in `mode` at `priority`, owned by `owner`
/// (the binder — a plugin name, "config", or "core"). The binding takes the
/// slot only when its priority ≥ the current holder's, so a higher tier
/// (config > plugin > core) always wins regardless of bind order. An
/// equal-priority bind from a *different* owner is a collision — surfaced as a
/// warning; last one wins.
pub fn bind(self: *Keymap, gpa: Allocator, mode: []const u8, key_in: []const u8, command: []const u8, priority: i32, owner: []const u8) Allocator.Error!void {
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
        gpa.free(cur.command);
        gpa.free(cur.owner);
    } else {
        bgop.key_ptr.* = try gpa.dupe(u8, key);
    }
    bgop.value_ptr.* = .{
        .command = try gpa.dupe(u8, command),
        .priority = priority,
        .owner = try gpa.dupe(u8, owner),
    };
}

/// The reserved layer consulted under EVERY mode, after its own fallback
/// chain — so a truly universal key (which-key on F1, the C-w window prefix)
/// works everywhere without being duplicated into each mode (or leaking a whole
/// mode's bindings in via a fallback). A mode still overrides a global key by
/// binding it locally; global is never a fallback target, only the final check.
pub const global_mode = "global";

/// The command bound to `keyspec` in the current mode or its fallback
/// chain, then the `global` layer, if any.
pub fn lookup(self: *const Keymap, key: []const u8) ?[]const u8 {
    var mode: []const u8 = self.mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (self.modes.getPtr(mode)) |bindings| {
            if (bindings.get(key)) |entry| return entry.command;
        }
        mode = self.parents.get(mode) orelse break;
    }
    // Universal fallback: `global` binds apply under every mode.
    if (self.modes.getPtr(global_mode)) |bindings| {
        if (bindings.get(key)) |entry| return entry.command;
    }
    return null;
}

/// What feeding a key produced (see `feed`).
pub const Feed = union(enum) {
    run: []const u8, // a full sequence resolved — run this command (borrowed)
    pending, // extended the pending chord — which-key shows its completions
    text, // a lone unbound key — the caller inserts it (if printable)
    none, // a dead-end chord — reset, nothing to do
};

/// The command a full SEQUENCE resolves to: the mode's own table, its fallback
/// chain, then `global`. A single-key seq gets global's universal binds; a
/// multi-key chord effectively won't (global holds single keys), so a global key
/// never fires MID-sequence — `SPC C-w` is the chord `space C-w`, not global
/// `C-w`. (This is why menus-as-sequences dissolve the "global is too global".)
fn resolveExact(self: *const Keymap, seq: []const u8) ?[]const u8 {
    var mode: []const u8 = self.mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (self.modes.getPtr(mode)) |b| if (b.get(seq)) |e| return e.command;
        mode = self.parents.get(mode) orelse break;
    }
    if (self.modes.getPtr(global_mode)) |b| if (b.get(seq)) |e| return e.command;
    return null;
}

/// Whether `seq` is a strict PREFIX of some bound sequence in the current mode,
/// its fallback chain, or `global` (more keys would complete a chord). Global IS
/// consulted so a UNIVERSAL chord (`C-w s` window commands, bound in global) is
/// reachable from every mode — this does NOT re-widen "global too global",
/// because a match requires the WHOLE `seq` to be a literal prefix of a global
/// key: mid-chord `space C-w` never matches global's `C-w …` (they don't share a
/// start), so a global key only ever begins a sequence, never continues one.
fn isPrefix(self: *const Keymap, seq: []const u8) bool {
    var mode: []const u8 = self.mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (self.modes.getPtr(mode)) |b| if (prefixIn(b, seq)) return true;
        mode = self.parents.get(mode) orelse break;
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

/// Feed one keyspec through the pending sequence. A complete binding wins
/// immediately (configs don't bind a prefix as also complete); else, if the
/// chord could still extend, hold it `pending`; else it's a dead end — a lone
/// unbound key is `text` to insert, a broken chord just resets. NOTE: a `.run`
/// command name borrows the keymap — use it before any rebind.
pub fn feed(self: *Keymap, gpa: Allocator, key: []const u8) Allocator.Error!Feed {
    const at_top = self.pending.len == 0;
    const cand = if (at_top) key else try std.fmt.allocPrint(gpa, "{s} {s}", .{ self.pending, key });
    defer if (!at_top) gpa.free(cand);

    if (self.resolveExact(cand)) |cmd| {
        try self.setPending(gpa, "");
        return .{ .run = cmd };
    }
    if (self.isPrefix(cand)) {
        try self.setPending(gpa, cand);
        return .pending;
    }
    try self.setPending(gpa, "");
    return if (at_top) .text else .none;
}

/// Set the pending sequence (owned copy); "" clears it (no allocation).
pub fn setPending(self: *Keymap, gpa: Allocator, seq: []const u8) Allocator.Error!void {
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
pub fn popPending(self: *Keymap, gpa: Allocator) Allocator.Error!void {
    if (self.pending.len == 0) return;
    const cut = std.mem.lastIndexOfScalar(u8, self.pending, ' ') orelse {
        try self.setPending(gpa, "");
        return;
    };
    try self.setPending(gpa, self.pending[0..cut]);
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
/// their base is `normal`; `magit`/`dired` have no parent, so they are their own
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
        // (dired/grep/output/magit). Stop here so a transient mode (visual/
        // insert) resolves to its editing base while a tool buffer keeps its own
        // mode — WITHOUT overshooting `normal`→`default` to the root, which would
        // strand a revisited file in the editing-less `default` mode.
        if (self.isRestingMode(cur)) return cur;
        cur = self.parents.get(cur) orelse return cur;
    }
    return cur;
}

/// Set the command unbound printable input runs in `mode`. `null`
/// records an *explicit* "swallow text" (the modal posture) — it stops
/// the fallback walk, so a normal mode inheriting bindings from an
/// insert-flavored parent does not inherit its text insertion.
pub fn setTextCommand(self: *Keymap, gpa: Allocator, mode: []const u8, cmd: ?[]const u8) Allocator.Error!void {
    const gop = try self.text_commands.getOrPut(gpa, mode);
    if (gop.found_existing) {
        gpa.free(gop.value_ptr.*);
    } else {
        gop.key_ptr.* = try gpa.dupe(u8, mode);
    }
    gop.value_ptr.* = try gpa.dupe(u8, cmd orelse "");
}

/// The current mode's text command (chain-walked like `lookup`; an
/// explicit none stops the walk).
pub fn textCommand(self: *const Keymap) ?[]const u8 {
    var mode: []const u8 = self.mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (self.text_commands.get(mode)) |cmd| {
            return if (cmd.len == 0) null else cmd;
        }
        mode = self.parents.get(mode) orelse return null;
    }
    return null;
}

pub fn setMode(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const owned = try gpa.dupe(u8, mode);
    gpa.free(self.mode);
    self.mode = owned;
    // A mode change abandons any half-typed chord (a stale `space f` must not
    // combine with the new mode's next key).
    try self.setPending(gpa, "");
}

/// Guest-initiated mode set. Identical to `setMode`, except that entering a
/// *menu* mode records its return target — the root non-menu mode we came from
/// — so a one-shot menu key can pop back (see `menuReturn`). Only guests route
/// through here; host-side mode save/restore (the picker) uses plain `setMode`,
/// so a restore-into-a-menu never records a bogus return target.
pub fn enterMode(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    if (self.isMenuMode(mode) and !std.mem.eql(u8, self.mode, mode)) {
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

/// The mode a one-shot key should pop `mode` back to (the root non-menu mode),
/// or null if `mode` isn't a menu with a recorded return target.
pub fn menuReturn(self: *const Keymap, mode: []const u8) ?[]const u8 {
    return self.menu_return.get(mode);
}

pub fn currentMode(self: *const Keymap) []const u8 {
    return self.mode;
}

pub const Binding = struct { key: []const u8, command: []const u8 };

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
    return if (b.get(key)) |e| e.command else null;
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

/// Declare `mode` a LOCKED projection mode (a read-only view: magit, a git diff/
/// log). See `locked_modes` + `mayLeaveLocked`.
pub fn markLockedMode(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const gop = try self.locked_modes.getOrPut(gpa, mode);
    if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, mode);
}

pub fn isLockedMode(self: *const Keymap, mode: []const u8) bool {
    return self.locked_modes.contains(mode);
}

/// Declare `mode` a RESTING mode — a mode a buffer settles in (see `resting_modes`
/// + `baseMode`). Idempotent.
pub fn markRestingMode(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const gop = try self.resting_modes.getOrPut(gpa, mode);
    if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, mode);
}

/// A resting mode is one explicitly declared, or any LOCKED projection (which is
/// always a buffer's resting mode).
pub fn isRestingMode(self: *const Keymap, mode: []const u8) bool {
    return self.resting_modes.contains(mode) or self.isLockedMode(mode);
}

/// Whether a within-buffer `setMode` to `target` is allowed from the CURRENT
/// mode: always, unless the current mode is LOCKED and `target` is a different
/// non-menu mode (which would drop a read-only projection into a generic editing
/// mode). The guest/builtin setMode doors consult this; buffer-switch does not.
pub fn mayLeaveLocked(self: *const Keymap, target: []const u8) bool {
    if (!self.isLockedMode(self.mode)) return true;
    return std.mem.eql(u8, target, self.mode) or self.isMenuMode(target);
}

/// Append `mode`'s own bindings (key → command) to `out`, in bind order.
/// For which-key: a leaf menu mode's whole table.
pub fn ownBindings(self: *const Keymap, gpa: Allocator, mode: []const u8, out: *std.ArrayList(Binding)) Allocator.Error!void {
    const b = self.modes.getPtr(mode) orelse return;
    for (b.keys(), b.values()) |k, v| try out.append(gpa, .{ .key = k, .command = v.command });
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
    return .{ .key = b.keys()[i], .command = b.values()[i].command };
}

/// Build the RESOLVED set of bindings AVAILABLE in `mode` into `self.resolved`
/// and return the count: the mode's own table, then each fallback parent, then
/// `global` — the FIRST binding of a key wins (a nearer mode's local override),
/// so each key appears once. This is "what can I press here", the same key set
/// `lookup` would resolve — so which-key shows the whole reachable context
/// (dired's nav keys AND the editing keys it inherits), not just one mode's own
/// table. Read back with `resolvedAt`; both are valid until the next keymap
/// mutation (the guest enumerates synchronously during its `on_menu`).
pub fn resolveBindings(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!usize {
    self.resolved.clearRetainingCapacity();
    self.resolved_group.clearRetainingCapacity();
    var m: []const u8 = mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        try self.addResolved(gpa, m);
        m = self.parents.get(m) orelse break;
    }
    try self.addResolved(gpa, global_mode);
    return self.resolved.items.len;
}

/// Append `mode`'s own bindings to `resolved`, skipping any key already present
/// (a nearer mode in the walk bound it — the override lookup honors). A binding
/// whose command names a menu mode is a GROUP (legacy menu-mode which-key).
fn addResolved(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const b = self.modes.getPtr(mode) orelse return;
    outer: for (b.keys(), b.values()) |k, v| {
        for (self.resolved.items) |existing| {
            if (std.mem.eql(u8, existing.key, k)) continue :outer;
        }
        try self.resolved.append(gpa, .{ .key = k, .command = v.command });
        try self.resolved_group.append(gpa, self.isMenuMode(v.command));
    }
}

/// Fill `resolved` (+ `resolved_group`) with the next-key CHOICES after
/// `prefix` — the pending chord ("" = top level, the F1 peek). Scans the current
/// mode + fallback chain (+ `global`, at top level only) for bindings whose key
/// extends `prefix` by ≥1 segment; the display key is the immediate NEXT segment.
/// Deduped by that segment (nearer mode / earlier bind wins). A segment is a LEAF
/// when `prefix seg` is itself a complete binding (its command is shown); a GROUP
/// when it only continues a chord (more keys follow — shown as a "+prefix"
/// label, `resolved_group` true). This is what which-key renders as you type a
/// chord: at `space`, the `f`/`g`/… choices; at `space f`, the file submenu's.
/// Read back with `resolvedAt` / `resolvedIsGroup`; valid until the next mutation.
pub fn completions(self: *Keymap, gpa: Allocator, prefix: []const u8) Allocator.Error!usize {
    self.resolved.clearRetainingCapacity();
    self.resolved_group.clearRetainingCapacity();
    var m: []const u8 = self.mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        try self.addCompletions(gpa, m, prefix);
        m = self.parents.get(m) orelse break;
    }
    // The universal layer is consulted too, so a global chord opener (`C-w`) is
    // offered from any mode. The prefix filter keeps it honest: mid-chord
    // (`space`) global's `C-w …` keys don't start with the prefix, so nothing
    // global leaks in — a global key only ever surfaces as a top-level choice.
    try self.addCompletions(gpa, global_mode, prefix);
    return self.resolved.items.len;
}

/// Append `mode`'s next-segment choices after `prefix` to `resolved`, deduped by
/// segment against what's there (a nearer mode already offered it).
fn addCompletions(self: *Keymap, gpa: Allocator, mode: []const u8, prefix: []const u8) Allocator.Error!void {
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
        for (self.resolved.items) |existing| {
            if (std.mem.eql(u8, existing.key, seg)) break; // already offered — dedup
        } else {
            try self.resolved.append(gpa, .{ .key = seg, .command = if (is_leaf) v.command else "+prefix" });
            try self.resolved_group.append(gpa, !is_leaf);
        }
    }
}

/// The `i`-th resolved binding from the last `resolveBindings`/`completions`.
pub fn resolvedAt(self: *const Keymap, i: usize) ?Binding {
    if (i >= self.resolved.items.len) return null;
    return self.resolved.items[i];
}

/// Whether the `i`-th resolved entry is a GROUP (opens a submenu / continues a
/// chord) rather than a runnable leaf — see `resolveBindings`/`completions`.
pub fn resolvedIsGroup(self: *const Keymap, i: usize) bool {
    if (i >= self.resolved_group.items.len) return false;
    return self.resolved_group.items[i];
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

    try km.setMode(gpa, "normal");
    try km.bind(gpa, "normal", "i", "enter-insert", prio_plugin, "vim");
    try km.bind(gpa, "normal", "C-s", "save", prio_plugin, "vim");
    try km.bind(gpa, "insert", "Escape", "enter-normal", prio_plugin, "vim");

    try t.expectEqualStrings("enter-insert", km.lookup("i").?);
    try t.expectEqualStrings("save", km.lookup("C-s").?);
    try t.expectEqual(@as(?[]const u8, null), km.lookup("Escape"));

    try km.setMode(gpa, "insert");
    try t.expectEqualStrings("enter-normal", km.lookup("Escape").?);
    try t.expectEqual(@as(?[]const u8, null), km.lookup("i"));

    // Same-owner rebinding replaces.
    try km.bind(gpa, "insert", "Escape", "custom-escape", prio_plugin, "vim");
    try t.expectEqualStrings("custom-escape", km.lookup("Escape").?);

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
    try a.setMode(gpa, "default");
    try t.expectEqualStrings("my-thing", a.lookup("j").?);

    // Same binds in the OPPOSITE order resolve identically — a lower tier can
    // never displace a higher one, so the result is a pure function of the set.
    var b: Keymap = .empty;
    defer b.deinit(gpa);
    try b.bind(gpa, "default", "j", "my-thing", prio_config, "config");
    try b.bind(gpa, "default", "j", "motion.down", prio_plugin, "vim");
    try b.bind(gpa, "default", "j", "cursor-down", prio_core, "core");
    try b.setMode(gpa, "default");
    try t.expectEqualStrings("my-thing", b.lookup("j").?);
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
    try km.setMode(gpa, "normal");
    try t.expectEqualStrings("which-key-now", km.lookup("F1").?);
    // In a standalone tool mode with NO fallback chain, F1 still works —
    // that's the whole point (before, tool modes were islands).
    try km.setMode(gpa, "dired");
    try t.expectEqualStrings("which-key-now", km.lookup("F1").?);
    // A mode still overrides a global key by binding it locally.
    try km.bind(gpa, "dired", "F1", "dired-help", prio_plugin, "dired");
    try t.expectEqualStrings("dired-help", km.lookup("F1").?);
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
    try km.setMode(gpa, "leader");
    try t.expectEqualStrings("leader-file", km.lookup("f").?); // own key
    try t.expectEqualStrings("menu-escape", km.lookup("BackSpace").?); // inherited nav
    try t.expectEqualStrings("which-key-page-down", km.lookup("PageDown").?);

    // baseMode stops at the menu (a buffer is never remembered as a menu, nor as
    // the menu-nav base it falls back to) — so switchTo's menu-skip stays correct.
    try t.expectEqualStrings("leader", km.baseMode("leader"));
    try t.expect(!km.parents.contains(Keymap.menu_nav_mode)); // the base itself has no fallback

    // A menu that already has its own fallback is left alone (not re-wired).
    try km.setFallback(gpa, "leader-git", "leader");
    try km.markMenuMode(gpa, "leader-git");
    try t.expectEqualStrings("leader", km.parents.get("leader-git").?);
}

test "keymap: a locked projection mode refuses to leave for an editing mode" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.markLockedMode(gpa, "magit");
    try km.markMenuMode(gpa, "git-branch-menu");

    try km.setMode(gpa, "magit");
    // From the locked projection you may NOT jump to a different editing mode
    // (the "normal-in-magit" leak) — that's now inexpressible...
    try t.expect(!km.mayLeaveLocked("normal"));
    try t.expect(!km.mayLeaveLocked("insert"));
    // ...but a menu (transient) and staying put are fine.
    try t.expect(km.mayLeaveLocked("git-branch-menu"));
    try t.expect(km.mayLeaveLocked("magit"));

    // From a menu (current mode not locked), returning to magit is allowed.
    try km.setMode(gpa, "git-branch-menu");
    try t.expect(km.mayLeaveLocked("magit"));
    // A non-locked mode never gates (ordinary editing).
    try km.setMode(gpa, "normal");
    try t.expect(km.mayLeaveLocked("insert"));
}

test "keymap: prefix sequences — a chord resolves; a menu is a prefix, not a mode" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.setMode(gpa, "normal");
    // A leader tree as SEQUENCES (no leader-* mode): SPC f f -> find-file, etc.
    try km.bind(gpa, "normal", "space f f", "find-file", prio_config, "cfg");
    try km.bind(gpa, "normal", "space g g", "git-status", prio_config, "cfg");
    try km.bind(gpa, "normal", "i", "vim-insert", prio_config, "vim");
    try km.bind(gpa, "global", "C-w", "window-thing", prio_config, "cfg");

    // A single bound key runs immediately.
    {
        const r = try km.feed(gpa, "i");
        try t.expect(r == .run);
        try t.expectEqualStrings("vim-insert", r.run);
        try t.expectEqual(@as(usize, 0), km.pending.len);
    }
    // SPC is a prefix -> pending; f -> still pending; f -> completes -> run.
    try t.expect((try km.feed(gpa, "space")) == .pending);
    try t.expectEqualStrings("space", km.pending);
    try t.expect((try km.feed(gpa, "f")) == .pending);
    try t.expectEqualStrings("space f", km.pending);
    {
        const r = try km.feed(gpa, "f");
        try t.expect(r == .run);
        try t.expectEqualStrings("find-file", r.run);
        try t.expectEqual(@as(usize, 0), km.pending.len);
    }
    // The "global is too global" fix falls out: SPC then C-w is the CHORD
    // `space C-w` (unbound) — NOT the global C-w. It resets, doesn't fire it.
    try t.expect((try km.feed(gpa, "space")) == .pending);
    try t.expect((try km.feed(gpa, "C-w")) == .none);
    try t.expectEqual(@as(usize, 0), km.pending.len);
    // C-w at the TOP (no pending) still hits global.
    {
        const r = try km.feed(gpa, "C-w");
        try t.expect(r == .run);
        try t.expectEqualStrings("window-thing", r.run);
    }
    // A lone unbound printable key is `text` (the caller inserts it).
    try t.expect((try km.feed(gpa, "x")) == .text);

    // Backspace pops one chord level.
    try t.expect((try km.feed(gpa, "space")) == .pending);
    try t.expect((try km.feed(gpa, "f")) == .pending);
    try km.popPending(gpa);
    try t.expectEqualStrings("space", km.pending);
}

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
    try km.setMode(gpa, "normal");
    try km.bind(gpa, "normal", "SPC :", "pick-commands", prio_config, "cfg");
    try t.expect((try km.feed(gpa, "space")) == .pending);
    try t.expectEqualStrings("pick-commands", (try km.feed(gpa, "colon")).run);

    // displayKey is the inverse — which-key shows the config's notation back.
    try t.expectEqualStrings("SPC :", km.displayKey(&buf, "space colon"));
    try t.expectEqualStrings("SPC f f", km.displayKey(&buf, "space f f"));
    try t.expectEqualStrings("C-x C-f", km.displayKey(&buf, "C-x C-f"));
    try t.expectEqualStrings(":", km.displayKey(&buf, "colon")); // a lone segment
    try t.expectEqualStrings("f", km.displayKey(&buf, "f"));
    try t.expectEqualStrings("Escape", km.displayKey(&buf, "Escape"));
}

test "keymap: completions — chord next-keys, leaf vs group, deduped, global at top" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);
    try km.setMode(gpa, "normal");
    // A leader tree as sequences: SPC f {f,r}, SPC g g; a plain top-level key.
    try km.bind(gpa, "normal", "space f f", "find-file", prio_config, "cfg");
    try km.bind(gpa, "normal", "space f r", "recent-files", prio_config, "cfg");
    try km.bind(gpa, "normal", "space g g", "git-status", prio_config, "cfg");
    try km.bind(gpa, "normal", "i", "vim-insert", prio_config, "vim");
    try km.bind(gpa, "global", "C-w", "window-thing", prio_config, "cfg");

    // Top level (empty prefix): the first segments, deduped. The three `space …`
    // binds collapse to ONE `space` group; `i` is a leaf; global `C-w` shows at
    // the top → {space, i, C-w} = 3.
    try t.expectEqual(@as(usize, 3), try km.completions(gpa, ""));
    // Build a name→(cmd,group) view to assert regardless of order.
    const Found = struct {
        fn get(k: *Keymap, key: []const u8) ?Binding {
            var i: usize = 0;
            while (i < k.resolved.items.len) : (i += 1) {
                if (std.mem.eql(u8, k.resolved.items[i].key, key)) return k.resolved.items[i];
            }
            return null;
        }
        fn group(k: *Keymap, key: []const u8) bool {
            var i: usize = 0;
            while (i < k.resolved.items.len) : (i += 1) {
                if (std.mem.eql(u8, k.resolved.items[i].key, key)) return k.resolvedIsGroup(i);
            }
            return false;
        }
    };
    _ = try km.completions(gpa, "");
    try t.expect(Found.get(&km, "space") != null);
    try t.expect(Found.group(&km, "space")); // continues a chord → group
    try t.expectEqualStrings("vim-insert", Found.get(&km, "i").?.command);
    try t.expect(!Found.group(&km, "i")); // runnable leaf
    try t.expectEqualStrings("window-thing", Found.get(&km, "C-w").?.command); // global at top
    // `space f f` and `space f r` collapse to ONE `space` group at the top.
    var space_count: usize = 0;
    for (km.resolved.items) |b| {
        if (std.mem.eql(u8, b.key, "space")) space_count += 1;
    }
    try t.expectEqual(@as(usize, 1), space_count);

    // After `space`: the file/git submenu keys `f` (group) and `g` (leaf-ish
    // group — `space g g`). Global does NOT appear mid-chord.
    {
        _ = try km.completions(gpa, "space");
        try t.expect(Found.get(&km, "f") != null);
        try t.expect(Found.group(&km, "f")); // space f {f,r} → still a group
        try t.expect(Found.get(&km, "g") != null);
        try t.expectEqual(@as(?Binding, null), Found.get(&km, "C-w")); // no global mid-chord
    }
    // After `space f`: the two leaves `f`→find-file, `r`→recent-files.
    {
        const n = try km.completions(gpa, "space f");
        try t.expectEqual(@as(usize, 2), n);
        try t.expectEqualStrings("find-file", Found.get(&km, "f").?.command);
        try t.expect(!Found.group(&km, "f")); // a leaf now
        try t.expectEqualStrings("recent-files", Found.get(&km, "r").?.command);
    }
}

test "keymap: menu return targets — guest entry records, nesting collapses to root" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.markMenuMode(gpa, "leader");
    try km.markMenuMode(gpa, "leader-file");
    try km.setMode(gpa, "normal");

    // Guest enters leader from normal → return target is normal.
    try km.enterMode(gpa, "leader");
    try t.expectEqualStrings("leader", km.currentMode());
    try t.expectEqualStrings("normal", km.menuReturn("leader").?);

    // Nested: enter leader-file from leader → collapses to the root (normal),
    // not one hop back to leader.
    try km.enterMode(gpa, "leader-file");
    try t.expectEqualStrings("normal", km.menuReturn("leader-file").?);

    // A non-menu mode has no return target.
    try t.expectEqual(@as(?[]const u8, null), km.menuReturn("normal"));
}

test "keymap: host-side setMode restore does NOT poison menu return targets" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.markMenuMode(gpa, "leader");
    try km.setMode(gpa, "normal");
    try km.enterMode(gpa, "leader"); // return target: normal

    // The picker saves prev="leader", sets "pick" (plain setMode, not a menu),
    // then on close restores "leader" via plain setMode. That restore must not
    // rewrite leader's return target to "pick".
    try km.setMode(gpa, "pick");
    try km.setMode(gpa, "leader");
    try t.expectEqualStrings("normal", km.menuReturn("leader").?);
}
