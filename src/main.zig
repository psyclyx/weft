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

const Args = struct {
    file: ?[]const u8 = null,
    font: ?[]const u8 = null,
    config: ?[]const u8 = null,
    /// `.wasm` plugin paths to load at startup, in order (repeatable
    /// `--plugin`). weft ships modeless; a plugin is loaded only when named.
    /// argv is static, so these slices stay valid for the run.
    plugins: [32][]const u8 = undefined,
    plugin_count: usize = 0,
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
    /// --share-root <dir>: opt in to serving a filesystem root to peers over
    /// collab (dired-on-a-peer, remote fs). Null = don't serve any fs — the
    /// SAFE default (a peer gets nothing). fs access is separate from --access
    /// (that gates the document).
    share_root: ?[]const u8 = null,
    /// --share-fs <none|read|rw>: the access peers get to --share-root. Default
    /// none (deny) even when a root is set, so sharing is a deliberate choice.
    share_fs: core.peer_fs.Access = .none,
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
        } else if (std.mem.eql(u8, a, "--plugin")) {
            if (it.next()) |v| if (out.plugin_count < out.plugins.len) {
                out.plugins[out.plugin_count] = v;
                out.plugin_count += 1;
            };
        } else if (std.mem.eql(u8, a, "--em")) {
            if (it.next()) |v| out.em = std.fmt.parseFloat(f32, v) catch out.em;
        } else if (std.mem.eql(u8, a, "--listen")) {
            if (it.next()) |v| out.listen = std.fmt.parseInt(u16, v, 10) catch null;
        } else if (std.mem.eql(u8, a, "--access")) {
            if (it.next()) |v| out.access = core.session.Access.parse(v) orelse out.access;
        } else if (std.mem.eql(u8, a, "--share-root")) {
            out.share_root = it.next() orelse out.share_root;
        } else if (std.mem.eql(u8, a, "--share-fs")) {
            if (it.next()) |v| out.share_fs = if (std.mem.eql(u8, v, "read"))
                .read
            else if (std.mem.eql(u8, v, "rw") or std.mem.eql(u8, v, "read_write"))
                .read_write
            else
                .none;
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
    // Capability consumers — written against capability names only.
    var completion_ui: core.complete_ui.CompletionUi = .empty;
    _ = try commands.bind(gpa, "complete", completion_ui.commandSpec());
    var def_ui: core.nav_ui.DefinitionUi = .empty;
    _ = try commands.bind(gpa, "goto-definition", def_ui.commandSpec());
    var sym_ui: core.nav_ui.SymbolsUi = .empty;
    defer sym_ui.deinit(gpa);
    _ = try commands.bind(gpa, "symbols", sym_ui.commandSpec());
    var hover_ui: core.nav_ui.HoverUi = .empty;
    defer hover_ui.deinit(gpa);
    _ = try commands.bind(gpa, "hover", hover_ui.commandSpec());

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
    _ = try commands.bind(gpa, "menu-escape", .{
        .name = "menu-escape",
        .summary = "Leave a menu, back to its return mode.",
        .args = &.{},
        .handler = menuEscapeHandler,
        .data = null,
    });
    // which-key: show the hint popup immediately (bypass the idle delay). If not
    // already in a menu, open the leader menu — so a help key (F1) surfaces it
    // from anywhere.
    var which_key_now = false;
    _ = try commands.bind(gpa, "which-key-now", .{
        .name = "which-key-now",
        .summary = "Show the which-key popup now (open the leader menu if idle).",
        .args = &.{},
        .handler = whichKeyNowHandler,
        .data = &which_key_now,
    });
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
    const plugin_dir = pluginDir(gpa);
    defer gpa.free(plugin_dir);
    const module_cache_dir = moduleCacheDir(gpa);
    defer if (module_cache_dir) |d| gpa.free(d);
    var plugin_host: PluginHost = .{
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
        loadJsConfig(gpa, &cmd_ctx, config_path, plugin_host.loader(), &config_kv) catch |e|
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
    _ = try commands.bind(gpa, "verify-peer", .{
        .name = "verify-peer",
        .summary = "Mark a peer fingerprint verified (after comparing its SAS out of band).",
        .args = &.{.{ .name = "fingerprint", .type = .string }},
        .handler = verifyPeerHandler,
        .data = &known_peers,
    });
    _ = try commands.bind(gpa, "forget-peer", .{
        .name = "forget-peer",
        .summary = "Revoke trust in a peer fingerprint (removes it from known_peers).",
        .args = &.{.{ .name = "fingerprint", .type = .string }},
        .handler = forgetPeerHandler,
        .data = &known_peers,
    });
    _ = try commands.bind(gpa, "peers", .{
        .name = "peers",
        .summary = "List connected peers with fingerprint, SAS words, and trust.",
        .args = &.{},
        .handler = peersHandler,
        .data = &share_ctx,
    });
    _ = try commands.bind(gpa, "cancel", .{
        .name = "cancel",
        .summary = "Abort a pending/in-flight connect and drop queued host intents.",
        .args = &.{},
        .handler = cancelHandler,
        .data = &share_ctx,
    });
    _ = try commands.bind(gpa, "grant", .{
        .name = "grant",
        .summary = "Set a connected peer's grade by fingerprint (view|edit|own).",
        .args = &.{ .{ .name = "fingerprint", .type = .string }, .{ .name = "grade", .type = .string } },
        .handler = grantHandler,
        .data = &share_ctx,
    });
    // Window layout: a recursive split tree over the region geometry. Core
    // commands only RECORD intent on `win_ctx`; the frame loop applies them
    // (splitFocused/closeFocused/focus/move by pane geometry) and keeps the
    // focused pane == the active buffer. The legacy names
    // (split/vsplit/unsplit/focus-other) alias onto the same intents so the
    // prebuilt `windows` .wasm plugin and older configs keep working.
    var win_ctx: WindowCtx = .{};
    const window_cmd_table = [_]struct { name: []const u8, action: WindowAction, summary: []const u8 }{
        .{ .name = "window-split", .action = .split, .summary = "Split the focused window horizontally (a pane below)." },
        .{ .name = "window-vsplit", .action = .vsplit, .summary = "Split the focused window vertically (a pane beside)." },
        .{ .name = "window-close", .action = .close, .summary = "Close the focused window, collapsing its split." },
        .{ .name = "window-focus-left", .action = .focus_left, .summary = "Focus the window to the left." },
        .{ .name = "window-focus-right", .action = .focus_right, .summary = "Focus the window to the right." },
        .{ .name = "window-focus-up", .action = .focus_up, .summary = "Focus the window above." },
        .{ .name = "window-focus-down", .action = .focus_down, .summary = "Focus the window below." },
        .{ .name = "window-move-left", .action = .move_left, .summary = "Swap the focused window with its left neighbor." },
        .{ .name = "window-move-right", .action = .move_right, .summary = "Swap the focused window with its right neighbor." },
        .{ .name = "window-move-up", .action = .move_up, .summary = "Swap the focused window with the one above." },
        .{ .name = "window-move-down", .action = .move_down, .summary = "Swap the focused window with the one below." },
        .{ .name = "split", .action = .split, .summary = "Split the focused window horizontally." },
        .{ .name = "vsplit", .action = .vsplit, .summary = "Split the focused window vertically." },
        .{ .name = "unsplit", .action = .close, .summary = "Close the focused window." },
        .{ .name = "focus-other", .action = .focus_next, .summary = "Focus the next window." },
    };
    // Stable storage so each command's `data` pointer stays valid for the run.
    var window_action_ctx: [window_cmd_table.len]WindowActionCtx = undefined;
    inline for (window_cmd_table, 0..) |wc, i| {
        window_action_ctx[i] = .{ .win = &win_ctx, .action = wc.action };
        _ = try commands.bind(gpa, wc.name, .{
            .name = wc.name,
            .summary = wc.summary,
            .args = &.{},
            .handler = windowActionHandler,
            .data = &window_action_ctx[i],
        });
    }

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
    var scroll_ctx: ScrollCtx = .{ .view = &view, .fb = &fb };
    inline for (.{
        .{ "scroll-line-down", "Scroll down one line.", scrollLineDown },
        .{ "scroll-line-up", "Scroll up one line.", scrollLineUp },
        .{ "scroll-half-down", "Scroll down half a page (moves the cursor).", scrollHalfDown },
        .{ "scroll-half-up", "Scroll up half a page (moves the cursor).", scrollHalfUp },
        .{ "scroll-page-down", "Scroll down a page (moves the cursor).", scrollPageDown },
        .{ "scroll-page-up", "Scroll up a page (moves the cursor).", scrollPageUp },
        .{ "center-line", "Center the current line in the viewport.", centerLine },
    }) |spec| {
        _ = try commands.bind(gpa, spec[0], .{
            .name = spec[0],
            .summary = spec[1],
            .args = &.{},
            .handler = spec[2],
            .data = &scroll_ctx,
        });
    }

    // Theme is DATA: a runtime/bindable `set-color <name> <#hex>`, plus colors
    // the config staged declaratively via weft.set("theme", "<field>", "#hex").
    // Re-linearized per-field on mutation (Theme.setColor), so the draw path
    // stays a plain lookup.
    _ = try commands.bind(gpa, "set-color", .{
        .name = "set-color",
        .summary = "Set a theme color (name, #rrggbb).",
        .args = &.{ .{ .name = "name", .type = .string }, .{ .name = "hex", .type = .string } },
        .handler = setColorHandler,
        .data = &view,
    });
    inline for (@typeInfo(view_mod.Theme).@"struct".fields) |f| {
        if (config_kv.get("theme", f.name)) |blob| {
            if (firstConfigRecord(blob)) |hex| _ = view.theme.setColor(f.name, hex);
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
            if (firstConfigRecord(raw)) |s| {
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
            if (firstConfigRecord(raw)) |s| {
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
        if (share_ctx.cancel_requested) {
            share_ctx.cancel_requested = false;
            if (share_ctx.pending_connect) |hp| {
                gpa.free(hp);
                share_ctx.pending_connect = null;
            }
            share_ctx.pending_listen = null;
            if (connect_task) |*h| {
                h.detach(); // worker still borrows connect_hostport → leak it
                connect_task = null;
                connect_hostport = null;
                setEcho(&echo_line, gpa, "canceled");
            }
            view_dirty = true;
        }
        if (share_ctx.pending_connect) |hostport| {
            share_ctx.pending_connect = null;
            // Already connected or connecting → drop the request. Otherwise
            // kick the TCP connect onto the pool (never on the frame thread).
            if (collab_session != null or connect_task != null) {
                gpa.free(hostport);
            } else if (pool.spawn(reconnectTask, .{hostport})) |h| {
                connect_task = h;
                connect_hostport = hostport; // freed when the handle is polled
                setEcho(&echo_line, gpa, "connecting…");
            } else |_| {
                gpa.free(hostport);
                setEcho(&echo_line, gpa, "connect: out of memory");
            }
            view_dirty = true;
        }
        // Finish an in-flight interactive connect once the socket is up.
        if (connect_task) |*h| {
            if (h.poll()) |res| {
                connect_task = null;
                const hp = connect_hostport.?;
                defer {
                    gpa.free(hp);
                    connect_hostport = null;
                }
                if (res) |fd| {
                    runtimeConnectFinish(gpa, &cmd_ctx, &collab_session, &conn, &fd_link, fd, hp, args.token, args.user, &caps, &my_identity) catch |err| {
                        _ = std.os.linux.close(fd);
                        var buf: [96]u8 = undefined;
                        setEcho(&echo_line, gpa, std.fmt.bufPrint(&buf, "connect failed: {t}", .{err}) catch "connect failed");
                    };
                } else |err| {
                    var buf: [96]u8 = undefined;
                    setEcho(&echo_line, gpa, std.fmt.bufPrint(&buf, "connect failed: {t}", .{err}) catch "connect failed");
                }
                view_dirty = true;
            }
        }
        // Listen intents (same out-of-hot-section region): bind/listen
        // are immediate, accept runs on the hub's own thread.
        if (share_ctx.pending_listen) |port| {
            share_ctx.pending_listen = null;
            if (hub == null) startListen(gpa, &hub, &share_ctx, &buffers, &caps, port, args.token, share_ctx.pending_access, &my_identity, &echo_line);
            view_dirty = true;
        }
        if (share_ctx.stop_listen_requested) {
            share_ctx.stop_listen_requested = false;
            if (hub) |*h| h.stopAccepting();
            view_dirty = true;
        }
        // ── Window-layout intents (outside the input hot section) ──
        // Each op saves the focused pane's scroll first, then mutates the
        // tree; a focus/content change makes the active buffer follow the
        // focused pane (applyWindowFocus). Geometry uses last render's frame.
        if (win_ctx.split) |axis| {
            win_ctx.split = null;
            win_layout.focusedPane().top_row = view.top_row; // carried into the surviving half
            win_layout.splitFocused(axis) catch {};
            view_dirty = true;
        }
        if (win_ctx.close) {
            win_ctx.close = false;
            if (win_layout.count() > 1) {
                win_layout.closeFocused();
                applyWindowFocus(&win_layout, &view, &buffers, gpa, &keymap);
                view_dirty = true;
            }
        }
        if (win_ctx.focus_dir) |dir| {
            win_ctx.focus_dir = null;
            win_layout.focusedPane().top_row = view.top_row;
            if (win_layout.focusNeighbor(last_frame_rect, dir)) {
                applyWindowFocus(&win_layout, &view, &buffers, gpa, &keymap);
                view_dirty = true;
            }
        }
        if (win_ctx.move_dir) |dir| {
            win_ctx.move_dir = null;
            win_layout.focusedPane().top_row = view.top_row;
            // Swap contents with the neighbor; focus stays put but now shows
            // the neighbor's buffer, so the active buffer follows it.
            if (win_layout.swapNeighbor(last_frame_rect, dir)) {
                applyWindowFocus(&win_layout, &view, &buffers, gpa, &keymap);
                view_dirty = true;
            }
        }
        if (win_ctx.focus_next) {
            win_ctx.focus_next = false;
            win_layout.focusedPane().top_row = view.top_row;
            if (win_layout.focusNext()) {
                applyWindowFocus(&win_layout, &view, &buffers, gpa, &keymap);
                view_dirty = true;
            }
        }
        if (win_ctx.click_focus) {
            win_ctx.click_focus = false;
            win_layout.focusedPane().top_row = view.top_row;
            if (win_layout.focusAt(last_frame_rect, win_ctx.click_x, win_ctx.click_y)) {
                applyWindowFocus(&win_layout, &view, &buffers, gpa, &keymap);
                view_dirty = true;
            }
        }
        // The focused pane always shows the active buffer (buffer switches
        // via open/tabs/etc. land here); a pane whose buffer was closed
        // falls back to the active one so no leaf dangles.
        win_layout.focusedPane().buffer_id = buffers.active_id;
        {
            const PruneCtx = struct { active: core.Buffers.Id, bufs: *core.Buffers };
            win_layout.eachPane(PruneCtx{ .active = buffers.active_id, .bufs = &buffers }, struct {
                fn visit(c: PruneCtx, p: *window_layout.Pane) void {
                    if (c.bufs.get(p.buffer_id) == null) p.buffer_id = c.active;
                }
            }.visit);
        }
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
    fn hasEntry(self: *const CursorConfig, mode: []const u8) bool {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.mode, mode)) return true;
        return false;
    }
    /// The mode whose caret should render for `mode`. A menu mode with no caret
    /// of its own inherits its return target's — so `leader` keeps normal's bar
    /// instead of flipping to a block. (Uses the menu-return relation, NOT the
    /// key-lookup `parents` chain, so no bindings leak into the menu.)
    fn resolveMode(self: *const CursorConfig, keymap: *const core.Keymap, mode: []const u8) []const u8 {
        if (self.hasEntry(mode)) return mode;
        if (keymap.isMenuMode(mode)) if (keymap.menuReturn(mode)) |ret| return ret;
        return mode;
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

fn setColorHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = ctx;
    const v: *view_mod.View = @ptrCast(@alignCast(data.?));
    if (!v.theme.setColor(args[0].string, args[1].string)) return error.InvalidArgument;
    return .nil;
}

/// `menu-escape` (Escape / C-g in a menu) — leave the current menu mode back to
/// its recorded return target (the root non-menu mode), or `normal`.
fn menuEscapeHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = data;
    _ = args;
    const km = ctx.keymap;
    const ret = km.menuReturn(km.currentMode()) orelse "normal";
    km.setMode(ctx.gpa, ret) catch {};
    return .nil;
}

/// `which-key-now` — flag an immediate popup (bypassing the idle delay), and if
/// not already in a menu, open the leader menu so a help key shows it anywhere.
fn whichKeyNowHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const flag: *bool = @ptrCast(@alignCast(data.?));
    flag.* = true;
    const km = ctx.keymap;
    if (!km.isMenuMode(km.currentMode())) km.enterMode(ctx.gpa, "leader") catch {};
    return .nil;
}

/// Decode the first record of a framed config blob (uvarint count, then per
/// record uvarint(len)++bytes — the encoding the config shim produces). Used to
/// read a single-value `weft.set` (e.g. a theme color) host-side.
fn firstConfigRecord(blob: []const u8) ?[]const u8 {
    var cur = blob;
    _ = getConfigUvarint(&cur) orelse return null; // record count
    const n = getConfigUvarint(&cur) orelse return null;
    if (n > cur.len) return null;
    return cur[0..@intCast(n)];
}
fn getConfigUvarint(cur: *[]const u8) ?u64 {
    var shift: u6 = 0;
    var v: u64 = 0;
    while (cur.len > 0) {
        const b = cur.*[0];
        cur.* = cur.*[1..];
        v |= @as(u64, b & 0x7f) << shift;
        if (b & 0x80 == 0) return v;
        if (shift >= 57) return null;
        shift += 7;
    }
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

/// `peers` — echo/log every connected peer's fingerprint, four-word SAS,
/// and trust grade, so a user can compare the SAS out of band and then
/// `verify-peer <fingerprint>`. The full detail goes to the log (many
/// peers won't fit the status line); the echo is a one-line summary.
fn peersHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    var count: usize = 0;
    var first_line: ?[]const u8 = null;
    var line_buf: [160]u8 = undefined;

    const report = struct {
        fn one(kp: *core.known_peers.KnownPeers, sess: *core.session.Session, role: []const u8, n: *usize, fl: *?[]const u8, lb: []u8) void {
            const fp = sess.peerFingerprint() orelse return;
            const sas = sess.sas() orelse return;
            n.* += 1;
            const trust = kp.trust(fp);
            std.log.info("peer {s}: {s} · SAS {s} · {s}", .{ role, &fp, &sas, trust.label() });
            if (fl.* == null) {
                fl.* = std.fmt.bufPrint(lb, "{s} {s} · {s}", .{ role, &fp, trust.label() }) catch null;
            }
        }
    };

    if (sc.session.*) |host| report.one(sc.known, host, "host", &count, &first_line, &line_buf);
    if (sc.hub.*) |*h| {
        for (h.clients.items) |p| report.one(sc.known, p.sess, "guest", &count, &first_line, &line_buf);
    }

    if (count == 0) return ok_echo(ctx, "no peers connected");
    if (count == 1 and first_line != null) return ok_echo(ctx, first_line.?);
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "{d} peers (see log for SAS)", .{count}) catch "peers");
}

