//! weft — the assembled editor: a Wayland window presenting a
//! `core.Editor` through snail's analytic glyph pipeline, all behavior
//! routed key → keymap → command ABI (built-ins and config/plugin
//! commands through the same door). The frame loop's only wait is the
//! swapchain (FIFO vsync); the input→commit→render path is bracketed by
//! the hot-section fence; frame + input latency percentiles log
//! continuously.
//!
//!   weft [file] [--font path.ttf] [--em N] [--config init.fnl]

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
    /// Access granted to peers on --listen (safe default: view). Peers
    /// cannot write unless the host explicitly grants edit/own.
    access: core.session.Access = .view,
    connect: ?[]const u8 = null, // host:port
    token: []const u8 = "weft-dev",
    user: []const u8 = "user",
    headless: bool = false,
    lsp_cmd: ?[]const u8 = null, // --headless host-side server
    /// With --connect: open the host's document as an editable partial
    /// checkout (content follows the cursor; huge files open instantly).
    partial: bool = false,
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
        } else if (std.mem.eql(u8, a, "--access")) {
            if (it.next()) |v| out.access = core.session.Access.parse(v) orelse out.access;
        } else if (std.mem.eql(u8, a, "--connect")) {
            out.connect = it.next() orelse out.connect;
        } else if (std.mem.eql(u8, a, "--token")) {
            out.token = it.next() orelse out.token;
        } else if (std.mem.eql(u8, a, "--user")) {
            out.user = it.next() orelse out.user;
        } else if (std.mem.eql(u8, a, "--headless")) {
            out.headless = true;
        } else if (std.mem.eql(u8, a, "--partial")) {
            out.partial = true;
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
            .access = args.access,
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
            // host. Nothing is read locally. A partial checkout keeps
            // the document virgin (adoptPartial replaces it wholesale).
            if (!args.partial) try b0.editor.adoptPath(gpa, path);
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
    var echo_line: std.ArrayList(u8) = .empty;
    defer echo_line.deinit(gpa);
    var cmd_ctx: core.command.Context = .{
        .gpa = gpa,
        .buffers = &buffers,
        .commands = &commands,
        .keymap = &keymap,
        .pick = &pick_state,
        .caps = &caps,
        .quit = &quit,
        .echo = &echo_line,
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

    // Caret config commands, registered before the config runs so it can
    // set per-mode styles at load time.
    var cursor_cfg = CursorConfig{ .gpa = gpa };
    defer cursor_cfg.deinit();
    _ = try commands.bind(gpa, "set-cursor", .{
        .name = "set-cursor",
        .summary = "Set the caret style (block|bar|underline) for a mode.",
        .args = &.{ .{ .name = "mode", .type = .string }, .{ .name = "style", .type = .string } },
        .handler = setCursorHandler,
        .data = &cursor_cfg,
    });
    _ = try commands.bind(gpa, "cursor-blink", .{
        .name = "cursor-blink",
        .summary = "Toggle caret blink (on|off) for a mode.",
        .args = &.{ .{ .name = "mode", .type = .string }, .{ .name = "state", .type = .string } },
        .handler = cursorBlinkHandler,
        .data = &cursor_cfg,
    });

    // The bundled plugin: UI policy (buffers picker, status, help) in
    // fennel over core mechanisms — loaded before user config so the
    // same names can be rebound there.
    const std_plugin = try core.Plugin.create(gpa, &cmd_ctx, "std");
    defer std_plugin.destroy();
    {
        const out = std_plugin.eval(gpa, @embedFile("bundled.fnl"), "bundled.fnl") catch blk: {
            std.log.err("bundled plugin failed to load", .{});
            break :blk try gpa.dupe(u8, "");
        };
        gpa.free(out);
    }

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
    _ = try commands.bind(gpa, "browse-remote", .{
        .name = "browse-remote",
        .summary = "Browse a remote directory (host, path) over the host's shell.",
        .args = &.{
            .{ .name = "host", .type = .string },
            .{ .name = "path", .type = .string },
        },
        .handler = browseRemoteHandler,
        .data = &attach_deps,
    });

    // ── Connection (wire v1.1: N shared buffers over one session) ──
    var fd_link: core.session.FdLink = undefined;
    var collab_session: ?*core.session.Session = null;
    defer if (collab_session) |s| s.destroy();
    var conn: ?core.session.Conn = null;
    defer if (conn) |*c| c.deinit();
    var partial_state: ?core.session.PartialDoc = null;
    defer if (partial_state) |*p| p.deinit();
    // Inbound hosting is a separate, additive role: the outbound client
    // state above (conn/collab_session/partial) is untouched; `hub`
    // accepts N peers, started at boot (--listen) or at runtime (listen).
    var hub: ?core.hub.Hub = null;
    defer if (hub) |*h| h.deinit();
    if (args.connect) |hostport| {
        fd_link = .{ .fd = try core.session.tcpConnect(hostport) };
        collab_session = try core.session.Session.create(gpa, fd_link.link(), .client, args.token, .own);
        conn = try core.session.Conn.init(gpa, collab_session.?, args.user, .client);
        const col = try conn.?.bindPrimary(&ed0.doc, 0);
        col.presence_layer = try caps.layers.claim(gpa, &ed0.doc, "presence", .replicated, "collab");
        // Host-scoped feeds (diagnostics) arrive over the wire.
        col.import_diag_layer = try caps.layers.claim(gpa, &ed0.doc, "diagnostics", .host, "remote-host");
        if (args.partial) {
            partial_state = core.session.PartialDoc.init(gpa, &ed0.doc);
            col.partial = &partial_state.?;
        }
    }
    var share_ctx: ShareCtx = .{
        .conn = &conn,
        .hub = &hub,
        .caps = &caps,
        .gpa = gpa,
        .buffers = &buffers,
        .partial = &partial_state,
    };
    attach_deps.share = &share_ctx;
    defer if (share_ctx.pending_connect) |hp| gpa.free(hp);
    defer {
        for (share_ctx.shared.items) |s| gpa.free(s.name);
        share_ctx.shared.deinit(gpa);
    }
    // Boot --listen folds onto the runtime listen path (one code path):
    // seed the intent; the first frame boots the hub.
    if (args.listen) |port| {
        share_ctx.pending_listen = port;
        share_ctx.pending_access = args.access;
    }
    _ = try commands.bind(gpa, "connect", .{
        .name = "connect",
        .summary = "Connect to a host at runtime; its document opens as a buffer.",
        .args = &.{.{ .name = "hostport", .type = .string }},
        .handler = connectHandler,
        .data = &share_ctx,
    });
    _ = try commands.bind(gpa, "disconnect", .{
        .name = "disconnect",
        .summary = "Drop the connection; shared buffers stay as local copies.",
        .args = &.{},
        .handler = disconnectHandler,
        .data = &share_ctx,
    });
    _ = try commands.bind(gpa, "realize-all", .{
        .name = "realize-all",
        .summary = "Fetch the whole partial checkout.",
        .args = &.{},
        .handler = realizeAllHandler,
        .data = &share_ctx,
    });
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
    _ = try commands.bind(gpa, "listen", .{
        .name = "listen",
        .summary = "Host on a port at an access grade (view|edit|own); peers connect and share buffers.",
        .args = &.{ .{ .name = "port", .type = .string }, .{ .name = "access", .type = .string } },
        .handler = listenHandler,
        .data = &share_ctx,
    });
    _ = try commands.bind(gpa, "stop-listening", .{
        .name = "stop-listening",
        .summary = "Stop accepting new peers (connected peers stay).",
        .args = &.{},
        .handler = stopListeningHandler,
        .data = &share_ctx,
    });

    // ── Window + Vulkan ──
    const window = try wayland.Window.init(1280, 800, "weft", "dev.psyclyx.weft");
    defer window.deinit();
    var fb = window.framebufferSize();
    const ctx = try Context.init(gpa, .{
        .display = window.display,
        .surface = window.surface,
    }, fb[0], fb[1], "weft");
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
    // Left-button drag: the source offset the press landed on. A plain
    // click just moves the caret; motion with the button held extends a
    // selection from this anchor.
    var drag_anchor: ?usize = null;
    var drag_selecting = false;
    // Caret blink: solid on any input, then toggle on a fixed period. Each
    // phase flip damages the view so an idle caret still blinks.
    var blink_on = true;
    var blink_next_ns: u64 = 0;
    const blink_period_ns: u64 = 530 * std.time.ns_per_ms;

    std.log.info("weft: rendering — {d} bytes open, em {d}", .{ ed0.text().byteLen(), args.em });

    while (!window.shouldClose() and !quit) {
        const frame_start = stats_mod.nowNs();
        window.pumpEvents();

        if (window.consumeResized() or ctx.swapchain_stale) {
            fb = window.framebufferSize();
            try ctx.recreateSwapchain(fb[0], fb[1]);
            view_dirty = true;
        }

        // ── Input → commit ──
        // The hot-section fence (no-blocking guarantee) is entered
        // narrowly inside dispatchKey around the typing/commit path, not
        // here: a bound key can also trigger a deliberately-blocking
        // control command (open a file, save), and those must be allowed
        // to block. See dispatchKey.
        var had_input = false;
        while (window.nextKeyEvent()) |ev| {
            if (!ev.pressed) continue;
            had_input = true;
            try dispatchKey(&cmd_ctx, &view, ev, fb[1]);
        }
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

        // ── Pointer → caret (click-to-place; drag extends a selection) ──
        // World space is framebuffer pixels; the surface-space pointer
        // scales by buffer_scale (HiDPI-correct, single multiply here).
        const scale: f32 = @floatFromInt(@max(window.buffer_scale, 1));
        const px = @as(f32, @floatCast(window.mouse_x)) * scale;
        const py = @as(f32, @floatCast(window.mouse_y)) * scale;
        if (window.consumeMousePressed(0)) {
            const off = view.offsetAtPoint(px, py);
            editor.clearSelection();
            editor.placeCursor(off);
            drag_anchor = off;
            drag_selecting = false;
            had_input = true;
            view_dirty = true;
        } else if (window.mouse_down[0]) {
            if (drag_anchor) |anchor| {
                const off = view.offsetAtPoint(px, py);
                if (off != editor.cursorOffset()) {
                    if (!drag_selecting) {
                        // First motion: anchor the mark, then drag the caret.
                        editor.placeCursor(anchor);
                        try editor.setMark(gpa);
                        drag_selecting = true;
                    }
                    editor.placeCursor(off);
                    had_input = true;
                    view_dirty = true;
                }
            }
        } else {
            drag_anchor = null;
            drag_selecting = false;
        }

        // Caret blink: any input shows a solid caret and restarts the
        // timer; otherwise, when the current mode blinks, flip on each
        // period and damage the view.
        if (had_input) {
            blink_on = true;
            blink_next_ns = frame_start + blink_period_ns;
        } else if (cursor_cfg.blinkFor(keymap.currentMode()) and frame_start >= blink_next_ns) {
            blink_on = !blink_on;
            blink_next_ns = frame_start + blink_period_ns;
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
        if (try def_ui.tick(&cmd_ctx)) view_dirty = true;
        if (try sym_ui.tick(&cmd_ctx)) view_dirty = true;
        // Drive any async pick source (completion race-and-refine, file
        // finder, dir browser) — a no-op for a static or source-less
        // pick. Completion now rides this instead of a bespoke tick.
        if (try pick_state.tick(&cmd_ctx)) view_dirty = true;
        // Apply connection intents recorded by commands (outside the
        // hot section: connect blocks on TCP, disconnect joins threads).
        if (share_ctx.disconnect_requested) {
            share_ctx.disconnect_requested = false;
            if (conn) |*c| {
                c.deinit();
                conn = null;
            }
            if (partial_state) |*p| {
                p.deinit();
                partial_state = null;
            }
            if (collab_session) |s| {
                s.destroy();
                collab_session = null;
            }
            view_dirty = true;
        }
        if (share_ctx.pending_connect) |hostport| {
            share_ctx.pending_connect = null;
            defer gpa.free(hostport);
            if (collab_session == null) runtimeConnect(
                gpa,
                &cmd_ctx,
                &collab_session,
                &conn,
                &fd_link,
                hostport,
                args.token,
                args.user,
                &caps,
            ) catch |err| {
                echo_line.clearRetainingCapacity();
                const msg = std.fmt.allocPrint(gpa, "connect failed: {t}", .{err}) catch "";
                defer if (msg.len > 0) gpa.free(msg);
                echo_line.appendSlice(gpa, msg) catch {};
            };
            view_dirty = true;
        }
        // Listen intents (same out-of-hot-section region): bind/listen
        // are immediate, accept runs on the hub's own thread.
        if (share_ctx.pending_listen) |port| {
            share_ctx.pending_listen = null;
            if (hub == null) startListen(gpa, &hub, &share_ctx, &buffers, &caps, port, args.token, share_ctx.pending_access, &echo_line);
            view_dirty = true;
        }
        if (share_ctx.stop_listen_requested) {
            share_ctx.stop_listen_requested = false;
            if (hub) |*h| h.stopAccepting();
            view_dirty = true;
        }
        if (hub) |*h| {
            // Adopt new peers (binds the primary + replays shares), then
            // publish the local cursor to every peer and tick.
            h.acceptPending(&share_ctx, guiConfigure);
            for (h.clients.items) |peer| {
                for (peer.conn.collabs.items) |col| {
                    if (buffers.get(@intCast(col.tag))) |b| col.cursor_offset = b.editor.cursorOffset();
                }
            }
            if (h.tick()) view_dirty = true;
            // Merge every peer's cursor into each shared doc's presence
            // layer for local display (per-peer collabs keep it null).
            if (share_ctx.primary_doc) |pd| {
                if (caps.layers.find(pd, "presence")) |pl| core.hub.unionPresence(h, pd, pl, gpa) catch {};
            }
            for (share_ctx.shared.items) |s| {
                if (caps.layers.find(s.doc, "presence")) |pl| core.hub.unionPresence(h, s.doc, pl, gpa) catch {};
            }
        }

        if (conn) |*c| {
            // Each bound buffer publishes its own cursor as presence.
            for (c.collabs.items) |col| {
                if (buffers.get(@intCast(col.tag))) |b| {
                    col.cursor_offset = b.editor.cursorOffset();
                }
            }
            // Partial checkout: realize content around the cursor (the
            // requests dedupe against realized + inflight spans).
            if (partial_state) |*p| {
                const cur = ed0.cursorOffset();
                p.want(collab_session.?, 0, cur -| (64 << 10), cur + (128 << 10)) catch {};
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
                            collab_session = try core.session.Session.create(gpa, fd_link.link(), .client, args.token, .own);
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
        // A partial checkout defers content rendering until the window
        // around the cursor is realized (rope holes panic on content
        // reads — the deterministic single choke point). The dirty flag
        // stays set, so the frame after realization repaints.
        const partial_blocked = if (partial_state) |*p| blk: {
            if (p.state != .open) break :blk false; // virgin/empty doc renders fine
            const cur = ed0.cursorOffset();
            const end = @min(ed0.text().byteLen(), cur + (64 << 10));
            break :blk !ed0.text().isRealized(.{ .start = cur -| (64 << 10), .end = end });
        } else false;
        if (view_dirty and !partial_blocked) {
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

            // Markdown styling for .md buffers: analyze a window (whole doc
            // when small) into per-byte attributes each damage frame — a
            // stale paint is slightly-old truth, like highlight bulk.
            var md_arena = std.heap.ArenaAllocator.init(gpa);
            defer md_arena.deinit();
            const md_inline: ?view_mod.MdInline = blk: {
                const path = editor.backingPath() orelse abuf.name;
                if (!isMarkdownPath(path)) break :blk null;
                const rope = editor.text();
                const total = rope.byteLen();
                const range = if (total <= 256 * 1024)
                    @import("stemma").Range{ .start = 0, .end = total }
                else rng: {
                    const rows = rope.lineCount();
                    const first = view.top_row -| 100;
                    const last = @min(rows -| 1, view.top_row + 200);
                    break :rng @import("stemma").Range{ .start = rope.lineRange(first).start, .end = rope.lineRange(last).end };
                };
                const attrs = core.markdown.analyze(md_arena.allocator(), rope, range) catch break :blk null;
                break :blk .{ .base = range.start, .attrs = attrs };
            };

            var pos_buf: [24]u8 = undefined;
            const buffer_pos = blk: {
                var index: usize = 0;
                var nth: usize = 0;
                var bit2 = buffers.iterator();
                while (bit2.next()) |b| {
                    nth += 1;
                    if (b == abuf) index = nth;
                }
                break :blk std.fmt.bufPrint(&pos_buf, "{d}/{d}", .{ index, buffers.count() }) catch null;
            };
            const shared_here = blk: {
                if (conn) |*c| {
                    for (c.collabs.items) |col| if (col.tag == abuf.id) break :blk true;
                }
                if (hub) |*h| {
                    for (h.clients.items) |peer| {
                        for (peer.conn.collabs.items) |col| if (col.tag == abuf.id) break :blk true;
                    }
                }
                break :blk false;
            };
            const backing_chip: ?[]const u8 = switch (editor.backing) {
                .none => if (shared_here) "@shared" else null,
                .file => if (shared_here) "file+shared" else "file",
                .shell => if (shared_here) "shell+shared" else "shell",
                .tool => "tool",
            };
            const unfetched_pct: ?u8 = blk: {
                var unfetched: usize = 0;
                for (editor.doc.unrealizedBase()) |h| unfetched += h.bytes;
                if (unfetched == 0) break :blk null;
                const total_len = editor.text().byteLen();
                if (total_len == 0) break :blk null;
                break :blk @intCast(@min(99, unfetched * 100 / total_len));
            };
            var listen_buf: [40]u8 = undefined;
            const link_note: ?[]const u8 = if (collab_session) |s|
                @tagName(s.liveness())
            else if (hub) |*h|
                (std.fmt.bufPrint(&listen_buf, "listening {d} ({s})", .{ h.clients.items.len, h.access.label() }) catch "listening")
            else
                null;
            const hud: view_mod.Hud = .{
                .mode = keymap.currentMode(),
                .md_inline = md_inline,
                .cursor_style = cursor_cfg.styleFor(keymap.currentMode()),
                .cursor_on = if (cursor_cfg.blinkFor(keymap.currentMode())) blink_on else true,
                .file = editor.backingPath() orelse abuf.name,
                .dirty = editor.isDirty(gpa) catch true,
                .save_failed = editor.save_state == .failed,
                .buffer_pos = buffer_pos,
                .backing = backing_chip,
                .save_note = switch (editor.save_state) {
                    .saving => "saving…",
                    .stale => "save stale",
                    else => null,
                },
                .unfetched_pct = unfetched_pct,
                .peers = if (caps.layers.find(&editor.doc, "presence")) |pl| pl.spanCount() else 0,
                .echo = if (echo_line.items.len > 0) echo_line.items else null,
                .pick = if (pick_state.active) &pick_state else null,
                .highlight_layer = caps.layers.find(&editor.doc, "highlight"),
                .diag_layer = caps.layers.find(&editor.doc, "diagnostics"),
                .presence_layer = caps.layers.find(&editor.doc, "presence"),
                .link = link_note,
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
/// Per-mode caret style + blink, set from config via `set-cursor` and
/// `cursor-blink` and read into the Hud each frame. Blink is per mode so
/// the sample config can blink in insert and stay solid in normal.
const CursorConfig = struct {
    const Entry = struct { mode: []u8, style: view_mod.CursorStyle = .block, blink: bool = false };
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,

    fn deinit(self: *CursorConfig) void {
        for (self.entries.items) |e| self.gpa.free(e.mode);
        self.entries.deinit(self.gpa);
    }
    fn styleFor(self: *const CursorConfig, mode: []const u8) view_mod.CursorStyle {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.mode, mode)) return e.style;
        return .block;
    }
    fn blinkFor(self: *const CursorConfig, mode: []const u8) bool {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.mode, mode)) return e.blink;
        return false;
    }
    fn entry(self: *CursorConfig, mode: []const u8) !*Entry {
        for (self.entries.items) |*e| if (std.mem.eql(u8, e.mode, mode)) return e;
        try self.entries.append(self.gpa, .{ .mode = try self.gpa.dupe(u8, mode) });
        return &self.entries.items[self.entries.items.len - 1];
    }
};

fn parseCursorStyle(s: []const u8) ?view_mod.CursorStyle {
    if (std.mem.eql(u8, s, "block")) return .block;
    if (std.mem.eql(u8, s, "bar")) return .bar;
    if (std.mem.eql(u8, s, "underline")) return .underline;
    return null;
}

fn setCursorHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = ctx;
    const cfg: *CursorConfig = @ptrCast(@alignCast(data.?));
    const style = parseCursorStyle(args[1].string) orelse return error.InvalidArgument;
    (try cfg.entry(args[0].string)).style = style;
    return .nil;
}

fn cursorBlinkHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = ctx;
    const cfg: *CursorConfig = @ptrCast(@alignCast(data.?));
    (try cfg.entry(args[0].string)).blink = std.mem.eql(u8, args[1].string, "on");
    return .nil;
}

fn isMarkdownPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".markdown");
}

