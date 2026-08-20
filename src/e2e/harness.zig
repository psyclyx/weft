//! e2e/harness — the HEADLESS integration harness that drives the full editor
//! the way a person does: boot the real config (or load plugins), press keys
//! through the keymap (so bound keys, chords, and modes behave exactly as in the
//! app), type text, run commands, and observe the rendered surface + disk. It
//! renders frames to PPM artifacts under `.zig-cache/tmp/` so a run leaves
//! screenshots to eyeball.
//!
//! The point (per the design brief): approach a task as "the natural way to do
//! X in weft is to press Y". If Y doesn't exist, is bound weird, or is more
//! painful than it should be, that difficulty is the SIGNAL — fix the core/
//! plugin/config, don't write a weird test to match. This file is the shared
//! driver; the per-concern test files (editing/window/collab/project/config/
//! teardown) import it and are pulled together by `e2e.zig`.

const std = @import("std");
pub const snail = @import("snail");
// The weft app (core + gfx + app) reaches this subdir as ONE named module wired
// in build.zig (src/weft.zig barrel) — no `../` reach-arounds across the tree.
const weft = @import("weft");
pub const core = weft.core;
const view_mod = weft.view;
const harness = weft.gfx_harness;
pub const window_layout = weft.window_layout;
const window_cmds = weft.window_cmds;
pub const app_session = weft.app_session;
pub const app_providers = weft.app_providers;
pub const app_collab = weft.app_collab;
pub const region = weft.region;

// Re-exports so the per-concern test files can alias what they need from this
// one harness module (`const core = h.core;` etc.) without their own imports.
pub const session = core.session;
pub const gfx_harness = harness; // aliased as `harness` in the window tests

const Allocator = std.mem.Allocator;
const command = core.command;

/// Headless framebuffer geometry for the App harness's composite snapshots.
pub const app_w: u32 = 640;
pub const app_h: u32 = 400;
pub const app_em: f32 = 16;

