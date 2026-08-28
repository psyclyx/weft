//! e2e/harness — the HEADLESS integration harness that drives the full editor
//! the way a person does: boot the real config (or load plugins), press keys
//! through the keymap (so bound keys, chords, and modes behave exactly as in the
//! app), type text, run commands, and observe the rendered surface + disk. The
//! authoritative two-editor spine renders with standard headless Vulkan (no
//! WSI/Wayland); smaller geometry tests retain a CPU target. PPM artifacts live
//! under `.zig-cache/tmp/`.
//!
//! The point (per the design brief): approach a task as "the natural way to do
//! X in weft is to press Y". If Y doesn't exist, is bound weird, or is more
//! painful than it should be, that difficulty is the SIGNAL — fix the core/
//! plugin/config, don't write a weird test to match. This file is the shared
//! driver; the per-concern test files (editing/window/collab/project/config/
//! teardown) import it and are pulled together by `e2e.zig`.

const std = @import("std");
pub const scene = weft.scene;
// The weft app (core + gfx + app) reaches this subdir as ONE named module wired
// in build.zig (src/weft.zig barrel) — no `../` reach-arounds across the tree.
const weft = @import("weft");
pub const core = weft.core;
pub const semantic_model = weft.semantic_model;
pub const view_runtime = weft.view_runtime;
pub const target_runtime = weft.target_runtime;
pub const fs = weft.fs;
const view_mod = weft.view;
const harness = weft.gfx_harness;
pub const window_layout = weft.window_layout;
pub const window_cmds = weft.window_cmds;
const app_buffers_cmds = weft.app_buffers_cmds;
pub const dispatch = weft.dispatch;
pub const app_session = weft.app_session;
pub const app_providers = weft.app_providers;
pub const app_collab = weft.app_collab;
pub const app_collab_cmds = weft.app_collab_cmds;
const app_application = weft.app_application;
const app_render_memory = weft.app_render_memory;
const app_headless_vulkan = weft.app_headless_vulkan;
pub const region = weft.region;

// Re-exports so the per-concern test files can alias what they need from this
// one harness module (`const core = h.core;` etc.) without their own imports.
pub const session = core.session;
pub const gfx_harness = harness; // aliased as `harness` in the window tests
pub const view = view_mod; // the View/Built/Hud package, for popup-layout introspection

const Allocator = std.mem.Allocator;
const command = core.command;

const InputKind = enum { text, command };

const InputObserver = struct {
    context: *anyopaque,
    after_input: *const fn (*anyopaque, InputKind) void,

    fn notify(self: InputObserver, kind: InputKind) void {
        self.after_input(self.context, kind);
    }
};

/// The authoritative editor capture canvas. The production frame, Vulkan
/// target, readback, ordinary PPMs, and each half of the demo video all use
/// this size. Keep the aspect ratio stable while giving the recorded editor
/// enough pixels for text and plugin surfaces to remain legible.
pub const CaptureCanvas = struct {
    width: u32,
    height: u32,
};

pub const editor_canvas = CaptureCanvas{ .width = 960, .height = 600 };
pub const pair_canvas = CaptureCanvas{
    .width = editor_canvas.width * 2,
    .height = editor_canvas.height,
};

// Compatibility aliases used by the geometry tests. They remain derived from
// the one editor-canvas declaration above rather than being independent sizes.
pub const app_w: u32 = editor_canvas.width;
pub const app_h: u32 = editor_canvas.height;
pub const pair_w: u32 = pair_canvas.width;
pub const pair_h: u32 = pair_canvas.height;
pub const app_em: f32 = 16;

/// The shipped resident JS plugins, as the catalog installs them — a test
/// drives the REAL reactor, never a paraphrase of it.
pub const acp_js = weft.acp_js;

