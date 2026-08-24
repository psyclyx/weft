//! Wasm transport for tokenized semantic relation providers.
//!
//! Canonical query bytes are borrowed only during a synchronous guest
//! callback. Answers are decoded into bridge-owned storage before returning
//! to the relation registry, which then clones the immutable edge value.

const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");
const plugin_semantic = @import("weft_plugin_semantic");
const scene_codec = @import("weft_scene_codec");
const target_runtime = @import("weft_target_runtime");
const wire_util = @import("semantic_wire.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

const max_provider_id_bytes = 4096;

pub fn initBridge(plugin: *WasmPlugin) plugin_semantic.relation.Bridge {
    return .init(plugin.gpa, .{ .context = plugin, .invoke_query = invokeGuestQuery });
}

fn invokeGuestQuery(raw: *anyopaque, token: u32) plugin_semantic.relation.CallbackError!void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(raw));
    contract.callOptionalExport(
        "on_semantic_relation_query",
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
        max_provider_id_bytes,
    ) orelse return;
    defer plugin.gpa.free(id);
    const ref = plugin.semantic_relations.register(
        &scope.services.target_relations,
        scope.owner,
        token,
        id,
    ) catch return;
    if (!wire_util.writeHandle(caller, @bitCast(args[3]), @bitCast(args[4]), ref)) {
        plugin.semantic_relations.remove(&scope.services.target_relations, ref) catch {};
        return;
    }
    results[0] = 1;
}

pub fn hClose(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const scope = plugin.semanticScope() orelse return;
    const ref = wire_util.readHandle(target_runtime.relation.ProviderRef, args[0..3]) orelse return;
    plugin.semantic_relations.remove(&scope.services.target_relations, ref) catch return;
    results[0] = 1;
}

pub fn hRequestLen(data: ?*anyopaque, _: *wasm.Caller, _: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const bytes = plugin.semantic_relations.currentRequestBytes() orelse {
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
    const bytes = plugin.semantic_relations.currentRequestBytes() orelse return;
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
            plugin.semantic_relations.respondNone() catch return;
        },
        1 => {
            const payload = wire_util.readBounded(
                plugin.gpa,
                caller,
                args[1],
                args[2],
                1,
                scene_codec.Limits.max_payload_bytes,
            ) orelse return;
            defer plugin.gpa.free(payload);
            var decoded = scene_codec.target.decodeLocated(plugin.gpa, payload) catch return;
            plugin.semantic_relations.adoptResolved(&decoded) catch {
                decoded.deinit();
                return;
            };
        },
        2, 3, 4, 5 => {
            if (payload_len != 0) return;
            const err: target_runtime.relation.QueryError = switch (kind) {
                2 => error.Unavailable,
                3 => error.InvalidRelation,
                4 => error.StaleTarget,
                5 => error.Failed,
                else => unreachable,
            };
            plugin.semantic_relations.respondFailure(err) catch return;
        },
        else => return,
    }
    results[0] = 1;
}
