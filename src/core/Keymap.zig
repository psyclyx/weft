//! Keymap — modal key → command-name tables. Pure string domain: a
//! keyspec is `[C-][M-]<xkb keysym name>` (shift lives in the keysym:
//! `a` vs `A`, specials keep their names — `Escape`, `Tab`, `Return`).
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

/// The command bound to `keyspec` in the current mode, if any.
pub fn lookup(self: *const Keymap, key: []const u8) ?[]const u8 {
    const bindings = self.modes.getPtr(self.mode) orelse return null;
    return bindings.get(key);
}

pub fn setMode(self: *Keymap, gpa: Allocator, mode: []const u8) Allocator.Error!void {
    const owned = try gpa.dupe(u8, mode);
    gpa.free(self.mode);
    self.mode = owned;
}

pub fn currentMode(self: *const Keymap) []const u8 {
    return self.mode;
}

/// Compose a keyspec from modifiers + a keysym name into `buf`.
pub fn keyspec(buf: []u8, ctrl: bool, alt: bool, keysym_name: []const u8) []const u8 {
    var i: usize = 0;
    if (ctrl) {
        @memcpy(buf[i..][0..2], "C-");
        i += 2;
    }
    if (alt) {
        @memcpy(buf[i..][0..2], "M-");
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
    try t.expectEqualStrings("C-M-x", keyspec(&buf, true, true, "x"));
    try t.expectEqualStrings("Escape", keyspec(&buf, false, false, "Escape"));
}
