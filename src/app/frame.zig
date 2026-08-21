//! `FrameCtx` — the read/borrow surface the frame BUILD phase needs. The HUD
//! aggregates the whole application (mode, tabs, peers, diagnostics, flash,
//! save state…), so `buildFrame` genuinely reads from every corner of the app;
//! this bundle names those borrows in one place instead of a long parameter
//! list. It OWNS nothing — every field is a pointer into a `main()` local (or a
//! small config value), so there is no init/deinit and no lifetime of its own.
//!
//! It is assembled once, before the loop, from the stable `main()` addresses;
//! the per-frame-varying handles (the active editor/buffer/attach, blink, the
//! frame clock, the framebuffer size) are passed to `buildFrame` per call.
//!
//! When the session/collab/providers clusters later become cohesive owned
//! structs, this bundle collapses into `&session, &collab, &providers` — it is
//! the seam that grouping will replace.

const std = @import("std");
const core = @import("../core/core.zig");
const region = @import("../gfx/region.zig");
const cursor_config = @import("cursor_config.zig");
const providers = @import("providers.zig");

/// which-key menu-overlay edge detection. Owns the small cluster of state that
/// tracks whether a menu mode is active and whether its hint popup has fired,
/// so `on_menu(open/close)` fire exactly once per enter/leave at the frame
/// boundary (never nested inside another guest call). `.{}` is the idle state.
///
/// PER-HEAD (north-star-plan §6 W2a-2): a menu popup opening for head A must
/// not suppress/idle-time head B's, so this struct's storage lives beside
/// whichever `core.Head` it tracks (`app.Session.menu_overlay` for the app's
/// one head today; a second head's own instance for a second). It can't live
/// ON `core.Head` itself — `Head` is core and this type is app-layer (it
/// notifies wasm plugins) — so `update` stays a pure-ish function of an
/// explicit `*core.Head` (mirroring the Keymap-tables/Head-cursor split),
/// and the CALLER is responsible for pairing the right overlay instance with
/// the right head, exactly as it already pairs `head`/`keymap`/`plugins`.
pub const MenuOverlay = struct {
    open: bool = false,
    shown: bool = false, // has on_menu(open) fired for the current menu?
    forced: bool = false, // F1 peek at a NON-menu mode's keys (toggled)
    open_ns: u64 = 0, // when the current menu was entered (idle timer)
    last_mode: [64]u8 = undefined,
    last_len: usize = 0,

    /// Fire menu-overlay edges: `on_menu(open)` when a (different) menu mode
    /// becomes active, `on_menu(close)` when we leave menus. `which_key_now`
    /// (F1) forces the hint immediately, bypassing the idle delay; it is
    /// consumed here. Returns whether the view was damaged.
    pub fn update(
        self: *MenuOverlay,
        head: *core.Head,
        keymap: *const core.Keymap,
        plugins: *std.ArrayList(*core.wasm_abi.WasmPlugin),
        frame_start: u64,
        which_key_now: *bool,
        which_key_delay_ns: u64,
    ) bool {
        var dirty = false;
        const cur = head.currentMode();
        const in_chord = head.pending.len > 0;
        const is_menu = keymap.isMenuMode(cur);
        // What the overlay currently reflects: the pending chord if one's being
        // typed (`space f`), else the mode name. which-key re-renders whenever
        // this changes — each keystroke of a chord grows the pending prefix, so
        // the completions update in place.
        const content: []const u8 = if (in_chord) head.pending else cur;
        const changed = self.open and !std.mem.eql(u8, content, self.last_mode[0..self.last_len]);
        // F1 toggles a forced peek at the CURRENT (any) mode. Leaving that mode
        // ends the peek — a menu you drill into then shows on its own.
        if (which_key_now.*) self.forced = !self.forced;
        which_key_now.* = false;
        if (changed) self.forced = false;

        // The overlay is active mid-chord (immediately as you type a sequence),
        // for a legacy menu mode (after the idle delay), or while a forced peek is
        // on (immediately, any mode). No hardcoded root menu.
        const active = in_chord or is_menu or self.forced;
        // "Same" must ALSO cover "closed before, closed now" — the ordinary
        // idle state outside any menu. The old `active and self.open and
        // !changed` was false whenever `active` was false REGARDLESS of
        // `self.open`, so this returned `dirty = true` on every single call
        // while idle outside a menu (north-star-plan §6 W2a-3: found via
        // the idle-wakeup measurement — dirty-gated present is meaningless
        // if something marks dirty unconditionally every wake). `changed`
        // is already false whenever `self.open` is false (see its
        // definition above), so comparing openness directly is exact.
        const same = (active == self.open) and !changed;
        if (!same) {
            // Entered/left/switched/grew: close a shown popup; the idle timer is
            // CONTINUOUS while the overlay stays up (menu→submenu hop, or a chord
            // growing key-by-key) — the successor inherits the wait already paid,
            // no re-delay. A fresh entry or a forced peek starts now.
            if (self.open and self.shown) {
                for (plugins.items) |pl| core.wasm_host.notifyMenu(pl, false);
            }
            const carry = self.open and active and !self.forced;
            const prev_open_ns = self.open_ns;
            self.open = active;
            self.shown = false;
            if (active) {
                self.open_ns = if (carry) prev_open_ns else frame_start;
                self.last_len = @min(content.len, self.last_mode.len);
                @memcpy(self.last_mode[0..self.last_len], content[0..self.last_len]);
            }
            dirty = true;
        }
        // Pop the hint once held past the idle delay — or immediately for a
        // forced peek (F1 wants it now).
        if (self.open and !self.shown and (self.forced or frame_start -| self.open_ns >= which_key_delay_ns)) {
            for (plugins.items) |pl| core.wasm_host.notifyMenu(pl, true);
            self.shown = true;
            dirty = true;
        }
        return dirty;
    }
};

