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
const core = @import("weft_core");
const region = @import("weft_gfx").region;
const view_mod = @import("weft_gfx").view;
const window_layout = @import("weft_gfx").window_layout;
const cursor_config = @import("cursor_config.zig");
const providers = @import("providers.zig");
const window_cmds = @import("window_cmds.zig");

/// which-key menu-overlay edge detection. Owns the small cluster of state that
/// tracks whether a menu mode is active and whether its hint popup has fired,
/// so `on_menu(open/close)` fire exactly once per enter/leave at the frame
/// boundary (never nested inside another guest call). `.{}` is the idle state.
///
/// PER-HEAD (doc/contextual-workspace-architecture.md §7): a menu popup
/// opening for head A must not suppress/idle-time head B's, so this struct's
/// storage lives beside whichever `core.Head` it tracks
/// (`app.Session.menu_overlay` for the app's one head today; a second head's
/// own instance for a second). It can't live ON `core.Head` itself — `Head`
/// is core and this type is app-layer (it notifies wasm plugins) — so
/// `update` stays a pure-ish function of an explicit `*core.Head` (mirroring
/// the Keymap-tables/Head-cursor split), and the CALLER is responsible for
/// pairing the right overlay instance with the right head, exactly as it
/// already pairs `head`/`keymap`/`plugins`.
pub const MenuOverlay = struct {
    open: bool = false,
    shown: bool = false, // has on_menu(open) fired for the current menu?
    forced: bool = false, // F1 peek at a NON-menu mode's keys (toggled)
    open_ns: u64 = 0, // when the current menu was entered (idle timer)
    last_mode: [64]u8 = undefined,
    last_len: usize = 0,
    /// The F1 "show the hint now" edge, set by the `which-key-now` command
    /// and consumed by `update` below. PER-HEAD, same reasoning as this
    /// struct's own doc: head A pressing F1 must not force head B's popup.
    /// Was a free-floating `main()`-local `bool` threaded through `Session.
    /// init`/`registerCursorCommands`/`tickAsync` (misclassified in the W2a-2
    /// sweep as "stays a main() local" — see `session.zig`'s old module doc);
    /// moved HERE rather than onto `core.Head` because it's read/mutated
    /// exclusively by this app-layer struct (the same "can't live on Head
    /// itself" reasoning above), and `Session.menu_overlay` is already the
    /// established "per-head, beside Head" home this struct's own doc names.
    which_key_now: bool = false,

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
        if (self.which_key_now) self.forced = !self.forced;
        self.which_key_now = false;
        if (changed) self.forced = false;

        // The overlay is active mid-chord (immediately as you type a sequence),
        // for a legacy menu mode (after the idle delay), or while a forced peek is
        // on (immediately, any mode). No hardcoded root menu.
        const active = in_chord or is_menu or self.forced;
        // "Same" must ALSO cover "closed before, closed now" — the ordinary
        // idle state outside any menu. The old `active and self.open and
        // !changed` was false whenever `active` was false REGARDLESS of
        // `self.open`, so this returned `dirty = true` on every single call
        // while idle outside a menu (doc/contextual-workspace-architecture.md §7: found via
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
    /// The `ui/statusline-seg` + `ui/gutter-segment` mesh Container (north-
    /// star-plan §6 W3-1) — `frame_builder.zig` fires it each build. Task
    /// #19's shared-Container fold-in: this is the SAME instance
    /// `session.caps`/`session.actions` bind into (`&session.container`),
    /// not a UI-mesh-only Container — the field keeps this name because
    /// every reader here only ever fires `ui/*` slots on it.
    ui_mesh: *core.container.Container,
    /// This frame's (today, singular) head — current mode, pending chord,
    /// pick session, echo line (doc/contextual-workspace-architecture.md §7).
    head: *core.Head,
    /// System-scoped semantic registries. Views and fields live with the
    /// system; only focus and interaction stacks live on the head above.
    semantic: *core.semantic.Services,
    /// Where an "open a workspace entry" outcome lands (§9.4) and the feed
    /// primary-focus changes are published on (§7). System-scoped, like the
    /// pane tree they act on.
    placement: *core.placement.Policy,
    focus_feed: *core.focus_feed.Feed,
    /// The viewports this system's manifest declares; the layout phase
    /// realizes them into the pane tree.
    viewports: *core.viewport.Registry,

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
    /// Null when the active entry holds no text — the pane presents its view
    /// instead of a document.
    editor: ?*core.Editor,
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

/// App-owned frame driver. Embeddings supply the editor/session borrows once;
/// every backend and capture sink then asks this object to advance/build the
/// complete editor frame. The caller cannot select layers, reconstruct HUD
/// state, attach a partial provider set, or cast `Buffer.frontend` itself.
pub const Driver = struct {
    ctx: FrameCtx,
    attach_deps: *providers.AttachDeps,
    window_ctx: *window_cmds.WindowCtx,
    layout: *window_layout.Layout,
    view: *view_mod.View,

    pub const Prepared = struct {
        buffer: *core.Buffers.Buffer,
        editor: ?*core.Editor,
        attach: *providers.Attach,
    };

    pub const BuildOptions = struct {
        frame_start: u64,
        fb: [2]u32,
        blink_on: bool,
        menu_shown: bool,
        /// A display-free pull sink has no compositor damage loop. Requesting
        /// a frame invalidates the app view as a whole; it still goes through
        /// the same builder and cannot choose what the rebuild contains.
        force_rebuild: bool = false,
    };

    /// Realize any declared-but-unbuilt viewports, then apply the ordinary
    /// frame-loop window intents. `cmd_ctx` is the live dispatch context a
    /// `weft.present` subject opens through — the same `open` every other
    /// locus runs, so composing a workspace grants nothing new.
    ///
    /// Kept public because the desktop loop must do pointer routing and
    /// collab work between prepare and build; pull-based backends simply let
    /// `build` call it.
    pub fn applyWindowIntents(self: *Driver, cmd_ctx: *core.command.Context) bool {
        var changed = window_cmds.materializeViewports(
            cmd_ctx,
            self.layout,
            self.ctx.buffers,
            self.ctx.gpa,
            self.ctx.head,
            self.ctx.keymap,
            self.ctx.viewports,
        );
        if (window_cmds.applyIntents(
            self.window_ctx,
            self.layout,
            self.view,
            self.ctx.buffers,
            self.ctx.gpa,
            self.ctx.head,
            self.ctx.keymap,
            self.ctx.last_frame_rect.*,
            self.ctx.placement,
            self.ctx.focus_feed,
        )) changed = true;
        if (changed) self.ctx.view_dirty.* = true;
        return changed;
    }

    /// Resolve and attach the complete visible editor set. This is app policy,
    /// shared by the desktop and memory backends; a sink never inventories
    /// providers or interprets the opaque frontend attachment.
    pub fn prepare(self: *Driver) !Prepared {
        const active = self.ctx.buffers.active();
        try providers.attachProviders(self.attach_deps, active);
        const Visible = struct {
            deps: *providers.AttachDeps,
            buffers: *core.Buffers,
            fn visit(state: *@This(), pane: *window_layout.Pane) void {
                const buffer = state.buffers.get(pane.buffer_id) orelse return;
                providers.attachProviders(state.deps, buffer) catch {};
            }
        };
        var visible = Visible{ .deps = self.attach_deps, .buffers = self.ctx.buffers };
        self.layout.eachPane(&visible, Visible.visit);
        const frontend = active.frontend orelse return error.ProviderAttachmentMissing;
        return .{
            .buffer = active,
            .editor = active.textEditor(),
            .attach = @ptrCast(@alignCast(frontend)),
        };
    }

    /// Build the scene resolved by the application lifecycle. Public only for
    /// `app/application.zig`: heads and harnesses advance `Application` rather
    /// than selecting prepare/async/layout phases themselves.
    pub fn buildPrepared(self: *Driver, renderer: anytype, active: Prepared, opts: BuildOptions) !void {
        if (opts.force_rebuild) self.ctx.view_dirty.* = true;
        try renderer.buildFrame(&self.ctx, .{
            .editor = active.editor,
            .abuf = active.buffer,
            .attach = active.attach,
            .frame_start = opts.frame_start,
            .fb = opts.fb,
            .blink_on = opts.blink_on,
            .menu_shown = opts.menu_shown,
        });
    }
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
            const ed = b.textEditor() orelse continue;
            if (ed.pollSave(gpa) and b == abuf) dirty = true;
            const was_stale = ed.save_state == .stale;
            if (try ed.pollBacking(gpa) and b == abuf) dirty = true;
            if (was_stale and ed.save_state == .idle) try ed.requestSave(gpa);
            if (poll_due or ed.save_state == .stale) try ed.requestBackingPoll(gpa);
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
        const cur_path = if (fx.buffers.active().textEditor()) |ed| ed.backingPath() orelse "" else "";
        if (!std.mem.eql(u8, cur_path, last_activate_path[0..last_activate_len.*])) {
            for (fx.plugins.items) |pl| core.wasm_host.notifyActivate(pl, cur_path);
            const n = @min(cur_path.len, last_activate_path.len);
            @memcpy(last_activate_path[0..n], cur_path[0..n]);
            last_activate_len.* = n;
        }
    }
    // Menu overlay edges — fired at the frame boundary (top-level, so a
    // menu-owner guest can't re-enter its store).
    if (menu.update(fx.head, fx.keymap, fx.plugins, frame_start, which_key_delay_ns)) dirty = true;
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
    const delay: u64 = 200;

    // Normal: nothing open.
    try head.setModeRaw(gpa, "normal");
    _ = mo.update(&head, &km, &plugins, 0, delay);
    try t.expect(!mo.open and !mo.shown);

    // Enter leader at t=100: open, not yet shown (0 < delay).
    try head.setModeRaw(gpa, "leader");
    _ = mo.update(&head, &km, &plugins, 100, delay);
    try t.expect(mo.open and !mo.shown);

    // t=350: held past the delay → the popup appears.
    _ = mo.update(&head, &km, &plugins, 350, delay);
    try t.expect(mo.shown);

    // Drill into leader-file at t=360: the idle timer is continuous (measured
    // from the first menu entry, t=100), so 360−100 ≥ delay → the submenu hint
    // shows THIS frame, no re-delay. This is the bug fix.
    try head.setModeRaw(gpa, "leader-file");
    _ = mo.update(&head, &km, &plugins, 360, delay);
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
    const delay: u64 = 200;

    // Fresh entry from normal: the timer starts now — the first popup waits.
    try head.setModeRaw(gpa, "normal");
    _ = mo.update(&head, &km, &plugins, 1000, delay);
    try head.setModeRaw(gpa, "leader-file");
    _ = mo.update(&head, &km, &plugins, 1000, delay);
    try t.expect(mo.open and !mo.shown);
    _ = mo.update(&head, &km, &plugins, 1150, delay); // 150 < delay
    try t.expect(!mo.shown);
    _ = mo.update(&head, &km, &plugins, 1201, delay); // 201 ≥ delay
    try t.expect(mo.shown);

    // Leaving menus entirely closes the overlay; a later re-entry starts fresh.
    try head.setModeRaw(gpa, "normal");
    _ = mo.update(&head, &km, &plugins, 1300, delay);
    try t.expect(!mo.open and !mo.shown);
    try head.setModeRaw(gpa, "leader");
    _ = mo.update(&head, &km, &plugins, 1300, delay);
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

    var mo: MenuOverlay = .{ .which_key_now = true }; // F1 pressed
    try head.setModeRaw(gpa, "leader");
    _ = mo.update(&head, &km, &plugins, 5, 10_000);
    try t.expect(mo.shown); // shown despite 5 ≪ delay
    try t.expect(!mo.which_key_now); // the flag was consumed
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
    // you're at (the git-style "wrong menu" jank).
    try head.setModeRaw(gpa, "normal");

    var mo: MenuOverlay = .{ .which_key_now = true }; // F1
    _ = mo.update(&head, &km, &plugins, 5, 10_000);
    try t.expect(mo.forced);
    try t.expect(mo.shown); // shown immediately for the current mode
    try t.expectEqualStrings("normal", head.currentMode()); // did NOT jump into "leader"

    // A second F1 dismisses the peek.
    mo.which_key_now = true;
    _ = mo.update(&head, &km, &plugins, 20, 10_000);
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
    try head.setModeRaw(gpa, "normal");

    var mo: MenuOverlay = .{ .which_key_now = true }; // F1 peeks normal
    _ = mo.update(&head, &km, &plugins, 5, 10_000);
    try t.expect(mo.forced and mo.shown);

    // Switch to another non-menu mode: the peek ends (no lingering overlay).
    try head.setModeRaw(gpa, "insert");
    _ = mo.update(&head, &km, &plugins, 20, 10_000);
    try t.expect(!mo.forced);
    try t.expect(!mo.open);
}

test "menu overlay: idle outside any menu is a stable state — no dirty every call" {
    // doc/contextual-workspace-architecture.md §7: this is the exact bug the idle-wakeup
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
    try head.setModeRaw(gpa, "normal");

    var mo: MenuOverlay = .{};
    const dirty1 = mo.update(&head, &km, &plugins, 0, 200);
    try t.expect(!dirty1); // both-closed IS the "same" state from `.{}`'s initial idle

    var i: u64 = 1;
    while (i < 20) : (i += 1) {
        const dirty = mo.update(&head, &km, &plugins, i * 100, 200);
        try t.expect(!dirty);
    }

    // A real transition (entering a menu) still reports dirty, proving the
    // fix didn't just make everything report `false`.
    try head.setModeRaw(gpa, "leader");
    try t.expect(mo.update(&head, &km, &plugins, 2100, 200));
}
