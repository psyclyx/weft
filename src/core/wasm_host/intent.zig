//! Live offers: a context's catalog, enumerated for a UI as one record
//! (`wl_offers_list`), and the narrow door that accepts one. A row carries
//! its refusal reason rather than vanishing — architecture §9.3: absence
//! means nonapplicable, `disabled` means relevant but impossible, and only
//! the second is a thing to explain.
//!
//! `wl_intent_invoke` stores no decision: it resolves the NAME again, here,
//! at accept time, and goes through `Plane.invokeNamed` — the effect door,
//! which rechecks epoch, table revision, and endpoint generation. A list
//! built one keystroke ago can therefore never invoke a superseded endpoint.

const std = @import("std");
const wasm = @import("../wasm.zig");
const catalog = @import("../catalog.zig");
const intent_mod = @import("../intent.zig");
const plugin_offers = @import("../plugin_offers.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// Longest refusal text the door reports; longer is truncated, never dropped.
const reason_max = 512;

/// Resolve `name` for the context as it is NOW and invoke the winner. Returns
/// the length of a refusal reason written to guest memory (0 = invoked), or
/// -1 when the name is no intention at all — the guest's other vocabulary
/// still owns it.
pub fn hIntentInvoke(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const ctx = p.activeCtx();
    const plane = ctx.intent orelse {
        results[0] = -1;
        return;
    };
    const name = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(name);
    var buf: [reason_max]u8 = undefined;
    results[0] = switch (plane.invokeNamed(ctx, name, &buf)) {
        .invoked => 0,
        .unknown => -1,
        .refused => |why| @intCast(caller.writeMemory(@intCast(args[2]), @intCast(args[3]), why) catch 0),
    };
}

// ── Offers for a CHOSEN context (doc/configs.md §3.5.2-4) ────────────
//
// The palette asks about the ACTIVE pane; a strip of offers may hold focus
// itself and still has to describe the editor. `where` (`intent.Where`)
// picks the context — 0 active, 1 the head's primary focus — and the whole
// enumeration crosses as ONE record per call, so the snapshot a UI reads
// cannot move between its rows, and nothing index-addressed has to be kept
// in step across calls. It is the only enumeration: the palette's rows and
// the offers projection read it through one library (`weft_offers`).

/// Longest record one enumeration writes; a context offering more is cut at
/// a row boundary (the count says how many made it).
const record_max = 1 << 16;

/// `wl_offers_list(where, out, cap)`: every offer in the chosen context as
/// one little-endian record —
///
///   u32 count, then per row:
///     u8  availability (0 enabled, 1 disabled, 2 checking)
///     u8  has_order, i32 order
///     6 × (u32 len, bytes): intention, provider, reason, label, group, icon
///
/// with the presentation already completed from the intention table
/// (`intent.presentation`), so every row has a label and a group. Returns
/// the record's length, or -1 for an unknown `where` or no catalog. Nothing
/// is written unless the whole record fits `cap`; the length still answers,
/// so a guest can grow its buffer and ask again.
pub fn hOffersList(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const where = intent_mod.Where.fromWire(@bitCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    const ctx = p.activeCtx();
    const plane = ctx.intent orelse {
        results[0] = -1;
        return;
    };
    const snap = plane.snapshotAt(ctx, where) orelse {
        results[0] = -1;
        return;
    };
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(p.gpa);
    encodeOffers(p.gpa, &out, plane, ctx, snap) catch {
        results[0] = -1;
        return;
    };
    const cap: usize = @intCast(@as(u32, @bitCast(args[2])));
    if (out.items.len <= cap) _ = caller.writeMemory(@intCast(args[1]), cap, out.items) catch 0;
    results[0] = @intCast(out.items.len);
}

/// The record `hOffersList` writes, built from one snapshot. Separate so a
/// unit test reads exactly the bytes a guest would.
pub fn encodeOffers(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    plane: *const intent_mod.Plane,
    ctx: ?*@import("../command.zig").Context,
    snap: *const catalog.Snapshot,
) std.mem.Allocator.Error!void {
    const cat = &plane.catalog;
    try out.appendNTimes(gpa, 0, 4);
    var count: u32 = 0;
    for (snap.candidates, 0..) |c, i| {
        if (i != 0 and snap.candidates[i - 1].intention == c.intention) continue; // the leader only
        const mark = out.items.len;
        const shown = intent_mod.presentation(plane, ctx, c);
        try out.append(gpa, switch (c.availability) {
            .enabled => 0,
            .disabled => 1,
            .checking => 2,
        });
        try out.append(gpa, @intFromBool(shown.order != null));
        try putU32(gpa, out, @bitCast(shown.order orelse 0));
        const reason: []const u8 = switch (c.availability) {
            .enabled => "",
            .disabled => |d| d.reason,
            .checking => "checking",
        };
        for ([_][]const u8{ cat.intentionName(c.intention), c.owner, reason, shown.label, shown.group, shown.icon }) |s| {
            try putU32(gpa, out, @intCast(s.len));
            try out.appendSlice(gpa, s);
        }
        if (out.items.len > record_max) {
            out.shrinkRetainingCapacity(mark);
            break;
        }
        count += 1;
    }
    std.mem.writeInt(u32, out.items[0..4], count, .little);
}

fn putU32(gpa: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) std.mem.Allocator.Error!void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(gpa, &b);
}

/// `wl_intent_invoke_at(where, name, out, cap)`: `wl_intent_invoke` for a
/// chosen context — resolved and run THERE (`Plane.invokeAt`), so a
/// toolbar's Undo undoes the editor it describes, not the toolbar. A name
/// that is no intention but a command runs as that command there, with no
/// arguments: a menubar's File › Save saves the editor while the sidebar
/// holds the keys. Same result convention: 0 invoked, -1 neither an
/// intention nor a command (or unknown `where`), else the refusal's length.
///
/// HEAD-GATED, unlike `wl_intent_invoke`: running in the primary context
/// moves which entry the head is on for the call (`Plane.invokeNamedAt`),
/// and moving the head is a dispatching entry's business — never a
/// background callback's, such as the `on_context_changed` that tells a
/// toolbar to redraw.
pub fn hIntentInvokeAt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    if (!shared.requireDispatch(p, caller, "wl_intent_invoke_at")) return;
    const where = intent_mod.Where.fromWire(@bitCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    const ctx = p.activeCtx();
    const plane = ctx.intent orelse {
        results[0] = -1;
        return;
    };
    const name = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(name);
    var buf: [reason_max]u8 = undefined;
    results[0] = switch (plane.invokeAt(ctx, where, name, &buf)) {
        .invoked => 0,
        .unknown => -1,
        .refused => |why| @intCast(caller.writeMemory(@intCast(args[3]), @intCast(args[4]), why) catch 0),
    };
}

/// `order` value meaning "no ordering hint" on `wl_provide_affordance`.
pub const no_order: i32 = std.math.minInt(i32);

/// `wl_provide_affordance(action, label, group, order)`: how THIS plugin's
/// providers of `action` present their offer where they win — the wasm twin
/// of `weft.provide`'s `{label, group, order}` option. Presentation only;
/// it changes no resolution. Returns how many providers took it (0: this
/// plugin provides no such action).
pub fn hProvideAffordance(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    results[0] = 0;
    const action = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(action);
    const label = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(label);
    const group = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(group);
    // The owner `wl_provide` bound under — one identity per plugin.
    var owner_buf: [128]u8 = undefined;
    const owner = std.fmt.bufPrint(&owner_buf, "plugin.{s}", .{p.name}) catch return;
    const n = p.activeCtx().actions.setAffordance(action, owner, .{
        .label = label,
        .group = group,
        .order = if (args[6] == no_order) null else args[6],
    }) catch return;
    results[0] = @intCast(n);
}

// ── Publishing a plugin's OWN offers ─────────────────────────────────
//
// The mirror of the reads above: a guest pushes a table of
// `(intention, its own command, reason)` rows, which `plugin_offers.zig`
// publishes under `plugin.<name>` and invokes back through the command
// door. Three calls — begin, row, commit — because a table reaches the
// catalog WHOLE or not at all; a half-staged one is never published.
//
// Not perm-gated and not head-gated: publishing is a declaration about the
// plugin's own buffer, like a keymap binding, and the fill that lands a
// plugin's new model is a background entry.

/// This plugin's publisher, created on first use. `WasmPlugin` is heap-
/// allocated, so the address the registered invoker captured stays put.
fn publisher(p: *WasmPlugin) ?*plugin_offers.Publisher {
    if (!p.offers_ready) {
        const plane = p.activeCtx().intent orelse return null;
        var buf: [128]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "plugin.{s}", .{p.name}) catch return null;
        p.offers.init(p.gpa, plane, name) catch return null;
        p.offers_ready = true;
    }
    return &p.offers;
}

