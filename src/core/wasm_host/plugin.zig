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

/// The membrane's ONE deny path: every perm-gated host import calls this
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
    if (p.perms[@intFromEnum(perm)]) return true;
    caller.trap("plugin '{s}' denied capability '{s}' (not requested in describe())", .{ p.name, perm.label() });
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