/// `grant <fingerprint> <grade>` — authorize a connected peer by identity
/// (host side). The grade takes effect immediately for a live peer and is
/// remembered for future reconnects of that fingerprint.
fn grantHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    if (args.len != 2 or args[0] != .string or args[1] != .string) return error.TypeMismatch;
    const fp = parseFingerprint(args[0].string) orelse
        return ok_echo(ctx, "grant: expected a fingerprint like k7q2-9fh3-...");
    const grade = core.session.Access.parse(args[1].string) orelse
        return ok_echo(ctx, "grant: grade must be view|edit|own");
    const h = &(sc.hub.* orelse return ok_echo(ctx, "grant: not hosting (start listen first)"));
    h.setPeerAccess(fp, grade) catch |err| {
        var buf: [64]u8 = undefined;
        return ok_echo(ctx, std.fmt.bufPrint(&buf, "grant failed: {t}", .{err}) catch "grant failed");
    };
    var buf: [64]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "granted {s} to {s}", .{ grade.label(), &fp }) catch "granted");
}

/// Scrolling commands operate on the focused pane's viewport, which lives
/// in the view (core commands can't see it).
const ScrollCtx = struct { view: *view_mod.View, fb: *[2]u32 };

fn scrollOf(data: ?*anyopaque) *ScrollCtx {
    return @ptrCast(@alignCast(data.?));
}

