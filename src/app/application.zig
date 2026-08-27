//! Platform-neutral application lifecycle.
//!
//! `Application` is the one owner of the input-to-frame sequencing shared by
//! the desktop shell and display-free heads. Platforms translate their events
//! into `input`; render targets implement `buildFrame`/presentation. Neither a
//! platform nor a test harness is allowed to select lifecycle phases.

const std = @import("std");
const application = @import("weft_application");
const core = @import("../core/core.zig");
const region = @import("../gfx/region.zig");
const window_layout = @import("../gfx/window_layout.zig");
const view_mod = @import("../gfx/view.zig");
const frame = @import("frame.zig");
const providers = @import("providers.zig");
const window_cmds = @import("window_cmds.zig");
const session_mod = @import("session.zig");
const dispatch = @import("dispatch.zig");

pub const Application = struct {
    session: *session_mod.Session,
    driver: frame.Driver,
    plugin_loop: *core.async_loop.Loop,
    js_plugins: *std.ArrayList(*core.quickjs.JsPlugin),

    view_dirty: bool = true,
    last_frame_rect: region.Rect = .{},
    flash_gen: u64 = 0,
    flash_start_ns: u64 = 0,
    flash_was_active: bool = false,

    next_backing_poll_ns: u64 = 0,
    last_activate_path: [std.fs.max_path_bytes]u8 = undefined,
    last_activate_len: usize = 0,
    last_active: core.Buffers.Id,
    which_key_delay_ns: u64,
    lifecycle: application.Lifecycle,

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
                .last_frame_rect = &self.last_frame_rect,
                .flash_gen = &self.flash_gen,
                .flash_start_ns = &self.flash_start_ns,
                .flash_was_active = &self.flash_was_active,
                .flash_duration_ns = args.flash_duration_ns,
            },
            .attach_deps = args.attach_deps,
            .window_ctx = args.window_ctx,
            .layout = args.layout,
            .view = args.view,
        };
    }

    /// Inject one canonical key event — the physical keyspec plus whatever
    /// text it committed — through the same dispatch door every platform uses.
    /// The next `advance` consumes the input damage edge.
    pub fn input(self: *Application, spec: []const u8, commit: core.TextCommit) !void {
        try dispatch.dispatchSpec(&self.session.cmd_ctx, spec, commit);
        self.lifecycle.noteInput();
    }

    /// Record input already translated by a platform adapter (pointer input or
    /// a platform head which bracketed dispatch under its own identity).
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

    pub const AdvanceOptions = application.AdvanceOptions;
    pub const AdvanceResult = application.AdvanceResult;

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
        if (try self.services.call(self, active)) damaged = true;
        return damaged;
    }

    pub fn applyWindowIntents(self: *Application) bool {
        return self.driver.applyWindowIntents();
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
        return damaged;
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