/// A full editor, headless — built around the REAL app state. It owns an
/// `app_session.Session` (the same struct `main()` holds: buffers, command/
/// keymap/pick surfaces, caps, echo, quit, cmd_ctx, AND the capability-consumer
/// UIs completion/definition/symbols/hover + cursor config, all wired by
/// `Session.init` exactly as the app does) plus `Providers` and the `main()`
/// plugin-host locals (engine/loop/plugins). Driving the real Session — not a
/// look-alike — is why completion / hover / goto-def work without the harness
/// re-wiring anything; a new capability the app gains is here for free.
pub const Editor = struct {
    gpa: Allocator,
    pool: *core.task.Pool,

    // The real editor state + provider registries, exactly as main() builds them.
    session: app_session.Session = undefined,
    prov: app_providers.Providers = undefined,

    // Pointer aliases into `session`, set once it inits — so the driving methods
    // and the tests read `ed.keymap` / `self.buffers` unchanged (auto-deref).
    buffers: *core.Buffers = undefined,
    commands: *command.Commands = undefined,
    keymap: *core.Keymap = undefined,
    /// This harness's (today, singular) head — mode/pending/pick/echo.
    head: *core.Head = undefined,
    pick: *core.Pick = undefined,
    caps: *core.Caps = undefined,
    ctx: *command.Context = undefined,

    // ── main()-local plugin host + async loop (the harness owns these) ──
    engine: core.wasm.Engine = undefined,
    plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty,
    /// Resident JS plugins (quickjs reactors: acp.js / dap.js), ticked each
    /// settle() like main()'s frame loop ticks them.
    js_plugins: std.ArrayList(*core.quickjs.JsPlugin) = .empty,
    plugin_kv: core.kv.Store = .empty,
    config_kv: core.kv.Store = .empty,
    loop: core.async_loop.Loop = undefined,
    subs: core.subbuffer.SubBuffers = .empty,
    register: core.register.Bank = .{},
    /// The complete production frame path, ending in a memory-backed present
    /// target. Tests and recorders only receive its finished framebuffer.
    render: app_render_memory.RenderState = undefined,
    memory_render_live: bool = false,
    /// Standard headless Vulkan target + the selected production renderer.
    /// Bound by the authoritative two-editor spine; never imports Wayland.
    vulkan_head: ?*app_headless_vulkan.Head = null,
    application: app_application.Application = undefined,
    frame_known_peers: core.known_peers.KnownPeers = undefined,
    frame_conn: ?core.session.Conn = null,
    frame_hub: ?core.hub.Hub = null,
    frame_collab_session: ?*core.session.Session = null,
    frame_partial_state: ?core.session.PartialDoc = null,
    frame_noted_host_fp: ?[24]u8 = null,
    /// Optional caller-side observation of completed input wakes. Production
    /// has no such hook; the demo recorder uses it only to pace the same input
    /// stream an ordinary E2E test drives.
    input_observer: ?InputObserver = null,

    // ── Window layout (multi-pane) ──
    /// The recursive pane tree, driven by the REAL window-layout commands
    /// (window-split/focus/move) through `window_cmds.applyIntents`, exactly as
    /// main's frame loop drives it.
    /// Alias of `render.fb.win_layout`: input, layout, rendering, and capture
    /// share one pane tree. There is no capture-only layout to drift.
    win_layout: *window_layout.Layout = undefined,
    win_ctx: window_cmds.WindowCtx = .{},
    /// Stable backing for the window commands' data pointers (registerCommands).
    win_actions: [window_cmds.cmd_count]window_cmds.WindowActionCtx = undefined,
    /// Stable composition data for provider-aware buffer and target opening.
    buffer_commands: app_buffers_cmds.Context = undefined,
    /// Stable backing for the collaboration commands' data pointer, filled by
    /// `enableCollabCommands` (opt-in — see there).
    share_ctx: app_collab.ShareCtx = undefined,
    pub fn init(gpa: Allocator, self: *Editor) !void {
        return initNamed(gpa, self, "user");
    }

    /// Like `init`, but names the user/agent — so two harnesses sharing a
    /// document over the collab loopback are DISTINCT CRDT replicas (identical
    /// agent names would collide event ids and corrupt the merge).
    pub fn initNamed(gpa: Allocator, self: *Editor, user: []const u8) !void {
        self.gpa = gpa;
        self.plugins = .empty;
        self.js_plugins = .empty;
        self.plugin_kv = .empty;
        self.config_kv = .empty;
        self.subs = .empty;
        self.register = .{};
        self.frame_conn = null;
        self.frame_hub = null;
        self.frame_collab_session = null;
        self.frame_partial_state = null;
        self.frame_noted_host_fp = null;
        self.input_observer = null;
        self.vulkan_head = null;
        self.pool = try core.task.Pool.init(gpa, .{ .threads = 2 });
        self.engine = try core.wasm.Engine.init(gpa);
        self.loop = core.async_loop.Loop.init(gpa, self.pool, core.task.nowNs);

        // Stand up the REAL app state, in main()'s construction order: Providers'
        // registries first (Session's capability consumers bind onto them), the
        // Session (builtins + capability/caret commands), then Providers' attach
        // phase (borrows the session caps).
        try self.prov.initRegistries(gpa);
        try self.session.init(gpa, self.pool, user, &self.prov.grammars);
        self.prov.initAttach(gpa, &self.session.system.caps, parentEnviron());

        // Alias the moved state (session is a field of *self, so these are stable).
        self.buffers = &self.session.system.buffers;
        self.commands = &self.session.system.commands;
        self.keymap = &self.session.system.keymap;
        self.head = &self.session.head;
        self.pick = &self.session.head.pick;
        self.caps = &self.session.system.caps;
        self.ctx = &self.session.cmd_ctx;

        // Proc-backed plugins (git/run/grep) shell out through the wasm host,
        // which passes this process-global environ to each child. main() sets it
        // at startup; the harness must too, or every subprocess runs PATH-less.
        core.wasm_host.setEnviron(parentEnviron());

        // Window layout: own the real pane tree + bind the real window commands.
        self.win_ctx = .{};
        try self.render.init(gpa, weft.font_provider.defaultMono(), app_em, self.buffers.active_id);
        self.memory_render_live = true;
        self.win_layout = &self.render.fb.win_layout;
        self.frame_known_peers = try core.known_peers.KnownPeers.load(gpa, parentEnviron());
        const ed0 = self.buffers.get(0) orelse self.buffers.active();
        self.application.init(.{
            .gpa = self.gpa,
            .session = &self.session,
            .attach_deps = &self.prov.attach_deps,
            .plugin_loop = &self.loop,
            .js_plugins = &self.js_plugins,
            .plugins = &self.plugins,
            .conn = &self.frame_conn,
            .hub = &self.frame_hub,
            .collab_session = &self.frame_collab_session,
            .partial_state = &self.frame_partial_state,
            .ed0 = ed0.textEditor().?,
            .known_peers = &self.frame_known_peers,
            .noted_host_fp = &self.frame_noted_host_fp,
            .window_ctx = &self.win_ctx,
            .layout = self.win_layout,
            .view = &self.render.fb.view,
        });
        try window_cmds.registerCommands(gpa, self.commands, &self.win_ctx, &self.win_actions);
        // The app's provider-aware open/close (shadows the core versions): opening
        // a file now attaches syntax + a language server per the lsp-add registry,
        // exactly as main() does, so a .zig buffer gets zls.
        self.buffer_commands = .{
            .attachments = &self.prov.attach_deps,
            .directories = .{
                .context = &self.session,
                .open = app_session.Session.openLocalDirectoryOpaque,
            },
        };
        try app_buffers_cmds.registerCommands(gpa, self.commands, &self.buffer_commands);
    }

    pub fn deinit(self: *Editor) void {
        const gpa = self.gpa;
        if (self.vulkan_head) |head| {
            head.deinit();
            gpa.destroy(head);
        } else if (self.memory_render_live) {
            self.render.deinit();
        }
        self.frame_known_peers.deinit();
        // A live picker owns a callback into one of the plugin instances
        // below. Termination delivers cancellation and rejects a reentrant
        // replacement before those instances are destroyed; Session.deinit's
        // second call is then an idempotent no-op.
        self.session.head.pick.terminate(self.ctx);
        for (self.js_plugins.items) |jp| jp.deinit();
        self.js_plugins.deinit(gpa);
        for (self.plugins.items) |p| p.deinit();
        self.plugins.deinit(gpa);
        self.loop.deinit();
        self.subs.deinit(gpa);
        self.register.deinit(gpa);
        // Tear down in main()'s order (shells outlive buffers): detach per-buffer
        // providers, free the Session (buffers/caps/keymap/…), join the pool,
        // then Providers LAST (the persistent shells outlive buffers + workers).
        {
            var it = self.session.system.buffers.iterator();
            while (it.next()) |b| app_providers.detachProviders(&self.prov.attach_deps, b);
        }
        self.session.deinit(gpa);
        self.pool.deinit();
        self.prov.deinit(gpa);
        self.plugin_kv.deinit(gpa);
        self.config_kv.deinit(gpa);
        self.engine.deinit();
    }

    /// Load a reference plugin from its embedded `.wasm` (describe+init run).
    pub fn load(self: *Editor, name: []const u8, wasm: []const u8) !void {
        const p = try core.wasm_abi.loadPlugin(&self.engine, self.ctx, name, wasm, .{
            .kv = &self.plugin_kv,
            .config = &self.config_kv,
            .loop = &self.loop,
            .subbuffers = &self.subs,
            .register = &self.register,
            .syntax_of = app_providers.resolveSyntax,
            .pool = self.pool,
            .grant_table = &self.session.system.grants,
        });
        try self.plugins.append(self.gpa, p);
    }

    /// Mint what `weft.grant(plugin, capability)` mints from config — for a
    /// test that loads a `.js` plugin DIRECTLY (`loadJs`) instead of through
    /// a config manifest, which would mint these itself. Must precede
    /// `loadJs`: that is when a plugin adopts its rows. `plugin`/`capability`
    /// are borrowed by the table (string literals at every call site).
    pub fn grant(self: *Editor, plugin: []const u8, capability: []const u8) !void {
        _ = try self.session.system.grants.grant(.{ .capability = capability }, plugin, null);
    }

    /// Load a resident JS plugin (a quickjs reactor — acp.js / dap.js), named so
    /// it reads its config namespace `weft.set("<name>", …)`. Ticked in settle().
    pub fn loadJs(self: *Editor, name: []const u8, src: []const u8) !void {
        const jp = try core.quickjs.JsPlugin.load(self.gpa, &self.engine, self.ctx, self.pool, parentEnviron(), name, &self.config_kv, src);
        try self.js_plugins.append(self.gpa, jp);
    }

    /// Register the app's collaboration commands (share/listen/peers/…) over
    /// this editor's own connection state, exactly as main() does. Opt-in
    /// rather than part of `init`, because only a test that names those
    /// commands needs them — the plugin catalog and core builtins are the
    /// default surface everywhere else.
    pub fn enableCollabCommands(self: *Editor) !void {
        self.share_ctx = .{
            .gpa = self.gpa,
            .buffers = self.buffers,
            .conn = &self.frame_conn,
            .hub = &self.frame_hub,
            .caps = self.caps,
            .partial = &self.frame_partial_state,
            .session = &self.frame_collab_session,
            .known = &self.frame_known_peers,
        };
        try app_collab_cmds.registerCommands(self.gpa, self.commands, &self.share_ctx, &self.frame_known_peers);
    }

    /// Set a plugin's config value (`weft.set("<plugin>", key, value)`), for
    /// pointing a JS plugin at a test fixture before loading it. The config store
    /// holds a FRAMED blob (uvarint record-count, then uvarint(len)++bytes), the
    /// same shape `weft.set` writes — a single value is one record.
    pub fn setConfig(self: *Editor, plugin: []const u8, key: []const u8, value: []const u8) !void {
        var blob: std.ArrayList(u8) = .empty;
        defer blob.deinit(self.gpa);
        try putUvarint(&blob, self.gpa, 1); // one record
        try putUvarint(&blob, self.gpa, value.len);
        try blob.appendSlice(self.gpa, value);
        try self.config_kv.put(self.gpa, plugin, key, blob.items);
    }

    /// Press a key: `spec` is a keyspec (e.g. "i", "Escape", "C-w", "SPC");
    /// `text` is the character it would type (printable input), or "". Sends the
    /// keypress through the REAL app dispatch (`app/dispatch.dispatchSpec`) — the
    /// same single implementation the compositor path uses after xkb translation
    /// — so chords, menus, text, and every binding behave EXACTLY as in the app.
    /// The harness keeps no parallel dispatch logic. `spec` accepts natural
    /// notation ("SPC"/"RET"); we canonicalize it here (the real path gets the
    /// canonical xkb name for free).
    ///
    /// A thin wrapper over `pressTimed` (the only difference is discarding the
    /// timing) — ONE dispatch path here, not two copies that can drift apart
    /// and quietly invalidate whichever one nothing is watching.
    pub fn press(self: *Editor, spec_in: []const u8, text: []const u8) void {
        _ = self.pressTimed(spec_in, text);
    }

    /// Like `press`, but returns the elapsed nanoseconds of the DISPATCH call
    /// ONLY — `core.task.nowNs()` (the raw-syscall monotonic clock this
    /// codebase already uses for hot-path timing; `std.time.Timer` needs
    /// `std.Io` plumbing this call site has no reason to carry) bracketing
    /// `dispatchSpec`. Key-spec normalization sits outside the timed window,
    /// matching what the real key-to-commit path pays (xkb translation happens
    /// before dispatch too). `press`
    /// delegates here and discards the return, so every ordinary keypress in
    /// the whole e2e suite pays two cheap clock reads — negligible next to a
    /// dispatch, and the price of having only one implementation to trust.
    /// This is the measurement instrument's ONLY hook into the app: it lives
    /// here, on the caller side, so `dispatch.zig` itself carries no timing
    /// and pays nothing when the return value goes unused. See `latency.zig`
    /// for the stats built on top of it, and `latency_test.zig` for the
    /// policy (what/how much to measure, and the regression threshold).
    pub fn pressTimed(self: *Editor, spec_in: []const u8, text: []const u8) u64 {
        // `text` is what this keystroke would commit; the platform's own
        // translation applies (a control byte commits nothing — §10.1).
        const commit: core.TextCommit = .from(text);
        const elapsed = self.inputTimed(spec_in, commit);
        // One injected event is one headless application wake. The lifecycle
        // work stays outside the dispatch-only latency measurement above.
        _ = self.advanceAt(core.task.nowNs(), false) catch {};
        if (self.input_observer) |observer| {
            observer.notify(if (commit.isEmpty()) .command else .text);
        }
        return elapsed;
    }

    fn inputTimed(self: *Editor, spec_in: []const u8, commit: core.TextCommit) u64 {
        var kbuf: [256]u8 = undefined;
        const spec = core.Keymap.normalizeKey(&kbuf, spec_in);
        const start = core.task.nowNs();
        self.application.input(spec, commit) catch {};
        return core.task.nowNs() -| start;
    }

    /// Press each key of a space-separated chord in turn — the natural way to
    /// write a leader sequence in a test: `ed.chord("SPC g i")` drives
    /// SPC→g→i. Non-printable by definition (leader keys), so no text.
    pub fn chord(self: *Editor, seq: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, seq, ' ');
        while (it.next()) |k| self.press(k, "");
    }

    /// Type a run of text the way a person does — one KEYSTROKE at a time through
    /// the real dispatch (`press`), NOT a bulk text-command. So typing composes
    /// with per-key behaviors exactly as at the keyboard: autopair fires on
    /// `(`/`"`, dot-repeat records the inserted chars, a mode's bound key in the
    /// middle of a run behaves as bound. `\n`→Enter, `\t`→Tab; every other
    /// codepoint presses itself.
    pub fn typeText(self: *Editor, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const ch = s[i..@min(i + n, s.len)];
            if (ch.len == 1 and ch[0] == '\n') {
                self.press("Return", "\n");
            } else if (ch.len == 1 and ch[0] == '\t') {
                self.press("Tab", "\t");
            } else {
                self.press(ch, ch);
            }
            i += ch.len;
        }
    }

    /// Run a command by name (a startup action, or a "menu leaf" invoked directly).
    pub fn run(self: *Editor, cmd: []const u8) void {
        _ = command.run(self.commands, self.ctx, cmd, &.{}) catch {};
        self.application.noteInput();
        _ = self.advanceAt(core.task.nowNs(), false) catch {};
    }

    /// Run a command with one string argument (e.g. `open <path>`).
    pub fn runStr(self: *Editor, cmd: []const u8, arg: []const u8) void {
        _ = command.run(self.commands, self.ctx, cmd, &.{.{ .string = arg }}) catch {};
        self.application.noteInput();
        _ = self.advanceAt(core.task.nowNs(), false) catch {};
    }

    /// The current transient echo line (what a plugin last reported to the user).
    pub fn echoText(self: *Editor) []const u8 {
        return self.session.head.echo.items;
    }

    /// Drive complete application wakes until the active buffer's async save
    /// reaches a terminal state — deterministic, no sleep-and-hope.
    ///
    /// Wall-clock bounded, like every other "wait for the pool" helper in this
    /// file (`drainToolContains`, `drainUntilOracle`, `Loopback.pumpUntil`) —
    /// NOT a fixed yield-count. A fixed count of `std.Thread.yield()` calls is
    /// a count of scheduling opportunities, not of elapsed time: under CPU
    /// contention (e.g. another `zig build test` running concurrently in the
    /// same tree) the OS can legitimately decline to run this process's pool
    /// worker for the whole budget, so the loop gave up while the save was
    /// still in flight — `save_state` stuck at `.saving` — and the very next
    /// disk read (or, worse, `requestSave`'s "one in flight is dropped" rule
    /// swallowing the NEXT save request too) saw a file that was never
    /// written. That's the concrete shape of the `c.js`-not-found flake: the
    /// wait raced its own background write, not a fixture-path collision
    /// (every fixture here lives under `Project`'s per-run `mkdtemp`'d
    /// directory, already collision-proof). Same generous bound as the LSP
    /// drains below — a save is cheap, so the happy path returns in a handful
    /// of iterations regardless; the bound only matters as a genuine-hang
    /// backstop.
    pub fn waitSave(self: *Editor) void {
        const deadline = core.task.nowNs() + 30 * std.time.ns_per_s;
        while (core.task.nowNs() < deadline) {
            _ = self.advanceAt(core.task.nowNs(), false) catch {};
            if (self.buffers.active().textEditor().?.save_state != .saving) return;
            std.Thread.yield() catch {};
        }
    }

    /// Advance complete application wakes while background work converges.
    /// This deliberately has no private inventory of async producers: picker,
    /// menu, plugins, backing state, activation, layout, and rendering advance
    /// through the same `Application` lifecycle as the desktop.
    pub fn settle(self: *Editor, rounds: usize) void {
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            _ = self.advanceAt(core.task.nowNs(), false) catch {};
            napUs(2000);
        }
    }

    fn advanceAt(self: *Editor, frame_start: u64, force_rebuild: bool) !app_application.Application.AdvanceResult {
        if (self.vulkan_head) |head| {
            return self.application.advance(&head.render, .{
                .frame_start = frame_start,
                .fb = .{ app_w, app_h },
                .force_rebuild = force_rebuild,
            });
        }
        return self.application.advance(&self.render, .{
            .frame_start = frame_start,
            .fb = .{ app_w, app_h },
            .force_rebuild = force_rebuild,
        });
    }

    // ── inspectors ──
    pub fn textAlloc(self: *Editor) ![]u8 {
        return self.buffers.active().textEditor().?.text().toOwnedSlice(self.gpa);
    }
    pub fn mode(self: *Editor) []const u8 {
        return self.head.currentMode();
    }
    pub fn bufferName(self: *Editor) []const u8 {
        return self.buffers.active().name;
    }
    /// Test-harness convenience: seeds `head`'s mode directly, no
    /// `*command.Context`/dispatch involved (mechanism-not-policy, task #19
    /// item 3) — distinct from `Head.setModeRaw`/`Ctx.setMode` by NAME, but
    /// implemented on the raw mechanism since it exists purely to establish
    /// test fixture state before a scenario drives real dispatch.
    pub fn setMode(self: *Editor, m: []const u8) void {
        self.head.setModeRaw(self.gpa, m) catch {};
    }

    /// Lazily create the harness's persistent View (glyph atlas + metrics),
    /// shared by the single-pane snapshot and the multi-pane composite. `pub`
    /// so a test file can build its OWN custom-sized frame (e.g. the
    /// popup-layout gate's flip/clamp scenarios, which need to choose the
    /// frame geometry deliberately) instead of the fixed `app_w`/`app_h`
    /// `snapshot`/`snapshotPanes` use.
    pub fn ensureView(self: *Editor) !*view_mod.View {
        if (self.vulkan_head) |head| return &head.render.fb.view;
        return &self.render.fb.view;
    }

    /// Write a PPM screenshot of the current frame under `.zig-cache/tmp/` (an
    /// artifact to eyeball; best-effort, never asserts).
    pub fn snapshot(self: *Editor, name: []const u8) void {
        const pixels = self.renderComposite() catch return;
        defer self.gpa.free(pixels);
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, ".zig-cache/tmp/weft-e2e-{s}.ppm", .{name}) catch return;
        harness.writePpm(self.gpa, path, pixels, app_w, app_h) catch {};
    }

    // ── Window layout (multi-pane), driven through the REAL commands ──

    /// Advance one ordinary application wake; window intents are one phase of
    /// that lifecycle, never a harness-selectable operation.
    pub fn applyWindow(self: *Editor) void {
        _ = self.advanceAt(core.task.nowNs(), false) catch {};
    }

    /// Number of panes currently tiled.
    pub fn paneCount(self: *Editor) usize {
        return self.win_layout.count();
    }

    /// Cut this editor over to the selected production renderer on a standard
    /// offscreen Vulkan image. There is no surface, swapchain, WSI extension,
    /// compositor, or platform event pump involved.
    pub fn enableHeadlessVulkan(self: *Editor) !void {
        if (self.vulkan_head != null) return;
        const head = try self.gpa.create(app_headless_vulkan.Head);
        errdefer self.gpa.destroy(head);
        try head.init(self.gpa, app_w, app_h, weft.font_provider.defaultMono(), app_em, self.buffers.active_id);
        errdefer head.deinit();
        self.render.deinit();
        self.memory_render_live = false;
        self.vulkan_head = head;
        self.win_layout = &head.render.fb.win_layout;
        self.application.bindTarget(self.win_layout, &head.render.fb.view);
    }

    /// Build and submit the whole editor frame without waiting for readback.
    /// The paired recorder submits both peers before resolving either fence.
    pub fn submitHeadlessFrameAt(self: *Editor, frame_start: u64) !void {
        const head = self.vulkan_head orelse return error.HeadlessVulkanNotEnabled;
        _ = try self.advanceAt(frame_start, true);
        var attempts: usize = 0;
        while (attempts < 10_000) : (attempts += 1) {
            if (try head.render.present(head.ctx, .{ app_w, app_h }, frame_start, false)) return;
            std.Thread.yield() catch {};
        }
        return error.VulkanSubmitDeferred;
    }

    pub fn readHeadlessFrame(self: *Editor) ![]u8 {
        const head = self.vulkan_head orelse return error.HeadlessVulkanNotEnabled;
        return head.ctx.readFrame(self.gpa);
    }

    /// Ask the editor's production render owner for one complete frame. This
    /// method supplies ordinary frame-loop state and provider attachments; it
    /// does not assemble a HUD, inspect a layer, or choose which surfaces draw.
    /// The returned pixels are copied from the active frame target and owned by
    /// the caller.
    pub fn renderCompositeAt(self: *Editor, frame_start: u64) ![]u8 {
        if (self.vulkan_head != null) {
            try self.submitHeadlessFrameAt(frame_start);
            return self.readHeadlessFrame();
        }
        _ = try self.advanceAt(frame_start, true);
        const complete = try self.render.present(.{ app_w, app_h });
        return self.gpa.dupe(u8, complete.pixels);
    }

    pub fn renderComposite(self: *Editor) ![]u8 {
        return self.renderCompositeAt(core.task.nowNs());
    }

    /// Composite all panes and write a PPM artifact (best-effort; never asserts).
    pub fn snapshotPanes(self: *Editor, name: []const u8) void {
        const pixels = self.renderComposite() catch return;
        defer self.gpa.free(pixels);
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, ".zig-cache/tmp/weft-app-{s}.ppm", .{name}) catch return;
        harness.writePpm(self.gpa, path, pixels, app_w, app_h) catch {};
    }
};

