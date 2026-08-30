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
    p.declared.append(p.gpa, .{ .name = name }) catch {
        p.gpa.free(name);
        return;
    };
}

/// `wl_declare_command_doc(name, params, summary)` — declare a command AND say
/// what it takes and does. The same declaration `wl_declare_command` makes,
/// plus the two facts that let the rest of the editor treat a plugin command
/// like a core one: its one-line summary, and its argument shape (see
/// `WasmPlugin.DeclaredCommand`). Describe-phase only, like its sibling.
pub fn hDeclareCommandDoc(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (p.phase != .describing) return;
    const gpa = p.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(name);
    const params_raw = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        gpa.free(name);
        return;
    };
    defer gpa.free(params_raw);
    const summary = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch {
        gpa.free(name);
        return;
    };
    errdefer gpa.free(summary);
    const parsed = WasmPlugin.DeclaredCommand.parseParams(gpa, params_raw) catch {
        gpa.free(name);
        gpa.free(summary);
        return;
    };
    p.declared.append(gpa, .{
        .name = name,
        .summary = summary,
        .params = parsed[0],
        .args = parsed[1],
    }) catch {
        gpa.free(name);
        gpa.free(summary);
        gpa.free(parsed[0]);
        gpa.free(parsed[1]);
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
