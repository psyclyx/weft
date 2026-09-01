//! The config surface's local plane: key binds, mode entry/fallback, the
//! text-input command, and menu/sticky-menu marks — each the host half of one
//! guest config import, bound at the plugin tier owned by the plugin's name.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command_mod = @import("../command.zig");
const input = @import("weft_input");
const facts = @import("weft_facts");
const Keymap = @import("../Keymap.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requireDispatch = shared.requireDispatch;
// The POLICY door (task #19 item 3) — `hSetMode`/`hExitToResting` are the
// ONE membrane chokepoint every guest's `weft.setMode`/`weft.exitToResting`
// funnels through (see `ctx.zig`'s module doc, "BACKGROUND CODE CANNOT"),
// so routing THIS site through `Ctx.capture`/`Ctx.enterMode`/`Ctx.setMode`
// is what puts every guest-driven mode change on the door without touching
// any of the ~15 guest plugin files that call `weft.setMode` directly.
const ctx_mod = @import("../ctx.zig");

pub fn hBindKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    const key = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(key);
    const cmd = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(cmd);
    // A plugin binds at the plugin tier, owned by its name (so a config bind
    // shadows it and equal-tier collisions between two plugins are surfaced).
    p.activeCtx().keymap.bind(gpa, mode, key, cmd, Keymap.prio_plugin, p.name) catch {};
}

/// wl_bind_keys(mode, key, framed list) — the same bind at the list arity
/// (architecture §10.2): the grammar authors a first-applicable order and
/// dispatch resolves it against the focus. A malformed or empty blob binds
/// nothing rather than half a list.
pub fn hBindKeys(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    const key = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(key);
    const blob = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(blob);
    var cmds: [Keymap.max_bind_commands][]const u8 = undefined;
    var n: usize = 0;
    var it = @import("../framed.zig").Records.init(blob) orelse return;
    while (it.next()) |rec| : (n += 1) {
        if (n == cmds.len) return;
        cmds[n] = rec;
    }
    if (n == 0) return;
    p.activeCtx().keymap.bindArms(gpa, mode, key, cmds[0..n], Keymap.prio_plugin, p.name) catch {};
}

/// wl_provide(action, predicate, cmd, prio) — a plugin registers a provider
/// for `action`, owned by its name (so teardown drops it and equal-tier
/// collisions are attributable).
///
/// The predicate crosses as an encoded `facts.Predicate`, through the same
/// codec `wl_slot_bind` uses. It used to cross as three fixed strings —
/// mode, lang, tool, each empty for "don't care" — which is a `When`, and
/// `When` was only ever translated into a `Predicate` on arrival. Three
/// parameters could express a conjunction of three specific axes and
/// nothing else: no glob, no tag, no locality, and no disjunction. A
/// provider wanting any of those had to bind broadly and re-test inside its
/// own command, which is the eligibility question leaking back across the
/// membrane it was moved off.
pub fn hProvide(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const action = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(action);
    const pred_bytes = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(pred_bytes);
    const cmd = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(cmd);
    // A malformed blob narrows to nothing rather than trapping — the same
    // permissive degradation `wl_slot_bind` documents, for the same reason:
    // a predicate is a narrowing, never a grant. `provide` deep-copies, so
    // this tree is ours to release either way.
    const predicate = facts.decode(gpa, pred_bytes) catch facts.Predicate{ .all = &.{} };
    defer facts.free(gpa, predicate);
    // ONE identity for a plugin across both planes. `plugin.<name>` is already
    // what this plugin's offers are published under (`wasm_host/intent.zig`'s
    // `publisher`), and a derived offer is attributed to the binding's owner —
    // so a verb reaching a key by `provide` and a verb reaching it by a pushed
    // table now name the same author, instead of `git` and `plugin.git` being
    // two owners that the §7.2 order would treat as strangers to each other.
    var owner_buf: [128]u8 = undefined;
    const owner = std.fmt.bufPrint(&owner_buf, "plugin.{s}", .{p.name}) catch p.name;
    p.activeCtx().actions.provide(.{
        .action = action,
        .predicate = predicate,
        .command = cmd,
        .priority = args[6],
        .owner = owner,
    }) catch |e| if (e == error.RaceRejectsProvider) {
        // Surface the mistake to the plugin author via the echo line when the
        // call is on a dispatching path or the load handshake (the common,
        // legitimate cases) — from a BACKGROUND entry, head.echo is exactly
        // the gated interaction state (review of #19 item 4: this error path
        // was the one ungated head.echo writer), so fall back to the log.
        const msg = std.fmt.allocPrint(gpa, "provide: '{s}' is a race action — register a capability provider instead", .{action}) catch return;
        defer gpa.free(msg);
        if (p.in_dispatch or p.loading) {
            p.activeCtx().head.echo.clearRetainingCapacity();
            p.activeCtx().head.echo.appendSlice(gpa, msg) catch {};
        } else {
            std.log.warn("plugin '{s}': {s}", .{ p.name, msg });
        }
    };
}

