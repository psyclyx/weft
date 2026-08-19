//! The config surface's local plane: key binds, mode entry/fallback, the
//! text-input command, and menu/sticky-menu marks — each mirrors an abi.Abi
//! config method, bound at the plugin tier owned by the plugin's name.

const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn hBindKey(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    const key = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(key);
    const cmd = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(cmd);
    // A plugin binds at the plugin tier, owned by its name (so a config bind
    // shadows it and equal-tier collisions between two plugins are surfaced).
    const Keymap = @import("../Keymap.zig");
    p.ctx.keymap.bind(gpa, mode, key, cmd, Keymap.prio_plugin, p.name) catch {};
}

pub fn hSetMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    // Guest-initiated: route through enterMode so entering a menu mode records
    // its one-shot return target. Host-side mode save/restore (the picker) uses
    // plain setMode and never records.
    p.ctx.keymap.enterMode(p.gpa, mode) catch {};
}

pub fn hSetFallback(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    const parent = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(parent);
    p.ctx.keymap.setFallback(gpa, mode, parent) catch {};
}

pub fn hTextInput(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    if (args[4] == 0) {
        p.ctx.keymap.setTextCommand(gpa, mode, null) catch {};
        return;
    }
    const cmd = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(cmd);
    p.ctx.keymap.setTextCommand(gpa, mode, cmd) catch {};
}

pub fn hMenuMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.ctx.keymap.markMenuMode(p.gpa, mode) catch {};
}

/// `sticky_menu(mode)`: mark a menu mode STICKY — it stays open after a leaf
/// key (flag-accumulating transients) instead of one-shot auto-popping.
pub fn hStickyMenu(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.ctx.keymap.markStickyMenu(p.gpa, mode) catch {};
}