// ── A second head over the SAME session
// (doc/contextual-workspace-architecture.md §7) ──────
//
// Proves two heads sharing one system don't collide: distinct mode/pending
// chord, distinct pick session, distinct echo line, distinct dot-repeat
// register — ALL exercised through the real dispatch path
// (`dispatch.dispatchSpec`/`command.run`), never by poking a `Head`'s fields
// directly. Deliberately NOT a second `Editor` — a second `Editor` stands up
// a second buffer set/keymap/caps/commands (a second SYSTEM); `SecondHead`
// borrows an existing `Editor`'s everything except the one thing that must
// be independent: `core.Head`. Mirrors `core.Head`'s own "two heads over one
// system" unit test (`Head.zig`), but driven through dispatch/command.run
// instead of touching `Pick`/mode fields directly, and over the full app
// stack (real keymap tables, real commands, a real buffer) instead of a
// minimal scaffold.
pub const SecondHead = struct {
    head: core.Head = .empty,
    ctx: command.Context = undefined,

    /// `start_mode` seeds this head's starting mode — a head attaching to an
    /// already-configured system starts in ITS resting mode (mirrors
    /// `Buffers.default_mode`/`setResting`'s "a file opened fresh lands in
    /// the configured mode"), not a bare empty string. mechanism-not-policy
    /// (task #19 item 3), mirroring `System.attachHead`: raw `setModeRaw`
    /// (not `dispatchSpec`/`Ctx.setMode`) — establishing where a
    /// newly-attached head starts is not itself a keystroke, and there is
    /// no `*command.Context` for THIS head yet to capture a `Ctx` from.
    pub fn init(self: *SecondHead, ed: *Editor, start_mode: []const u8) !void {
        self.head = .empty;
        self.ctx = ed.ctx.*; // same buffers/commands/keymap/caps/actions — only `.head` differs
        self.ctx.head = &self.head;
        try self.head.setModeRaw(ed.gpa, start_mode);
    }

    pub fn deinit(self: *SecondHead, gpa: Allocator) void {
        self.head.deinit(gpa);
    }

    /// Press a key AS this head — the same real dispatch `Editor.press` uses.
    pub fn press(self: *SecondHead, spec_in: []const u8, text: []const u8) void {
        var kbuf: [256]u8 = undefined;
        const spec = core.Keymap.normalizeKey(&kbuf, spec_in);
        dispatch.dispatchSpec(&self.ctx, spec, .from(text)) catch {};
    }

    /// Press each key of a space-separated chord in turn (mirrors `Editor.chord`).
    pub fn chord(self: *SecondHead, seq: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, seq, ' ');
        while (it.next()) |k| self.press(k, "");
    }

    /// Type a run of text one keystroke at a time (mirrors `Editor.typeText`).
    pub fn typeText(self: *SecondHead, s: []const u8) void {
        var i: usize = 0;
        while (i < s.len) {
            const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const ch = s[i..@min(i + n, s.len)];
            if (ch.len == 1 and ch[0] == '\n') {
                self.press("Return", "\n");
            } else if (ch.len == 1 and ch[0] == '\t') {
                self.press("Tab", "\t");
            } else {
                self.press(ch, ch);
            }
            i += ch.len;
        }
    }

    /// Run a command by name AS this head (mirrors `Editor.run`).
    pub fn run(self: *SecondHead, cmd: []const u8) void {
        _ = command.run(self.ctx.commands, &self.ctx, cmd, &.{}) catch {};
    }

    /// Apply pending window-layout intents (window-split/focus/move) AS
    /// THIS head — mirrors `Editor.applyWindow`, but against `ed`'s shared
    /// `win_ctx`/`win_layout` with `self.head` as the acting head, so a
    /// focus/split/close recorded by a command THIS head ran lands on
    /// THIS head's handle, not `ed`'s own. The two-head window-op gate
    /// (doc/contextual-workspace-architecture.md §7) drives real split/close/focus
    /// sequences "as" each head through this.
    pub fn applyWindow(self: *SecondHead, ed: *Editor) void {
        _ = window_cmds.applyIntents(
            &ed.win_ctx,
            ed.win_layout,
            &ed.render.fb.view,
            ed.buffers,
            ed.gpa,
            &self.head,
            ed.keymap,
            ed.application.last_frame_rect,
            &ed.session.system.placement,
            &ed.session.system.focus,
        );
    }

    pub fn mode(self: *SecondHead) []const u8 {
        return self.head.currentMode();
    }

    pub fn echoText(self: *SecondHead) []const u8 {
        return self.head.echo.items;
    }
};

/// TestHead — the SECOND head implementation W0b's gate asks for (task W0b
/// item 4, doc/cwa-prior-docs-audit.md §5: "a second head implementation (tty or
/// test-head) attaches through the same grant"): a minimal, harness-driven
/// client wrapping `SecondHead` (above — already "a second `core.Head` on
/// the real session, driven through the real dispatch") with its own named
/// `core.InProcClient` identity, so keypress injection goes through the
/// SAME `beginDispatch`/`endDispatch` bracket `app/window_head.zig`'s
/// `WindowHead.dispatchKey` uses, not a look-alike. This is the concrete
/// proof that the guard-sharing mechanics (W0b item 2/3) are genuinely
/// transport/client-agnostic: two DIFFERENT client identities ("window-head"
/// vs "test-head"), same `core.InProcClient` type, same bracket discipline,
/// same downstream `wasm_host/plugin.zig` `canDispatch` a future
/// `requireDispatch`-gated in-process call would read. Reads a laid-out
/// frame through the SAME scene path the window-head uses too — this
/// struct adds no rendering of its own; a caller drives `Editor.
/// ensureView`/`renderComposite` (below) exactly as it would for the
/// primary head, because the render pipeline is per-SESSION, not per-head
/// (see `app/window_head.zig`'s module doc on what a head owns vs what it
/// shares).
pub const TestHead = struct {
    second: SecondHead = .{},
    client: core.InProcClient = undefined,

    /// Unlike `app/window_head.zig`'s WindowHead (first-party, self-grants
    /// everything), TestHead starts with NO perms granted — a test that
    /// wants to exercise a perm-gated path sets `self.client.perms[...]`
    /// explicitly, so a gate test asserting denial (see
    /// `e2e/test_head_test.zig`) is testing something real, not a tautology
    /// against an identity that already grants itself everything.
    pub fn init(self: *TestHead, ed: *Editor, start_mode: []const u8) !void {
        try self.second.init(ed, start_mode);
        self.client = .{ .name = "test-head", .active_ctx = &self.second.ctx };
    }

    pub fn deinit(self: *TestHead, gpa: Allocator) void {
        self.second.deinit(gpa);
    }

    /// Inject one key spec through the REAL dispatch entry
    /// (`app/dispatch.zig:dispatchSpec`, via `SecondHead.press`), bracketed
    /// by THIS head's `InProcClient.in_dispatch` — see this struct's doc.
    pub fn press(self: *TestHead, spec: []const u8, text: []const u8) void {
        const prior = self.client.beginDispatch();
        defer self.client.endDispatch(prior);
        self.second.press(spec, text);
    }

    /// Press each key of a space-separated chord in turn, each individually
    /// bracketed (mirrors `SecondHead.chord`, but through THIS struct's
    /// guarded `press`).
    pub fn chord(self: *TestHead, seq: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, seq, ' ');
        while (it.next()) |k| self.press(k, "");
    }

    pub fn run(self: *TestHead, cmd: []const u8) void {
        const prior = self.client.beginDispatch();
        defer self.client.endDispatch(prior);
        self.second.run(cmd);
    }

    pub fn mode(self: *TestHead) []const u8 {
        return self.second.mode();
    }

    pub fn echoText(self: *TestHead) []const u8 {
        return self.second.echoText();
    }
};

// ── Loopback TCP multiplayer transport ──────────────────────────────
//
// Two live encrypted Sessions over an actual loopback TCP connection, each
// syncing one editor's document through a real `Collab`. The scenario retains
// the same narrow participant interface, but its transport now exercises the
// production TCP byte stream and the complete authenticated Session handshake.
// Identities are generated in memory for this participant only; no user key
// store is loaded or modified.

const linux = std.os.linux;

pub fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

/// Sleep for roughly `us` microseconds of wall-clock — enough to let each
/// session's reader/writer threads make progress. A raw nanosleep, like
/// watch.zig's `napMs`: `std.Thread.sleep` left std in 0.16, and a yield-spin
/// would hold a core the readers need (every caller waits hundreds of
/// microseconds or more, so nanosleep's granularity is ample).
pub fn napUs(us: u64) void {
    const ns = us * std.time.ns_per_us;
    var req: linux.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (linux.errno(linux.nanosleep(&req, &req)) == .INTR) {}
}

