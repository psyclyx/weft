//! weft — the assembled editor: a Wayland window presenting a
//! `core.Editor` through snail's analytic glyph pipeline, all behavior
//! routed key → keymap → command ABI (built-ins and config/plugin
//! commands through the same door). The frame loop's only wait is the
//! swapchain (FIFO vsync); the input→commit→render path is bracketed by
//! the hot-section fence; frame + input latency percentiles log
//! continuously.
//!
//!   weft [file] [--font path.ttf] [--em N] [--plugin p.wasm]... [--config config.js]

const std = @import("std");
const wayland = @import("platform/wayland.zig");
const Context = @import("gfx/context.zig").Context;
const core = @import("core/core.zig");
const view_mod = @import("gfx/view.zig");
const region = @import("gfx/region.zig");
const window_layout = @import("gfx/window_layout.zig");
const stats_mod = @import("gfx/stats.zig");
const snail = @import("snail");
const stemma = @import("stemma");
const snail_vk = @import("gfx/snail_vk/root.zig");
const vk = @import("vk.zig").c;

const embedded_font = @embedFile("font_mono");

const headless = @import("headless.zig");

const handler = @import("app/handler.zig");
const ok_echo = handler.ok_echo;
const setEcho = handler.setEcho;
const scroll = @import("app/scroll.zig");
const window_cmds = @import("app/window_cmds.zig");
const cursor_config = @import("app/cursor_config.zig");
const config_load = @import("app/config_load.zig");
const dispatch = @import("app/dispatch.zig");
const setup = @import("app/setup.zig");
const collab = @import("app/collab.zig");
const collab_cmds = @import("app/collab_cmds.zig");
const ShareCtx = collab.ShareCtx;
const hostTrustChip = collab.hostTrustChip;
const selectionAnchorOf = collab.selectionAnchorOf;
const identityHandler = collab_cmds.identityHandler;
const guiConfigure = collab.guiConfigure;
const providers = @import("app/providers.zig");
const Attach = providers.Attach;
const AttachDeps = providers.AttachDeps;
const attachProviders = providers.attachProviders;
const detachProviders = providers.detachProviders;
const resolveSyntax = providers.resolveSyntax;
const LspServers = providers.LspServers;
const lspAddCommand = providers.lspAddCommand;
const grammarAddCommand = providers.grammarAddCommand;
const reconnectTask = providers.reconnectTask;
const buffers_cmds = @import("app/buffers_cmds.zig");