/// `offers_begin(tool, revision)`: start a table about the entry whose tool
/// identity is `tool` (empty = every context), stamped with the plugin's own
/// model ordinal, so an offer resolved against a superseded model dies at
/// the effect door.
pub fn hOffersBegin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const pub_ = publisher(p) orelse {
        results[0] = 0;
        return;
    };
    const scope = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = 0;
        return;
    };
    defer p.gpa.free(scope);
    pub_.begin(p.gpa, scope, @intCast(@as(u32, @bitCast(args[2])))) catch {
        results[0] = 0;
        return;
    };
    results[0] = 1;
}

/// `offer(intention, command, reason)`: stage one row. An empty `reason` is
/// an enabled offer; anything else is §9.3's relevant-but-impossible, and
/// the code shown when a UI explains the key.
pub fn hOffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const pub_ = publisher(p) orelse {
        results[0] = 0;
        return;
    };
    const gpa = p.gpa;
    const intention = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = 0;
        return;
    };
    defer gpa.free(intention);
    const cmd = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        results[0] = 0;
        return;
    };
    defer gpa.free(cmd);
    const reason = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch {
        results[0] = 0;
        return;
    };
    defer gpa.free(reason);
    // A plugin may only point an offer at a command it declared: an offer is
    // not a way to reach someone else's authority.
    if (!p.declaresCommand(cmd)) {
        caller.trap("plugin '{s}' offered '{s}' through '{s}', which it never declared", .{ p.name, intention, cmd });
        results[0] = 0;
        return;
    }
    const arity = if (p.activeCtx().commands.resolve(cmd)) |c| c.arity else null;
    pub_.add(gpa, intention, cmd, reason, arity) catch {
        results[0] = 0;
        return;
    };
    results[0] = 1;
}