/// One view-computed vertical step. The goal-x (world px) is taken from
/// the editor (sticky across a run of up/down) or seeded from the current
/// caret's rendered x; the target offset is the nearest caret to it on
/// the adjacent row. This is the interactive replacement for the core's
/// scalar-column `moveVertical` — monospace stays exact (uniform
/// advances), proportional text tracks the visual column.
fn visualVertical(ed: *core.Editor, view: *view_mod.View, dir: i32) !void {
    const rope = ed.text();
    const cur = ed.cursorOffset();
    const gx = ed.goalX() orelse try view.xOfOffsetOnRow(rope, cur);
    ed.setGoalX(gx); // persists even at the doc edges, for the next step
    const pt = rope.offsetToPoint(cur);
    const rows = rope.lineCount();
    const target_row = if (dir < 0)
        (if (pt.row == 0) return else pt.row - 1)
    else
        (if (pt.row + 1 >= rows) return else pt.row + 1);
    const target = try view.xToOffsetOnRow(rope, target_row, gx);
    ed.moveToVisual(target, gx);
}

fn dispatchKey(ctx: *core.command.Context, view: *view_mod.View, ev: wayland.KeyEvent, fb_h: u32) !void {
    const c = wayland.c;
    // Paging needs viewport geometry the core doesn't know; view-aware
    // dispatch stays here.
    if (ev.keysym == c.XKB_KEY_Page_Up or ev.keysym == c.XKB_KEY_Page_Down) {
        const rows = view.visibleRows(fb_h);
        const dir: i32 = if (ev.keysym == c.XKB_KEY_Page_Up) -1 else 1;
        for (0..rows) |_| try visualVertical(ctx.editor(), view, dir);
        return;
    }

    var name_buf: [64]u8 = undefined;
    const n = c.xkb_keysym_get_name(ev.keysym, &name_buf, name_buf.len);
    if (n > 0) {
        var spec_buf: [80]u8 = undefined;
        const spec = core.Keymap.keyspec(&spec_buf, ev.mods.ctrl, ev.mods.alt, ev.mods.shift, name_buf[0..@intCast(n)]);
        if (ctx.keymap.lookup(spec)) |cmd_name| {
            // Vertical motion is view-computed (goal-x over rendered
            // geometry), not the core's column fallback — the interactive
            // override of these commands. Same precedent as Page above.
            if (std.mem.eql(u8, cmd_name, "cursor-up")) {
                try visualVertical(ctx.editor(), view, -1);
                return;
            }
            if (std.mem.eql(u8, cmd_name, "cursor-down")) {
                try visualVertical(ctx.editor(), view, 1);
                return;
            }
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
        // modal posture: normal mode has none and swallows it). This IS
        // the hot typing→commit path — fence it so an accidental blocking
        // API here trips in Debug.
        const tc = ctx.keymap.textCommand() orelse return;
        core.task.beginHotSection();
        defer core.task.endHotSection();
        _ = core.command.run(ctx.commands, ctx, tc, &.{.{ .string = text }}) catch |err| {
            std.log.warn("{s} failed: {t}", .{ tc, err });
        };
    }
}

/// Resolve and evaluate the user config: `--config` wins, else
/// $XDG_CONFIG_HOME/weft/init.fnl, else ~/.config/weft/init.fnl.
/// Read-only; a missing default config means built-in defaults.
fn loadConfig(gpa: std.mem.Allocator, plugin: *core.Plugin, override: ?[]const u8, environ: std.process.Environ) !void {
    var buf: [512]u8 = undefined;
    const path = override orelse blk: {
        if (environ.getPosix("XDG_CONFIG_HOME")) |x| {
            break :blk std.fmt.bufPrint(&buf, "{s}/weft/init.fnl", .{x}) catch return;
        }
        if (environ.getPosix("HOME")) |h| {
            break :blk std.fmt.bufPrint(&buf, "{s}/.config/weft/init.fnl", .{h}) catch return;
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

// ── Remote directory browsing (fs_source over the host's shell) ─────

/// One remote-browse pick's navigation state: the host and the current
/// directory. Accepting descends (dir), ascends (`../`), or opens a
/// file — each re-runs `browse-remote` or `open` by name.
const RemoteBrowse = struct {
    host: []u8,
    path: []u8,
};

/// `browse-remote <host> <path>` — list a remote directory over the
/// persistent ssh shell and pick over it (streamed by fs_source).
fn browseRemoteHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const deps: *AttachDeps = @ptrCast(@alignCast(data.?));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.TypeMismatch;
    const host = args[0].string;
    const path = args[1].string;
    const gpa = ctx.gpa;
    const fs = try deps.shellFor(host);

    const rb = try gpa.create(RemoteBrowse);
    errdefer gpa.destroy(rb);
    rb.host = try gpa.dupe(u8, host);
    errdefer gpa.free(rb.host);
    rb.path = try gpa.dupe(u8, path);
    errdefer gpa.free(rb.path);
    const prompt = try std.fmt.allocPrint(gpa, "dir {s}:{s}", .{ host, path });
    defer gpa.free(prompt);
    // Source built last: openWith closes it on failure, so the only
    // unwinding left is rb (its errdefers above).
    const rd = try core.fs_source.RemoteDir.create(gpa, ctx.buffers.pool, fs, path);
    try ctx.pick.openWith(ctx, prompt, &.{}, .{
        .handler = browseRemoteAccept,
        .cleanup = browseRemoteCleanup,
        .data = rb,
    }, .{ .allow_free_text = true, .source = rd.source() });
    return .nil;
}

fn browseRemoteAccept(ctx: *core.command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    const rb: *RemoteBrowse = @ptrCast(@alignCast(data.?));
    const gpa = ctx.gpa;
    if (std.mem.eql(u8, choice, "../")) {
        const up = parentPath(rb.path);
        _ = try core.command.run(ctx.commands, ctx, "browse-remote", &.{
            .{ .string = rb.host }, .{ .string = up },
        });
        return;
    }
    if (std.mem.endsWith(u8, choice, "/")) {
        const child = try joinPath(gpa, rb.path, choice[0 .. choice.len - 1]);
        defer gpa.free(child);
        _ = try core.command.run(ctx.commands, ctx, "browse-remote", &.{
            .{ .string = rb.host }, .{ .string = child },
        });
        return;
    }
    const child = try joinPath(gpa, rb.path, choice);
    defer gpa.free(child);
    const spec = try std.fmt.allocPrint(gpa, "{s}:{s}", .{ rb.host, child });
    defer gpa.free(spec);
    _ = try core.command.run(ctx.commands, ctx, "open", &.{.{ .string = spec }});
}

fn browseRemoteCleanup(data: ?*anyopaque, gpa: std.mem.Allocator) void {
    const rb: *RemoteBrowse = @ptrCast(@alignCast(data.?));
    gpa.free(rb.host);
    gpa.free(rb.path);
    gpa.destroy(rb);
}

/// Directory portion of `p` (trailing slashes stripped), or "." at the
/// root — a borrowed subslice, valid for `p`'s lifetime.
fn parentPath(p: []const u8) []const u8 {
    var end = p.len;
    while (end > 0 and p[end - 1] == '/') end -= 1;
    if (std.mem.lastIndexOfScalar(u8, p[0..end], '/')) |i| {
        return if (i == 0) "/" else p[0..i];
    }
    return ".";
}

fn joinPath(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, base, ".")) return gpa.dupe(u8, name);
    var b = base;
    while (b.len > 0 and b[b.len - 1] == '/') b = b[0 .. b.len - 1];
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ b, name });
}

