//! "Which key runs this, here" (doc/chrome.md §1.3).
//!
//! `keysFor(ctx, gpa, target)` answers with every key sequence that, pressed
//! where the person is, would run `target` — a command, an action or an
//! intention — shortest first. "Where the person is" is the binding mode of
//! the focused context (its source/structural variant included), or, while a
//! picker is open, the mode the picker was opened from: the palette asks
//! about the place a person came from, not about the picker's own keys.
//!
//! A key counts when the arm dispatch would take for it names `target`, walked
//! the way dispatch walks it (`intent.explain` is the other reading of the
//! same walk): a flat arm that resolves ends the walk; an intention arm is
//! asked of the catalog, and the command its winning offer runs
//! (`Invokers.commandOf`) is what it runs. So `C-s` bound to
//! `[std.persistence.save, file.save]` runs `file.save` in a file and the
//! commit in a git draft, and the answer for `file.save` is `C-s` in the one
//! and not the other.
//!
//! A reading, not a dispatch: nothing is invoked and nothing is minted.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const catalog = @import("catalog.zig");
const intent = @import("intent.zig");
const Keymap = @import("Keymap.zig");

/// The binding mode a person's keys resolve through right now: the focused
/// context's, or — while a picker holds the keys — the one it was opened
/// from.
pub fn personMode(ctx: *command.Context) []const u8 {
    const pick = &ctx.head.pick;
    if (pick.active and pick.prev_mode.len > 0) return ctx.bindingModeFor(pick.prev_mode);
    return ctx.bindingMode();
}

/// Every key sequence that runs `target` in `mode` here, shortest first
/// (fewest keys, then fewest bytes). Owned by the caller: free each and the
/// slice.
pub fn keysFor(ctx: *command.Context, gpa: Allocator, target: []const u8, mode: []const u8) Allocator.Error![][]u8 {
    var bindings: std.ArrayList(Keymap.Binding) = .empty;
    defer bindings.deinit(gpa);
    var groups: std.ArrayList(bool) = .empty;
    defer groups.deinit(gpa);
    _ = try ctx.keymap.resolveBindingsInto(gpa, mode, &bindings, &groups);

    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |k| gpa.free(k);
        out.deinit(gpa);
    }
    for (bindings.items, groups.items) |b, is_group| {
        if (is_group) continue;
        if (!runs(ctx, b.arms, target)) continue;
        try out.append(gpa, try gpa.dupe(u8, b.key));
    }
    std.mem.sort([]u8, out.items, {}, shorter);
    return out.toOwnedSlice(gpa);
}

pub fn free(gpa: Allocator, keys: [][]u8) void {
    for (keys) |k| gpa.free(k);
    gpa.free(keys);
}

/// Whether the arm dispatch would take from `arms` here is `target`.
fn runs(ctx: *command.Context, arms: []const []const u8, target: []const u8) bool {
    for (arms) |arm| {
        if (!catalog.isIntentionName(arm)) {
            // A flat arm that names something ends the walk, as it does for
            // dispatch: a registered command, or a menu to enter.
            if (ctx.commands.resolve(arm) != null) return std.mem.eql(u8, arm, target);
            if (ctx.keymap.modeHasTag(arm, "menu")) return false;
            continue;
        }
        switch (armVerdict(ctx, arm)) {
            .skip => continue,
            .runs => |cmd| return std.mem.eql(u8, arm, target) or
                (if (cmd) |c| std.mem.eql(u8, c, target) else false),
            // Refused here: the key still MEANS this intention — pressing it
            // reports why — so it is the key for the intention, and runs
            // nothing else.
            .refused => return std.mem.eql(u8, arm, target),
        }
    }
    return false;
}

const Verdict = union(enum) {
    /// Nothing offers it here: the next arm gets its turn.
    skip,
    /// It would run, through this command where its endpoint names one.
    runs: ?[]const u8,
    refused,
};

fn armVerdict(ctx: *command.Context, intention: []const u8) Verdict {
    const plane = ctx.intent orelse return .skip;
    const id = plane.catalog.findIntention(intention) orelse return .skip;
    const snap = plane.snapshotFor(ctx) orelse return .skip;
    return switch (snap.resolveOne(id)) {
        .decision => |d| .{ .runs = plane.invokers.commandOf(ctx, d.endpoint) },
        .unavailable => |u| switch (u) {
            .no_offer => .skip,
            .disabled, .checking => .refused,
        },
        .ambiguous => .refused,
    };
}

fn shorter(_: void, a: []u8, b: []u8) bool {
    const ka = std.mem.count(u8, a, " ");
    const kb = std.mem.count(u8, b, " ");
    if (ka != kb) return ka < kb;
    if (a.len != b.len) return a.len < b.len;
    return std.mem.lessThan(u8, a, b);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "keysFor: a flat arm, an intention arm and its fallback, a shadowed key, shortest first" {
    const gpa = t.allocator;
    const pool = try @import("task.zig").Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try @import("System.zig").create(gpa, pool, "editor", "user");
    defer sys.destroy();
    var ctx = sys.contextFor(&sys.default_head);
    try sys.default_head.setModeRaw(gpa, "normal");
    const km = &sys.keymap;

    try km.bind(gpa, "normal", "space f s", "file.save", Keymap.prio_config, "t");
    try km.bind(gpa, "normal", "C-x C-s", "file.save", Keymap.prio_config, "t");
    // The persistence intention: core's editing provider answers it with
    // `file.save` in a text entry, so the key runs `file.save` here.
    try km.bindArms(gpa, "normal", "C-s", &.{ "std.persistence.save", "edit.undo" }, Keymap.prio_config, "t");
    try km.bind(gpa, "normal", "u", "edit.undo", Keymap.prio_config, "t");
    // Shadowed: `normal` falls back to `default`, whose `Z` is overridden.
    try km.setFallback(gpa, "normal", "default");
    try km.bind(gpa, "default", "Z", "file.save", Keymap.prio_core, "t");
    try km.bind(gpa, "normal", "Z", "edit.redo", Keymap.prio_config, "t");

    const keys = try keysFor(&ctx, gpa, "file.save", "normal");
    defer free(gpa, keys);
    const want = [_][]const u8{ "C-s", "C-x C-s", "space f s" };
    try t.expectEqual(want.len, keys.len);
    for (want, keys) |w, k| try t.expectEqualStrings(w, k);

    // The intention itself is run by the same key, and `edit.undo` by `u` and
    // the modeless floor's `C-z` it inherits — never by C-s, whose fallback
    // arm is not reached where save answers.
    const by_intention = try keysFor(&ctx, gpa, "std.persistence.save", "normal");
    defer free(gpa, by_intention);
    try t.expectEqual(@as(usize, 1), by_intention.len);
    const undo = try keysFor(&ctx, gpa, "edit.undo", "normal");
    defer free(gpa, undo);
    try t.expectEqual(@as(usize, 2), undo.len);
    try t.expectEqualStrings("u", undo[0]);
    try t.expectEqualStrings("C-z", undo[1]);

    // Where nothing persists — an entry no `file.save` provider answers —
    // the intention is not offered, the walk reaches C-s's fallback arm, and
    // C-s is an UNDO key there: the same key, a different answer, by context.
    const listing = try sys.buffers.create(gpa, "*listing*");
    try sys.buffers.switchTo(gpa, listing, &sys.default_head, &sys.keymap);
    try sys.buffers.active().setTool(gpa, "projection");
    const there = try keysFor(&ctx, gpa, "edit.undo", "normal");
    defer free(gpa, there);
    try t.expectEqual(@as(usize, 3), there.len);
    try t.expectEqualStrings("C-s", there[1]);
}