/// A full editor, headless. Owns the buffers/commands/keymap/caps and a live
/// plugin set; drives them through the same command + keymap surface main.zig
/// uses.
pub const Editor = struct {
    gpa: Allocator,
    pool: *core.task.Pool,
    buffers: core.Buffers,
    commands: command.Commands,
    keymap: core.Keymap,
    pick: core.pick.Pick,
    caps: core.Caps,
    actions: core.Actions,
    quit: bool = false,
    echo: std.ArrayList(u8) = .empty,
    ctx: command.Context = undefined,
    engine: core.wasm.Engine,
    plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty,
    plugin_kv: core.kv.Store = .empty,
    config_kv: core.kv.Store = .empty,
    loop: core.async_loop.Loop,
    subs: core.subbuffer.SubBuffers = .empty,
    register: core.register = .empty,
    view: ?view_mod.View = null,
    /// Last active buffer id — so a buffer switch (open, buffer-next) fires
    /// `on_activate` to plugins, exactly as main's loop does.
    last_active: core.Buffers.Id = 0,

    // ── Window layout (multi-pane) ──
    /// The recursive pane tree, driven by the REAL window-layout commands
    /// (window-split/focus/move) through `window_cmds.applyIntents`, exactly as
    /// main's frame loop drives it.
    win_layout: window_layout.Layout = undefined,
    win_ctx: window_cmds.WindowCtx = .{},
    /// Stable backing for the window commands' data pointers (registerCommands).
    win_actions: [window_cmds.cmd_count]window_cmds.WindowActionCtx = undefined,
    /// Last render's pane frame — geometry for focus/move-by-direction intents.
    last_frame_rect: region.Rect = .{ .x = 0, .y = 0, .w = app_w, .h = app_h },

    pub fn init(gpa: Allocator, self: *Editor) !void {
        return initNamed(gpa, self, "user");
    }

    /// Like `init`, but names the user/agent — so two harnesses sharing a
    /// document over the collab loopback are DISTINCT CRDT replicas (identical
    /// agent names would collide event ids and corrupt the merge).
    pub fn initNamed(gpa: Allocator, self: *Editor, user: []const u8) !void {
        self.quit = false;
        self.echo = .empty;
        self.plugins = .empty;
        self.plugin_kv = .empty;
        self.config_kv = .empty;
        self.subs = .empty;
        self.register = .empty;
        self.view = null;
        self.pool = try core.task.Pool.init(gpa, .{ .threads = 2 });
        self.gpa = gpa;
        self.commands = .empty;
        self.keymap = .empty;
        self.pick = .empty;
        self.caps = core.Caps.init(gpa, core.task.nowNs);
        self.actions = core.Actions.init(gpa);
        self.engine = try core.wasm.Engine.init();
        self.loop = core.async_loop.Loop.init(gpa, self.pool, core.task.nowNs);
        self.buffers = try core.Buffers.init(gpa, self.pool, user);
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .actions = &self.actions,
            .pick = &self.pick,
            .caps = &self.caps,
            .quit = &self.quit,
            .echo = &self.echo,
        };
        try core.builtins.install(gpa, &self.commands, &self.keymap, &self.actions);
        // Proc-backed plugins (git/run/grep) shell out through the wasm host,
        // which passes this process-global environ to each child. main() sets it
        // at startup; the harness must too, or every subprocess runs PATH-less
        // and can't find its tool (git-init would silently no-op). Set to the
        // real parent env — the faithful, main()-matching model.
        core.wasm_host.setEnviron(parentEnviron());
        // Window layout: own the real pane tree and bind the real window
        // commands onto our command surface (window-split/focus/move → intents
        // applied by window_cmds.applyIntents), exactly like main().
        self.win_ctx = .{};
        self.last_frame_rect = .{ .x = 0, .y = 0, .w = app_w, .h = app_h };
        self.win_layout = try window_layout.Layout.init(gpa, self.buffers.active_id);
        try window_cmds.registerCommands(gpa, &self.commands, &self.win_ctx, &self.win_actions);
        self.last_active = self.buffers.active_id;
    }

    /// Mirror main's loop: when the active buffer changes, fire `on_activate`
    /// to every plugin with the new buffer's path — this is what lets the
    /// `modes` plugin detect a file's language the moment you open it.
    fn syncActivate(self: *Editor) void {
        if (self.buffers.active_id == self.last_active) return;
        self.last_active = self.buffers.active_id;
        const b = self.buffers.active();
        const path = b.editor.backingPath() orelse b.name;
        for (self.plugins.items) |p| core.wasm_host.notifyActivate(p, path);
    }

    pub fn deinit(self: *Editor) void {
        const gpa = self.gpa;
        self.win_layout.deinit();
        for (self.plugins.items) |p| p.deinit();
        self.plugins.deinit(gpa);
        if (self.view) |*v| v.deinit();
        self.loop.deinit();
        self.subs.deinit(gpa);
        self.register.deinit(gpa);
        self.actions.deinit();
        self.caps.deinit();
        self.pick.deinit(gpa);
        self.keymap.deinit(gpa);
        self.commands.deinit(gpa);
        self.echo.deinit(gpa);
        self.buffers.deinit(gpa);
        self.plugin_kv.deinit(gpa);
        self.config_kv.deinit(gpa);
        self.engine.deinit();
        self.pool.deinit();
    }

    /// Load a reference plugin from its embedded `.wasm` (describe+init run).
    pub fn load(self: *Editor, name: []const u8, wasm: []const u8) !void {
        const p = try core.wasm_abi.loadPlugin(&self.engine, &self.ctx, name, wasm, .{
            .kv = &self.plugin_kv,
            .config = &self.config_kv,
            .loop = &self.loop,
            .subbuffers = &self.subs,
            .register = &self.register,
            .pool = self.pool,
        });
        try self.plugins.append(self.gpa, p);
    }

    /// Press a key: `spec` is a keyspec (e.g. "i", "Escape", "C-w", "SPC");
    /// `text` is the character it would type (printable input), or "". Mirrors
    /// app/dispatch.zig `dispatchKey` FAITHFULLY — through `keymap.feed`, so
    /// multi-key CHORDS work: pressing "SPC" then "g" then "i" walks the leader
    /// sequence to `git-init`, exactly as a user does under the real config.
    /// (The old lookup-based path only saw single keys — it could never drive
    /// the SPC leader tree the sample config is built on.)
    pub fn press(self: *Editor, spec_in: []const u8, text: []const u8) void {
        self.ctx.user_initiated = true; // a keystroke: helper-plugin edits are the user's
        defer self.ctx.user_initiated = false;
        // Canonicalize natural notation ("SPC"→"space", "RET"→"Return") — `bind`
        // stores canonical and `feed` matches it (the real dispatch gets the
        // canonical xkb name for free; a test writes what it means).
        var kbuf: [256]u8 = undefined;
        const spec = core.Keymap.normalizeKey(&kbuf, spec_in);
        // Mid-chord meta keys act on the which-key overlay, not the sequence.
        if (self.keymap.pending.len > 0) {
            if (std.mem.eql(u8, spec, "BackSpace")) {
                self.keymap.popPending(self.gpa) catch {};
                return;
            }
            if (self.keymap.navCommand(spec)) |cmd| {
                _ = command.run(&self.commands, &self.ctx, cmd, &.{}) catch {};
                return;
            }
        }
        switch (self.keymap.feed(self.gpa, spec) catch core.Keymap.Feed.none) {
            .pending, .none => return, // chord extends, or a dead end — nothing to run
            .text => {}, // a lone unbound key — fall through to text insertion
            .run => |cmd_name| {
                if (self.keymap.isMenuMode(cmd_name)) {
                    self.keymap.enterMode(self.gpa, cmd_name) catch {};
                    self.syncActivate();
                    return;
                }
                const menu_before: ?[]u8 = if (self.keymap.isMenuMode(self.keymap.currentMode()))
                    self.gpa.dupe(u8, self.keymap.currentMode()) catch null
                else
                    null;
                defer if (menu_before) |m| self.gpa.free(m);
                const result = command.run(&self.commands, &self.ctx, cmd_name, &.{}) catch command.Value.nil;
                switch (result) {
                    .string => |s| if (s.len > 0) {
                        self.echo.clearRetainingCapacity();
                        self.echo.appendSlice(self.gpa, s) catch {};
                    },
                    else => {},
                }
                if (menu_before) |m| {
                    if (!self.keymap.isStickyMenu(m) and std.mem.eql(u8, self.keymap.currentMode(), m)) {
                        if (self.keymap.menuReturn(m)) |ret| self.keymap.setMode(self.gpa, ret) catch {};
                    }
                }
                self.syncActivate();
                return;
            },
        }
        if (text.len == 0) return;
        if (self.keymap.textCommand()) |tc| {
            _ = command.run(&self.commands, &self.ctx, tc, &.{.{ .string = text }}) catch {};
        }
        self.syncActivate();
    }

    /// Press each key of a space-separated chord in turn — the natural way to
    /// write a leader sequence in a test: `ed.chord("SPC g i")` drives
    /// SPC→g→i. Non-printable by definition (leader keys), so no text.
    pub fn chord(self: *Editor, seq: []const u8) void {
        var it = std.mem.tokenizeScalar(u8, seq, ' ');
        while (it.next()) |k| self.press(k, "");
    }

    /// Type a run of printable text through the active mode's text command
    /// (bulk insert; use `press` for keys that trigger bindings like autopair).
    pub fn typeText(self: *Editor, s: []const u8) void {
        self.ctx.user_initiated = true;
        defer self.ctx.user_initiated = false;
        if (self.keymap.textCommand()) |tc| {
            _ = command.run(&self.commands, &self.ctx, tc, &.{.{ .string = s }}) catch {};
        }
    }

    /// Run a command by name (a startup action, or a "menu leaf" invoked directly).
    pub fn run(self: *Editor, cmd: []const u8) void {
        _ = command.run(&self.commands, &self.ctx, cmd, &.{}) catch {};
        self.syncActivate();
    }

    /// Run a command with one string argument (e.g. `open <path>`).
    pub fn runStr(self: *Editor, cmd: []const u8, arg: []const u8) void {
        _ = command.run(&self.commands, &self.ctx, cmd, &.{.{ .string = arg }}) catch {};
        self.syncActivate();
    }

    /// The current transient echo line (what a plugin last reported to the user).
    pub fn echoText(self: *Editor) []const u8 {
        return self.echo.items;
    }

    /// Drive the active buffer's async save to completion (bounded spin), the
    /// same poll main's loop does — deterministic, no sleep-and-hope.
    pub fn waitSave(self: *Editor) void {
        var i: usize = 0;
        while (i < 10_000) : (i += 1) {
            if (self.buffers.active().editor.pollSave(self.gpa)) return;
            std.Thread.yield() catch {};
        }
    }

    /// Pump async plugin work (proc output, fs listings) to completion-ish:
    /// tick the loop a bounded number of times with small sleeps.
    pub fn settle(self: *Editor, rounds: usize) void {
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            _ = self.loop.tick();
            for (self.plugins.items) |p| _ = core.wasm_host.drainReplSessions(p);
            std.Thread.sleep(2 * std.time.ns_per_ms);
        }
    }

    // ── inspectors ──
    pub fn textAlloc(self: *Editor) ![]u8 {
        return self.buffers.active().editor.text().toOwnedSlice(self.gpa);
    }
    pub fn mode(self: *Editor) []const u8 {
        return self.keymap.currentMode();
    }
    pub fn bufferName(self: *Editor) []const u8 {
        return self.buffers.active().name;
    }
    pub fn setMode(self: *Editor, m: []const u8) void {
        self.keymap.setMode(self.gpa, m) catch {};
    }

    /// Lazily create the harness's persistent View (glyph atlas + metrics),
    /// shared by the single-pane snapshot and the multi-pane composite.
    fn ensureView(self: *Editor) !*view_mod.View {
        if (self.view == null) self.view = try view_mod.View.init(self.gpa, @embedFile("font_mono"), app_em);
        return &self.view.?;
    }

    /// Write a PPM screenshot of the current frame under `.zig-cache/tmp/` (an
    /// artifact to eyeball; best-effort, never asserts).
    pub fn snapshot(self: *Editor, name: []const u8) void {
        const v = self.ensureView() catch return;
        const hud: view_mod.Hud = .{
            .mode = self.keymap.currentMode(),
            .file = self.buffers.active().name,
            .pick = if (self.pick.active) &self.pick else null,
        };
        const pixels = harness.renderView(self.gpa, v, &self.buffers.active().editor, hud, app_w, app_h) catch return;
        defer self.gpa.free(pixels);
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, ".zig-cache/tmp/weft-e2e-{s}.ppm", .{name}) catch return;
        harness.writePpm(self.gpa, path, pixels, app_w, app_h) catch {};
    }

    // ── Window layout (multi-pane), driven through the REAL commands ──

    /// Apply any pending window-layout intents (window-split/focus/move recorded
    /// by the bound commands) through the REAL frame-loop applier — mutating the
    /// pane tree and keeping the focused pane on the active buffer. Mirrors
    /// main()'s `window_cmds.applyIntents` call.
    pub fn applyWindow(self: *Editor) void {
        const v = self.ensureView() catch return;
        _ = window_cmds.applyIntents(&self.win_ctx, &self.win_layout, v, &self.buffers, self.gpa, &self.keymap, self.last_frame_rect);
    }

    /// Number of panes currently tiled.
    pub fn paneCount(self: *Editor) usize {
        return self.win_layout.count();
    }

    /// Render EVERY pane headlessly and composite into one RGBA8 framebuffer
    /// (caller frees) — the headless analogue of the frame loop's `renderPanes`
    /// + `present`. Panes are laid out by the real window layout; each builds its
    /// own buffer into its slot rect (identity transform); the focused pane uses
    /// the shared view scroll + caret, the others their own scroll. Records
    /// `last_frame_rect` so subsequent focus/move-by-direction intents resolve
    /// against real geometry.
    pub fn renderComposite(self: *Editor) ![]u8 {
        const gpa = self.gpa;
        const v = try self.ensureView();
        const frame: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(app_w), .h = @floatFromInt(app_h) };
        self.last_frame_rect = frame;
        var slots: [window_layout.max_panes]window_layout.Slot = undefined;
        const n = self.win_layout.collect(frame, &slots);

        const projection = snail.Mat4.ortho(0, @floatFromInt(app_w), @floatFromInt(app_h), 0, -1, 1);
        const w2p = snail.mvpToScenePixel(projection, @floatFromInt(app_w), @floatFromInt(app_h)) orelse unreachable;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        v.resetFrame();

        var built: std.ArrayList(view_mod.Built) = .empty;
        defer {
            for (built.items) |*b| b.deinit(gpa);
            built.deinit(gpa);
        }
        for (slots[0..n]) |slot| {
            const b = self.buffers.get(slot.pane.buffer_id) orelse self.buffers.active();
            const hud: view_mod.Hud = .{
                .mode = self.keymap.currentMode(),
                .file = b.editor.backingPath() orelse b.name,
                .cursor_on = slot.focused, // the caret belongs to the focused pane
                .pane_border = slot.border,
            };
            const top_row: *usize = if (slot.focused) &v.top_row else &slot.pane.top_row;
            const bp = try v.build(arena.allocator(), &b.editor, hud, top_row, slot.rect, .{}, w2p);
            try built.append(gpa, bp);
        }
        return harness.renderBuilt(gpa, v, built.items, app_w, app_h);
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

