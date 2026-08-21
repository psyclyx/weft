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
    contract.callOptionalExport("on_complete", &p.instance, .{handle}) catch {
        caps.decline(req.session);
        p.capsBuilderClear();
    };
}
