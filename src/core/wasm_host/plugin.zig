//! Shared leaf for the `wasm_host` handler groups. Holds what every group needs
//! but nothing group-specific: the `WasmPlugin` type (re-exported from the
//! lifecycle side), the perm indices, the process environ the effect handlers
//! inherit, and the plugin edit-principal resolver. Each handler-group file
//! imports THIS file (never the `wasm_host.zig` facade), so the groups never
//! form an import cycle among themselves — the facade imports both.

const std = @import("std");
const Document = @import("../Document.zig");
const wasm = @import("../wasm.zig");
const grants_mod = @import("../grants.zig");

// The lifecycle side (wasm_abi) owns the plugin type; the handlers operate on
// it. The two @import each other (Zig permits the file-level cycle) — routing
// the type through this leaf keeps the handler groups off the facade.
const wasm_abi = @import("../wasm_abi.zig");
pub const WasmPlugin = wasm_abi.WasmPlugin;

pub const perm_fs_read = 0;
pub const perm_fs_write = 1;
pub const perm_net = 2;
pub const perm_proc = 3;
pub const perm_timer = 4;

/// The membrane's one grant-gate vocabulary (doc/architecture.md §2.4 /
/// doc/north-star-plan.md review C9), enum-closed so a new perm can't be
/// checked without a name for its trap message.
pub const Perm = enum(u32) {
    fs_read = perm_fs_read,
    fs_write = perm_fs_write,
    net = perm_net,
    proc = perm_proc,
    timer = perm_timer,

    pub fn label(self: Perm) []const u8 {
        return switch (self) {
            .fs_read => "fs_read",
            .fs_write => "fs_write",
            .net => "net",
            .proc => "proc",
            .timer => "timer",
        };
    }
};

/// Translate a plugin's DECLARED perms (the `describe()` boolean handshake)
/// into `grants.HandleTable` rows, at LOAD time (north-star-plan §6 W4 slice
/// 1, task item 1: "the System's grant table is POPULATED from the loaded
/// plugins' declared perms ... translated into GrantDecls, so the machinery
/// runs on real data without a new config verb"). Called once, from
/// `wasm_abi/runtime.zig`'s `loadPlugin` right after `describe()` finishes
/// (`perms` is final at that point) — a plugin loaded WITHOUT a table wired
/// (`opts.grant_table == null`, every headless test today) never calls this;
/// see `hasPerm`'s doc for what that means for it.
///
/// **The composition rule (W4 slice 4, north-star-plan §2.4)**: BEFORE
/// minting a fresh boolean-derived row for a declared perm, this checks
/// `table.findLive` for an ALREADY-live row on the exact same (principal,
/// capability) pair — one a config-authored `weft.grant`
/// (`manifest.zig`'s `reconcileGrants`) mints strictly before
/// this call runs (`Manifest.apply`/`.reconcile` order: grants, then
/// `loadPlugins`). If found, that row's handle is REUSED as-is — a
/// config-authored grant NARROWS/REPLACES the describe() baseline for that
/// pair, never sits alongside it as a second, unrestricted row a confused
/// deputy could reach for instead. If not found (the ordinary case — no
/// `weft.grant` named this plugin+capability), a fresh unrestricted
/// (`.none`-limit) row is minted exactly as before this slice. A `grant`
/// failure (OOM) degrades to `CapHandle.none` for that one perm — logged,
/// not fatal: the plugin loses that capability rather than the whole load
/// failing on an allocator hiccup unrelated to the wasm module itself.
pub fn mintGrantHandles(table: *grants_mod.HandleTable, principal: []const u8, perms: [WasmPlugin.perm_count]bool, out: *[WasmPlugin.perm_count]grants_mod.CapHandle) void {
    inline for (0..WasmPlugin.perm_count) |i| {
        if (perms[i]) {
            const p: Perm = @enumFromInt(i);
            if (table.findLive(principal, p.label())) |existing| {
                out[i] = existing;
            } else {
                out[i] = table.grant(.{ .capability = p.label() }, principal, null) catch blk: {
                    std.log.warn("wasm_host: plugin '{s}' — minting a grant-table row for '{s}' failed (OOM); that capability is UNAVAILABLE", .{ principal, p.label() });
                    break :blk grants_mod.CapHandle.none;
                };
            }
        }
    }
}

