//! Wasm transport for one owner-scoped semantic action provider.
//!
//! The portable plugin bridge owns callback state and response lifetimes. This
//! leaf only copies canonical bytes through linear memory and invokes the
//! guest's optional synchronous callback.

const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");
const plugin_semantic = @import("weft_plugin_semantic");
const scene_codec = @import("weft_scene_codec");
const view_runtime = @import("weft_view_runtime");
const wire_util = @import("semantic_wire.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn initBridge(plugin: *WasmPlugin) plugin_semantic.action.Bridge {
    return .init(plugin.gpa, .{ .context = plugin, .invoke = invokeGuest });
}

fn invokeGuest(raw: *anyopaque) plugin_semantic.action.CallbackError!void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(raw));
    contract.callOptionalExport("on_semantic_action", &plugin.instance, .{}) catch return error.Failed;
}

pub fn hProvider(data: ?*anyopaque, _: *wasm.Caller, _: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const scope = plugin.semanticScope() orelse return;
    scope.services.actions.register(plugin.gpa, scope.owner, view_runtime.action.Provider.init(&plugin.semantic_actions)) catch return;
    results[0] = 1;
}

pub fn hRequestLen(data: ?*anyopaque, _: *wasm.Caller, _: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const bytes = plugin.semantic_actions.currentRequestBytes() orelse {
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
    const bytes = plugin.semantic_actions.currentRequestBytes() orelse return;
    const out_cap: u32 = @bitCast(args[1]);
    if (out_cap < bytes.len) return;
    const out_ptr: u32 = @bitCast(args[0]);
    const written = caller.writeMemory(out_ptr, out_cap, bytes) catch return;
    if (written == bytes.len) results[0] = @intCast(written);
}

pub fn hRespond(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const kind: u32 = @bitCast(args[0]);
    const payload_len: u32 = @bitCast(args[2]);
    switch (kind) {
        0 => {
            if (payload_len != 0) return;
            plugin.semantic_actions.respondDeclined() catch return;
        },
        1 => {
            if (payload_len != 0) return;
            plugin.semantic_actions.respondHandled() catch return;
        },
        2, 3 => {
            const payload = wire_util.readBounded(plugin.gpa, caller, args[1], args[2], 1, scene_codec.Limits.max_payload_bytes) orelse return;
            defer plugin.gpa.free(payload);
            if (kind == 2) {
                var decoded = scene_codec.transfer.decode(plugin.gpa, payload) catch return;
                plugin.semantic_actions.adoptTransfer(&decoded) catch {
                    decoded.deinit();
                    return;
                };
            } else {
                var decoded = scene_codec.interaction.decode(plugin.gpa, payload) catch return;
                plugin.semantic_actions.adoptInteraction(&decoded) catch {
                    decoded.deinit();
                    return;
                };
            }
        },
        else => return,
    }
    results[0] = 1;
}
