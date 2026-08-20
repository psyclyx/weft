//! workflow — a HEADLESS integration harness that drives the full editor the
//! way a person does: load plugins, press keys (through the keymap, so bound
//! keys and modes behave exactly as in the app), type text, run commands, and
//! inspect buffer/mode state. It renders frames to PPM artifacts under
//! `.zig-cache/tmp/` so a run leaves screenshots to eyeball, without asserting
//! exact pixels.
//!
//! The point (per the design brief): approach a task as "the natural way to do
//! X in weft is to press Y". If Y doesn't exist, or X is more painful than it
//! should be, the test is hard to write — and that difficulty is the signal.
//! So these tests double as a punch-list of rough edges. Keep them granular, so
//! a failure names the exact step.

const std = @import("std");
const snail = @import("snail");
const core = @import("core/core.zig");
const view_mod = @import("gfx/view.zig");
const harness = @import("gfx/harness.zig");
const window_layout = @import("gfx/window_layout.zig");
const window_cmds = @import("app/window_cmds.zig");
const app_session = @import("app/session.zig");
const app_providers = @import("app/providers.zig");
const app_collab = @import("app/collab.zig");
const region = @import("gfx/region.zig");

const Allocator = std.mem.Allocator;
const command = core.command;

/// Headless framebuffer geometry for the App harness's composite snapshots.
const app_w: u32 = 640;
const app_h: u32 = 400;
const app_em: f32 = 16;

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
    pub fn press(self: *Editor, spec: []const u8, text: []const u8) void {
        self.ctx.user_initiated = true; // a keystroke: helper-plugin edits are the user's
        defer self.ctx.user_initiated = false;
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
const session = core.session;

fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM, 0, &fds);
    if (linux.errno(rc) != .SUCCESS) return error.SocketPair;
    return fds;
}

