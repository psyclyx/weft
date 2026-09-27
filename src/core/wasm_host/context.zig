//! `wl_context_set` / `wl_context_get` / `wl_context_changed` / `wl_places` /
//! `wl_subject_watch` and the `on_context_changed` and `on_subject_changed`
//! events — a guest's view of context (doc/model.md §2.5,
//! `core/context.zig`). Every door's body is shared with the JS plane
//! (`qjs_context_*`, `qjs_places`, `qjs_subject_watch`), one body each, like
//! the edit reads.
//!
//! PUBLISHING is not sensitive: a value is a claim about the plugin's own
//! work ("my REPL is live in this place"), it grants nothing, and a
//! predicate that reads it only narrows where a provider is OFFERED —
//! invocation still rechecks everything at the effect door. So the set door
//! carries no permission, like `wl_provide`. A plugin publishes only under
//! its own name (`repl` → `repl.session`). It may publish while answering a
//! provider round: frames are drawn from snapshots (doc/model.md §2.7), so a
//! publication is simply part of the next version.
//!
//! READING is a decision, and the default is open: any plugin may read the
//! PRIMARY context — what the user is looking at, which every piece of chrome
//! already shows on screen. What is NOT readable through this door is another
//! context: there is no "read the context at entry N", so a plugin learns
//! nothing about entries the user is not on. Should a publisher ever need to
//! say something private, the right shape is a grant on the key's namespace,
//! checked here; nothing published today needs it.

const std = @import("std");
const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");
const context_mod = @import("../context.zig");
const intent = @import("../intent.zig");
const facts = @import("weft_facts");
const shared = @import("plugin.zig");
const Door = @import("../plugin_resources.zig").Door;
const WasmPlugin = shared.WasmPlugin;

/// `wl_context_set` refusal codes (0 = done, changed or not).
pub const refused: i32 = -1;
pub const held: i32 = -2;

/// `contextSet(key, value, scope, place) -> 0 | -1 | -2`: publish `value`
/// for `key` at `scope` (0 entry, 1 place, 2 global) of the entry this call
/// is about, as this plugin — or, at the place scope with a non-empty
/// `place`, at the place that `dir` designation names. An empty value
/// retracts. -1 for a key that is not under this plugin's own name (`repl`
/// publishes `repl.session`, and nobody else can), an
/// oversized value, an unknown scope, a `place` that is not a `dir`
/// designation (or given at another scope), an entry in no nameable place,
/// or no context to publish into; -2 when another plugin holds the key there.
///
/// Naming a place grants nothing: a value is a claim about the publisher's
/// own work, and the one-owner rule still holds per (place, key).
pub fn setBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = refused;
    const context = d.ctx.context orelse return;
    const kind = std.enums.fromInt(context_mod.ScopeKind, @as(u32, @bitCast(args[4]))) orelse return;
    const entry = d.ctx.entry() orelse return;
    const gpa = d.ctx.gpa;
    const key = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(key);
    const value = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(value);
    const place = caller.readMemory(gpa, @intCast(args[5]), @intCast(args[6])) catch return;
    defer gpa.free(place);
    if (place.len != 0) {
        if (kind != .place) return;
        const named = @import("weft_semantic").durable.parse(place) orelse return;
        if (named.kind != .directory) return;
    }
    _ = context.store.set(d.resources.name, context.scopeFor(kind, entry, place), key, value) catch |err| {
        if (err == error.Held) results[0] = held;
        return;
    };
    results[0] = 0;
}
pub const hContextSet = shared.wasmDoor(setBody, null);

/// `contextGet(key, out, cap) -> len | -1`: the PRIMARY context's value for
/// `key` (any key — builtin or published) into guest memory, clamped to
/// `cap`; the full length is returned so a short buffer can grow. -1 when
/// the key has no value there. `offers` answers the revision last delivered.
pub fn getBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const gpa = d.ctx.gpa;
    const key = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(key);
    var scratch: [32]u8 = undefined;
    const value: []const u8 = if (std.mem.eql(u8, key, "offers")) blk: {
        const context = d.ctx.context orelse return;
        const fp = context.fingerprint("offers") orelse return;
        break :blk std.fmt.bufPrint(&scratch, "{x}", .{fp}) catch return;
    } else blk: {
        const scope = intent.primaryScopeOf(d.ctx) orelse return;
        break :blk intent.factsIn(scope).get(key) orelse return;
    };
    const cap: usize = @intCast(@max(args[3], 0));
    _ = caller.writeMemory(@intCast(args[2]), cap, value) catch return;
    results[0] = @intCast(@min(value.len, @as(usize, std.math.maxInt(i32))));
}
pub const hContextGet = shared.wasmDoor(getBody, null);