/// The PURE grant check (W0b — doc/north-star-plan.md §2.5, migrated to the
/// handle table by W4 §6/§2.4): whether `id` currently POSSESSES `perm`.
/// Deliberately `anytype`, not `*WasmPlugin`: this is the ONE piece of logic
/// that must never drift between the wasm transport and the in-process
/// transport (C7's "one contract, two transports"), so it is factored out
/// where BOTH `requirePerm` (below, wasm) and `core/inproc/InProcClient.zig`
/// (in-process) call it — neither reimplements the check. `id` is duck-typed
/// (`perms`/`grant_table`/`grant_handles` fields) rather than a nominal
/// shared struct: WasmPlugin and InProcClient hold them under the same
/// names without either depending on the other's type, mirroring
/// `gfx/context.zig`'s `assertPlatform`/`app/rasterizer.zig`'s
/// comptime-contract convention already used for the Platform/Rasterizer
/// seams (P3) — see `InProcClient.zig`'s `assertClientIdentity` for the
/// analogous compile-time check on this shape.
///
/// **The migration, precisely** (§6 W4 gate: "the hasPerm migration must be
/// behavior-identical for granted plugins"): when `id.grant_table` is wired
/// (a real `System`, or a test that opts in), the booleans are NOT the
/// checked state anymore — only `id.grant_handles[perm]`'s live table row is
/// (§2.4 "use = possession"). A revoked row fails here on its very next
/// check, with no re-read of `perms` at all — that's what makes revoking a
/// RUNNING plugin's capability take effect immediately. When NO table is
/// wired (`id.grant_table == null` — every construction that predates W4,
/// still the common case for bare unit-test fixtures), this degrades
/// EXACTLY to the pre-W4 boolean read: the machinery is simply absent, not
/// silently bypassed, so every existing test that pokes `.perms[i] = true`
/// directly (without ever touching a `HandleTable`) keeps behaving
/// identically.
pub fn hasPerm(id: anytype, comptime perm: Perm) bool {
    if (id.grant_table) |table| {
        return table.check(id.grant_handles[@intFromEnum(perm)]);
    }
    return id.perms[@intFromEnum(perm)];
}

/// `id`'s currently-possessed `Limit` for `perm` (W4 slice 2, task #8) — the
/// read side `wasm_host/fs.zig`'s split bodies consult AFTER `hasPerm`
/// already confirmed possession. Same duck-typed `anytype`/degrade story as
/// `hasPerm`: no table wired (`id.grant_table == null`, every pre-W4
/// construction and every test that doesn't opt in) → `.none` — the fs
/// bodies' existing cwd-relative, unconfined behavior, byte-identical to
/// before this slice (mintGrantHandles never sets anything but `.none` for a
/// boolean-derived grant either, so a real System degrades the same way
/// until something actually mints a limited row). Deliberately does NOT
/// re-check possession itself — a caller that hasn't already gated on
/// `hasPerm` shouldn't be asking "what's the limit" at all.
pub fn limitFor(id: anytype, comptime perm: Perm) grants_mod.Limit {
    if (id.grant_table) |table| {
        return table.limitFor(id.grant_handles[@intFromEnum(perm)]);
    }
    return .none;
}

/// The wasm-specific half of denial: format + raise the trap. Split out of
/// `requirePerm` so a SPLIT handler's semantic body (which embeds `hasPerm`
/// itself — see e.g. `fs.zig`'s `fsRead`) can call this directly from its
/// wasm trampoline's `catch` arm, without re-deriving the message or
/// double-checking the bit `hasPerm` already decided. `requirePerm` below is
/// this plus the check, kept for the ~117 handlers not yet split (task W0b
/// item 1 — see doc/north-star-plan.md's honest coverage note): behavior is
/// byte-identical to before this refactor, MODULO the message: a table-wired
/// plugin now gets a REVOCATION-specific reason, distinct from "never
/// requested" (§6 W4 gate) — a plugin with no table wired keeps the exact
/// pre-W4 wording, since there is no revocation state to distinguish.
pub fn trapPermDenied(p: *WasmPlugin, caller: *wasm.Caller, comptime perm: Perm) void {
    const reason: []const u8 = if (p.grant_table) |table| switch (table.reasonFor(p.grant_handles[@intFromEnum(perm)])) {
        .revoked => "revoked",
        .scope_expired => "scope expired",
        // `.ok`/`.never_granted` are the only reasons `hasPerm`'s FALSE result
        // can actually correspond to when no limit is in play (this function
        // is only ever called after `hasPerm` already said no); `.out_of_limit`/
        // `.collapsed` are never `reasonFor`'s answer (neither inspects paths
        // or documents — see `grants.Reason`'s doc) but the switch must stay
        // exhaustive over the shared enum, so both are bucketed with the same
        // wording, defensively.
        .never_granted, .ok, .out_of_limit, .collapsed => "not requested in describe()",
    } else "not requested in describe()";
    caller.trap("plugin '{s}' denied capability '{s}' ({s})", .{ p.name, perm.label(), reason });
}

