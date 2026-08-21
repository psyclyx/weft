//! The reified implicit timers + fd sources for the app-layer scheduler
//! loop (north-star-plan §6 W2a-3 / §4 C16). Every entry here replaces a
//! `now >= some_deadline` check that used to be serviced *by accident*
//! because the old loop unconditionally woke every vsync — the check
//! itself (the actual state mutation: flip the caret, fire the which-key
//! popup, retry a stale save…) still lives exactly where it always did
//! (`main.zig`'s per-wake body, `frame.zig`'s `tickAsync`, `collab.zig`'s
//! `tickCollab`); what moves here is only the QUESTION "when do you next
//! need attention", asked once per scheduler wake so `core/scheduler.zig`
//! can sleep until the real answer instead of guessing via vsync.
//!
//! Every `*Due`/`*Query` function here is a PURE query: it reads state,
//! returns the next absolute `now_ns` this source needs the body to run
//! again (or `null` to go dormant), and mutates nothing. `main.zig`'s
//! per-wake body — run unconditionally after every `Scheduler.step()`,
//! whichever source woke it — does the actual work, unchanged from before
//! this file existed. This split is what lets one `step()` wake for
//! several reasons at once and still run one coherent pass.
//!
//! `headless.zig` shares the fd-drain helpers and the pool/hub source
//! shapes with `main.zig` (north-star-plan §6 W2a-3 item 5's unification)
//! but not the window-shaped timers below (blink/repeat/which-key/flash/
//! pointer are all window concerns headless has none of).

const std = @import("std");
const core = @import("../core/core.zig");
const scheduler = core.scheduler;
const wayland = @import("../platform/wayland.zig");
const cursor_config = @import("cursor_config.zig");
const frame = @import("frame.zig");
const collab = @import("collab.zig");

/// A source that never mutates, only marks readiness on an fd `step`
/// already knows how to drain by itself (`onReady = null`, see
/// `scheduler.zig`'s doc) has nothing for this file to do — this no-op is
/// only needed for a REAL fd (wayland's socket) whose draining is someone
/// else's job (`Window.pumpEvents`, called unconditionally every wake).
pub fn noopFdReady(ctx: ?*anyopaque, readable: bool, writable: bool) void {
    _ = ctx;
    _ = readable;
    _ = writable;
}

// ── 1. Key repeat — old site: wayland.zig's `emitKeyRepeats`, clock-polled
// inside `pumpEvents`, correct only because vsync called it every ~16ms. ──

pub fn keyRepeatDue(ctx: ?*anyopaque, now: u64) ?u64 {
    _ = now;
    const w: *wayland.Window = @ptrCast(@alignCast(ctx.?));
    return w.repeatDueNs();
}

// ── 2. Caret blink — old site: main.zig's inline `blink_next_ns` compare
// (§6 old-numbering ~:513-523). ──

pub const BlinkCtx = struct {
    cursor_cfg: *const cursor_config.CursorConfig,
    keymap: *const core.Keymap,
    head: *const core.Head,
    blink_next_ns: *const u64,
};

pub fn blinkDue(ctx: ?*anyopaque, now: u64) ?u64 {
    _ = now;
    const self: *const BlinkCtx = @ptrCast(@alignCast(ctx.?));
    const mode = self.cursor_cfg.resolveMode(self.keymap, self.head, self.head.currentMode());
    if (!self.cursor_cfg.blinkFor(mode)) return null;
    return self.blink_next_ns.*;
}

// ── 3. Which-key idle delay — old site: `frame.MenuOverlay.update`'s
// `frame_start -| open_ns >= which_key_delay_ns` compare. ──

pub const WhichKeyCtx = struct {
    menu: *const frame.MenuOverlay,
    delay_ns: u64,
};

pub fn whichKeyDue(ctx: ?*anyopaque, now: u64) ?u64 {
    _ = now;
    const self: *const WhichKeyCtx = @ptrCast(@alignCast(ctx.?));
    if (!self.menu.open or self.menu.shown or self.menu.forced) return null;
    return self.menu.open_ns + self.delay_ns;
}

// ── 4. Backing poll cadence — old site: `frame.tickAsync`'s
// `next_backing_poll_ns` compare (unconditional 2s cadence; unchanged). ──

pub fn backingPollDue(ctx: ?*anyopaque, now: u64) ?u64 {
    _ = now;
    const next: *const u64 = @ptrCast(@alignCast(ctx.?));
    return next.*;
}

// ── 5. vim-goggles flash expiry — old site: main.zig's inline flash block
// inside `frame_builder.zig`'s `buildFrame` (`flash_start_ns +
// flash_duration_ns` compare, previously only re-checked because vsync
// forced a rebuild every frame regardless of damage). ──

pub const FlashCtx = struct {
    flash_start_ns: *const u64,
    flash_duration_ns: u64,
};

pub fn flashDue(ctx: ?*anyopaque, now: u64) ?u64 {
    const self: *const FlashCtx = @ptrCast(@alignCast(ctx.?));
    const fs = core.wasm_host.flashState();
    if (fs.gen == 0) return null;
    const due = self.flash_start_ns.* + self.flash_duration_ns;
    if (due <= now) return null; // already expired; the body clears it on this wake
    return due;
}

// ── 6. Client reconnect backoff — old site: `collab.tickCollab`'s
// `next_reconnect_ns` compare, live only while offline with a --connect
// target. ──

pub const ReconnectCtx = struct {
    share_ctx: *const collab.ShareCtx,
    next_reconnect_ns: *const u64,
    connect_arg: ?[]const u8,
};

