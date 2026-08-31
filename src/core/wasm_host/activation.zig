//! Activation (design §3): the host tells a plugin which buffer took focus so it
//! can attach language keymaps/facts; the guest reads that path back during the
//! `on_activate` dispatch.

const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// Fire the activation event (design §3): tell a plugin a buffer with `path`
/// took focus, so it can attach language keymaps/facts. A no-op for a plugin
/// that doesn't export `on_activate`. The plugin is resident, so this host→
/// guest call can never use-after-free. The path is borrowed for the call.
pub fn notifyActivate(p: *WasmPlugin, path: []const u8) void {
    p.cur_activate_path = path;
    defer p.cur_activate_path = &.{};
    contract.callOptionalExport("on_activate", &p.instance, .{}) catch {}; // MissingExport → skip
}

/// Service a plugin's async proc I/O — but only when there's something to do.
/// A plugin "registers" interest by opening a raw proc stream (`wl_proc_spawn`);
/// the host calls its `on_poll` export ONLY when one of those streams has bytes
/// pending. So idle plugins (and every plugin without a stream) cost nothing —
/// this is readiness-driven, not a blind per-frame poll. Returns whether it ran.
pub fn notifyPollIfReady(p: *WasmPlugin) bool {
    const ready = for (p.proc_streams.slice()) |maybe| {
        if (maybe) |s| if (s.pending() > 0) break true;
    } else false;
    if (!ready) return false;
    contract.callOptionalExport("on_poll", &p.instance, .{}) catch {}; // MissingExport → skip
    return true;
}

pub fn hActivatePath(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), p.cur_activate_path) catch 0);
}