/// A two-peer, in-process collab pair binding two editors' active documents.
/// `host` is the server role, `peer` the client; both are granted `.own` so
/// edits converge in either direction. Presence layers are claimed on both
/// docs so cursors replicate too.
pub const Loopback = struct {
    gpa: Allocator,
    host_ed: *Editor,
    peer_ed: *Editor,
    listener: i32 = -1,
    host_identity: core.identity.Identity,
    peer_identity: core.identity.Identity,
    // FdLinks live here at stable addresses: each Session's Link borrows &fd.
    host_fd: session.FdLink,
    peer_fd: session.FdLink,
    // Keep the generic transport wrappers at stable addresses too. Sessions
    // borrow their Link values while their reader/writer threads are live.
    // The wrappers are zero-latency unless an opt-in demo requests shaping.
    host_chaos: session.ChaosLink,
    peer_chaos: session.ChaosLink,
    host_sess: *session.Session,
    peer_sess: *session.Session,
    host_col: session.Collab,
    peer_col: session.Collab,

    /// Init in place (the FdLinks must not move after the sessions capture
    /// their addresses). Binds the two harnesses' active documents on quad 0.
    pub fn init(
        self: *Loopback,
        gpa: Allocator,
        host_ed: *Editor,
        peer_ed: *Editor,
        host_name: []const u8,
        peer_name: []const u8,
    ) !void {
        self.gpa = gpa;
        self.host_ed = host_ed;
        self.peer_ed = peer_ed;
        self.host_identity = core.identity.Identity.generate();
        self.peer_identity = core.identity.Identity.generate();
        // Loopback callers commonly declare `var link: Loopback = undefined`;
        // default field initializers therefore do not run. Establish the
        // deterministic zero-latency baseline before any optional demo env is
        // inspected.
        // Bind an ephemeral TCP listener first, then connect through the same
        // session transport used by the application. Accepting synchronously
        // is safe here: connect() completes once the kernel has queued the
        // connection, and Session owns the blocking connected fds thereafter.
        self.listener = try session.tcpListener(0);
        errdefer {
            _ = linux.close(self.listener);
            self.listener = -1;
        }
        const port = try session.tcpListenerPort(self.listener);
        const hostport = try std.fmt.allocPrint(gpa, "127.0.0.1:{d}", .{port});
        defer gpa.free(hostport);
        const peer_fd = try session.tcpConnect(hostport);
        errdefer _ = linux.close(peer_fd);
        const host_fd = try session.tcpAccept(self.listener);
        errdefer _ = linux.close(host_fd);
        _ = linux.close(self.listener);
        self.listener = -1;
        self.host_fd = .{ .fd = host_fd };
        self.peer_fd = .{ .fd = peer_fd };
        self.host_chaos = .{};
        try self.host_chaos.start(gpa, self.host_fd.link());
        errdefer self.host_chaos.close();
        self.peer_chaos = .{};
        try self.peer_chaos.start(gpa, self.peer_fd.link());
        errdefer self.peer_chaos.close();
        // Network shaping is a recording concern, not an E2E-test concern.
        // Keep ordinary tests at the same zero-latency TCP path. The request
        // is checked here rather than in core, so production never acquires
        // demo policy or environment handling.
        if (std.c.getenv("WEFT_E2E_VIDEO")) |raw_video| {
            if (std.mem.sliceTo(raw_video, 0).len != 0) {
                const base_ms = envU32("WEFT_E2E_TRANSPORT_BASE_MS", 25, 0, 2000);
                const jitter_ms = envU32("WEFT_E2E_TRANSPORT_JITTER_MS", 95, 0, 2000);
                const seed = envU32("WEFT_E2E_TRANSPORT_SEED", 0x51_7a_11, 0, std.math.maxInt(u32));
                const base_ns = @as(u64, base_ms) * std.time.ns_per_ms;
                const jitter_ns = @as(u64, jitter_ms) * std.time.ns_per_ms;
                const seed64: u64 = seed;
                self.host_chaos.configureLatency(base_ns, jitter_ns, seed64);
                self.peer_chaos.configureLatency(base_ns, jitter_ns, seed64 +% 0xd1b54a32d192ed03);
            }
        }
        // The transport samples the handshake and every later queued write at
        // its own boundary. Capturing more or fewer video frames cannot alter
        // the deterministic network trace.
        const host_doc = &host_ed.buffers.active().textEditor().?.doc;
        const peer_doc = &peer_ed.buffers.active().textEditor().?.doc;
        self.host_sess = try session.Session.create(gpa, self.host_chaos.link(), .server, "loopback", .own, &self.host_identity);
        errdefer self.host_sess.destroy();
        self.peer_sess = try session.Session.create(gpa, self.peer_chaos.link(), .client, "loopback", .own, &self.peer_identity);
        errdefer self.peer_sess.destroy();

        // The frame builder reads this narrow optional session seam for the
        // ordinary connection-status chip. Keep it pointed at the live,
        // authenticated transport rather than inventing harness-only status.
        host_ed.frame_collab_session = self.host_sess;
        peer_ed.frame_collab_session = self.peer_sess;
        errdefer {
            host_ed.frame_collab_session = null;
            peer_ed.frame_collab_session = null;
        }

        const deadline = core.task.nowNs() + 5 * std.time.ns_per_s;
        while ((!self.host_sess.established.load(.acquire) or
            !self.peer_sess.established.load(.acquire)) and
            core.task.nowNs() < deadline) napUs(300);
        if (!self.host_sess.established.load(.acquire) or
            !self.peer_sess.established.load(.acquire)) return error.AuthenticationFailed;
        const host_peer_fp = self.host_sess.peerFingerprint() orelse return error.AuthenticationFailed;
        const peer_peer_fp = self.peer_sess.peerFingerprint() orelse return error.AuthenticationFailed;
        if (!std.mem.eql(u8, &host_peer_fp, &self.peer_identity.fingerprint()) or
            !std.mem.eql(u8, &peer_peer_fp, &self.host_identity.fingerprint()))
            return error.IdentityMismatch;
        self.host_col = try session.Collab.init(gpa, self.host_sess, host_doc, host_name);
        errdefer self.host_col.deinit();
        self.peer_col = try session.Collab.init(gpa, self.peer_sess, peer_doc, peer_name);
        // Replicate cursors: each side folds the other's presence into its own
        // "presence" layer (claimed via the harness caps), exactly as the collab
        // wiring does. Both scenario participants select cursor sharing.
        self.host_col.presence_layer = try host_ed.caps.layers.claim(gpa, host_doc, "presence", .replicated, "collab");
        self.peer_col.presence_layer = try peer_ed.caps.layers.claim(gpa, peer_doc, "presence", .replicated, "collab");
        self.host_col.publish_presence = true;
        self.peer_col.publish_presence = true;
    }

    pub fn deinit(self: *Loopback) void {
        if (self.listener >= 0) {
            _ = linux.close(self.listener);
            self.listener = -1;
        }
        self.host_ed.frame_collab_session = null;
        self.peer_ed.frame_collab_session = null;
        self.host_col.deinit();
        self.peer_col.deinit();
        self.host_sess.destroy();
        self.peer_sess.destroy();
    }

    /// One sync round: drain+handle+push each side, publishing live cursors.
    /// Advance both peers exactly once. Scenarios that synchronize rendering
    /// with collaboration use this narrow clock edge; bounded convergence
    /// assertions should normally prefer `pumpUntil` below.
    pub fn tick(self: *Loopback) !void {
        _ = try self.host_col.tick(self.host_ed.buffers.active().textEditor().?.cursorOffset());
        _ = try self.peer_col.tick(self.peer_ed.buffers.active().textEditor().?.cursorOffset());
    }

    fn sees(collab: *const session.Collab, name: []const u8, offset: usize) bool {
        const presence = collab.presenceNamed(name) orelse return false;
        const resolved = collab.resolvePresence(presence) orelse return false;
        return resolved.head == offset;
    }

    /// Drive the transport until both replicas have folded the cursor state
    /// at this logical frame boundary. A single host-then-peer tick is
    /// asymmetric: the peer posts after the host has already drained, which
    /// made the left screen one half-frame stale. The capture/recorder knows
    /// none of this; the collaboration participant owns its quiescence rule.
    pub fn synchronize(self: *Loopback) !void {
        const host_offset = self.host_ed.buffers.active().textEditor().?.cursorOffset();
        const peer_offset = self.peer_ed.buffers.active().textEditor().?.cursorOffset();
        const deadline = core.task.nowNs() + 5 * std.time.ns_per_s;
        while (core.task.nowNs() < deadline) {
            try self.tick();
            if (sees(&self.host_col, self.peer_col.name, peer_offset) and
                sees(&self.peer_col, self.host_col.name, host_offset)) return;
            napUs(300);
        }
        return error.PresenceDidNotSynchronize;
    }

    /// Pump sync rounds (bounded by wall clock, since the session threads need
    /// real time) until `pred` holds or the timeout elapses. Returns whether it
    /// converged.
    pub fn pumpUntil(self: *Loopback, ctx: anytype, comptime pred: fn (@TypeOf(ctx)) bool) !bool {
        // Wall-clock bounded (the session reader/writer threads deliver on real
        // time). Convergence is ~3ms in practice; the generous deadline is just
        // a safety bound for a genuine failure, and `pred` returns the instant
        // it holds, so the happy path is fast.
        const deadline = core.task.nowNs() + 5 * std.time.ns_per_s;
        while (core.task.nowNs() < deadline) {
            try self.tick();
            if (pred(ctx)) return true;
            napUs(300);
        }
        return false;
    }
};

// ── The guest catalog, embedded for the tests ───────────────────────

const guest = struct {
    const edit = @embedFile("guest_edit_wasm");
    const motions = @embedFile("guest_motions_wasm");
    const textobjects = @embedFile("guest_textobjects_wasm");
    const operators = @embedFile("guest_operators_wasm");
    const vim = @embedFile("guest_vim_wasm");
    const autopair = @embedFile("guest_autopair_wasm");
    const comment = @embedFile("guest_comment_wasm");
    const indent = @embedFile("guest_indent_wasm");
    const lsp = @embedFile("guest_lsp_wasm");
    const files = @embedFile("guest_files_wasm");
    const buffers = @embedFile("guest_buffers_wasm");
    const modes = @embedFile("guest_modes_wasm");
    const notes = @embedFile("guest_notes_wasm");
    const git = @embedFile("guest_git_wasm");
    const whitespace = @embedFile("guest_whitespace_wasm");
    const grep = @embedFile("guest_grep_wasm");
    const run = @embedFile("guest_run_wasm");
    const make = @embedFile("guest_make_wasm");
    const fmt = @embedFile("guest_fmt_wasm");
    const emacs = @embedFile("guest_emacs_wasm");
    const helix = @embedFile("guest_helix_wasm");
    const repl = @embedFile("guest_repl_wasm");
    const console = @embedFile("guest_console_wasm");
    const llm = @embedFile("guest_llm_wasm");
    const which_key = @embedFile("guest_which_key_wasm");
    /// Test fixture only (not installed) — see `src/guest/headtest.zig`'s
    /// module doc: the minimal guest the two-head gate's guest-ABI tests
    /// (`two_head_test.zig`) drive.
    const headtest = @embedFile("guest_headtest_wasm");
};

/// The base editing set under an EMACS keymap (modeless: printable keys self-
/// insert). The coworker in the collab matrix who "uses emacs, but can edit".
pub fn loadEmacs(ed: *Editor) !void {
    try ed.load("edit", guest.edit);
    try ed.load("motions", guest.motions);
    try ed.load("operators", guest.operators);
    try ed.load("emacs", guest.emacs);
    try setResting(ed); // emacs init set "emacs"
}

/// The base editing set under a HELIX keymap (selection-first modal editing).
pub fn loadHelix(ed: *Editor) !void {
    try ed.load("edit", guest.edit);
    try ed.load("motions", guest.motions);
    try ed.load("textobjects", guest.textobjects);
    try ed.load("operators", guest.operators);
    try ed.load("helix", guest.helix);
    try setResting(ed); // helix init set "helix-normal"
}

/// A standard vim editing set (synchronous plugins only — no subprocess).
pub fn loadVim(ed: *Editor) !void {
    try ed.load("edit", guest.edit);
    try ed.load("motions", guest.motions);
    try ed.load("textobjects", guest.textobjects);
    try ed.load("operators", guest.operators);
    try ed.load("comment", guest.comment);
    try ed.load("indent", guest.indent);
    try ed.load("autopair", guest.autopair);
    try ed.load("vim", guest.vim);
    try setResting(ed); // vim init set "normal"; make it the fresh-buffer mode
}

/// The minimal guest-ABI head-addressing test fixture (task #14) — see
/// `src/guest/headtest.zig`'s module doc for its three commands + `on_poll`.
/// Loaded against `ed`'s (head A's) ctx, exactly like every other `load*`
/// helper here — the two-head gate then drives its commands "as" a SECOND
/// head to prove the guest ABI itself is head-addressed.
pub fn loadHeadtest(ed: *Editor) !void {
    try ed.load("headtest", guest.headtest);
}

/// Load ONE grammar from the embedded catalog by name — the load a config's
/// `weft.plugin(name)` performs, without a config in the way. For gates that
/// drive several grammars through the same script (the §10.4 posture gate),
/// where the interesting difference is the grammar, not the config.
pub fn loadGrammar(ed: *Editor, name: []const u8) !void {
    try ed.load(name, plugin_catalog.get(name) orelse return error.UnknownPlugin);
    try setResting(ed);
}

/// Mirror main.zig: after the editor guest has set the base editing mode, capture
/// it as `default_mode` so a file opened fresh (e.g. from *grep*/files) lands in
/// that mode, not stuck in the tool buffer's mode or an empty mode.
fn setResting(ed: *Editor) !void {
    try ed.buffers.setDefaultMode(ed.gpa, ed.head.currentMode());
}

/// The vim set plus the buffer/language/notes/git tools — a fuller "IDE"
/// surface for the multi-step project workflows. proc-backed plugins (git)
/// only do subprocess work when their commands are actually invoked.
pub fn loadWorkspace(ed: *Editor) !void {
    try loadVim(ed);
    try ed.load("whitespace", guest.whitespace);
    try ed.load("buffers", guest.buffers);
    try ed.load("modes", guest.modes);
    try ed.load("notes", guest.notes);
    try ed.load("git", guest.git);
}

/// The workspace plus the hint overlay — for a test that asserts what a user
/// SEES when peeking a mode's keys. `whichKeyText`/`whichKeyShows` read the
/// surface the which_key PLUGIN publishes, so it has to be loaded.
pub fn loadWorkspaceWithHints(ed: *Editor) !void {
    try loadWorkspace(ed);
    try ed.load("which_key", guest.which_key);
}

/// The whole-app spine's plugin surface for the direct Editor harness. The
/// config-driven App already owns lsp through config.js; it does not call this
/// helper, so there is no duplicate plugin instance.
pub fn loadSpine(ed: *Editor) !void {
    try loadWorkspace(ed);
    try ed.load("lsp", guest.lsp);
}

/// The workspace plus the project navigation/build tools — the surface a person
/// uses to actually work a codebase: files (file tree), grep (rg search),
/// run/make (shell out a build/run), fmt (format a buffer). Used by the
/// whole-app "web" e2e verticals.
pub fn loadWebIde(ed: *Editor) !void {
    try loadWorkspace(ed);
    try ed.load("files", guest.files);
    try ed.load("grep", guest.grep);
    try ed.load("run", guest.run);
    try ed.load("make", guest.make);
    try ed.load("fmt", guest.fmt);
}

/// The instantiable session tools: REPLs, consoles, and LLM conversations,
/// each of which owns a buffer per instance.
pub fn loadSessions(ed: *Editor) !void {
    try ed.load("repl", guest.repl);
    try ed.load("console", guest.console);
    try ed.load("llm", guest.llm);
}