/// Yield for roughly `us` microseconds of wall-clock — enough to let each
/// session's reader/writer threads make progress (a tight spin would starve
/// them). Mirrors session.zig's own test helper.
fn napUs(us: u64) void {
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
fn loadVim(ed: *Editor) !void {
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
fn loadWorkspace(ed: *Editor) !void {
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
fn loadWebIde(ed: *Editor) !void {
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
fn tmpPath(gpa: Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
}

/// The parent process's environment as a `std.process.Environ` (the harness
/// links libc, so `std.c.environ` is populated). Proc-backed plugins (git/run/
/// grep) need PATH to resolve `git` etc. inside their `/bin/sh -c`, so the
/// harness must hand this to the wasm host exactly as `main()` does at startup
/// (core.wasm_host.setEnviron) — otherwise every subprocess runs PATH-less and
/// silently fails to find its tool. The same block feeds the test's own oracle.
fn parentEnviron() std.process.Environ {
    return .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
}

// This Zig's std dropped ambient process-cwd mutation (part of the `std.Io`
// migration — see the gap note below), so the project harness reaches the raw
// Linux syscalls directly, exactly as session.zig reaches `linux.socket*`.
fn getCwdAlloc(gpa: Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    if (@as(isize, @bitCast(rc)) < 0) return error.GetCwd;
    return gpa.dupe(u8, std.mem.sliceTo(buf[0..rc], 0));
}

fn chdirTo(path: []const u8) !void {
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
const Project = struct {
    gpa: Allocator,
    td: std.testing.TmpDir,
    root: []u8, // absolute path to the project dir (the process cwd while live)
    prev_cwd: []u8, // absolute cwd to restore on deinit

    fn init(self: *Project, gpa: Allocator) !void {
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

    fn deinit(self: *Project) void {
        chdirTo(self.prev_cwd) catch {};
        self.td.cleanup();
        self.gpa.free(self.root);
        self.gpa.free(self.prev_cwd);
    }

    /// Absolute path to `name` inside the project (caller frees).
    fn path(self: *Project, name: []const u8) ![]u8 {
        return std.fs.path.join(self.gpa, &.{ self.root, name });
    }

    /// Run a shell command to completion in the project and return its trimmed
    /// stdout (caller frees). The test's own on-disk ORACLE — a human running
    /// `git …` in a terminal — never the editor's plugin path; used to verify
    /// content. Runs through `/bin/sh -c` (like the editor's own proc path) so
    /// argv[0] is PATH-resolved — this Zig's `process.spawn` does not itself
    /// search PATH for a bare command name.
    fn oracle(self: *Project, sh_cmd: []const u8) ![]u8 {
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
    fn shot(self: *Project, ed: *Editor, name: []const u8) void {
        ed.applyWindow();
        const pixels = ed.renderComposite() catch return;
        defer self.gpa.free(pixels);
        const fname = std.fmt.allocPrint(self.gpa, "{s}/.zig-cache/tmp/weft-e2e-{s}.ppm", .{ self.prev_cwd, name }) catch return;
        defer self.gpa.free(fname);
        harness.writePpm(self.gpa, fname, pixels, app_w, app_h) catch {};
    }
};

/// Author a file the way a person does: open it (adopts the path), enter
/// insert, type the body, escape, save, and drive the save to disk. The natural
/// motion — `open` then `i…Esc` then `save`. Assumes a normal-editing resting
/// mode (call before entering any tool buffer, so no tool mode swallows typing).
fn authorFile(ed: *Editor, name: []const u8, body: []const u8) void {
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
fn toolText(ed: *Editor, name: []const u8) ?[]u8 {
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
fn drainToolContains(ed: *Editor, name: []const u8, needle: []const u8) bool {
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
fn drainUntilOracle(proj: *Project, ed: *Editor, sh_cmd: []const u8, needle: []const u8) bool {
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

// ── Tests: granular editor workflows ────────────────────────────────

const t = std.testing;

test "workflow: vim — insert text, escape, and it lands in the buffer" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);

    // vim starts in normal. The natural way to type is: i, then the text, Esc.
    try t.expectEqualStrings("normal", ed.mode());
    ed.press("i", ""); // enter insert
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText("hello weft");
    ed.press("Escape", "");
    try t.expectEqualStrings("normal", ed.mode());

    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("hello weft", got);
    ed.snapshot("vim-insert");
}

test "workflow: vim — dw deletes a word (operator + motion compose)" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);

    ed.press("i", "");
    ed.typeText("alpha bravo charlie");
    ed.press("Escape", "");
    // Back to the start of the line, then delete the first word with `dw`.
    ed.press("0", ""); // motion.line-start (via vim/n/*)
    ed.press("d", ""); // enter operator-pending
    ed.press("w", ""); // word motion → op.delete applies
    const got = try ed.textAlloc();
    defer gpa.free(got);
    // "alpha " is gone (the word + its trailing space, vim `dw`).
    try t.expect(std.mem.startsWith(u8, got, "bravo"));
}

test "workflow: autopair — typing an open paren inserts the matched pair" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    // The natural way: bind the pair keys (a config would). Then in insert, `(`
    // is a bound key (not plain text) → the pair is inserted, caret between.
    try ed.keymap.bind(gpa, "insert", "parenleft", "pair-paren", core.Keymap.prio_config, "test");

    ed.press("i", "");
    ed.press("parenleft", "("); // bound → pair-paren, not literal text
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("()", got);
}

test "workflow: vim — x deletes the char under the cursor" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("abc");
    ed.press("Escape", "");
    ed.press("0", ""); // to line start
    ed.press("x", ""); // delete-forward
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("bc", got);
}

test "workflow: vim — o opens a line below and enters insert" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("one");
    ed.press("Escape", "");
    ed.press("o", ""); // open below → insert
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText("two");
    ed.press("Escape", "");
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("one\ntwo", got);
}

test "workflow: vim — u undoes the last insert as one unit" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("scratch");
    ed.press("Escape", "");
    ed.press("u", ""); // undo the whole insert
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("", got);
}

test "workflow: vim — undo after dw undoes the dw, not the typing" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("foo bar baz");
    ed.press("Escape", "");
    ed.press("0", ""); // line start
    ed.press("d", "");
    ed.press("w", ""); // dw deletes "foo "
    {
        const after = try ed.textAlloc();
        defer gpa.free(after);
        try t.expectEqualStrings("bar baz", after);
    }
    // The dw is applied by the operators PLUGIN, but you initiated it — so it
    // joins YOUR undo history. Undo must restore "foo ", not undo the typing.
    ed.press("u", "");
    const undone = try ed.textAlloc();
    defer gpa.free(undone);
    try t.expectEqualStrings("foo bar baz", undone);
}

test "workflow: vim — Y yanks a line, p pastes it below" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("line");
    ed.press("Escape", "");
    ed.press("Y", ""); // yank-line
    ed.press("p", ""); // paste below
    const got = try ed.textAlloc();
    defer gpa.free(got);
    try t.expectEqualStrings("line\nline", got);
}

test "workflow: vim — cw changes a word then re-inserts" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("foo bar");
    ed.press("Escape", "");
    ed.press("0", "");
    ed.press("c", ""); // enter operator-change
    ed.press("w", ""); // word → change; lands in insert
    try t.expectEqualStrings("insert", ed.mode());
    ed.typeText("baz");
    ed.press("Escape", "");
    const got = try ed.textAlloc();
    defer gpa.free(got);
    // "foo" became "baz"; "bar" survives (cw doesn't eat the trailing space).
    try t.expect(std.mem.startsWith(u8, got, "baz"));
    try t.expect(std.mem.indexOf(u8, got, "bar") != null);
}

