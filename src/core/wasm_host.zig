//! wasm_host — the `weft.*` host-import table: one small function per abi.Abi
//! method the guest shim (src/guest/weft.zig) imports, each marshalling to
//! command.Context across the sandbox membrane, plus the trampolines that
//! dispatch back into the guest (commands, pick accept, completion provider)
//! and the deferred shell-insert machinery. Split from wasm_abi.zig — which
//! owns the WasmPlugin lifecycle + handshake — to keep each file focused on
//! one concern; the two @import each other (Zig permits the cycle).
//!
//! `defineImports` itself no longer hand-lists the ~123 imports: it walks
//! `membrane/contract.zig`'s comptime table, the one place name/arity/handler
//! are declared together (see that file for the drift-killing rationale).
//! Handler bodies stay exactly where they were, in wasm_host/*.zig.

const wasm = @import("wasm.zig");

// The lifecycle side owns the plugin type; `defineImports` binds over it. The
// two @import each other (Zig permits the file-level cycle).
const wasm_abi = @import("wasm_abi.zig");
const WasmPlugin = wasm_abi.WasmPlugin;

const contract = @import("membrane/contract.zig");

// The shared leaf every handler group imports (WasmPlugin, perms, environ,
// the peer resolver). Re-exported below so `core.wasm_host.X` is unchanged.
const plugin = @import("wasm_host/plugin.zig");
pub const perm_fs_read = plugin.perm_fs_read;
pub const perm_fs_write = plugin.perm_fs_write;
pub const perm_net = plugin.perm_net;
pub const perm_proc = plugin.perm_proc;
pub const perm_timer = plugin.perm_timer;
pub const setEnviron = plugin.setEnviron;
pub fn hostEnviron() @import("std").process.Environ {
    return plugin.g_environ;
}
pub const resolvePeerWp = plugin.resolvePeerWp;

const layers = @import("wasm_host/layers.zig");
pub const Flash = layers.Flash;
pub const flashState = layers.flashState;

const fs = @import("wasm_host/fs.zig");
pub const PeerFsBridge = fs.PeerFsBridge;
pub const setPeerFsBridge = fs.setPeerFsBridge;
pub const deliverToBuffer = fs.deliverToBuffer;

const activation = @import("wasm_host/activation.zig");
pub const notifyActivate = activation.notifyActivate;
pub const notifyPollIfReady = activation.notifyPollIfReady;

const sessions = @import("wasm_host/sessions.zig");
pub const drainReplSessions = sessions.drainReplSessions;

const menu = @import("wasm_host/menu.zig");
pub const notifyMenu = menu.notifyMenu;

/// Bind the full `weft.*` host-import membrane (the guest-side surface in
/// src/guest/weft.zig) by walking `membrane/contract.zig`'s table — one
/// `defineFn` per entry, tagged with the plugin so the callback recovers its
/// state. The contract table is the only place an import's name/arity/
/// handler are declared; nothing here hand-lists them anymore.
pub fn defineImports(linker: *wasm.Linker, p: *WasmPlugin) !void {
    for (contract.imports) |entry| {
        try linker.defineFn("weft", entry.name, entry.params.len, entry.results.len, entry.handler, p);
    }
}
