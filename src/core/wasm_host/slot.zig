//! D2's generic, schema-directed membrane verbs — the host-side handlers for
//! `wl_slot_declare`/`wl_slot_bind`/`wl_payload_push`/`wl_payload_read`
//! (doc/d2-schema-payloads.md §3.2), binding `core/slot.zig`'s `SlotHost`
//! the same way `capability.zig` (this directory) binds `core/capability.zig`'s
//! `Caps` — same shape, deliberately not merged with it (see `core/slot.zig`'s
//! module doc for why).
//!
//! Both halves live here: `declare`/`bind`/`payload_push` let a guest
//! PROVIDE a slot, and `slot_fire`/`slot_result*`/`slot_finish` let it
//! CONSUME one. The consumer half is what makes a plugin ecosystem possible
//! rather than just a plugin catalog — without it a guest could answer the
//! host's questions but had to ask its own as untyped `wl_run` command
//! strings.
//!
//! `wl_slot_bind`'s predicate crosses WHOLE: the guest builds a
//! `facts.Predicate` — the host's own type, shared as the `weft_facts` module
//! for the same reason `weft_input` and `weft_membrane` are — and encodes it
//! with the same function this side decodes with (`facts.encode` /
//! `facts.decode`). One codec, called twice; there is no format for the two
//! planes to drift on because there is no second implementation.
//!
//! It used to cross as a "deliberately minimal" micro-format carrying a
//! SINGLE LEAF — `1`=mode, `2`=ext, `3`=lang, `4`=tool — justified on the
//! grounds that it covered every case the repo's providers then constructed.
//! It did, and that was the problem: a provider whose interest was a
//! disjunction, a glob, a tag, or a locality could not say so, so it bound
//! everything and tested inside itself. Interest the host cannot decode is
//! interest it cannot route, gate, or `explain` — which is the whole reason
//! eligibility is host-side. The simplification was not in the wire; it was
//! in what providers were then willing to want.

