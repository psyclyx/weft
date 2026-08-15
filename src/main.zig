//! scion — the assembled editor: a Wayland window presenting a
//! `core.Editor` through snail's analytic glyph pipeline, all behavior
//! routed key → keymap → command ABI (built-ins and config/plugin
//! commands through the same door). The frame loop's only wait is the
//! swapchain (FIFO vsync); the input→commit→render path is bracketed by
//! the hot-section fence; frame + input latency percentiles log
//! continuously.
//!
//!   scion [file] [--font path.ttf] [--em N] [--config init.fnl]

const std = @import("std");
const wayland = @import("platform/wayland.zig");
const Context = @import("gfx/context.zig").Context;
const core = @import("core/core.zig");
const view_mod = @import("gfx/view.zig");
const stats_mod = @import("gfx/stats.zig");
const snail = @import("snail");
const snail_vk = @import("gfx/snail_vk/root.zig");
const vk = @import("vk.zig").c;

const embedded_font = @embedFile("font_mono");

const headless = @import("headless.zig");

const Args = struct {
    file: ?[]const u8 = null,
    font: ?[]const u8 = null,
    config: ?[]const u8 = null,
    em: f32 = 15,
    listen: ?u16 = null,
    connect: ?[]const u8 = null, // host:port
    token: []const u8 = "scion-dev",
    user: []const u8 = "user",
    headless: bool = false,
    lsp_cmd: ?[]const u8 = null, // --headless host-side server
};