/// `contextChanged(out, cap) -> len`: the keys the event being delivered
/// reports as moved, one per line, clamped to `cap`; the full length is
/// returned. Outside a delivery it answers the last one's. The JS plane reads
/// it the same way, inside its own `on_context_changed`.
pub fn changedBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = 0;
    const context = d.ctx.context orelse return;
    writeLines(d.ctx.gpa, caller, args, results, context.movedKeys());
}
pub const hContextChanged = shared.wasmDoor(changedBody, null);

/// `places(out, cap) -> len`: the places the workspace is working in
/// (`context.Context.places`), one designation per line (clamped); returns
/// the full length. A read of the workspace, like `wl_context_get`.
pub fn placesBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = 0;
    const context = d.ctx.context orelse return;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(d.ctx.gpa);
    context.places(d.ctx.gpa, d.ctx.buffers, &names) catch return;
    writeLines(d.ctx.gpa, caller, args, results, names.items);
}
pub const hPlaces = shared.wasmDoor(placesBody, null);

/// `lines` joined by newlines into guest memory at `(args[0], args[1])`,
/// clamped; `results[0]` is the full length.
fn writeLines(gpa: std.mem.Allocator, caller: *wasm.Caller, args: []const i32, results: []i32, lines: []const []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (lines, 0..) |line, i| {
        if (i > 0) out.append(gpa, '\n') catch return;
        out.appendSlice(gpa, line) catch return;
    }
    const cap: usize = @intCast(@max(args[1], 0));
    _ = caller.writeMemory(@intCast(args[0]), cap, out.items) catch return;
    results[0] = @intCast(@min(out.items.len, @as(usize, std.math.maxInt(i32))));
}

/// `subjectWatch(designation, watching) -> 0 | -1 | -2`: hear
/// `on_subject_changed` whenever the entry opening `designation` reads
/// differently — an edit, a parse that landed — from the next frame boundary
/// on (`context.Context.watch`); `watching` 0 stops. -1 for text that is not
/// a designation or no context to watch in; -2 past `context.max_watches`.
///
/// Not sensitive, like `contextGet`: a watch learns only THAT content moved,
/// at the boundary, and reading it is the ordinary doors' business under the
/// ordinary rules. Watches end when the plugin unloads.
pub fn watchBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    results[0] = -1;
    const context = d.ctx.context orelse return;
    const gpa = d.ctx.gpa;
    const subject = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(subject);
    if (args[2] == 0) {
        context.unwatch(d.resources.name, subject);
        results[0] = 0;
        return;
    }
    context.watch(d.resources.name, subject, d.ctx.buffers) catch |err| {
        if (err == error.TooMany) results[0] = -2;
        return;
    };
    results[0] = 0;
}
pub const hSubjectWatch = shared.wasmDoor(watchBody, null);

/// Fire `on_subject_changed` at one plugin for one moved subject, BOUND to
/// the subject's entry (`command.Context.bindEntry`) for the call: every
/// door the callback reads — the text, the outline, the designation — is
/// the subject's, whichever entry is in front. The caller
/// (`app/application.zig`) decides WHEN — the frame boundary, beside
/// `on_context_changed` — and this only delivers. Returns whether it ran.
pub fn notifySubjectChanged(p: *WasmPlugin, entry: @import("../Buffers.zig").Ref) bool {
    const ctx = p.activeCtx();
    const was = ctx.bindEntry(entry);
    defer _ = ctx.bindEntry(was);
    contract.callOptionalExport("on_subject_changed", p, .{}) catch return false;
    return true;
}

/// Fire the context-changed event (`on_context_changed`) at one plugin: keys
/// of the head's primary context just moved (`wl_context_changed` lists
/// them). The caller (`app/application.zig`'s `notifyContextChanged`)
/// decides WHEN — once per frame at most, at the frame boundary, never from
/// inside a dispatch — and this only delivers. A plugin that does not export
/// the callback is remembered as deaf after the first try, so it costs
/// nothing on later changes. Returns whether it ran.
pub fn notifyContextChanged(p: *WasmPlugin) bool {
    if (p.context_listener == .deaf) return false;
    contract.callOptionalExport("on_context_changed", p, .{}) catch |err| {
        if (err == error.MissingExport) p.context_listener = .deaf;
        return false;
    };
    p.context_listener = .listening;
    return true;
}

/// Could this plugin be listening? Unknown counts as yes — it is asked once.
pub fn hearsContext(p: *const WasmPlugin) bool {
    return p.context_listener != .deaf;
}
