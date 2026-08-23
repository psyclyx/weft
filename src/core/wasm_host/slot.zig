//! D2's generic, schema-directed membrane verbs — the host-side handlers for
//! `wl_slot_declare`/`wl_slot_bind`/`wl_payload_push`/`wl_payload_read`
//! (doc/d2-schema-payloads.md §3.2), binding `core/slot.zig`'s `SlotHost`
//! the same way `capability.zig` (this directory) binds `core/capability.zig`'s
//! `Caps` — same shape, deliberately not merged with it (see `core/slot.zig`'s
//! module doc for why).
//!
//! `wl_slot_bind`'s predicate crosses as a small, DELIBERATELY MINIMAL wire
//! micro-format, not a full schema-encoded `facts.Predicate` (doc/
//! d2-schema-payloads.md §3.2 names "facts.Predicate has a schema too —
//! self-hosting again" as the aspirational end state; giving `Predicate`
//! itself a `Schema` and marshalling it generically is real added surface
//! this slice's scope doesn't need — the disclosed simplification is exactly
//! this file's `parsePredicate`, documented at its definition below).
//! Format: `[]` (empty) = match-everything (`.all = &.{}`); `[tag: u8][uv
//! len][bytes]` = a single leaf (`1`=mode, `2`=ext, `3`=lang, `4`=tool) —
//! covers every case this repo's providers actually construct today
//! (`capability.zig`'s own `predicateFromExtensions` never needs more than a
//! single-axis leaf or an OR of same-axis leaves either).

const std = @import("std");
const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");
const container_mod = @import("../container.zig");
const facts_mod = @import("../facts.zig");
const schema_mod = @import("../schema.zig");
const slot_mod = @import("../slot.zig");
const wire_mod = @import("../wire.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// `wl_slot_declare(name_ptr, name_len, shape, composition, schema_ptr,
/// schema_len)` — see contract_data.zig's entry doc for the shape/
/// composition DEVIATION from the design doc's literal 4-param listing.
pub fn hSlotDeclare(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const host = p.activeCtx().slot_host orelse return;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const shape: container_mod.Shape = switch (@as(u32, @bitCast(args[2]))) {
        0 => .query,
        1 => .feed,
        2 => .action,
        else => .value,
    };
    const composition: container_mod.Composition = switch (@as(u32, @bitCast(args[3]))) {
        0 => .first_wins,
        2 => .merge_ranked,
        else => .ordered_union,
    };
    const schema_bytes = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(schema_bytes);
    const schema = schema_mod.parseSchema(gpa, schema_bytes) catch {
        caller.trap("wl_slot_declare: malformed schema blob for '{s}'", .{name});
        return;
    };
    p.declared_schemas.append(gpa, schema) catch {
        schema_mod.freeSchema(gpa, schema);
        return;
    };
    host.container.declareSlot(.{ .name = name, .shape = shape, .composition = composition, .schema = schema }) catch {};
}

/// The DELIBERATELY MINIMAL predicate wire format — see this file's module
/// doc. Returns `.all = &.{}` (match everything) for an empty/malformed
/// blob rather than trapping: a predicate is a NARROWING, never an
/// authority grant, so degrading to "matches everywhere" on a bad blob is
/// safe in the same sense an unrecognized `.ext` filter defaulting to "no
/// filter" would be — a permissive default, not a silent security hole.
fn parsePredicate(p: *WasmPlugin, bytes: []const u8) !facts_mod.Predicate {
    if (bytes.len < 1) return .{ .all = &.{} };
    const tag = bytes[0];
    var cur = bytes[1..];
    const n = wire_mod.getUv(&cur) catch return .{ .all = &.{} };
    if (n > cur.len) return .{ .all = &.{} };
    const owned = try p.gpa.dupe(u8, cur[0..@intCast(n)]);
    errdefer p.gpa.free(owned);
    try p.slot_predicate_strs.append(p.gpa, owned);
    return switch (tag) {
        1 => .{ .mode = owned },
        2 => .{ .ext = owned },
        3 => .{ .lang = owned },
        4 => .{ .tool = owned },
        else => .{ .all = &.{} },
    };
}

/// `wl_slot_bind(name_ptr, name_len, predicate_ptr, predicate_len, tier,
/// priority)` — bind this plugin as a provider for an already-declared slot.
pub fn hSlotBind(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const host = p.activeCtx().slot_host orelse return;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const pred_bytes = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(pred_bytes);
    const predicate = parsePredicate(p, pred_bytes) catch return;
    const tier: container_mod.Tier = switch (@as(u32, @bitCast(args[4]))) {
        0 => .core,
        1 => .imported,
        2 => .plugin,
        3 => .config,
        else => .transient,
    };
    const priority = args[5];
    host.register(.{
        .slot = name,
        .owner = p.name,
        .predicate = predicate,
        .priority = priority,
        .tier = tier,
        .data = p,
        .handler = wpSlotProvider,
    }) catch |e| {
        if (e == error.UnknownSlot) caller.trap("wl_slot_bind: '{s}' was never declared (wl_slot_declare first)", .{name});
    };
}

/// The trampoline `SlotHost.fire` calls for a matched wasm provider: hands
/// the guest the session and lets it own the answer, mirroring
/// `capability.zig`'s `wpCompletionProvider` exactly (sync commit during the
/// call, or a stashed session answered later off a poll).
fn wpSlotProvider(data: ?*anyopaque, host: *slot_mod.SlotHost, req: *const slot_mod.Request) anyerror!void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const handle: i32 = @bitCast(@as(u32, @truncate(req.session)));
    contract.callOptionalExport("on_slot_fire", &p.instance, .{handle}) catch {
        host.decline(req.session);
    };
}

/// `wl_payload_push(session, version, ptr, len)` — push one schema-encoded
/// payload for `session`. `version` (the producer's `SchemaRef`, §2.3) is
/// accepted per the contract but not yet compared against a tracked "current"
/// version — that skew only matters for a REMOTE peer with a stale schema
/// (§2.3's last bullet, rendering.md wire-scene territory); a single
/// process's `Container` has exactly one live schema per slot for its whole
/// run (`declareSlot`'s keep-the-first-declared policy), so there is no live
/// skew to detect within this slice's scope. Named, not silently dropped.
pub fn hPayloadPush(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const host = p.activeCtx().slot_host orelse return;
    const session: u64 = @as(u32, @bitCast(args[0]));
    const bytes = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer p.gpa.free(bytes);
    host.push(session, .{ .owner = p.name }, bytes) catch {};
}

/// `wl_payload_read(session, ptr, cap)` — host->guest: fill the guest's
/// scratch buffer with the fired session's schema-encoded REQUEST payload.
/// Returns the byte count written, or -1 if the session is unknown/dead.
pub fn hPayloadRead(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const host = p.activeCtx().slot_host orelse {
        results[0] = -1;
        return;
    };
    const session: u64 = @as(u32, @bitCast(args[0]));
    const s = host.session(session) orelse {
        results[0] = -1;
        return;
    };
    const n = caller.writeMemory(@intCast(args[1]), @intCast(args[2]), s.request) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(n);
}