// ── Buffer sharing over the connection ──────────────────────────────

/// A buffer shared over the hub, remembered so late-joining peers can be
/// caught up (the hub analog of `Conn.share_names`). `name` is owned.
const SharedDoc = struct {
    doc: *core.Document,
    name: []u8,
    tag: u64,
};

const ShareCtx = struct {
    gpa: std.mem.Allocator,
    buffers: *core.Buffers,
    /// Outbound client connection (connect/--connect); single.
    conn: *?core.session.Conn,
    /// Inbound hosting: N peers (listen/--listen); additive.
    hub: *?core.hub.Hub,
    caps: *core.Caps,
    partial: *?core.session.PartialDoc,
    /// Buffers shared over the hub — replayed to late joiners.
    shared: std.ArrayList(SharedDoc) = .empty,
    /// The doc bound at quad 0 for every hub peer (the buffer active
    /// when listening began); set by the listen apply block.
    primary_doc: ?*core.Document = null,
    primary_tag: u64 = 0,
    /// Commands record INTENTS here; the frame loop applies them
    /// outside the input hot section (connect blocks on TCP, disconnect
    /// joins session threads).
    pending_connect: ?[]u8 = null,
    disconnect_requested: bool = false,
    pending_listen: ?u16 = null,
    /// Access grade for the next `listen` (safe default: view).
    pending_access: core.session.Access = .view,
    stop_listen_requested: bool = false,
};