/// Focus the buffer displayed under `name` — how a user reaches one instance of
/// an instantiable tool among several.
pub fn focusBuffer(ed: *Editor, name: []const u8) !void {
    const id = ed.buffers.findByName(name) orelse return error.NoSuchBuffer;
    try ed.buffers.switchTo(ed.gpa, id, ed.head, ed.keymap);
}

/// A writable path inside the test's tmpdir (which lives under
/// `.zig-cache/tmp/<sub_path>/`, the codebase's convention — see
/// core/tests.zig). Caller frees.
pub fn tmpPath(gpa: Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

/// Fixture `git` must not read the developer's own config: a global
/// `commit.gpgsign`, `core.hooksPath`, or credential helper there would
/// reshape every fixture commit — or block one on a prompt no test can
/// answer. Prepended below, so these win over an inherited value (getenv
/// takes the first match).
const git_pins = [_]?[*:0]const u8{
    "GIT_CONFIG_GLOBAL=/dev/null",
    "GIT_CONFIG_NOSYSTEM=1",
    "GIT_TERMINAL_PROMPT=0",
};

/// `git_pins` ++ the parent environment, built once and never freed — it
/// outlives every child, exactly as `std.c.environ` does. The suite is
/// sequential (like the chdir below), so the lazy build needs no lock.
var pinned_environ: ?[:null]const ?[*:0]const u8 = null;

/// The parent process's environment as a `std.process.Environ` (the harness
/// links libc, so `std.c.environ` is populated), with the git pins on front.
/// Proc-backed plugins (git/run/grep) need PATH to resolve `git` etc. inside
/// their `/bin/sh -c`, so the harness must hand this to the wasm host exactly
/// as `main()` does at startup (core.wasm_host.setEnviron) — otherwise every
/// subprocess runs PATH-less and silently fails to find its tool. The same
/// block feeds the test's own oracle.
pub fn parentEnviron() std.process.Environ {
    const block = pinned_environ orelse pin: {
        const gpa = std.heap.page_allocator;
        var entries: std.ArrayList(?[*:0]const u8) = .empty;
        entries.appendSlice(gpa, &git_pins) catch @panic("OOM");
        for (std.mem.span(std.c.environ)) |entry| entries.append(gpa, entry) catch @panic("OOM");
        const block = entries.toOwnedSliceSentinel(gpa, null) catch @panic("OOM");
        pinned_environ = block;
        break :pin block;
    };
    return .{ .block = .{ .slice = block } };
}

/// LEB128 uvarint, appended to `out` — for framing a config blob (see setConfig).
fn putUvarint(out: *std.ArrayList(u8), gpa: Allocator, value: usize) !void {
    var v = value;
    while (v >= 0x80) {
        try out.append(gpa, @intCast((v & 0x7f) | 0x80));
        v >>= 7;
    }
    try out.append(gpa, @intCast(v));
}

// This Zig's std dropped ambient process-cwd mutation (part of the `std.Io`
// migration — see the gap note below), so the project harness reaches the raw
// Linux syscalls directly, exactly as session.zig reaches `linux.socket*`.
pub fn getCwdAlloc(gpa: Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    if (@as(isize, @bitCast(rc)) < 0) return error.GetCwd;
    return gpa.dupe(u8, std.mem.sliceTo(buf[0..rc], 0));
}

pub fn chdirTo(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const rc = linux.chdir(@as([*:0]const u8, @ptrCast(&buf)));
    if (@as(isize, @bitCast(rc)) < 0) return error.Chdir;
}

// libc mkdtemp: create a unique 0700 directory from a `…XXXXXX` template (mutated
// in place), returning the path or null. Used to place the throwaway project in
// the SYSTEM tmp, outside any git repo — see Project.
extern "c" fn mkdtemp(template: [*:0]u8) ?[*:0]u8;

/// Backstop for a `command -v` probe (task #23 part B): this execs a shell
/// builtin against PATH, nothing else — a real answer lands in milliseconds,
/// so seconds of slack absorbs a loaded box without ever approaching the old
/// UNBOUNDED wait (`core.proc.run` blocked until the child's EOF, no matter
/// how long that took — see `core.proc.runDeadline`'s doc comment). If this
/// ever actually fires, the shell itself is wedged, not the probed tool.
const tool_probe_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } };

/// Whether `tool` is on PATH (probed through a shell, so it respects the same
/// PATH the proc plugins inherit). Lets a test `return error.SkipZigTest` cleanly
/// when an optional part of the toolchain (see src/e2e/shell.nix — zls, lldb-dap)
/// isn't present, so the suite still passes outside that shell.
///
/// A timeout is treated the same as "not found" (UNAVAILABLE — the caller
/// skips), but LOUDLY: a `command -v` wedging is itself a finding, worth a
/// warn even though the test doesn't fail for it.
pub fn toolAvailable(gpa: Allocator, tool: []const u8) bool {
    const argv = [_][]const u8{ "/bin/sh", "-c", "command -v \"$0\" >/dev/null 2>&1 && printf yes", tool };
    const start = core.task.nowNs();
    var res = core.proc.runDeadline(gpa, &argv, .{ .environ = parentEnviron() }, tool_probe_timeout) catch |err| {
        if (err == error.Timeout) {
            const elapsed_ms = (core.task.nowNs() - start) / std.time.ns_per_ms;
            std.log.warn("toolAvailable({s}): `command -v` timed out after {d}ms (backstop 5s) — treating as unavailable", .{ tool, elapsed_ms });
        }
        return false;
    };
    defer res.deinit(gpa);
    return std.mem.indexOf(u8, res.stdout, "yes") != null;
}

/// Create an isolated directory under the system tmp (`$TMPDIR` or `/tmp`) and
/// return its absolute path (caller frees). Unlike `std.testing.tmpDir` — which
/// nests under `<cwd>/.zig-cache/tmp`, INSIDE this repo — this is a real
/// standalone dir with no git-repo ancestor, so a project here reads as "not a
/// repository" until it runs git-init, exactly like a person's fresh directory.
pub fn makeSystemTmpDir(gpa: Allocator) ![]u8 {
    const base = if (std.c.getenv("TMPDIR")) |p| std.mem.span(p) else "/tmp";
    const suffix = "/weft-e2e-XXXXXX";
    var tmpl: [4096]u8 = undefined;
    if (base.len + suffix.len + 1 > tmpl.len) return error.NameTooLong;
    @memcpy(tmpl[0..base.len], base);
    @memcpy(tmpl[base.len..][0..suffix.len], suffix);
    tmpl[base.len + suffix.len] = 0;
    const made = mkdtemp(@ptrCast(&tmpl)) orelse return error.MkdTemp;
    return gpa.dupe(u8, std.mem.span(made));
}

fn envU32(comptime name: [:0]const u8, fallback: u32, min: u32, max: u32) u32 {
    const raw = std.c.getenv(name) orelse return fallback;
    const value = std.fmt.parseInt(u32, std.mem.sliceTo(raw, 0), 10) catch return fallback;
    return if (value >= min and value <= max) value else fallback;
}

