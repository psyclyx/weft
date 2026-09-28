//! Where a name stands in a chosen context (doc/chrome.md §2.1): whether it
//! would run there — and if not, why not — and which keys run it there.
//!
//! A menu row asks exactly this about the command it stands for: the menubar
//! greys Undo with "there is no change to undo", shows `C-s` beside Save, and
//! does both for the PRIMARY context, since that is where its items run while a
//! companion (a sidebar) holds the keyboard. The context menu asks it of the
//! context under the pointer. Nothing here is a second resolver: an intention
//! is resolved by the catalog snapshot dispatch uses, an action by the
//! container dispatch's trampoline asks, a mapping by `selection.admits`, and
//! the keys by `keys_for` — each fed the chosen scope (`intent.scopeOf`).
//!
//! A reading, not a dispatch: nothing is invoked, and the head never moves.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const catalog = @import("catalog.zig");
const intent = @import("intent.zig");
const keys_for = @import("keys_for.zig");
const selection = @import("selection.zig");

pub const Standing = struct {
    /// Why it would not run here, in words a person reads; null when it
    /// would. Borrowed from the catalog or a static table — valid until the
    /// next catalog publish.
    reason: ?[]const u8 = null,
    /// The keys that run it there, shortest first (`keys_for.free`).
    keys: [][]u8 = &.{},

    pub fn deinit(self: *Standing, gpa: Allocator) void {
        keys_for.free(gpa, self.keys);
        self.* = .{};
    }
};

/// How `name` — a command, an action or an intention — stands in `where`;
/// null when nothing by that name exists here.
pub fn of(ctx: *command.Context, gpa: Allocator, name: []const u8, where: intent.Where) Allocator.Error!?Standing {
    const reason = (try reasonAt(ctx, name, where)) orelse return null;
    const mode = keys_for.modeAt(ctx, where);
    var keys = try keys_for.keysForAt(ctx, gpa, name, mode, where);
    // A command no key runs right now may still have a key that MEANS it: an
    // intention whose offer here runs it, refused for the moment. A greyed
    // Undo shows C-z — pressing it says the same thing the greying does.
    if (keys.len == 0) if (ctx.intent) |plane| if (plane.snapshotAt(ctx, where)) |snap| {
        // The intentions first: asking for their keys consults the snapshot
        // again, which may rebuild it in place.
        var meant: [8]catalog.IntentionId = undefined;
        var n: usize = 0;
        for (snap.candidates) |c| {
            if (n == meant.len) break;
            const runs = plane.invokers.commandOf(ctx, c.endpoint) orelse continue;
            if (std.mem.eql(u8, runs, name)) {
                meant[n] = c.intention;
                n += 1;
            }
        }
        for (meant[0..n]) |id| {
            const by_intention = try keys_for.keysForAt(ctx, gpa, plane.catalog.intentionName(id), mode, where);
            if (by_intention.len == 0) {
                keys_for.free(gpa, by_intention);
                continue;
            }
            keys_for.free(gpa, keys);
            keys = by_intention;
            break;
        }
    };
    return .{ .reason = reason.why, .keys = keys };
}

const Reason = struct { why: ?[]const u8 };