fn viewportRows(sc: *ScrollCtx) usize {
    _ = sc.fb;
    return sc.view.bodyRows(); // the focused pane's body height, split-aware
}

/// Move the focused pane's viewport by `delta` rows, optionally carrying
/// the cursor with it (vim C-d/C-u/C-f/C-b move the cursor; C-e/C-y do not).
fn doScroll(ctx: *core.command.Context, sc: *ScrollCtx, delta: i64, move_cursor: bool) void {
    const ed = ctx.editor();
    const rope = ed.text();
    const last = rope.lineCount() -| 1;
    if (delta >= 0)
        sc.view.top_row = @min(sc.view.top_row + @as(usize, @intCast(delta)), last)
    else
        sc.view.top_row -|= @intCast(-delta);
    if (move_cursor) {
        const cur_row = rope.offsetToPoint(ed.cursorOffset()).row;
        const nr = if (delta >= 0)
            @min(cur_row + @as(usize, @intCast(delta)), last)
        else
            cur_row -| @as(usize, @intCast(-delta));
        ed.clearSelection();
        ed.placeCursor(rope.lineRange(nr).start);
    }
}

fn scrollLineDown(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    doScroll(ctx, scrollOf(data), 1, false);
    return .nil;
}
fn scrollLineUp(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    doScroll(ctx, scrollOf(data), -1, false);
    return .nil;
}
fn scrollHalfDown(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    doScroll(ctx, sc, @intCast(viewportRows(sc) / 2), true);
    return .nil;
}
fn scrollHalfUp(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    doScroll(ctx, sc, -@as(i64, @intCast(viewportRows(sc) / 2)), true);
    return .nil;
}
fn scrollPageDown(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    doScroll(ctx, sc, @intCast(viewportRows(sc) -| 2), true);
    return .nil;
}
fn scrollPageUp(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    doScroll(ctx, sc, -@as(i64, @intCast(viewportRows(sc) -| 2)), true);
    return .nil;
}
fn centerLine(ctx: *core.command.Context, data: ?*anyopaque, _: []const core.command.Value) anyerror!core.command.Value {
    const sc = scrollOf(data);
    const ed = ctx.editor();
    const cur_row = ed.text().offsetToPoint(ed.cursorOffset()).row;
    sc.view.top_row = cur_row -| (viewportRows(sc) / 2);
    return .nil;
}

