//! The pick membrane: a guest accumulates items between begin/end then opens a
//! pick whose terminal outcome trampolines back into `on_pick_accept`; plus
//! the file-pick door and callback-scoped outcome reads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const pick_mod = @import("../pick.zig");
const fs_source = @import("../fs_source.zig");
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requireDispatch = shared.requireDispatch;
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
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // HEAD-GATED (task #19 item 4): opening a pick puts the dispatching
    // head's `Head.pick` into session — `wl_pick_begin`/`wl_pick_add` only
    // touch this plugin's OWN scratch (pick_prompt/pick_items), never
    // `Head`, so they stay ungated; the actual head mutation happens here.
    if (!requireDispatch(p, caller, "wl_pick_end")) return;
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
    // HEAD-GATED (task #19 item 4): same door as `wl_pick_end`, just with a
    // built-in file-tree source instead of guest-supplied items.
    if (!requireDispatch(p, caller, "wl_open_file_pick")) return;
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

fn outcomeOf(data: ?*anyopaque) ?pick_mod.Outcome {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    return p.cur_pick_outcome;
}

/// Callback-scoped outcome discriminator: cancelled=0, input=1,
/// candidate=2, and -1 outside `on_pick_accept`.
pub fn hPickOutcomeKind(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    results[0] = if (outcomeOf(data)) |outcome| switch (outcome) {
        .cancelled => 0,
        .input => 1,
        .candidate => 2,
    } else -1;
}

fn outcomeText(outcome: pick_mod.Outcome) []const u8 {
    return switch (outcome) {
        .cancelled => "",
        .input => |input| input,
        .candidate => |candidate| candidate.text,
    };
}

pub fn hPickOutcomeText(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const outcome = outcomeOf(data) orelse {
        results[0] = -1;
        return;
    };
    writeOutcomeBytes(caller, args, results, outcomeText(outcome));
}

pub fn hPickOutcomeQuery(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const outcome = outcomeOf(data) orelse {
        results[0] = -1;
        return;
    };
    const query = switch (outcome) {
        .cancelled => "",
        .input => |input| input,
        .candidate => |candidate| candidate.query,
    };
    writeOutcomeBytes(caller, args, results, query);
}

/// A two-pass, exact byte read: cap=0 reports the required length; a nonzero
/// call either writes the complete value or returns -2. Picker outcomes must
/// never inherit the generic scratch-reader convention of silent truncation.
fn writeOutcomeBytes(caller: *wasm.Caller, args: []const i32, results: []i32, bytes: []const u8) void {
    const cap: usize = @intCast(args[1]);
    if (cap == 0) {
        results[0] = std.math.cast(i32, bytes.len) orelse -2;
        return;
    }
    if (cap < bytes.len) {
        results[0] = -2;
        return;
    }
    const written = caller.writeMemory(@intCast(args[0]), cap, bytes) catch {
        results[0] = -1;
        return;
    };
    results[0] = @intCast(written);
}

pub fn hPickOutcomeIndex(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    results[0] = if (outcomeOf(data)) |outcome| switch (outcome) {
        .candidate => |candidate| @intCast(candidate.index),
        .input => -1,
        .cancelled => -1,
    } else -1;
}

pub fn hPickOutcomeMatchStart(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    results[0] = if (outcomeOf(data)) |outcome| switch (outcome) {
        .candidate => |candidate| @intCast(candidate.match.start),
        .input => -1,
        .cancelled => -1,
    } else -1;
}

pub fn hPickOutcomeMatchSpan(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    results[0] = if (outcomeOf(data)) |outcome| switch (outcome) {
        .candidate => |candidate| @intCast(candidate.match.span),
        .input => -1,
        .cancelled => -1,
    } else -1;
}

/// Pick completion: frame the immutable outcome, dispatch to the guest's
/// `on_pick_accept`, then restore any outer callback frame.
/// DISPATCHING (wasm_host/commands.zig's classification): `ctx` is the head
/// whose pick session just accepted — route `active_ctx` through it for the
/// call's duration (save/restore, same reentrancy discipline as
/// `wpCmdTrampoline`), so `wl_pick_outcome_*` and anything else
/// `on_pick_accept` reaches see THAT dispatch's state.
fn wpPickAccept(ctx: *command.Context, data: ?*anyopaque, outcome: pick_mod.Outcome) anyerror!void {
    const bp: *WasmBoundPick = @ptrCast(@alignCast(data.?));
    const p = bp.plugin;
    const saved_ctx = p.active_ctx;
    const saved_dispatch = p.in_dispatch;
    const saved_outcome = p.cur_pick_outcome;
    p.active_ctx = ctx;
    p.in_dispatch = true; // DISPATCHING (task #19 item 4) — see wpCmdTrampoline's doc
    p.cur_pick_outcome = outcome;
    defer {
        p.cur_pick_outcome = saved_outcome;
        p.active_ctx = saved_ctx;
        p.in_dispatch = saved_dispatch;
    }
    try contract.callRequiredExport("on_pick_accept", &p.instance, .{@as(i32, @intCast(bp.pick_id))});
}

fn wpPickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const bp: *WasmBoundPick = @ptrCast(@alignCast(data.?));
    gpa.destroy(bp);
}