test "workflow: modes — opening a file detects its language on activate" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // The natural way to "work on a zig file" is to open it. modes' on_activate
    // fires (harness mirrors main) and echoes the detected language.
    ed.runStr("open", "/tmp/weft-nonexistent-main.zig");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "zig") != null);

    ed.runStr("open", "/tmp/weft-nonexistent-app.js");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "javascript") != null);
}

// ── Multi-pane: split the window and render every pane headlessly ───

test "app/window: vsplit into two panes, each renders its own buffer" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);

    // Buffer A (the scratch buffer): type into it.
    ed.press("i", "");
    ed.typeText("ALPHA pane\nleft body\n");
    ed.press("Escape", "");
    try t.expectEqual(@as(usize, 1), ed.paneCount());

    // Split via the REAL window command → intent → applyIntents. Both panes
    // start on buffer A; focus stays on the original (left) half.
    ed.run("window-vsplit");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.paneCount());

    // Move focus to the right pane and open a second buffer there — the real
    // "focused pane follows the active buffer" invariant carries it.
    ed.run("window-focus-right");
    ed.applyWindow();
    ed.runStr("buffer-create", "*bravo*");
    ed.applyWindow();
    try t.expectEqualStrings("*bravo*", ed.bufferName());
    ed.press("i", "");
    ed.typeText("BRAVO pane\nright body\n");
    ed.press("Escape", "");

    // The two panes show distinct buffers.
    const frame: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(app_w), .h = @floatFromInt(app_h) };
    var slots: [window_layout.max_panes]window_layout.Slot = undefined;
    const n = ed.win_layout.collect(frame, &slots);
    try t.expectEqual(@as(usize, 2), n);
    try t.expect(slots[0].pane.buffer_id != slots[1].pane.buffer_id);

    // Composite every pane headlessly and assert each pane's body drew content
    // (its buffer rendered into its own slot rect), then emit the artifact.
    const pixels = try ed.renderComposite();
    defer gpa.free(pixels);
    for (slots[0..n]) |slot| {
        const x0: u32 = @intFromFloat(slot.rect.x + 10);
        const y0: u32 = @intFromFloat(slot.rect.y + 10);
        const x1: u32 = @intFromFloat(slot.rect.x + slot.rect.w - 10);
        const y1: u32 = @intFromFloat(slot.rect.y + 40);
        try t.expect(harness.hasContent(pixels, app_w, x0, y0, x1, y1));
    }
    ed.snapshotPanes("vsplit-two");
}

test "app/window: a further split tiles three panes and still composites" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadVim(&ed);
    ed.press("i", "");
    ed.typeText("root buffer\n");
    ed.press("Escape", "");

    // vsplit, then split the focused half horizontally → three panes.
    ed.run("window-vsplit");
    ed.applyWindow();
    ed.run("window-split");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 3), ed.paneCount());

    const pixels = try ed.renderComposite();
    defer gpa.free(pixels);
    // Something was drawn somewhere in the frame (all three panes share the
    // root buffer here; the point is the tiling + composite path holds up).
    try t.expect(harness.hasContent(pixels, app_w, 0, 0, app_w, app_h));
    ed.snapshotPanes("tri-pane");
}

// ── Multiplayer: two harnesses pair on a document over the loopback ──
//
// Exercises the REAL session sync layer: two live encrypted Sessions over a
// socketpair, document sync via `Collab.tick` (drain → handleFrame → push) —
// the same code `collab.tickCollab` calls under the hood. Peer A types through
// the real keymap/command path; the pump converges it into peer B's buffer.

