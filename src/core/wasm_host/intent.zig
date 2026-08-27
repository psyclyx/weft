//! Live offers: the focused context's catalog, enumerated for a UI, and the
//! narrow door that accepts one.
//!
//! Enumeration is index-addressed like the command registry beside it
//! (`commands.zig`): count, then name/provider/reason per row, each read
//! against the snapshot for the CURRENT context (a cache hit while nothing
//! moves). A row carries its refusal reason rather than vanishing —
//! architecture §9.3: absence means nonapplicable, `disabled` means relevant
//! but impossible, and only the second is a thing to explain.
//!
//! `wl_intent_invoke` stores no decision: it resolves the NAME again, here,
//! at accept time, and goes through `Plane.invokeNamed` — the effect door,
//! which rechecks epoch, table revision, and endpoint generation. A list
//! built one keystroke ago can therefore never invoke a superseded endpoint.

const std = @import("std");
const wasm = @import("../wasm.zig");
const catalog = @import("../catalog.zig");
const plugin_offers = @import("../plugin_offers.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// Longest refusal text the door reports; longer is truncated, never dropped.
const reason_max = 512;

fn snapshot(p: *WasmPlugin) ?*const catalog.Snapshot {
    const ctx = p.activeCtx();
    const plane = ctx.intent orelse return null;
    return plane.snapshotFor(ctx);
}

fn leader(p: *WasmPlugin, i: i32) ?catalog.Candidate {
    const snap = snapshot(p) orelse return null;
    return snap.leader(@intCast(i));
}

fn write(caller: *wasm.Caller, args: []const i32, text: []const u8) i32 {
    return @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), text) catch 0);
}

pub fn hOfferCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const snap = snapshot(p) orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intCast(snap.intentionCount());
}

pub fn hOfferName(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const c = leader(p, args[0]) orelse {
        results[0] = -1;
        return;
    };
    results[0] = write(caller, args, p.activeCtx().intent.?.catalog.intentionName(c.intention));
}

pub fn hOfferProvider(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const c = leader(p, args[0]) orelse {
        results[0] = -1;
        return;
    };
    results[0] = write(caller, args, c.owner);
}

/// Why the `i`-th offer cannot run: the provider's stable reason code, or
/// nothing written (0) when it can.
pub fn hOfferReason(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const c = leader(p, args[0]) orelse {
        results[0] = -1;
        return;
    };
    results[0] = switch (c.availability) {
        .enabled => 0,
        .disabled => |d| write(caller, args, d.reason),
        .checking => write(caller, args, "checking"),
    };
}

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
    pub_.add(gpa, intention, cmd, reason) catch {
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
