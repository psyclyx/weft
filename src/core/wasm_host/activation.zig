//! Activation (design §3): the host tells a plugin which buffer took focus so it
//! can attach language keymaps/facts; the guest reads that path back during the
//! `on_activate` dispatch.

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// Fire the activation event (design §3): tell a plugin a buffer with `path`
/// took focus, so it can attach language keymaps/facts. A no-op for a plugin
/// that doesn't export `on_activate`. The plugin is resident, so this host→
/// guest call can never use-after-free. The path is borrowed for the call.
pub fn notifyActivate(p: *WasmPlugin, path: []const u8) void {
    p.cur_activate_path = path;
    defer p.cur_activate_path = &.{};
    p.instance.callVoid("on_activate", &.{}) catch {}; // MissingExport → skip
}

pub fn hActivatePath(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), p.cur_activate_path) catch 0);
}
