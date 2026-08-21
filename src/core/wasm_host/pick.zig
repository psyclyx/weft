//! The pick membrane: a guest accumulates items between begin/end then opens a
//! pick whose accept trampolines back into its on_pick_accept; plus the file
//! pick door (a local finder source) and the accepted choice/index reads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const pick_mod = @import("../pick.zig");
const fs_source = @import("../fs_source.zig");
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const WasmBoundPick = @import("../wasm_abi.zig").WasmBoundPick;

// trampoline that dispatches to the guest's on_pick_accept.
pub fn hPickBegin(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    for (p.pick_items.items) |it| {
        gpa.free(it.text);
        gpa.free(it.doc);
    }
    p.pick_items.clearRetainingCapacity();
    const prompt = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(prompt);
    p.pick_prompt.clearRetainingCapacity();
    p.pick_prompt.appendSlice(gpa, prompt) catch {};
    p.pick_id = @intCast(args[2]);
}

pub fn hPickAdd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const text = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(text);
    const doc = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        gpa.free(text);
        return;
    };
    p.pick_items.append(gpa, .{ .text = text, .doc = doc }) catch {
        gpa.free(text);
        gpa.free(doc);
    };
}

pub fn hPickEnd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const bp = gpa.create(WasmBoundPick) catch return;
    bp.* = .{ .plugin = p, .pick_id = p.pick_id };
    const entries = gpa.alloc(pick_mod.Entry, p.pick_items.items.len) catch {
        gpa.destroy(bp);
        return;
    };
    defer gpa.free(entries);
    for (p.pick_items.items, entries) |it, *e| e.* = .{ .text = it.text, .doc = it.doc };
    p.activeCtx().head.pick.open(p.activeCtx(), p.pick_prompt.items, entries, .{
        .handler = wpPickAccept,
        .cleanup = wpPickCleanup,
        .data = bp,
    }) catch {
        gpa.destroy(bp);
    };
}

pub fn hOpenFilePick(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const prompt = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(prompt);
    const root = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer gpa.free(root);
    const bp = gpa.create(WasmBoundPick) catch return;
    bp.* = .{ .plugin = p, .pick_id = @intCast(args[4]) };
    const finder = fs_source.LocalFinder.create(gpa, p.activeCtx().buffers.pool, root) catch {
        gpa.destroy(bp);
        return;
    };
    // openWith closes the source on failure; only the BoundPick is ours.
    p.activeCtx().head.pick.openWith(p.activeCtx(), prompt, &.{}, .{
        .handler = wpPickAccept,
        .cleanup = wpPickCleanup,
        .data = bp,
    }, .{ .source = finder.source(), .allow_free_text = true }) catch {
        gpa.destroy(bp);
    };
}

pub fn hPickChoice(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), p.cur_choice) catch 0);
}

/// The add-order index of the accepted candidate (as the guest supplied them
/// via `pickAdd`), or -1 for free-text. Lets a source resolve the choice to a
/// position it recorded at add time, unambiguous under duplicate rows.
pub fn hPickChoiceIndex(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = if (p.activeCtx().head.pick.accepted_index) |i| @intCast(i) else -1;
}

/// Pick accept: stash the choice, dispatch to the guest's on_pick_accept.
/// DISPATCHING (wasm_host/commands.zig's classification): `ctx` is the head
/// whose pick session just accepted — route `active_ctx` through it for the
/// call's duration (save/restore, same reentrancy discipline as
/// `wpCmdTrampoline`), so `wl_pick_choice`/`wl_pick_choice_index` and anything
/// else `on_pick_accept` reaches see THAT head's state.
fn wpPickAccept(ctx: *command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    const bp: *WasmBoundPick = @ptrCast(@alignCast(data.?));
    const p = bp.plugin;
    const saved_ctx = p.active_ctx;
    p.active_ctx = ctx;
    defer p.active_ctx = saved_ctx;
    p.cur_choice = choice;
    defer p.cur_choice = &.{};
    try contract.callRequiredExport("on_pick_accept", &p.instance, .{@as(i32, @intCast(bp.pick_id))});
}

fn wpPickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const bp: *WasmBoundPick = @ptrCast(@alignCast(data.?));
    gpa.destroy(bp);
}