test "app/collab: peer A types, it converges into peer B's buffer + cursor" {
    const gpa = t.allocator;
    var a: Editor = undefined;
    try Editor.initNamed(gpa, &a, "alice");
    defer a.deinit();
    var b: Editor = undefined;
    try Editor.initNamed(gpa, &b, "bob");
    defer b.deinit();
    try loadVim(&a);
    try loadVim(&b);

    var link: Loopback = undefined;
    try Loopback.init(&link, gpa, &a, &b, "alice", "bob");
    defer link.deinit();

    // Alice types through the real vim path (i → text → Esc).
    a.press("i", "");
    a.typeText("hello from alice");
    a.press("Escape", "");

    // Pump the loopback until Bob's document carries Alice's text.
    const Ctx = struct { b: *Editor };
    const converged = try link.pumpUntil(Ctx{ .b = &b }, struct {
        fn pred(c: Ctx) bool {
            const txt = c.b.buffers.active().editor.text().toOwnedSlice(c.b.gpa) catch return false;
            defer c.b.gpa.free(txt);
            return std.mem.indexOf(u8, txt, "hello from alice") != null;
        }
    }.pred);
    if (!converged) {
        const at0 = a.buffers.active().editor.text().toOwnedSlice(gpa) catch &.{};
        defer gpa.free(at0);
        const bt0 = b.buffers.active().editor.text().toOwnedSlice(gpa) catch &.{};
        defer gpa.free(bt0);
        std.debug.print("\n[CONVERGE-FAIL] host_live={} peer_live={} alice='{s}' bob='{s}' host_announced={} peer_announced={}\n", .{
            link.host_sess.liveness(), link.peer_sess.liveness(), at0, bt0,
            link.host_col.announced,   link.peer_col.announced,
        });
    }
    try t.expect(converged);

    // Both replicas hold identical text — convergence, not just delivery.
    const at = try a.buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(at);
    const bt = try b.buffers.active().editor.text().toOwnedSlice(gpa);
    defer gpa.free(bt);
    try t.expectEqualStrings(at, bt);

    // Cursor/presence: Alice's caret replicated into Bob's presence layer.
    // Presence rides a SEPARATE feed (channel base+1) from the text ops, so it
    // can land a tick or two after the text converges — pump for it rather than
    // asserting immediately (asserting bare here is a race that flakes under
    // load). This was the actual cause of the collab test's intermittent fail.
    const PCtx = struct { link: *Loopback };
    const saw_alice = try link.pumpUntil(PCtx{ .link = &link }, struct {
        fn pred(c: PCtx) bool {
            for (c.link.peer_col.presence_names.items) |name| {
                if (std.mem.eql(u8, name, "alice")) return true;
            }
            return false;
        }
    }.pred);
    try t.expect(saw_alice);

    // Round-trip the other way: Bob edits, it lands back on Alice.
    b.press("A", ""); // append at line end (vim)
    b.press("i", ""); // ensure insert (A may already switch; harmless)
    b.typeText(" + bob");
    b.press("Escape", "");
    const Ctx2 = struct { a: *Editor };
    const back = try link.pumpUntil(Ctx2{ .a = &a }, struct {
        fn pred(c: Ctx2) bool {
            const txt = c.a.buffers.active().editor.text().toOwnedSlice(c.a.gpa) catch return false;
            defer c.a.gpa.free(txt);
            return std.mem.indexOf(u8, txt, "bob") != null;
        }
    }.pred);
    try t.expect(back);
}

// Regression guard for the session teardown hang: `Session.destroy` must WAKE
// its blocked reader (via shutdown()), not park on it. Before the fix, close()
// alone left the reader blocked in read() until the peer's next ~1s heartbeat,
// so every teardown took ~1000ms — real dead time that starved other threads
// under load. This runs the isolated session sync (no wasm) and asserts each
// teardown is prompt AND the doc converged.
test "regression: session teardown is prompt (no reader-park hang)" {
    const gpa = t.allocator;
    var iter: usize = 0;
    while (iter < 12) : (iter += 1) {
        var da = try core.Document.init(gpa, "alice");
        defer da.deinit(gpa);
        var db = try core.Document.init(gpa, "bob");
        defer db.deinit(gpa);
        const fds = try socketPair();
        var fa = session.FdLink{ .fd = fds[0] };
        var fb = session.FdLink{ .fd = fds[1] };
        const sa = try session.Session.create(gpa, fa.link(), .server, "t", .own, null);
        const sb = try session.Session.create(gpa, fb.link(), .client, "t", .own, null);
        var ca = try session.Collab.init(gpa, sa, &da, "alice");
        var cb = try session.Collab.init(gpa, sb, &db, "bob");

        try da.insert(gpa, 0, "hello");
        var ok = false;
        const deadline = core.task.nowNs() + 5 * std.time.ns_per_s;
        while (core.task.nowNs() < deadline) {
            _ = try ca.tick(0);
            _ = try cb.tick(0);
            if (db.text().byteLen() >= 5) {
                ok = true;
                break;
            }
            napUs(200);
        }
        try t.expect(ok);

        // Teardown must be prompt — the whole point. A regressed destroy() that
        // parks on the blocked reader would blow well past this (~1s each).
        const t1 = core.task.nowNs();
        ca.deinit();
        cb.deinit();
        sb.destroy();
        sa.destroy();
        try t.expect(core.task.nowNs() - t1 < 300 * std.time.ns_per_ms);
    }
}