/// The membrane's THIRD deny path (task #8 / W4 slice 2, alongside
/// `trapPermDenied`/`trapNotDispatching`): a `.fs_root`-limited grant IS
/// possessed (this only ever fires from a split body's `catch` arm on
/// `error.OutOfLimit`, which `fs.zig`'s bodies return ONLY after `hasPerm`
/// already passed), but `path` fell outside its root. Re-derives the root
/// via `limitFor` rather than threading it through every call site — a
/// second, cheap table read, no I/O — so the trap names BOTH the offending
/// path and the root it escaped (§6 W4 slice 2: "trapped with the path and
/// root named"). `root` is `"?"` only if this is ever called for a perm
/// whose CURRENT limit isn't `.fs_root` — defensive, not reachable through
/// `fs.zig`'s own call sites today.
pub fn trapOutOfLimit(p: *WasmPlugin, caller: *wasm.Caller, comptime perm: Perm, path: []const u8) void {
    const root: []const u8 = switch (limitFor(p, perm)) {
        .fs_root => |r| r,
        .none, .doc_region, .graph_subtree => "?", // this trap is fs-path-shaped; neither reaches it (see this fn's doc)
    };
    caller.trap("plugin '{s}' denied capability '{s}': path '{s}' is outside the granted root '{s}'", .{ p.name, perm.label(), path, root });
}

/// The membrane's ONE deny path: every perm-gated host import NOT YET split
/// into semantic-body-plus-trampoline (see `trapPermDenied`'s doc) calls this
/// before doing anything else. Granted → returns true, the site proceeds.
/// Denied → traps the guest's call right here (`caller.trap`, wasm.zig) and
/// returns false so the site's own `if (!requirePerm(...)) return;` reads as
/// the whole gate — there is no second way to spell "denied" at a call site,
/// so a site that forgets this call has no perm check at all (loud in
/// review), and no site can hand back a success-shaped value on denial
/// (doc/north-star-plan.md §2.4: "denied effects trap", review C9/[FIX 10]).
/// The trap message names the plugin and the missing capability; it surfaces
/// through the same guest-trap log path every other wasm trap already gets
/// (`wasm.zig`'s `checkErr`/`checkTrap`), so denial is loud exactly like any
/// other guest fault.
pub fn requirePerm(p: *WasmPlugin, caller: *wasm.Caller, comptime perm: Perm) bool {
    if (hasPerm(p, perm)) return true;
    trapPermDenied(p, caller, perm);
    return false;
}

/// The membrane's SECOND deny path (task #19 item 4, alongside `requirePerm`
/// above): every import that MUTATES per-head interaction state (mode/
/// pending/pick/echo — `Head.zig`'s module doc; NOT mode/menu/action TABLE
/// declarations, which are system-scoped, and NOT the buffer/editor-owned
/// cursor/selection — see `contract_data.zig`'s `.head_gated` doc for the
/// full boundary) calls this before touching `activeCtx().head`. TWO entry
/// classes admit it:
///   - In dispatch (`p.in_dispatch`, set by `wpCmdTrampoline`/
///     `wpPickAccept` for the DISPATCHING entries `on_command`/
///     `on_pick_accept`) — the ordinary case, exactly like `requirePerm`.
///   - Loading (`p.loading`, set by `loadPlugin` around `describe()`+
///     `init()` — see that field's doc for why setting the STARTING mode
///     during load can't hijack a second head: there isn't one yet).
/// Outside BOTH (every other BACKGROUND entry — `on_activate`/`on_poll`/
/// `on_fill`/`on_complete`/`on_menu`, none of which carry a real dispatching
/// head, AND none of which are the one-time load handshake) → traps the
/// guest's call right here (`caller.trap`, same as `requirePerm`) and
/// returns false, so `if (!requireDispatch(...)) return;` reads as the whole
/// gate — same shape, same trap-message discipline, same "no site can hand
/// back a success-shaped value on denial" property `requirePerm`'s doc
/// states. A background entry that legitimately needs to reach the head
/// AFTER load (an async LSP response landing off `on_poll` that wants to
/// echo a result, say) has ONE sanctioned door: dispatch itself back in
/// through `wl_run` — a real command name, cross-checked at registration
/// like any other — which re-enters `wpCmdTrampoline` and is a DISPATCHING
/// entry by definition, promoting `in_dispatch` to true for the nested
/// call's duration (see that trampoline's doc). There is no OTHER way to
/// spell "background, but make an exception" — exactly the point.
/// The PURE dispatch-entry check — `id`'s counterpart to `hasPerm` above,
/// same rationale (duck-typed `anytype`, shared unconditionally by both
/// transports so the two entry classes it admits — dispatching, and the
/// one-time load handshake — can never drift between a wasm trap and an
/// in-process error). `id` needs `in_dispatch: bool` and `loading: bool`.
pub fn canDispatch(id: anytype) bool {
    return id.in_dispatch or id.loading;
}