/// Wire a hub-side collab as a participant-and-relay: no local presence
/// layer (the frame loop unions all peers into one), publish our own
/// cursor, relay peers to each other.
fn wireHubShare(sc: *ShareCtx, peer: *core.hub.Peer, col: *core.session.Collab, doc: *core.Document) !void {
    col.presence_layer = null;
    col.export_diag_layer = sc.caps.layers.find(doc, "diagnostics");
    col.publish_presence = true;
    col.relay = core.hub.relayPresence;
    col.relay_ctx = try peer.relayFor(doc);
}

/// Bind a newly joined hub peer: the primary doc at quad 0, then replay
/// every already-shared buffer so late joiners are caught up.
fn guiConfigure(ctx: ?*anyopaque, peer: *core.hub.Peer) anyerror!void {
    const sc: *ShareCtx = @ptrCast(@alignCast(ctx.?));
    const pd = sc.primary_doc orelse return error.NoPrimary;
    const col = try peer.conn.bindPrimary(pd, sc.primary_tag);
    try wireHubShare(sc, peer, col, pd);
    _ = sc.caps.layers.claim(sc.gpa, pd, "presence", .replicated, "collab") catch {};
    for (sc.shared.items) |s| {
        const scol = try peer.conn.share(s.doc, s.name, s.tag);
        try wireHubShare(sc, peer, scol, s.doc);
        _ = sc.caps.layers.claim(sc.gpa, s.doc, "presence", .replicated, "collab") catch {};
    }
}

