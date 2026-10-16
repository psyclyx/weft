//! Activation (design §3): the host tells a plugin which buffer took focus so it
//! can attach language keymaps/facts; the guest reads that path back during the
//! `on_activate` dispatch.

const std = @import("std");
const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;
const pty_doors = @import("pty.zig");
const async_loop = @import("../async.zig");
const semantic_fs_doors = @import("semantic_fs.zig");

/// Fire the activation event (design §3): tell a plugin a buffer with `path`
/// took focus, so it can attach language keymaps/facts. A no-op for a plugin
/// that doesn't export `on_activate`. The plugin is resident, so this host→
/// guest call can never use-after-free. The path is borrowed for the call.
pub fn notifyActivate(p: *WasmPlugin, path: []const u8) void {
    p.cur_activate_path = path;
    defer p.cur_activate_path = &.{};
    contract.callOptionalExport("on_activate", p, .{}) catch {}; // MissingExport → skip
}

/// Service a plugin's async proc I/O — but only when there's something to do.
/// A plugin "registers" interest by opening a raw proc stream (`wl_proc_spawn`);
/// the host calls its `on_poll` export ONLY when one of those streams has bytes
/// pending. So idle plugins (and every plugin without a stream) cost nothing —
/// this is readiness-driven, not a blind per-frame poll. A directory the
/// plugin watches (`wl_semantic_fs_watch`) that changed is ready too.
/// Returns whether it ran.
pub fn notifyPollIfReady(p: *WasmPlugin) bool {
    // Asked every time, first: polling a watch is what drains it.
    const watched = semantic_fs_doors.pollWatches(p);
    const streamed = for (p.resources.streams.slice()) |maybe| {
        if (maybe) |s| if (s.pending() > 0) break true;
    } else pty_doors.anyPtyReady(p) or pty_doors.anyExtentMoved(p);
    const raced = @import("capability.zig").raceReady(p);
    const ready = watched or streamed or raced;
    if (!ready) return false;
    notifyPoll(p);
    return true;
}

/// Fire `on_poll` now. What it answers for includes every grid entry of the
/// plugin's whose pane moved (`Buffer.extent_moved`): those are cleared
/// here, heard or not, so an owner that never asks is not asked again.
pub fn notifyPoll(p: *WasmPlugin) void {
    p.seen_grid_closes = p.activeCtx().buffers.grid_closes;
    var it = p.activeCtx().buffers.iterator();
    while (it.next()) |b| if (b.extent_moved and std.mem.eql(u8, b.creator, p.name)) {
        b.extent_moved = false;
    };
    contract.callOptionalExport("on_poll", p, .{}) catch {}; // MissingExport → skip
}

/// After a frame: tell every plugin whose grid entry the frame gave a new
/// extent (the pane it shows in grew, shrank, or first showed it), so it
/// can size its grid — and its terminal — before the next one. Returns
/// whether any was told (their publishes are the next frame's to draw).
pub fn notifyExtents(plugins: []const *WasmPlugin) bool {
    var any = false;
    for (plugins) |p| if (pty_doors.anyExtentMoved(p)) {
        notifyPoll(p);
        any = true;
    };
    return any;
}

pub fn hActivatePath(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = @intCast(caller.writeMemory(@intCast(args[0]), @intCast(args[1]), p.cur_activate_path) catch 0);
}

// ── Signals ─────────────────────────────────────────────────────────
//
// A NAMED "something changed" one plugin raises and any other hears, without
// either naming the other: the `lsp` plugin says `diagnostics` when a
// server's diagnostics move, and a list of problems re-reads them. Core keeps
// no vocabulary of signal names and no payload — a listener asks the emitter
// through its ordinary commands for whatever it needs.
//
// An emit is RECORDED on the emitter and delivered at the frame boundary
// (`deliverSignals`), never from inside the emit: the emitter may be in the
// middle of a command or a poll, and a listener re-entering it there would
// recurse into state it is still writing. Several emits of one name in one
// wake are one delivery.
//
// Core raises names of its own too, in a namespace no plugin may emit into
// (`core_namespace`) — so a listener can trust that `input.typed` was typing
// and not a plugin saying so. Core still carries no payload with them.
//
// A signal can also be raised LATER (`wl_signal_emit_after`): a timer on the
// plugin loop that, when due, raises the name exactly as an emit would. A
// pending one is per (plugin, name), so raising it again before it fires
// moves it — the whole of a debounce.