fn parseArgs(process_args: std.process.Args) Args {
    var out: Args = .{};
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.skip(); // argv0
    while (it.next()) |a| {
        if (std.mem.eql(u8, a, "--font")) {
            out.font = it.next() orelse out.font;
        } else if (std.mem.eql(u8, a, "--config")) {
            out.config = it.next() orelse out.config;
        } else if (std.mem.eql(u8, a, "--em")) {
            if (it.next()) |v| out.em = std.fmt.parseFloat(f32, v) catch out.em;
        } else if (std.mem.eql(u8, a, "--listen")) {
            if (it.next()) |v| out.listen = std.fmt.parseInt(u16, v, 10) catch null;
        } else if (std.mem.eql(u8, a, "--connect")) {
            out.connect = it.next() orelse out.connect;
        } else if (std.mem.eql(u8, a, "--token")) {
            out.token = it.next() orelse out.token;
        } else if (std.mem.eql(u8, a, "--user")) {
            out.user = it.next() orelse out.user;
        } else if (std.mem.eql(u8, a, "--headless")) {
            out.headless = true;
        } else if (std.mem.eql(u8, a, "--lsp")) {
            out.lsp_cmd = it.next() orelse out.lsp_cmd;
        } else {
            out.file = a;
        }
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    // Debug builds get leak checking; release builds get the lean
    // allocator (DebugAllocator's bookkeeping costs real RSS).
    const debug_alloc = @import("builtin").mode == .Debug;
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (debug_alloc) {
        _ = gpa_state.deinit();
    };
    const gpa = if (debug_alloc) gpa_state.allocator() else std.heap.c_allocator;

    // POSIX argv is static; the parsed slices stay valid for the run.
    const args = parseArgs(init.minimal.args);

    // Persistent host: same binary, window half never initialized.
    if (args.headless) {
        return headless.run(gpa, .{
            .listen = args.listen orelse 7777,
            .token = args.token,
            .lsp_cmd = args.lsp_cmd,
            .file = args.file,
        }, init.minimal.environ);
    }

    // ── Core ──
    // Registered before everything so it runs LAST: shells must outlive
    // the buffers whose backings (and in-flight save workers) use them.
    var attach_deps_ptr: ?*AttachDeps = null;
    defer if (attach_deps_ptr) |d| d.deinitShells();
    var pool = try core.task.Pool.init(gpa, .{});
    defer pool.deinit();
    var buffers = try core.Buffers.init(gpa, pool, args.user);
    defer buffers.deinit(gpa);
    if (args.file) |path| {
        const b0 = buffers.active();
        gpa.free(b0.name);
        b0.name = try gpa.dupe(u8, std.fs.path.basename(path));
        if (args.connect != null) {
            // Remote document: the path is a NAME (language routing,
            // status line); content arrives over the wire from the
            // host. Nothing is read locally.
            try b0.editor.adoptPath(gpa, path);
        } else b0.editor.openFile(gpa, path) catch |err| switch (err) {
            error.FileNotFound => {
                // New file: adopt the path, save creates it.
                try b0.editor.adoptPath(gpa, path);
            },
            else => |e| return e,
        };
    }
    // Stable: buffer 0 outlives the run; wire v1 collab binds to it.
    const ed0 = &buffers.active().editor;

    // ── Command surface + config plugin ──
    var commands: core.command.Commands = .empty;
    defer commands.deinit(gpa);
    var keymap: core.Keymap = .empty;
    defer keymap.deinit(gpa);
    var pick_state: core.Pick = .empty;
    defer pick_state.deinit(gpa);
    var caps = core.Caps.init(gpa, core.task.nowNs);
    defer caps.deinit();
    var quit = false;
    var cmd_ctx: core.command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .pick = &pick_state,
        .caps = &caps,
        .quit = &quit,
    };
    try core.builtins.install(gpa, &commands, &keymap);
    // Capability consumers — written against capability names only.
    var completion_ui: core.complete_ui.CompletionUi = .empty;
    _ = try commands.bind(gpa, "complete", completion_ui.commandSpec());
    var def_ui: core.nav_ui.DefinitionUi = .empty;
    _ = try commands.bind(gpa, "goto-definition", def_ui.commandSpec());
    var sym_ui: core.nav_ui.SymbolsUi = .empty;
    defer sym_ui.deinit(gpa);
    _ = try commands.bind(gpa, "symbols", sym_ui.commandSpec());

    // Grammars are data: builtins seeded, config extends via command.
    var grammars = try core.syntax.Runtime.initBuiltins(gpa);
    defer grammars.deinit(gpa);
    _ = try commands.bind(gpa, "grammar-add", grammarAddCommand(&grammars));

    // Language servers are data: config registers (extension, command)
    // pairs; nothing here names a server.
    var lsp_servers: LspServers = .empty;
    defer lsp_servers.deinit(gpa);
    _ = try commands.bind(gpa, "lsp-add", lspAddCommand(&lsp_servers));

    // Config runs before language attach so `grammar-add`/`lsp-add`
    // apply to the file being opened.
    const config_plugin = try core.Plugin.create(gpa, &cmd_ctx, "config");
    defer config_plugin.destroy();
    _ = try commands.bind(gpa, "eval", core.plugin.evalCommand(config_plugin));
    try loadConfig(gpa, config_plugin, args.config, init.minimal.environ);

    // ── Per-buffer providers (syntax + LSP hang off Buffer.frontend) ──
    var attach_deps: AttachDeps = .{
        .gpa = gpa,
        .grammars = &grammars,
        .lsp_servers = &lsp_servers,
        .caps = &caps,
        .environ = init.minimal.environ,
        // Placement routing: for a remote-hosted document the server
        // runs on the host peer and diagnostics arrive as the imported
        // host feed — no local LSP.
        .local_lsp = args.connect == null,
    };
    attach_deps_ptr = &attach_deps;
    defer {
        var det_it = buffers.iterator();
        while (det_it.next()) |b| detachProviders(&attach_deps, b);
    }
    try attachProviders(&attach_deps, buffers.active());
    // The graphical shell's open/close know about providers and remote
    // shells; they shadow the core versions (registry last-wins).
    _ = try commands.bind(gpa, "open", .{
        .name = "open",
        .summary = "Open a local file or host:path over a shell, with providers.",
        .args = &.{.{ .name = "path", .type = .string }},
        .handler = openBufferHandler,
        .data = &attach_deps,
    });
    _ = try commands.bind(gpa, "buffer-close", .{
        .name = "buffer-close",
        .summary = "Close the active buffer (refuses when dirty), detaching providers.",
        .args = &.{},
        .handler = closeBufferHandler,
        .data = &attach_deps,
    });

    // ── Connection (wire v1.1: N shared buffers over one session) ──
    var fd_link: core.session.FdLink = undefined;
    var collab_session: ?*core.session.Session = null;
    defer if (collab_session) |s| s.destroy();
    var conn: ?core.session.Conn = null;
    defer if (conn) |*c| c.deinit();
    if (args.listen != null or args.connect != null) {
        const fd = if (args.listen) |port| blk: {
            std.log.info("collab: listening on port {d} — waiting for a peer", .{port});
            break :blk try core.session.tcpListen(port);
        } else try core.session.tcpConnect(args.connect.?);
        fd_link = .{ .fd = fd };
        const role: core.secure.Role = if (args.listen != null) .server else .client;
        collab_session = try core.session.Session.create(gpa, fd_link.link(), role, args.token);
        conn = try core.session.Conn.init(gpa, collab_session.?, args.user, role);
        const col = try conn.?.bindPrimary(&ed0.doc, 0);
        col.presence_layer = try caps.layers.claim(gpa, &ed0.doc, "presence", .replicated, "collab");
        if (args.connect != null) {
            // Host-scoped feeds (diagnostics) arrive over the wire.
            col.import_diag_layer = try caps.layers.claim(gpa, &ed0.doc, "diagnostics", .host, "remote-host");
        }
    }
    var share_ctx: ShareCtx = .{ .conn = &conn, .caps = &caps };
    attach_deps.share = &share_ctx;
    _ = try commands.bind(gpa, "share", .{
        .name = "share",
        .summary = "Share the active buffer over the connection.",
        .args = &.{},
        .handler = shareHandler,
        .data = &share_ctx,
    });
    _ = try commands.bind(gpa, "open-shared", .{
        .name = "open-shared",
        .summary = "Pick one of the peer's shared buffers and open it.",
        .args = &.{},
        .handler = openSharedHandler,
        .data = &share_ctx,
    });

    // ── Window + Vulkan ──
    const window = try wayland.Window.init(1280, 800, "scion", "dev.psyclyx.scion");
    defer window.deinit();
    var fb = window.framebufferSize();
    const ctx = try Context.init(gpa, .{
        .display = window.display,
        .surface = window.surface,
    }, fb[0], fb[1], "scion");
    defer ctx.deinit();

    const vctx: snail_vk.VulkanContext = .{
        .physical_device = ctx.physical_device,
        .device = ctx.device,
        .graphics_queue = ctx.queue,
        .queue_family_index = ctx.queue_family,
        .render_pass = ctx.render_pass,
    };

    // ── Snail render path ──
    const font_bytes: []const u8 = if (args.font) |p| try core.file.readAlloc(gpa, p) else embedded_font;
    defer if (args.font != null) gpa.free(@constCast(font_bytes));
    var view = try view_mod.View.init(gpa, font_bytes, args.em);
    defer view.deinit();

    var layout: snail_vk.VulkanResourceLayout = undefined;
    try layout.init(vctx);
    defer layout.deinit();
    const resources = snail_vk.cacheResourceContext(vctx, &layout);
    var cache = try snail_vk.VulkanDeviceAtlas.init(gpa, view.pool, resources, .{});
    defer cache.deinit();
    var renderer = try snail_vk.Renderer.init(vctx, layout.desc_set_layout, 2 << 20, @import("gfx/context.zig").max_frames_in_flight, .disabled);
    defer renderer.deinit();

    // Initial (empty) upload establishes the live binding.
    var binding: [1]snail.render.records.Binding = undefined;
    try snail_vk.uploadAndWait(gpa, vctx, resources, ctx.command_pool, &cache, &.{&view.atlas}, &binding);

    var stats: stats_mod.Stats = .{};
    var built: ?view_mod.Built = null;
    defer if (built) |*b| b.deinit(gpa);
    var instances: std.ArrayList(snail.render.records.Instance) = .empty;
    defer instances.deinit(gpa);
    var batches: std.ArrayList(snail.render.records.DrawBatch) = .empty;
    defer batches.deinit(gpa);
    var view_dirty = true;
    var last_liveness: core.session.Liveness = .connecting;
    var reconnect: ?core.task.Handle(anyerror!i32) = null;
    defer if (reconnect) |*h| h.detach();
    var next_reconnect_ns: u64 = 0;
    var next_backing_poll_ns: u64 = 0;
    var last_active: core.Buffers.Id = buffers.active_id;

    std.log.info("scion: rendering — {d} bytes open, em {d}", .{ ed0.text().byteLen(), args.em });

    while (!window.shouldClose() and !quit) {
        const frame_start = stats_mod.nowNs();
        window.pumpEvents();

        if (window.consumeResized() or ctx.swapchain_stale) {
            fb = window.framebufferSize();
            try ctx.recreateSwapchain(fb[0], fb[1]);
            view_dirty = true;
        }

        // ── Input → commit (hot section: no blocking API compiles in) ──
        var had_input = false;
        core.task.beginHotSection();
        while (window.nextKeyEvent()) |ev| {
            if (!ev.pressed) continue;
            had_input = true;
            try dispatchKey(&cmd_ctx, &view, ev, fb[1]);
        }
        core.task.endHotSection();
        if (window.shouldClose()) break;

        // Commands may have created/switched buffers; lazily attach
        // providers and damage the view on focus change.
        const abuf = buffers.active();
        try attachProviders(&attach_deps, abuf);
        const editor = &abuf.editor;
        const attach: *Attach = @ptrCast(@alignCast(abuf.frontend.?));
        if (buffers.active_id != last_active) {
            last_active = buffers.active_id;
            view_dirty = true;
        }

        // Backing maintenance for every buffer: fold saves, merge
        // external writes, retry stale saves, schedule polls.
        {
            const poll_due = stats_mod.nowNs() >= next_backing_poll_ns;
            if (poll_due) next_backing_poll_ns = stats_mod.nowNs() + 2 * std.time.ns_per_s;
            var mit = buffers.iterator();
            while (mit.next()) |b| {
                if (b.editor.pollSave(gpa) and b == abuf) view_dirty = true;
                const was_stale = b.editor.save_state == .stale;
                if (try b.editor.pollBacking(gpa) and b == abuf) view_dirty = true;
                if (was_stale and b.editor.save_state == .idle) try b.editor.requestSave(gpa);
                if (poll_due or b.editor.save_state == .stale) try b.editor.requestBackingPoll(gpa);
            }
        }
        if (attach.lsp) |l| {
            if (try l.tick(&cmd_ctx)) view_dirty = true;
        }
        if (try completion_ui.tick(&cmd_ctx)) view_dirty = true;
        if (try def_ui.tick(&cmd_ctx)) view_dirty = true;
        if (try sym_ui.tick(&cmd_ctx)) view_dirty = true;
        if (conn) |*c| {
            // Each bound buffer publishes its own cursor as presence.
            for (c.collabs.items) |col| {
                if (buffers.get(@intCast(col.tag))) |b| {
                    col.cursor_offset = b.editor.cursorOffset();
                }
            }
            if (try c.tick()) view_dirty = true;
            const live = collab_session.?.liveness();
            if (live != last_liveness) {
                last_liveness = live;
                view_dirty = true;
            }
            // A flapping link reconnects itself (client role): pooled
            // connect attempts every 3s, rebind on success — the resync
            // is the ordinary frontier exchange (+ share re-announce).
            if (live == .offline and args.connect != null) {
                if (reconnect) |*h| {
                    if (h.poll()) |res| {
                        reconnect = null;
                        if (res) |fd| {
                            collab_session.?.destroy();
                            fd_link = .{ .fd = fd };
                            collab_session = try core.session.Session.create(gpa, fd_link.link(), .client, args.token);
                            try c.rebind(collab_session.?);
                            std.log.info("collab: reconnected", .{});
                            view_dirty = true;
                        } else |_| {
                            next_reconnect_ns = stats_mod.nowNs() + 3 * std.time.ns_per_s;
                        }
                    }
                } else if (stats_mod.nowNs() >= next_reconnect_ns) {
                    next_reconnect_ns = stats_mod.nowNs() + 3 * std.time.ns_per_s;
                    reconnect = try pool.spawn(reconnectTask, .{args.connect.?});
                }
            }
        }
        if (editor.doc.commitCount() != attach.seen_commits) {
            attach.seen_commits = editor.doc.commitCount();
            view_dirty = true;
        }
        if (had_input) view_dirty = true; // cursor moves damage the view

        // ── Rebuild + upload on damage ──
        if (view_dirty) {
            view_dirty = false;
            const projection = snail.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1);
            const world_to_pixel = snail.mvpToScenePixel(projection, @floatFromInt(fb[0]), @floatFromInt(fb[1])) orelse unreachable;

            if (attach.syntax) |syn| {
                _ = try syn.sync(gpa, &editor.doc);
                if (caps.layers.find(&editor.doc, "highlight")) |hl| {
                    // Whole doc when small; a generous window around the
                    // viewport otherwise (republshed every damage frame).
                    const rope = editor.text();
                    const total = rope.byteLen();
                    const range = stemma_range: {
                        if (total <= 256 * 1024) break :stemma_range @import("stemma").Range{ .start = 0, .end = total };
                        const rows = rope.lineCount();
                        const first = view.top_row -| 100;
                        const last = @min(rows - 1, view.top_row + 200);
                        break :stemma_range @import("stemma").Range{ .start = rope.lineRange(first).start, .end = rope.lineRange(last).end };
                    };
                    try syn.publishHighlight(gpa, &editor.doc, hl, range);
                }
            }
            const hud: view_mod.Hud = .{
                .mode = keymap.currentMode(),
                .file = editor.backingPath() orelse abuf.name,
                .dirty = editor.isDirty(gpa) catch true,
                .save_failed = editor.save_state == .failed,
                .pick = if (pick_state.active) &pick_state else null,
                .highlight_layer = caps.layers.find(&editor.doc, "highlight"),
                .diag_layer = caps.layers.find(&editor.doc, "diagnostics"),
                .presence_layer = caps.layers.find(&editor.doc, "presence"),
                .link = if (collab_session) |s| @tagName(s.liveness()) else null,
                .cursor_diag = blk: {
                    const dl = caps.layers.find(&editor.doc, "diagnostics") orelse break :blk null;
                    const cur = editor.cursorOffset();
                    for (0..dl.spanCount()) |i| {
                        const d = dl.resolvedSpan(i);
                        if (cur >= d.start and cur <= d.end) break :blk d.message;
                    }
                    break :blk null;
                },
            };
            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const b = try view.build(arena_state.allocator(), editor, hud, fb[0], fb[1], world_to_pixel);
            if (built) |*old| old.deinit(gpa);
            built = b;
            if (b.records_added != 0) {
                binding[0] = try snail_vk.uploadDeltaAndWait(gpa, vctx, resources, ctx.command_pool, &cache, binding[0], &view.atlas);
            }

            // Emit the instance/batch stream for the new picture.
            instances.clearRetainingCapacity();
            batches.clearRetainingCapacity();
            try instances.resize(gpa, b.shapes.len);
            try batches.resize(gpa, b.shapes.len);
            var ilen: usize = 0;
            var blen: usize = 0;
            _ = try snail.emit.emit(
                instances.items,
                batches.items,
                &ilen,
                &blen,
                binding[0],
                &view.atlas,
                b.shapes,
                .identity,
                .{ 1, 1, 1, 1 },
            );
            instances.items.len = ilen;
            batches.items.len = blen;
        }

        // ── Draw ──
        const cmd = try ctx.beginFrame() orelse continue;
        ctx.beginRenderPass(cmd, view.theme.background);
        renderer.beginFrame(ctx.current_frame);
        const draw_state: snail.render.target.DrawState = .{
            .mvp = snail.Mat4.ortho(0, @floatFromInt(fb[0]), @floatFromInt(fb[1]), 0, -1, 1),
            .surface = .{
                .pixel_width = fb[0],
                .pixel_height = fb[1],
                .encoding = if (ctx.surfaceEncodesSrgb()) .srgb else .linear,
            },
        };
        try renderer.render(cmd, &cache, draw_state, instances.items, batches.items);
        try ctx.endFrame();

        const frame_ns = stats_mod.nowNs() - frame_start;
        stats.recordFrame(frame_ns);
        if (had_input) stats.recordInput(frame_ns);
        _ = stats.maybeLog(600);
    }
    ctx.waitIdle();
}

