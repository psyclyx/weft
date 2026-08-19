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
pub const MenuOverlay = struct {
    open: bool = false,
    shown: bool = false, // has on_menu(open) fired for the current menu?
    open_ns: u64 = 0, // when the current menu was entered (idle timer)
    last_mode: [64]u8 = undefined,
    last_len: usize = 0,

    /// Fire menu-overlay edges: `on_menu(open)` when a (different) menu mode
    /// becomes active, `on_menu(close)` when we leave menus. `which_key_now`
    /// (F1) forces the hint immediately, bypassing the idle delay; it is
    /// consumed here. Returns whether the view was damaged.
    pub fn update(
        self: *MenuOverlay,
        keymap: *core.Keymap,
        plugins: *std.ArrayList(*core.wasm_abi.WasmPlugin),
        frame_start: u64,
        which_key_now: *bool,
        which_key_delay_ns: u64,
    ) bool {
        var dirty = false;
        const cur = keymap.currentMode();
        const is_menu = keymap.isMenuMode(cur);
        const same = is_menu and self.open and std.mem.eql(u8, cur, self.last_mode[0..self.last_len]);
        if (!same) {
            // Entered/left/switched menu: close a shown popup; (re)start the
            // idle timer. Do NOT show yet — the delay gates that below.
            if (self.open and self.shown) {
                for (plugins.items) |pl| core.wasm_host.notifyMenu(pl, false);
            }
            self.open = is_menu;
            self.shown = false;
            if (is_menu) {
                self.open_ns = frame_start;
                self.last_len = @min(cur.len, self.last_mode.len);
                @memcpy(self.last_mode[0..self.last_len], cur[0..self.last_len]);
            }
            dirty = true;
        }
        // Pop the hint once held past the idle delay (or F1 forced it now).
        if (self.open and !self.shown and (which_key_now.* or frame_start -| self.open_ns >= which_key_delay_ns)) {
            for (plugins.items) |pl| core.wasm_host.notifyMenu(pl, true);
            self.shown = true;
            dirty = true;
        }
        which_key_now.* = false;
        return dirty;
    }
};

pub const FrameCtx = struct {
    gpa: std.mem.Allocator,

    // ── Editor/session core ──
    buffers: *core.Buffers,
    caps: *core.Caps,
    keymap: *core.Keymap,
    pick: *core.Pick,
    echo: *std.ArrayList(u8),

    // ── Capability UI + config read by the HUD ──
    hover_ui: *core.nav_ui.HoverUi,
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
/// stale saves, schedule polls), the LSP + nav/hover/pick ticks, native async
/// completions and REPL streaming, the buffer-activation event, and the
/// menu-overlay edges. Returns whether the view was damaged.
pub fn tickAsync(
    fx: *const FrameCtx,
    abuf: *core.Buffers.Buffer,
    attach: *providers.Attach,
    cmd_ctx: *core.command.Context,
    def_ui: *core.nav_ui.DefinitionUi,
    sym_ui: *core.nav_ui.SymbolsUi,
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
    if (attach.lsp) |l| {
        if (try l.tick(cmd_ctx)) dirty = true;
    }
    if (try def_ui.tick(cmd_ctx)) dirty = true;
    if (try sym_ui.tick(cmd_ctx)) dirty = true;
    if (try fx.hover_ui.tick(cmd_ctx)) dirty = true;
    // Hover dismisses when the cursor leaves the point it was requested at.
    if (fx.hover_ui.active and fx.buffers.active().editor.cursorOffset() != fx.hover_ui.offset) {
        fx.hover_ui.clear();
        dirty = true;
    }
    // Drive any async pick source (completion race-and-refine, file
    // finder, dir browser) — a no-op for a static or source-less
    // pick. Completion now rides this instead of a bespoke tick.
    if (try fx.pick.tick(cmd_ctx)) dirty = true;
    // Deliver native async completions (subprocess/timer output, deferred
    // edits) on the frame thread; a completion repaints.
    if (plugin_loop.tick()) dirty = true;
    // Stream any interactive REPL output into its comint buffer.
    for (fx.plugins.items) |pl| {
        if (core.wasm_host.drainReplSessions(pl)) dirty = true;
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
    if (menu.update(fx.keymap, fx.plugins, frame_start, which_key_now, which_key_delay_ns)) dirty = true;
    return dirty;
}