pub const FrameCtx = struct {
    gpa: std.mem.Allocator,

    // ── Editor/session core ──
    buffers: *core.Buffers,
    caps: *core.Caps,
    keymap: *core.Keymap,
    /// This frame's (today, singular) head — current mode, pending chord,
    /// pick session, echo line (north-star-plan §6 W2a-1).
    head: *core.Head,

    // ── Config read by the HUD ──
    cursor_cfg: *cursor_config.CursorConfig,

    // ── Plugins (live surfaces + menu overlays) ──
    plugins: *std.ArrayList(*core.wasm_abi.WasmPlugin),

    // ── Collab/net state (all pointers to `main()`'s optionals) ──
    conn: *?core.session.Conn,
    hub: *?core.hub.Hub,
    collab_session: *?*core.session.Session,
    partial_state: *?core.session.PartialDoc,
    /// Buffer 0's editor (wire v1) — the partial-checkout gate reads it.
    ed0: *core.Editor,
    known_peers: *core.known_peers.KnownPeers,
    /// The outbound host fingerprint last noted (the trust chip reads it).
    noted_host_fp: *?[24]u8,

    // ── Cross-phase signals the build both reads and writes ──
    /// Damage flag: the build gates on it (skips a clean frame) and re-arms it
    /// for the frame after a flash so the flash is drawn then cleared.
    view_dirty: *bool,
    /// Last render's pane frame, for click routing next frame.
    last_frame_rect: *region.Rect,

    // ── vim-goggles flash timing ──
    flash_gen: *u64,
    flash_start_ns: *u64,
    flash_was_active: *bool,
    flash_duration_ns: u64,
};

/// The per-frame-varying handles passed to `buildFrame` (the active buffer's
/// editor/buffer/provider attachment plus the frame's clock/geometry), kept
/// distinct from the stable `FrameCtx` borrows.
pub const Active = struct {
    editor: *core.Editor,
    abuf: *core.Buffers.Buffer,
    attach: *providers.Attach,
    frame_start: u64,
    fb: [2]u32,
    blink_on: bool,
    /// Whether the which-key hint is due this frame (past the idle delay).
    /// The host-side fallback hint gates on this too, so it doesn't flash in
    /// the panel during the delay before a which-key plugin's surface appears.
    menu_shown: bool,
};

