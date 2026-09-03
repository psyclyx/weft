//! `palette/<name>` — the COLOUR level of theming.
//!
//! Two levels, deliberately separate. A row role resolves to a style CLASS
//! through `projection.zig`'s `theme/<leaf>` family; a class (or any other
//! named colour the view paints) resolves to an sRGB hex string here. Keeping
//! them apart is what lets a producer invent a role without inventing a colour,
//! and lets one colourscheme restyle every producer at once.
//!
//! This family exists at all only because `Container.bind` now OWNS a
//! provider's payload. Before that it borrowed, so a binding's value had to
//! have a static spelling — which is why `theme/<leaf>` binds `@tagName` of a
//! closed enum. A colour has no such spelling, so the palette could not be a
//! slot and lived instead as a startup-only walk over a struct in `main.zig`.
//!
//! Core owns the NAMES (the vocabulary the view can paint, which config must be
//! able to address) and none of the VALUES: the defaults are the view's struct
//! initialisers, so an unbound slot means "whatever weft ships" rather than a
//! second copy of the palette living here to drift from the first.

const std = @import("std");
const container_mod = @import("container.zig");
const Facts = @import("weft_facts").Facts;

pub const slot_prefix = "palette/";

/// Every colour the view can paint, in `gfx/view/Theme.zig`'s field order.
/// `Theme` carries a comptime assertion that its fields match this list
/// exactly, so the two cannot drift: adding a colour without making it
/// themeable stops compiling.
pub const names = [_][]const u8{
    "background",
    "foreground",
    "cursor",
    "cursor_text",
    "selection",
    "status",
    "accent",
    "syn_keyword",
    "syn_string",
    "syn_comment",
    "syn_number",
    "syn_type",
    "syn_function",
    "syn_constant",
    "syn_operator",
    "syn_attribute",
    "diag_error",
    "diag_warn",
    "heading",
    "md_marker",
    "md_code",
    "md_link",
};

/// The static slot string for a palette name, or null if it is not one.
///
/// Static because a `Binding.slot` is still borrowed (only the PAYLOAD became
/// owned) — and because a name that is not in `names` is not a palette entry,
/// which is the check a config's typo needs to hit.
pub fn slotFor(name: []const u8) ?[]const u8 {
    inline for (names) |n| {
        if (std.mem.eql(u8, n, name)) return slot_prefix ++ n;
    }
    return null;
}

/// Declare every `palette/<name>`, first-wins, value-shaped. Core binds NO
/// defaults here — see the module doc.
pub fn declare(container: *container_mod.Container) !void {
    inline for (names) |n| {
        try container.declareSlot(.{
            .name = slot_prefix ++ n,
            .shape = .value,
            .composition = .first_wins,
        });
    }
}

/// The bound sRGB colour for one palette name, or null if nothing has bound it
/// (in which case the view keeps its shipped default).
pub fn colorFor(
    container: *const container_mod.Container,
    f: Facts,
    comptime name: []const u8,
) ?[4]f32 {
    const winner = container.resolveOne(slot_prefix ++ name, f) orelse return null;
    const hex = switch (winner.provider) {
        .value => |v| v,
        else => return null,
    };
    return parseHex(hex);
}

/// `#rrggbb` or `rrggbb` → straight sRGB in 0..1, alpha 1. Null on anything
/// else, so a malformed colour leaves the default standing rather than
/// becoming black.
pub fn parseHex(hex: []const u8) ?[4]f32 {
    const h = if (hex.len > 0 and hex[0] == '#') hex[1..] else hex;
    if (h.len != 6) return null;
    const r = std.fmt.parseInt(u8, h[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, h[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, h[4..6], 16) catch return null;
    const s = 1.0 / 255.0;
    return .{
        @as(f32, @floatFromInt(r)) * s,
        @as(f32, @floatFromInt(g)) * s,
        @as(f32, @floatFromInt(b)) * s,
        1,
    };
}

const t = std.testing;

test "palette: a name resolves to its static slot; a stranger does not" {
    try t.expectEqualStrings("palette/accent", slotFor("accent").?);
    try t.expectEqualStrings("palette/syn_keyword", slotFor("syn_keyword").?);
    try t.expect(slotFor("not_a_colour") == null);
    // A prefix of a real name is not a real name.
    try t.expect(slotFor("syn_") == null);
}

test "palette: hex parses with and without the hash, and rejects the rest" {
    const red = parseHex("#ff0000").?;
    try t.expectApproxEqAbs(@as(f32, 1), red[0], 0.001);
    try t.expectApproxEqAbs(@as(f32, 0), red[1], 0.001);
    try t.expectApproxEqAbs(@as(f32, 1), red[3], 0.001);
    try t.expect(parseHex("000000") != null);
    try t.expect(parseHex("zzzzzz") == null);
    try t.expect(parseHex("#12") == null);
    try t.expect(parseHex("") == null);
}

test "palette: an unbound slot yields null, a bound one yields its colour" {
    var c = container_mod.Container.init(t.allocator);
    defer c.deinit();
    try declare(&c);

    const f: Facts = .{};
    try t.expect(colorFor(&c, f, "accent") == null);

    // Bind from a buffer that dies before the read — the whole point of the
    // container owning its payloads now.
    {
        var scratch: [8]u8 = undefined;
        const hex = try std.fmt.bufPrint(&scratch, "#00ff00", .{});
        try c.bind(.{
            .slot = slotFor("accent").?,
            .provider = .{ .value = hex },
            .predicate = .{ .all = &.{} },
            .tier = .config,
            .owner = "test",
        });
        @memset(&scratch, 0);
    }
    const green = colorFor(&c, f, "accent").?;
    try t.expectApproxEqAbs(@as(f32, 0), green[0], 0.001);
    try t.expectApproxEqAbs(@as(f32, 1), green[1], 0.001);
}
