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
const session_mod = @import("app/session.zig");
const Session = session_mod.Session;
const render_mod = @import("app/render.zig");
const frame_mod = @import("app/frame.zig");
const collab = @import("app/collab.zig");
const collab_cmds = @import("app/collab_cmds.zig");
const hostTrustChip = collab.hostTrustChip;
const selectionAnchorOf = collab.selectionAnchorOf;
const identityHandler = collab_cmds.identityHandler;
const guiConfigure = collab.guiConfigure;
const providers = @import("app/providers.zig");
const Attach = providers.Attach;
const attachProviders = providers.attachProviders;
const detachProviders = providers.detachProviders;
const resolveSyntax = providers.resolveSyntax;
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
    // Providers owns the config-extended registries (grammars, lsp_servers) and
    // the per-buffer attach bundle. Its deinit is registered FIRST so it runs
    // LAST: the persistent remote shells must outlive the buffers whose backings
    // + in-flight save workers use them, and the pool whose workers may still
    // hold one. The registries exist now (before the session) so the session's
    // capability consumers can bind grammar-add/lsp-add onto them; attach_deps is
    // built later, once caps + the connect placement are known.
    var providers_state: providers.Providers = undefined;
    try providers_state.initRegistries(gpa);
    defer providers_state.deinit(gpa);
    var pool = try core.task.Pool.init(gpa, .{});
    defer pool.deinit();

    // which-key: show the hint popup immediately (bypass the idle delay). If not
    // already in a menu, open the leader menu — so a help key (F1) surfaces it
    // from anywhere. Dispatch reads it; the session's caret commands bind it.
    var which_key_now = false;

    // ── Core editing state ──
    // `Session` owns the buffers, the command/keymap/pick surfaces, the caps
    // store, the echo line + quit flag, the capability-consumer UIs and the
    // caret config. Built IN PLACE (cmd_ctx borrows its siblings), it installs
    // the built-ins and binds the capability + caret/which-key commands in
    // registration order; its deinit frees them in the reverse order main()
    // used to.
    var session: Session = undefined;
    try session.init(gpa, pool, args.user, &providers_state.grammars, &providers_state.lsp_servers, &which_key_now);
    defer session.deinit(gpa);
    const buffers = &session.buffers;
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
    _ = try session.commands.bind(gpa, "identity", .{
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
        .ctx = &session.cmd_ctx,
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
        config_load.loadJsConfig(gpa, &session.cmd_ctx, config_path, plugin_host.loader(), &config_kv) catch |e|
            std.log.warn("config: {s} failed to load: {t}", .{ config_path, e });
    }
    // The config's editor plugin (vim/helix) has set the base editing mode by
    // now; capture it as the mode fresh buffers open in, so a tool buffer's
    // mode (dired/magit) can never leak into a file opened from it.
    session.buffers.setDefaultMode(gpa, session.keymap.currentMode()) catch {};

    // ── Per-buffer providers (syntax + LSP hang off Buffer.frontend) ──
    // Phase two of `providers_state`: build attach_deps in place (it borrows the
    // session caps + the connect placement — for a remote-hosted document the
    // server runs on the host peer and diagnostics arrive as the imported host
    // feed, so no local LSP). detachProviders runs here (before Session.deinit,
    // while caps + buffers' docs are alive); the shells live on, freed last by
    // providers_state.deinit.
    providers_state.initAttach(gpa, &session.caps, init.minimal.environ, args.connect == null);
    const attach_deps = &providers_state.attach_deps;
    defer {
        var det_it = buffers.iterator();
        while (det_it.next()) |b| detachProviders(attach_deps, b);
    }
    try attachProviders(attach_deps, buffers.active());
    // The graphical shell's open/close know about providers and remote
    // shells; they shadow the core versions (registry last-wins).
    try buffers_cmds.registerCommands(gpa, &session.commands, attach_deps);

    // ── Connection (wire v1.1: N shared buffers over one session) ──
    // `Collab` owns the whole connection cluster (outbound conn/session/partial,
    // inbound hub, the opt-in shared fs + .peer bridge, the ShareCtx intent
    // surface, and the frame-loop liveness/reconnect state). initBase lays the
    // skeleton in place (share_ctx points at sibling fields) and is infallible,
    // so its deinit is registered right after — before `connect` fills the
    // outbound optionals, so a connect error cleans partial state (exactly how
    // main() used to pre-defer the optionals). Registered here (after the
    // provider detach defer) it tears down BEFORE detach — conn/hub must unbind
    // before the doc layers drop — and before Session (it reads the session caps).
    // (known_peers + my_identity stay main() locals: built early for the identity
    // command; Collab borrows them.)
    var collab_state: collab.Collab = undefined;
    collab_state.initBase(gpa, buffers, &session.caps, &known_peers, args.share_root, args.share_fs, args.listen, args.access);
    defer collab_state.deinit(gpa);
    try collab_state.connect(gpa, ed0, &session.caps, &my_identity, args.connect, args.token, args.user, args.partial);
    // The buffer close path unbinds shares before the doc dies (Providers borrows
    // the share surface).
    attach_deps.share = &collab_state.share_ctx;
    try collab_cmds.registerCommands(gpa, &session.commands, &collab_state.share_ctx, &known_peers);
    // Window layout: a recursive split tree over the region geometry. Core
    // commands only RECORD intent on `win_ctx`; the frame loop applies them
    // (splitFocused/closeFocused/focus/move by pane geometry) and keeps the
    // focused pane == the active buffer. The legacy names
    // (split/vsplit/unsplit/focus-other) alias onto the same intents so the
    // prebuilt `windows` .wasm plugin and older configs keep working.
    var win_ctx: window_cmds.WindowCtx = .{};
    // Stable storage so each command's `data` pointer stays valid for the run.
    var window_action_ctx: [window_cmds.cmd_count]window_cmds.WindowActionCtx = undefined;
    try window_cmds.registerCommands(gpa, &session.commands, &win_ctx, &window_action_ctx);

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

    // ── Render path (backend chosen by -Drenderer; both share `ctx`) ──
    const font_bytes: []const u8 = if (args.font) |p| try core.file.readAlloc(gpa, p) else embedded_font;
    defer if (args.font != null) gpa.free(@constCast(font_bytes));
    // All render resources + the pane tree are OWNED by `render`; it builds
    // them in place (no move hazard) and frees them in the reverse order
    // main() used to. ctx (the device) is declared earlier, so it outlives
    // render's Vulkan frees. The aliases below are non-owning borrows so the
    // frame loop reads `view`/`cache`/etc. unchanged.
    var render: render_mod.RenderState = undefined;
    try render.init(gpa, ctx, font_bytes, args.em, buffers.active_id);
    defer render.deinit();
    const view = &render.fb.view;
    const win_layout = &render.fb.win_layout;

    // Scrolling commands need the view + framebuffer (which core commands
    // don't see), so they're registered here. `view.top_row` is always the
    // focused pane's scroll.
    var scroll_ctx: scroll.ScrollCtx = .{ .view = view, .fb = &fb };
    try scroll.registerCommands(gpa, &session.commands, &scroll_ctx);

    // Theme is DATA: a runtime/bindable `set-color <name> <#hex>`, plus colors
    // the config staged declaratively via weft.set("theme", "<field>", "#hex").
    // Re-linearized per-field on mutation (Theme.setColor), so the draw path
    // stays a plain lookup.
    _ = try session.commands.bind(gpa, "set-color", .{
        .name = "set-color",
        .summary = "Set a theme color (name, #rrggbb).",
        .args = &.{ .{ .name = "name", .type = .string }, .{ .name = "hex", .type = .string } },
        .handler = cursor_config.setColorHandler,
        .data = view,
    });
    inline for (@typeInfo(view_mod.Theme).@"struct".fields) |f| {
        if (config_kv.get("theme", f.name)) |blob| {
            if (config_load.firstConfigRecord(blob)) |hex| _ = view.theme.setColor(f.name, hex);
        }
    }

    var view_dirty = true;
    // Last activated buffer path (copied — the borrowed slice would dangle).
    var last_activate_path: [std.fs.max_path_bytes]u8 = undefined;
    var last_activate_len: usize = 0;
    var last_frame_rect: region.Rect = .{}; // last render's pane frame, for click routing
    // Liveness, the last-announced host fingerprint, the self-reconnect handle,
    // and the interactive-connect handle/hostport all live on `collab_state` now
    // (its deinit detaches the in-flight handles — a bounded, one-shot leak if a
    // connect worker still borrows the hostport). The status-line trust chip
    // reads its live grade from `known_peers`.
    var next_backing_poll_ns: u64 = 0;
    var last_active: core.Buffers.Id = buffers.active_id;
    // Menu-overlay (on_menu) edge detection: fire at the frame boundary when the
    // active menu mode changes, so a which-key plugin re-renders exactly on
    // enter/leave (and never nested inside another guest call).
    var menu_overlay: frame_mod.MenuOverlay = .{};
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

    // The frame BUILD's read/borrow surface — pointers to the stable state the
    // HUD + pane build read each frame (the per-frame active editor/buffer and
    // clock are passed as `frame.Active`). Owns nothing.
    const fx: frame_mod.FrameCtx = .{
        .gpa = gpa,
        .buffers = buffers,
        .caps = &session.caps,
        .keymap = &session.keymap,
        .pick = &session.pick,
        .echo = &session.echo,
        .hover_ui = &session.hover_ui,
        .cursor_cfg = &session.cursor_cfg,
        .plugins = &plugins,
        .conn = &collab_state.conn,
        .hub = &collab_state.hub,
        .collab_session = &collab_state.collab_session,
        .partial_state = &collab_state.partial_state,
        .ed0 = ed0,
        .known_peers = &known_peers,
        .noted_host_fp = &collab_state.noted_host_fp,
        .view_dirty = &view_dirty,
        .last_frame_rect = &last_frame_rect,
        .flash_gen = &flash_gen,
        .flash_start_ns = &flash_start_ns,
        .flash_was_active = &flash_was_active,
        .flash_duration_ns = flash_duration_ns,
    };

    std.log.info("weft: rendering — {d} bytes open, em {d}", .{ ed0.text().byteLen(), args.em });

    while (!window.shouldClose() and !session.quit) {
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
            try dispatch.dispatchKey(&session.cmd_ctx, view, ev, fb[1]);
        }
        if (window.shouldClose()) break;

        // Commands may have created/switched buffers; lazily attach
        // providers and damage the view on focus change.
        const abuf = buffers.active();
        try attachProviders(attach_deps, abuf);
        const editor = &abuf.editor;
        const attach: *Attach = @ptrCast(@alignCast(abuf.frontend.?));
        if (buffers.active_id != last_active) {
            last_active = buffers.active_id;
            view_dirty = true;
        }

        // ── Pointer → caret (click-to-place; drag extends a selection) ──
        if (try dispatch.handlePointer(window, win_layout, view, editor, &win_ctx, gpa, last_frame_rect, &drag_anchor, &drag_selecting, &had_input))
            view_dirty = true;

        // Caret blink: any input shows a solid caret and restarts the
        // timer; otherwise, when the current mode blinks, flip on each
        // period and damage the view.
        if (had_input) {
            blink_on = true;
            blink_next_ns = frame_start + blink_period_ns;
        } else if (session.cursor_cfg.blinkFor(session.keymap.currentMode()) and frame_start >= blink_next_ns) {
            blink_on = !blink_on;
            blink_next_ns = frame_start + blink_period_ns;
            view_dirty = true;
        }

        // ── Async housekeeping tick (backing/LSP/nav/pick/plugins/activate/menu) ──
        if (try frame_mod.tickAsync(&fx, abuf, attach, &session.cmd_ctx, &session.def_ui, &session.sym_ui, &plugin_loop, &next_backing_poll_ns, &last_activate_path, &last_activate_len, &menu_overlay, &which_key_now, which_key_delay_ns, frame_start))
            view_dirty = true;
        // ── Connect/disconnect/listen intents (outside the hot section:
        // connect blocks on TCP, disconnect joins threads). ──
        if (collab.applyIntents(&collab_state.share_ctx, &session.cmd_ctx, pool, &collab_state.connect_task, &collab_state.connect_hostport, &collab_state.fd_link, &session.echo, &my_identity, args.token, args.user))
            view_dirty = true;
        // ── Window-layout intents (outside the input hot section) ──
        if (window_cmds.applyIntents(&win_ctx, win_layout, view, buffers, gpa, &session.keymap, last_frame_rect))
            view_dirty = true;
        // ── Collab tick (adopt/publish/relay, partial fetch, peer-fs, reconnect) ──
        if (try collab.tickCollab(&collab_state.share_ctx, &session.cmd_ctx, ed0, win_layout, &collab_state.peer_fs_bridge, &collab_state.remote_fs, &collab_state.peer_fs_inflight, &collab_state.noted_host_fp, &collab_state.last_liveness, &collab_state.reconnect, &collab_state.next_reconnect_ns, &collab_state.fd_link, &my_identity, pool, args.connect, args.token, &session.echo))
            view_dirty = true;
        if (editor.doc.commitCount() != attach.seen_commits) {
            attach.seen_commits = editor.doc.commitCount();
            view_dirty = true;
        }
        if (had_input) view_dirty = true; // cursor moves damage the view

        // ── Rebuild + upload on damage (backend-independent build) ──
        try render.buildFrame(&fx, .{
            .editor = editor,
            .abuf = abuf,
            .attach = attach,
            .frame_start = frame_start,
            .fb = fb,
            .blink_on = blink_on,
            .menu_shown = menu_overlay.shown,
        });

        // ── Draw ── (the only GPU/swapchain touch; headless skips it)
        try render.present(ctx, fb, frame_start, had_input);
    }
    ctx.waitIdle();
}