/// One key event → keymap lookup → command. Runs inside the hot
/// section: dispatch is a table lookup plus the command itself,
/// allocation-only. Unbound printable input becomes `insert-text` —
/// itself a command; there is no editing path around the ABI.
fn dispatchKey(ctx: *core.command.Context, view: *view_mod.View, ev: wayland.KeyEvent, fb_h: u32) !void {
    const c = wayland.c;
    // Paging needs viewport geometry the core doesn't know; view-aware
    // dispatch stays here.
    if (ev.keysym == c.XKB_KEY_Page_Up or ev.keysym == c.XKB_KEY_Page_Down) {
        const rows = view.visibleRows(fb_h);
        for (0..rows) |_| {
            if (ev.keysym == c.XKB_KEY_Page_Up) ctx.editor().moveUp() else ctx.editor().moveDown();
        }
        return;
    }

    var name_buf: [64]u8 = undefined;
    const n = c.xkb_keysym_get_name(ev.keysym, &name_buf, name_buf.len);
    if (n > 0) {
        var spec_buf: [80]u8 = undefined;
        const spec = core.Keymap.keyspec(&spec_buf, ev.mods.ctrl, ev.mods.alt, name_buf[0..@intCast(n)]);
        if (ctx.keymap.lookup(spec)) |cmd_name| {
            _ = core.command.run(ctx.commands, ctx, cmd_name, &.{}) catch |err| {
                std.log.warn("command {s} failed: {t}", .{ cmd_name, err });
            };
            return;
        }
    }
    if (ev.mods.ctrl or ev.mods.alt) return;
    const text = ev.text();
    if (text.len > 0 and !(text.len == 1 and text[0] < 0x20)) {
        // Unbound printable input runs the mode's text command (the
        // modal posture: normal mode has none and swallows it).
        const tc = ctx.keymap.textCommand() orelse return;
        _ = core.command.run(ctx.commands, ctx, tc, &.{.{ .string = text }}) catch |err| {
            std.log.warn("{s} failed: {t}", .{ tc, err });
        };
    }
}