/// Window-layout intents; applied in the frame loop (which owns the pane
/// tree + scroll/build state). Commands only record intent — the loop
/// mutates the layout and keeps the focused pane == the active buffer.
const WindowCtx = struct {
    split: ?region.Axis = null, // request a split of the focused pane
    close: bool = false,
    focus_dir: ?window_layout.Dir = null,
    move_dir: ?window_layout.Dir = null,
    focus_next: bool = false, // cycle focus (legacy `focus-other`)
    click_focus: bool = false, // focus the pane at (click_x, click_y)
    click_x: f32 = 0,
    click_y: f32 = 0,
};

/// Which window operation a bound command requests (mapped to a WindowCtx
/// field in windowActionHandler). vim `:split` is a horizontal divider
/// (stacked rows); `:vsplit` a vertical one (side-by-side columns).
const WindowAction = enum {
    split,
    vsplit,
    close,
    focus_next,
    focus_left,
    focus_right,
    focus_up,
    focus_down,
    move_left,
    move_right,
    move_up,
    move_down,
};

/// A command → intent binding: which WindowCtx to poke and how. Held in a
/// stable array so `command.bind`'s data pointer stays valid for the run.
const WindowActionCtx = struct { win: *WindowCtx, action: WindowAction };

fn windowActionHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const a: *WindowActionCtx = @ptrCast(@alignCast(data.?));
    switch (a.action) {
        .split => a.win.split = .horizontal, // stacked rows (vim :split)
        .vsplit => a.win.split = .vertical, // side-by-side columns (vim :vsplit)
        .close => a.win.close = true,
        .focus_next => a.win.focus_next = true,
        .focus_left => a.win.focus_dir = .left,
        .focus_right => a.win.focus_dir = .right,
        .focus_up => a.win.focus_dir = .up,
        .focus_down => a.win.focus_dir = .down,
        .move_left => a.win.move_dir = .left,
        .move_right => a.win.move_dir = .right,
        .move_up => a.win.move_dir = .up,
        .move_down => a.win.move_dir = .down,
    }
    return ok_echo(ctx, "window");
}

