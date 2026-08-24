//! Generic semantic-view introspection and action dispatch for editor plugins.
//!
//! Input plugins see only whether the dispatching head has a semantic view and
//! an open action name. They never learn a tool kind or call dired directly.

const wasm = @import("../wasm.zig");
const std = @import("std");
const kernel = @import("weft_kernel");
const scene_codec = @import("weft_scene_codec");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requireDispatch = shared.requireDispatch;

/// Action identifiers are protocol names, not an unbounded payload channel.
/// Keep this admission limit local to the transport; the kernel deliberately
/// leaves the open action namespace extensible.
const max_action_bytes = 4096;

const handle_bytes = @sizeOf(kernel.handle.Wire);

fn readHandle(comptime Ref: type, args: []const i32) ?Ref {
    const wire: kernel.handle.Wire = .{
        .authority = @bitCast(args[0]),
        .slot = @bitCast(args[1]),
        .generation = @bitCast(args[2]),
    };
    if (wire.generation == 0) return null;
    return Ref.fromWire(wire);
}

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

fn writeHandle(caller: *wasm.Caller, out_ptr: u32, out_cap: u32, ref: anytype) bool {
    if (out_cap < handle_bytes) return false;
    const wire = ref.toWire();
    var bytes: [handle_bytes]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], wire.authority, .little);
    std.mem.writeInt(u32, bytes[4..8], wire.slot, .little);
    std.mem.writeInt(u32, bytes[8..12], wire.generation, .little);
    return (caller.writeMemory(out_ptr, out_cap, &bytes) catch return false) == handle_bytes;
}

fn readPayload(plugin: *WasmPlugin, caller: *wasm.Caller, ptr: i32, len: i32) ?[]u8 {
    const payload_len: u32 = @bitCast(len);
    if (payload_len == 0 or payload_len > scene_codec.Limits.max_payload_bytes) return null;
    const payload_ptr: u32 = @bitCast(ptr);
    return caller.readMemory(plugin.gpa, payload_ptr, payload_len) catch null;
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
    if (!writeHandle(caller, @bitCast(args[2]), @bitCast(args[3]), ref)) {
        _ = services.closeTarget(plugin.gpa, plugin.name, ref);
        return;
    }
    results[0] = 1;
}

pub fn hSemanticTargetReplace(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const services = plugin.activeCtx().semantic orelse return;
    const ref = readHandle(kernel.target.Ref, args[0..3]) orelse return;
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
    const ref = readHandle(kernel.target.Ref, args[0..3]) orelse {
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
    if (!writeHandle(caller, @bitCast(args[6]), @bitCast(args[7]), ref)) {
        _ = services.closeView(plugin.gpa, plugin.name, ref);
        return;
    }
    results[0] = 1;
}

pub fn hSemanticViewReplace(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const services = plugin.activeCtx().semantic orelse return;
    const ref = readHandle(kernel.view.Ref, args[0..3]) orelse return;
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
    const ref = readHandle(kernel.view.Ref, args[0..3]) orelse {
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
