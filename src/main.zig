//! weft — the assembled editor: a Wayland window presenting a
//! `core.Editor` through the renderer-neutral view and Skia, all behavior
//! routed key → keymap → command ABI (built-ins and config/plugin
//! commands through the same door). The frame loop's only wait is the
//! swapchain (FIFO vsync); the input→commit→render path is bracketed by
//! the hot-section fence; frame + input latency percentiles log
//! continuously.
//!
//!   weft [file] [--font path.ttf] [--em N] [--plugin p.wasm]... [--config config.js]

const std = @import("std");
const core = @import("core/core.zig");
const view_mod = @import("gfx/view.zig");
const region = @import("gfx/region.zig");
const window_layout = @import("gfx/window_layout.zig");
const stats_mod = @import("gfx/stats.zig");
const stemma = @import("stemma");
const vk = @import("vk.zig").c;
const font_provider = @import("weft_font_provider");

const embedded_font = font_provider.defaultMono();

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
const window_head = @import("app/window_head.zig");
const application_mod = @import("app/application.zig");
const frame_mod = @import("app/frame.zig");
const collab = @import("app/collab.zig");
const collab_cmds = @import("app/collab_cmds.zig");
const loop_sources = @import("app/loop_sources.zig");
const scheduler = core.scheduler;
const hostTrustChip = collab.hostTrustChip;
const selectionAnchorOf = collab.selectionAnchorOf;
const identityHandler = collab_cmds.identityHandler;
const guiConfigure = collab.guiConfigure;
const providers = @import("app/providers.zig");
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