/// After a window op moved focus (or changed the focused pane's content),
/// make the active buffer follow the focused pane and restore that pane's
/// scroll — the invariant "focused pane == active buffer".
fn applyWindowFocus(win_layout: *window_layout.Layout, view: *view_mod.View, buffers: *core.Buffers, gpa: std.mem.Allocator, keymap: *core.Keymap) void {
    const fp = win_layout.focusedPane();
    if (buffers.get(fp.buffer_id) != null and buffers.active_id != fp.buffer_id)
        buffers.switchTo(gpa, fp.buffer_id, keymap) catch {};
    view.top_row = fp.top_row;
}

/// `cancel` (C-g) — records the intent; the frame loop drops queued
/// connect/listen requests and detaches an in-flight connect.
fn cancelHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const sc: *ShareCtx = @ptrCast(@alignCast(data.?));
    sc.cancel_requested = true;
    return ok_echo(ctx, "canceled");
}

/// Status-line chip for a peer's trust grade (null = don't show).
fn hostTrustChip(trust: core.known_peers.Trust) ?[]const u8 {
    return switch (trust) {
        .verified => "✓ verified",
        .unverified => "⚠ unverified",
        .unknown => "⚠ unknown",
    };
}

/// The far end of the editor's selection (the end that is not the caret),
/// or the caret itself when nothing is selected — what presence publishes
/// so peers can render our selection, not just our cursor.
fn selectionAnchorOf(ed: *const core.Editor) usize {
    const cur = ed.cursorOffset();
    if (ed.selectedRange()) |r| return if (cur == r.start) r.end else r.start;
    return cur;
}