/// Start the hub: assign into the slot FIRST, then `listen` against the
/// slot's stable address (the accept thread captures it).
fn startListen(
    gpa: std.mem.Allocator,
    hub_slot: *?core.hub.Hub,
    sc: *ShareCtx,
    buffers: *core.Buffers,
    caps: *core.Caps,
    port: u16,
    token: []const u8,
    access: core.session.Access,
    echo: *std.ArrayList(u8),
) void {
    sc.primary_doc = &buffers.active().editor.doc;
    sc.primary_tag = buffers.active_id;
    hub_slot.* = core.hub.Hub.init(gpa, token, access) catch {
        setEcho(echo, gpa, "listen: out of memory");
        return;
    };
    const h = &hub_slot.*.?;
    h.listen(port) catch |err| {
        var buf: [64]u8 = undefined;
        setEcho(echo, gpa, std.fmt.bufPrint(&buf, "listen failed: {t}", .{err}) catch "listen failed");
        h.deinit();
        hub_slot.* = null;
        return;
    };
    _ = caps.layers.claim(gpa, sc.primary_doc.?, "presence", .replicated, "collab") catch {};
    var buf: [32]u8 = undefined;
    setEcho(echo, gpa, std.fmt.bufPrint(&buf, "listening on {d}", .{port}) catch "listening");
}