// ── Project-level e2e: build a tiny app the way a person would ───────
//
// This is the test we keep growing. It drives weft through the natural motions
// of starting a project in a scratch dir: open a file, write code, save it to
// disk, and confirm the language is recognized. Each granular step is its own
// test so a failure names exactly what broke. Capabilities we don't have yet
// are recorded as gaps (the difficulty is the signal), not faked as passes.

test "e2e/project: weft `save` writes the buffer to disk" {
    const gpa = t.allocator;
    var td = t.tmpDir(.{});
    defer td.cleanup();
    const path = try tmpPath(gpa, &td.sub_path, "main.zig");
    defer gpa.free(path);

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // The natural way: open the path, type code, save.
    ed.runStr("open", path); // new file → adopts the path
    ed.press("i", "");
    ed.typeText("const x = 41;\n");
    ed.press("Escape", "");
    ed.run("save");
    ed.waitSave(); // drive the async save to completion, deterministically

    const on_disk = try core.file.readAlloc(gpa, path);
    defer gpa.free(on_disk);
    try t.expect(std.mem.indexOf(u8, on_disk, "const x = 41;") != null);
}

test "e2e/project: opening the saved file recognizes its language" {
    const gpa = t.allocator;
    var td = t.tmpDir(.{});
    defer td.cleanup();
    const zig_path = try tmpPath(gpa, &td.sub_path, "app.zig");
    defer gpa.free(zig_path);
    const js_path = try tmpPath(gpa, &td.sub_path, "app.js");
    defer gpa.free(js_path);

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    ed.runStr("open", zig_path);
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "zig") != null);
    ed.runStr("open", js_path); // switching buffers re-fires on_activate
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "javascript") != null);
}

test "e2e/project: magit push/pull/fetch transients are sticky menus" {
    const gpa = t.allocator;
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // The flag transients must be sticky (stay open while flags accumulate) —
    // sticky implies menu-mode, so which-key also lists their keys. The reset
    // transient (a plain one-shot menu) must NOT be sticky.
    try t.expect(ed.keymap.isStickyMenu("git-push-menu"));
    try t.expect(ed.keymap.isStickyMenu("git-pull-menu"));
    try t.expect(ed.keymap.isStickyMenu("git-fetch-menu"));
    try t.expect(ed.keymap.isMenuMode("git-push-menu"));
    try t.expect(!ed.keymap.isStickyMenu("git-reset-menu"));
    try t.expect(ed.keymap.isMenuMode("git-reset-menu"));
}

