//! The pick membrane: a guest accumulates items between begin/end then opens a
//! pick whose terminal outcome trampolines back into `on_pick_accept`; plus
//! the file-pick door and callback-scoped outcome reads.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasm = @import("../wasm.zig");
const command = @import("../command.zig");
const pick_mod = @import("../pick.zig");
const fs_source = @import("../fs_source.zig");
const designation = @import("../designation.zig");
const contract = @import("../membrane/contract.zig");

const buffers = @import("buffers.zig");
const Buffers = @import("../Buffers.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const requireDispatch = shared.requireDispatch;
const WasmBoundPick = @import("../wasm_abi.zig").WasmBoundPick;
const WasmPluginT = @import("../wasm_abi/WasmPlugin.zig");
const LiveSource = WasmPluginT.LiveSource;

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
    // BITCAST, not `@intCast`. A pick id is an OPAQUE tag the guest chooses and
    // the host only ever echoes back to it, so every one of the 2^32 words it
    // can send is a legitimate id — including the ones whose top bit is set,
    // which arrive here as a negative `i32`. `@intCast` panicked on those, so
    // any guest that used the high half of its own id space — deliberately or
    // by accident — took the HOST down. Same sign-bit class as the handle
    // tables (`core/handles.zig`), at a door that carries no permission at all.
    p.pick_id = @bitCast(args[2]);
    p.pick_free_text = false; // each pick opts in for itself
    p.pick_category.clearRetainingCapacity(); // …and so does annotation
    p.pick_live = null; // …and so does being fed live
}

/// `wl_pick_live(flags, debounce_ms, min_query)` — between `begin` and
/// `end`: the plugin FEEDS this pick rather than handing it rows at open.
/// Flag bit 0: query-driven — each time the query settles (`debounce_ms`
/// still, at least `min_query` bytes) the plugin hears `on_pick_query` and
/// pushes rows for that query (`wl_pick_push`); without it the plugin
/// fills the pick once and the picker narrows the rows as usual. Bit 1: the
/// plugin matched the rows itself (a search per query), so they are shown
/// as given, unfiltered and in its order. Ungated: it touches only this
/// plugin's own scratch, as `wl_pick_free_text` does.
pub fn hPickLive(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const flags: u32 = @bitCast(args[0]);
    p.pick_live = .{
        .query_driven = flags & 1 != 0,
        .given = flags & 2 != 0,
        .debounce_ms = @bitCast(args[1]),
        .min_query = @bitCast(args[2]),
    };
}

/// `wl_pick_query(ptr, cap)` — the settled query, during `on_pick_query`
/// only (-1 outside it); the exact two-pass read every outcome read uses.
pub fn hPickQuery(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const query = p.cur_live_query orelse {
        results[0] = -1;
        return;
    };
    writeOutcomeBytes(caller, args, results, query);
}

/// `wl_pick_push(epoch, text, doc)` — a row for the query `epoch` names
/// (the one `on_pick_query` was handed; 0 for a fill-once pick). 1 taken;
/// 0 refused — the query has moved on, or this one has its `max_rows` —
/// so a plugin can stop producing; -1 when it has no live pick open. Never
/// touches the head: the rows wait on the pick's source until the next
/// frame, so a plugin may push from anywhere it runs (a process's answer
/// included), not only from a dispatch.
pub fn hPickPush(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const live = p.live_pick orelse {
        results[0] = -1;
        return;
    };
    const epoch: u32 = @bitCast(args[0]);
    if (epoch != live.epoch) {
        results[0] = 0;
        return;
    }
    if (live.taken >= LiveSource.max_rows) {
        live.capped = true;
        results[0] = 0;
        return;
    }
    const gpa = p.gpa;
    const text = caller.readMemory(gpa, @intCast(args[1]), @intCast(args[2])) catch {
        results[0] = 0;
        return;
    };
    const doc = caller.readMemory(gpa, @intCast(args[3]), @intCast(args[4])) catch {
        gpa.free(text);
        results[0] = 0;
        return;
    };
    live.pending.append(gpa, .{ .text = text, .doc = doc }) catch {
        gpa.free(text);
        gpa.free(doc);
        results[0] = 0;
        return;
    };
    live.taken += 1;
    results[0] = 1;
}