/// wasm-specific denial half — see `trapPermDenied`'s doc for why this is
/// split out (a split handler's semantic body calls this from its
/// trampoline's `catch`, in-process code never does).
pub fn trapNotDispatching(p: *WasmPlugin, caller: *wasm.Caller, comptime verb: []const u8) void {
    caller.trap("plugin '{s}' called {s} from a background entry — head state requires a dispatching entry (on_command/on_pick_accept, or a nested wl_run) or the load handshake (describe/init)", .{ p.name, verb });
}

pub fn requireDispatch(p: *WasmPlugin, caller: *wasm.Caller, comptime verb: []const u8) bool {
    if (canDispatch(p)) return true;
    trapNotDispatching(p, caller, verb);
    return false;
}

/// The parent process's environment, so a `proc` child inherits PATH (nix
/// tools like `rg`/`zig` are NOT on /bin/sh's built-in path). Set once at
/// startup from `main`; empty in tests (the child falls back to sh's default
/// PATH, which finds common tools like `git`).
pub var g_environ: std.process.Environ = .empty;
pub fn setEnviron(env: std.process.Environ) void {
    g_environ = env;
}

pub fn resolvePeerWp(ctx: *anyopaque, doc: *Document) Document.AddPeerError!Document.PeerId {
    const p: *WasmPlugin = @ptrCast(@alignCast(ctx));
    // Author as the overridden agent identity when one is set (a wl_edit_as
    // call), else as the plugin's own peer. The peer name IS the CRDT identity,
    // so a distinct name → a distinct sub-peer → per-agent selective undo.
    return doc.peerNamed(p.gpa, p.author_override orelse p.name);
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "mintGrantHandles: the composition rule — a pre-existing config-authored row is REUSED, never duplicated" {
    const gpa = t.allocator;
    var table = grants_mod.HandleTable.init(gpa);
    defer table.deinit();

    // A config-authored `weft.grant("git", "fs_write", {root: "repo"})` has
    // already minted its row (`manifest.zig`'s `reconcileGrants`, which the
    // real pipeline always runs BEFORE `loadPlugin`/`mintGrantHandles` — see
    // this function's doc).
    const configured = try table.grant(.{ .capability = "fs_write", .limit = .{ .fs_root = "repo" } }, "git", null);

    // `describe()` ALSO asked for fs_write (the ordinary boolean handshake) —
    // and, say, fs_read, which config never mentioned.
    var perms: [WasmPlugin.perm_count]bool = @splat(false);
    perms[perm_fs_write] = true;
    perms[perm_fs_read] = true;
    var handles: [WasmPlugin.perm_count]grants_mod.CapHandle = @splat(grants_mod.CapHandle.none);
    mintGrantHandles(&table, "git", perms, &handles);

    // fs_write: the plugin's possessed handle IS the config-authored row —
    // same idx/gen, not a second, unrestricted duplicate.
    try t.expectEqual(configured.idx, handles[perm_fs_write].idx);
    try t.expectEqual(configured.gen, handles[perm_fs_write].gen);
    switch (table.limitFor(handles[perm_fs_write])) {
        .fs_root => |root| try t.expectEqualStrings("repo", root),
        .none, .doc_region, .graph_subtree => return error.TestUnexpectedResult,
    }
    // Exactly ONE live row exists for (git, fs_write) — the boolean baseline
    // was never separately minted.
    var live_fs_write: usize = 0;
    for (table.rows.items) |r| {
        if (r.alive and std.mem.eql(u8, r.principal, "git") and std.mem.eql(u8, r.capability, "fs_write")) live_fs_write += 1;
    }
    try t.expectEqual(@as(usize, 1), live_fs_write);

    // fs_read: config never granted it — the ordinary unrestricted
    // boolean-derived row is minted, exactly as before this slice.
    try t.expect(table.check(handles[perm_fs_read]));
    try t.expectEqual(grants_mod.Limit.none, table.limitFor(handles[perm_fs_read]));

    // Revoking the config grant leaves fs_write with nothing to fall back
    // to (the composition rule's honest consequence — see grants.zig's
    // module doc): no separate baseline row exists to "return".
    _ = table.revoke("git", "fs_write");
    try t.expect(!table.check(handles[perm_fs_write]));
}