/// Resolve and evaluate the user config: `--config` wins, else
/// $XDG_CONFIG_HOME/scion/init.fnl, else ~/.config/scion/init.fnl.
/// Read-only; a missing default config means built-in defaults.
fn loadConfig(gpa: std.mem.Allocator, plugin: *core.Plugin, override: ?[]const u8, environ: std.process.Environ) !void {
    var buf: [512]u8 = undefined;
    const path = override orelse blk: {
        if (environ.getPosix("XDG_CONFIG_HOME")) |x| {
            break :blk std.fmt.bufPrint(&buf, "{s}/scion/init.fnl", .{x}) catch return;
        }
        if (environ.getPosix("HOME")) |h| {
            break :blk std.fmt.bufPrint(&buf, "{s}/.config/scion/init.fnl", .{h}) catch return;
        }
        return;
    };
    const src = core.file.readAlloc(gpa, path) catch |err| switch (err) {
        error.FileNotFound => {
            if (override != null) std.log.warn("config not found: {s}", .{path});
            return;
        },
        else => |e| return e,
    };
    defer gpa.free(src);
    const out = plugin.eval(gpa, src, "init.fnl") catch {
        std.log.err("config failed (see above): {s}", .{path});
        return;
    };
    gpa.free(out);
    std.log.info("config loaded: {s}", .{path});
}

