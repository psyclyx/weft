//! Wasm transport for tokenized semantic target handlers.
//!
//! Probes receive immutable descriptors and opens receive revision-stamped
//! locations. Canonical request bytes are borrowed only during the synchronous
//! guest callback; the bridge retains no guest pointer or linear-memory slice.

const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");
const semantic = @import("weft_semantic");
const plugin_semantic = @import("weft_plugin_semantic");
const scene_codec = @import("weft_scene_codec");
const target_runtime = @import("weft_target_runtime");
const wire_util = @import("semantic_wire.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

const max_handler_id_bytes = 4096;

pub fn initBridge(plugin: *WasmPlugin) plugin_semantic.target.Bridge {
    return .init(plugin.gpa, .{
        .context = plugin,
        .invoke_probe = invokeGuestProbe,
        .invoke_open = invokeGuestOpen,
    });
}

fn invokeGuestProbe(raw: *anyopaque, token: u32) plugin_semantic.target.CallbackError!void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(raw));
    contract.callOptionalExport(
        "on_semantic_target_probe",
        &plugin.instance,
        .{@as(i32, @bitCast(token))},
    ) catch return error.Failed;
}

fn invokeGuestOpen(raw: *anyopaque, token: u32) plugin_semantic.target.CallbackError!void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(raw));
    contract.callOptionalExport(
        "on_semantic_target_open",
        &plugin.instance,
        .{@as(i32, @bitCast(token))},
    ) catch return error.Failed;
}

pub fn hRegister(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const scope = plugin.semanticScope() orelse return;
    const token: u32 = @bitCast(args[0]);
    const id = wire_util.readBounded(
        plugin.gpa,
        caller,
        args[1],
        args[2],
        1,
        max_handler_id_bytes,
    ) orelse return;
    defer plugin.gpa.free(id);
    const ref = plugin.semantic_targets.register(
        &scope.services.target_handlers,
        scope.owner,
        token,
        id,
    ) catch return;
    if (!wire_util.writeHandle(caller, @bitCast(args[3]), @bitCast(args[4]), ref)) {
        plugin.semantic_targets.remove(&scope.services.target_handlers, ref) catch {};
        return;
    }
    results[0] = 1;
}

pub fn hClose(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const scope = plugin.semanticScope() orelse return;
    const ref = wire_util.readHandle(target_runtime.resolver.HandlerRef, args[0..3]) orelse return;
    plugin.semantic_targets.remove(&scope.services.target_handlers, ref) catch return;
    results[0] = 1;
}

pub fn hRequestLen(data: ?*anyopaque, _: *wasm.Caller, _: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const bytes = plugin.semantic_targets.currentRequestBytes() orelse {
        results[0] = -1;
        return;
    };
    if (bytes.len > scene_codec.Limits.max_payload_bytes) {
        results[0] = -1;
        return;
    }
    results[0] = @intCast(bytes.len);
}

pub fn hRequest(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const bytes = plugin.semantic_targets.currentRequestBytes() orelse return;
    const out_cap: u32 = @bitCast(args[1]);
    if (out_cap < bytes.len) return;
    const out_ptr: u32 = @bitCast(args[0]);
    const written = caller.writeMemory(out_ptr, out_cap, bytes) catch return;
    if (written == bytes.len) results[0] = @intCast(written);
}

pub fn hProbeRespond(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const kind: u32 = @bitCast(args[0]);
    switch (kind) {
        0 => plugin.semantic_targets.respondProbeNone() catch return,
        1 => plugin.semantic_targets.respondProbeMatch(.fallback) catch return,
        2 => plugin.semantic_targets.respondProbeMatch(.compatible) catch return,
        3 => plugin.semantic_targets.respondProbeMatch(.preferred) catch return,
        4 => plugin.semantic_targets.respondProbeMatch(.exact) catch return,
        5 => plugin.semantic_targets.respondProbeError(error.Unavailable) catch return,
        6 => plugin.semantic_targets.respondProbeError(error.InvalidTarget) catch return,
        7 => plugin.semantic_targets.respondProbeError(error.Failed) catch return,
        else => return,
    }
    results[0] = 1;
}

pub fn hOpenRespond(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const kind: u32 = @bitCast(args[0]);
    switch (kind) {
        0 => {
            const view = wire_util.readHandle(semantic.view.Ref, args[1..4]) orelse return;
            plugin.semantic_targets.respondOpenView(view) catch return;
        },
        1, 2, 3, 4 => {
            // Error responses carry no ambient payload. Requiring canonical
            // zeroes makes accidental stale-handle leakage fail closed.
            if (args[1] != 0 or args[2] != 0 or args[3] != 0) return;
            const err: target_runtime.resolver.OpenError = switch (kind) {
                1 => error.StaleTarget,
                2 => error.Unavailable,
                3 => error.Rejected,
                4 => error.Failed,
                else => unreachable,
            };
            plugin.semantic_targets.respondOpenError(err) catch return;
        },
        else => return,
    }
    results[0] = 1;
}