/// Longest signal name; a longer one is refused.
pub const max_signal_name = 64;
/// Most distinct names one plugin listens for.
pub const max_signal_subscriptions = 16;
/// Most delayed signals one plugin holds pending at once.
pub const max_signal_timers = 16;

/// The namespace of the signals core raises itself; a plugin's emit into it
/// is refused.
pub const core_namespace = "input.";
/// Raised at the frame boundary after a person's live keystroke typed text
/// into the active entry's text document (`Head.typed`).
pub const typed_signal = core_namespace ++ "typed";
/// Raised at the frame boundary when the active entry, or its primary caret,
/// is not where it was at the last one: what a popup anchored at the caret
/// (a hover, a signature's help) is closed or moved on.
pub const caret_signal = core_namespace ++ "caret";
/// Raised at the frame boundary when the head's mode is not the one it was
/// in at the last one (insert left, a picker opened).
pub const mode_signal = core_namespace ++ "mode";

fn coreOwned(name: []const u8) bool {
    return std.mem.startsWith(u8, name, core_namespace);
}

/// `wl_signal_subscribe(name) -> id`: hear `name` as `on_signal(id)`. The same
/// name twice is the same id. -1 when refused.
pub fn hSignalSubscribe(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = -1;
    const len: u32 = @bitCast(args[1]);
    if (len == 0 or len > max_signal_name) return;
    const name = caller.readMemory(p.gpa, @as(u32, @bitCast(args[0])), len) catch return;
    for (p.signal_subscriptions.items, 0..) |known, i| if (std.mem.eql(u8, known, name)) {
        p.gpa.free(name);
        results[0] = @intCast(i);
        return;
    };
    if (p.signal_subscriptions.items.len >= max_signal_subscriptions) return p.gpa.free(name);
    p.signal_subscriptions.append(p.gpa, name) catch return p.gpa.free(name);
    results[0] = @intCast(p.signal_subscriptions.items.len - 1);
}

/// `wl_signal_emit(name)`: raise `name` for every listener, at the next frame
/// boundary. Returns 1 when recorded.
pub fn hSignalEmit(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    const len: u32 = @bitCast(args[1]);
    if (len == 0 or len > max_signal_name) return;
    const name = caller.readMemory(p.gpa, @as(u32, @bitCast(args[0])), len) catch return;
    if (coreOwned(name)) return p.gpa.free(name);
    raise(p, name);
    results[0] = 1;
}

/// Record `name` (owned, taken) as raised by `p` this wake.
fn raise(p: *WasmPlugin, name: []u8) void {
    for (p.signals_raised.items) |known| if (std.mem.eql(u8, known, name)) {
        p.gpa.free(name);
        return;
    };
    p.signals_raised.append(p.gpa, name) catch p.gpa.free(name);
}

/// One pending `wl_signal_emit_after`: the plugin loop's sink context. Owned
/// by the loop (freed by its teardown, fired or cancelled); `p.signal_timers`
/// only borrows it, to find and cancel it by name.
pub const SignalTimer = struct {
    /// Read only when the timer FIRES — a cancelled one (its plugin may be
    /// gone) is freed through `gpa` alone.
    plugin: *WasmPlugin,
    gpa: std.mem.Allocator,
    name: []u8,
    id: async_loop.Id = undefined,
};

