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

const Bindings = std.StringArrayHashMapUnmanaged([]u8);

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

pub const empty: Keymap = .{};

pub fn deinit(self: *Keymap, gpa: Allocator) void {
    for (self.modes.keys(), self.modes.values()) |mode_name, *bindings| {
        gpa.free(mode_name);
        for (bindings.keys(), bindings.values()) |k, v| {
            gpa.free(k);
            gpa.free(v);
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
    gpa.free(self.mode);
    self.* = .{};
}

/// Bind `keyspec` to `command` in `mode` (created on first use).
/// Rebinding replaces — a config shadowing a built-in binding.
pub fn bind(self: *Keymap, gpa: Allocator, mode: []const u8, key: []const u8, command: []const u8) Allocator.Error!void {
    const gop = try self.modes.getOrPut(gpa, mode);
    if (!gop.found_existing) {
        gop.key_ptr.* = try gpa.dupe(u8, mode);
        gop.value_ptr.* = .empty;
    }
    const bgop = try gop.value_ptr.getOrPut(gpa, key);
    if (bgop.found_existing) {
        gpa.free(bgop.value_ptr.*);
    } else {
        bgop.key_ptr.* = try gpa.dupe(u8, key);
    }
    bgop.value_ptr.* = try gpa.dupe(u8, command);
}

/// The command bound to `keyspec` in the current mode or its fallback
/// chain, if any.
pub fn lookup(self: *const Keymap, key: []const u8) ?[]const u8 {
    var mode: []const u8 = self.mode;
    var depth: usize = 0;
    while (depth < 8) : (depth += 1) {
        if (self.modes.getPtr(mode)) |bindings| {
            if (bindings.get(key)) |cmd| return cmd;
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

/// Append `mode`'s own bindings (key → command) to `out`, in bind order.
/// For which-key: a leaf menu mode's whole table.
pub fn ownBindings(self: *const Keymap, gpa: Allocator, mode: []const u8, out: *std.ArrayList(Binding)) Allocator.Error!void {
    const b = self.modes.getPtr(mode) orelse return;
    for (b.keys(), b.values()) |k, v| try out.append(gpa, .{ .key = k, .command = v });
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
    try km.bind(gpa, "normal", "i", "enter-insert");
    try km.bind(gpa, "normal", "C-s", "save");
    try km.bind(gpa, "insert", "Escape", "enter-normal");

    try t.expectEqualStrings("enter-insert", km.lookup("i").?);
    try t.expectEqualStrings("save", km.lookup("C-s").?);
    try t.expectEqual(@as(?[]const u8, null), km.lookup("Escape"));

    try km.setMode(gpa, "insert");
    try t.expectEqualStrings("enter-normal", km.lookup("Escape").?);
    try t.expectEqual(@as(?[]const u8, null), km.lookup("i"));

    // Rebinding shadows.
    try km.bind(gpa, "insert", "Escape", "custom-escape");
    try t.expectEqualStrings("custom-escape", km.lookup("Escape").?);

    var buf: [32]u8 = undefined;
    try t.expectEqualStrings("C-M-x", keyspec(&buf, true, true, false, "x"));
    try t.expectEqualStrings("Escape", keyspec(&buf, false, false, false, "Escape"));
    try t.expectEqualStrings("S-Return", keyspec(&buf, false, false, true, "Return"));
    try t.expectEqualStrings("C-M-S-Tab", keyspec(&buf, true, true, true, "Tab"));
}

test "keymap: menu modes are leaf prefix tables, with enumerable bindings" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    try km.bind(gpa, "normal", "i", "insert");
    try km.bind(gpa, "leader", "f", "find-file");
    try km.bind(gpa, "leader", "c", "collab");

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
