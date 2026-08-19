//! Group A + the describe phase: logging, and the declarations a guest records
//! during describe() (commands, capabilities, perm requests) — recorded only
//! while describing, cross-checked later against what it registers.

const std = @import("std");
const wasm = @import("../wasm.zig");
const wasm_abi = @import("../wasm_abi.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn hLog(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const msg = caller.readMemory(p.gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    defer p.gpa.free(msg);
    switch (args[0]) {
        2 => std.log.warn("{s}", .{msg}),
        3 => std.log.err("{s}", .{msg}),
        else => std.log.info("{s}", .{msg}),
    }
}

// Describe phase: declarations recorded only while describing.
pub fn hDeclareCommand(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (p.phase != .describing) return;
    const name = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    p.declared.append(p.gpa, name) catch {
        p.gpa.free(name);
        return;
    };
}

pub fn hDeclareCapability(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (p.phase != .describing) return;
    const name = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    p.declared_caps.append(p.gpa, name) catch {
        p.gpa.free(name);
        return;
    };
}

pub fn hRequestPerm(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (p.phase != .describing) return;
    const idx: usize = @intCast(args[0]);
    if (idx < wasm_abi.perm_count) p.perms[idx] = true;
}