// ── In-process multiplayer loopback ─────────────────────────────────
//
// Two live encrypted Sessions over a socketpair, each syncing one editor's
// document through a real `Collab`. This is the harness analogue of two peers
// connected over TCP — it drives the REAL session sync path (Session handshake
// + Collab drain/handleFrame/push), the same code `collab.tickCollab` calls
// under the hood, without standing up a socket server. It closes the "no
// in-process collab loopback" gap the project notes called out.

const linux = std.os.linux;

pub fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

/// Yield for roughly `us` microseconds of wall-clock — enough to let each
/// session's reader/writer threads make progress (a tight spin would starve
/// them). Mirrors session.zig's own test helper.
pub fn napUs(us: u64) void {
    const deadline = core.task.nowNs() + us * std.time.ns_per_us;
    while (core.task.nowNs() < deadline) std.Thread.yield() catch {};
}

/// A two-peer, in-process collab pair binding two editors' active documents.
/// `host` is the server role, `peer` the client; both are granted `.own` so
/// edits converge in either direction. Presence layers are claimed on both
/// docs so cursors replicate too.
pub const Loopback = struct {
    gpa: Allocator,
    host_ed: *Editor,
    peer_ed: *Editor,
    // FdLinks live here at stable addresses: each Session's Link borrows &fd.
    host_fd: session.FdLink,
    peer_fd: session.FdLink,
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
        const fds = try socketPair();
        self.gpa = gpa;
        self.host_ed = host_ed;
        self.peer_ed = peer_ed;
        self.host_fd = .{ .fd = fds[0] };
        self.peer_fd = .{ .fd = fds[1] };
        const host_doc = &host_ed.buffers.active().editor.doc;
        const peer_doc = &peer_ed.buffers.active().editor.doc;
        self.host_sess = try session.Session.create(gpa, self.host_fd.link(), .server, "loopback", .own, null);
        errdefer self.host_sess.destroy();
        self.peer_sess = try session.Session.create(gpa, self.peer_fd.link(), .client, "loopback", .own, null);
        errdefer self.peer_sess.destroy();
        self.host_col = try session.Collab.init(gpa, self.host_sess, host_doc, host_name);
        errdefer self.host_col.deinit();
        self.peer_col = try session.Collab.init(gpa, self.peer_sess, peer_doc, peer_name);
        // Replicate cursors: each side folds the other's presence into its own
        // "presence" layer (claimed via the harness caps), exactly as the collab
        // wiring does. Publishing is on by default.
        self.host_col.presence_layer = try host_ed.caps.layers.claim(gpa, host_doc, "presence", .replicated, "collab");
        self.peer_col.presence_layer = try peer_ed.caps.layers.claim(gpa, peer_doc, "presence", .replicated, "collab");
    }

    pub fn deinit(self: *Loopback) void {
        self.host_sess.destroy();
        self.peer_sess.destroy();
        self.host_col.deinit();
        self.peer_col.deinit();
    }

    /// One sync round: drain+handle+push each side, publishing live cursors.
    fn tickOnce(self: *Loopback) !void {
        _ = try self.host_col.tick(self.host_ed.buffers.active().editor.cursorOffset());
        _ = try self.peer_col.tick(self.peer_ed.buffers.active().editor.cursorOffset());
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
            try self.tickOnce();
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
    const dired = @embedFile("guest_dired_wasm");
    const buffers = @embedFile("guest_buffers_wasm");
    const modes = @embedFile("guest_modes_wasm");
    const notes = @embedFile("guest_notes_wasm");
    const git = @embedFile("guest_git_wasm");
    const whitespace = @embedFile("guest_whitespace_wasm");
    const grep = @embedFile("guest_grep_wasm");
    const run = @embedFile("guest_run_wasm");
    const make = @embedFile("guest_make_wasm");
    const fmt = @embedFile("guest_fmt_wasm");
};

