//! Completion provider (host↔guest data-gather): the guest registers a provider
//! in init(); the host binds it into the caps registry with a trampoline that
//! calls the guest's `on_complete(session)` per request. Unlike the old sync
//! one-shot, the guest now OWNS the session's answer — it accretes rich items
//! with `wl_caps_item` and flushes them with `wl_caps_commit`, or gives up with
//! `wl_caps_decline`. It may do so DURING `on_complete` (a sync source like
//! dabbrev) or LATER, off a poll (an async source like LSP): a deferred provider
//! stashes the session id and commits when its response lands, exactly as the
//! native caps model allows (`caps.push` by session id, grace-window bounded).
//! The host no longer pushes on the guest's behalf.

const std = @import("std");
const wasm = @import("../wasm.zig");
const capability = @import("../capability.zig");
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

pub fn hProvideCompletion(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = args;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    // Cross-check: must be declared as the matching capability.
    if (!p.declaresCapability("edit/completion")) {
        p.load_error = error.UndeclaredCapability;
        return;
    }
    if (p.provider_id != null) return; // idempotent
    const gpa = p.gpa;
    const id = std.fmt.allocPrint(gpa, "plugin.{s}/edit/completion", .{p.name}) catch {
        p.load_error = error.OutOfMemory;
        return;
    };
    p.activeCtx().caps.register(.{
        .capability = "edit/completion",
        .id = id,
        // `fast`, not `instant`: a guest source may answer off a later poll
        // (LSP), so it sorts below any truly-instant provider but the merge
        // still shows it the moment it commits.
        .latency = .fast,
        .placement = .host,
        .data = p,
        .handler = wpCompletionProvider,
    }) catch |e| {
        gpa.free(id);
        p.load_error = e;
        return;
    };
    p.provider_id = id;
}

pub fn hCompletionPrefix(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const n = caller.writeMemory(@intCast(args[0]), @intCast(args[1]), p.cur_prefix) catch 0;
    results[0] = @intCast(n);
}

/// Session ids are small monotonic u64 counters; they round-trip losslessly
/// through the i32 wasm boundary as a zero-extended u32 handle.
fn sessionOf(arg: i32) u64 {
    return @as(u32, @bitCast(arg));
}

/// `wl_caps_item(session, text, tl, label, ll, detail, dl, kind, doc, docl, rank)`
/// — append one rich completion item to the plugin's pending batch for `session`.
pub fn hCapsItem(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const gpa = p.gpa;
    const session = sessionOf(args[0]);
    // A new session's first item retires any stale half-built batch.
    if (p.caps_builder_session != session) p.capsBuilderClear();
    p.caps_builder_session = session;

    const text = caller.readMemory(gpa, @intCast(args[1]), @intCast(args[2])) catch return;
    if (text.len == 0) {
        gpa.free(text);
        return;
    }
    const label = caller.readMemory(gpa, @intCast(args[3]), @intCast(args[4])) catch {
        gpa.free(text);
        return;
    };
    const detail = caller.readMemory(gpa, @intCast(args[5]), @intCast(args[6])) catch {
        gpa.free(text);
        gpa.free(label);
        return;
    };
    const doc = caller.readMemory(gpa, @intCast(args[8]), @intCast(args[9])) catch {
        gpa.free(text);
        gpa.free(label);
        gpa.free(detail);
        return;
    };
    const kind: u8 = @truncate(@as(u32, @bitCast(args[7])));
    const rank: i32 = args[10];

    p.caps_builder.append(gpa, .{
        .text = text,
        .label = label,
        .detail = detail,
        .documentation = doc,
        .kind = kind,
        .rank = rank,
    }) catch {
        gpa.free(text);
        gpa.free(label);
        gpa.free(detail);
        gpa.free(doc);
    };
}

/// `wl_caps_commit(session)` — flush the pending batch into the session as one
/// push (deep-copied + re-stamped host-side), decrementing `outstanding` once.
pub fn hCapsCommit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const session = sessionOf(args[0]);
    const from: capability.Caps.From = .{ .id = p.provider_id orelse return, .latency = .fast };
    // Even an empty commit answers the session (so it can reach done()).
    const empty: []capability.CompletionItem = &.{};
    const items = if (p.caps_builder_session == session) p.caps_builder.items else empty;
    p.activeCtx().caps.push(session, from, .{ .completion = items }) catch {};
    p.capsBuilderClear();
}

