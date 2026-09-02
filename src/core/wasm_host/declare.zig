//! Group A + the describe phase: logging, and the declarations a guest records
//! during describe() (commands, capabilities, perm requests) — recorded only
//! while describing, cross-checked later against what it registers.

const std = @import("std");
const wasm = @import("../wasm.zig");
const wasm_abi = @import("../wasm_abi.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const plugin_resources = @import("../plugin_resources.zig");
const Resources = plugin_resources.Resources;
const Door = plugin_resources.Door;
const Perm = shared.Perm;

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

// ── Declaring a command: ONE BODY, BOTH PLANES ──────────────────────────
//
// A JS plugin is a wasm plugin — it runs inside quickjs.wasm — so what a
// command SAYS ABOUT ITSELF cannot be two things. It was: the wasm plane
// declared a summary and an argument shape here, the JS plane had no such door
// at all, and its register bound the literal string "js" as the summary with no
// arguments. That is not one plane missing a feature; it is one concept with
// two definitions, and the second drifted because there was a second to drift.
//
// These two bodies take a `Door` — the `Resources` block BOTH planes embed —
// so `wasmDoor` and `jsDoor` generate the two trampolines from them and there
// is nowhere for a difference to live. `e2e/demolition_test.zig` proves it by
// function pointer, exactly as it does for the proc doors.

/// `declare_command(name)` — a bare declaration: this guest has a command by
/// this name. Accepted only while declarations are open, which on the wasm
/// plane means `describe()` and on the JS plane means init.
pub fn declareBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const r = d.resources;
    if (!r.accepting_declarations) return;
    const name = caller.readMemory(r.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    r.declared.append(r.gpa, .{ .name = name }) catch {
        r.gpa.free(name);
        return;
    };
}

/// `declare_command_doc(name, params, summary)` — declare a command AND say
/// what it takes and does. The same declaration `declare_command` makes, plus
/// the two facts that let the rest of the editor treat a plugin command like a
/// core one: its one-line summary, and its argument shape.
pub fn declareDocBody(d: Door, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const r = d.resources;
    if (!r.accepting_declarations) return;
    const gpa = r.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    const params_raw = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        gpa.free(name);
        return;
    };
    defer gpa.free(params_raw);
    const summary = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch {
        gpa.free(name);
        return;
    };
    const parsed = Resources.DeclaredCommand.parseParams(gpa, params_raw) catch {
        gpa.free(name);
        gpa.free(summary);
        return;
    };
    r.declared.append(gpa, .{
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

/// The two doors, and the table the anti-drift gate reads. Same shape as
/// `wasm_host/proc.zig`'s `doors`, for the same reason.
pub const doors = .{
    .{ .name = "declare_command", .body = declareBody, .wl = hDeclareCommand, .wl_gate = @as(?Perm, null), .qjs_gate = @as(?Perm, null) },
    .{ .name = "declare_command_doc", .body = declareDocBody, .wl = hDeclareCommandDoc, .wl_gate = @as(?Perm, null), .qjs_gate = @as(?Perm, null) },
};

/// Re-exported so the anti-drift gate can recompute a handler from the table
/// and compare pointers, exactly as it does for `proc`.
pub const wasmDoorFor = shared.wasmDoor;

pub const hDeclareCommand = wasmDoorFor(declareBody, null);
pub const hDeclareCommandDoc = wasmDoorFor(declareDocBody, null);

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