const std = @import("std");
const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");
const container_mod = @import("../container.zig");
const facts_mod = @import("weft_facts");
const schema_mod = @import("weft_schema");
const slot_mod = @import("../slot.zig");
const intent = @import("../intent.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// `wl_slot_declare(name_ptr, name_len, shape, composition, schema_ptr,
/// schema_len)` — see membrane/root.zig's entry doc for the shape/
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

/// Decode a bound predicate through the ONE codec (`core/facts.zig`), which
/// is the same function the guest encoded with — not a second implementation
/// of an agreed format.
///
/// What this replaces is worth naming, because it was the shape of the
/// problem: a four-tag blob carrying exactly one leaf, so `mode`, `ext`,
/// `lang`, or `tool` — and nothing else the type can express. No `glob`, no
/// `tag`, no `locus`, and no combinators at all, which meant a language
/// server's own file filter (`any(ext=".zig", ext=".rs", …)`) was not
/// encodable and had to live inside the guest as a self-filter. A predicate
/// that cannot be written is a predicate the host cannot evaluate, which is
/// how interest ends up back on the wrong side of the membrane.
///
/// A malformed blob still degrades to `.all = &.{}` rather than trapping: a
/// predicate is a NARROWING, never an authority grant, so "matches
/// everywhere" is a permissive default and not a silent hole. What is NOT
/// tolerated is a blob that would cost something to refuse late — an
/// over-long child count or a nesting depth that would recurse the host off
/// its stack — both of which `facts.decode` rejects before allocating.
fn parsePredicate(p: *WasmPlugin, bytes: []const u8) !facts_mod.Predicate {
    const pred = facts_mod.decode(p.gpa, bytes) catch return .{ .all = &.{} };
    p.slot_predicates.append(p.gpa, pred) catch {
        facts_mod.free(p.gpa, pred);
        return .{ .all = &.{} };
    };
    return pred;
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
/// the guest the session and lets it own the answer (sync commit during the
/// call, or a stashed session answered later off a poll).
///
/// **Routes `active_ctx`, and deliberately does NOT set `in_dispatch`.**
/// Two halves of one rule, both load-bearing:
///
///   - Routing is what makes a fire from OUTSIDE a dispatch correct. Every
///     fire used to originate in a command handler, where `active_ctx` was
///     already the right head, so `wpCompletionProvider` never needed this
///     and neither did this. A fire from the frame loop (`Pick.tick`'s
///     annotation round — doc/marginalia.md §3.5) has no dispatch behind it,
///     and a provider's `wl_payload_push` reaches `p.activeCtx()`: without
///     the save/restore it would push through whichever head this plugin
///     last ran under. Same three lines `wpPickAccept` uses.
///   - Leaving `in_dispatch` FALSE is the protection, not an oversight. Every
///     head-gated door (`requireDispatch`) refuses, so a provider physically
///     cannot set a mode, open a pick, or echo from inside a fire. Answering
///     a question conveys no authority — the guarantee
///     `wasm_host/annotate.zig` makes for decorators, obtained here by never
///     granting it rather than by checking for it afterwards.
fn wpSlotProvider(data: ?*anyopaque, host: *slot_mod.SlotHost, req: *const slot_mod.Request) anyerror!void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const handle: i32 = @bitCast(@as(u32, @truncate(req.session)));
    const saved_ctx = p.active_ctx;
    if (req.ctx) |c| p.active_ctx = @ptrCast(@alignCast(c));
    defer p.active_ctx = saved_ctx;
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

// ── The consumer half ────────────────────────────────────────────────
// `declare`/`bind`/`push` let a guest ANSWER; these let it ASK. Both
// halves go through the SAME `SlotHost`, so a guest consuming a slot is
// indistinguishable, to a provider, from the host consuming it: the
// provider's `on_slot_fire` cannot tell who asked, and must not.
//
// What a guest does NOT get to choose is the CONTEXT. `facts` come from
// `intent.factsFor` — the one fact builder a keystroke's intention
// resolution also uses — and the version from the active document, so a
// guest cannot fire "as" a mode, tool or language it is not in, and every
// observation locator in every answer is restamped (`SlotHost.push`)
// against the version the host stamped rather than one the caller claimed.

/// `wl_slot_fire(name_ptr, name_len, request_ptr, request_len)` — fire a
/// declared slot at every eligible provider. Returns the session handle,
/// or -1 when the slot is undeclared, carries no schema, or nothing is
/// eligible here (all three are "nobody answers that question in this
/// context", which is a normal answer, not an error).
pub fn hSlotFire(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    results[0] = -1;
    const ctx = p.activeCtx();
    const host = ctx.slot_host orelse return;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const request = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(request);
    // The version every answer's observation locators are restamped to. A
    // context with no text entry (a tool buffer, a headless dispatch) still
    // fires — it just has no document version to stamp with, and a provider
    // that returns an observation locator then fails the restamp walk rather
    // than smuggling an unstamped offset through.
    const version: []u8 = blk: {
        const ed = ctx.buffers.active().textEditor() orelse break :blk &.{};
        break :blk ed.doc.version(gpa) catch break :blk &.{};
    };
    defer if (version.len > 0) gpa.free(version);
    // `.ctx` is what lets a PROVIDER (a different plugin, whose `active_ctx`
    // is whatever it last ran under) answer for the head that actually asked
    // — see `wpSlotProvider`'s doc and `slot.Request.ctx`.
    const id = host.fire(name, intent.factsFor(ctx), version, .{ .request = request, .ctx = ctx }) catch return;
    results[0] = @bitCast(@as(u32, @truncate(id orelse return)));
}

/// The session a `wl_slot_*` consumer verb names, or null.
fn consumerSession(p: *WasmPlugin, arg: i32) ?*slot_mod.Session {
    const host = p.activeCtx().slot_host orelse return null;
    return host.session(@as(u32, @bitCast(arg)));
}

/// `wl_slot_result_count(session)` — how many answers have landed.
pub fn hSlotResultCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = consumerSession(p, args[0]) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(s.all().len);
}

/// `wl_slot_done(session)` — 1 once every matched provider has answered or
/// declined. A guest polls this from `on_poll` for the async providers;
/// a race whose providers all answer synchronously is already done when
/// `wl_slot_fire` returns.
pub fn hSlotDone(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const s = consumerSession(p, args[0]) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intFromBool(s.done());
}

/// `wl_slot_result(session, index, ptr, cap)` — one answer's schema-encoded
/// payload, already restamped. Returns its length, or -1.
pub fn hSlotResult(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const s = consumerSession(p, args[0]) orelse return;
    const i: usize = @as(u32, @bitCast(args[1]));
    if (i >= s.all().len) return;
    const n = caller.writeMemory(@intCast(args[2]), @intCast(args[3]), s.all()[i].payload) catch return;
    results[0] = @intCast(n);
}

/// `wl_slot_result_provider(session, index, ptr, cap)` — WHO answered.
/// Attribution is data the consumer gets, not something it has to infer
/// from the payload: an `ordered_union` consumer showing "3 badges" can say
/// which plugin each came from, the same way the palette attributes offers.
pub fn hSlotResultProvider(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const s = consumerSession(p, args[0]) orelse return;
    const i: usize = @as(u32, @bitCast(args[1]));
    if (i >= s.all().len) return;
    const n = caller.writeMemory(@intCast(args[2]), @intCast(args[3]), s.all()[i].provider) catch return;
    results[0] = @intCast(n);
}

/// `wl_slot_finish(session)` — release it. A guest that forgets leaks the
/// session until plugin teardown, exactly as a forgotten `wl_release_range`
/// does; the host does not guess when a consumer is done reading.
pub fn hSlotFinish(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const host = p.activeCtx().slot_host orelse return;
    host.finish(@as(u32, @bitCast(args[0])));
}