/// The async housekeeping tick (run each frame, after input): backing
/// maintenance for every buffer (fold saves, merge external writes, retry
/// stale saves, schedule polls), the pick tick, native async completions,
/// plugin poll/REPL streaming (the LSP plugin rides this), the buffer-activation
/// event, and the menu-overlay edges. Returns whether the view was damaged.
pub fn tickAsync(
    fx: *const FrameCtx,
    abuf: *core.Buffers.Buffer,
    cmd_ctx: *core.command.Context,
    plugin_loop: *core.async_loop.Loop,
    next_backing_poll_ns: *u64,
    last_activate_path: *[std.fs.max_path_bytes]u8,
    last_activate_len: *usize,
    menu: *MenuOverlay,
    which_key_now: *bool,
    which_key_delay_ns: u64,
    frame_start: u64,
) !bool {
    const gpa = fx.gpa;
    var dirty = false;
    // Backing maintenance for every buffer: fold saves, merge external
    // writes, retry stale saves, schedule polls.
    {
        const poll_due = core.task.nowNs() >= next_backing_poll_ns.*;
        if (poll_due) next_backing_poll_ns.* = core.task.nowNs() + 2 * std.time.ns_per_s;
        var mit = fx.buffers.iterator();
        while (mit.next()) |b| {
            if (b.editor.pollSave(gpa) and b == abuf) dirty = true;
            const was_stale = b.editor.save_state == .stale;
            if (try b.editor.pollBacking(gpa) and b == abuf) dirty = true;
            if (was_stale and b.editor.save_state == .idle) try b.editor.requestSave(gpa);
            if (poll_due or b.editor.save_state == .stale) try b.editor.requestBackingPoll(gpa);
        }
    }
    // Drive any async pick source (completion race-and-refine, file
    // finder, dir browser) — a no-op for a static or source-less
    // pick. Completion now rides this instead of a bespoke tick.
    if (try fx.head.pick.tick(cmd_ctx)) dirty = true;
    // Deliver native async completions (subprocess/timer output, deferred
    // edits) on the frame thread; a completion repaints.
    if (plugin_loop.tick()) dirty = true;
    // Stream any interactive REPL output into its comint buffer.
    for (fx.plugins.items) |pl| {
        if (core.wasm_host.drainReplSessions(pl)) dirty = true;
        // Service raw-proc plugins (the lsp client) when their stream has bytes.
        if (core.wasm_host.notifyPollIfReady(pl)) dirty = true;
    }
    // Fire the activation event when the focused buffer's path changes, so
    // language-aware plugins (`modes`) can attach keymaps/facts.
    {
        const cur_path = fx.buffers.active().editor.backingPath() orelse "";
        if (!std.mem.eql(u8, cur_path, last_activate_path[0..last_activate_len.*])) {
            for (fx.plugins.items) |pl| core.wasm_host.notifyActivate(pl, cur_path);
            const n = @min(cur_path.len, last_activate_path.len);
            @memcpy(last_activate_path[0..n], cur_path[0..n]);
            last_activate_len.* = n;
        }
    }
    // Menu overlay edges — fired at the frame boundary (top-level, so a
    // menu-owner guest can't re-enter its store).
    if (menu.update(fx.head, fx.keymap, fx.plugins, frame_start, which_key_now, which_key_delay_ns)) dirty = true;
    return dirty;
}

// ── Tests ───────────────────────────────────────────────────────────

const t = std.testing;

test "menu overlay: drilling into a submenu doesn't re-delay once the popup is up" {
    const gpa = t.allocator;
    var km: core.Keymap = .empty;
    defer km.deinit(gpa);
    var head: core.Head = .empty;
    defer head.deinit(gpa);
    try km.markMenuMode(gpa, "leader");
    try km.markMenuMode(gpa, "leader-file");
    var plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty;
    defer plugins.deinit(gpa);

    var mo: MenuOverlay = .{};
    var wkn = false;
    const delay: u64 = 200;

    // Normal: nothing open.
    try head.setMode(gpa, "normal");
    _ = mo.update(&head, &km, &plugins, 0, &wkn, delay);
    try t.expect(!mo.open and !mo.shown);

    // Enter leader at t=100: open, not yet shown (0 < delay).
    try head.setMode(gpa, "leader");
    _ = mo.update(&head, &km, &plugins, 100, &wkn, delay);
    try t.expect(mo.open and !mo.shown);

    // t=350: held past the delay → the popup appears.
    _ = mo.update(&head, &km, &plugins, 350, &wkn, delay);
    try t.expect(mo.shown);

    // Drill into leader-file at t=360: the idle timer is continuous (measured
    // from the first menu entry, t=100), so 360−100 ≥ delay → the submenu hint
    // shows THIS frame, no re-delay. This is the bug fix.
    try head.setMode(gpa, "leader-file");
    _ = mo.update(&head, &km, &plugins, 360, &wkn, delay);
    try t.expect(mo.shown);
}

test "menu overlay: entering a menu from a non-menu still waits the idle delay" {
    const gpa = t.allocator;
    var km: core.Keymap = .empty;
    defer km.deinit(gpa);
    var head: core.Head = .empty;
    defer head.deinit(gpa);
    try km.markMenuMode(gpa, "leader");
    try km.markMenuMode(gpa, "leader-file");
    var plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty;
    defer plugins.deinit(gpa);

    var mo: MenuOverlay = .{};
    var wkn = false;
    const delay: u64 = 200;

    // Fresh entry from normal: the timer starts now — the first popup waits.
    try head.setMode(gpa, "normal");
    _ = mo.update(&head, &km, &plugins, 1000, &wkn, delay);
    try head.setMode(gpa, "leader-file");
    _ = mo.update(&head, &km, &plugins, 1000, &wkn, delay);
    try t.expect(mo.open and !mo.shown);
    _ = mo.update(&head, &km, &plugins, 1150, &wkn, delay); // 150 < delay
    try t.expect(!mo.shown);
    _ = mo.update(&head, &km, &plugins, 1201, &wkn, delay); // 201 ≥ delay
    try t.expect(mo.shown);

    // Leaving menus entirely closes the overlay; a later re-entry starts fresh.
    try head.setMode(gpa, "normal");
    _ = mo.update(&head, &km, &plugins, 1300, &wkn, delay);
    try t.expect(!mo.open and !mo.shown);
    try head.setMode(gpa, "leader");
    _ = mo.update(&head, &km, &plugins, 1300, &wkn, delay);
    try t.expect(!mo.shown); // fresh timer, not instant
}

