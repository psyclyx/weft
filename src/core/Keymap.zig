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
    for (self.menu_return.keys(), self.menu_return.values()) |k, v| {
        gpa.free(k);
        gpa.free(v);
    }
    self.menu_return.deinit(gpa);
    gpa.free(self.mode);
    self.* = .{};
}

/// Bind `keyspec` to `command` in `mode` at `priority`, owned by `owner`
/// (the binder — a plugin name, "config", or "core"). The binding takes the
/// slot only when its priority ≥ the current holder's, so a higher tier
/// (config > plugin > core) always wins regardless of bind order. An
/// equal-priority bind from a *different* owner is a collision — surfaced as a
/// warning; last one wins.
pub fn bind(self: *Keymap, gpa: Allocator, mode: []const u8, key: []const u8, command: []const u8, priority: i32, owner: []const u8) Allocator.Error!void {
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

/// The command bound to `keyspec` in the current mode or its fallback
/// chain, if any.
pub fn lookup(self: *const Keymap, key: []const u8) ?[]const u8 {
    var mode: []const u8 = self.mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (self.modes.getPtr(mode)) |bindings| {
            if (bindings.get(key)) |entry| return entry.command;
        }
        mode = self.parents.get(mode) orelse return null;
    }
    return null;
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

/// Declare `mode` a prefix menu (config policy — the leader/chord tables).
/// which-key shows its bindings while it is active.
pub fn markMenuMode(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const gop = try self.menu_modes.getOrPut(gpa, mode);
    if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, mode);
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
