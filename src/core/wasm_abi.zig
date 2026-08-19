//! wasm_abi — run a `.wasm` plugin against the weft ABI. The host defines the
//! `weft.*` functions the guest imports, marshalling each to
//! `command.Context`: `cursor` reads the caret; `edit` reads the guest's
//! bytes out of its linear memory and applies them through `Context.edit` —
//! the SAME grade gate, authored as the plugin's own peer. This is plan 05's
//! core: a plugin compiled to `.wasm` reaches the editor only across the
//! sandbox membrane, yet lands its edits on the identical authority path an
//! in-process catalog plugin uses. The full ABI (log/kv/layers/pick/…) marshals
//! the same way — one host function per import; this proves the shape.

const std = @import("std");

// The bulk lives in leaves: WasmPlugin + membrane handle types in
// `wasm_abi/plugin.zig`, the runGuest/load path in `wasm_abi/runtime.zig`, and
// the membrane test suite in `wasm_abi/tests.zig`. This facade re-exports the
// public surface so `core.wasm_abi.X` is unchanged, and pulls the tests in.
const plugin_mod = @import("wasm_abi/plugin.zig");
pub const WasmPlugin = plugin_mod.WasmPlugin;
pub const SyntaxResolver = plugin_mod.SyntaxResolver;
pub const perm_count = plugin_mod.perm_count;
pub const WasmCmd = plugin_mod.WasmCmd;
pub const PendingItem = plugin_mod.PendingItem;
pub const WasmBoundPick = plugin_mod.WasmBoundPick;
pub const StampSlot = plugin_mod.StampSlot;
pub const QueryCap = plugin_mod.QueryCap;

const runtime = @import("wasm_abi/runtime.zig");
pub const guest_hello = runtime.guest_hello;
pub const runGuest = runtime.runGuest;
pub const LoadOptions = runtime.LoadOptions;
pub const loadPlugin = runtime.loadPlugin;

test {
    std.testing.refAllDecls(@This());
    _ = @import("wasm_abi/tests.zig");
}
