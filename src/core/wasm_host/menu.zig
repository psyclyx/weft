//! Menu bindings + on_menu: which-key (a guest) reads the CURRENT menu mode's
//! table by index during its on_menu(open) and renders it into a surface. Core
//! owns WHEN (fired at the frame boundary, top-level — see notifyMenu).

const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

// which-key enumerates the CHOICES available right now. Mid-chord (a pending
// key sequence — `space f`) it lists that prefix's next-key COMPLETIONS (`f`, `r`
// …), the leader tree as sequences. At rest / on an F1 peek it lists the current
// mode's top-level choices (`completions("")` — segments deduped, a chord-opener
// shown as a group). A legacy menu MODE (still-migrating config) falls back to
// the mode's whole resolved table. Either way `key`/`cmd`/`group` index the built
// list; the guest enumerates synchronously in one `on_menu`.
pub fn hMenuBindingCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const km = p.ctx.keymap;
    const n = if (km.pending.len > 0)
        km.completions(p.gpa, km.pending) catch 0
    else if (km.isMenuMode(km.currentMode()))
        km.resolveBindings(p.gpa, km.currentMode()) catch 0
    else
        km.completions(p.gpa, "") catch 0;
    results[0] = @intCast(n);
}
pub fn hMenuBindingKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = p.ctx.keymap.resolvedAt(@intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    // which-key shows keys in the config's notation ("SPC :"), not the canonical
    // stored form ("space colon") — display only; logic uses the canonical key.
    var dbuf: [256]u8 = undefined;
    const disp = p.ctx.keymap.displayKey(&dbuf, b.key);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), disp) catch 0);
}
pub fn hMenuBindingCmd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = p.ctx.keymap.resolvedAt(@intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), b.command) catch 0);
}

/// Whether the `i`-th entry is a GROUP (opens a submenu / continues a chord)
/// rather than a runnable leaf — computed when the list was built (a chord
/// completion with more keys after it, or a legacy binding onto a menu mode).
pub fn hMenuBindingIsGroup(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = if (p.ctx.keymap.resolvedIsGroup(@intCast(args[0]))) 1 else 0;
}

/// Fire a guest's `on_menu(open)` — a menu mode was entered (open=1) or left
/// (open=0). Called at the FRAME boundary (top-level, never nested inside
/// another guest call), so a menu-owner plugin re-entering its own wasmtime
/// store is impossible. Guests without the export are skipped.
pub fn notifyMenu(p: *WasmPlugin, open: bool) void {
    contract.callOptionalExport("on_menu", &p.instance, .{@as(i32, if (open) 1 else 0)}) catch {};
}
