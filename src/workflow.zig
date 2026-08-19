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
const core = @import("core/core.zig");
const view_mod = @import("gfx/view.zig");
const harness = @import("gfx/harness.zig");

const Allocator = std.mem.Allocator;
const command = core.command;

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
    quit: bool = false,
    echo: std.ArrayList(u8) = .empty,
    ctx: command.Context = undefined,
    engine: core.wasm.Engine,
    plugins: std.ArrayList(*core.wasm_abi.WasmPlugin) = .empty,
    plugin_kv: core.kv.Store = .empty,
    config_kv: core.kv.Store = .empty,
    loop: core.async_loop.Loop,
    subs: core.subbuffer.SubBuffers = .empty,
    view: ?view_mod.View = null,
    /// Last active buffer id — so a buffer switch (open, buffer-next) fires
    /// `on_activate` to plugins, exactly as main's loop does.
    last_active: core.Buffers.Id = 0,

    pub fn init(gpa: Allocator, self: *Editor) !void {
        self.quit = false;
        self.echo = .empty;
        self.plugins = .empty;
        self.plugin_kv = .empty;
        self.config_kv = .empty;
        self.subs = .empty;
        self.view = null;
        self.pool = try core.task.Pool.init(gpa, .{ .threads = 2 });
        self.gpa = gpa;
        self.commands = .empty;
        self.keymap = .empty;
        self.pick = .empty;
        self.caps = core.Caps.init(gpa, core.task.nowNs);
        self.engine = try core.wasm.Engine.init();
        self.loop = core.async_loop.Loop.init(gpa, self.pool, core.task.nowNs);
        self.buffers = try core.Buffers.init(gpa, self.pool, "user");
        self.ctx = .{
            .gpa = gpa,
            .buffers = &self.buffers,
            .commands = &self.commands,
            .keymap = &self.keymap,
            .pick = &self.pick,
            .caps = &self.caps,
            .quit = &self.quit,
            .echo = &self.echo,
        };
        try core.builtins.install(gpa, &self.commands, &self.keymap);
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
        for (self.plugins.items) |p| p.deinit();
        self.plugins.deinit(gpa);
        if (self.view) |*v| v.deinit();
        self.loop.deinit();
        self.subs.deinit(gpa);
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
            .pool = self.pool,
        });
        try self.plugins.append(self.gpa, p);
    }

    /// Press a key: `spec` is a keyspec (e.g. "i", "Escape", "C-w"); `text` is
    /// the character it would type (for printable input), or "". Mirrors
    /// main.zig's dispatch: a bound command runs (a menu-mode name enters the
    /// submenu; a one-shot menu key pops back), else printable text is inserted.
    pub fn press(self: *Editor, spec: []const u8, text: []const u8) void {
        if (self.keymap.lookup(spec)) |cmd| {
            if (self.keymap.isMenuMode(cmd)) {
                self.keymap.enterMode(self.gpa, cmd) catch {};
                return;
            }
            const before: ?[]u8 = if (self.keymap.isMenuMode(self.keymap.currentMode()))
                self.gpa.dupe(u8, self.keymap.currentMode()) catch null
            else
                null;
            defer if (before) |b| self.gpa.free(b);
            _ = command.run(&self.commands, &self.ctx, cmd, &.{}) catch {};
            if (before) |b| {
                if (!self.keymap.isStickyMenu(b) and std.mem.eql(u8, self.keymap.currentMode(), b)) {
                    if (self.keymap.menuReturn(b)) |ret| self.keymap.setMode(self.gpa, ret) catch {};
                }
            }
            self.syncActivate();
            return;
        }
        if (text.len == 0) return;
        if (self.keymap.textCommand()) |tc| {
            _ = command.run(&self.commands, &self.ctx, tc, &.{.{ .string = text }}) catch {};
        }
    }

    /// Type a run of printable text through the active mode's text command
    /// (bulk insert; use `press` for keys that trigger bindings like autopair).
    pub fn typeText(self: *Editor, s: []const u8) void {
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

    /// Write a PPM screenshot of the current frame under `.zig-cache/tmp/` (an
    /// artifact to eyeball; best-effort, never asserts).
    pub fn snapshot(self: *Editor, name: []const u8) void {
        if (self.view == null) self.view = view_mod.View.init(self.gpa, @embedFile("font_mono"), 16) catch return;
        const v = &self.view.?;
        const hud: view_mod.Hud = .{
            .mode = self.keymap.currentMode(),
            .file = self.buffers.active().name,
            .pick = if (self.pick.active) &self.pick else null,
        };
        const w: u32 = 640;
        const h: u32 = 400;
        const pixels = harness.renderView(self.gpa, v, &self.buffers.active().editor, hud, w, h) catch return;
        defer self.gpa.free(pixels);
        var buf: [128]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, ".zig-cache/tmp/weft-e2e-{s}.ppm", .{name}) catch return;
        harness.writePpm(self.gpa, path, pixels, w, h) catch {};
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

/// A writable path inside the test's tmpdir (which lives under
/// `.zig-cache/tmp/<sub_path>/`, the codebase's convention — see
/// core/tests.zig). Caller frees.
fn tmpPath(gpa: Allocator, sub_path: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/{s}", .{ sub_path, name });
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

// ── Documented gaps (the difficulty IS the signal) ──────────────────
//
// The project brief calls for the e2e to also drive *git*, *a debugger*, and
// *a coworker* (multiplayer). Those steps aren't cleanly expressible as unit
// tests yet, so they're recorded here rather than written as flaky/green fakes.
// When each gains the missing piece, promote it into a granular test above.
//
//   • git (magit) workflow: the git plugin shells out via `proc` and operates
//     on the process CWD, so a real staged/committed assertion needs (a) a
//     tmpdir made the process CWD and (b) driving the async proc to completion
//     in-harness. This Zig's churned subprocess/`Io.Dir` API made a robust,
//     non-flaky version more trouble than signal for now; the magit commands
//     themselves are unit-covered on the plugin side. A small "run a child in
//     a tmpdir + pump the loop until proc drains" harness would unlock it.
//   • debugger: there is no debug/DAP plugin or `debug-*` command surface, so
//     "set a breakpoint and step" has no keys to press — the biggest missing
//     IDE capability the e2e wants.
//   • coworker (multiplayer): the collab session/hub needs a socket transport
//     to stand up two peers; the headless harness has no in-process loopback
//     yet, so a two-editor "pair on the same buffer" scenario can't be driven.
//     A loopback session pair on the harness would unlock it.
//   • per-language build/test/run: `lang-run`/`make-*` shell out via `proc`;
//     exercising them for several languages needs those toolchains in the test
//     environment, so they're left to the manual/CI matrix, not the unit suite.

test {
    std.testing.refAllDecls(@This());
}
