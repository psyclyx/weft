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

const buffers = @import("buffers.zig");
const Buffers = @import("../Buffers.zig");

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
        gpa.free(it.key);
    }
    p.pick_items.clearRetainingCapacity();
    const prompt = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer gpa.free(prompt);
    p.pick_prompt.clearRetainingCapacity();
    p.pick_prompt.appendSlice(gpa, prompt) catch {};
    p.pick_id = @intCast(args[2]);
    p.pick_free_text = false; // each pick opts in for itself
    p.pick_category.clearRetainingCapacity(); // …and so does annotation
}

/// `wl_pick_free_text(on)` — between `begin` and `end`: let this pick accept
/// what was TYPED, not only a listed candidate (`Pick.allow_free_text`, the
/// same option the built-in file pick uses). The command palette needs it to
/// mean anything by `listen 7777 edit`: a query with arguments in it matches
/// no row, and without this the accept was a silent cancel.
pub fn hPickFreeText(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    p.pick_free_text = args[0] != 0;
}

/// `wl_pick_category(str)` — between `begin` and `end`: what KIND of pick
/// this is (`"file"`, `"buffer"`, `"command"`). Uninterpreted by core; the
/// only thing done with it is handing it to annotators.
///
/// **Empty — the default — means this pick is never annotated.** `begin`
/// resets it, so every pick opts in for itself and a producer that says
/// nothing (git's confirm, an agent's permission prompt) cannot be decorated
/// by anyone. Ungated for the same reason `wl_pick_free_text` is: it touches
/// only this plugin's own scratch.
pub fn hPickCategory(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const category = caller.readMemory(p.gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    defer p.gpa.free(category);
    p.pick_category.clearRetainingCapacity();
    p.pick_category.appendSlice(p.gpa, category) catch {};
}

pub fn hPickAdd(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    addItem(data, caller, args, null, "");
}

/// `wl_pick_add_keyed`: `wl_pick_add` plus an uninterpreted PUBLIC key an
/// annotator can resolve when the label is not one. Core never parses it.
///
/// No producer in the tree needs this today — the ones whose label is not a
/// key are `wl_pick_add_buffer` (which supplies its own, below) and the
/// intrinsic pickers, whose rows no outside annotator can resolve at all. It
/// ships anyway because without it the annotation membrane would be usable
/// only by core producers and by whichever shipped plugins someone edits,
/// which is the opposite of the point. Speculative, and said so here so it is
/// not later misremembered as demand.
pub fn hPickAddKeyed(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const key = caller.readMemory(p.gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer p.gpa.free(key);
    addItem(data, caller, args, null, key);
}

/// `wl_pick_add_buffer`: like `wl_pick_add`, but the candidate carries the
/// identity of the `args[4]`-th open buffer as its ACCEPT KEY. Identity
/// travels WITH the row, so no parallel table and no label parsing can go
/// stale under the accept — and a buffer closed while the picker is open is
/// refused rather than confused with whatever took its slot.
pub fn hPickAddBuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const b = buffers.bufferAtIndex(p, @intCast(args[4])) orelse return;
    // TWO handles for two different jobs, and they must not be confused. The
    // `Ref` is IDENTITY — it survives a rename and refuses a reused slot, and
    // it is what accept resolves. The annotation key is a NAME an outsider
    // could look up, because a `Ref` means nothing to an annotator and the
    // label ("3: foo.zig [ro] *") is display text, not a handle. The path
    // when there is one, else the display name.
    const annot_key = if (b.textEditor()) |ed| (ed.backingPath() orelse b.name) else b.name;
    addItem(data, caller, args, b.ref(), annot_key);
}

fn addItem(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, buffer: ?Buffers.Ref, key: []const u8) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const text = caller.readMemory(gpa, @intCast(args[0]), @intCast(args[1])) catch return;
    errdefer gpa.free(text);
    const doc = caller.readMemory(gpa, @intCast(args[2]), @intCast(args[3])) catch {
        gpa.free(text);
        return;
    };
    errdefer gpa.free(doc);
    const owned_key = gpa.dupe(u8, key) catch {
        gpa.free(text);
        gpa.free(doc);
        return;
    };
    p.pick_items.append(gpa, .{ .text = text, .doc = doc, .key = owned_key, .buffer = buffer }) catch {
        gpa.free(text);
        gpa.free(doc);
        gpa.free(owned_key);
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
    defer p.pick_category.clearRetainingCapacity(); // consumed at open — see `hOpenFilePick`
    const bp = gpa.create(WasmBoundPick) catch return;
    // Accept keys move in ONE bulk transfer at open — never a per-candidate
    // callback the pick would have to make at accept time.
    const keys = gpa.alloc(?Buffers.Ref, p.pick_items.items.len) catch {
        gpa.destroy(bp);
        return;
    };
    for (p.pick_items.items, keys) |it, *k| k.* = it.buffer;
    bp.* = .{ .plugin = p, .pick_id = p.pick_id, .buffer_keys = keys };
    const entries = gpa.alloc(pick_mod.Entry, p.pick_items.items.len) catch {
        gpa.free(keys);
        gpa.destroy(bp);
        return;
    };
    defer gpa.free(entries);
    for (p.pick_items.items, entries) |it, *e| e.* = .{ .text = it.text, .doc = it.doc, .key = it.key };
    p.activeCtx().head.pick.openWith(p.activeCtx(), p.pick_prompt.items, entries, .{
        .handler = wpPickAccept,
        .cleanup = wpPickCleanup,
        .data = bp,
    }, .{ .allow_free_text = p.pick_free_text, .category = p.pick_category.items }) catch {
        gpa.free(keys);
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
    // The category is CONSUMED at open, here as in `hPickEnd`: this door has
    // no `begin` to reset it, so leaving it set would let one pick's opt-in
    // leak into the next one that forgot to declare.
    defer p.pick_category.clearRetainingCapacity();
    p.activeCtx().head.pick.openWith(p.activeCtx(), prompt, &.{}, .{
        .handler = wpPickAccept,
        .cleanup = wpPickCleanup,
        .data = bp,
    }, .{ .source = finder.source(), .allow_free_text = true, .category = p.pick_category.items }) catch {
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

/// A two-pass, exact byte read — `plugin.writeExact`. Picker outcomes must
/// never inherit the generic scratch-reader convention of silent truncation;
/// that reasoning turned out not to be specific to picks, so it lives beside
/// the other shared door helpers now.
const writeOutcomeBytes = shared.writeExact;

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

/// The live id of the buffer the accepted candidate NAMED (`wl_pick_add_buffer`),
/// or -1: free text, a candidate that carries no buffer key, or — the point of
/// the key — one whose buffer was closed while the picker was open. A refusal,
/// never the stranger now holding that slot.
pub fn hPickOutcomeBuffer(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const bp = p.cur_pick orelse return;
    const outcome = p.cur_pick_outcome orelse return;
    const i = switch (outcome) {
        .candidate => |candidate| candidate.index,
        .input, .cancelled => return,
    };
    if (i >= bp.buffer_keys.len) return; // appended by a live source: no key
    const ref = bp.buffer_keys[i] orelse return;
    const b = p.activeCtx().buffers.resolve(ref) orelse return;
    results[0] = @intCast(b.id);
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
    const top_level = p.dispatch_depth == 0;
    if (top_level) {
        p.clearEphemeralRanges();
        p.clearRetiredResultBuffers();
    }
    const saved_ctx = p.active_ctx;
    const saved_dispatch = p.in_dispatch;
    const saved_outcome = p.cur_pick_outcome;
    const saved_pick = p.cur_pick;
    p.dispatch_depth += 1;
    p.active_ctx = ctx;
    p.in_dispatch = true; // DISPATCHING (task #19 item 4) — see wpCmdTrampoline's doc
    p.cur_pick_outcome = outcome;
    p.cur_pick = bp;
    defer {
        p.dispatch_depth -= 1;
        p.cur_pick_outcome = saved_outcome;
        p.cur_pick = saved_pick;
        p.active_ctx = saved_ctx;
        p.in_dispatch = saved_dispatch;
    }
    try contract.callRequiredExport("on_pick_accept", &p.instance, .{@as(i32, @intCast(bp.pick_id))});
}

fn wpPickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const bp: *WasmBoundPick = @ptrCast(@alignCast(data.?));
    gpa.free(bp.buffer_keys);
    gpa.destroy(bp);
}