fn setEcho(echo: *std.ArrayList(u8), gpa: std.mem.Allocator, msg: []const u8) void {
    echo.clearRetainingCapacity();
    echo.appendSlice(gpa, msg) catch {};
}

/// `listen <port>` — start hosting at runtime (records the intent; the
/// frame loop starts the hub outside the hot section).
fn listenHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.TypeMismatch;
    if (sc.hub.* != null) return .{ .string = "already listening (stop-listening first)" };
    const port = std.fmt.parseInt(u16, args[0].string, 10) catch return .{ .string = "bad port" };
    const access = core.session.Access.parse(args[1].string) orelse
        return .{ .string = "access must be view|edit|own" };
    sc.pending_listen = port;
    sc.pending_access = access;
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "listening ({s} access)…", .{access.label()}) catch "listening…");
}

/// `stop-listening` — stop accepting new peers; connected peers stay.
fn stopListeningHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    if (sc.hub.* == null) return .{ .string = "not listening" };
    sc.stop_listen_requested = true;
    return ok_echo(ctx, "no longer accepting peers");
}

/// `connect host:port` — join a host at runtime (the remote primary
/// opens as a new buffer). No auto-reconnect for runtime connections.
fn connectHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    if (sc.conn.* != null) return .{ .string = "already connected (disconnect first)" };
    if (sc.pending_connect) |old| ctx.gpa.free(old);
    sc.pending_connect = try ctx.gpa.dupe(u8, args[0].string);
    return ok_echo(ctx, "connecting…");
}

