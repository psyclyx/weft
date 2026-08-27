//! Buffer introspection: walk the open buffers by index and read each one's id,
//! name, active flag, and read-only flag across the membrane.

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

/// The i-th open buffer, or null (O(i) walk — the introspection path).
pub fn bufferAtIndex(p: *WasmPlugin, i: usize) ?*@import("../Buffers.zig").Buffer {
    var it = p.activeCtx().buffers.iterator();
    var j: usize = 0;
    while (it.next()) |b| : (j += 1) if (j == i) return b;
    return null;
}

pub fn hBufferCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.activeCtx().buffers.count());
}

pub fn hBufferId(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = bufferAtIndex(p, @intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(b.id);
}

pub fn hBufferName(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = bufferAtIndex(p, @intCast(args[0])) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), b.name) catch 0);
}

pub fn hBufferActive(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = bufferAtIndex(p, @intCast(args[0]));
    results[0] = if (b != null and b == p.activeCtx().buffers.active()) 1 else 0;
}

pub fn hBufferReadonly(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = bufferAtIndex(p, @intCast(args[0]));
    results[0] = if (b != null and b.?.read_only) 1 else 0;
}