/// `wl_signal_emit_after(name, ms) -> 1 | 0`: raise `name` as `wl_signal_emit`
/// would, once `ms` milliseconds have passed. A pending one of the same name
/// from this plugin is moved (re-armed from now), and a negative `ms` only
/// cancels it. Gated on `timer`: it is a wakeup of the frame loop on the
/// plugin's say-so. 0 when refused (too long, core's namespace, past
/// `max_signal_timers`, no loop).
pub fn hSignalEmitAfter(data: ?*anyopaque, caller: *wasm.Caller, args: []const i32, results: []i32) void {
    const p: *WasmPlugin = @ptrCast(@alignCast(data.?));
    results[0] = 0;
    if (!shared.requirePerm(p, caller, .timer)) return;
    const loop = p.loop orelse return;
    const len: u32 = @bitCast(args[1]);
    if (len == 0 or len > max_signal_name) return;
    const name = caller.readMemory(p.gpa, @as(u32, @bitCast(args[0])), len) catch return;
    if (coreOwned(name)) return p.gpa.free(name);
    for (p.signal_timers.items, 0..) |pending, i| if (std.mem.eql(u8, pending.name, name)) {
        loop.cancel(pending.id); // the loop frees it at its next tick
        _ = p.signal_timers.swapRemove(i);
        break;
    };
    const ms = args[2];
    if (ms < 0) {
        p.gpa.free(name);
        results[0] = 1;
        return;
    }
    if (p.signal_timers.items.len >= max_signal_timers) return p.gpa.free(name);
    p.signal_timers.ensureUnusedCapacity(p.gpa, 1) catch return p.gpa.free(name);
    const timer = p.gpa.create(SignalTimer) catch return p.gpa.free(name);
    timer.* = .{ .plugin = p, .gpa = p.gpa, .name = name };
    timer.id = loop.timer(@as(u64, @intCast(ms)) * std.time.ns_per_ms, 0, .{
        .ctx = timer,
        .call = signalTimerDue,
        .deinit = signalTimerFree,
    }) catch {
        signalTimerFree(timer);
        return;
    };
    p.signal_timers.appendAssumeCapacity(timer);
    results[0] = 1;
}

/// Due: raise the name for the next boundary, as an emit made now would.
fn signalTimerDue(ctx: ?*anyopaque, result: ?[]const u8) void {
    _ = result;
    const timer: *SignalTimer = @ptrCast(@alignCast(ctx.?));
    const p = timer.plugin;
    for (p.signal_timers.items, 0..) |pending, i| if (pending == timer) {
        _ = p.signal_timers.swapRemove(i);
        break;
    };
    const name = p.gpa.dupe(u8, timer.name) catch return;
    raise(p, name);
}

fn signalTimerFree(ctx: ?*anyopaque) void {
    const timer: *SignalTimer = @ptrCast(@alignCast(ctx.?));
    const gpa = timer.gpa;
    gpa.free(timer.name);
    gpa.destroy(timer);
}

/// A plugin going away: cancel what it holds pending, so no timer of its
/// fires into freed memory. The loop frees each at its next tick (or its own
/// teardown); none is called.
pub fn cancelSignalTimers(p: *WasmPlugin) void {
    const loop = p.loop orelse return;
    for (p.signal_timers.items) |pending| loop.cancel(pending.id);
    p.signal_timers.clearRetainingCapacity();
}

/// Deliver every signal any of `plugins` raised since the last call — and
/// `core_raised`, the names core raised itself (`core_namespace`) — to every
/// plugin listening for it (`on_signal(id)`), then forget them. The caller
/// decides WHEN — the app's frame boundary. A signal raised by a listener
/// during delivery waits for the next boundary. Returns whether any listener
/// ran.
pub fn deliverSignals(gpa: std.mem.Allocator, plugins: []const *WasmPlugin, core_raised: []const []const u8) bool {
    var raised: std.ArrayList([]u8) = .empty;
    defer {
        for (raised.items) |name| gpa.free(name);
        raised.deinit(gpa);
    }
    for (core_raised) |name| {
        std.debug.assert(coreOwned(name));
        const owned = gpa.dupe(u8, name) catch continue;
        raised.append(gpa, owned) catch gpa.free(owned);
    }
    for (plugins) |p| {
        for (p.signals_raised.items) |name| {
            defer p.gpa.free(name);
            for (raised.items) |known| {
                if (std.mem.eql(u8, known, name)) break;
            } else {
                const owned = gpa.dupe(u8, name) catch continue;
                raised.append(gpa, owned) catch gpa.free(owned);
            }
        }
        p.signals_raised.clearRetainingCapacity();
    }
    var ran = false;
    for (raised.items) |name| {
        for (plugins) |p| {
            for (p.signal_subscriptions.items, 0..) |known, id| {
                if (!std.mem.eql(u8, known, name)) continue;
                contract.callOptionalExport("on_signal", p, .{@as(i32, @intCast(id))}) catch continue;
                ran = true;
            }
        }
    }
    return ran;
}