/// `disconnect` — drop the connection; shared buffers stay as local
/// copies.
fn disconnectHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    if (sc.conn.* == null) return .{ .string = "not connected" };
    sc.disconnect_requested = true;
    return ok_echo(ctx, "disconnecting…");
}

/// `realize-all` — fetch the whole partial checkout.
fn realizeAllHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const p = if (sc.partial.*) |*p| p else return .{ .string = "not a partial checkout" };
    p.fetch_all = true;
    return ok_echo(ctx, "fetching the whole document…");
}

fn ok_echo(ctx: *core.command.Context, msg: []const u8) !core.command.Value {
    ctx.echo.clearRetainingCapacity();
    try ctx.echo.appendSlice(ctx.gpa, msg);
    return .nil;
}

/// `share` — announce the active buffer to the peer(s): over the
/// outbound connection AND to every hub peer, remembering it for late
/// joiners. One history root; the peer's frontier exchange bootstraps
/// content. The hub's primary buffer is already served, so it is skipped.
fn shareHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    if (sc.conn.* == null and sc.hub.* == null) return .{ .string = "not connected" };
    const buf = ctx.buffer();
    const doc = &buf.editor.doc;
    var did = false;

    if (sc.conn.*) |*c| {
        var already = false;
        for (c.collabs.items) |col| if (col.tag == buf.id) {
            already = true;
            break;
        };
        if (!already) {
            const col = try c.share(doc, buf.name, buf.id);
            col.presence_layer = try sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
            col.export_diag_layer = sc.caps.layers.find(doc, "diagnostics");
            did = true;
        }
    }

    if (sc.hub.*) |*h| {
        const is_primary = if (sc.primary_doc) |pd| pd == doc else false;
        var recorded = false;
        for (sc.shared.items) |s| if (s.tag == buf.id) {
            recorded = true;
            break;
        };
        if (!is_primary and !recorded) {
            const name_owned = try sc.gpa.dupe(u8, buf.name);
            errdefer sc.gpa.free(name_owned);
            try sc.shared.append(sc.gpa, .{ .doc = doc, .name = name_owned, .tag = buf.id });
            _ = sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab") catch {};
            for (h.clients.items) |peer| {
                var has = false;
                for (peer.conn.collabs.items) |col| if (col.tag == buf.id) {
                    has = true;
                    break;
                };
                if (has) continue;
                const scol = peer.conn.share(doc, buf.name, buf.id) catch continue;
                wireHubShare(sc, peer, scol, doc) catch continue;
            }
            did = true;
        }
    }

    if (!did) return .{ .string = "already shared" };
    std.log.info("shared buffer {s}", .{buf.name});
    return .nil;
}

/// One openable offer across all connections: the owning Conn, the hub
/// peer it belongs to (null for the outbound connection), the Conn-local
/// offer index, and its display name (borrowed).
const OfferRef = struct {
    conn: *core.session.Conn,
    peer: ?*core.hub.Peer,
    index: usize,
    name: []const u8,
};

fn collectOffers(sc: *ShareCtx, gpa: std.mem.Allocator, out: *std.ArrayList(OfferRef)) !void {
    if (sc.conn.*) |*c| {
        for (c.offers.items, 0..) |o, i| {
            if (!o.opened) try out.append(gpa, .{ .conn = c, .peer = null, .index = i, .name = o.name });
        }
    }
    if (sc.hub.*) |*h| {
        for (h.clients.items) |peer| {
            for (peer.conn.offers.items, 0..) |o, i| {
                if (!o.opened) try out.append(gpa, .{ .conn = &peer.conn, .peer = peer, .index = i, .name = o.name });
            }
        }
    }
}