/// The signal a split head-gated import returns on a missing dispatching
/// entry — see `fs.zig`'s `PermError` for the identical rationale one level
/// up the guard ladder (`shared.canDispatch` vs `shared.hasPerm`): the wasm
/// trampoline turns this into a trap (`shared.trapNotDispatching`); an
/// in-process caller lets it propagate as an ordinary Zig error.
pub const DispatchError = error{NotDispatching};

/// `weft.setMode(mode)` semantic body (task #19 item 3's POLICY DOOR,
/// HEAD-GATED per task #19 item 4 — W0b split, doc/extensibility-native-surface.md):
/// the mode-leak class's founding bug ("background forces a mode") is
/// `shared.canDispatch(id)` here — SAME check `requireDispatch`'s wasm trap
/// uses, shared not reimplemented. Compare `hMenuMode`/
/// `hRestingMode`/`hStickyMenu` below, which DECLARE a mode's system-scoped
/// TABLE properties and stay ungated (no split needed — they carry no head
/// state). Routes through `Ctx.enterMode` (never raw `Head`) — the SAME
/// policy door a host command handler uses — so entering a menu mode still
/// records its one-shot return target; host-side mode save/restore (the
/// picker) goes through the door's plain `setMode` instead and never
/// records (see `ctx.zig`'s `Ctx.enterMode` doc). `gpa` is separate from
/// `ctx.gpa` only because the wasm trampoline already has `p.gpa` in hand;
/// an in-process caller passes its own allocator (ordinarily the same one
/// `ctx.gpa` names).
pub fn setMode(gpa: Allocator, ctx: *command_mod.Context, id: anytype, mode: []const u8) DispatchError!void {
    if (!shared.canDispatch(id)) return error.NotDispatching;
    const c = ctx_mod.Ctx.capture(ctx);
    c.enterMode(ctx.keymap, mode) catch {};
    // Remember a RESTING mode as the active buffer's resting mode, so exiting a
    // transient sub-mode (insert/visual) returns HERE — this is what keeps a
    // tool projection (files) live after an in-place edit + Escape.
    if (ctx.keymap.isRestingMode(mode)) {
        const buf = ctx.buffers.active();
        const held = gpa.dupe(u8, mode) catch return;
        gpa.free(buf.mode);
        buf.mode = held;
    }
}

pub fn hSetMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    setMode(p.gpa, p.activeCtx(), p, mode) catch {
        shared.trapNotDispatching(p, caller, "wl_set_mode");
    };
}

/// `exitToResting()`: leave a transient mode (insert/visual) back to the active
/// buffer's RESTING mode — its own tool mode (files) if it has one, else the base
/// editing mode. Replaces a guest's hardcoded `setMode("normal")` on Escape, so a
/// projection's keys never sleep after an in-place edit.
pub fn hExitToResting(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // HEAD-GATED (task #19 item 4): same door as `wl_set_mode`, one hop
    // removed — it resolves the target mode, then calls through `Ctx.setMode`
    // (task #19 item 3: the policy door, not the raw mechanism).
    if (!requireDispatch(p, caller, "wl_exit_to_resting")) return;
    const ctx = p.activeCtx();
    const buf = ctx.buffers.active();
    // The buffer's declared resting mode (its tool mode, or the base it was
    // stamped with on open) — no core-baked mode name; the config owns what
    // "resting" means. An entry that never declared one rests where its
    // POSTURE says (§10.4), so Escape in a structural entry cannot land in
    // the text editing base.
    const target = if (buf.mode.len > 0) buf.mode else ctx.buffers.restingModeFor(ctx.posture());
    if (target.len == 0) return;
    const owned = p.gpa.dupe(u8, target) catch return;
    defer p.gpa.free(owned);
    const c = ctx_mod.Ctx.capture(ctx);
    c.setMode(owned) catch {};
}

