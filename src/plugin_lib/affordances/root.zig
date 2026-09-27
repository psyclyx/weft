//! Arranging offers for chrome: the ORDER a strip of buttons or a menu shows
//! a context's offers in, from the presentation their providers declared
//! (`group`, `order`; doc/configs.md §3.5.4).
//!
//! The host hands offers over in its own stable order and says nothing about
//! layout — "grouping and ordering by `group`/`order` is the UI's policy"
//! (`weft.offersIn`). Two UIs arranging the same offers differently would
//! teach a user two maps of one editor, so the policy lives here, once, and
//! the toolbar and the context menu both call it:
//!
//!   - offers sharing a `group` sit together, and a separator falls between
//!     groups;
//!   - a group sits where its most urgent member asks (the lowest `order`
//!     in it), ties broken by which group the host listed first;
//!   - inside a group, lower `order` first, then host order. An offer that
//!     states no order sorts after every one that does.
//!
//! Pure data: no `weft` import, so it runs natively under `zig build test`.

const std = @import("std");

/// One offer to place. `seq` is its position in the host's listing — the
/// tie-breaker that keeps the arrangement stable when nothing else decides.
pub const Item = struct {
    group: []const u8,
    order: ?i32 = null,
    seq: u32,
};

/// The most items one arrangement places; more are left in host order.
pub const max_items = 256;

/// Sort `items` in place into the arranged order.
pub fn arrange(items: []Item) void {
    if (items.len < 2 or items.len > max_items) return;
    // Each item carries its group's key: the group's lowest order, then its
    // first appearance — so sorting by (key, own order, seq) gathers groups.
    const Keyed = struct { item: Item, group_order: i64, group_first: u32 };
    var keyed: [max_items]Keyed = undefined;
    for (items, 0..) |a, i| {
        var best: i64 = orderKey(a.order);
        var first: u32 = a.seq;
        for (items) |b| {
            if (!std.mem.eql(u8, a.group, b.group)) continue;
            best = @min(best, orderKey(b.order));
            first = @min(first, b.seq);
        }
        keyed[i] = .{ .item = a, .group_order = best, .group_first = first };
    }
    std.sort.pdq(Keyed, keyed[0..items.len], {}, struct {
        fn lt(_: void, x: Keyed, y: Keyed) bool {
            if (x.group_order != y.group_order) return x.group_order < y.group_order;
            if (x.group_first != y.group_first) return x.group_first < y.group_first;
            const xo = orderKey(x.item.order);
            const yo = orderKey(y.item.order);
            if (xo != yo) return xo < yo;
            return x.item.seq < y.item.seq;
        }
    }.lt);
    for (keyed[0..items.len], 0..) |k, i| items[i] = k.item;
}

/// Whether a separator belongs before `items[i]` of an arranged list.
pub fn separatorBefore(items: []const Item, i: usize) bool {
    return i > 0 and !std.mem.eql(u8, items[i - 1].group, items[i].group);
}

fn orderKey(order: ?i32) i64 {
    return if (order) |o| o else std.math.maxInt(i64);
}

const t = std.testing;

fn groups(items: []const Item, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (items, 0..) |it, i| {
        if (separatorBefore(items, i)) w.writeAll("|") catch {};
        w.writeAll(it.group) catch {};
        w.print("{d}", .{it.seq}) catch {};
    }
    return w.buffered();
}

test "affordances: groups gather, ordered by their most urgent member" {
    var items = [_]Item{
        .{ .group = "git", .seq = 0 },
        .{ .group = "history", .order = 24, .seq = 1 },
        .{ .group = "git", .order = 3, .seq = 2 },
        .{ .group = "history", .order = 23, .seq = 3 },
        .{ .group = "fs", .seq = 4 },
    };
    arrange(&items);
    var buf: [64]u8 = undefined;
    // git's best is 3, history's 23; fs states nothing and goes last. Inside
    // a group, stated order first, then the host's order.
    try t.expectEqualStrings("git2git0|history3history1|fs4", groups(&items, &buf));
}

test "affordances: with no orders at all, the host's order stands, grouped" {
    var items = [_]Item{
        .{ .group = "b", .seq = 0 },
        .{ .group = "a", .seq = 1 },
        .{ .group = "b", .seq = 2 },
    };
    arrange(&items);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("b0b2|a1", groups(&items, &buf));
}
