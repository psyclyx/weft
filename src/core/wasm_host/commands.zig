//! Commands: a guest registers one (cross-checked against its manifest) bound to
//! a trampoline that dispatches back into its on_command export; runs commands by
//! name (with int/str args); and introspects the registry (count/name/summary).

const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const wasm_abi = @import("../wasm_abi.zig");
const WasmCmd = wasm_abi.WasmCmd;

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn hRegister(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cname = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch {
        results[0] = -1;
        return;
    };
    // Cross-check against the manifest: an undeclared command fails the load.
    if (!p.declaresCommand(cname)) {
        gpa.free(cname);
        p.load_error = error.UndeclaredCommand;
        results[0] = -1;
        return;
    }
    const wc = gpa.create(WasmCmd) catch {
        gpa.free(cname);
        results[0] = -1;
        return;
    };
    wc.* = .{ .plugin = p, .id = @intCast(p.commands.items.len), .name = cname };
    p.commands.append(gpa, wc) catch {
        gpa.free(cname);
        gpa.destroy(wc);
        results[0] = -1;
        return;
    };
    _ = p.ctx.commands.bind(gpa, wc.name, .{
        .name = wc.name,
        .summary = "",
        .args = &.{},
        .handler = wpCmdTrampoline,
        .data = wc,
    }) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(wc.id);
}

pub fn hRun(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(cmd);
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{}) catch {};
}

pub fn hRunInt(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const cmd = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(cmd);
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{.{ .integer = args[2] }}) catch {};
}

pub fn hRunStr(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(cmd);
    const s = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(s);
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{.{ .string = s }}) catch {};
}

pub fn hRunStr2(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const cmd = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(cmd);
    const a = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(a);
    const b = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(b);
    _ = command.run(p.ctx.commands, p.ctx, cmd, &.{ .{ .string = a }, .{ .string = b } }) catch {};
}

// Introspection — command registry + open buffers.
pub fn hCommandCount(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(p.ctx.commands.count());
}

pub fn hCommandName(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    if (p.ctx.commands.lookup(n) == null) {
        results[0] = -1;
        return;
    }
    const name = p.ctx.commands.nameOf(n);
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), name) catch 0);
}

pub fn hCommandSummary(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n: command.Commands.Name = @enumFromInt(@as(usize, @intCast(args[0])));
    const cmd = p.ctx.commands.lookup(n) orelse {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(caller.writeMemory(@intCast(args[1]), @intCast(args[2]), cmd.summary) catch 0);
}

/// Command dispatch back into the guest: stash the args (readable via
/// `wl_arg_*`), reset the result, run `on_command(id)`, and return whatever
/// result the guest set (`wl_set_result_*`, default nil). String results
/// borrow the plugin's `result_buf` until the next dispatch.
fn wpCmdTrampoline(ctx: *command.Context, data: ?*anyopaque, args: []const command.Value) anyerror!command.Value {
    _ = ctx;
    const wc: *WasmCmd = @ptrCast(@alignCast(data.?));
    const p = wc.plugin;
    p.cur_args = args;
    p.result = .nil;
    p.stampsClear(); // fresh per-dispatch stamp table
    defer p.cur_args = &.{};
    try p.instance.callVoid("on_command", &.{@intCast(wc.id)});
    return p.result;
}
