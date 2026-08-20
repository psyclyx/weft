//! Menu bindings + on_menu: which-key (a guest) reads the CURRENT menu mode's
//! table by index during its on_menu(open) and renders it into a surface. Core
//! owns WHEN (fired at the frame boundary, top-level — see notifyMenu).

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

// which-key enumerates the RESOLVED set of AVAILABLE bindings — the mode's own
// table PLUS everything reachable through its fallback chain and the global
// layer (a nearer mode's override wins) — not just the mode's own table. So the
// hint answers "what can I press here" (in dired: its nav keys AND the editing
// keys it inherits), independent of how many modes compose the context.
// `resolveBindings` builds the deduped list once in `count`; `key`/`cmd`/`group`
// index it (the guest enumerates synchronously in one `on_menu`).
pub fn hMenuBindingCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const km = p.ctx.keymap;
    results[0] = @intCast(km.resolveBindings(p.gpa, km.currentMode()) catch 0);
}
pub fn hMenuBindingKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = p.ctx.keymap.resolvedAt(@intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), b.key) catch 0);
}
pub fn hMenuBindingCmd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = p.ctx.keymap.resolvedAt(@intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), b.command) catch 0);
}

/// Whether the `i`-th binding is a GROUP (opens a submenu) rather than a leaf
/// command. Convention (see vim): a submenu-entry binds a key to a command
/// named the same as the menu mode it enters — so a binding is a group exactly
/// when its command is itself a registered menu mode. No bind-ABI change needed.
pub fn hMenuBindingIsGroup(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const km = p.ctx.keymap;
    const b = km.resolvedAt(@intCast(args[0])) orelse {
        results[0] = 0;
        return;
    };
    results[0] = if (km.isMenuMode(b.command)) 1 else 0;
}

/// Fire a guest's `on_menu(open)` — a menu mode was entered (open=1) or left
/// (open=0). Called at the FRAME boundary (top-level, never nested inside
/// another guest call), so a menu-owner plugin re-entering its own wasmtime
/// store is impossible. Guests without the export are skipped.
pub fn notifyMenu(p: *WasmPlugin, open: bool) void {
    p.instance.callVoid("on_menu", &.{@as(i32, if (open) 1 else 0)}) catch {};
}