fn identityHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    _ = args;
    const id: *core.identity.Identity = @ptrCast(@alignCast(data.?));
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "identity {s}", .{&id.fingerprint()}) catch "identity");
}

/// Load and run the user's `config.js` in the quickjs.wasm sandbox (plan
/// 06B). Reads the file, spins a one-shot wasm engine, and evals — the config
/// wires the editor only through the `weft.*` grants. The engine is scoped to
/// the eval: config is a startup declaration, not a resident runtime.
fn loadJsConfig(gpa: std.mem.Allocator, ctx: *core.command.Context, path: []const u8, loader: ?core.quickjs.PluginLoader, config: *core.kv.Store) !void {
    const src = try core.file.readAlloc(gpa, path);
    defer gpa.free(src);
    var engine = try core.wasm.Engine.init();
    defer engine.deinit();
    try core.quickjs.evalConfig(&engine, ctx, loader, config, src);
}

/// Resolve the reference-plugin directory: `$WEFT_PLUGIN_DIR` if set, else
/// `<exe>/../lib/weft/plugins` (where `zig build` installs them). Falls back to
/// a bare "plugins" if the exe path can't be found. Caller owns the result.
fn pluginDir(gpa: std.mem.Allocator) []const u8 {
    if (std.c.getenv("WEFT_PLUGIN_DIR")) |d| return gpa.dupe(u8, std.mem.span(d)) catch "plugins";
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const exe_dir = std.process.executableDirPathAlloc(threaded.io(), gpa) catch
        return gpa.dupe(u8, "plugins") catch "plugins";
    defer gpa.free(exe_dir);
    return std.fs.path.join(gpa, &.{ exe_dir, "..", "lib", "weft", "plugins" }) catch
        gpa.dupe(u8, "plugins") catch "plugins";
}

/// The compiled-module (`.cwasm`) cache directory: `$WEFT_CACHE_DIR`, else
/// `$XDG_CACHE_HOME/weft/modules`, else `$HOME/.cache/weft/modules`. Null when
/// no writable base can be resolved (caching disabled — the editor still runs,
/// just recompiles each start). Caller owns the result.
fn moduleCacheDir(gpa: std.mem.Allocator) ?[]const u8 {
    if (std.c.getenv("WEFT_CACHE_DIR")) |d| return gpa.dupe(u8, std.mem.span(d)) catch null;
    if (std.c.getenv("XDG_CACHE_HOME")) |d|
        return std.fs.path.join(gpa, &.{ std.mem.span(d), "weft", "modules" }) catch null;
    if (std.c.getenv("HOME")) |d|
        return std.fs.path.join(gpa, &.{ std.mem.span(d), ".cache", "weft", "modules" }) catch null;
    return null;
}

