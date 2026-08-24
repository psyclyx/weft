//! Generic semantic-view introspection and action dispatch for editor plugins.
//!
//! Input plugins see only whether the dispatching head has a semantic view and
//! an open action name. They never learn a tool kind or call dired directly.

const wasm = @import("../wasm.zig");
const kernel = @import("weft_kernel");
const scene_codec = @import("weft_scene_codec");
const wire_util = @import("semantic_wire.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requireDispatch = shared.requireDispatch;

/// Action identifiers are protocol names, not an unbounded payload channel.
/// Keep this admission limit local to the transport; the kernel deliberately
/// leaves the open action namespace extensible.
const max_action_bytes = 4096;

fn optionalTarget(args: []const i32) error{InvalidHandle}!?kernel.target.Ref {
    const authority: u32 = @bitCast(args[0]);
    const slot: u32 = @bitCast(args[1]);
    const generation: u32 = @bitCast(args[2]);
    if (generation == 0) {
        if (authority != 0 or slot != 0) return error.InvalidHandle;
        return null;
    }
    return kernel.target.Ref.fromWire(.{ .authority = authority, .slot = slot, .generation = generation });
}

fn readPayload(plugin: *WasmPlugin, caller: *wasm.Caller, ptr: i32, len: i32) ?[]u8 {
    return wire_util.readBounded(plugin.gpa, caller, ptr, len, 1, scene_codec.Limits.max_payload_bytes);
}

/// Publish a provider-neutral target definition encoded by the canonical
/// scene codec. The host owns the admitted clone; guest memory is borrowed
/// only for this call. Returns 1 and writes a typed handle on success.
pub fn hSemanticTargetPublish(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const services = plugin.activeCtx().semantic orelse return;
    const payload = readPayload(plugin, caller, args[0], args[1]) orelse return;
    defer plugin.gpa.free(payload);
    var decoded = scene_codec.decodeTarget(plugin.gpa, payload) catch return;
    defer decoded.deinit();
    const ref = services.publishTarget(plugin.gpa, plugin.name, decoded.value) catch return;
    if (!wire_util.writeHandle(caller, @bitCast(args[2]), @bitCast(args[3]), ref)) {
        _ = services.closeTarget(plugin.gpa, plugin.name, ref);
        return;
    }
    results[0] = 1;
}

pub fn hSemanticTargetReplace(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const services = plugin.activeCtx().semantic orelse return;
    const ref = wire_util.readHandle(kernel.target.Ref, args[0..3]) orelse return;
    const payload = readPayload(plugin, caller, args[3], args[4]) orelse return;
    defer plugin.gpa.free(payload);
    var decoded = scene_codec.decodeTarget(plugin.gpa, payload) catch return;
    defer decoded.deinit();
    services.replaceTarget(plugin.gpa, plugin.name, ref, decoded.value) catch return;
    results[0] = 1;
}

pub fn hSemanticTargetClose(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const services = plugin.activeCtx().semantic orelse {
        results[0] = 0;
        return;
    };
    const ref = wire_util.readHandle(kernel.target.Ref, args[0..3]) orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intFromBool(services.closeTarget(plugin.gpa, plugin.name, ref));
}

/// Publish a retained semantic scene. A generation-zero all-zero target wire
/// means no target; any live target remains independently generation checked.
pub fn hSemanticViewPublish(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const services = plugin.activeCtx().semantic orelse return;
    const payload = readPayload(plugin, caller, args[0], args[1]) orelse return;
    defer plugin.gpa.free(payload);
    const target = optionalTarget(args[2..5]) catch return;
    var decoded = scene_codec.decodeScene(plugin.gpa, payload) catch return;
    defer decoded.deinit();
    const revision: u32 = @bitCast(args[5]);
    const ref = services.publishView(plugin.gpa, plugin.name, target, revision, decoded.root.*) catch return;
    if (!wire_util.writeHandle(caller, @bitCast(args[6]), @bitCast(args[7]), ref)) {
        _ = services.closeView(plugin.gpa, plugin.name, ref);
        return;
    }
    results[0] = 1;
}

pub fn hSemanticViewReplace(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const services = plugin.activeCtx().semantic orelse return;
    const ref = wire_util.readHandle(kernel.view.Ref, args[0..3]) orelse return;
    const revision: u32 = @bitCast(args[3]);
    const payload = readPayload(plugin, caller, args[4], args[5]) orelse return;
    defer plugin.gpa.free(payload);
    var decoded = scene_codec.decodeScene(plugin.gpa, payload) catch return;
    defer decoded.deinit();
    services.replaceView(plugin.gpa, plugin.name, ref, revision, decoded.root.*) catch return;
    results[0] = 1;
}

pub fn hSemanticViewClose(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const services = plugin.activeCtx().semantic orelse {
        results[0] = 0;
        return;
    };
    const ref = wire_util.readHandle(kernel.view.Ref, args[0..3]) orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intFromBool(services.closeView(plugin.gpa, plugin.name, ref));
}

pub fn hSemanticActive(data: ?*anyopaque, _: *wasm.Caller, _: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const services = plugin.activeCtx().semantic orelse {
        results[0] = 0;
        return;
    };
    results[0] = @intFromBool(services.hasActiveView(plugin.activeCtx().head));
}

/// Attach a live semantic view to the dispatching head. NodeId is a u64 in
/// the kernel, so the wasm32 ABI carries explicit low/high words plus a
/// presence bit; neither side narrows it through an i32 result or handle.
pub fn hSemanticViewFocus(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    if (!requireDispatch(plugin, caller, "wl_semantic_view_focus")) return;
    const ref = wire_util.readHandle(kernel.view.Ref, args[0..3]) orelse return;
    const has_preferred: u32 = @bitCast(args[5]);
    if (has_preferred > 1) return;
    const preferred: ?kernel.scene.NodeId = if (has_preferred == 0) null else blk: {
        const low: u64 = @as(u64, @as(u32, @bitCast(args[3])));
        const high: u64 = @as(u64, @as(u32, @bitCast(args[4])));
        break :blk @enumFromInt((high << 32) | low);
    };
    const ctx = plugin.activeCtx();
    const services = ctx.semantic orelse return;
    _ = services.focusView(ctx.head, plugin.gpa, ref, preferred) catch return;
    results[0] = 1;
}

/// Decode a bounded canonical interaction definition and open it on the
/// dispatching head's local stack. The typed ref is written last; if guest
/// output is invalid, roll back the newly opened scope before returning.
pub fn hSemanticInteractionOpen(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    if (!requireDispatch(plugin, caller, "wl_semantic_interaction_open")) return;
    const ctx = plugin.activeCtx();
    const services = ctx.semantic orelse return;
    const payload = readPayload(plugin, caller, args[0], args[1]) orelse return;
    defer plugin.gpa.free(payload);
    var decoded = scene_codec.decodeInteraction(plugin.gpa, payload) catch return;
    defer decoded.deinit();
    const ref = services.openInteraction(&ctx.head.interactions, plugin.gpa, decoded.value) catch return;
    if (!wire_util.writeHandle(caller, @bitCast(args[2]), @bitCast(args[3]), ref)) {
        _ = services.closeInteraction(&ctx.head.interactions, plugin.gpa, ref);
        return;
    }
    results[0] = 1;
}

/// Close only the active interaction named by the typed ref. A stale or
/// buried ref returns 0 and leaves the head-local stack unchanged.
pub fn hSemanticInteractionClose(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    if (!requireDispatch(plugin, caller, "wl_semantic_interaction_close")) return;
    const ctx = plugin.activeCtx();
    const services = ctx.semantic orelse return;
    const ref = wire_util.readHandle(kernel.interaction.Ref, args[0..3]) orelse return;
    results[0] = @intFromBool(services.closeInteraction(&ctx.head.interactions, plugin.gpa, ref));
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