/// `grammar-add <ext> <package-dir> <symbol>` — grammars as data.
fn grammarAddCommand(runtime: *core.syntax.Runtime) core.command.Command {
    return .{
        .name = "grammar-add",
        .summary = "Register a tree-sitter grammar package for an extension.",
        .args = &.{
            .{ .name = "ext", .type = .string },
            .{ .name = "dir", .type = .string },
            .{ .name = "symbol", .type = .string },
        },
        .handler = grammarAddHandler,
        .data = runtime,
    };
}

fn grammarAddHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const runtime: *core.syntax.Runtime = @ptrCast(@alignCast(data.?));
    if (args.len != 3) return error.ArityMismatch;
    for (args) |a| {
        if (a != .string) return error.TypeMismatch;
    }
    try runtime.add(ctx.gpa, args[0].string, args[1].string, args[2].string);
    return .nil;
}

/// Language-server registrations: (extension → argv), config-supplied.
const LspServers = struct {
    const Entry = struct {
        ext: []u8,
        argv: [][]u8,
        exts: [1][]const u8,

        fn extSlice(self: *Entry) []const []const u8 {
            self.exts[0] = self.ext;
            return &self.exts;
        }
    };

    list: std.ArrayList(*Entry) = .empty,

    const empty: LspServers = .{};

    fn deinit(self: *LspServers, gpa: std.mem.Allocator) void {
        for (self.list.items) |e| {
            gpa.free(e.ext);
            for (e.argv) |a| gpa.free(a);
            gpa.free(e.argv);
            gpa.destroy(e);
        }
        self.list.deinit(gpa);
    }

    fn match(self: *LspServers, path: []const u8) ?*Entry {
        var i = self.list.items.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.endsWith(u8, path, self.list.items[i].ext)) return self.list.items[i];
        }
        return null;
    }
};

