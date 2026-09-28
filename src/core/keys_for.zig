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

/// The binding mode keys resolve through in a chosen context: where the
/// person is (`personMode`) for the context the head is on, or — for a
/// primary it is not on (a companion holds the keyboard) — the mode that
/// entry rests in, its structural variant when its saved focus is on a scene
/// row, as `Context.bindingModeFor` decides live.
pub fn modeAt(ctx: *command.Context, where: intent.Where) []const u8 {
    const scope = intent.scopeOf(ctx, where);
    if (scope.live) return personMode(ctx);
    if (scope.focus.path() != null) {
        if (ctx.keymap.variantFor(scope.mode, .structural)) |variant| return variant;
    }
    return scope.entry.bindingMode(ctx.keymap, scope.mode);
}

/// Every key sequence that runs `target` in `mode` here, shortest first
/// (fewest keys, then fewest bytes). Owned by the caller: free each and the
/// slice.
pub fn keysFor(ctx: *command.Context, gpa: Allocator, target: []const u8, mode: []const u8) Allocator.Error![][]u8 {
    return keysForAt(ctx, gpa, target, mode, .active);
}

/// `keysFor` with every intention arm asked of a CHOSEN context rather than
/// the focused one: the keys a menubar shows beside an item that runs in the
/// primary context while a companion holds the keyboard. `mode` is that
/// context's binding mode (`modeAt`).
pub fn keysForAt(ctx: *command.Context, gpa: Allocator, target: []const u8, mode: []const u8, where: intent.Where) Allocator.Error![][]u8 {
    // Asked once per question, not once per intention arm per key: the
    // snapshot is what every arm of this reading is resolved against.
    const snap = if (ctx.intent) |plane| plane.snapshotAt(ctx, where) else null;
    const stamp: Stamp = .of(ctx, snap);
    var scratch: Index = .{};
    defer scratch.deinit();
    // The plane holds one index per context; a system without one (a unit
    // test's) reads through a throwaway.
    const index = if (ctx.intent) |plane| &plane.keys[@intFromEnum(where)] else &scratch;
    if (!index.fresh(stamp, mode)) try index.rebuild(ctx, stamp, mode, snap);

    const keys = index.by_target.get(target) orelse &.{};
    const out = try gpa.alloc([]u8, keys.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |k| gpa.free(k);
        gpa.free(out);
    }
    for (keys) |k| {
        out[n] = try gpa.dupe(u8, k);
        n += 1;
    }
    return out;
}

pub fn free(gpa: Allocator, keys: [][]u8) void {
    for (keys) |k| gpa.free(k);
    gpa.free(keys);
}

/// Which key runs what, in one binding mode of one context: every name a key
/// runs there (the arm dispatch would take, and the command an intention's
/// winning offer runs through) → its keys, shortest first. The reverse of the
/// keymap, walked once per question rather than once per ROW: the palette
/// asks it of every command it lists, a menu of every row, and walking every
/// key's arms each time cost a resolution of the whole mode chain and a
/// catalog snapshot per intention arm, per row.
///
/// Held for one `Stamp` — the keymap's revision, the command registry's, the
/// binding mode, and the catalog snapshot it was resolved against — so any
/// bind, load, focus move or offer change reads afresh.
pub const Index = struct {
    /// Everything the index holds, in memory of its OWN: an asker hands in
    /// whatever allocator its answer should live in (a frame's scratch, for
    /// a tooltip), and the index outlives every one of them.
    arena: ?std.heap.ArenaAllocator = null,
    stamp: ?Stamp = null,
    mode: []const u8 = "",
    by_target: std.StringHashMapUnmanaged([]const []const u8) = .empty,

    pub fn deinit(self: *Index) void {
        if (self.arena) |*arena| arena.deinit();
        self.* = .{};
    }

    fn fresh(self: *const Index, stamp: Stamp, mode: []const u8) bool {
        const held = self.stamp orelse return false;
        return std.meta.eql(held, stamp) and std.mem.eql(u8, self.mode, mode);
    }

    fn rebuild(self: *Index, ctx: *command.Context, stamp: Stamp, mode: []const u8, snap: ?*const catalog.Snapshot) Allocator.Error!void {
        self.deinit();
        const gpa = ctx.gpa;
        self.arena = .init(gpa);
        const a = self.arena.?.allocator();

        var bindings: std.ArrayList(Keymap.Binding) = .empty;
        defer bindings.deinit(gpa);
        var groups: std.ArrayList(bool) = .empty;
        defer groups.deinit(gpa);
        _ = try ctx.keymap.resolveBindingsInto(gpa, mode, &bindings, &groups);

        var lists: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        for (bindings.items, groups.items) |b, is_group| {
            if (is_group) continue;
            const ran = ranBy(ctx, b.arms, snap) orelse continue;
            const key = try a.dupe(u8, b.key);
            try addKey(a, &lists, ran.name, key);
            if (ran.via) |via| if (!std.mem.eql(u8, via, ran.name)) try addKey(a, &lists, via, key);
        }
        try self.by_target.ensureTotalCapacity(a, lists.count());
        var it = lists.iterator();
        while (it.next()) |e| {
            std.mem.sort([]const u8, e.value_ptr.items, {}, shorter);
            self.by_target.putAssumeCapacity(e.key_ptr.*, e.value_ptr.items);
        }
        self.mode = try a.dupe(u8, mode);
        self.stamp = stamp;
    }

    fn addKey(a: Allocator, lists: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)), name: []const u8, key: []const u8) Allocator.Error!void {
        const gop = try lists.getOrPut(a, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try a.dupe(u8, name);
            gop.value_ptr.* = .empty;
        }
        try gop.value_ptr.append(a, key);
    }
};