pub fn hSetFallback(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    const parent = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(parent);
    p.activeCtx().keymap.setFallback(gpa, mode, parent) catch {};
}

pub fn hTextInput(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    if (args[4] == 0) {
        p.activeCtx().keymap.setCommitCommand(gpa, mode, null) catch {};
        return;
    }
    const cmd = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(cmd);
    p.activeCtx().keymap.setCommitCommand(gpa, mode, cmd) catch {};
}

pub fn hMenuMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.activeCtx().keymap.markMenuMode(p.gpa, mode) catch {};
}

/// `resting_mode(mode)`: declare a mode a buffer can rest in, so `baseMode` stops
/// there instead of overshooting to the root `default`.
pub fn hRestingMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.activeCtx().keymap.markRestingMode(p.gpa, mode) catch {};
}

/// `resting_posture(posture, mode)`: the GRAMMAR's half of §10.4 — the mode
/// it rests in for `posture`. System-scoped like the other mode-table
/// declarations (no head state), so it is legal from `init`, which is where
/// every grammar declares it.
pub fn hRestingPosture(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const posture = input.Posture.fromWire(@bitCast(args[0])) orelse return;
    const mode = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(mode);
    const ctx = p.activeCtx();
    ctx.buffers.setRestingFor(p.gpa, posture, mode) catch return;
    ctx.keymap.markRestingMode(p.gpa, mode) catch {};
}

/// `posture()`: read how the addressed entry rests (§10.4). The ONE read a
/// grammar needs — it asks the DECLARATION, never what tool it is looking at.
pub fn hPosture(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @bitCast(@intFromEnum(p.activeCtx().posture()));
}

/// `declare_posture(posture)`: the PRESENTATION OWNER's half of §10.4 —
/// override the derivation on the entry this dispatch addresses. HEAD-GATED
/// for the same reason `wl_set_mode` is (task #19 item 4): "background
/// declares a posture for whatever entry happens to be active" is the
/// founding mode-leak bug wearing a new hat.
pub fn hDeclarePosture(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (!requireDispatch(p, caller, "wl_declare_posture")) return;
    const posture = input.Posture.fromWire(@bitCast(args[0])) orelse return;
    p.activeCtx().buffer().declarePosture(posture);
}

/// `sticky_menu(mode)`: mark a menu mode STICKY — it stays open after a leaf
/// key (flag-accumulating transients) instead of one-shot auto-popping.
pub fn hStickyMenu(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.activeCtx().keymap.markStickyMenu(p.gpa, mode) catch {};
}

// ── Reading the tables ───────────────────────────────────────────────
//
// `menu.zig`'s `wl_menu_binding_*` reads the current head's RESOLVED MENU
// LIST — head-scoped, mode-scoped, and scoped to the chord being typed. It is
// what which-key needs and it cannot answer "which key runs this command",
// in this mode or any other, because it never sees a mode it is not standing
// in.
//
// These two read the TABLES instead — the thing `Keymap.zig` says it owns
// ("everything that describes what a mode IS"), with the mode named
// explicitly rather than taken from a head.
//
// LISTINGS, not indexed accessors. Five indexed doors (mode_count/mode_name/
// binding_count/binding_key/binding_cmd) would re-run `resolveBindingsInto`
// — an allocating fallback-chain walk — once per index, which is O(n²) plus
// a per-call allocation, and the only escape is a resolved-list cache in core
// (what `Head` keeps for the menu doors). Two listing doors have neither
// problem, and they put the parsing where the policy already is: a guest
// deciding what "the key for this command" means.
//
// Both use `writeExact`, so a table too big for the caller's buffer says so
// (-2) instead of silently arriving half-length. Half a keymap looks exactly
// like a small keymap.