fn lspAddCommand(servers: *LspServers) core.command.Command {
    return .{
        .name = "lsp-add",
        .summary = "Register a language server command for an extension.",
        .args = &.{
            .{ .name = "ext", .type = .string },
            .{ .name = "cmd", .type = .string },
        },
        .handler = lspAddHandler,
        .data = servers,
    };
}

fn lspAddHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const servers: *LspServers = @ptrCast(@alignCast(data.?));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.TypeMismatch;
    const gpa = ctx.gpa;
    var argv: std.ArrayList([]u8) = .empty;
    errdefer {
        for (argv.items) |a| gpa.free(a);
        argv.deinit(gpa);
    }
    var it = std.mem.tokenizeScalar(u8, args[1].string, ' ');
    while (it.next()) |word| try argv.append(gpa, try gpa.dupe(u8, word));
    if (argv.items.len == 0) return error.TypeMismatch;
    const e = try gpa.create(LspServers.Entry);
    errdefer gpa.destroy(e);
    e.* = .{
        .ext = try gpa.dupe(u8, args[0].string),
        .argv = try argv.toOwnedSlice(gpa),
        .exts = undefined,
    };
    try servers.list.append(gpa, e);
    return .nil;
}

fn reconnectTask(hostport: []const u8) anyerror!i32 {
    return core.session.tcpConnect(hostport);
}

// ── Per-buffer provider attachments ─────────────────────────────────
// Syntax and LSP are per-buffer instances hanging off Buffer.frontend;
// their capability providers decline foreign documents, so per-buffer
// registrations race correctly. Highlight/diagnostic layers key by
// (doc, name) in the shared store.