/// The resident wasm-plugin loader: holds the engine, the editor context, the
/// effect services, and the live plugin list. Both `--plugin` and the config's
/// `weft.plugin(name)` funnel through `load`, so name resolution and lifetime
/// are one path. Plugins stay resident for the session (their registered
/// commands hold pointers into the WasmPlugin); the list frees them at exit.
const PluginHost = struct {
    gpa: std.mem.Allocator,
    engine: *core.wasm.Engine,
    ctx: *core.command.Context,
    opts: core.wasm_abi.LoadOptions,
    list: *std.ArrayList(*core.wasm_abi.WasmPlugin),
    dir: []const u8,

    /// A bare name ("vim") resolves to `<dir>/vim.wasm`; anything with a path
    /// separator or a `.wasm` suffix is taken literally (explicit --plugin
    /// paths). Writes into `buf`, returns the slice.
    fn resolve(self: *PluginHost, buf: []u8, name: []const u8) ?[]const u8 {
        if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.endsWith(u8, name, ".wasm"))
            return name;
        return std.fmt.bufPrint(buf, "{s}/{s}.wasm", .{ self.dir, name }) catch null;
    }

    fn load(self: *PluginHost, name: []const u8) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = self.resolve(&path_buf, name) orelse return;
        // Compilation copies the module, so the file bytes free right after.
        const bytes = core.file.readAlloc(self.gpa, path) catch |e| {
            std.log.warn("plugin: {s} failed to read: {t}", .{ path, e });
            return;
        };
        defer self.gpa.free(bytes);
        const p = core.wasm_abi.loadPlugin(self.engine, self.ctx, std.fs.path.stem(name), bytes, self.opts) catch |e| {
            std.log.warn("plugin: {s} failed to load: {t}", .{ path, e });
            return;
        };
        self.list.append(self.gpa, p) catch p.deinit();
    }

    fn loader(self: *PluginHost) core.quickjs.PluginLoader {
        return .{ .ctx = self, .load = trampoline };
    }
    fn trampoline(ctx: *anyopaque, name: []const u8) void {
        const self: *PluginHost = @ptrCast(@alignCast(ctx));
        self.load(name);
    }
};

/// Parse a 24-char fingerprint argument (five base32 groups) into bytes.
fn parseFingerprint(s: []const u8) ?[24]u8 {
    if (s.len != 24) return null;
    var fp: [24]u8 = undefined;
    @memcpy(&fp, s);
    return fp;
}

fn verifyPeerHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const kp: *core.known_peers.KnownPeers = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const fp = parseFingerprint(args[0].string) orelse
        return ok_echo(ctx, "verify-peer: expected a fingerprint like k7q2-9fh3-...");
    kp.verify(fp) catch |err| {
        var buf: [64]u8 = undefined;
        return ok_echo(ctx, std.fmt.bufPrint(&buf, "verify-peer failed: {t}", .{err}) catch "verify-peer failed");
    };
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "verified {s}", .{&fp}) catch "verified");
}

fn forgetPeerHandler(ctx: *core.command.Context, data: ?*anyopaque, args: []const core.command.Value) anyerror!core.command.Value {
    const kp: *core.known_peers.KnownPeers = @ptrCast(@alignCast(data.?));
    if (args.len != 1 or args[0] != .string) return error.TypeMismatch;
    const fp = parseFingerprint(args[0].string) orelse
        return ok_echo(ctx, "forget-peer: expected a fingerprint like k7q2-9fh3-...");
    kp.forget(fp) catch |err| {
        var buf: [64]u8 = undefined;
        return ok_echo(ctx, std.fmt.bufPrint(&buf, "forget-peer failed: {t}", .{err}) catch "forget-peer failed");
    };
    var buf: [48]u8 = undefined;
    return ok_echo(ctx, std.fmt.bufPrint(&buf, "forgot {s}", .{&fp}) catch "forgot");
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
    // Skip folded rows (shared fold-aware successor — the magit status buffer's
    // j/k bind to cursor-up/down, which land here).
    const target_row = ed.nextVisibleRow(pt.row, if (dir < 0) -1 else 1, rows) orelse return;
    const target = try view.xToOffsetOnRow(rope, target_row, gx);
    ed.moveToVisual(target, gx);
}

