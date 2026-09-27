//! Activation (design §3): the host tells a plugin which buffer took focus so it
//! can attach language keymaps/facts; the guest reads that path back during the
//! `on_activate` dispatch.

const std = @import("std");
const wasm = @import("../wasm.zig");
const contract = @import("../membrane/contract.zig");

const shared = @import("plugin.zig");
const WasmPlugin = shared.WasmPlugin;

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
/// this is readiness-driven, not a blind per-frame poll. Returns whether it ran.
pub fn notifyPollIfReady(p: *WasmPlugin) bool {
    const ready = for (p.resources.streams.slice()) |maybe| {
        if (maybe) |s| if (s.pending() > 0) break true;
    } else false;
    if (!ready) return false;
    contract.callOptionalExport("on_poll", p, .{}) catch {}; // MissingExport → skip
    return true;
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

/// Longest signal name; a longer one is refused.
pub const max_signal_name = 64;
/// Most distinct names one plugin listens for.
pub const max_signal_subscriptions = 16;

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
    for (p.signals_raised.items) |known| if (std.mem.eql(u8, known, name)) {
        p.gpa.free(name);
        results[0] = 1;
        return;
    };
    p.signals_raised.append(p.gpa, name) catch return p.gpa.free(name);
    results[0] = 1;
}

/// Deliver every signal any of `plugins` raised since the last call to every
/// plugin listening for it (`on_signal(id)`), then forget them. The caller
/// decides WHEN — the app's frame boundary. A signal raised by a listener
/// during delivery waits for the next boundary. Returns whether any listener
/// ran.
pub fn deliverSignals(gpa: std.mem.Allocator, plugins: []const *WasmPlugin) bool {
    var raised: std.ArrayList([]u8) = .empty;
    defer {
        for (raised.items) |name| gpa.free(name);
        raised.deinit(gpa);
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