const Attach = struct {
    syntax: ?*core.syntax.Syntax = null,
    lsp: ?*core.lsp.Lsp = null,
    seen_commits: usize = 0,
};

const AttachDeps = struct {
    gpa: std.mem.Allocator,
    grammars: *core.syntax.Runtime,
    lsp_servers: *LspServers,
    caps: *core.Caps,
    environ: std.process.Environ,
    local_lsp: bool,
    /// Set once the connection exists: buffer close unbinds shares
    /// before the document dies.
    share: ?*ShareCtx = null,
    /// Persistent shells per remote host (ssh spawner), created on
    /// first `open host:path` and reused for every buffer on that host.
    shells: std.StringHashMapUnmanaged(*core.ShellFs) = .empty,

    fn deinitShells(self: *AttachDeps) void {
        var it = self.shells.iterator();
        while (it.next()) |e| {
            e.value_ptr.*.deinit();
            self.gpa.destroy(e.value_ptr.*);
            self.gpa.free(e.key_ptr.*);
        }
        self.shells.deinit(self.gpa);
    }

    fn shellFor(self: *AttachDeps, host: []const u8) !*core.ShellFs {
        if (self.shells.get(host)) |fs| return fs;
        const fs = try self.gpa.create(core.ShellFs);
        errdefer self.gpa.destroy(fs);
        fs.* = try core.ShellFs.spawn(self.gpa, &.{ "ssh", host, "sh" }, self.environ);
        errdefer fs.deinit();
        try self.shells.put(self.gpa, try self.gpa.dupe(u8, host), fs);
        return fs;
    }
};

/// Idempotent: give a buffer its provider bundle (syntax by extension,
/// LSP when locally placed). Buffers without a path get an empty
/// bundle (tool/scratch).
fn attachProviders(deps: *AttachDeps, buf: *core.Buffers.Buffer) !void {
    if (buf.frontend != null) return;
    const gpa = deps.gpa;
    const at = try gpa.create(Attach);
    at.* = .{};
    buf.frontend = at;
    const p = buf.editor.backingPath() orelse return;
    const doc = &buf.editor.doc;

    if (deps.grammars.forPath(p)) |spec| {
        at.syntax = core.syntax.Syntax.create(gpa, spec, doc) catch |err| blk: {
            std.log.warn("syntax {s} unavailable: {t}", .{ spec.name, err });
            break :blk null;
        };
    }
    if (at.syntax) |syn| {
        try core.syntax.registerProviders(deps.caps, syn);
        _ = try deps.caps.registerFeed(doc, "edit/highlight", "highlight", .local, "treesitter");
    }
    if (deps.local_lsp) {
        if (deps.lsp_servers.match(p)) |entry| {
            at.lsp = core.lsp.Lsp.create(gpa, entry.argv, p, doc, deps.environ) catch |err| blk: {
                std.log.warn("lsp unavailable: {t}", .{err});
                break :blk null;
            };
            if (at.lsp) |l| {
                const diag_layer = try deps.caps.registerFeed(doc, "edit/diagnostics", "diagnostics", .host, "lsp/server");
                l.attachDiagnostics(diag_layer);
                l.attachCaps(deps.caps, entry.extSlice());
            }
        }
    }
}

fn detachProviders(deps: *AttachDeps, buf: *core.Buffers.Buffer) void {
    const at: *Attach = @ptrCast(@alignCast(buf.frontend orelse return));
    if (at.lsp) |l| l.destroy();
    if (at.syntax) |s| s.destroy();
    deps.caps.layers.dropDoc(deps.gpa, &buf.editor.doc);
    deps.gpa.destroy(at);
    buf.frontend = null;
}