// ── The whole-app spine: start a project, write code, version it ────
//
// This is THE e2e the brief asks for: drive weft the way a person starts a web
// app — in a real directory, through the editor's OWN commands and keys — and
// verify the on-disk result. It launched a documented gap ("live-git subprocess
// e2e needs a tmpdir-as-cwd + proc-drain harness"); `Project` closes it. Every
// place the natural motion had no key/command was treated as SIGNAL and fixed
// in the plugin/config (e.g. there was no in-editor `git init` — now there is),
// never worked around in the test.
test "e2e/spine: write a file, init a repo, stage and commit — all through weft" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWorkspace(&ed);

    // ── 1. Write the first file the way a person does: open, type, save. ──
    // (Mode starts `normal`; edit BEFORE entering any tool buffer, so no
    // tool-mode ever swallows the typing — see [[mode-leak-class]].)
    ed.runStr("open", "index.html");
    ed.press("i", "");
    ed.typeText("<!doctype html>\n<title>weft demo</title>\n");
    ed.press("Escape", "");
    ed.run("save");
    ed.waitSave();

    // CONTENT is verified on disk (the artifact a human checks), not via the
    // editor's model.
    {
        const disk = try core.file.readAlloc(gpa, "index.html");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "<title>weft demo</title>") != null);
    }

    // ── 2. Start version control from INSIDE the editor (the new git-init). ──
    // Before this command existed, git-status on a non-repo showed an empty
    // buffer and there was no in-editor way to create the repo.
    ed.run("git-init");
    // Prove git ACTUALLY ran, not just that the (unconditional) "Branch:" header
    // rendered: wait for the real `git status` output to list the untracked file
    // in *magit*. Then confirm the repo on disk via the git oracle.
    try t.expect(drainToolContains(&ed, "*magit*", "index.html"));
    {
        const gitdir = try proj.oracle("git rev-parse --git-dir");
        defer gpa.free(gitdir);
        try t.expect(gitdir.len > 0); // ".git" (or its absolute path)
    }
    proj.shot(&ed, "spine-1-init");

    // Configure an author for this repo (world setup — a human's git identity),
    // so the commit below has one. Repo-local, hermetic.
    {
        const e1 = try proj.oracle("git config user.email e2e@weft.test");
        gpa.free(e1);
        const e2 = try proj.oracle("git config user.name weft-e2e");
        gpa.free(e2);
    }

    // ── 4. Stage everything with the magit key `S`, then commit with `c c`. ──
    // We're in the *magit* buffer (git-init focused it), so these are real
    // magit keypresses, not command invocations.
    try t.expectEqualStrings("magit", ed.mode());
    ed.press("S", ""); // git-stage-all → git add -A → re-gather (async)
    // Disk oracle, drained: the file becomes staged once the async `git add`
    // the keypress scheduled actually runs.
    try t.expect(drainUntilOracle(&proj, &ed, "git diff --cached --name-only", "index.html"));
    proj.shot(&ed, "spine-2-staged");

    // Commit dispatch: `c` opens the transient, `c` again starts a commit.
    ed.press("c", ""); // git-commit-dispatch (menu)
    ed.press("c", ""); // git-commit → *git-commit* buffer, mode git-commit
    try t.expectEqualStrings("git-commit", ed.mode());
    ed.typeText("initial commit: weft demo skeleton");
    ed.press("C-c", ""); // git-commit-menu
    ed.press("C-c", ""); // git-commit-finish → git commit -F … → re-gather
    try t.expect(drainToolContains(&ed, "*magit*", "initial commit"));
    proj.shot(&ed, "spine-3-committed");

    // ── 5. Verify the commit landed, on disk, via the git oracle. ──
    {
        const log = try proj.oracle("git log --oneline");
        defer gpa.free(log);
        try t.expect(std.mem.indexOf(u8, log, "initial commit: weft demo skeleton") != null);
    }
    {
        const tracked = try proj.oracle("git ls-files");
        defer gpa.free(tracked);
        try t.expectEqualStrings("index.html", tracked);
    }
}

// ── The web-app narrative: many files, search them, run the code ────
//
// Continues the spine: a person fleshing out a small web app drops in more
// files, searches across them, and runs the code. Drives the project-nav/build
// tools (grep=rg, run=node) through their real commands; verifies FILE content
// on disk and TOOL output on the rendered surface; screenshots each step.
test "e2e/web: author js + html, grep across them, run it with node" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    try loadWebIde(&ed);

    // ── 1. Author two files the natural way (open → type → save). ──
    authorFile(&ed, "app.js",
        \\function greet(name) {
        \\  return "hello " + name;
        \\}
        \\console.log(greet("weft"));
        \\
    );
    authorFile(&ed, "index.html",
        \\<!doctype html>
        \\<title>weft demo</title>
        \\<script src="app.js"></script>
        \\
    );
    // CONTENT on disk (the human's check).
    {
        const disk = try core.file.readAlloc(gpa, "app.js");
        defer gpa.free(disk);
        try t.expect(std.mem.indexOf(u8, disk, "return \"hello \" + name;") != null);
    }

    // ── 2. Search the project for a token that appears in BOTH files. ──
    // `grep` runs `rg` into *grep*; a person types the pattern. "weft" is in
    // app.js (greet("weft")) and index.html (<title>weft demo</title>).
    ed.runStr("grep", "weft");
    try t.expect(drainToolContains(&ed, "*grep*", "app.js"));
    {
        const hits = toolText(&ed, "*grep*") orelse return error.NoGrepBuffer;
        defer gpa.free(hits);
        try t.expect(std.mem.indexOf(u8, hits, "app.js") != null);
        try t.expect(std.mem.indexOf(u8, hits, "index.html") != null);
    }
    proj.shot(&ed, "web-1-grep");

    // ── 3. Run the code with node — real execution, real output. ──
    ed.runStr("run-command", "node app.js");
    try t.expect(drainToolContains(&ed, "*output*", "hello weft"));
    proj.shot(&ed, "web-2-run");

    // ── 4. Browse the project as a file tree with dired. ──
    ed.run("dired");
    try t.expect(drainToolContains(&ed, "*dired*", "app.js"));
    {
        const tree = toolText(&ed, "*dired*") orelse return error.NoDiredBuffer;
        defer gpa.free(tree);
        try t.expect(std.mem.indexOf(u8, tree, "app.js") != null);
        try t.expect(std.mem.indexOf(u8, tree, "index.html") != null);
    }
    try t.expectEqualStrings("dired", ed.mode());
    proj.shot(&ed, "web-3-dired");
}