/// Opt-in streaming encoder for the frames emitted by Project.capture.
///
/// Frames are encoded as one PPM at a time and written to ffmpeg's stdin. No
/// frame directory or unbounded in-memory sequence is retained. The encoder is
/// only constructed when WEFT_E2E_VIDEO is set; normal e2e runs do not touch
/// this path.
pub const VideoRecorder = struct {
    gpa: Allocator,
    output_path: []u8,
    io_threaded: ?std.Io.Threaded = null,
    child: ?std.process.Child = null,
    frame_count: usize = 0,
    width: ?u32 = null,
    height: ?u32 = null,
    fps: u32 = 30,

    pub fn init(gpa: Allocator, requested_path: []const u8, base_dir: []const u8) !VideoRecorder {
        const output_path = if (std.fs.path.isAbsolute(requested_path))
            try gpa.dupe(u8, requested_path)
        else
            try std.fs.path.join(gpa, &.{ base_dir, requested_path });
        errdefer gpa.free(output_path);

        const fps = envU32("WEFT_E2E_VIDEO_FPS", 30, 1, 120);
        var recorder: VideoRecorder = .{
            .gpa = gpa,
            .output_path = output_path,
            .fps = fps,
        };
        errdefer recorder.deinit();

        var threaded: std.Io.Threaded = .init(gpa, .{ .environ = parentEnviron() });
        const io = threaded.io();
        if (std.fs.path.dirname(output_path)) |parent| {
            try std.Io.Dir.cwd().createDirPath(io, parent);
        }

        var fps_buf: [16]u8 = undefined;
        const fps_text = std.fmt.bufPrint(&fps_buf, "{d}", .{fps}) catch unreachable;
        const child = std.process.spawn(io, .{
            .argv = &.{
                "ffmpeg",   "-hide_banner", "-loglevel",          "error", "-y",
                "-f",       "image2pipe",   "-vcodec",            "ppm",   "-framerate",
                fps_text,   "-i",           "-",                  "-c:v",  "libx264",
                "-pix_fmt", "yuv420p",      recorder.output_path,
            },
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch |err| {
            threaded.deinit();
            std.log.warn("e2e video: ffmpeg unavailable ({t}); recording disabled", .{err});
            return recorder;
        };
        recorder.io_threaded = threaded;
        recorder.child = child;
        return recorder;
    }

    pub fn active(self: *const VideoRecorder) bool {
        return self.child != null and self.io_threaded != null;
    }

    pub fn record(self: *VideoRecorder, pixels: []const u8, width: u32, height: u32) !void {
        if (!self.active()) return;
        if (self.width) |expected| {
            if (expected != width or self.height.? != height) return error.InvalidFrameSize;
        } else {
            self.width = width;
            self.height = height;
        }

        const header = try std.fmt.allocPrint(self.gpa, "P6\n{d} {d}\n255\n", .{ width, height });
        defer self.gpa.free(header);
        const rgb_len = @as(usize, width) * height * 3;
        const out = try self.gpa.alloc(u8, header.len + rgb_len);
        defer self.gpa.free(out);
        @memcpy(out[0..header.len], header);
        var di = header.len;
        var i: usize = 0;
        while (i < pixels.len) : (i += 4) {
            out[di] = pixels[i];
            out[di + 1] = pixels[i + 1];
            out[di + 2] = pixels[i + 2];
            di += 3;
        }
        const io_threaded = &self.io_threaded.?;
        const stdin = self.child.?.stdin orelse return error.EncoderClosed;
        try stdin.writeStreamingAll(io_threaded.io(), out[0..di]);
        self.frame_count += 1;
    }

    /// Close ffmpeg's image2pipe input and wait for the bounded encoder to
    /// finish. The demo path may block here; normal tests never construct one.
    pub fn finish(self: *VideoRecorder) void {
        if (self.child == null) return;
        const io_threaded = &self.io_threaded.?;
        var child = self.child.?;
        if (child.stdin) |stdin| {
            stdin.close(io_threaded.io());
            child.stdin = null;
        }
        const term = child.wait(io_threaded.io()) catch |err| {
            std.log.warn("e2e video: ffmpeg wait failed ({t})", .{err});
            self.child = null;
            return;
        };
        self.child = null;
        switch (term) {
            .exited => |code| if (code != 0) {
                std.log.warn("e2e video: ffmpeg exited with status {d}", .{code});
            } else {
                std.log.info("e2e video: wrote {s} ({d} frames at {d} fps)", .{ self.output_path, self.frame_count, self.fps });
            },
            else => std.log.warn("e2e video: ffmpeg did not exit normally", .{}),
        }
    }

    pub fn deinit(self: *VideoRecorder) void {
        if (self.child) |*child| {
            child.kill(self.io_threaded.?.io());
            self.child = null;
        }
        if (self.io_threaded) |*threaded| threaded.deinit();
        self.gpa.free(self.output_path);
        self.* = undefined;
    }
};

/// Optional work that advances product state immediately before a demo frame
/// is rendered. The recorder knows nothing about collaboration (or any other
/// subsystem): a scenario binds its own clock participant, and the one frame
/// boundary then observes the resulting state on both screens.
pub const DemoFrameHook = struct {
    context: *anyopaque,
    run: *const fn (*anyopaque) void,

    pub fn init(pointer: anytype) DemoFrameHook {
        const Pointer = @TypeOf(pointer);
        const info = switch (@typeInfo(Pointer)) {
            .pointer => |value| value,
            else => @compileError("demo frame hook must be initialized from a pointer"),
        };
        if (info.size != .one or info.is_const)
            @compileError("demo frame hook requires a mutable single-item pointer");
        const Implementation = info.child;
        const Adapter = struct {
            fn run(raw: *anyopaque) void {
                const implementation: *Implementation = @ptrCast(@alignCast(raw));
                implementation.beforeDemoFrame();
            }
        };
        return .{ .context = pointer, .run = Adapter.run };
    }
};

// ── Project: weft launched IN a real on-disk project ────────────────
//
// The whole-app e2e drives weft the way a person starts a project: in a
// throwaway directory that IS the process CWD, so the proc-backed plugins
// (git/run/grep) operate on it exactly as a real weft launched in a project
// root does (proc children inherit weft's cwd — see core/proc.zig). Per the
// e2e's observation boundary, FILE CONTENT is verified by reading the disk (the
// artifact a human checks), while UI state is read off the rendered surface
// (tool buffers, echo). Nothing pokes editor.doc/CRDT internals.
//
// chdir is process-global and the suite is sequential, so `deinit` restores the
// original cwd before cleanup; screenshots are written to ABSOLUTE paths under
// the original cwd so they survive the tmpdir's removal.
pub const Project = struct {
    gpa: Allocator,
    root: []u8, // absolute path to the project dir (the process cwd while live)
    prev_cwd: []u8, // absolute cwd to restore on deinit
    video: ?VideoRecorder = null,
    demo_left: ?*Editor = null,
    demo_right: ?*Editor = null,
    demo_frame_hook: ?DemoFrameHook = null,
    input_pacing_suspended: bool = false,
    typing_ms: u32 = 110,
    command_ms: u32 = 500,
    linger_ms: u32 = 1500,
    rest_ms: u32 = 2500,

    pub fn init(self: *Project, gpa: Allocator) !void {
        self.gpa = gpa;
        self.video = null;
        self.demo_left = null;
        self.demo_right = null;
        self.demo_frame_hook = null;
        self.input_pacing_suspended = false;
        self.typing_ms = 110;
        self.command_ms = 500;
        self.linger_ms = 1500;
        self.rest_ms = 2500;
        self.prev_cwd = try getCwdAlloc(gpa);
        errdefer gpa.free(self.prev_cwd);
        // A real isolated dir in the system tmp — NOT under this repo — so the
        // project has no git ancestor and behaves like a person's fresh folder.
        self.root = try makeSystemTmpDir(gpa);
        errdefer gpa.free(self.root);
        try chdirTo(self.root);
        errdefer chdirTo(self.prev_cwd) catch {};

        if (std.c.getenv("WEFT_E2E_VIDEO")) |raw_path| {
            const requested_path = std.mem.sliceTo(raw_path, 0);
            if (requested_path.len != 0) {
                self.video = try VideoRecorder.init(gpa, requested_path, self.prev_cwd);
                self.typing_ms = envU32("WEFT_E2E_TYPING_MS", 110, 0, 2000);
                self.command_ms = envU32("WEFT_E2E_COMMAND_MS", 500, 0, 5000);
                self.linger_ms = envU32("WEFT_E2E_LINGER_MS", 1500, 0, 10000);
                self.rest_ms = envU32("WEFT_E2E_REST_MS", 2500, 0, 10000);
            }
        }
    }

    /// True only when the opt-in encoder actually spawned. Normal tests never
    /// enter the demo path, and a missing ffmpeg falls back to ordinary timing.
    pub fn demoEnabled(self: *const Project) bool {
        return if (self.video) |*video| video.active() else false;
    }

    /// Bind the two existing test screens to one capture clock. The caller
    /// owns both Editors and must keep them alive until Project.deinit.
    pub fn bindDemoScreens(self: *Project, left: *Editor, right: *Editor) !void {
        try left.enableHeadlessVulkan();
        try right.enableHeadlessVulkan();
        self.demo_left = left;
        self.demo_right = right;
        if (self.demoEnabled()) {
            const observer: InputObserver = .{
                .context = self,
                .after_input = observeDemoInput,
            };
            left.input_observer = observer;
            right.input_observer = observer;
        }
    }

    fn observeDemoInput(raw: *anyopaque, kind: InputKind) void {
        const self: *Project = @ptrCast(@alignCast(raw));
        if (self.input_pacing_suspended) return;
        self.delay(switch (kind) {
            .text => self.typing_ms,
            .command => self.command_ms,
        });
    }

    /// Add a scenario-owned participant to the synchronized capture clock.
    /// This is deliberately a generic lifecycle seam: the video harness does
    /// not import or identify the subsystem being advanced.
    pub fn bindDemoFrameHook(self: *Project, hook: DemoFrameHook) void {
        self.demo_frame_hook = hook;
    }

    pub fn clearDemoFrameHook(self: *Project) void {
        self.demo_frame_hook = null;
    }

    pub fn deinit(self: *Project) void {
        if (self.video) |*video| {
            video.finish();
            video.deinit();
        }
        chdirTo(self.prev_cwd) catch {};
        // Remove the throwaway tree. `$0` carries the path as an argv, so spaces
        // and specials can't break the command; run from prev_cwd, not inside it.
        if (core.proc.run(self.gpa, &.{ "/bin/sh", "-c", "rm -rf -- \"$0\"", self.root }, .{ .cwd = self.prev_cwd, .environ = parentEnviron() })) |res| {
            var r = res;
            r.deinit(self.gpa);
        } else |_| {}
        self.gpa.free(self.root);
        self.gpa.free(self.prev_cwd);
    }

    /// Absolute path to `name` inside the project (caller frees).
    pub fn path(self: *Project, name: []const u8) ![]u8 {
        return std.fs.path.join(self.gpa, &.{ self.root, name });
    }

    /// Run a shell command to completion in the project and return its trimmed
    /// stdout (caller frees). The test's own on-disk ORACLE — a human running
    /// `git …` in a terminal — never the editor's plugin path; used to verify
    /// content. Runs through `/bin/sh -c` (like the editor's own proc path) so
    /// argv[0] is PATH-resolved — this Zig's `process.spawn` does not itself
    /// search PATH for a bare command name.
    ///
    /// Bounded (task #23 part B, `core.proc.runDeadline`): most oracle
    /// commands are git/ls/printf (well under a second), but
    /// authoring_test.zig also drives a real `clang` compile through here —
    /// bounded generously (tens of seconds) so a genuine compile never trips
    /// it, while a wedged child still fails fast instead of hanging the whole
    /// test binary. Unlike `toolAvailable`, a timed-out oracle is NOT
    /// skippable: it means the test environment itself can't answer a
    /// question about the disk, which is a broken run, not an absent
    /// optional tool — so the error propagates (test FAILURE) after logging
    /// the command and elapsed time that plain `error.Timeout` alone can't
    /// carry.
    const oracle_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } };

    pub fn oracle(self: *Project, sh_cmd: []const u8) ![]u8 {
        const start = core.task.nowNs();
        var res = core.proc.runDeadline(self.gpa, &.{ "/bin/sh", "-c", sh_cmd }, .{ .cwd = self.root, .environ = parentEnviron() }, oracle_timeout) catch |err| {
            if (err == error.Timeout) {
                const elapsed_ms = (core.task.nowNs() - start) / std.time.ns_per_ms;
                std.log.err("oracle(\"{s}\") timed out after {d}ms (backstop 60s) — the test environment can't answer; broken run, not a skippable condition", .{ sh_cmd, elapsed_ms });
            }
            return err;
        };
        defer res.deinit(self.gpa);
        return self.gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
    }

    fn record(self: *Project, pixels: []const u8, width: u32, height: u32) void {
        if (self.video) |*video| {
            video.record(pixels, width, height) catch |err| {
                std.log.warn("e2e video: could not write frame {d}: {t}", .{ video.frame_count, err });
            };
        }
    }

    fn pairPixels(self: *Project) ![]u8 {
        const left = self.demo_left orelse return error.NoDemoScreens;
        const right = self.demo_right orelse return error.NoDemoScreens;
        // Both renders happen inside this one capture operation. There is no
        // per-screen timer: the pair shares one logical frame timestamp.
        const frame_start = core.task.nowNs();
        if (left.vulkan_head != null and right.vulkan_head != null) {
            try left.submitHeadlessFrameAt(frame_start);
            right.submitHeadlessFrameAt(frame_start) catch |err| {
                const orphan = try left.readHeadlessFrame();
                self.gpa.free(orphan);
                return err;
            };
        }
        const left_pixels = if (left.vulkan_head != null)
            try left.readHeadlessFrame()
        else
            try left.renderCompositeAt(frame_start);
        defer self.gpa.free(left_pixels);
        const right_pixels = if (right.vulkan_head != null)
            try right.readHeadlessFrame()
        else
            try right.renderCompositeAt(frame_start);
        defer self.gpa.free(right_pixels);
        const out = try self.gpa.alloc(u8, @as(usize, pair_w) * pair_h * 4);
        var y: usize = 0;
        while (y < pair_h) : (y += 1) {
            const dst = out[y * pair_w * 4 ..][0 .. pair_w * 4];
            const src_left = left_pixels[y * app_w * 4 ..][0 .. app_w * 4];
            const src_right = right_pixels[y * app_w * 4 ..][0 .. app_w * 4];
            @memcpy(dst[0 .. app_w * 4], src_left);
            @memcpy(dst[app_w * 4 ..], src_right);
        }
        return out;
    }

    /// Return one synchronized, completed-frame pair for framebuffer-only
    /// assertions. This is the exact sink operation recording uses, without
    /// writing an artifact or consulting either editor's model.
    pub fn capturePairPixels(self: *Project) ![]u8 {
        if (self.demo_frame_hook) |hook| hook.run(hook.context);
        return self.pairPixels();
    }

    fn frame(self: *Project) void {
        if (self.demo_frame_hook) |hook| hook.run(hook.context);
        const pixels = self.pairPixels() catch return;
        defer self.gpa.free(pixels);
        self.record(pixels, pair_w, pair_h);
    }

    fn delay(self: *Project, ms: u32) void {
        if (!self.demoEnabled() or self.demo_left == null or self.demo_right == null or ms == 0) return;
        const fps = self.video.?.fps;
        const count = (@as(u64, ms) * fps + 999) / 1000;
        const interval_us = @max(@as(u64, 1), 1_000_000 / fps);
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            self.frame();
            napUs(interval_us);
        }
    }

    /// Drive two independent editor heads at the same logical cadence. Each
    /// peer dispatches at most one Unicode scalar before the collaboration
    /// clock and synchronized renderer advance. Normal tests execute the same
    /// interleaving without wall-clock delay or extra frames.
    pub fn typeConcurrently(
        self: *Project,
        left: *Editor,
        left_text: []const u8,
        right: *Editor,
        right_text: []const u8,
    ) void {
        var left_i: usize = 0;
        var right_i: usize = 0;
        while (left_i < left_text.len or right_i < right_text.len) {
            self.input_pacing_suspended = true;
            if (left_i < left_text.len) {
                const n = std.unicode.utf8ByteSequenceLength(left_text[left_i]) catch 1;
                const ch = left_text[left_i..@min(left_i + n, left_text.len)];
                left.typeText(ch);
                left_i += ch.len;
            }
            if (right_i < right_text.len) {
                const n = std.unicode.utf8ByteSequenceLength(right_text[right_i]) catch 1;
                const ch = right_text[right_i..@min(right_i + n, right_text.len)];
                right.typeText(ch);
                right_i += ch.len;
            }
            self.input_pacing_suspended = false;
            self.delay(self.typing_ms);
        }
    }

    /// Hold the current completed editor frames at a deliberate narrative
    /// beat. This is a recording concern only; the ordinary E2E scenario has
    /// no sleep and emits no additional frames.
    pub fn rest(self: *Project) void {
        self.delay(self.rest_ms);
    }

    /// Capture one synchronized pair whenever two screens are bound. Video
    /// mode adds encoding and linger frames; it never selects a different
    /// editor/capture path from the ordinary E2E artifact.
    pub fn capture(self: *Project, ed: *Editor, name: []const u8) void {
        if (self.demo_left != null and self.demo_right != null) {
            if (self.demo_frame_hook) |hook| hook.run(hook.context);
            const pixels = self.pairPixels() catch return;
            const fname = std.fmt.allocPrint(self.gpa, "{s}/.zig-cache/tmp/weft-e2e-{s}.ppm", .{ self.prev_cwd, name }) catch {
                self.gpa.free(pixels);
                return;
            };
            defer self.gpa.free(fname);
            harness.writePpm(self.gpa, fname, pixels, pair_w, pair_h) catch {};
            if (self.demoEnabled()) self.record(pixels, pair_w, pair_h);
            self.gpa.free(pixels);
            if (self.demoEnabled()) self.delay(self.linger_ms);
            return;
        }
        self.shot(ed, name);
    }

    /// Write a composite screenshot to an absolute artifact path that outlives
    /// the tmpdir (best-effort; the e2e leaves frames to eyeball).
    pub fn shot(self: *Project, ed: *Editor, name: []const u8) void {
        const pixels = ed.renderComposite() catch return;
        defer self.gpa.free(pixels);
        const fname = std.fmt.allocPrint(self.gpa, "{s}/.zig-cache/tmp/weft-e2e-{s}.ppm", .{ self.prev_cwd, name }) catch return;
        defer self.gpa.free(fname);
        harness.writePpm(self.gpa, fname, pixels, app_w, app_h) catch {};
        self.record(pixels, app_w, app_h);
    }
};

// ── Booting the REAL config.js ──────────────────────────────────────
//
// The hand-wired loaders above set up a known plugin set; they can't surface
// what's MISSING or bound weird in the sample config. `bootConfig` runs the
// actual `config/config.js` in the quickjs sandbox — the same door main() uses
// — against the embedded catalog, so a test drives the editor a user really
// configured. What the config asks for but we can't load is recorded (a
// finding), not silently dropped.