/// Every mode with a binding table, newline-joined, in declaration order.
/// Caller owns the bytes.
pub fn modeNames(gpa: Allocator, km: *const Keymap) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (km.modes.keys(), 0..) |name, i| {
        if (i > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, name);
    }
    return out.toOwnedSlice(gpa);
}

/// Mode `mode`'s bindings RESOLVED through its fallback chain, one per line
/// as `<key>\t<command>`. Caller owns the bytes.
///
/// The key is the DISPLAY form (`Keymap.displayKey`: `SPC g s`), matching
/// `wl_menu_binding_key` exactly. The canonical stored form is deliberately
/// not exposed: no consumer needs it, and shipping both spellings of one key
/// through the membrane is an invitation to compare the wrong one.
pub fn bindingTable(gpa: Allocator, km: *const Keymap, mode: []const u8) Allocator.Error![]u8 {
    var bindings: std.ArrayList(Keymap.Binding) = .empty;
    defer bindings.deinit(gpa);
    var groups: std.ArrayList(bool) = .empty;
    defer groups.deinit(gpa);
    _ = try km.resolveBindingsInto(gpa, mode, &bindings, &groups);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var dbuf: [256]u8 = undefined;
    for (bindings.items, 0..) |b, i| {
        if (i > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, km.displayKey(&dbuf, b.key));
        try out.append(gpa, '\t');
        try out.appendSlice(gpa, b.command);
    }
    return out.toOwnedSlice(gpa);
}

pub fn hModeNames(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const listing = modeNames(p.gpa, p.activeCtx().keymap) catch {
        results[0] = -1;
        return;
    };
    defer p.gpa.free(listing);
    shared.writeExact(caller, args, results, listing);
}

pub fn hBindingTable(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(mode);
    const listing = bindingTable(gpa, p.activeCtx().keymap, mode) catch {
        results[0] = -1;
        return;
    };
    defer gpa.free(listing);
    shared.writeExact(caller, args[2..], results, listing);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "the binding table resolves the fallback chain, and a chord is one row" {
    const gpa = t.allocator;
    var km: Keymap = .empty;
    defer km.deinit(gpa);

    // `visual` falls back to `normal`: a reader standing in `visual` must see
    // what `visual` would actually run, which includes what it inherits. This
    // is the difference from `Keymap.bindingAt`, which sees one table.
    try km.bind(gpa, "normal", "d", "delete", 0, "test");
    try km.bind(gpa, "normal", "space g s", "git-status", 0, "test");
    try km.bind(gpa, "visual", "y", "yank", 0, "test");
    try km.setFallback(gpa, "visual", "normal");

    const listing = try bindingTable(gpa, &km, "visual");
    defer gpa.free(listing);

    // A chord is ONE row carrying the whole sequence, not one row per key —
    // "which key runs git-status" has a single answer and this is it.
    try t.expect(std.mem.indexOf(u8, listing, "git-status") != null);
    var saw_own = false;
    var saw_inherited = false;
    var expect_buf: [256]u8 = undefined;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const cmd = line[tab + 1 ..];
        if (std.mem.eql(u8, cmd, "yank")) saw_own = true;
        if (std.mem.eql(u8, cmd, "delete")) saw_inherited = true;
        if (std.mem.eql(u8, cmd, "git-status")) {
            // The DISPLAY form, matching `wl_menu_binding_key` — a reader
            // renders this, it never feeds it back to a lookup.
            try t.expectEqualStrings(km.displayKey(&expect_buf, "space g s"), line[0..tab]);
        }
    }
    try t.expect(saw_own);
    try t.expect(saw_inherited);

    // An undeclared mode is not an error: it inherits `global` and nothing
    // else, which is honestly "no bindings here".
    const none = try bindingTable(gpa, &km, "no-such-mode");
    defer gpa.free(none);
    try t.expectEqualStrings("", none);

    const names = try modeNames(gpa, &km);
    defer gpa.free(names);
    try t.expect(std.mem.indexOf(u8, names, "normal") != null);
    try t.expect(std.mem.indexOf(u8, names, "visual") != null);
}