fn dispatchKey(ctx: *core.command.Context, view: *view_mod.View, ev: wayland.KeyEvent, fb_h: u32) !void {
    const c = wayland.c;
    // Paging needs viewport geometry the core doesn't know; view-aware
    // dispatch stays here.
    if (ev.keysym == c.XKB_KEY_Page_Up or ev.keysym == c.XKB_KEY_Page_Down) {
        _ = fb_h;
        const rows = view.bodyRows();
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
            // A bound key whose command NAMES a menu mode enters that submenu
            // (the which-key / doom leader tree). Config declares submenus with
            // `weft.menu` and binds leader keys to them; entering records the
            // one-shot return target. No per-submenu entry command is needed.
            if (ctx.keymap.isMenuMode(cmd_name)) {
                ctx.keymap.enterMode(ctx.gpa, cmd_name) catch {};
                return;
            }
            // Snapshot a menu mode so a one-shot key can pop back to its return
            // target after the command runs — but only if the command didn't
            // itself change the mode (submenu entry and explicit mode sets are
            // preserved). Recorded/resolved by Keymap.enterMode on guest entry.
            const menu_before: ?[]u8 = if (ctx.keymap.isMenuMode(ctx.keymap.currentMode()))
                ctx.gpa.dupe(u8, ctx.keymap.currentMode()) catch null
            else
                null;
            defer if (menu_before) |m| ctx.gpa.free(m);

            const result = core.command.run(ctx.commands, ctx, cmd_name, &.{}) catch |err| blk: {
                std.log.warn("command {s} failed: {t}", .{ cmd_name, err });
                break :blk core.command.Value.nil;
            };
            // Surface a returned string as transient feedback so command results
            // (e.g. share's "not connected") aren't silently dropped.
            switch (result) {
                .string => |s| if (s.len > 0) {
                    ctx.echo.clearRetainingCapacity();
                    ctx.echo.appendSlice(ctx.gpa, s) catch {};
                },
                else => {},
            }
            // One-shot menu: still in the menu we entered on ⇒ pop to its return
            // target (the root non-menu mode). setMode dupes internally. A STICKY
            // menu is exempt — it stays open so flag toggles accumulate; it
            // leaves only via an explicit mode change (execute) or Escape.
            if (menu_before) |m| {
                if (!ctx.keymap.isStickyMenu(m) and std.mem.eql(u8, ctx.keymap.currentMode(), m)) {
                    if (ctx.keymap.menuReturn(m)) |ret| ctx.keymap.setMode(ctx.gpa, ret) catch {};
                }
            }
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

/// The `abi.SyntaxResolver` the catalog uses: reach a buffer's live grammar
/// through the shell-owned frontend slot (core cannot; the host can).
fn resolveSyntax(buf: *core.Buffers.Buffer) ?*core.syntax.Syntax {
    const at: *Attach = @ptrCast(@alignCast(buf.frontend orelse return null));
    return at.syntax;
}

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
        // BatchMode=yes: never block on an interactive password prompt (a
        // classic hang); ConnectTimeout bounds an unreachable host. The
        // spawn is still synchronous on the frame thread, but now it fails
        // fast instead of wedging the editor.
        fs.* = try core.ShellFs.spawn(self.gpa, &.{
            "ssh", "-o",               "BatchMode=yes",
            "-o",  "ConnectTimeout=8", host,
            "sh",
        }, self.environ);
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
    const doc = &buf.editor.doc;

    // The buffer's *language* is identified by its name/path hint —
    // independent of where the bytes live. A shared (remote) buffer holds
    // its content in our replica, so tree-sitter highlights it locally
    // even with no local file backing. (Local) LSP is different: the
    // server needs the file on this machine, so it attaches only to a
    // locally-backed buffer, below.
    const lang_path = buf.editor.backingPath() orelse buf.name;

    if (deps.grammars.forPath(lang_path)) |spec| {
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
        if (buf.editor.backingPath()) |p| {
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
    /// Outbound host session (for the `peers` command's fp/SAS/trust).
    session: *?*core.session.Session = undefined,
    /// TOFU store, for trust lookups in the `peers` command.
    known: *core.known_peers.KnownPeers = undefined,
    /// Buffers shared over the hub — replayed to late joiners.
    shared: std.ArrayList(SharedDoc) = .empty,
    /// The doc bound at quad 0 for every hub peer (the buffer active
    /// when listening began); set by the listen apply block.
    primary_doc: ?*core.Document = null,
    primary_tag: u64 = 0,
    /// Opt-in filesystem sharing (--share-root/--share-fs): a confined root
    /// served to peers, and the grant. Null root ⇒ serve no fs (default).
    peer_fs_root: ?*core.rooted_fs.RootedFs = null,
    fs_grant: core.peer_fs.Grant = .{},
    /// Commands record INTENTS here; the frame loop applies them
    /// outside the input hot section (connect blocks on TCP, disconnect
    /// joins session threads).
    pending_connect: ?[]u8 = null,
    disconnect_requested: bool = false,
    pending_listen: ?u16 = null,
    /// Access grade for the next `listen` (safe default: view).
    pending_access: core.session.Access = .view,
    stop_listen_requested: bool = false,
    /// C-g: drop queued connect/listen intents and abort an in-flight
    /// connect. Applied in the frame loop (which owns the connect handle).
    cancel_requested: bool = false,
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
    // Serve the opt-in shared filesystem root to this peer (default: none, so a
    // peer gets nothing unless the host passed --share-root/--share-fs).
    col.peer_fs_root = sc.peer_fs_root;
    col.fs_grant = sc.fs_grant;
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
    my_identity: *const core.identity.Identity,
    echo: *std.ArrayList(u8),
) void {
    sc.primary_doc = &buffers.active().editor.doc;
    sc.primary_tag = buffers.active_id;
    hub_slot.* = core.hub.Hub.init(gpa, token, access, my_identity) catch {
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
/// Finish a runtime connect from an already-open socket `fd` (the TCP
/// connect ran on the pool). Builds the client session + Conn and a
/// buffer for the remote primary.
fn runtimeConnectFinish(
    gpa: std.mem.Allocator,
    ctx: *core.command.Context,
    session_slot: *?*core.session.Session,
    conn_slot: *?core.session.Conn,
    fd_link: *core.session.FdLink,
    fd: i32,
    hostport: []const u8,
    token: []const u8,
    user: []const u8,
    caps: *core.Caps,
    my_identity: *const core.identity.Identity,
) !void {
    fd_link.* = .{ .fd = fd };
    const sess = try core.session.Session.create(gpa, fd_link.link(), .client, token, .own, my_identity);
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