/// `open <path>` — dedupe by path; `host:path` opens over a persistent
/// ssh shell (the coreutils tier); providers attach either way.
fn openBufferHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const deps: *AttachDeps = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const spec = args[0].string;
    if (ctx.buffers.findByPath(spec)) |id| {
        try ctx.buffers.switchTo(ctx.gpa, id, ctx.keymap);
        return .{ .integer = @intCast(id) };
    }

    // scp-style remote: host:path (no '/' before the first ':').
    const remote: ?struct { host: []const u8, path: []const u8 } = blk: {
        const colon = std.mem.indexOfScalar(u8, spec, ':') orelse break :blk null;
        if (std.mem.indexOfScalar(u8, spec[0..colon], '/') != null) break :blk null;
        if (colon == 0 or colon + 1 >= spec.len) break :blk null;
        break :blk .{ .host = spec[0..colon], .path = spec[colon + 1 ..] };
    };

    if (remote) |r| {
        // Dedupe remote opens by (shell, remote path).
        const fs0 = deps.shells.get(r.host);
        var rit = ctx.buffers.iterator();
        while (rit.next()) |b| {
            switch (b.editor.backing) {
                .shell => |s| if (s.fs == fs0 and std.mem.eql(u8, s.path, r.path)) {
                    try ctx.buffers.switchTo(ctx.gpa, b.id, ctx.keymap);
                    return .{ .integer = @intCast(b.id) };
                },
                else => {},
            }
        }
    }

    const id = try ctx.buffers.create(ctx.gpa, std.fs.path.basename(spec));
    errdefer ctx.buffers.close(ctx.gpa, id, ctx.keymap) catch {};
    const buf = ctx.buffers.get(id).?;
    if (remote) |r| {
        const fs = try deps.shellFor(r.host);
        try buf.editor.openShell(ctx.gpa, fs, r.path);
    } else {
        buf.editor.openFile(ctx.gpa, spec) catch |err| switch (err) {
            error.FileNotFound => try buf.editor.adoptPath(ctx.gpa, spec),
            else => |e| return e,
        };
    }
    try attachProviders(deps, buf);
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.keymap);
    return .{ .integer = @intCast(id) };
}

// ── Buffer sharing over the connection ──────────────────────────────

const ShareCtx = struct {
    conn: *?core.session.Conn,
    caps: *core.Caps,
};

/// `share` — announce the active buffer on the connection; the peer
/// sees it via `open-shared`. One history root; the peer's frontier
/// exchange bootstraps content.
fn shareHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const c = if (sc.conn.*) |*c| c else return .{ .string = "not connected" };
    const buf = ctx.buffer();
    for (c.collabs.items) |col| {
        if (col.tag == buf.id) return .{ .string = "already shared" };
    }
    const doc = &buf.editor.doc;
    const col = try c.share(doc, buf.name, buf.id);
    col.presence_layer = try sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
    col.export_diag_layer = sc.caps.layers.find(doc, "diagnostics");
    std.log.info("shared buffer {s} on channel {d}", .{ buf.name, col.base });
    return .nil;
}

/// `open-shared` — pick over the peer's unopened announcements; accept
/// opens it into a fresh buffer (no local backing: the sharer saves).
fn openSharedHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const c = if (sc.conn.*) |*c| c else return .{ .string = "not connected" };
    var items: std.ArrayList([]u8) = .empty;
    defer {
        for (items.items) |it| ctx.gpa.free(it);
        items.deinit(ctx.gpa);
    }
    for (c.offers.items, 0..) |o, i| {
        if (o.opened) continue;
        try items.append(ctx.gpa, try std.fmt.allocPrint(ctx.gpa, "{d}: @{s}", .{ i, o.name }));
    }
    if (items.items.len == 0) return .{ .string = "no shared buffers offered" };
    const borrowed = try ctx.gpa.alloc([]const u8, items.items.len);
    defer ctx.gpa.free(borrowed);
    for (items.items, borrowed) |line, *slot| slot.* = line;
    try ctx.pick.open(ctx, "shared", borrowed, .{ .handler = openSharedAccept, .data = sc });
    return .nil;
}

fn openSharedAccept(ctx: *core.command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    const c = if (sc.conn.*) |*c| c else return;
    const colon = std.mem.indexOfScalar(u8, choice, ':') orelse return;
    const index = std.fmt.parseInt(usize, choice[0..colon], 10) catch return;
    if (index >= c.offers.items.len or c.offers.items[index].opened) return;
    const o = c.offers.items[index];

    const display = try std.fmt.allocPrint(ctx.gpa, "@{s}", .{o.name});
    defer ctx.gpa.free(display);
    const id = try ctx.buffers.create(ctx.gpa, display);
    const buf = ctx.buffers.get(id).?;
    const doc = &buf.editor.doc;
    const col = try c.openOffer(index, doc, id);
    col.presence_layer = try sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
    col.import_diag_layer = try sc.caps.layers.claim(ctx.gpa, doc, "diagnostics", .host, "remote-host");
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.keymap);
}

fn closeBufferHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const deps: *AttachDeps = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const b = ctx.buffer();
    if (b.editor.isDirty(ctx.gpa) catch true) return .{ .string = "dirty" };
    // Order matters: shares reference the doc and its layers.
    if (deps.share) |sc| {
        if (sc.conn.*) |*c| c.unbindTag(b.id);
    }
    detachProviders(deps, b);
    try ctx.buffers.close(ctx.gpa, b.id, ctx.keymap);
    return .nil;
}