test "menu overlay: F1 forces the popup immediately, bypassing the delay" {
    const gpa = t.allocator;
    var km: core.Keymap = .empty;
    defer km.deinit(gpa);
    var head: core.Head = .empty;
    defer head.deinit(gpa);
    try km.markMenuMode(gpa, "leader");
    var plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty;
    defer plugins.deinit(gpa);

    var mo: MenuOverlay = .{};
    var wkn = true; // F1 pressed
    try head.setMode(gpa, "leader");
    _ = mo.update(&head, &km, &plugins, 5, &wkn, 10_000);
    try t.expect(mo.shown); // shown despite 5 ≪ delay
    try t.expect(!wkn); // the flag was consumed
}

test "menu overlay: F1 peeks the CURRENT (non-menu) mode; no forced leader; toggles off" {
    const gpa = t.allocator;
    var km: core.Keymap = .empty;
    defer km.deinit(gpa);
    var head: core.Head = .empty;
    defer head.deinit(gpa);
    var plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty;
    defer plugins.deinit(gpa);
    // "normal" is NOT a menu mode; F1 must still reveal ITS keys — the old
    // behavior force-entered a hardcoded "leader" instead of showing the level
    // you're at (the magit-style "wrong menu" jank).
    try head.setMode(gpa, "normal");

    var mo: MenuOverlay = .{};
    var wkn = true; // F1
    _ = mo.update(&head, &km, &plugins, 5, &wkn, 10_000);
    try t.expect(mo.forced);
    try t.expect(mo.shown); // shown immediately for the current mode
    try t.expectEqualStrings("normal", head.currentMode()); // did NOT jump into "leader"

    // A second F1 dismisses the peek.
    wkn = true;
    _ = mo.update(&head, &km, &plugins, 20, &wkn, 10_000);
    try t.expect(!mo.forced);
    try t.expect(!mo.open);
    try t.expect(!mo.shown);
}

test "menu overlay: leaving the peeked mode ends the forced peek" {
    const gpa = t.allocator;
    var km: core.Keymap = .empty;
    defer km.deinit(gpa);
    var head: core.Head = .empty;
    defer head.deinit(gpa);
    var plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty;
    defer plugins.deinit(gpa);
    try head.setMode(gpa, "normal");

    var mo: MenuOverlay = .{};
    var wkn = true; // F1 peeks normal
    _ = mo.update(&head, &km, &plugins, 5, &wkn, 10_000);
    try t.expect(mo.forced and mo.shown);

    // Switch to another non-menu mode: the peek ends (no lingering overlay).
    try head.setMode(gpa, "insert");
    wkn = false;
    _ = mo.update(&head, &km, &plugins, 20, &wkn, 10_000);
    try t.expect(!mo.forced);
    try t.expect(!mo.open);
}

test "menu overlay: idle outside any menu is a stable state — no dirty every call" {
    // north-star-plan §6 W2a-3: this is the exact bug the idle-wakeup
    // measurement caught — `update` must report NOT dirty on a second
    // consecutive call with nothing changed, or dirty-gated present is
    // meaningless (every wake would rebuild regardless of real damage).
    const gpa = t.allocator;
    var km: core.Keymap = .empty;
    defer km.deinit(gpa);
    var head: core.Head = .empty;
    defer head.deinit(gpa);
    try km.markMenuMode(gpa, "leader");
    var plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty;
    defer plugins.deinit(gpa);
    try head.setMode(gpa, "normal");

    var mo: MenuOverlay = .{};
    var wkn = false;
    const dirty1 = mo.update(&head, &km, &plugins, 0, &wkn, 200);
    try t.expect(!dirty1); // both-closed IS the "same" state from `.{}`'s initial idle

    var i: u64 = 1;
    while (i < 20) : (i += 1) {
        const dirty = mo.update(&head, &km, &plugins, i * 100, &wkn, 200);
        try t.expect(!dirty);
    }

    // A real transition (entering a menu) still reports dirty, proving the
    // fix didn't just make everything report `false`.
    try head.setMode(gpa, "leader");
    try t.expect(mo.update(&head, &km, &plugins, 2100, &wkn, 200));
}