// ── Coverage + documented gaps (the difficulty IS the signal) ───────
//
// NOW COVERED (promoted from gaps into the granular tests above):
//   • multi-pane rendering: the App harness owns a real window_layout.Layout,
//     drives the real window commands through window_cmds.applyIntents, and
//     renders EVERY pane headlessly via renderComposite → harness.renderBuilt
//     (the headless analogue of the frame loop's renderPanes + present). See
//     "app/window: …". The GPU-in-build seam is gone too: the atlas upload was
//     lifted out of the backend-independent build into render.zig's `present`,
//     so the same view.build path the exe uses now rasterizes on the CPU.
//   • coworker (multiplayer): the in-process collab loopback (Loopback above)
//     stands up two encrypted Sessions over a socketpair, each syncing an
//     editor's document via a real Collab. "app/collab: …" types through the
//     real vim path on peer A and asserts convergence into peer B's buffer +
//     cursor. This drives the REAL session sync layer (Session handshake +
//     Collab.tick — the same code collab.tickCollab calls); it does NOT drive
//     the full tickCollab frame-loop wrapper (partial-checkout / peer-fs /
//     reconnect / hub adoption), which still needs the ShareCtx plumbing.
//   • git (magit) workflow — NOW COVERED by "e2e/spine: …" above. `Project`
//     closes the gap the note below used to describe: it makes a tmpdir the
//     process CWD (raw linux.chdir — this Zig's std dropped ambient cwd) and
//     sets the wasm host's parent environ (setEnviron), so the git plugin's
//     `/bin/sh -c "git …"` children resolve `git` on PATH and operate on the
//     project. The async magit mutations (init/stage/commit) are DRAINED to
//     completion (drainUntilOracle) and verified on disk via a git oracle — a
//     real repo, real commit, not a mocked one. Building it surfaced two live
//     bugs, both fixed: the harness never set g_environ (every subprocess ran
//     PATH-less), and there was no in-editor `git init` (added: git-init +
//     SPC g i). NOTE still open: magit renders "Branch:" UNCONDITIONALLY, so
//     git-status on a non-repo shows a fake-empty magit instead of offering to
//     init — a display bug worth a follow-up (git-status should detect a
//     non-repo and hint git-init).
//
// STILL OPEN — recorded here rather than written as flaky/green fakes; promote
// each into a granular test when it gains the missing piece:
//   • debugger: there is no debug/DAP plugin or `debug-*` command surface, so
//     "set a breakpoint and step" has no keys to press — the biggest missing
//     IDE capability the e2e wants.
//   • full collab frame-loop path: the loopback exercises the session/Collab
//     sync layer directly; wrapping it in collab.tickCollab (to also cover the
//     hub multi-peer adoption, partial checkout, and reconnect branches) needs
//     the ShareCtx + main() frame-loop locals stood up headlessly.
//   • per-language build/test/run: `lang-run`/`make-*` shell out via `proc`;
//     exercising them for several languages needs those toolchains in the test
//     environment, so they're left to the manual/CI matrix, not the unit suite.