/// Every reference plugin, keyed by the name a config's `weft.plugin(name)`
/// uses → its embedded wasm (the test module embeds the whole catalog). The
/// analogue of the lib/weft/plugins dir the shipped binary resolves against.
const plugin_catalog = std.StaticStringMap([]const u8).initComptime(.{
    .{ "edit", @embedFile("guest_edit_wasm") },
    .{ "complete", @embedFile("guest_complete_wasm") },
    .{ "project", @embedFile("guest_project_wasm") },
    .{ "palette", @embedFile("guest_palette_wasm") },
    .{ "structural", @embedFile("guest_structural_wasm") },
    .{ "ts", @embedFile("guest_ts_wasm") },
    .{ "region", @embedFile("guest_region_wasm") },
    .{ "shell", @embedFile("guest_shell_wasm") },
    .{ "motions", @embedFile("guest_motions_wasm") },
    .{ "textobjects", @embedFile("guest_textobjects_wasm") },
    .{ "operators", @embedFile("guest_operators_wasm") },
    .{ "vim", @embedFile("guest_vim_wasm") },
    .{ "comment", @embedFile("guest_comment_wasm") },
    .{ "indent", @embedFile("guest_indent_wasm") },
    .{ "lsp", @embedFile("guest_lsp_wasm") },
    .{ "whitespace", @embedFile("guest_whitespace_wasm") },
    .{ "numbers", @embedFile("guest_numbers_wasm") },
    .{ "autopair", @embedFile("guest_autopair_wasm") },
    .{ "consult", @embedFile("guest_consult_wasm") },
    .{ "git", @embedFile("guest_git_wasm") },
    .{ "grep", @embedFile("guest_grep_wasm") },
    .{ "run", @embedFile("guest_run_wasm") },
    .{ "make", @embedFile("guest_make_wasm") },
    .{ "notes", @embedFile("guest_notes_wasm") },
    .{ "fmt", @embedFile("guest_fmt_wasm") },
    .{ "buffers", @embedFile("guest_buffers_wasm") },
    .{ "windows", @embedFile("guest_windows_wasm") },
    .{ "modes", @embedFile("guest_modes_wasm") },
    .{ "snippets", @embedFile("guest_snippets_wasm") },
    .{ "direnv", @embedFile("guest_direnv_wasm") },
    .{ "llm", @embedFile("guest_llm_wasm") },
    .{ "console", @embedFile("guest_console_wasm") },
    .{ "repl", @embedFile("guest_repl_wasm") },
    .{ "net", @embedFile("guest_net_wasm") },
    .{ "http", @embedFile("guest_http_wasm") },
    .{ "which_key", @embedFile("guest_which_key_wasm") },
    .{ "files", @embedFile("guest_files_wasm") },
    .{ "helix", @embedFile("guest_helix_wasm") },
    .{ "emacs", @embedFile("guest_emacs_wasm") },
    .{ "debug", @embedFile("guest_debug_wasm") },
    // The synthetic third-party grammar of the Files conformance gate
    // (src/guest/gramtest.zig) — catalog-resolvable so the gate's config
    // loads it the way a config loads any grammar.
    .{ "gramtest", @embedFile("guest_gramtest_wasm") },
});

/// The PluginLoader `weft.plugin(name)` funnels through during a config boot.
/// Resolves each name against the embedded catalog and loads it onto the
/// editor; records what it couldn't resolve/load so the test can report it.
pub const ConfigLoader = struct {
    ed: *Editor,
    missing: std.ArrayList([]const u8) = .empty, // names not in the catalog
    failed: std.ArrayList([]const u8) = .empty, // resolved but loadPlugin errored
    /// EVERY name `weft.plugin(name)` requested, in request order — the
    /// M3/M4 parity harness's "plugin load-list set-equality" evidence
    /// (config_test.zig): recorded regardless of catalog/load outcome (a
    /// `.js` name included), so two configs with the same catalog list
    /// produce the same set here.
    requested: std.ArrayList([]const u8) = .empty,

    pub fn deinit(self: *ConfigLoader) void {
        for (self.missing.items) |s| self.ed.gpa.free(s);
        for (self.failed.items) |s| self.ed.gpa.free(s);
        for (self.requested.items) |s| self.ed.gpa.free(s);
        self.missing.deinit(self.ed.gpa);
        self.failed.deinit(self.ed.gpa);
        self.requested.deinit(self.ed.gpa);
    }

    fn loadFn(ctx: *anyopaque, name: []const u8) void {
        const self: *ConfigLoader = @ptrCast(@alignCast(ctx));
        const gpa = self.ed.gpa;
        self.requested.append(gpa, gpa.dupe(u8, name) catch return) catch {};
        // The shipped `.js` catalog (build.zig's `js_plugins`, installed
        // beside the .wasm plugins): embedded here the same way, so a config
        // that names one loads it as a resident quickjs plugin.
        const js_catalog = [_]struct { name: []const u8, ns: []const u8, src: []const u8 }{
            .{ .name = "dap.js", .ns = "dap", .src = weft.dap_js },
            .{ .name = "acp.js", .ns = "acp", .src = weft.acp_js },
        };
        for (js_catalog) |entry| {
            if (!std.mem.eql(u8, name, entry.name)) continue;
            self.ed.loadJs(entry.ns, entry.src) catch {
                self.failed.append(gpa, gpa.dupe(u8, name) catch return) catch {};
            };
            return;
        }
        if (std.mem.endsWith(u8, name, ".js")) {
            self.missing.append(gpa, gpa.dupe(u8, name) catch return) catch {};
            return;
        }
        const bytes = plugin_catalog.get(name) orelse {
            self.missing.append(gpa, gpa.dupe(u8, name) catch return) catch {};
            return;
        };
        self.ed.load(name, bytes) catch {
            self.failed.append(gpa, gpa.dupe(u8, name) catch return) catch {};
        };
    }

    pub fn loader(self: *ConfigLoader) core.quickjs.PluginLoader {
        return .{ .ctx = self, .load = loadFn };
    }
};

/// A stable, sorted text snapshot of `requested` — comparable between two
/// `ConfigLoader`s with `expectEqualStrings` (M3/M4 parity: "plugin
/// load-list set-equality").
pub fn requestedPluginsSnapshot(gpa: Allocator, loader_state: *const ConfigLoader) ![]u8 {
    const list = try gpa.dupe([]const u8, loader_state.requested.items);
    defer gpa.free(list);
    std.mem.sort([]const u8, list, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (list) |name| {
        try out.appendSlice(gpa, name);
        try out.append(gpa, '\n');
    }
    return out.toOwnedSlice(gpa);
}

/// A stable, sorted text snapshot of an entire `kv.Store` — namespace, key,
/// and the raw framed value blob — for a "full config-store diff" (M3/M4
/// parity: catches ANY value divergence, not just a hand-picked key).
pub fn kvSnapshot(gpa: Allocator, store: *core.kv.Store) ![]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    var nsit = store.ns.iterator();
    while (nsit.next()) |nse| {
        var kit = nse.value_ptr.iterator();
        while (kit.next()) |ke| {
            const line = try std.fmt.allocPrint(gpa, "{s}\x00{s}\x00{s}\n", .{ nse.key_ptr.*, ke.key_ptr.*, ke.value_ptr.* });
            try lines.append(gpa, line);
        }
    }
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines.items) |l| try out.appendSlice(gpa, l);
    return out.toOwnedSlice(gpa);
}

/// A stable, sorted text snapshot of the keymap's MODE STRUCTURE — which
/// modes are declared menus/sticky-menus/locked/resting, and which modes
/// declare that they commit text (`commitCommand`) — the which-key GROUP
/// structure a bind-only snapshot can't see (M3/M4 parity item 4).
pub fn modeStructureSnapshot(gpa: Allocator, km: *core.Keymap) ![]u8 {
    var names: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer names.deinit(gpa);
    for (km.modes.keys()) |k| try names.put(gpa, k, {});
    for (km.menu_modes.keys()) |k| try names.put(gpa, k, {});
    for (km.commit_commands.keys()) |k| try names.put(gpa, k, {});

    const list = try gpa.dupe([]const u8, names.keys());
    defer gpa.free(list);
    std.mem.sort([]const u8, list, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    // `commitCommand` is a pure function of (tables, mode) — W2a-1's split
    // (Head owns the CURRENT-mode cursor; Keymap only holds tables) means
    // probing every mode name needs no save/restore dance against a live
    // head anymore; it never touches one.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (list) |mode| {
        const txt = km.commitCommand(mode) orelse "<none>";
        const line = try std.fmt.allocPrint(gpa, "{s}|menu={}|sticky={}|resting={}|text={s}\n", .{
            mode, km.isMenuMode(mode), km.isStickyMenu(mode), km.isRestingMode(mode), txt,
        });
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    }
    return out.toOwnedSlice(gpa);
}

/// Boot the editor from the real `config/config.js` (read from `config_dir`,
/// which also resolves its `weft.use("defaults")`). Fills `loader_state` with
/// any plugins the config asked for that couldn't load.
pub fn bootConfig(ed: *Editor, config_dir: []const u8, loader_state: *ConfigLoader) !void {
    try bootConfigNamed(ed, config_dir, "config.js", loader_state);
}

/// Like `bootConfig`, but the config FILE within `config_dir` is named
/// explicitly — the M3/M4 parity harness's door (doc/configuration.md §7): boot
/// `config.js` and `config.northstar.js` from the SAME directory (so both
/// resolve `weft.use("defaults")` identically) into two separate `Editor`s.
pub fn bootConfigNamed(ed: *Editor, config_dir: []const u8, filename: []const u8, loader_state: *ConfigLoader) !void {
    const cfg_path = try std.fmt.allocPrint(ed.gpa, "{s}/{s}", .{ config_dir, filename });
    defer ed.gpa.free(cfg_path);
    const src = try core.file.readAlloc(ed.gpa, cfg_path);
    defer ed.gpa.free(src);
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, loader_state.loader(), &ed.config_kv, config_dir, src);
}

/// A stable, sorted text snapshot of the RESOLVED keymap: every (mode, key)
/// this editor's keymap tables hold, across every mode, mapped to its
/// authored arm list (`|`-joined, so a fallback list is compared whole) —
/// `owner`/`priority` deliberately excluded (two
/// manifests reaching the same resolved table through different tiers is
/// exactly the point being tested, not a difference). Comparable with
/// `expectEqualStrings` between two editors booted from different configs.
pub fn keymapSnapshot(gpa: Allocator, km: *core.Keymap) ![]u8 {
    var lines: std.ArrayList([]u8) = .empty;
    defer {
        for (lines.items) |l| gpa.free(l);
        lines.deinit(gpa);
    }
    var mit = km.modes.iterator();
    while (mit.next()) |me| {
        var kit = me.value_ptr.iterator();
        while (kit.next()) |ke| {
            var arms: std.ArrayList(u8) = .empty;
            defer arms.deinit(gpa);
            for (ke.value_ptr.commands, 0..) |c, i| {
                if (i > 0) try arms.append(gpa, '|');
                try arms.appendSlice(gpa, c);
            }
            const line = try std.fmt.allocPrint(gpa, "{s}\x00{s}\x00{s}\n", .{ me.key_ptr.*, ke.key_ptr.*, arms.items });
            try lines.append(gpa, line);
        }
    }
    std.mem.sort([]u8, lines.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (lines.items) |l| try out.appendSlice(gpa, l);
    return out.toOwnedSlice(gpa);
}

/// A text snapshot of how `actions` resolve across the cross product of
/// `modes` × `langs` (deterministic iteration order — the lists are small,
/// fixed, and given in the same order by both callers, so no sort needed).
/// The action-provider-set analogue of `keymapSnapshot`.
pub fn actionSnapshot(gpa: Allocator, ctx: *command.Context, actions: []const []const u8, modes: []const []const u8, langs: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (actions) |a| for (modes) |m| for (langs) |l| {
        const cmd = ctx.actions.resolve(a, .{ .mode = m, .lang = l }) orelse "<none>";
        const line = try std.fmt.allocPrint(gpa, "{s}|{s}|{s}->{s}\n", .{ a, m, l, cmd });
        defer gpa.free(line);
        try out.appendSlice(gpa, line);
    };
    return out.toOwnedSlice(gpa);
}

/// Read the currently retained which-key surface as the text a user reads.
/// This deliberately does not notify the plugin: doing so would reopen the
/// menu and reset its pagination offset.
fn whichKeySurfaceText(ed: *Editor, gpa: Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (ed.plugins.items) |pl| {
        if (!pl.surface.active) continue;
        for (pl.surface.rows.items) |row| {
            for (row.spans.items) |span| {
                try out.appendSlice(gpa, span.text);
                try out.append(gpa, ' ');
            }
            try out.append(gpa, '\n');
        }
    }
    return out.toOwnedSlice(gpa);
}

/// What the which-key overlay actually SHOWS on screen right now, as the text a
/// user reads. This does NOT re-derive completions from the keymap (that would
/// test what the harness *thinks* which-key shows) — it fires `on_menu` exactly
/// as the app's MenuOverlay does, lets the which_key PLUGIN publish its surface
/// (with its own noise-filtering + config-notation key display), and reads that
/// surface's spans. So `whichKeyText` is literally the rendered overlay content.
/// Caller frees. Empty if no plugin published a menu surface.
pub fn whichKeyText(ed: *Editor, gpa: Allocator) ![]u8 {
    for (ed.plugins.items) |pl| core.wasm_host.notifyMenu(pl, true); // peek (like F1)
    defer for (ed.plugins.items) |pl| core.wasm_host.notifyMenu(pl, false); // leave, including OOM
    return whichKeySurfaceText(ed, gpa);
}

/// Whether the rendered which-key overlay shows `needle` (a key in config
/// notation, or a command name) — i.e. a user peeking the hint would SEE it.
/// Long menus are searched through the real menu-nav page command, keeping the
/// pending prefix intact. This matters when config grows a generic prefix:
/// each declared action remains discoverable even after it crosses PAGE.
pub fn whichKeyShows(ed: *Editor, needle: []const u8) bool {
    defer for (ed.plugins.items) |pl| core.wasm_host.notifyMenu(pl, false);
    var previous = whichKeyText(ed, ed.gpa) catch return false;
    while (true) {
        if (std.mem.indexOf(u8, previous, needle) != null) {
            ed.gpa.free(previous);
            return true;
        }

        // `C-n` is a configured which-key navigation key. It pages the
        // retained surface without feeding the key into the pending chord.
        ed.press("C-n", "");
        const current = whichKeySurfaceText(ed, ed.gpa) catch {
            ed.gpa.free(previous);
            return false;
        };

        // At the final page which-key clamps its offset, so an unchanged
        // surface is the generic end-of-pages signal. No page count or plugin
        // knowledge is needed here.
        if (std.mem.eql(u8, previous, current)) {
            ed.gpa.free(previous);
            ed.gpa.free(current);
            return false;
        }
        ed.gpa.free(previous);
        previous = current;
    }
}

/// Author a file the way a person does: open it (adopts the path), enter
/// insert, type the body, escape, save, and drive the save to disk. The natural
/// motion — `open` then `i…Esc` then `save`. Assumes a normal-editing resting
/// mode (call before entering any tool buffer, so no tool mode swallows typing).
pub fn authorFile(ed: *Editor, name: []const u8, body: []const u8) void {
    ed.runStr("open", name);
    ed.press("i", "");
    ed.typeText(body);
    ed.press("Escape", "");
    ed.run("save");
    ed.waitSave();
}

/// The text of a named TOOL buffer (git/files/echo projections) — these ARE
/// the rendered UI surface, so reading them to assert UI state is fair under
/// the e2e's boundary (real FILE content is read from disk instead). Returns
/// null if no such buffer exists. Caller frees.
pub fn toolText(ed: *Editor, name: []const u8) ?[]u8 {
    var it = ed.buffers.iterator();
    while (it.next()) |b| {
        if (std.mem.eql(u8, b.name, name))
            return b.textEditor().?.text().toOwnedSlice(ed.gpa) catch null;
    }
    return null;
}

/// Drive the async loop until the ACTIVE buffer's own text contains `needle`,
/// bounded by wall clock — the buffer-content counterpart to
/// `drainToolContains`/`drainSurfaceText`/`drainEcho`, for a plugin-authored
/// edit that lands directly in the EDITED buffer (e.g. format-buffer's
/// `procFilter`, task #28) rather than a tool buffer/surface/echo. A fixed
/// `settle(N)` round count is scheduling opportunities, not elapsed time —
/// see `drainEcho`'s doc comment for why that's the wrong bound for an async
/// pool-thread delivery.
pub fn drainBufferContains(ed: *Editor, needle: []const u8) bool {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.settle(3);
        const txt = ed.textAlloc() catch return false;
        defer ed.gpa.free(txt);
        if (std.mem.indexOf(u8, txt, needle) != null) return true;
    }
    return false;
}