pub fn reconnectDue(ctx: ?*anyopaque, now: u64) ?u64 {
    _ = now;
    const self: *const ReconnectCtx = @ptrCast(@alignCast(ctx.?));
    if (self.connect_arg == null) return null;
    const sess = self.share_ctx.session.* orelse return null;
    if (sess.liveness() != .offline) return null;
    return self.next_reconnect_ns.*;
}

// ── 7. Pick async-source debounce — old site: `Pick.tick`'s
// `task.nowNs() - last_query_ns >= src.debounce_ns` compare, live only
// while a picker with an async source is open. ──

pub fn pickDebounceDue(ctx: ?*anyopaque, now: u64) ?u64 {
    _ = now;
    const head: *const core.Head = @ptrCast(@alignCast(ctx.?));
    if (!head.pick.active) return null;
    const src = head.pick.source orelse return null;
    if (head.pick.source_epoch == head.pick.query_epoch) return null; // nothing pending
    return head.pick.last_query_ns + src.debounce_ns;
}

// ── 8. Present retry — new (no old site): a frame was BUILT but the GPU
// fence wasn't signaled yet (`Context.beginFrame` returning null rather
// than blocking — north-star-plan §2.7's "never block on a GPU fence").
// Demands immediacy (returns `now`) exactly while a present is
// outstanding; fully dormant otherwise. As of the lost-wakeup ordering
// fix (`scheduler.zig`'s `step`), "demands immediacy" is no longer
// aspirational — the very next `step` (not one step later) sees a
// `present_pending` this source's own caller just set, so a present that
// was deferred for a busy fence really does retry on the next wake.
//
// Suppressed while the swapchain is stale/zero-extent (review fix: a
// minimized window leaves `present_pending` latched with nothing
// presentable — without this gate, THIS source would spin `step` at
// zero-timeout forever, 100% CPU, for as long as the window stays
// minimized). Re-arms itself the instant `swapchain_stale` clears — no
// separate "on resize" hook needed, since a real resize sets
// `view_dirty` unconditionally (main.zig), which rebuilds and re-latches
// `present_pending` through the ordinary dirty path. ──

pub const PresentRetryCtx = struct {
    pending: *const bool,
    swapchain_stale: *const bool,
};

pub fn presentRetryDue(ctx: ?*anyopaque, now: u64) ?u64 {
    const self: *const PresentRetryCtx = @ptrCast(@alignCast(ctx.?));
    if (self.swapchain_stale.*) return null; // minimized/zero-extent: nothing to present
    if (!self.pending.*) return null;
    return now;
}

// ── 9. plugin_loop's own timers — old site: none (this loop's timers were
// ALREADY explicit deadlines, `core/async.zig`'s `Timer.due_ns` — but
// nothing told the frame loop about them; `tick()` only ran because vsync
// called it every frame). `nextDueNs` is a pure query over the same data. ──

pub fn pluginLoopDue(ctx: ?*anyopaque, now: u64) ?u64 {
    _ = now;
    const loop: *const core.async_loop.Loop = @ptrCast(@alignCast(ctx.?));
    return loop.nextDueNs();
}

// ── 10. Background services fallback — a deliberate, bounded-latency
// compromise (see the report / north-star-plan follow-up), NOT a
// per-subsystem reification: collab hub/conn ticking has a real push
// wakeup (Session/Hub's `wake_fd`, registered as fd sources below), but
// REPL/LSP proc-stream readiness (`wasm_host.notifyPollIfReady`/
// `drainReplSessions`) and picker async POLL sources are serviced by a
// long-running pool task writing into a plain buffer with no completion
// signal of its own (`task.Pool`'s wake-fd only fires when the WHOLE task
// finishes, i.e. process exit, not per byte). Rather than plumb a
// dedicated wakeup through every one of those (repl_session.zig,
// proc_stream.zig, each guest's own polling shape), this is one named,
// honestly-bounded 8ms fallback.
//
// Gated on an ACTUALLY-LIVE stream (review fix: gating on "any plugin
// resident" was wrong — LSP/modes/syntax/vim etc. are ordinary plugins
// too, so any real config would arm this at ~125 wakes/s FOREVER, worse
// than the vsync loop it replaced, and it was masking the lost-wakeup
// bug by accident). A plugin is "streaming" only while it holds an open
// raw-proc, REPL, or net session — `proc_streams`/`sessions`/
// `net_sessions` (host-side) and `streams` (quickjs) are stable-index
// slot arrays; a non-null entry is an OPEN handle, independent of
// whether it currently has pending bytes (that's what the 8ms poll is
// FOR — to notice bytes arriving on an otherwise-quiet handle). A
// plugin with no open stream (the common case — most plugins never open
// one) costs nothing here. ──

pub const PluginStreamCtx = struct {
    plugins: *const std.ArrayList(*core.wasm_abi.WasmPlugin),
    js_plugins: *const std.ArrayList(*core.quickjs.JsPlugin),
};

const plugin_stream_interval_ns: u64 = 8 * std.time.ns_per_ms;

fn anyOpenStream(items: anytype) bool {
    for (items) |maybe| if (maybe != null) return true;
    return false;
}

fn hasLiveStream(self: *const PluginStreamCtx) bool {
    for (self.plugins.items) |p| {
        if (anyOpenStream(p.proc_streams.items)) return true;
        if (anyOpenStream(p.sessions.items)) return true;
        if (anyOpenStream(p.net_sessions.items)) return true;
    }
    for (self.js_plugins.items) |jp| {
        if (anyOpenStream(jp.streams.items)) return true;
    }
    return false;
}

pub fn pluginStreamDue(ctx: ?*anyopaque, now: u64) ?u64 {
    const self: *const PluginStreamCtx = @ptrCast(@alignCast(ctx.?));
    if (!hasLiveStream(self)) return null;
    return now + plugin_stream_interval_ns;
}
