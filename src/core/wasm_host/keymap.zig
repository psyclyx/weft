//! The config surface's local plane: key binds, mode entry/fallback, the
//! text-input command, and menu/sticky-menu marks — each mirrors an abi.Abi
//! config method, bound at the plugin tier owned by the plugin's name.

const std = @import("std");
const wasm = @import("../wasm.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requireDispatch = shared.requireDispatch;

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
    p.activeCtx().keymap.bind(gpa, mode, key, cmd, Keymap.prio_plugin, p.name) catch {};
}

/// wl_declare_action(name) — a plugin declares an abstract intent + its
/// trampoline command, so a key can bind to `name` and dispatch by context.
pub fn hDeclareAction(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const name = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(name);
    const command = @import("../command.zig");
    command.registerAction(gpa, p.activeCtx().commands, p.activeCtx().actions, name, .pick) catch {};
}

/// wl_provide(action, mode, lang, tool, cmd, prio) — a plugin registers a
/// provider for `action`, owned by its name (so teardown drops it and equal-
/// tier collisions are attributable). Empty mode/lang/tool = "don't care".
pub fn hProvide(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const action = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(action);
    const mode = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(mode);
    const lang = caller.readMemory(gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer gpa.free(lang);
    const tool = caller.readMemory(gpa, @intCast(args[6]), @intCast(args[7])) catch return;
    defer gpa.free(tool);
    const cmd = caller.readMemory(gpa, @intCast(args[8]), @intCast(args[9])) catch return;
    defer gpa.free(cmd);
    p.activeCtx().actions.provide(.{
        .action = action,
        .when = .{
            .mode = if (mode.len > 0) mode else null,
            .lang = if (lang.len > 0) lang else null,
            .tool = if (tool.len > 0) tool else null,
        },
        .command = cmd,
        .priority = args[10],
        .owner = p.name,
    }) catch |e| if (e == error.RaceRejectsProvider) {
        // Surface the mistake to the plugin author via the echo line when the
        // call is on a dispatching path or the load handshake (the common,
        // legitimate cases) — from a BACKGROUND entry, head.echo is exactly
        // the gated interaction state (review of #19 item 4: this error path
        // was the one ungated head.echo writer), so fall back to the log.
        const msg = std.fmt.allocPrint(gpa, "provide: '{s}' is a race action — register a capability provider instead", .{action}) catch return;
        defer gpa.free(msg);
        if (p.in_dispatch or p.loading) {
            p.activeCtx().head.echo.clearRetainingCapacity();
            p.activeCtx().head.echo.appendSlice(gpa, msg) catch {};
        } else {
            std.log.warn("plugin '{s}': {s}", .{ p.name, msg });
        }
    };
}

pub fn hSetMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // HEAD-GATED (task #19 item 4): SETS the current head's mode (the
    // mode-leak class's founding bug — "background forces a mode"). Compare
    // `wl_menu_mode`/`wl_locked_mode`/`wl_resting_mode`/`wl_sticky_menu`
    // below, which DECLARE a mode's system-scoped TABLE properties and stay
    // ungated.
    if (!requireDispatch(p, caller, "wl_set_mode")) return;
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    // A locked projection mode (magit/git-view) refuses to switch to a different
    // editing mode — you can't land in `normal` inside a read-only projection.
    if (!p.activeCtx().keymap.mayLeaveLocked(p.activeCtx().head.currentMode(), mode)) return;
    // Guest-initiated: route through enterMode so entering a menu mode records
    // its one-shot return target. Host-side mode save/restore (the picker) uses
    // plain setMode and never records.
    p.activeCtx().head.enterMode(p.gpa, p.activeCtx().keymap, mode) catch {};
    // Remember a RESTING mode as the active buffer's resting mode, so exiting a
    // transient sub-mode (insert/visual) returns HERE — this is what keeps a
    // tool projection (dired) live after an in-place edit + Escape.
    if (p.activeCtx().keymap.isRestingMode(mode)) {
        const buf = p.activeCtx().buffers.active();
        const held = p.gpa.dupe(u8, mode) catch return;
        p.gpa.free(buf.mode);
        buf.mode = held;
    }
}

/// `exitToResting()`: leave a transient mode (insert/visual) back to the active
/// buffer's RESTING mode — its own tool mode (dired) if it has one, else the base
/// editing mode. Replaces a guest's hardcoded `setMode("normal")` on Escape, so a
/// projection's keys never sleep after an in-place edit.
pub fn hExitToResting(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // HEAD-GATED (task #19 item 4): same door as `wl_set_mode`, one hop
    // removed — it resolves the target mode, then calls `head.setMode`.
    if (!requireDispatch(p, caller, "wl_exit_to_resting")) return;
    const buf = p.activeCtx().buffers.active();
    // The buffer's declared resting mode (its tool mode, or the config base it
    // was stamped with on open) — no core-baked mode name; the config owns what
    // "resting" means. `default_mode` is the last resort if a buffer never
    // declared one.
    const target = if (buf.mode.len > 0) buf.mode else p.activeCtx().buffers.default_mode;
    if (target.len == 0) return;
    const owned = p.gpa.dupe(u8, target) catch return;
    defer p.gpa.free(owned);
    p.activeCtx().head.setMode(p.gpa, owned) catch {};
}

pub fn hSetFallback(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    const parent = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(parent);
    p.activeCtx().keymap.setFallback(gpa, mode, parent) catch {};
}

pub fn hTextInput(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const mode = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(mode);
    if (args[4] == 0) {
        p.activeCtx().keymap.setTextCommand(gpa, mode, null) catch {};
        return;
    }
    const cmd = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(cmd);
    p.activeCtx().keymap.setTextCommand(gpa, mode, cmd) catch {};
}

pub fn hMenuMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.activeCtx().keymap.markMenuMode(p.gpa, mode) catch {};
}

/// `locked_mode(mode)`: mark a read-only projection mode pinned (see
/// Keymap.mayLeaveLocked) — magit/git-view can't be left for a generic editing
/// mode, only a menu or itself.
pub fn hLockedMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.activeCtx().keymap.markLockedMode(p.gpa, mode) catch {};
}

/// `resting_mode(mode)`: declare a mode a buffer can rest in, so `baseMode` stops
/// there instead of overshooting to the root `default`.
pub fn hRestingMode(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.activeCtx().keymap.markRestingMode(p.gpa, mode) catch {};
}

/// `sticky_menu(mode)`: mark a menu mode STICKY — it stays open after a leaf
/// key (flag-accumulating transients) instead of one-shot auto-popping.
pub fn hStickyMenu(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const mode = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(mode);
    p.activeCtx().keymap.markStickyMenu(p.gpa, mode) catch {};
}