/// A standard vim editing set (synchronous plugins only — no subprocess).
pub fn loadVim(ed: *Editor) !void {
    try ed.load("edit", guest.edit);
    try ed.load("motions", guest.motions);
    try ed.load("textobjects", guest.textobjects);
    try ed.load("operators", guest.operators);
    try ed.load("comment", guest.comment);
    try ed.load("autopair", guest.autopair);
    try ed.load("vim", guest.vim);
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

/// The workspace plus the project navigation/build tools — the surface a person
/// uses to actually work a codebase: dired (file tree), grep (rg search),
/// run/make (shell out a build/run), fmt (format a buffer). Used by the
/// whole-app "web" e2e verticals.
pub fn loadWebIde(ed: *Editor) !void {
    try loadWorkspace(ed);
    try ed.load("dired", guest.dired);
    try ed.load("grep", guest.grep);
    try ed.load("run", guest.run);
    try ed.load("make", guest.make);
    try ed.load("fmt", guest.fmt);
}

/// A writable path inside the test's tmpdir (which lives under
/// `.zig-cache/tmp/<sub_path>/`, the codebase's convention — see
/// core/tests.zig). Caller frees.
pub fn tmpPath(gpa: Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

/// The parent process's environment as a `std.process.Environ` (the harness
/// links libc, so `std.c.environ` is populated). Proc-backed plugins (git/run/
/// grep) need PATH to resolve `git` etc. inside their `/bin/sh -c`, so the
/// harness must hand this to the wasm host exactly as `main()` does at startup
/// (core.wasm_host.setEnviron) — otherwise every subprocess runs PATH-less and
/// silently fails to find its tool. The same block feeds the test's own oracle.
pub fn parentEnviron() std.process.Environ {
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
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
    td: std.testing.TmpDir,
    root: []u8, // absolute path to the project dir (the process cwd while live)
    prev_cwd: []u8, // absolute cwd to restore on deinit

    pub fn init(self: *Project, gpa: Allocator) !void {
        self.gpa = gpa;
        self.prev_cwd = try getCwdAlloc(gpa);
        errdefer gpa.free(self.prev_cwd);
        self.td = std.testing.tmpDir(.{});
        // The testing tmpdir lives at `<cwd>/.zig-cache/tmp/<sub_path>` (the
        // codebase convention — see tmpPath); make its absolute form the process
        // cwd so proc-backed plugins operate on it.
        self.root = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/{s}", .{ self.prev_cwd, self.td.sub_path[0..] });
        errdefer gpa.free(self.root);
        try chdirTo(self.root);
    }

    pub fn deinit(self: *Project) void {
        chdirTo(self.prev_cwd) catch {};
        self.td.cleanup();
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
    pub fn oracle(self: *Project, sh_cmd: []const u8) ![]u8 {
        var res = try core.proc.run(self.gpa, &.{ "/bin/sh", "-c", sh_cmd }, .{ .cwd = self.root, .environ = parentEnviron() });
        defer res.deinit(self.gpa);
        return self.gpa.dupe(u8, std.mem.trim(u8, res.stdout, " \t\r\n"));
    }

    /// Write a composite screenshot to an absolute artifact path that outlives
    /// the tmpdir (best-effort; the e2e leaves frames to eyeball). Syncs the
    /// window layout to the active buffer first — the real frame loop runs
    /// `applyIntents` every frame, so without this the focused pane still shows
    /// the buffer it was created with and the screenshot lies about what a user
    /// sees (a magit mode chip over an empty *scratch* body).
    pub fn shot(self: *Project, ed: *Editor, name: []const u8) void {
        ed.applyWindow();
        const pixels = ed.renderComposite() catch return;
        defer self.gpa.free(pixels);
        const fname = std.fmt.allocPrint(self.gpa, "{s}/.zig-cache/tmp/weft-e2e-{s}.ppm", .{ self.prev_cwd, name }) catch return;
        defer self.gpa.free(fname);
        harness.writePpm(self.gpa, fname, pixels, app_w, app_h) catch {};
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
    .{ "dired", @embedFile("guest_dired_wasm") },
    .{ "helix", @embedFile("guest_helix_wasm") },
    .{ "emacs", @embedFile("guest_emacs_wasm") },
});

/// The PluginLoader `weft.plugin(name)` funnels through during a config boot.
/// Resolves each name against the embedded catalog and loads it onto the
/// editor; records what it couldn't resolve/load so the test can report it.
pub const ConfigLoader = struct {
    ed: *Editor,
    missing: std.ArrayList([]const u8) = .empty, // names not in the catalog
    failed: std.ArrayList([]const u8) = .empty, // resolved but loadPlugin errored

    pub fn deinit(self: *ConfigLoader) void {
        for (self.missing.items) |s| self.ed.gpa.free(s);
        for (self.failed.items) |s| self.ed.gpa.free(s);
        self.missing.deinit(self.ed.gpa);
        self.failed.deinit(self.ed.gpa);
    }

    fn loadFn(ctx: *anyopaque, name: []const u8) void {
        const self: *ConfigLoader = @ptrCast(@alignCast(ctx));
        const gpa = self.ed.gpa;
        if (std.mem.endsWith(u8, name, ".js")) return; // JS plugins aren't wired headlessly yet
        const bytes = plugin_catalog.get(name) orelse {
            self.missing.append(gpa, gpa.dupe(u8, name) catch return) catch {};
            return;
        };
        self.ed.load(name, bytes) catch {
            self.failed.append(gpa, gpa.dupe(u8, name) catch return) catch {};
        };
    }

    fn loader(self: *ConfigLoader) core.quickjs.PluginLoader {
        return .{ .ctx = self, .load = loadFn };
    }
};

/// Boot the editor from the real `config/config.js` (read from `config_dir`,
/// which also resolves its `weft.use("defaults")`). Fills `loader_state` with
/// any plugins the config asked for that couldn't load.
pub fn bootConfig(ed: *Editor, config_dir: []const u8, loader_state: *ConfigLoader) !void {
    const cfg_path = try std.fmt.allocPrint(ed.gpa, "{s}/config.js", .{config_dir});
    defer ed.gpa.free(cfg_path);
    const src = try core.file.readAlloc(ed.gpa, cfg_path);
    defer ed.gpa.free(src);
    try core.quickjs.evalConfig(&ed.engine, &ed.ctx, loader_state.loader(), &ed.config_kv, config_dir, src);
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
    for (ed.plugins.items) |pl| core.wasm_host.notifyMenu(pl, false); // leave
    return out.toOwnedSlice(gpa);
}

/// Whether the rendered which-key overlay shows `needle` (a key in config
/// notation, or a command name) — i.e. a user peeking the hint would SEE it.
pub fn whichKeyShows(ed: *Editor, needle: []const u8) bool {
    const text = whichKeyText(ed, ed.gpa) catch return false;
    defer ed.gpa.free(text);
    return std.mem.indexOf(u8, text, needle) != null;
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

/// The text of a named TOOL buffer (magit/dired/echo projections) — these ARE
/// the rendered UI surface, so reading them to assert UI state is fair under
/// the e2e's boundary (real FILE content is read from disk instead). Returns
/// null if no such buffer exists. Caller frees.
pub fn toolText(ed: *Editor, name: []const u8) ?[]u8 {
    var it = ed.buffers.iterator();
    while (it.next()) |b| {
        if (std.mem.eql(u8, b.name, name))
            return b.editor.text().toOwnedSlice(ed.gpa) catch null;
    }
    return null;
}

/// Drive the async loop until the named tool buffer contains `needle`, bounded
/// by wall clock (the proc drain runs on a pool thread and delivers on real
/// time). Returns whether it appeared. Mirrors the git-status async test's
/// drain, generalized over an arbitrary buffer + needle.
pub fn drainToolContains(ed: *Editor, name: []const u8, needle: []const u8) bool {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        _ = ed.loop.tick();
        if (toolText(ed, name)) |txt| {
            defer ed.gpa.free(txt);
            if (std.mem.indexOf(u8, txt, needle) != null) return true;
        }
        std.Thread.yield() catch {};
    }
    return false;
}

/// Drive the async loop until the DISK oracle `sh_cmd` reports `needle` (or a
/// timeout). A magit mutation (stage/commit) shells out asynchronously — the
/// keypress only SCHEDULES `git add`/`git commit`; the loop tick is what lets
/// the pool worker run it. Polling the on-disk oracle each round makes the
/// assertion deterministic (disk truth), never a sleep-and-hope. git ops
/// complete in a few ms, so this converges in a handful of rounds.
pub fn drainUntilOracle(proj: *Project, ed: *Editor, sh_cmd: []const u8, needle: []const u8) bool {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        _ = ed.loop.tick();
        const out = proj.oracle(sh_cmd) catch {
            std.Thread.yield() catch {};
            continue;
        };
        defer ed.gpa.free(out);
        if (std.mem.indexOf(u8, out, needle) != null) return true;
        std.Thread.yield() catch {};
    }
    return false;
}
