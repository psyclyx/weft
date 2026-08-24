//! Shared scalar/byte marshalling for semantic host-import leaves.

const std = @import("std");
const wasm = @import("../wasm.zig");
const semantic = @import("weft_semantic");

pub const handle_bytes = @sizeOf(semantic.handle.Wire);

pub fn readHandle(comptime Ref: type, args: []const i32) ?Ref {
    const wire: semantic.handle.Wire = .{
        .authority = @bitCast(args[0]),
        .slot = @bitCast(args[1]),
        .generation = @bitCast(args[2]),
    };
    if (wire.generation == 0) return null;
    return Ref.fromWire(wire);
}

pub fn writeHandle(caller: *wasm.Caller, out_ptr: u32, out_cap: u32, ref: anytype) bool {
    if (out_cap < handle_bytes) return false;
    const wire = ref.toWire();
    var bytes: [handle_bytes]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], wire.authority, .little);
    std.mem.writeInt(u32, bytes[4..8], wire.slot, .little);
    std.mem.writeInt(u32, bytes[8..12], wire.generation, .little);
    return (caller.writeMemory(out_ptr, out_cap, &bytes) catch return false) == handle_bytes;
}

pub fn readBounded(
    gpa: std.mem.Allocator,
    caller: *wasm.Caller,
    ptr: i32,
    len: i32,
    minimum: usize,
    maximum: usize,
) ?[]u8 {
    const value_len: u32 = @bitCast(len);
    if (value_len < minimum or value_len > maximum) return null;
    const value_ptr: u32 = @bitCast(ptr);
    return caller.readMemory(gpa, value_ptr, value_len) catch null;
}
