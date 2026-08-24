//! Generic semantic-view introspection and action dispatch for editor plugins.
//!
//! Input plugins see only whether the dispatching head has a semantic view and
//! an open action name. They never learn a tool kind or call dired directly.

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requireDispatch = shared.requireDispatch;

/// Action identifiers are protocol names, not an unbounded payload channel.
/// Keep this admission limit local to the transport; the kernel deliberately
/// leaves the open action namespace extensible.
const max_action_bytes = 4096;

pub fn hSemanticActive(data: ?*anyopaque, _: *wasm.Caller, _: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const services = plugin.activeCtx().semantic orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intFromBool(services.hasActiveView(plugin.activeCtx().head));
}

/// Return values are transport status, not policy: 0 unavailable/declined,
/// 1 handled, 2 transfer stored, 3 interaction opened, -1 refused/failed.
pub fn hSemanticAction(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    if (!requireDispatch(plugin, caller, "wl_semantic_action")) return;
    const action_ptr: u32 = @bitCast(args[0]);
    const action_len: u32 = @bitCast(args[1]);
    if (action_len == 0 or action_len > max_action_bytes) return;
    const action = caller.readMemory(plugin.gpa, action_ptr, action_len) catch return;
    defer plugin.gpa.free(action);
    const ctx = plugin.activeCtx();
    const services = ctx.semantic orelse {
        results[0] = 0;
        return;
    };
    const effect = services.invokeFocusedAction(&ctx.head.interactions, ctx.head, plugin.gpa, action) catch return;
    results[0] = if (effect) |value| switch (value) {
        .declined => 0,
        .handled => 1,
        .transfer_stored => 2,
        .interaction_opened => 3,
    } else 0;
}
