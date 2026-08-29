//! wasm_abi — run a `.wasm` plugin against the weft ABI. The host defines the
//! `weft.*` functions the guest imports, marshalling each to
//! `command.Context`: `cursor` reads the caret; `edit` reads the guest's
//! bytes out of its linear memory and applies them through `Context.edit` —
//! the SAME grade gate, authored as the plugin's own peer. This is plan 05's
//! core: a plugin compiled to `.wasm` reaches the editor only across the
//! sandbox membrane, and its edits land on the ordinary authority path — the
//! one core's own effects take. The full ABI (log/kv/layers/pick/…) marshals
//! the same way — one host function per import; this proves the shape.

const std = @import("std");

// The bulk lives in leaves: WasmPlugin + membrane handle types in
// `wasm_abi/WasmPlugin.zig`, the runGuest/load path in `wasm_abi/runtime.zig`, and
// the membrane test suite in `wasm_abi/tests.zig`. This facade re-exports the
// public surface so `core.wasm_abi.X` is unchanged, and pulls the tests in.
pub const WasmPlugin = @import("wasm_abi/WasmPlugin.zig");
pub const SyntaxResolver = WasmPlugin.SyntaxResolver;
pub const perm_count = WasmPlugin.perm_count;
pub const WasmCmd = WasmPlugin.WasmCmd;
pub const PendingItem = WasmPlugin.PendingItem;
pub const WasmBoundPick = WasmPlugin.WasmBoundPick;
pub const RangeSlot = WasmPlugin.RangeSlot;
pub const QueryCap = WasmPlugin.QueryCap;

const runtime = @import("wasm_abi/runtime.zig");
pub const guest_hello = runtime.guest_hello;
pub const runGuest = runtime.runGuest;
pub const LoadOptions = runtime.LoadOptions;
pub const loadPlugin = runtime.loadPlugin;

test {
    std.testing.refAllDecls(@This());
    _ = @import("wasm_abi/tests.zig");
}