/// What an `Index` was derived from. Every field is a counter that moves
/// when its source does, so equality is freshness.
const Stamp = struct {
    keymap: u64,
    commands: u64,
    snapshot: ?struct { key: u64, revision: u64, epoch: u64 },

    fn of(ctx: *command.Context, snap: ?*const catalog.Snapshot) Stamp {
        return .{
            .keymap = ctx.keymap.revision,
            .commands = ctx.commands.revision,
            .snapshot = if (snap) |s| .{ .key = s.key, .revision = s.revision, .epoch = s.epoch } else null,
        };
    }
};

/// What a key runs here: the arm dispatch would take from `arms` (`name`),
/// and — for an intention arm that would run — the command its winning offer
/// runs through (`via`). Null when the key runs nothing here.
const Ran = struct { name: []const u8, via: ?[]const u8 = null };

fn ranBy(ctx: *command.Context, arms: []const []const u8, snap: ?*const catalog.Snapshot) ?Ran {
    for (arms) |arm| {
        if (!catalog.isIntentionName(arm)) {
            // A flat arm that names something ends the walk, as it does for
            // dispatch: a registered command, or a menu to enter.
            if (ctx.commands.resolve(arm) != null) return .{ .name = arm };
            if (ctx.keymap.modeHasTag(arm, "menu")) return null;
            continue;
        }
        switch (armVerdict(ctx, arm, snap)) {
            .skip => continue,
            .runs => |cmd| return .{ .name = arm, .via = cmd },
            // Refused here: the key still MEANS this intention — pressing it
            // reports why — so it is the key for the intention, and runs
            // nothing else.
            .refused => return .{ .name = arm },
        }
    }
    return null;
}

const Verdict = union(enum) {
    /// Nothing offers it here: the next arm gets its turn.
    skip,
    /// It would run, through this command where its endpoint names one.
    runs: ?[]const u8,
    refused,
};

fn armVerdict(ctx: *command.Context, intention: []const u8, snapshot: ?*const catalog.Snapshot) Verdict {
    const plane = ctx.intent orelse return .skip;
    const id = plane.catalog.findIntention(intention) orelse return .skip;
    const snap = snapshot orelse return .skip;
    return switch (snap.resolveOne(id)) {
        .decision => |d| .{ .runs = plane.invokers.commandOf(ctx, d.endpoint) },
        .unavailable => |u| switch (u) {
            .no_offer => .skip,
            .disabled, .checking => .refused,
        },
        .ambiguous => .refused,
    };
}

fn shorter(_: void, a: []const u8, b: []const u8) bool {
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

test "keysFor: the index is read again after a bind, an unbind, a fallback or a command moves" {
    const gpa = t.allocator;
    const pool = try @import("task.zig").Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try @import("System.zig").create(gpa, pool, "editor", "user");
    defer sys.destroy();
    var ctx = sys.contextFor(&sys.default_head);
    try sys.default_head.setModeRaw(gpa, "normal");
    const km = &sys.keymap;

    const count = struct {
        fn of(c: *command.Context, target: []const u8) !usize {
            const keys = try keysFor(c, t.allocator, target, "normal");
            defer free(t.allocator, keys);
            return keys.len;
        }
    }.of;
    try km.bind(gpa, "normal", "Z", "file.save", Keymap.prio_config, "t");
    // Asked with a frame's scratch that is gone before the next question (a
    // tooltip's): the index is in memory of its own, not the asker's.
    {
        var frame = std.heap.ArenaAllocator.init(gpa);
        defer frame.deinit();
        const keys = try keysFor(&ctx, frame.allocator(), "file.save", "normal");
        try t.expectEqual(@as(usize, 1), keys.len);
    }
    try t.expectEqual(@as(usize, 1), try count(&ctx, "file.save"));
    try t.expectEqual(@as(usize, 1), try count(&ctx, "file.save")); // held
    try km.bind(gpa, "normal", "W", "file.save", Keymap.prio_config, "t");
    try t.expectEqual(@as(usize, 2), try count(&ctx, "file.save"));
    km.unbind(gpa, "normal", "W", "t");
    try t.expectEqual(@as(usize, 1), try count(&ctx, "file.save"));
    // A mode it falls back to lends it keys.
    try km.bind(gpa, "base", "Q", "file.save", Keymap.prio_config, "t");
    try t.expectEqual(@as(usize, 1), try count(&ctx, "file.save"));
    try km.setFallback(gpa, "normal", "base");
    try t.expectEqual(@as(usize, 2), try count(&ctx, "file.save"));
    // A flat arm counts only while it names a command.
    try km.bind(gpa, "normal", "Y", "zz.later", Keymap.prio_config, "t");
    try t.expectEqual(@as(usize, 0), try count(&ctx, "zz.later"));
    const later = struct {
        fn run(_: *command.Context, _: struct {}) anyerror!command.Value {
            return .nil;
        }
    }.run;
    _ = try sys.commands.bind(gpa, "zz.later", command.define("zz.later", "Later.", later));
    try t.expectEqual(@as(usize, 1), try count(&ctx, "zz.later"));
}