/// `wl_pick_done(epoch)` — every row for that query has been pushed. What
/// lets an answer of NO rows replace the last query's rows, rather than
/// leave them standing as if they still matched.
pub fn hPickDone(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const live = p.live_pick orelse return;
    if (@as(u32, @bitCast(args[0])) == live.epoch) live.done = true;
}

// ── The live source: the pick's side of `wl_pick_live` ───────────────

fn liveSource(live: *LiveSource) pick_mod.Source {
    return .{
        .onQuery = if (live.spec.query_driven) liveQuery else null,
        .poll = livePoll,
        .close = liveClose,
        .ready = liveReady,
        .data = live,
        .min_query = live.spec.min_query,
        .debounce_ns = @as(u64, live.spec.debounce_ms) * std.time.ns_per_ms,
    };
}

fn dropPending(live: *LiveSource, gpa: Allocator) void {
    for (live.pending.items) |row| {
        gpa.free(row.text);
        gpa.free(row.doc);
    }
    live.pending.clearRetainingCapacity();
}

/// The query settled: a new generation. Rows still waiting for the last one
/// are dropped, and the plugin is asked about this one — framed as a
/// dispatch on the head whose pick it is, the way `on_pick_accept` is.
fn liveQuery(data: ?*anyopaque, ctx: *command.Context, query: []const u8, epoch: u64) anyerror!void {
    const live: *LiveSource = @ptrCast(@alignCast(data.?));
    const p = live.plugin;
    dropPending(live, p.gpa);
    live.epoch = @truncate(epoch);
    live.taken = 0;
    live.done = false;
    live.capped = false;
    const saved_query = p.cur_live_query;
    p.cur_live_query = query;
    defer p.cur_live_query = saved_query;
    try callFramed(p, ctx, "on_pick_query", .{ @as(i32, @bitCast(live.pick_id)), @as(i32, @bitCast(live.epoch)) });
}

/// Each frame: take the waiting rows into the pick. The first rows of a new
/// generation (or its `done` with none) replace the last one's, so a query's
/// answer never shows mixed with the one before it.
fn livePoll(data: ?*anyopaque, ctx: *command.Context) anyerror!bool {
    const live: *LiveSource = @ptrCast(@alignCast(data.?));
    const gpa = live.plugin.gpa;
    const fresh = live.shown != live.epoch;
    const p = &ctx.head.pick;
    if (p.truncated != live.capped and !fresh) {
        p.truncated = live.capped;
        if (live.pending.items.len == 0) return true;
    }
    if (live.pending.items.len == 0 and !(fresh and live.done)) return false;
    defer dropPending(live, gpa);
    const texts = try gpa.alloc([]const u8, live.pending.items.len);
    defer gpa.free(texts);
    const docs = try gpa.alloc([]const u8, live.pending.items.len);
    defer gpa.free(docs);
    for (live.pending.items, texts, docs) |row, *tx, *dc| {
        tx.* = row.text;
        dc.* = row.doc;
    }
    if (fresh) {
        const entries = try gpa.alloc(pick_mod.Entry, texts.len);
        defer gpa.free(entries);
        for (entries, texts, docs) |*en, tx, dc| en.* = .{ .text = tx, .doc = dc };
        try p.refresh(gpa, entries, &.{});
        live.shown = live.epoch;
        p.truncated = live.capped;
    } else {
        try p.appendItems(gpa, texts, docs);
    }
    return true;
}

fn liveReady(data: ?*anyopaque) bool {
    const live: *LiveSource = @ptrCast(@alignCast(data.?));
    return live.pending.items.len > 0 or (live.done and live.shown != live.epoch);
}