/// `wl_caps_decline(session)` — this provider will not answer `session`.
pub fn hCapsDecline(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const session = sessionOf(args[0]);
    p.activeCtx().caps.decline(session);
    if (p.caps_builder_session == session) p.capsBuilderClear();
}

// ── The consumer side: a plugin that RACES the providers ─────────────
//
// What `complete_ui` did in core, as doors: fire a race at the caret, read the
// merged ranking as answers land, finish. What the race is FOR — a popup, an
// inline hint, nothing at all — is the plugin's.

/// `wl_caps_fire(kind, offset, prefix, prefix_len) -> session`: race the
/// providers of `kind` (0: completion) over the active entry's document at
/// `offset`, the word typed so far being `prefix`. The plugin holds one race
/// at a time: a new fire finishes the last. -1 when nothing was fired.
pub fn hCapsFire(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    if (args[0] != 0) return;
    const ctx = p.activeCtx();
    if (p.caps_fired != 0) {
        p.capsConsumerDrop();
        ctx.caps.finish(p.caps_fired);
        p.caps_fired = 0;
    }
    const editor = ctx.buffer().textEditor() orelse return;
    const prefix = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer p.gpa.free(prefix);
    const offset: usize = @min(@as(u32, @bitCast(args[1])), editor.text().byteLen());
    const id = (ctx.fireRace(.completion, &editor.doc, editor.backingPath(), .{ .offset = offset, .text = prefix }) catch return) orelse return;
    if (id > std.math.maxInt(u31)) {
        ctx.caps.finish(id);
        return;
    }
    p.caps_fired = id;
    p.caps_done_told = false;
    results[0] = @intCast(id);
}

/// `wl_caps_poll(session) -> count`: fold in what has landed and rank the
/// whole (`Caps.mergedCompletion`); the count of merged items, read with
/// `wl_caps_merged`. Bit 30 set: every provider has answered (or timed
/// out) — no more answers will come. Bit 29 set: an answer already read was
/// filled in since (a resolved item's docs). -1 when the session is not
/// this plugin's or is gone.
pub fn hCapsPoll(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const id = sessionOf(args[0]);
    if (id == 0 or id != p.caps_fired) return;
    const ctx = p.activeCtx();
    const s = ctx.caps.session(id) orelse {
        p.capsConsumerDrop();
        p.caps_fired = 0;
        return;
    };
    _ = s.poll();
    const touched = s.touched;
    s.touched = false;
    const merged = ctx.caps.mergedCompletion(p.gpa, id) catch return;
    p.capsConsumerDrop();
    p.caps_merged = merged;
    var n: i32 = @intCast(@min(merged.len, std.math.maxInt(u16)));
    if (s.done(@import("../task.zig").nowNs())) n |= 1 << 30;
    if (touched) n |= 1 << 29;
    results[0] = n;
}

/// `wl_caps_merged(session, i, field, ptr, cap) -> i32`: field 0 text, 1
/// label, 2 detail, 3 documentation of the `i`-th merged item, written to
/// `ptr` (cap 0 reports the length; a short destination answers -2); field 4
/// answers its kind (`CompletionItem.kind`). -1 when there is no such item.
pub fn hCapsMerged(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const id = sessionOf(args[0]);
    if (id == 0 or id != p.caps_fired) return;
    const i: usize = @as(u32, @bitCast(args[1]));
    if (i >= p.caps_merged.len) return;
    const it = p.caps_merged[i];
    const bytes: []const u8 = switch (args[2]) {
        0 => it.text,
        1 => it.label,
        2 => it.detail,
        3 => it.documentation,
        4 => {
            results[0] = it.kind;
            return;
        },
        else => return,
    };
    const cap: u32 = @bitCast(args[4]);
    if (cap == 0) {
        results[0] = @intCast(@min(bytes.len, std.math.maxInt(i31)));
        return;
    }
    if (bytes.len > cap) {
        results[0] = -2;
        return;
    }
    const n = caller.writeMemory(@intCast(args[3]), cap, bytes) catch return;
    results[0] = @intCast(n);
}