pub fn hOffersCommit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const pub_ = publisher(p) orelse {
        results[0] = 0;
        return;
    };
    pub_.commit(p.gpa) catch {
        results[0] = 0;
        return;
    };
    results[0] = 1;
}

/// Withdraw the whole table: this plugin offers nothing here. Absence is
/// nonapplicable — an empty table would still be a claim.
pub fn hOffersRetract(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!p.offers_ready) return;
    p.offers.retract(p.gpa);
}

const t = std.testing;

test "wl_offers_list's record: one row per offered intention, presentation completed, reasons carried" {
    const gpa = t.allocator;
    var plane: intent_mod.Plane = undefined;
    try plane.init(gpa);
    defer plane.deinit(gpa);
    try plane.syncShape(.{ .can_undo = false });
    const snap = try plane.catalog.snapshot(.{ .key = 1, .revision = 1 });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try encodeOffers(gpa, &out, &plane, null, snap);

    // Read it back the way the SDK's `Offers.next` does.
    const bytes = out.items;
    try t.expectEqual(@as(u32, @intCast(snap.intentionCount())), std.mem.readInt(u32, bytes[0..4], .little));
    var at: usize = 4;
    var saw_undo = false;
    var rows: u32 = 0;
    while (at < bytes.len) : (rows += 1) {
        const availability = bytes[at];
        const has_order = bytes[at + 1] != 0;
        at += 6;
        var parts: [6][]const u8 = undefined;
        for (&parts) |*part| {
            const n = std.mem.readInt(u32, bytes[at..][0..4], .little);
            part.* = bytes[at + 4 ..][0..n];
            at += 4 + n;
        }
        // Every row can be shown: a label and a group always.
        try t.expect(parts[3].len > 0 and parts[4].len > 0);
        if (std.mem.eql(u8, parts[0], "std.history.undo")) {
            saw_undo = true;
            try t.expectEqual(@as(u8, 1), availability); // disabled…
            try t.expectEqualStrings("nothing-to-undo", parts[2]); // …and why
            try t.expectEqualStrings("core.editing", parts[1]);
            try t.expectEqualStrings("Undo", parts[3]);
            try t.expectEqualStrings("history", parts[4]);
            try t.expect(has_order);
        }
    }
    try t.expect(saw_undo);
    try t.expectEqual(@as(u32, @intCast(snap.intentionCount())), rows);
}