fn liveClose(data: ?*anyopaque, gpa: Allocator) void {
    const live: *LiveSource = @ptrCast(@alignCast(data.?));
    if (live.plugin.live_pick == live) live.plugin.live_pick = null;
    dropPending(live, gpa);
    live.pending.deinit(gpa);
    gpa.destroy(live);
}

/// Call a plugin's callback as a DISPATCH on `ctx`'s head — the framing
/// `wpPickAccept` gives `on_pick_accept` (see its doc), for the live
/// source's `on_pick_query`.
fn callFramed(p: *WasmPlugin, ctx: *command.Context, comptime name: []const u8, args: anytype) !void {
    if (p.dispatch_depth == 0) {
        p.clearEphemeralRanges();
        p.clearRetiredResultBuffers();
    }
    const saved_ctx = p.active_ctx;
    const saved_dispatch = p.in_dispatch;
    p.dispatch_depth += 1;
    p.active_ctx = ctx;
    p.in_dispatch = true;
    defer {
        p.dispatch_depth -= 1;
        p.active_ctx = saved_ctx;
        p.in_dispatch = saved_dispatch;
    }
    try contract.callOptionalExport(name, p, args);
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

/// `wl_pick_add_keyed`: like `wl_pick_add`, but the row's public KEY is its
/// own — a command row a person reads by label, which an annotator looks up
/// by id (`args[4..6]`). The accept still reads it by add order.
pub fn hPickAddKeyed(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const key = caller.readMemory(p.gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer p.gpa.free(key);
    addItem(data, caller, args, null, key);
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
    // A live pick's feed, handed to the pick as its source: `openWith` owns
    // it from here, closing it on failure as on close.
    const live: ?*LiveSource = if (p.pick_live) |spec| blk: {
        const l = gpa.create(LiveSource) catch {
            gpa.free(keys);
            gpa.destroy(bp);
            return;
        };
        l.* = .{ .plugin = p, .pick_id = p.pick_id, .spec = spec };
        break :blk l;
    } else null;
    const given = if (p.pick_live) |spec| spec.given else false;
    p.activeCtx().head.pick.openWith(p.activeCtx(), p.pick_prompt.items, entries, .{
        .handler = wpPickAccept,
        .cleanup = wpPickCleanup,
        .data = bp,
    }, .{
        .allow_free_text = p.pick_free_text,
        .category = p.pick_category.items,
        .source = if (live) |l| liveSource(l) else null,
        .style = if (given) .given else .orderless,
    }) catch {
        gpa.free(keys);
        gpa.destroy(bp);
        return;
    };
    // Open: the feed is live. (Opening closed any live pick before it, whose
    // source cleared this field on the way out.)
    p.live_pick = live;
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
    // What it lists is the place this dispatch runs in, resolved the way a
    // typed name is (`designation.resolveRelative`), so the candidates it
    // hands back are relative to exactly what `open` will resolve them
    // against. The guest names no directory.
    const ctx = p.activeCtx();
    const root = (designation.resolveRelative(ctx, gpa, ".") catch return) orelse {
        ctx.head.echo.say(gpa, "open: this place has no local directory to list") catch {};
        return;
    };
    defer gpa.free(root);
    const bp = gpa.create(WasmBoundPick) catch return;
    bp.* = .{ .plugin = p, .pick_id = @intCast(args[2]) };
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
    // BITCAST on the way back out too — the mirror of `hPickBegin`'s. The id is
    // the guest's own word and must return to it unchanged; `@intCast` panicked
    // on exactly the ids `hPickBegin` had just been taught to accept, so the
    // crash simply moved from the ask to the answer.
    try contract.callRequiredExport("on_pick_accept", p, .{@as(i32, @bitCast(bp.pick_id))});
}

fn wpPickCleanup(data: ?*anyopaque, gpa: Allocator) void {
    const bp: *WasmBoundPick = @ptrCast(@alignCast(data.?));
    gpa.free(bp.buffer_keys);
    gpa.destroy(bp);
}