/// Whether the race this plugin fired has something to tell it: answers that
/// landed since its last poll, or — once — that every provider has answered.
/// What `on_poll` is raised for, beside streams and watches.
pub fn raceReady(p: *WasmPlugin) bool {
    if (p.caps_fired == 0) return false;
    const s = p.activeCtx().caps.session(p.caps_fired) orelse return true;
    if (s.fresh < s.results.items.len or s.touched) return true;
    if (!p.caps_done_told and s.done(@import("../task.zig").nowNs())) {
        p.caps_done_told = true;
        return true;
    }
    return false;
}

/// `wl_caps_resolve(session, i) -> i32`: ask the provider that answered the
/// `i`-th merged item to fill in what it left out (its documentation —
/// `completionItem/resolve`), by calling that provider's `on_resolve(session,
/// index)` with the item's index in ITS answer. 1 when asked; 0 when there
/// is nothing to ask (it has docs, or its provider resolves nothing); -1
/// when there is no such item. The answer lands as a touched session.
pub fn hCapsResolve(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const id = sessionOf(args[0]);
    if (id == 0 or id != p.caps_fired) return;
    const i: usize = @as(u32, @bitCast(args[1]));
    if (i >= p.caps_merged.len) return;
    results[0] = 0;
    const item = p.caps_merged[i];
    if (item.documentation.len > 0) return;
    const caps = p.activeCtx().caps;
    const origin = caps.itemOrigin(id, item) orelse return;
    // Only a plugin provider has an `on_resolve` to ask.
    const provider = for (caps.providers.items) |*pr| {
        if (pr.handler == wpCompletionProvider and std.mem.eql(u8, pr.id, origin.provider)) break pr;
    } else return;
    const owner: *WasmPlugin = @ptrCast(@alignCast(provider.data.?));
    if (owner == p) return;
    contract.callOptionalExport("on_resolve", owner, .{ @as(i32, @intCast(id)), @as(i32, @intCast(origin.index)) }) catch return;
    results[0] = 1;
}

/// `wl_caps_item_doc(session, index, detail, dl, doc, docl)`: as the provider
/// that answered `session`, fill in item `index` of its answer with what it
/// resolved: a detail (when non-empty) and its documentation (markdown).
pub fn hCapsItemDoc(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const provider = p.provider_id orelse return;
    const detail = caller.readMemory(p.gpa, @intCast(args[2]), @intCast(args[3])) catch return;
    defer p.gpa.free(detail);
    const doc = caller.readMemory(p.gpa, @intCast(args[4]), @intCast(args[5])) catch return;
    defer p.gpa.free(doc);
    p.activeCtx().caps.resolveItem(sessionOf(args[0]), provider, @as(u32, @bitCast(args[1])), detail, doc) catch {};
}

/// `wl_caps_finish(session)`: the race is done with — dismissed, accepted,
/// or replaced.
pub fn hCapsFinish(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    _ = caller;
    _ = results;
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    const id = sessionOf(args[0]);
    if (id == 0 or id != p.caps_fired) return;
    p.capsConsumerDrop();
    p.activeCtx().caps.finish(id);
    p.caps_fired = 0;
}

/// Caps trampoline: hand the guest the session and let it own the answer. A sync
/// source commits/declines before returning; an async source stashes the session
/// and answers off a later poll. On a guest trap we decline so the session isn't
/// left hanging to the grace deadline.
fn wpCompletionProvider(data: ?*anyopaque, caps: *capability.Caps, req: *const capability.Request) anyerror!void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    if (req.kind != .completion) {
        caps.decline(req.session);
        return;
    }
    p.cur_prefix = req.text;
    defer p.cur_prefix = &.{};
    const handle: i32 = @bitCast(@as(u32, @truncate(req.session)));
    contract.callOptionalExport("on_complete", p, .{handle}) catch {
        caps.decline(req.session);
        p.capsBuilderClear();
    };
}