/// Null: no such name. Otherwise `why` is null when it would run.
fn reasonAt(ctx: *command.Context, name: []const u8, where: intent.Where) Allocator.Error!?Reason {
    const plane = ctx.intent;
    const cmd = ctx.commands.resolve(name);
    if (catalog.isIntentionName(name) and cmd == null) {
        const p = plane orelse return .{ .why = "no catalog here" };
        const id = p.catalog.findIntention(name) orelse return null;
        const snap = p.snapshotAt(ctx, where) orelse return .{ .why = "no catalog here" };
        return .{ .why = switch (snap.resolveOne(id)) {
            .decision => null,
            .unavailable => |u| switch (u) {
                .no_offer => "nothing offers this here",
                .disabled => |d| if (d.reason.message.len > 0) d.reason.message else d.reason.reason,
                .checking => "still being worked out",
            },
            .ambiguous => "two providers offer this equally",
        } };
    }
    const c = cmd orelse return null;
    const scope = intent.scopeOf(ctx, where);
    // What the offers that RUN this command say about it here — the core
    // table's Undo is disabled with its reason where nothing can be undone.
    // One that can run is enough; else the first refusal speaks for them.
    if (plane) |p| if (p.snapshotAt(ctx, where)) |snap| {
        var refused: ?[]const u8 = null;
        var enabled = false;
        for (snap.candidates) |cand| {
            const runs = p.invokers.commandOf(ctx, cand.endpoint) orelse continue;
            if (!std.mem.eql(u8, runs, name)) continue;
            switch (cand.availability) {
                .enabled => enabled = true,
                .disabled => |d| if (refused == null) {
                    refused = if (d.message.len > 0) d.message else d.reason;
                },
                .checking => {},
            }
        }
        if (!enabled) if (refused) |why| return .{ .why = why };
    };
    // An action nothing provides here does nothing but say so.
    if (c.handler == command.actionTrampoline) {
        if (ctx.actions.container.resolveOne(name, intent.factsIn(scope)) == null)
            return .{ .why = "nothing here provides it" };
    }
    // What dispatch would refuse on the selection's shape.
    if (selection.admits(c.arity, selection.shapeOfEntry(scope.entry, scope.focus))) |refusal|
        return .{ .why = selection.reason(refusal).message };
    return .{ .why = null };
}

/// `s` in its text form: a `state` line (`ready` or `disabled`), a `reason`
/// line when disabled, then one `key` line per key, shortest first, each as
/// the keymap DISPLAYS it (`SPC f s`). The shape `wl_command_at` answers in.
pub fn encode(ctx: *command.Context, gpa: Allocator, s: Standing) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, if (s.reason == null) "state\tready\n" else "state\tdisabled\n");
    if (s.reason) |why| {
        try out.appendSlice(gpa, "reason\t");
        for (why) |ch| try out.append(gpa, if (ch == '\t' or ch == '\n') ' ' else ch);
        try out.append(gpa, '\n');
    }
    for (s.keys) |key| {
        var shown_buf: [256]u8 = undefined;
        try out.appendSlice(gpa, "key\t");
        try out.appendSlice(gpa, ctx.keymap.displayKey(&shown_buf, key));
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "standing: a command's reason comes from the offers that run it, an action's from its providers, and its keys from the chosen mode" {
    const gpa = t.allocator;
    const pool = try @import("task.zig").Pool.init(gpa, .{ .threads = 1 });
    defer pool.deinit();
    const sys = try @import("System.zig").create(gpa, pool, "editor", "user");
    defer sys.destroy();
    var ctx = sys.contextFor(&sys.default_head);
    try sys.default_head.setModeRaw(gpa, "normal");
    try sys.keymap.bind(gpa, "normal", "u", "edit.undo", @import("Keymap.zig").prio_config, "t");

    // Nothing to undo yet: the core table's Undo row says why, and the key
    // that would run it is still the key.
    var undo = (try of(&ctx, gpa, "edit.undo", .active)).?;
    defer undo.deinit(gpa);
    try t.expectEqualStrings("there is no change to undo", undo.reason.?);
    try t.expectEqual(@as(usize, 1), undo.keys.len);
    try t.expectEqualStrings("u", undo.keys[0]);

    // A plain command with nothing standing in its way runs.
    var open = (try of(&ctx, gpa, "file.open", .active)).?;
    defer open.deinit(gpa);
    try t.expect(open.reason == null);

    // No such name at all.
    try t.expect((try of(&ctx, gpa, "no.such-command", .active)) == null);

    // The text form a guest reads.
    const text = try encode(&ctx, gpa, undo);
    defer gpa.free(text);
    try t.expectEqualStrings("state\tdisabled\nreason\tthere is no change to undo\nkey\tu\n", text);
}