/// Host a second, minimal system ("agent-ux") on `host` — task #19 items
/// 1/4's live-swap gate, run against the REAL desktop session rather than
/// `core/System.zig`'s synthetic fixtures. `src` is `config/agent-ux.js`'s
/// already-read bytes. Mirrors `core/System.zig`'s own "the real
/// config/agent-ux.js manifest hosts a SECOND system end-to-end" gate test
/// almost exactly (a scoped, one-shot `wasm.Engine` for the eval, just like
/// `config_load.ConfigSession.reload`'s pattern — config is a startup
/// declaration, not a resident runtime) but against `Session.host` instead
/// of a bare test-local `Host`. Deliberately does NOT call `initPlugins` on
/// the new system (task #19 item 3: the second system stays plugin-free).
fn hostAgentUx(gpa: std.mem.Allocator, pool: *core.task.Pool, host: *core.System.Host, user: []const u8, src: []const u8) !void {
    const sys = try core.System.create(gpa, pool, "agent-ux", user);
    errdefer sys.destroy();
    var engine = try core.wasm.Engine.init(gpa);
    defer engine.deinit();
    var c = sys.contextFor(&sys.default_head);
    const m = try core.quickjs.evalToManifest(&engine, &c, null, &sys.config_kv, "config", src, .config, "agent-ux");
    {
        // The manifest errdefer must not outlive applyManifest: on success,
        // ownership of `m` moves into sys.applied_manifest, and sys.destroy()
        // (the outer errdefer) frees it — a still-armed m.destroy() on a later
        // failure (hostSystem OOM) would double-free.
        errdefer m.destroy();
        try sys.applyManifest(gpa, m, null);
    }
    try host.hostSystem(sys);
    std.log.info("agent-ux: hosted a second system from config/agent-ux.js ({d} bytes)", .{src.len});
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
            .file = args.file,
        }, init.minimal.environ);
    }

    // ── Core ──
    // Providers owns the config-extended grammar registry and the per-buffer
    // attach bundle. Its deinit is registered FIRST so it runs LAST: the
    // persistent remote shells must outlive the buffers whose backings + in-flight
    // save workers use them, and the pool whose workers may still hold one. The
    // registry exists now (before the session) so the session's capability
    // consumers can bind grammar-add onto it; attach_deps is built later, once
    // caps are known.
    var providers_state: providers.Providers = undefined;
    try providers_state.initRegistries(gpa);
    defer providers_state.deinit(gpa);
    var pool = try core.task.Pool.init(gpa, .{});
    defer pool.deinit();

    // ── Core editing state ──
    // `Session` owns the buffers, the command/keymap/pick surfaces, the caps
    // store, the echo line + quit flag, the capability-consumer UIs and the
    // caret config. Built IN PLACE (cmd_ctx borrows its siblings), it installs
    // the built-ins and binds the capability + caret/which-key commands in
    // registration order; its deinit frees them in the reverse order main()
    // used to. which-key's F1 "show the hint now" flag lives on
    // `session.menu_overlay` (per-head, beside `session.head` — see
    // `frame.MenuOverlay`'s field doc), not a separate local here.
    var session: Session = undefined;
    try session.init(gpa, pool, args.user, &providers_state.grammars);
    defer session.deinit(gpa);
    const buffers = &session.system.buffers;
    if (args.file) |path| {
        const b0 = buffers.active();
        const ed = b0.textEditor().?;
        gpa.free(b0.name);
        b0.name = try gpa.dupe(u8, std.fs.path.basename(path));
        if (args.connect != null) {
            // Remote document: the path is a NAME (language routing,
            // status line); content arrives over the wire from the
            // host. Nothing is read locally. A partial checkout keeps
            // the document virgin (adoptPartial replaces it wholesale).
            if (!args.partial) try ed.adoptPath(gpa, path);
        } else ed.openFile(gpa, path) catch |err| switch (err) {
            error.FileNotFound => {
                // New file: adopt the path, save creates it.
                try ed.adoptPath(gpa, path);
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
    const ed0 = buffers.active().textEditor().?;

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
    _ = try session.system.commands.bind(gpa, "identity", .{
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
    //
    // OWNED by `session.system` now (task #19 item 3: "plugin instances are
    // PER-SYSTEM" — `core.System.Plugins`), not bare `main()` locals — this
    // is a STRUCTURAL move only: the editor system is still the only one
    // that ever calls `initPlugins`/loads a plugin (agent-ux "stays
    // plugin-free" per the task). `plug` below is a convenience alias to
    // `session.system.plugins.?`, taken once, right after creation — it
    // stays valid even across a LATER `system-swap` (a raw pointer into the
    // editor System's heap-pinned allocation, not re-read through
    // `session.system`), which is exactly right: plugin ticking/streaming
    // is unconditionally editor-scoped regardless of which system the head
    // is currently attached to (agent-ux never gets its own).
    try session.system.initPlugins(pool);
    const plug = &session.system.plugins.?;
    // Give plugin `proc` children the parent PATH (nix tools like rg/zig).
    core.wasm_host.setEnviron(init.minimal.environ);
    const plugin_dir = config_load.pluginDir(gpa);
    defer gpa.free(plugin_dir);
    var plugin_host: config_load.PluginHost = .{
        .gpa = gpa,
        .engine = &plug.engine,
        .ctx = &session.cmd_ctx,
        // `.grant_table = &session.system.grants`
        // (doc/contextual-workspace-architecture.md §13.5 slice 4 —
        // "this slice makes grants REAL in the desktop"): the
        // production loader now mints every loaded plugin's perms as
        // REVOCABLE handle-table rows instead of bare booleans, and
        // couples with `Ctx.capture`'s already-wired `ctx.grant_table`
        // (`System.contextFor`) so the capture-time powerbox and a
        // plugin's own possession checks agree — see `ctx.zig`'s
        // `Ctx.grants` field doc for the coupling rule this closes.
        .opts = .{ .kv = &plug.kv, .config = &session.system.config_kv, .loop = &plug.loop, .subbuffers = &plug.subbuffers, .register = &plug.register, .syntax_of = resolveSyntax, .pool = pool, .grant_table = &session.system.grants },
        .list = &plug.list,
        .js_list = &plug.js_list,
        .dir = plugin_dir,
    };
    // The live `revoke`/`grants-show` debug commands
    // (doc/contextual-workspace-architecture.md §13.5 slice 4) — opt-in,
    // per-embedder wiring (see their own docs for why `builtins.install`
    // doesn't bind them unconditionally): bound onto the editor system now
    // that its grant table actually holds real, production-minted rows.
    try core.System.registerRevokeCommand(gpa, &session.system.commands, session.system);
    try core.System.registerGrantsShowCommand(gpa, &session.system.commands, session.system);
    // Explicit --plugin flags load first, in order.
    for (args.plugins[0..args.plugin_count]) |name| plugin_host.load(name);

    // ── User config: config.js in the quickjs.wasm sandbox (plan 06B) ──
    // The local plane, one tier down: `config.js` (via --config) wires keys
    // and actions, reaching the editor only through the `weft.*` grants — the
    // same door a plugin uses. It can also load plugins itself (`weft.plugin`),
    // so the sample config brings up its own vim/palette without --plugin. A
    // bare weft with no plugins is modeless. Absent or broken config is a
    // warning, never fatal.
    //
    // `config_session` outlives this block (held for the whole run) so
    // `config-reload` can `Manifest.reconcile` against the manifest actually
    // applied, rather than blindly re-running the JS program
    // (doc/configuration.md §5). Only wired when a config
    // path was given.
    var config_session: ?config_load.ConfigSession = null;
    defer if (config_session) |*cs| cs.deinit();
    if (args.config) |config_path| {
        config_session = config_load.ConfigSession.init(gpa, &session.cmd_ctx, config_path, plugin_host.loader(), &session.system.config_kv) catch |e| blk: {
            std.log.warn("config: {s} failed to load: {t}", .{ config_path, e });
            break :blk null;
        };
        // `weft.statusSegment` mesh reachability (doc/cwa-prior-docs-audit.md §5
        // item 3): binds straight into `session.system.container` — the same
        // shared Container `session.system.caps`/`.actions` already use.
        if (config_session) |*cs| cs.ui_bind = .{ .ctx = &session.system.container, .bind = view_mod.ui_mesh.bindManifestSegment };
        if (config_session) |*cs| cs.reload() catch |e|
            std.log.warn("config: {s} failed to load: {t}", .{ config_path, e });
        if (config_session) |*cs| _ = try session.system.commands.bind(gpa, "config-reload", .{
            .name = "config-reload",
            .summary = "Reload config.js, reconciled against the manifest last applied.",
            .args = &.{},
            .handler = config_load.configReloadHandler,
            .data = cs,
        });
    }
    // The config's editor plugin (vim/helix) has set the base editing mode by
    // now; capture it as the mode fresh buffers open in, so a tool buffer's
    // mode (files/git) can never leak into a file opened from it.
    session.system.buffers.setDefaultMode(gpa, session.head.currentMode()) catch {};

    // ── A second hosted system: agent-ux (doc/cwa-prior-docs-audit.md §5)
    // ── A minimal SECOND system, hosted alongside "editor" on the SAME
    // `session.host` — proves `system-swap` works on the REAL desktop
    // session, not just `System.zig`'s synthetic gate fixtures.
    // `config/agent-ux.js` is a dev-checkout GATE FIXTURE, not an installed
    // file (see its own module doc — no `build.zig install` rule ships it);
    // a missing/broken read degrades to a warning, never fatal, same as
    // `--config`. Deliberately minimal — "a few binds, no heavy plugins" —
    // so this costs nothing when absent and stays plugin-free when present
    // (task #19 item 3: the SECOND system never calls `initPlugins`).
    if (core.file.readAlloc(gpa, "config/agent-ux.js")) |src| {
        defer gpa.free(src);
        hostAgentUx(gpa, pool, &session.host, args.user, src) catch |e|
            std.log.warn("agent-ux: failed to host: {t}", .{e});
    } else |_| {}
    // The `system-swap <name>` command — SHADOWS `core.System.
    // registerSwapCommand` (registry last-wins, same pattern
    // `buffers_cmds.zig` uses): identical surface, but additionally refuses
    // while a live collab connection is bound to the CURRENT system's
    // Document (task #19 item 2). Bound onto EVERY hosted system's command
    // table (not just "editor"'s) so a head that swapped onto agent-ux can
    // swap BACK — see `Session.SwapCmdData`'s doc. `swap_data`'s address is
    // stable for the run (a `main()` local); every system's binding shares
    // the same `data` pointer.
    var swap_data: session_mod.Session.SwapCmdData = .{ .session = &session };
    for (session.host.systems.values()) |sys| {
        _ = try sys.commands.bind(gpa, "system-swap", .{
            .name = "system-swap",
            .summary = "Re-bind this head to another hosted system (refuses on an open transient/menu or a live collab connection).",
            .args = &.{.{ .name = "name", .type = .string }},
            .handler = session_mod.Session.systemSwapHandler,
            .data = &swap_data,
        });
    }

    // ── Per-buffer providers (syntax + LSP hang off Buffer.frontend) ──
    // Phase two of `providers_state`: build attach_deps in place (it borrows the
    // session caps + the connect placement — for a remote-hosted document the
    // server runs on the host peer and diagnostics arrive as the imported host
    // feed, so no local LSP). detachProviders runs here (before Session.deinit,
    // while caps + buffers' docs are alive); the shells live on, freed last by
    // providers_state.deinit.
    // W0b: swap-blocking — `AttachDeps.caps` is a long-lived borrow of the
    // EDITOR system's caps, baked once here. Providers/LSP attach is
    // structurally editor-only (agent-ux never gets a `--file`/providers
    // pass); not repointed on swap — see `fx`'s doc below for the full
    // borrow-audit finding this is one instance of.
    providers_state.initAttach(gpa, &session.system.caps, init.minimal.environ);
    const attach_deps = &providers_state.attach_deps;
    defer {
        var det_it = buffers.iterator();
        while (det_it.next()) |b| detachProviders(attach_deps, b);
    }
    try attachProviders(attach_deps, buffers.active());
    // The graphical shell's open/close know about providers and remote
    // shells; they shadow the core versions (registry last-wins).
    var buffer_command_context: buffers_cmds.Context = .{
        .attachments = attach_deps,
        .directories = .{
            .context = &session,
            .open = Session.openLocalDirectoryOpaque,
        },
    };
    try buffers_cmds.registerCommands(gpa, &session.system.commands, &buffer_command_context);

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
    // W0b: swap-blocking — `ShareCtx.buffers`/`.caps` are long-lived borrows
    // of the EDITOR system, baked once here; NOT repointed on swap. This is
    // exactly why `system-swap`'s refusal (task #19 item 2, wired below via
    // `Collab.isLiveOpaque`) exists: a swap while a connection is LIVE would
    // otherwise leave it silently bound to a system's buffers that stopped
    // being the one dispatch/rendering targets. While dormant (no
    // connection), the stale borrow is inert.

    // This is the interactive editor, so sharing pre-selects presence and every
    // share path says so; `--no-share-presence`, `weft.set("collab",
    // "share-presence", "off")`, and the `share-presence` command each opt out.
    const share_presence = collab.presenceDefault(args.share_presence, blk: {
        const raw = session.system.config_kv.get("collab", "share-presence") orelse break :blk null;
        break :blk config_load.firstConfigRecord(raw);
    });
    var collab_state: collab.Collab = undefined;
    collab_state.initBase(gpa, buffers, &session.system.caps, &known_peers, args.share_root, args.share_fs, share_presence, args.listen, args.access);
    defer collab_state.deinit(gpa);
    try collab_state.connect(gpa, ed0, &session.system.caps, &my_identity, args.connect, args.token, args.user, args.partial);
    // The buffer close path unbinds shares before the doc dies (Providers borrows
    // the share surface).
    attach_deps.share = &collab_state.share_ctx;
    try collab_cmds.registerCommands(gpa, &session.system.commands, &collab_state.share_ctx, &known_peers);
    // `system-swap`'s live-collab refusal (task #19 item 2) — wired NOW that
    // `collab_state` exists at a stable address; `swap_data` was bound onto
    // every hosted system's commands earlier with this predicate unset
    // (always-allow) because collab doesn't exist yet that early. Nothing
    // reads `isBlocked` before the frame loop starts, so the gap is inert.
    swap_data.blocked_ctx = &collab_state;
    swap_data.isBlocked = collab.Collab.isLiveOpaque;
    // Window layout: a recursive split tree over the region geometry. Core
    // commands only RECORD intent on `win_ctx`; the frame loop applies them
    // (splitFocused/closeFocused/focus/move by pane geometry) and keeps the
    // focused pane == the active buffer. The legacy names
    // (split/vsplit/unsplit/focus-other) alias onto the same intents so the
    // prebuilt `windows` .wasm plugin and older configs keep working.
    var win_ctx: window_cmds.WindowCtx = .{};
    // Stable storage so each command's `data` pointer stays valid for the run.
    var window_action_ctx: [window_cmds.cmd_count]window_cmds.WindowActionCtx = undefined;
    try window_cmds.registerCommands(gpa, &session.system.commands, &win_ctx, &window_action_ctx);

    // ── Window + Vulkan + Rasterizer, as ONE unit: the window-head (W0b,
    //    doc/extensibility-native-surface.md) — an in-process client owning the
    //    platform attachment, under its own named identity. See
    //    `app/window_head.zig`'s module doc for what this does and
    //    deliberately does NOT extract (the frame loop stays here).
    const font_bytes: []const u8 = if (args.font) |p| try core.file.readAlloc(gpa, p) else embedded_font;
    defer if (args.font != null) gpa.free(@constCast(font_bytes));
    var whead: window_head.WindowHead = undefined;
    try whead.init(gpa, &session.cmd_ctx, 1280, 800, font_bytes, args.em, buffers.active_id);
    defer whead.deinit();
    // The swapchain's actual extent is authoritative: a server-side-deco or
    // tiling compositor can force it to differ from the requested framebuffer
    // size. Drive all render geometry (layout, MVP, surface size) from it — from
    // frame one — so nothing mis-scales.
    var fb: [2]u32 = .{ whead.ctx.extent.width, whead.ctx.extent.height };
    // `view`/`win_layout` alias `whead.render.fb.*` — non-owning borrows so
    // the frame loop reads them unchanged regardless of backend.
    const view = &whead.render.fb.view;
    const win_layout = &whead.render.fb.win_layout;

    // Scrolling commands need the view + framebuffer (which core commands
    // don't see), so they're registered here. `view.top_row` is always the
    // focused pane's scroll.
    var scroll_ctx: scroll.ScrollCtx = .{ .view = view, .fb = &fb };
    try scroll.registerCommands(gpa, &session.system.commands, &scroll_ctx);

    // Vertical motion + paging are view-computed (goal-x over rendered geometry,
    // which the core can't see). Register them as commands carrying the live
    // `view`: `cursor-up`/`cursor-down` SHADOW the core scalar versions by late
    // binding, and `scroll-page-*` are ordinary commands — so key dispatch is
    // pure keymap→command with no name special-case. Page binds in the GLOBAL
    // layer, so it works in every mode as the old hardcoded keysym branch did.
    const view_cmds = [_]core.command.Command{
        .{ .name = "cursor-up", .summary = "Move up one visual line (goal-x).", .args = &.{}, .handler = dispatch.cursorUpHandler, .data = view },
        .{ .name = "cursor-down", .summary = "Move down one visual line (goal-x).", .args = &.{}, .handler = dispatch.cursorDownHandler, .data = view },
        .{ .name = "scroll-page-up", .summary = "Move up one page.", .args = &.{}, .handler = dispatch.scrollPageUpHandler, .data = view },
        .{ .name = "scroll-page-down", .summary = "Move down one page.", .args = &.{}, .handler = dispatch.scrollPageDownHandler, .data = view },
    };
    for (view_cmds) |vc| _ = try session.system.commands.bind(gpa, vc.name, vc);
    try session.system.keymap.bind(gpa, core.Keymap.global_mode, "Page_Up", "scroll-page-up", core.Keymap.prio_core, "shell");
    try session.system.keymap.bind(gpa, core.Keymap.global_mode, "Page_Down", "scroll-page-down", core.Keymap.prio_core, "shell");

    // Theme is DATA: a runtime/bindable `set-color <name> <#hex>`, plus colors
    // the config staged declaratively via weft.set("theme", "<field>", "#hex").
    // Re-linearized per-field on mutation (Theme.setColor), so the draw path
    // stays a plain lookup.
    _ = try session.system.commands.bind(gpa, "set-color", .{
        .name = "set-color",
        .summary = "Set a theme color (name, #rrggbb).",
        .args = &.{ .{ .name = "name", .type = .string }, .{ .name = "hex", .type = .string } },
        .handler = cursor_config.setColorHandler,
        .data = view,
    });
    inline for (@typeInfo(view_mod.Theme).@"struct".fields) |f| {
        if (session.system.config_kv.get("theme", f.name)) |blob| {
            if (config_load.firstConfigRecord(blob)) |hex| _ = view.theme.setColor(f.name, hex);
        }
    }

    // Liveness, the last-announced host fingerprint, the self-reconnect handle,
    // and the interactive-connect handle/hostport all live on `collab_state` now
    // (its deinit detaches the in-flight handles — a bounded, one-shot leak if a
    // connect worker still borrows the hostport). The status-line trust chip
    // reads its live grade from `known_peers`.
    // Menu-overlay (on_menu) edge detection: fire at the frame boundary when the
    // active menu mode changes, so a which-key plugin re-renders exactly on
    // enter/leave (and never nested inside another guest call). Per-head
    // storage: `session.menu_overlay` lives beside `session.head` (see
    // `Session`'s doc — doc/contextual-workspace-architecture.md §7).
    // which-key idle delay (doom-style): don't pop the hint until the menu has
    // been held this long — unless which-key-now (F1) forces it. Config sets it
    // via weft.set("which_key", "delay-ms", "200") — owned by the which_key
    // plugin's namespace, not the old "editor" grab-bag (doc/configuration.md §7's
    // forcing-function finding: every config value needs an owner).
    const which_key_delay_ns: u64 = blk: {
        if (session.system.config_kv.get("which_key", "delay-ms")) |raw| {
            if (config_load.firstConfigRecord(raw)) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |ms| break :blk ms * std.time.ns_per_ms else |_| {}
            }
        }
        break :blk 200 * std.time.ns_per_ms;
    };
    // vim-goggles flash timing: a guest sets a range via wl_flash; we draw it
    // for `flash-ms` then clear it. Duration is config (default 150ms).
    const flash_duration_ns: u64 = blk: {
        if (session.system.config_kv.get("editor", "flash-ms")) |raw| {
            if (config_load.firstConfigRecord(raw)) |s| {
                if (std.fmt.parseInt(u64, s, 10)) |ms| break :blk ms * std.time.ns_per_ms else |_| {}
            }
        }
        break :blk 150 * std.time.ns_per_ms;
    };
    // Platform input and network services plug into the one application
    // lifecycle. They contribute events/effects; neither can select, skip, or
    // reorder async, menu, picker, layout, or build phases.
    const PointerInput = struct {
        window: @TypeOf(whead.window),
        drag_anchor: ?usize = null,
        drag_selecting: bool = false,

        fn run(raw: ?*anyopaque, app: *application_mod.Application, active: frame_mod.Driver.Prepared) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            var had_input = false;
            _ = try dispatch.handlePointer(
                self.window,
                app.driver.layout,
                &app.session.head,
                &app.session.system.semantic,
                app.driver.view,
                active.editor,
                app.driver.window_ctx,
                app.driver.ctx.gpa,
                app.last_frame_rect,
                &self.drag_anchor,
                &self.drag_selecting,
                &had_input,
            );
            return had_input;
        }
    };
    var pointer_input: PointerInput = .{ .window = whead.window };

    const DesktopServices = struct {
        state: *collab.Collab,
        pool: *core.task.Pool,
        identity: *const core.identity.Identity,
        connect: ?[]const u8,
        token: []const u8,
        user: []const u8,

        fn run(raw: ?*anyopaque, app: *application_mod.Application, _: frame_mod.Driver.Prepared) anyerror!bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const state = self.state;
            var damaged = collab.applyIntents(
                &state.share_ctx,
                &app.session.cmd_ctx,
                self.pool,
                &state.connect_task,
                &state.connect_hostport,
                &state.fd_link,
                app.session.echo(),
                self.identity,
                self.token,
                self.user,
            );
            if (try collab.tickCollab(
                &state.share_ctx,
                &app.session.cmd_ctx,
                app.driver.ctx.ed0,
                app.driver.layout,
                &state.peer_fs_bridge,
                &state.remote_fs,
                &state.peer_fs_inflight,
                &state.noted_host_fp,
                &state.last_liveness,
                &state.reconnect,
                &state.next_reconnect_ns,
                &state.fd_link,
                self.identity,
                self.pool,
                self.connect,
                self.token,
                app.session.echo(),
            )) damaged = true;
            if (state.reconcileRemoteFilesystem(app.session.system) catch |err| blk: {
                std.log.warn("peer filesystem publication unavailable: {t}", .{err});
                break :blk false;
            }) damaged = true;
            return damaged;
        }
    };
    var desktop_services: DesktopServices = .{
        .state = &collab_state,
        .pool = pool,
        .identity = &my_identity,
        .connect = args.connect,
        .token = args.token,
        .user = args.user,
    };

    var application: application_mod.Application = undefined;
    application.init(.{
        .gpa = gpa,
        .session = &session,
        .attach_deps = attach_deps,
        .plugin_loop = &plug.loop,
        .js_plugins = &plug.js_list,
        .plugins = &plug.list,
        .conn = &collab_state.conn,
        .hub = &collab_state.hub,
        .collab_session = &collab_state.collab_session,
        .partial_state = &collab_state.partial_state,
        .ed0 = ed0,
        .known_peers = &known_peers,
        .noted_host_fp = &collab_state.noted_host_fp,
        .window_ctx = &win_ctx,
        .layout = win_layout,
        .view = view,
        .which_key_delay_ns = which_key_delay_ns,
        .flash_duration_ns = flash_duration_ns,
        .before_async = .{ .context = &pointer_input, .run = PointerInput.run },
        .services = .{ .context = &desktop_services, .run = DesktopServices.run },
    });

    std.log.info("weft: rendering — {d} bytes open, em {d}", .{ ed0.text().byteLen(), args.em });

    // ── The scheduler (doc/contextual-workspace-architecture.md §7):
    // registered SOURCES, one poll()-based wait per iteration.
    // `main()`'s per-wake body below is UNCHANGED from the pre-scheduler
    // loop (same input→commit→build→ present shape) except: it now runs
    // once per genuine wake (an fd ready, or a deadline reached) instead
    // of once per vsync regardless of whether anything happened, and the
    // final present is gated on `render.fb.rebuilt` (see
    // `loop_sources.zig`'s module doc + the per-source doc comments
    // below for the old clock-polled site each timer replaces).
    var sched = scheduler.Scheduler.init(gpa, stats_mod.nowNs);
    defer sched.deinit();

    // fd sources: the wayland display socket (already non-blocking; the
    // scheduler only needs to know it's a wake reason — the actual pump
    // stays in the body, unconditional, below) and the task pool's
    // completion signal (real push wakeup — §6 W2a-3 item 3).
    _ = try sched.addFd(whead.window.fd(), .{ .read = true }, null, loop_sources.noopFdReady, "wayland");
    const pool_wake_fd = try scheduler.newWakeFd();
    defer scheduler.closeWakeFd(pool_wake_fd);
    pool.setNotifyFd(pool_wake_fd);
    _ = try sched.addFd(pool_wake_fd, .{ .read = true }, null, null, "pool");

    // Reified timers (§6 W2a-3 item 2) — see loop_sources.zig for the old
    // clock-polled site each one replaces.
    var blink_ctx: loop_sources.BlinkCtx = .{
        .cursor_cfg = &session.cursor_cfg,
        .keymap = &session.system.keymap,
        .head = &session.head,
        .blink_next_ns = application.blinkDeadline(),
    };
    _ = try sched.addTimer(&blink_ctx, loop_sources.blinkDue, "caret_blink");
    _ = try sched.addTimer(whead.window, loop_sources.keyRepeatDue, "key_repeat");
    var which_key_ctx: loop_sources.WhichKeyCtx = .{ .menu = &session.menu_overlay, .delay_ns = which_key_delay_ns };
    _ = try sched.addTimer(&which_key_ctx, loop_sources.whichKeyDue, "which_key_delay");
    _ = try sched.addTimer(&application.next_backing_poll_ns, loop_sources.backingPollDue, "backing_poll");
    var flash_ctx: loop_sources.FlashCtx = .{ .flash_start_ns = &application.flash_start_ns, .flash_duration_ns = flash_duration_ns };
    _ = try sched.addTimer(&flash_ctx, loop_sources.flashDue, "flash_expiry");
    var reconnect_ctx: loop_sources.ReconnectCtx = .{
        .share_ctx = &collab_state.share_ctx,
        .next_reconnect_ns = &collab_state.next_reconnect_ns,
        .connect_arg = args.connect,
    };
    _ = try sched.addTimer(&reconnect_ctx, loop_sources.reconnectDue, "reconnect_backoff");
    _ = try sched.addTimer(&session.head, loop_sources.pickDebounceDue, "pick_debounce");
    _ = try sched.addTimer(&plug.loop, loop_sources.pluginLoopDue, "plugin_loop_timers");
    var plugin_stream_ctx: loop_sources.PluginStreamCtx = .{ .plugins = &plug.list, .js_plugins = &plug.js_list };
    _ = try sched.addTimer(&plugin_stream_ctx, loop_sources.pluginStreamDue, "plugin_stream_poll");

    // Present discipline (§6 W2a-3 item 4): `present_pending` is set once a
    // frame is actually built, and cleared once `render.present` reports
    // it submitted one; while pending, the retry source below demands an
    // immediate re-check (the fence-poll in `Context.beginFrame` never
    // blocks, so this is a tight but self-limiting loop, not a busy spin —
    // it only runs while there is genuinely a frame waiting to go out).
    // Suppressed while `ctx.swapchain_stale` at a zero extent — see
    // `PresentRetryCtx`'s doc for why that guard is load-bearing, not
    // cosmetic.
    var present_pending = false;
    var present_retry_ctx: loop_sources.PresentRetryCtx = .{ .pending = &present_pending, .swapchain_stale = &whead.ctx.swapchain_stale };
    _ = try sched.addTimer(&present_retry_ctx, loop_sources.presentRetryDue, "present_retry");

    // The outbound session's wake-fd (§6 W2a-3 item 3) exists for the whole
    // run regardless of whether a session is bound to it yet (`Collab`
    // creates it in `initBase`) — register it once, unconditionally;
    // nothing signals it until `Session.setWakeFd` wires an actual session
    // (see collab.zig's `connect`/`runtimeConnectFinish`/reconnect-rebind).
    if (collab_state.share_ctx.conn_wake_fd >= 0)
        _ = try sched.addFd(collab_state.share_ctx.conn_wake_fd, .{ .read = true }, null, null, "conn");
    // The hub's eventfd, by contrast, doesn't exist until the Hub struct
    // itself does (--listen at boot, or the `listen` command at runtime) —
    // tracked so it's registered/removed exactly once per transition.
    var hub_src_id: ?scheduler.Id = null;

    while (!whead.window.shouldClose() and !session.system.quit) {
        _ = try sched.step();
        const frame_start = stats_mod.nowNs();
        whead.window.pumpEvents();

        // A configure callback has already acked xdg_surface and committed
        // the newest usable geometry before this edge is visible. Recreate
        // before building a frame; no present may use retired resources.
        const resized = whead.window.consumeResized();
        const req = whead.window.framebufferSize();
        // A zero-size surface has no work to retry: do not queue-idle on
        // every scheduler wake while the stale marker is intentionally held.
        if (resized or (whead.ctx.swapchain_stale and req[0] != 0 and req[1] != 0)) {
            whead.ctx.recreateSwapchain(req[0], req[1]) catch |e| switch (e) {
                // Zero-size surface: the swapchain is torn down and can't be
                // recreated yet. Skip this frame until a usable extent arrives
                // (don't render into a destroyed swapchain).
                error.ZeroExtent => {
                    whead.ctx.swapchain_stale = true;
                    // Nothing is presentable at zero extent — drop any
                    // latched present so `present_retry` (also gated on
                    // `swapchain_stale` directly, belt-and-suspenders)
                    // has nothing to spin on. The next real resize sets
                    // application damage unconditionally, which re-latches this
                    // through the ordinary dirty path once there's an
                    // actual frame to show again.
                    present_pending = false;
                    continue;
                },
                else => return e,
            };
            // Any frame latched before the configure was for the old extent;
            // only the frame built below may be presented on this swapchain.
            present_pending = false;
            // Geometry follows the swapchain's actual extent, not the request.
            fb = .{ whead.ctx.extent.width, whead.ctx.extent.height };
            application.damage();
        }

        // ── Input → commit ──
        // The hot-section fence (no-blocking guarantee) is entered
        // narrowly inside dispatchKey around the typing/commit path, not
        // here: a bound key can also trigger a deliberately-blocking
        // control command (open a file, save), and those must be allowed
        // to block. See dispatchKey. `whead.dispatchKey` (not
        // `dispatch.dispatchKey` directly) brackets the call under the
        // window-head's `InProcClient` identity (W0b item 3) — see
        // `app/window_head.zig`'s module doc.
        while (whead.window.nextKeyEvent()) |ev| {
            if (!ev.pressed) continue;
            try whead.dispatchKey(&session.cmd_ctx, ev);
            application.noteInput();
        }
        if (whead.window.shouldClose()) break;

        // One application wake owns every platform-neutral phase through the
        // completed scene. The desktop contributes input and collaboration via
        // the hooks installed above; the same call is used by headless capture.
        const advanced = try application.advance(&whead.render, .{
            .frame_start = frame_start,
            .fb = fb,
        });
        // The hub's wake-fd source tracks the Hub struct's own lifetime
        // (listen/stop-listen, connect/disconnect are all funneled through
        // `applyIntents`/`tickCollab` above) — reconcile once per wake.
        if (collab_state.hub != null and hub_src_id == null) {
            hub_src_id = try sched.addFd(collab_state.hub.?.wake_fd, .{ .read = true }, null, null, "hub");
        } else if (collab_state.hub == null and hub_src_id != null) {
            sched.removeFd(hub_src_id.?);
            hub_src_id = null;
        }
        // ── Draw ── (the only GPU/swapchain touch; headless skips it)
        // Present discipline (§6 W2a-3 item 4): only when a frame was
        // actually built this wake or one is still outstanding from a
        // deferred retry — an idle editor with nothing dirty submits
        // NOTHING, vsync or not. `render.present` itself never blocks on
        // the GPU fence (`Context.beginFrame`'s zero-timeout poll); a
        // `false` return means it deferred, and `present_pending` stays
        // set so the `present_retry` timer source demands an immediate
        // recheck next step.
        present_pending = present_pending or whead.render.fb.rebuilt;
        if (present_pending) {
            if (try whead.render.present(whead.ctx, fb, frame_start, advanced.had_input)) present_pending = false;
        }
    }
    whead.ctx.waitIdle();
}