/// Drive the async loop until the named tool buffer contains `needle`, bounded
/// by wall clock (the proc drain runs on a pool thread and delivers on real
/// time). Returns whether it appeared. Mirrors the git-status async test's
/// drain, generalized over an arbitrary buffer + needle.
/// Re-fire an async `cmd` until the echo line contains `needle` (or a budget
/// elapses). Re-fires because an LSP request before the server's handshake is
/// declined, not queued — keep asking until the server is ready and one lands,
/// its result echoed (the lsp plugin echoes hover / "no X" messages).
///
/// Bounded by WALL CLOCK, not a round count (task #28): a fixed iteration
/// count is scheduling opportunities, not elapsed time — under CPU
/// contention (or just a slower box) the OS can legitimately decline to run
/// this process's pool worker for whatever the budget assumed, so the loop
/// gives up while the real zls round-trip is still in flight. Same failure
/// shape `waitSave`'s doc comment already names for saves; `drainToolContains`/
/// `drainUntilOracle` already use a real deadline for this reason — this
/// mirrors them instead of round-counting.
pub fn drainEcho(ed: *Editor, cmd: []const u8, needle: []const u8) bool {
    const deadline = core.task.nowNs() + 30 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.run(cmd);
        ed.settle(3);
        if (std.mem.indexOf(u8, ed.echoText(), needle) != null) return true;
    }
    return false;
}

/// A single-shot read of "does ANY plugin's active surface show `needle` in
/// some row's span text" — the same "what does the user actually see"
/// reading `whichKeyText` uses for the which-key overlay, factored out so
/// `drainSurfaceText` (poll until true) and `surfaceGone` (assert false,
/// no re-firing) share one walk instead of two copies.
pub fn surfaceHasText(ed: *Editor, needle: []const u8) bool {
    for (ed.plugins.items) |pl| {
        if (!pl.surface.active) continue;
        for (pl.surface.rows.items) |row| {
            for (row.spans.items) |span| {
                if (std.mem.indexOf(u8, span.text, needle) != null) return true;
            }
        }
    }
    return false;
}

/// `drainEcho`'s counterpart for a producer that shows a retained SURFACE
/// instead of the echo line (rendering P2 — doc/rendering.md — e.g. the
/// `lsp` plugin's hover popup, `wl_surface_caret`). Re-fires `cmd` until
/// `surfaceHasText` is true (or a budget elapses). Wall-clock bounded —
/// see `drainEcho`'s doc comment (task #28).
pub fn drainSurfaceText(ed: *Editor, cmd: []const u8, needle: []const u8) bool {
    const deadline = core.task.nowNs() + 30 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.run(cmd);
        ed.settle(3);
        if (surfaceHasText(ed, needle)) return true;
    }
    return false;
}

/// Fire a completion caps session at `off` and settle until the LSP PLUGIN
/// commits a non-empty result into it — proof the async provider round-trip
/// (on_complete → textDocument/completion → poll → capsCommit) works end to end.
/// Retries the whole fire while the server is still handshaking (an early fire
/// declines, not-ready). Returns true once an `lsp` provider result with items
/// lands; false after the budget.
pub fn drainLspCompletion(ed: *Editor, off: usize, prefix: []const u8) bool {
    var attempt: usize = 0;
    while (attempt < 60) : (attempt += 1) {
        const b = ed.buffers.active();
        const sid = (ed.caps.fire(.completion, &b.textEditor().?.doc, b.textEditor().?.backingPath(), .{
            .offset = off,
            .text = prefix,
        }) catch {
            ed.settle(5);
            continue;
        }) orelse {
            ed.settle(5);
            continue;
        };
        var found = false;
        var i: usize = 0;
        while (i < 80) : (i += 1) {
            ed.settle(2);
            const s = ed.caps.session(sid) orelse break;
            for (s.all()) |r| {
                if (r.payload == .completion and
                    std.mem.indexOf(u8, r.provider, "lsp") != null and
                    r.payload.completion.len > 0)
                {
                    found = true;
                    break;
                }
            }
            if (found or s.done(core.task.nowNs())) break;
        }
        ed.caps.finish(sid);
        if (found) return true;
        ed.settle(10); // let the handshake finish, then re-fire
    }
    return false;
}

/// Like `drainLspCompletion`, but succeeds only when the MERGED completion set
/// contains an item whose text contains `needle` — proves a specific candidate
/// (e.g. a symbol introduced by an edit, so didChange must have synced) actually
/// surfaced, not merely that some result arrived.
pub fn drainCompletionText(ed: *Editor, off: usize, prefix: []const u8, needle: []const u8) bool {
    var attempt: usize = 0;
    while (attempt < 60) : (attempt += 1) {
        const b = ed.buffers.active();
        const sid = (ed.caps.fire(.completion, &b.textEditor().?.doc, b.textEditor().?.backingPath(), .{
            .offset = off,
            .text = prefix,
        }) catch {
            ed.settle(5);
            continue;
        }) orelse {
            ed.settle(5);
            continue;
        };
        var found = false;
        var i: usize = 0;
        while (i < 80) : (i += 1) {
            ed.settle(2);
            const merged = ed.caps.mergedCompletion(ed.gpa, sid) catch &.{};
            for (merged) |it| {
                if (std.mem.indexOf(u8, it.text, needle) != null) found = true;
            }
            ed.gpa.free(merged);
            const s = ed.caps.session(sid) orelse break;
            if (found or s.done(core.task.nowNs())) break;
        }
        ed.caps.finish(sid);
        if (found) return true;
        ed.settle(10);
    }
    return false;
}

/// Re-fire `cmd` until it opens a pick (a references / symbols location list).
/// Wall-clock bounded — see `drainEcho`'s doc comment (task #28).
pub fn drainPick(ed: *Editor, cmd: []const u8) bool {
    const deadline = core.task.nowNs() + 30 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.run(cmd);
        ed.settle(3);
        if (ed.pick.active) return true;
    }
    return false;
}

/// Settle until the active buffer's `diagnostics` layer has at least one span
/// (the language server published), or a budget elapses. The layer's span count
/// is the same rendered state the gutter/underlines draw from. Wall-clock
/// bounded — see `drainEcho`'s doc comment (task #28).
pub fn drainDiagnostics(ed: *Editor) bool {
    const deadline = core.task.nowNs() + 30 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.settle(3);
        if (ed.session.system.caps.layers.find(ed.ctx.document(), "diagnostics")) |l| {
            if (l.spanCount() > 0) return true;
        }
    }
    return false;
}

pub fn drainToolContains(ed: *Editor, name: []const u8, needle: []const u8) bool {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        // Advance the editor's whole frame step: async deliveries, persistent
        // REPL/net streams, wasm polls, and resident JS reactors. A waiter must
        // not maintain its own partial inventory of producers.
        ed.settle(1);
        if (toolText(ed, name)) |txt| {
            defer ed.gpa.free(txt);
            if (std.mem.indexOf(u8, txt, needle) != null) return true;
        }
    }
    return false;
}

/// Drive complete application wakes until there are NO in-flight tasks (every
/// subprocess this `Editor` scheduled — `wl_proc_to_buffer`'s "mutate ;
/// gather" among them — has been delivered), or a timeout. `Loop.tasks`
/// (async.zig) is the pool-wake signal itself: an entry
/// is only removed once `handle.poll()` reports the pool thread actually
/// finished, so `tasks.items.len == 0` is a direct observation of subprocess
/// exit — not an inference from elapsed ticks.
///
/// This is the fix for the git-rebase-interactive flake (task #22): a caller
/// about to fire a SECOND git subprocess in the same worktree (e.g. abort,
/// right after continue) must first prove the first one's `git` process has
/// actually exited, or the two can collide on `.git/index.lock`. The old
/// `ed.settle(50)` used a FIXED round count — the same shape as the `waitSave`
/// flake (see its doc comment): a count of scheduling opportunities, not of
/// elapsed time. `settle`'s rounds each busy-wait a real 2ms via `napUs`, so
/// under light load 50 rounds comfortably outlasts a `git` subprocess — but
/// under CPU contention (a concurrent `zig build`, or plain machine load) the
/// OS can decline to run this process's POOL WORKER thread (a different
/// thread than the one busy-waiting) for the whole ~100ms budget, so the
/// fixed count elapses while the subprocess is still in flight, and the very
/// next git invocation races it for the lock. Wall-clock bounded like every
/// other "wait for the pool" helper in this file (`waitSave`,
/// `drainToolContains`, `drainUntilOracle`) — the loop keeps ticking past any
/// fixed budget as long as real time remains, so it only gives up on a
/// genuine hang.
pub fn drainLoopIdle(ed: *Editor) bool {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.settle(1);
        if (ed.loop.tasks.items.len == 0) return true;
    }
    return false;
}

/// Drive the async loop until the DISK oracle `sh_cmd` reports `needle` (or a
/// timeout). A git mutation (stage/commit) shells out asynchronously — the
/// keypress only SCHEDULES `git add`/`git commit`; application wakes deliver
/// the pool result. Polling the on-disk oracle each round makes the
/// assertion deterministic (disk truth), never a sleep-and-hope. git ops
/// complete in a few ms, so this converges in a handful of rounds.
pub fn drainUntilOracle(proj: *Project, ed: *Editor, sh_cmd: []const u8, needle: []const u8) bool {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.settle(1);
        const out = proj.oracle(sh_cmd) catch {
            continue;
        };
        defer ed.gpa.free(out);
        if (std.mem.indexOf(u8, out, needle) != null) return true;
    }
    return false;
}

/// A booted weft in a throwaway project: the REAL `config.js` loaded, driving in
/// a tmp dir that is the process cwd. The one-call setup every config-driven
/// exploratory test wants — drive `app.ed` through the real bindings, verify
/// `app.proj` on disk. `config_dir` is the repo's `config/` (Project captured
/// the repo root as `prev_cwd` before chdir'ing into the tmp project).
pub const App = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    pub fn init(self: *App, gpa: Allocator) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{self.proj.prev_cwd});
        defer gpa.free(config_dir);
        try bootConfig(&self.ed, config_dir, &self.loader);
        try setResting(&self.ed); // mirror main.zig: config's base mode → default_mode
    }

    pub fn deinit(self: *App) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};