// ── Teardown ordering: shells outlive buffers (the untestable shutdown path) ──
//
// main()'s shutdown is invisible to the compiler and to every GUI-less test: a
// mis-ordered deinit only crashes a real user at quit. This test stands up the
// two ordering-critical clusters (`Session` owns the buffers; `Providers` owns
// the persistent remote shells) exactly as main() builds them, attaches a
// shell-backed buffer with an IN-FLIGHT save, then tears them down IN MAIN()'s
// ORDER — Session before Providers, with the pool joined in between. Under
// std.testing.allocator (leak detection) + the DebugAllocator (double-free/UAF),
// a wrong cut (shells freed before the buffers whose save worker still holds a
// shell backing) fails HERE instead of crashing at a user's quit.
//
// Editor.deinit spin-waits any in-flight save to completion using the shell fs,
// so the shell MUST still be alive when the buffer dies — precisely the
// shells-outlive-buffers invariant. Freeing Providers before Session would UAF.
test "app/teardown: shells outlive buffers through an in-flight shell save" {
    const gpa = t.allocator;
    var td = t.tmpDir(.{});
    defer td.cleanup();
    const path = try tmpPath(gpa, &td.sub_path, "shell-backed.txt");
    defer gpa.free(path);
    // The backing shell reads the path off the local fs; seed it on disk.
    try core.file.writeBytes(gpa, path, "initial contents\n");

    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(std.c.environ) } };
    const pool = try core.task.Pool.init(gpa, .{});

    // Build the two clusters in main()'s construction order: Providers'
    // registries first (the session's capability consumers bind onto them),
    // then the Session, then Providers' attach phase (borrows session caps).
    var prov: app_providers.Providers = undefined;
    try prov.initRegistries(gpa);
    var which_key_now = false;
    var sess: app_session.Session = undefined;
    try sess.init(gpa, pool, "teardown-user", &prov.grammars, &prov.lsp_servers, &which_key_now);
    prov.initAttach(gpa, &sess.caps, environ, true);

    // A persistent shell registered in Providers.attach_deps.shells, exactly as
    // AttachDeps.shellFor does (gpa.create + spawn + put with a duped key), so
    // Providers.deinit is what frees it — the cross-cluster resource.
    const fs = try gpa.create(core.ShellFs);
    fs.* = try core.ShellFs.spawn(gpa, &.{"/bin/sh"}, environ);
    try prov.attach_deps.shells.put(gpa, try gpa.dupe(u8, "localhost"), fs);

    // Back buffer 0 by that shell and kick an in-flight save: the pool worker now
    // holds `fs`, and Editor.deinit will spin-wait it out at teardown.
    const ed = &sess.buffers.active().editor;
    try ed.openShell(gpa, fs, path);
    try ed.doc.insert(gpa, ed.text().byteLen(), "an unsaved edit\n");
    try ed.requestSave(gpa);

    // ── Tear down in main()'s EXACT order ──
    // 1. detach per-buffer providers (before the buffers/caps die).
    {
        var it = sess.buffers.iterator();
        while (it.next()) |b| app_providers.detachProviders(&prov.attach_deps, b);
    }
    // 2. Session (buffers die here; Editor.deinit waits out the save on `fs`).
    sess.deinit(gpa);
    // 3. Pool joins remaining workers.
    pool.deinit();
    // DETERMINISTIC proof of shells-outlive-buffers: the buffers and every save
    // worker that referenced `fs` are now gone (Session + pool torn down), yet
    // the shell — owned by Providers, not yet freed — is still ALIVE. A live
    // round-trip succeeds here; if the cut were inverted (Providers freed first)
    // this would UAF the shell instead. (This is the checkable core of the
    // invariant. The in-flight-save UAF itself is timing-dependent — a fast
    // shell save can complete before teardown — so we assert liveness directly
    // rather than racing the crash.)
    const live_size = try fs.size(gpa, path);
    try t.expect(live_size > 0);
    // 4. Providers LAST — frees the shells, safely after every buffer + worker
    //    that referenced them. (A leak/double-free trips the allocator.)
    prov.deinit(gpa);
}

// The default modeless path (no --connect/--listen): Collab still owns the async
// `.peer` fs bridge, the reply-correlation map, and the share intent surface.
// Its deinit must free them and clear the process-global bridge pointer without
// leak or double-free. (The CONNECTED teardown — conn/hub/session/partial —
// needs a live socket + GUI, so it can't run here; Collab.deinit mirrors the
// prior main() defers line-for-line, verified by inspection. This covers the
// path every bare launch hits, under the leak-checking allocator.)
test "app/teardown: unconnected Collab constructs + tears down clean" {
    const gpa = t.allocator;
    const pool = try core.task.Pool.init(gpa, .{});
    defer pool.deinit();
    var prov: app_providers.Providers = undefined;
    try prov.initRegistries(gpa);
    defer prov.deinit(gpa);
    var which_key_now = false;
    var sess: app_session.Session = undefined;
    try sess.init(gpa, pool, "collab-user", &prov.grammars, &prov.lsp_servers, &which_key_now);
    defer sess.deinit(gpa);
    // known_peers + my_identity stay main() locals (Collab borrows them); an empty
    // in-memory store keeps this hermetic (no config-home read/write).
    var known: core.known_peers.KnownPeers = .{ .gpa = gpa };
    defer known.deinit();
    var id = core.identity.Identity.generate();

    var col: app_collab.Collab = undefined;
    col.initBase(gpa, &sess.buffers, &sess.caps, &known, null, .none, null, .view);
    try col.connect(gpa, &sess.buffers.active().editor, &sess.caps, &id, null, "tok", "user", false);
    // main()'s order: Collab before Session (it reads the session caps + must
    // unbind before the doc layers drop).
    col.deinit(gpa);
}

test {
    std.testing.refAllDecls(@This());
}
