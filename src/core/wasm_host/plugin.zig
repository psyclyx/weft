//! Shared leaf for the `wasm_host` handler groups. Holds what every group needs
//! but nothing group-specific: the `WasmPlugin` type (re-exported from the
//! lifecycle side), the perm indices, the process environ the effect handlers
//! inherit, and the plugin edit-principal resolver. Each handler-group file
//! imports THIS file (never the `wasm_host.zig` facade), so the groups never
//! form an import cycle among themselves — the facade imports both.

const std = @import("std");
const Document = @import("../Document.zig");

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
