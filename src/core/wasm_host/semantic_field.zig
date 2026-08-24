//! Wasm transport for generic retained editable fields.
//!
//! Field state is host-owned and renderer-readable. An edit synchronously
//! calls the guest's optional `on_semantic_field_edit(token)` export; during
//! that callback only, the guest reads the current request and accepts it by
//! pushing a new snapshot at a distinct revision.

const std = @import("std");
const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");
const kernel = @import("weft_kernel");
const plugin_semantic = @import("weft_plugin_semantic");
const view_runtime = @import("weft_view_runtime");
const wire_util = @import("semantic_wire.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

const flag_read_only: u32 = 1 << 0;
const flag_single_line: u32 = 1 << 1;
const known_flags = flag_read_only | flag_single_line;
const edit_meta_bytes = 7 * @sizeOf(u32);

pub fn initBridge(plugin: *WasmPlugin) plugin_semantic.field.Bridge {
    return .init(plugin.gpa, .{ .context = plugin, .invoke_edit = invokeGuestEdit });
}

fn invokeGuestEdit(raw: *anyopaque, token: u32) plugin_semantic.field.CallbackError!void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(raw));
    contract.callOptionalExport("on_semantic_field_edit", &plugin.instance, .{@as(i32, @bitCast(token))}) catch return error.Failed;
}

const OwnedInput = struct {
    revision: []u8,
    bytes: []u8,
    value: view_runtime.field.Snapshot,

    fn deinit(self: *OwnedInput, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
        gpa.free(self.revision);
        self.* = undefined;
    }
};

fn readSnapshot(plugin: *WasmPlugin, caller: *wasm.Caller, args: []const i32) ?OwnedInput {
    const revision = wire_util.readBounded(plugin.gpa, caller, args[0], args[1], 1, plugin_semantic.field.max_revision_bytes) orelse return null;
    errdefer plugin.gpa.free(revision);
    const bytes = wire_util.readBounded(plugin.gpa, caller, args[2], args[3], 0, plugin_semantic.field.max_value_bytes) orelse return null;
    errdefer plugin.gpa.free(bytes);
    const flags: u32 = @bitCast(args[6]);
    if (flags & ~known_flags != 0) return null;
    return .{
        .revision = revision,
        .bytes = bytes,
        .value = .{
            .revision = revision,
            .bytes = bytes,
            .selection = .{
                .anchor = @as(u32, @bitCast(args[4])),
                .caret = @as(u32, @bitCast(args[5])),
            },
            .read_only = flags & flag_read_only != 0,
            .single_line = flags & flag_single_line != 0,
        },
    };
}

pub fn hFieldRegister(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const services = plugin.activeCtx().semantic orelse return;
    var snapshot = readSnapshot(plugin, caller, args[1..8]) orelse return;
    defer snapshot.deinit(plugin.gpa);
    const token: u32 = @bitCast(args[0]);
    const ref = plugin.semantic_fields.register(&services.fields, plugin.name, token, snapshot.value) catch return;
    if (!wire_util.writeHandle(caller, @bitCast(args[8]), @bitCast(args[9]), ref)) {
        plugin.semantic_fields.remove(&services.fields, plugin.name, ref) catch {};
        return;
    }
    results[0] = 1;
}

pub fn hFieldUpdate(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const ref = wire_util.readHandle(kernel.scene.FieldRef, args[0..3]) orelse return;
    var snapshot = readSnapshot(plugin, caller, args[3..10]) orelse return;
    defer snapshot.deinit(plugin.gpa);
    plugin.semantic_fields.update(ref, snapshot.value) catch return;
    results[0] = 1;
}

pub fn hFieldClose(data: ?*anyopaque, _: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const services = plugin.activeCtx().semantic orelse return;
    const ref = wire_util.readHandle(kernel.scene.FieldRef, args[0..3]) orelse return;
    plugin.semantic_fields.remove(&services.fields, plugin.name, ref) catch return;
    results[0] = 1;
}

pub fn hFieldEditMeta(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const current = plugin.semantic_fields.currentEdit() orelse return;
    if (args.len != 2) return;
    const out_cap: u32 = @bitCast(args[1]);
    if (out_cap < edit_meta_bytes or current.expected_revision.len > std.math.maxInt(u32) or current.edit.replacement.len > std.math.maxInt(u32)) return;
    if (current.edit.start > std.math.maxInt(u32) or current.edit.end > std.math.maxInt(u32)) return;
    var words: [7]u32 = .{
        @intCast(current.edit.start),
        @intCast(current.edit.end),
        @intCast(current.expected_revision.len),
        @intCast(current.edit.replacement.len),
        @intFromBool(current.edit.selection_after != null),
        0,
        0,
    };
    if (current.edit.selection_after) |selection| {
        if (selection.anchor > std.math.maxInt(u32) or selection.caret > std.math.maxInt(u32)) return;
        words[5] = @intCast(selection.anchor);
        words[6] = @intCast(selection.caret);
    }
    var bytes: [edit_meta_bytes]u8 = undefined;
    for (words, 0..) |word, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, .little);
    const out_ptr: u32 = @bitCast(args[0]);
    const written = caller.writeMemory(out_ptr, out_cap, &bytes) catch return;
    if (written == bytes.len) results[0] = @intCast(written);
}

fn writeCurrentBytes(caller: *wasm.Caller, args: []const i32, results: []i32, value: []const u8) void {
    results[0] = -1;
    const out_cap: u32 = @bitCast(args[1]);
    if (out_cap < value.len) return;
    const out_ptr: u32 = @bitCast(args[0]);
    const written = caller.writeMemory(out_ptr, out_cap, value) catch return;
    if (written == value.len) results[0] = @intCast(written);
}

pub fn hFieldEditRevision(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const current = plugin.semantic_fields.currentEdit() orelse {
        results[0] = -1;
        return;
    };
    writeCurrentBytes(caller, args, results, current.expected_revision);
}

pub fn hFieldEditReplacement(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const plugin: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const current = plugin.semantic_fields.currentEdit() orelse {
        results[0] = -1;
        return;
    };
    writeCurrentBytes(caller, args, results, current.edit.replacement);
}
