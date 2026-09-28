//! Platform-neutral application lifecycle.
//!
//! `Application` is the one owner of the input-to-frame sequencing shared by
//! the desktop shell and display-free heads. Platforms translate their events
//! into `input`; render targets implement `buildFrame`/presentation. Neither a
//! platform nor a test harness is allowed to select lifecycle phases.

const std = @import("std");
const lifecycle_mod = @import("weft_lifecycle");
const core = @import("weft_core");
const region = @import("weft_gfx").region;
const window_layout = @import("weft_gfx").window_layout;
const view_mod = @import("weft_gfx").view;
const frame = @import("frame.zig");
const providers = @import("providers.zig");
const window_cmds = @import("window_cmds.zig");
const session_mod = @import("session.zig");
const dispatch = @import("dispatch.zig");
const pointer_mod = @import("pointer.zig");
const platform = @import("weft_platform");

pub const Application = struct {
    session: *session_mod.Session,
    driver: frame.Driver,
    plugin_loop: *core.async_loop.Loop,
    js_plugins: *std.ArrayList(*core.quickjs.JsPlugin),

    view_dirty: bool = true,
    /// What the pointer rests on — frame input the pointer keeps and the
    /// frame reads (`pointer.Hover`).
    hover: pointer_mod.Hover = .{},
    last_frame_rect: region.Rect = .{},
    flash_gen: u64 = 0,
    flash_start_ns: u64 = 0,
    flash_was_active: bool = false,
    /// How long a flash shows; the frame re-reads `editor/flash-ms` into it
    /// whenever a new flash starts.
    flash_duration_ns: u64 = 150 * std.time.ns_per_ms,
    /// When the head's message was said, for how long the frame shows it —
    /// noted at each wake's boundary (`observe`), read by the frame.
    echo_timing: frame.EchoTiming = .{},
    /// The same for the system's last notice (`Buffers.notices`).
    notice_timing: frame.EchoTiming = .{},
    /// This wake's clock (`tickAsync`'s `frame_start`), for what `observe`
    /// notes just before the frame.
    wake_ns: u64 = 0,

    next_backing_poll_ns: u64 = 0,
    last_activate_path: [std.fs.max_path_bytes]u8 = undefined,
    last_activate_len: usize = 0,
    last_active: core.Buffers.Id,
    which_key_delay_ns: u64,
    lifecycle: lifecycle_mod.Lifecycle,

    before_async: Hook = .{},
    services: Hook = .{},

    pub const Hook = struct {
        context: ?*anyopaque = null,
        run: ?*const fn (?*anyopaque, *Application, frame.Driver.Prepared) anyerror!bool = null,

        fn call(self: Hook, app: *Application, active: frame.Driver.Prepared) !bool {
            const run = self.run orelse return false;
            return run(self.context, app, active);
        }
    };

    pub const Init = struct {
        gpa: std.mem.Allocator,
        session: *session_mod.Session,
        attach_deps: *providers.AttachDeps,
        plugin_loop: *core.async_loop.Loop,
        js_plugins: *std.ArrayList(*core.quickjs.JsPlugin),
        plugins: *std.ArrayList(*core.wasm_abi.WasmPlugin),
        conn: *?core.session.Conn,
        hub: *?core.hub.Hub,
        collab_session: *?*core.session.Session,
        partial_state: *?core.session.PartialDoc,
        ed0: *core.Editor,
        known_peers: *core.known_peers.KnownPeers,
        noted_host_fp: *?[24]u8,
        window_ctx: *window_cmds.WindowCtx,
        layout: *window_layout.Layout,
        view: *view_mod.View,
        which_key_delay_ns: u64 = 200 * std.time.ns_per_ms,
        flash_duration_ns: u64 = 150 * std.time.ns_per_ms,
        /// The `weft.set` store the frame reads live (flash timing). The
        /// harness passes its own; null means the system's.
        config: ?*const core.kv.Store = null,
        blink_period_ns: u64 = 530 * std.time.ns_per_ms,
        before_async: Hook = .{},
        services: Hook = .{},
    };

    pub fn init(self: *Application, args: Init) void {
        self.* = .{
            .session = args.session,
            .driver = undefined,
            .plugin_loop = args.plugin_loop,
            .js_plugins = args.js_plugins,
            .last_active = args.session.system.buffers.active_id,
            .which_key_delay_ns = args.which_key_delay_ns,
            .lifecycle = .{ .blink_period_ns = args.blink_period_ns },
            .before_async = args.before_async,
            .services = args.services,
            .flash_duration_ns = args.flash_duration_ns,
        };
        self.driver = .{
            .ctx = .{
                .gpa = args.gpa,
                .buffers = &args.session.system.buffers,
                .caps = &args.session.system.caps,
                .keymap = &args.session.system.keymap,
                .ui_mesh = &args.session.system.container,
                .head = &args.session.head,
                .semantic = &args.session.system.semantic,
                .placement = &args.session.system.placement,
                .viewports = &args.session.system.viewports,
                .cursor_cfg = &args.session.cursor_cfg,
                .plugins = args.plugins,
                .conn = args.conn,
                .hub = args.hub,
                .collab_session = args.collab_session,
                .partial_state = args.partial_state,
                .ed0 = args.ed0,
                .known_peers = args.known_peers,
                .noted_host_fp = args.noted_host_fp,
                .view_dirty = &self.view_dirty,
                .hover = &self.hover,
                .last_frame_rect = &self.last_frame_rect,
                .flash_gen = &self.flash_gen,
                .flash_start_ns = &self.flash_start_ns,
                .flash_was_active = &self.flash_was_active,
                .flash_duration_ns = &self.flash_duration_ns,
                .echo_timing = &self.echo_timing,
                .notice_timing = &self.notice_timing,
                .config = args.config orelse &args.session.system.config_kv,
                .cmd_ctx = &args.session.cmd_ctx,
            },
            .attach_deps = args.attach_deps,
            .window_ctx = args.window_ctx,
            .layout = args.layout,
            .view = args.view,
        };
        // The pointer commands' layout door reads through the driver, so a
        // `bindTarget` swap is seen by the next click without re-installing.
        args.session.cmd_ctx.panes = pointer_mod.panesDoor(&self.driver);
    }

    /// Inject one pointer event, its position in framebuffer pixels, through
    /// the same dispatch door keys use (`app/pointer.zig`). The platform
    /// scales from its surface coordinates; the head brackets identity.
    pub fn pointer(self: *Application, ev: platform.PointerEvent) !void {
        if (try pointer_mod.handle(&self.driver, &self.session.cmd_ctx, ev)) self.lifecycle.noteInput();
    }

    /// Inject one canonical key event — the physical keyspec plus whatever
    /// text it committed — through the same dispatch door every platform uses.
    /// The next `advance` consumes the input damage edge.
    pub fn input(self: *Application, spec: []const u8, commit: core.TextCommit) !void {
        try dispatch.dispatchSpec(&self.session.cmd_ctx, spec, commit);
        self.lifecycle.noteInput();
    }

    /// Record input already translated by a platform adapter (a platform
    /// head which bracketed dispatch under its own identity).
    pub fn noteInput(self: *Application) void {
        self.lifecycle.noteInput();
    }

    pub fn damage(self: *Application) void {
        self.view_dirty = true;
    }

    /// Rebind the presentation geometry without changing application state.
    /// Used when a head swaps its render target (for example CPU to offscreen
    /// Vulkan); lifecycle ownership remains here.
    pub fn bindTarget(self: *Application, layout: *window_layout.Layout, view: *view_mod.View) void {
        self.driver.layout = layout;
        self.driver.view = view;
        self.view_dirty = true;
    }

    pub const AdvanceOptions = lifecycle_mod.AdvanceOptions;
    pub const AdvanceResult = lifecycle_mod.AdvanceResult;

    /// Advance one complete application wake through an arbitrary production
    /// renderer. This is the only application-owned route to `buildFrame`:
    /// prepare, platform-neutral input effects, async/plugin/menu work,
    /// services such as collaboration, layout intents, damage, then build.
    pub fn advance(self: *Application, renderer: anytype, opts: AdvanceOptions) !AdvanceResult {
        return self.lifecycle.advance(self, renderer, opts);
    }

    pub fn blinkDeadline(self: *Application) *u64 {
        return &self.lifecycle.blink_next_ns;
    }

    pub fn prepare(self: *Application) !frame.Driver.Prepared {
        return self.driver.prepare();
    }

    pub fn beforeAsync(self: *Application, active: frame.Driver.Prepared) !bool {
        return self.before_async.call(self, active);
    }

    pub fn blinkEnabled(self: *Application) bool {
        return self.session.cursor_cfg.blinkFor(self.session.head.currentMode());
    }

    pub fn tickAsync(self: *Application, active: frame.Driver.Prepared, frame_start: u64) !bool {
        self.wake_ns = frame_start;
        var damaged = try frame.tickAsync(
            &self.driver.ctx,
            active.buffer,
            &self.session.cmd_ctx,
            self.plugin_loop,
            &self.next_backing_poll_ns,
            &self.last_activate_path,
            &self.last_activate_len,
            &self.session.menu_overlay,
            self.which_key_delay_ns,
            frame_start,
        );

        for (self.js_plugins.items) |plugin| if (plugin.tick()) {
            damaged = true;
        };
        // The pointer has rested long enough: the frame that shows the
        // tooltip is due (the loop's `tooltip_delay` timer woke us for it).
        // Its key hint is found now, off the frame path: the frame is handed
        // it (doc/model.md §2.7).
        if (self.hover.ripen(frame_start)) {
            self.hover.settle(&self.session.cmd_ctx, self.driver.view.hoveredCommand());
            damaged = true;
        }
        if (try self.services.call(self, active)) damaged = true;
        return damaged;
    }

    pub fn applyWindowIntents(self: *Application) bool {
        var damaged = self.driver.applyWindowIntents(&self.session.cmd_ctx);
        if (self.notifyContextChanged()) damaged = true;
        if (self.notifySubjectsChanged()) damaged = true;
        // Named signals plugins raised this wake (`wl_signal_emit`), heard at
        // the same boundary and for the same reason: never inside the
        // dispatch or poll that raised them.
        if (core.wasm_host.deliverSignals(self.driver.ctx.gpa, self.driver.ctx.plugins.items)) {
            damaged = true;
            // A provider that accepted a reveal reads there, off the layout
            // pass, and republishes: one more layout pass asks it again, so
            // the reveal lands in this wake rather than at the next input.
            if (self.driver.ctx.viewports.revealsWaiting())
                _ = self.driver.applyWindowIntents(&self.session.cmd_ctx);
        }
        return damaged;
    }

    /// The context-changed event (doc/model.md §2.5): tell every listener —
    /// Zig consumers and plugins exporting `on_context_changed` — which keys
    /// of the head's PRIMARY context moved, so chrome redraws and companions
    /// retarget without polling.
    ///
    /// Here, after the layout phase, because that is where primary focus is
    /// recorded — so a focus move, a mode change, an entry switch, a provider
    /// registration, an availability flip and a `contextSet` made anywhere in
    /// this wake are all visible, and are delivered as ONE event. It runs at
    /// the frame boundary, never inside a dispatch, so a listener re-entering
    /// the doors cannot recurse into the dispatch that caused the change, and
    /// a change a listener makes is the NEXT frame's event. The comparison is
    /// per key, over content (`context.Context.observe`), so a frame where
    /// nothing moved fires nothing and a caret move in text fires nothing.
    ///
    /// The workspace hears the same list: a viewport whose subject or reveal
    /// is bound to a moved key (`weft.present(v, {subject: {context: k}})`)
    /// presents or reveals again, in a second layout pass right here — so a
    /// sidebar following `place` is on the new place in the frame the place
    /// changed, through this one comparison rather than a watcher of its own.
    fn notifyContextChanged(self: *Application) bool {
        const ctx = &self.session.cmd_ctx;
        const context = ctx.context orelse return false;
        const plugins = self.driver.ctx.plugins.items;
        const viewports = self.driver.ctx.viewports;
        // A JS plugin says when it installs a handler (`weft.onContextChanged`,
        // `JsPlugin.hears_context`); one that never does is never asked.
        const js_hears = for (self.js_plugins.items) |jp| {
            if (jp.hears_context) break true;
        } else false;
        const hears = context.listeners.items.len > 0 or viewports.followsAny() or js_hears or for (plugins) |pl| {
            if (core.wasm_host.hearsContext(pl)) break true;
        } else false;
        if (!hears) return false;
        const moved = context.observe(ctx) catch |err| {
            std.log.warn("context: observing the primary context failed: {t}", .{err});
            return false;
        };
        if (!moved) return false;
        var ran = context.notify();
        for (plugins) |pl| {
            if (core.wasm_host.notifyContextChanged(pl)) ran = true;
        }
        for (self.js_plugins.items) |jp| {
            if (jp.notifyContextChanged()) ran = true;
        }
        if (viewports.follow(context.movedKeys())) {
            if (self.driver.applyWindowIntents(ctx)) ran = true;
        }
        return ran;
    }

    /// The subject event (doc/model.md §2.5, `context.Context.watch`): tell
    /// each producer watching a subject that the subject reads differently —
    /// an edit, or a parse that landed with no edit — so a projection of it
    /// (the outline of a document) reads it again, once, bound to the
    /// subject's entry. The same boundary and the same guarantees as the
    /// context event: coalesced over the wake, never inside a dispatch, and
    /// a change the listener makes is the next frame's.
    fn notifySubjectsChanged(self: *Application) bool {
        const ctx = &self.session.cmd_ctx;
        const context = ctx.context orelse return false;
        if (context.watches.items.len == 0) return false;
        const moved = context.observeSubjects(ctx.buffers) catch |err| {
            std.log.warn("context: observing watched subjects failed: {t}", .{err});
            return false;
        };
        if (!moved) return false;
        var ran = false;
        // By index: a listener may watch or unwatch, but `subjects_moved` is
        // replaced only by the next observation.
        var i: usize = 0;
        while (i < context.subjects_moved.items.len) : (i += 1) {
            const m = context.subjects_moved.items[i];
            for (self.driver.ctx.plugins.items) |pl| {
                if (!std.mem.eql(u8, pl.name, m.owner)) continue;
                if (core.wasm_host.notifySubjectChanged(pl, m.entry)) ran = true;
            }
            for (self.js_plugins.items) |jp| {
                if (!std.mem.eql(u8, jp.name, m.owner)) continue;
                if (jp.notifySubjectChanged(m.entry)) ran = true;
            }
        }
        return ran;
    }

    pub fn observe(self: *Application, active: frame.Driver.Prepared) bool {
        var damaged = false;
        if (self.driver.ctx.buffers.active_id != self.last_active) {
            self.last_active = self.driver.ctx.buffers.active_id;
            damaged = true;
        }
        if (active.editor) |ed| {
            if (ed.doc.commitCount() != active.attach.seen_commits) {
                active.attach.seen_commits = ed.doc.commitCount();
                damaged = true;
            }
        }
        // The head's message, timed where it was said: the last thing noted
        // before the frame, so whatever this wake said is in it, and the
        // frame only reads whether it shows.
        // A notice — what no head asked to hear — is timed by the same rule.
        const echo = &self.session.head.echo;
        const notices = &self.driver.ctx.buffers.notices;
        const ms = echoMs(self.driver.ctx.config);
        if (self.echo_timing.note(echo.said, echo.items.len > 0, self.wake_ns, ms)) damaged = true;
        if (self.notice_timing.note(notices.said, notices.len > 0, self.wake_ns, ms)) damaged = true;
        return damaged;
    }

    /// After the frame: ask the plugins what it had no answer to
    /// (doc/model.md §2.7). Never during the build, so an answering provider
    /// can neither tear the frame nor be refused for acting.
    pub fn answerRequests(self: *Application, renderer: anytype) !bool {
        return renderer.answerRequests(&self.driver.ctx);
    }

    pub fn buildPrepared(self: *Application, renderer: anytype, active: frame.Driver.Prepared, opts: anytype) !void {
        try self.driver.buildPrepared(renderer, active, .{
            .frame_start = opts.frame_start,
            .fb = opts.fb,
            .blink_on = opts.blink_on,
            .menu_shown = self.session.menu_overlay.shown,
            .force_rebuild = opts.force_rebuild,
        });
    }
};

/// `editor/echo-ms`: how long a message shows, when a config says.
fn echoMs(config: ?*const core.kv.Store) ?u64 {
    const raw = (config orelse return null).get("editor", "echo-ms") orelse return null;
    return std.fmt.parseInt(u64, core.framed.first(raw) orelse return null, 10) catch null;
}