/// `open-shared` — pick over every peer's unopened announcements
/// (outbound host + all hub peers); accept opens it into a fresh buffer.
fn openSharedHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    var refs: std.ArrayList(OfferRef) = .empty;
    defer refs.deinit(ctx.gpa);
    try collectOffers(sc, ctx.gpa, &refs);
    if (refs.items.len == 0) return .{ .string = "no shared buffers offered" };
    var texts: std.ArrayList([]u8) = .empty;
    defer {
        for (texts.items) |it| ctx.gpa.free(it);
        texts.deinit(ctx.gpa);
    }
    var entries: std.ArrayList(core.pick.Entry) = .empty;
    defer entries.deinit(ctx.gpa);
    for (refs.items, 0..) |r, i| {
        const text = try std.fmt.allocPrint(ctx.gpa, "{d}: @{s}", .{ i, r.name });
        try texts.append(ctx.gpa, text);
        try entries.append(ctx.gpa, .{ .text = text, .doc = "shared by a peer — open to collaborate" });
    }
    try ctx.pick.open(ctx, "shared", entries.items, .{ .handler = openSharedAccept, .data = sc });
    return .nil;
}

fn openSharedAccept(ctx: *core.command.Context, data: ?*anyopaque, choice: []const u8) anyerror!void {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    const colon = std.mem.indexOfScalar(u8, choice, ':') orelse return;
    const list_idx = std.fmt.parseInt(usize, choice[0..colon], 10) catch return;
    var refs: std.ArrayList(OfferRef) = .empty;
    defer refs.deinit(ctx.gpa);
    collectOffers(sc, ctx.gpa, &refs) catch return;
    if (list_idx >= refs.items.len) return;
    const ref = refs.items[list_idx];
    if (ref.index >= ref.conn.offers.items.len or ref.conn.offers.items[ref.index].opened) return;

    const display = try std.fmt.allocPrint(ctx.gpa, "@{s}", .{ref.name});
    defer ctx.gpa.free(display);
    const id = try ctx.buffers.create(ctx.gpa, display);
    const buf = ctx.buffers.get(id).?;
    const doc = &buf.editor.doc;
    const col = try ref.conn.openOffer(ref.index, doc, id);
    if (ref.peer) |peer| {
        // A hub peer shared a buffer to us: participate + relay it.
        try wireHubShare(sc, peer, col, doc);
        _ = sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab") catch {};
    } else {
        // Offered by the host we connected out to.
        col.presence_layer = try sc.caps.layers.claim(ctx.gpa, doc, "presence", .replicated, "collab");
        col.import_diag_layer = try sc.caps.layers.claim(ctx.gpa, doc, "diagnostics", .host, "remote-host");
    }
    try ctx.buffers.switchTo(ctx.gpa, id, ctx.keymap);
}

/// Runtime connect: fresh buffer for the remote primary, client
/// session + Conn bound to it.
fn runtimeConnect(
    gpa: std.mem.Allocator,
    ctx: *core.command.Context,
    session_slot: *?*core.session.Session,
    conn_slot: *?core.session.Conn,
    fd_link: *core.session.FdLink,
    hostport: []const u8,
    token: []const u8,
    user: []const u8,
    caps: *core.Caps,
) !void {
    const fd = try core.session.tcpConnect(hostport);
    fd_link.* = .{ .fd = fd };
    const sess = try core.session.Session.create(gpa, fd_link.link(), .client, token, .own);
    errdefer sess.destroy();
    var c = try core.session.Conn.init(gpa, sess, user, .client);
    errdefer c.deinit();

    const display = try std.fmt.allocPrint(gpa, "@{s}", .{hostport});
    defer gpa.free(display);
    const id = try ctx.buffers.create(gpa, display);
    const buf = ctx.buffers.get(id).?;
    const col = try c.bindPrimary(&buf.editor.doc, id);
    col.presence_layer = try caps.layers.claim(gpa, &buf.editor.doc, "presence", .replicated, "collab");
    col.import_diag_layer = try caps.layers.claim(gpa, &buf.editor.doc, "diagnostics", .host, "remote-host");
    session_slot.* = sess;
    conn_slot.* = c;
    try ctx.buffers.switchTo(gpa, id, ctx.keymap);
    std.log.info("connected to {s}", .{hostport});
}

fn closeBufferHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const deps: *AttachDeps = @ptrCast(@alignCast(data.?));
    if (args.len != 0) return error.ArityMismatch;
    const b = ctx.buffer();
    if (b.editor.isDirty(ctx.gpa) catch true) return .{ .string = "dirty" };
    // Order matters: shares reference the doc and its layers.
    if (deps.share) |sc| {
        if (sc.conn.*) |*c| c.unbindTag(b.id);
        if (sc.hub.*) |*h| for (h.clients.items) |peer| peer.conn.unbindTag(b.id);
        var i: usize = 0;
        while (i < sc.shared.items.len) {
            if (sc.shared.items[i].tag == b.id) {
                sc.gpa.free(sc.shared.items[i].name);
                _ = sc.shared.swapRemove(i);
            } else i += 1;
        }
    }
    detachProviders(deps, b);
    try ctx.buffers.close(ctx.gpa, b.id, ctx.keymap);
    return .nil;
}