const arg_parse = @import("app/args.zig");
const Args = arg_parse.Args;
const parseArgs = arg_parse.parseArgs;

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
    // Connecting as a peer without a --file: the shared document still binds to
    // buffer 0 (wire v1), but don't leave it named "*scratch*" — name it after
    // the host so the peer clearly lands in the shared session, not a scratchpad.
    if (args.connect) |hostport| {
        if (args.file == null) {
            if (std.fmt.allocPrint(gpa, "@{s}", .{hostport})) |nm| {
                const b0 = buffers.active();
                gpa.free(b0.name);
                b0.name = nm;
            } else |_| {}
        }
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
    // Capability consumers — written against capability names only. The
    // vars live here (used by the frame loop + their defers); `setup`
    // runs the mechanical bind sequence in registration order.
    var completion_ui: core.complete_ui.CompletionUi = .empty;
    var def_ui: core.nav_ui.DefinitionUi = .empty;
    var sym_ui: core.nav_ui.SymbolsUi = .empty;
    defer sym_ui.deinit(gpa);
    var hover_ui: core.nav_ui.HoverUi = .empty;
    defer hover_ui.deinit(gpa);
    // Grammars are data: builtins seeded, config extends via command.
    var grammars = try core.syntax.Runtime.initBuiltins(gpa);
    defer grammars.deinit(gpa);
    // Language servers are data: config registers (extension, command)
    // pairs; nothing here names a server.
    var lsp_servers: LspServers = .empty;
    defer lsp_servers.deinit(gpa);
    try setup.registerCapabilityConsumers(gpa, &commands, &completion_ui, &def_ui, &sym_ui, &hover_ui, &grammars, &lsp_servers);

    // Caret config commands, registered before the config runs so it can
    // set per-mode styles at load time.
    var cursor_cfg = cursor_config.CursorConfig{ .gpa = gpa };
    defer cursor_cfg.deinit();
    // which-key: show the hint popup immediately (bypass the idle delay). If not
    // already in a menu, open the leader menu — so a help key (F1) surfaces it
    // from anywhere.
    var which_key_now = false;
    try setup.registerCursorCommands(gpa, &commands, &cursor_cfg, &which_key_now);

    // This machine's long-term identity (generated + persisted on first
    // run). Names us to peers; the fingerprint is what a human verifies.
    var my_identity = core.identity.loadOrGenerate(gpa, init.minimal.environ) catch |err| blk: {
        std.log.warn("identity: {t} — using an ephemeral one this run", .{err});
        break :blk core.identity.Identity.generate();
    };
    std.log.info("weft identity {s}", .{&my_identity.fingerprint()});
    // TOFU store: remembers whom we've verified out of band (see the
    // status line's peer trust; first contact is accepted but unverified).
    var known_peers = try core.known_peers.KnownPeers.load(gpa, init.minimal.environ);
    defer known_peers.deinit();
    _ = try commands.bind(gpa, "identity", .{
        .name = "identity",
        .summary = "Show this machine's identity fingerprint.",
        .args = &.{},
        .handler = identityHandler,
        .data = &my_identity,
    });

    // ── Plugins: external .wasm, sandboxed under wasmtime (no in-process
    //    trust). weft ships MODELESS — nothing here unless the user asks with
    //    --plugin. The reference catalog (vim, palette, edit, …) lives as
    //    `.wasm` under lib/weft/plugins/; each runs behind the perm handshake,
    //    reaching the editor only through the `weft.*` membrane and authoring
    //    every edit as its own peer. The effect services the ABI's Group D/E
    //    need are wired here and forwarded across the membrane.
    var plugin_kv: core.kv.Store = .empty;
    defer plugin_kv.deinit(gpa);
    // Config data the config plane stages via weft.set — a DISTINCT store from
    // plugin_kv so runtime scratch and injected config can never collide.
    var config_kv: core.kv.Store = .empty;
    defer config_kv.deinit(gpa);
    var plugin_subs: core.subbuffer.SubBuffers = .empty;
    defer plugin_subs.deinit(gpa);
    var plugin_loop = core.async_loop.Loop.init(gpa, pool, core.task.nowNs);
    defer plugin_loop.deinit();
    // Give plugin `proc` children the parent PATH (nix tools like rg/zig).
    core.wasm_host.setEnviron(init.minimal.environ);
    var wasm_engine = try core.wasm.Engine.init();
    defer wasm_engine.deinit();
    var plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty;
    defer {
        for (plugins.items) |p| p.deinit();
        plugins.deinit(gpa);
    }
    const plugin_dir = config_load.pluginDir(gpa);
    defer gpa.free(plugin_dir);
    const module_cache_dir = config_load.moduleCacheDir(gpa);
    defer if (module_cache_dir) |d| gpa.free(d);
    var plugin_host: config_load.PluginHost = .{
        .gpa = gpa,
        .engine = &wasm_engine,
        .ctx = &cmd_ctx,
        .opts = .{ .kv = &plugin_kv, .config = &config_kv, .loop = &plugin_loop, .subbuffers = &plugin_subs, .syntax_of = resolveSyntax, .pool = pool, .module_cache_dir = module_cache_dir },
        .list = &plugins,
        .dir = plugin_dir,
    };
    // Explicit --plugin flags load first, in order.
    for (args.plugins[0..args.plugin_count]) |name| plugin_host.load(name);

    // ── User config: config.js in the quickjs.wasm sandbox (plan 06B) ──
    // The local plane, one tier down: `config.js` (via --config) wires keys
    // and actions, reaching the editor only through the `weft.*` grants — the
    // same door a plugin uses. It can also load plugins itself (`weft.plugin`),
    // so the sample config brings up its own vim/palette without --plugin. A
    // bare weft with no plugins is modeless. Absent or broken config is a
    // warning, never fatal.
    if (args.config) |config_path| {
        config_load.loadJsConfig(gpa, &cmd_ctx, config_path, plugin_host.loader(), &config_kv) catch |e|
            std.log.warn("config: {s} failed to load: {t}", .{ config_path, e });
    }

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
    try buffers_cmds.registerCommands(gpa, &commands, &attach_deps);

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
    // Opt-in filesystem sharing (host side): a confined root served to peers.
    // Default off — a peer gets nothing unless the host passed --share-root.
    var peer_fs_root: ?core.rooted_fs.RootedFs = null;
    defer if (peer_fs_root) |*r| r.close();
    if (args.share_root) |root_dir| {
        if (gpa.dupeZ(u8, root_dir)) |rz| {
            defer gpa.free(rz);
            peer_fs_root = core.rooted_fs.RootedFs.open(rz.ptr) catch blk: {
                std.log.warn("share-root: cannot open '{s}'", .{root_dir});
                break :blk null;
            };
        } else |_| {}
    }
    // Client side: correlate .peer fs replies for a connected session, and the
    // bridge the guest queues async LIST requests through (dired-on-a-peer).
    var remote_fs = core.session.RemoteFs.init(gpa);
    defer remote_fs.deinit();
    var peer_fs_bridge = core.wasm_host.PeerFsBridge{ .gpa = gpa };
    core.wasm_host.setPeerFsBridge(&peer_fs_bridge);
    defer peer_fs_bridge.deinit();
    defer core.wasm_host.setPeerFsBridge(null);
    var peer_fs_inflight: std.AutoHashMapUnmanaged(u64, []u8) = .empty;
    defer {
        var pit = peer_fs_inflight.valueIterator();
        while (pit.next()) |v| gpa.free(v.*);
        peer_fs_inflight.deinit(gpa);
    }
    if (args.connect) |hostport| {
        fd_link = .{ .fd = try core.session.tcpConnect(hostport) };
        collab_session = try core.session.Session.create(gpa, fd_link.link(), .client, args.token, .own, &my_identity);
        conn = try core.session.Conn.init(gpa, collab_session.?, args.user, .client);
        const col = try conn.?.bindPrimary(&ed0.doc, 0);
        col.presence_layer = try caps.layers.claim(gpa, &ed0.doc, "presence", .replicated, "collab");
        // Host-scoped feeds (diagnostics) arrive over the wire.
        col.import_diag_layer = try caps.layers.claim(gpa, &ed0.doc, "diagnostics", .host, "remote-host");
        col.remote_fs = &remote_fs; // client can list/read the host's shared root
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
        .session = &collab_session,
        .known = &known_peers,
        .peer_fs_root = if (peer_fs_root) |*r| r else null,
        .fs_grant = .{ .access = args.share_fs },
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
    try collab_cmds.registerCommands(gpa, &commands, &share_ctx, &known_peers);
    // Window layout: a recursive split tree over the region geometry. Core
    // commands only RECORD intent on `win_ctx`; the frame loop applies them
    // (splitFocused/closeFocused/focus/move by pane geometry) and keeps the
    // focused pane == the active buffer. The legacy names
    // (split/vsplit/unsplit/focus-other) alias onto the same intents so the
    // prebuilt `windows` .wasm plugin and older configs keep working.
    var win_ctx: window_cmds.WindowCtx = .{};
    // Stable storage so each command's `data` pointer stays valid for the run.
    var window_action_ctx: [window_cmds.cmd_count]window_cmds.WindowActionCtx = undefined;
    try window_cmds.registerCommands(gpa, &commands, &win_ctx, &window_action_ctx);

    // ── Window + Vulkan ──
    const window = try wayland.Window.init(1280, 800, "weft", "dev.psyclyx.weft");
    defer window.deinit();
    var fb = window.framebufferSize();
    const ctx = try Context.init(gpa, .{
        .display = window.display,
        .surface = window.surface,
    }, fb[0], fb[1], "weft");
    defer ctx.deinit();
    // The swapchain's actual extent is authoritative: a server-side-deco or
    // tiling compositor can force it to differ from the requested framebuffer
    // size. Drive all render geometry (layout, MVP, surface size) from it — from
    // frame one — so nothing mis-scales.
    fb = .{ ctx.extent.width, ctx.extent.height };

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

    // Scrolling commands need the view + framebuffer (which core commands
    // don't see), so they're registered here. `view.top_row` is always the
    // focused pane's scroll.
    var scroll_ctx: scroll.ScrollCtx = .{ .view = &view, .fb = &fb };
    try scroll.registerCommands(gpa, &commands, &scroll_ctx);

    // Theme is DATA: a runtime/bindable `set-color <name> <#hex>`, plus colors
    // the config staged declaratively via weft.set("theme", "<field>", "#hex").
    // Re-linearized per-field on mutation (Theme.setColor), so the draw path
    // stays a plain lookup.
    _ = try commands.bind(gpa, "set-color", .{
        .name = "set-color",
        .summary = "Set a theme color (name, #rrggbb).",
        .args = &.{ .{ .name = "name", .type = .string }, .{ .name = "hex", .type = .string } },
        .handler = cursor_config.setColorHandler,
        .data = &view,
    });
    inline for (@typeInfo(view_mod.Theme).@"struct".fields) |f| {
        if (config_kv.get("theme", f.name)) |blob| {
            if (config_load.firstConfigRecord(blob)) |hex| _ = view.theme.setColor(f.name, hex);
        }
    }

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
    // One `Built` per rendered pane, kept alive for the frame (its shapes
    // feed the instance stream) and freed at the top of the next render.
    var built_panes: std.ArrayList(view_mod.Built) = .empty;
    defer {
        for (built_panes.items) |*b| b.deinit(gpa);
        built_panes.deinit(gpa);
    }
    var instances: std.ArrayList(snail.render.records.Instance) = .empty;
    defer instances.deinit(gpa);
    var batches: std.ArrayList(snail.render.records.DrawBatch) = .empty;
    defer batches.deinit(gpa);
    var view_dirty = true;
    // Last activated buffer path (copied — the borrowed slice would dangle).
    var last_activate_path: [std.fs.max_path_bytes]u8 = undefined;
    var last_activate_len: usize = 0;
    // Window layout: a recursive tree of panes over the region geometry. A
    // single leaf is the ordinary unsplit case; splitFocused adds leaves.
    // The focused pane is always `buffers.active()` (so editing/input flow
    // through the active buffer unchanged), and each pane keeps its own
    // scroll (the focused pane's mirrors `view.top_row`).
    var win_layout = try window_layout.Layout.init(gpa, buffers.active_id);
    defer win_layout.deinit();
    var last_frame_rect: region.Rect = .{}; // last render's pane frame, for click routing
    var last_liveness: core.session.Liveness = .connecting;
    // The fingerprint we last announced for the outbound host, so a
    // reconnect to a different key re-announces (and TOFU-records) it. The
    // status-line trust chip reads its live grade from `known_peers`.
    var noted_host_fp: ?[24]u8 = null;
    var reconnect: ?core.task.Handle(anyerror!i32) = null;
    defer if (reconnect) |*h| h.detach();
    // Interactive `connect`: the TCP connect runs on the pool (it can take
    // seconds, or time out) so the frame thread never blocks. The hostport
    // is owned and borrowed by the worker until the handle is polled; on
    // shutdown with a connect in flight we detach and leak it (the worker
    // may still be reading it — a bounded, one-shot leak).
    var connect_task: ?core.task.Handle(anyerror!i32) = null;
    var connect_hostport: ?[]u8 = null;
    defer if (connect_task) |*h| h.detach();
    var next_reconnect_ns: u64 = 0;
    var next_backing_poll_ns: u64 = 0;
    var last_active: core.Buffers.Id = buffers.active_id;
    // Menu-overlay (on_menu) edge detection: fire at the frame boundary when the
    // active menu mode changes, so a which-key plugin re-renders exactly on
    // enter/leave (and never nested inside another guest call).
    var menu_open = false;
    var menu_shown = false; // has on_menu(open) fired for the current menu?
    var menu_open_ns: u64 = 0; // when the current menu was entered (idle timer)
    var last_menu_mode: [64]u8 = undefined;
    var last_menu_len: usize = 0;
    // which-key idle delay (doom-style): don't pop the hint until the menu has
    // been held this long — unless which-key-now (F1) forces it. Config sets it
    // via weft.set("editor", "which-key-delay-ms", "200").
    const which_key_delay_ns: u64 = blk: {
        if (config_kv.get("editor", "which-key-delay-ms")) |raw| {
            if (config_load.firstConfigRecord(raw)) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |ms| break :blk ms * std.time.ns_per_ms else |_| {}
            }
        }
        break :blk 200 * std.time.ns_per_ms;
    };
    // vim-goggles flash timing: a guest sets a range via wl_flash; we draw it
    // for `flash-ms` then clear it. Duration is config (default 150ms).
    var flash_gen: u64 = 0;
    var flash_start_ns: u64 = 0;
    var flash_was_active = false;
    const flash_duration_ns: u64 = blk: {
        if (config_kv.get("editor", "flash-ms")) |raw| {
            if (config_load.firstConfigRecord(raw)) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |ms| break :blk ms * std.time.ns_per_ms else |_| {}
            }
        }
        break :blk 150 * std.time.ns_per_ms;
    };
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
            const req = window.framebufferSize();
            ctx.recreateSwapchain(req[0], req[1]) catch |e| switch (e) {
                // Minimized / zero-size surface: the swapchain is torn down and
                // can't be recreated yet. Skip this frame and retry next one
                // (don't render into a destroyed swapchain).
                error.ZeroExtent => {
                    ctx.swapchain_stale = true;
                    continue;
                },
                else => return e,
            };
            // Geometry follows the swapchain's actual extent, not the request.
            fb = .{ ctx.extent.width, ctx.extent.height };
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
            try dispatch.dispatchKey(&cmd_ctx, &view, ev, fb[1]);
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
        // Pane routing: a click outside the focused pane's rect focuses the
        // pane under the cursor (the intent is applied below, against the
        // layout); inside, the click maps directly (panes render into their
        // own rects, so the geometry map is already in absolute coords). The
        // frame rect is last render's — one-frame latency, unseen.
        const click_in_peek = win_layout.count() > 1 and !win_layout.focusedRect(last_frame_rect).contains(px, py);
        if (window.consumeMousePressed(0)) {
            if (click_in_peek) {
                win_ctx.click_focus = true;
                win_ctx.click_x = px;
                win_ctx.click_y = py;
                had_input = true;
                view_dirty = true;
            } else {
                const off = view.offsetAtPoint(px, py);
                editor.clearSelection();
                editor.placeCursor(off);
                drag_anchor = off;
                drag_selecting = false;
                had_input = true;
                view_dirty = true;
            }
        } else if (window.mouse_down[0] and !click_in_peek) {
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
        if (try hover_ui.tick(&cmd_ctx)) view_dirty = true;
        // Hover dismisses when the cursor leaves the point it was requested at.
        if (hover_ui.active and buffers.active().editor.cursorOffset() != hover_ui.offset) {
            hover_ui.clear();
            view_dirty = true;
        }
        // Drive any async pick source (completion race-and-refine, file
        // finder, dir browser) — a no-op for a static or source-less
        // pick. Completion now rides this instead of a bespoke tick.
        if (try pick_state.tick(&cmd_ctx)) view_dirty = true;
        // Deliver native async completions (subprocess/timer output, deferred
        // edits) on the frame thread; a completion repaints.
        if (plugin_loop.tick()) view_dirty = true;
        // Stream any interactive REPL output into its comint buffer.
        for (plugins.items) |pl| {
            if (core.wasm_host.drainReplSessions(pl)) view_dirty = true;
        }
        // Fire the activation event when the focused buffer's path changes, so
        // language-aware plugins (`modes`) can attach keymaps/facts.
        {
            const cur_path = buffers.active().editor.backingPath() orelse "";
            if (!std.mem.eql(u8, cur_path, last_activate_path[0..last_activate_len])) {
                for (plugins.items) |pl| core.wasm_host.notifyActivate(pl, cur_path);
                const n = @min(cur_path.len, last_activate_path.len);
                @memcpy(last_activate_path[0..n], cur_path[0..n]);
                last_activate_len = n;
            }
        }
        // Menu overlay edges: on_menu(open) when a (different) menu mode becomes
        // active, on_menu(close) when we leave menus. Fired here at the frame
        // boundary — top-level, so a menu-owner guest can't re-enter its store.
        {
            const cur = keymap.currentMode();
            const is_menu = keymap.isMenuMode(cur);
            const same = is_menu and menu_open and std.mem.eql(u8, cur, last_menu_mode[0..last_menu_len]);
            if (!same) {
                // Entered/left/switched menu: close a shown popup; (re)start the
                // idle timer. Do NOT show yet — the delay gates that below.
                if (menu_open and menu_shown) {
                    for (plugins.items) |pl| core.wasm_host.notifyMenu(pl, false);
                }
                menu_open = is_menu;
                menu_shown = false;
                if (is_menu) {
                    menu_open_ns = frame_start;
                    last_menu_len = @min(cur.len, last_menu_mode.len);
                    @memcpy(last_menu_mode[0..last_menu_len], cur[0..last_menu_len]);
                }
                view_dirty = true;
            }
            // Pop the hint once held past the idle delay (or F1 forced it now).
            if (menu_open and !menu_shown and (which_key_now or frame_start -| menu_open_ns >= which_key_delay_ns)) {
                for (plugins.items) |pl| core.wasm_host.notifyMenu(pl, true);
                menu_shown = true;
                view_dirty = true;
            }
            which_key_now = false;
        }
        // ── Connect/disconnect/listen intents (outside the hot section:
        // connect blocks on TCP, disconnect joins threads). ──
        if (collab.applyIntents(&share_ctx, &cmd_ctx, pool, &connect_task, &connect_hostport, &fd_link, &echo_line, &my_identity, args.token, args.user))
            view_dirty = true;
        // ── Window-layout intents (outside the input hot section) ──
        if (window_cmds.applyIntents(&win_ctx, &win_layout, &view, &buffers, gpa, &keymap, last_frame_rect))
            view_dirty = true;
        if (hub) |*h| {
            // Adopt new peers (binds the primary + replays shares), then
            // publish the local cursor to every peer and tick.
            h.acceptPending(&share_ctx, guiConfigure);
            for (h.clients.items) |peer| {
                for (peer.conn.collabs.items) |col| {
                    if (buffers.get(@intCast(col.tag))) |b| {
                        col.cursor_offset = b.editor.cursorOffset();
                        col.selection_anchor = selectionAnchorOf(&b.editor);
                    }
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
            // Each bound buffer publishes its own cursor + selection.
            for (c.collabs.items) |col| {
                if (buffers.get(@intCast(col.tag))) |b| {
                    col.cursor_offset = b.editor.cursorOffset();
                    col.selection_anchor = selectionAnchorOf(&b.editor);
                }
            }
            // Partial checkout: realize content around the cursor (the
            // requests dedupe against realized + inflight spans). Also want
            // the scroll window of every pane rendering the partial buffer
            // (buffer 0, wire v1) — a split peeking it elsewhere must not
            // read an unrealized hole (see partial_blocked below).
            if (partial_state) |*p| {
                const cur = ed0.cursorOffset();
                p.want(collab_session.?, 0, cur -| (64 << 10), cur + (128 << 10)) catch {};
                const WantCtx = struct { p: *core.session.PartialDoc, sess: *core.session.Session, ed0: *core.Editor };
                win_layout.eachPane(WantCtx{ .p = p, .sess = collab_session.?, .ed0 = ed0 }, struct {
                    fn visit(wc: WantCtx, pane: *window_layout.Pane) void {
                        if (pane.buffer_id != 0) return; // the partial doc is buffer 0
                        const rope = wc.ed0.text();
                        const rows = rope.lineCount();
                        if (rows == 0) return;
                        const start = rope.lineRange(@min(pane.top_row, rows - 1)).start;
                        wc.p.want(wc.sess, 0, start -| (8 << 10), start + (128 << 10)) catch {};
                    }
                }.visit);
            }
            if (try c.tick()) view_dirty = true;
            // Async .peer fs: post the guest's queued LIST requests over the
            // session, then deliver any completed listings into their buffers.
            if (collab_session) |sess| {
                for (peer_fs_bridge.requests.items) |req| {
                    defer gpa.free(req.path);
                    const enc = core.peer_fs.encodeList(gpa, req.path) catch {
                        gpa.free(req.dest);
                        continue;
                    };
                    defer gpa.free(enc);
                    if (remote_fs.request(sess, 0, enc)) |id| {
                        peer_fs_inflight.put(gpa, id, req.dest) catch gpa.free(req.dest);
                    } else |_| gpa.free(req.dest);
                }
                peer_fs_bridge.requests.clearRetainingCapacity();
                var done: [16]u64 = undefined;
                var dn: usize = 0;
                var pit = peer_fs_inflight.iterator();
                while (pit.next()) |e| {
                    if (remote_fs.take(e.key_ptr.*)) |resp| {
                        defer gpa.free(resp);
                        if (core.peer_fs.decodeResponse(resp)) |dec| {
                            if (dec.status == .ok)
                                core.wasm_host.deliverToBuffer(&cmd_ctx, e.value_ptr.*, "peer-fs", dec.payload);
                        }
                        gpa.free(e.value_ptr.*);
                        if (dn < done.len) {
                            done[dn] = e.key_ptr.*;
                            dn += 1;
                        }
                        view_dirty = true;
                    }
                }
                for (done[0..dn]) |id| _ = peer_fs_inflight.remove(id);
            }
            // Note the host's identity once per handshake: TOFU-record it
            // and echo its fingerprint + SAS + trust so the user can verify
            // the four words out of band before trusting a new host.
            if (collab_session.?.peerFingerprint()) |fp| {
                if (noted_host_fp == null or !std.mem.eql(u8, &noted_host_fp.?, &fp)) {
                    noted_host_fp = fp;
                    const prior = known_peers.remember(fp) catch core.known_peers.Trust.unknown;
                    const sas = collab_session.?.sas().?; // established ⇒ present
                    var buf: [96]u8 = undefined;
                    const msg = if (prior == .verified)
                        std.fmt.bufPrint(&buf, "host {s} · verified", .{&fp}) catch "host verified"
                    else
                        std.fmt.bufPrint(&buf, "host {s} · unverified · SAS {s}", .{ &fp, &sas }) catch "host unverified";
                    setEcho(&echo_line, gpa, msg);
                    std.log.info("collab: {s}", .{msg});
                    view_dirty = true;
                }
            }
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
                            collab_session = try core.session.Session.create(gpa, fd_link.link(), .client, args.token, .own, &my_identity);
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
        // Gate on ALL rendered panes on the partial buffer, not just the
        // focused one: any pane's visible window (its scroll .. a screenful)
        // must be realized before we read it.
        const partial_blocked = if (partial_state) |*p| blk: {
            if (p.state != .open) break :blk false; // virgin/empty doc renders fine
            const cur = ed0.cursorOffset();
            const end = @min(ed0.text().byteLen(), cur + (64 << 10));
            if (!ed0.text().isRealized(.{ .start = cur -| (64 << 10), .end = end })) break :blk true;
            const CheckCtx = struct { ed0: *core.Editor, blocked: bool = false };
            var cc = CheckCtx{ .ed0 = ed0 };
            win_layout.eachPane(&cc, struct {
                fn visit(c: *CheckCtx, pane: *window_layout.Pane) void {
                    if (pane.buffer_id != 0) return; // only the partial doc holes
                    const rope = c.ed0.text();
                    const rows = rope.lineCount();
                    if (rows == 0) return;
                    const start = rope.lineRange(@min(pane.top_row, rows - 1)).start;
                    const e = @min(rope.byteLen(), start + (48 << 10));
                    if (!rope.isRealized(.{ .start = start, .end = e })) c.blocked = true;
                }
            }.visit);
            break :blk cc.blocked;
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
                if (!cursor_config.isMarkdownPath(path)) break :blk null;
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
            // Collect the plugins' live overlays for this frame (which-key,
            // dired, magit … render through the retained surface door).
            var surface_buf: [64]*const core.surface.Surface = undefined;
            var surface_n: usize = 0;
            for (plugins.items) |pl| {
                if (pl.surface.active and surface_n < surface_buf.len) {
                    surface_buf[surface_n] = &pl.surface;
                    surface_n += 1;
                }
            }
            // which-key: while a leader/chord prefix is active (a leaf menu
            // mode) and no picker is open, list that mode's bindings. This is
            // the host FALLBACK — if a which-key plugin is loaded it renders a
            // surface (surface_n > 0) and the host render steps aside, so the
            // menu is never drawn twice.
            var wk_hints: std.ArrayList(core.Keymap.Binding) = .empty;
            defer wk_hints.deinit(gpa);
            if (surface_n == 0 and !pick_state.active and keymap.isMenuMode(keymap.currentMode())) {
                keymap.ownBindings(gpa, keymap.currentMode(), &wk_hints) catch {};
            }
            // Buffer tab strip (only with more than one buffer open). Name
            // slices borrow the buffers' own strings — valid this frame.
            var tab_list: std.ArrayList(view_mod.Tab) = .empty;
            defer tab_list.deinit(gpa);
            if (buffers.count() > 1) {
                var bit3 = buffers.iterator();
                while (bit3.next()) |b| {
                    const nm = b.editor.backingPath() orelse b.name;
                    tab_list.append(gpa, .{ .name = std.fs.path.basename(nm), .active = b == abuf }) catch {};
                }
            }
            // vim-goggles: a guest set a flash range; show it for the duration.
            const flash_range: ?stemma.Range = fblk: {
                const fs = core.wasm_host.flashState();
                if (fs.gen != flash_gen) {
                    flash_gen = fs.gen;
                    flash_start_ns = frame_start;
                }
                const active = fs.gen > 0 and (frame_start -| flash_start_ns) < flash_duration_ns;
                if (active or flash_was_active) view_dirty = true; // draw it, then clear it
                flash_was_active = active;
                if (!active) break :fblk null;
                const len = editor.text().byteLen();
                break :fblk .{ .start = @min(fs.start, len), .end = @min(fs.end, len) };
            };
            const hud: view_mod.Hud = .{
                .mode = keymap.currentMode(),
                .which_key = if (wk_hints.items.len > 0) wk_hints.items else null,
                .surfaces = surface_buf[0..surface_n],
                .flash = flash_range,
                .hover = if (hover_ui.active) .{ .text = hover_ui.text.items, .offset = hover_ui.offset } else null,
                .tabs = if (tab_list.items.len > 1) tab_list.items else null,
                .md_inline = md_inline,
                .cursor_style = cursor_cfg.styleFor(cursor_cfg.resolveMode(&keymap, keymap.currentMode())),
                .cursor_on = if (cursor_cfg.blinkFor(cursor_cfg.resolveMode(&keymap, keymap.currentMode()))) blink_on else true,
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
                .styles_layer = caps.layers.find(&editor.doc, "styles"),
                .diag_layer = caps.layers.find(&editor.doc, "diagnostics"),
                .presence_layer = caps.layers.find(&editor.doc, "presence"),
                .link = link_note,
                .trust = if (collab_session != null) blk: {
                    const fp = noted_host_fp orelse break :blk null;
                    break :blk hostTrustChip(known_peers.trust(fp));
                } else null,
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
            view.resetFrame();
            // Panes tile the frame via the window layout; each leaf builds
            // into its own rect (absolute coords) — no emit translate, and
            // click routing is the layout's hit-test. Non-focused panes build
            // FIRST (their own scroll, no caret/dock); the focused pane builds
            // LAST so `view.frame_layout` ends on it (caret + between-frame
            // hit-testing) and carries the caret + picker dock.
            const window_rect: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(fb[0]), .h = @floatFromInt(fb[1]) };
            // Carve the picker's window-bottom dock off the window FIRST, so the
            // panes lay out in what remains — the picker is a real region, not an
            // overlay, and cannot overlap a pane or status line (region.zig's
            // contract). Zero-height when no pick is open ⇒ panes fill the window.
            const dock_cut = window_rect.cutBottom(view.pickDockHeight(if (pick_state.active) &pick_state else null));
            const pick_dock = dock_cut.strip;
            const frame_rect = dock_cut.rest;
            last_frame_rect = frame_rect;

            var slots: [window_layout.max_panes]window_layout.Slot = undefined;
            const nslots = win_layout.collect(frame_rect, &slots);

            // Free last frame's builds; each pane appends a fresh one below.
            for (built_panes.items) |*old| old.deinit(gpa);
            built_panes.clearRetainingCapacity();

            var foc_rect = frame_rect;
            var foc_border: region.Edges = .{};
            for (slots[0..nslots]) |slot| {
                if (slot.focused) {
                    foc_rect = slot.rect;
                    foc_border = slot.border;
                    continue; // the focused pane builds last, below
                }
                const ob = buffers.get(slot.pane.buffer_id) orelse continue;
                ob.editor.fold_layer = caps.layers.find(&ob.editor.doc, "folds");
                const other_hud: view_mod.Hud = .{
                    .mode = keymap.currentMode(),
                    .file = ob.editor.backingPath() orelse ob.name,
                    .cursor_on = false, // the caret belongs to the focused pane
                    .pane_border = slot.border,
                    // A peeked tool buffer keeps its colors: thread its styles feed too.
                    .styles_layer = caps.layers.find(&ob.editor.doc, "styles"),
                };
                const bo = try view.build(arena_state.allocator(), &ob.editor, other_hud, &slot.pane.top_row, slot.rect, .{}, world_to_pixel);
                try built_panes.append(gpa, bo);
                if (bo.records_added != 0)
                    binding[0] = try snail_vk.uploadDeltaAndWait(gpa, vctx, resources, ctx.command_pool, &cache, binding[0], &view.atlas);
            }

            // The focused pane: active buffer, full HUD, caret, picker dock.
            var fhud = hud;
            fhud.pane_border = foc_border;
            editor.fold_layer = caps.layers.find(&editor.doc, "folds");
            const b = try view.build(arena_state.allocator(), editor, fhud, &view.top_row, foc_rect, pick_dock, world_to_pixel);
            try built_panes.append(gpa, b);
            if (b.records_added != 0)
                binding[0] = try snail_vk.uploadDeltaAndWait(gpa, vctx, resources, ctx.command_pool, &cache, binding[0], &view.atlas);
            win_layout.focusedPane().top_row = view.top_row; // scrollToCursor may have moved it

            // Every pane rendered into its own rect (identity transform), so
            // all panes accumulate into one instance stream, one draw. The
            // focused pane is last in `built_panes` → its caret draws on top.
            instances.clearRetainingCapacity();
            batches.clearRetainingCapacity();
            var total_shapes: usize = 0;
            for (built_panes.items) |bp| total_shapes += bp.shapes.len;
            try instances.resize(gpa, @max(total_shapes, 1));
            try batches.resize(gpa, @max(total_shapes, 1));
            var ilen: usize = 0;
            var blen: usize = 0;
            for (built_panes.items) |bp| {
                _ = try snail.emit.emit(instances.items, batches.items, &ilen, &blen, binding[0], &view.atlas, bp.shapes, .identity, .{ 1, 1, 1, 1 });
            }
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
