//! Shared leaf for the `wasm_host` handler groups. Holds what every group needs
//! but nothing group-specific: the `WasmPlugin` type (re-exported from the
//! lifecycle side), the perm indices, the process environ the effect handlers
//! inherit, and the plugin edit-principal resolver. Each handler-group file
//! imports THIS file (never the `wasm_host.zig` facade), so the groups never
//! form an import cycle among themselves — the facade imports both.

const std = @import("std");
const Document = @import("../Document.zig");
const wasm = @import("../wasm.zig");

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

    fn label(self: Perm) []const u8 {
        return switch (self) {
            .fs_read => "fs_read",
            .fs_write => "fs_write",
            .net => "net",
            .proc => "proc",
            .timer => "timer",
        };
    }
};

/// The PURE grant check (W0b — doc/north-star-plan.md §2.5): whether `id`
/// declared `perm`. Deliberately `anytype`, not `*WasmPlugin`: this is the
/// ONE piece of logic that must never drift between the wasm transport and
/// the in-process transport (C7's "one contract, two transports"), so it is
/// factored out where BOTH `requirePerm` (below, wasm) and
/// `core/inproc/InProcClient.zig` (in-process) call it — neither
/// reimplements "is the bit set". `id` is duck-typed (a `perms:
/// [perm_count]bool` field) rather than a nominal shared struct: WasmPlugin
/// and InProcClient hold that field under the same name without either
/// depending on the other's type, mirroring `gfx/context.zig`'s
/// `assertPlatform`/`app/rasterizer.zig`'s comptime-contract convention
/// already used for the Platform/Rasterizer seams (P3) — see
/// `InProcClient.zig`'s `assertClientIdentity` for the analogous compile-time
/// check on this shape.
pub fn hasPerm(id: anytype, comptime perm: Perm) bool {
    return id.perms[@intFromEnum(perm)];
}

/// The wasm-specific half of denial: format + raise the trap. Split out of
/// `requirePerm` so a SPLIT handler's semantic body (which embeds `hasPerm`
/// itself — see e.g. `fs.zig`'s `fsRead`) can call this directly from its
/// wasm trampoline's `catch` arm, without re-deriving the message or
/// double-checking the bit `hasPerm` already decided. `requirePerm` below is
/// this plus the check, kept for the ~117 handlers not yet split (task W0b
/// item 1 — see doc/north-star-plan.md's honest coverage note): behavior is
/// byte-identical to before this refactor.
pub fn trapPermDenied(p: *WasmPlugin, caller: *wasm.Caller, comptime perm: Perm) void {
    caller.trap("plugin '{s}' denied capability '{s}' (not requested in describe())", .{ p.name, perm.label() });
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
