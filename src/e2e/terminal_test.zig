//! e2e test file — the terminal (doc/terminal.md): a real shell on a real
//! pty, emulated by libghostty-vt inside the terminal plugin, drawn as a grid
//! in ide.js's bottom panel, taking every key but the grammar's break-out.
//!
//! Each test drives it as a person does — C-` to open it, keys through the
//! keymap, the break-out chord to leave — and reads what the person would
//! see: the grid's cells (`h.toolText` spells a grid entry's screen as
//! lines), their colours, the shell's own answers.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");
const chrome = @import("chrome_test.zig");

const core = h.core;
const Editor = h.Editor;
const IdeApp = ide.IdeApp;
const Cell = core.grid.Cell;

const term = "*terminal*";

/// The entry the bottom panel shows, or null when it is not docked.
fn panelEntry(ed: *Editor) ?*core.Buffers.Buffer {
    const node = ed.viewportPane("panel") orelse return null;
    return ed.buffers.get(node.pane().buffer_id);
}

/// A shell with a prompt the tests can name and no startup files: `$ `.
const test_shell = "PS1='$ ' exec bash --norc --noprofile";

/// Open the terminal on `shell` and wait for its first prompt.
fn openShell(app: *IdeApp, shell: []const u8) !void {
    const ed = &app.ed;
    try ide.openFile(ed, "x.txt", "x\n");
    try ed.setConfig("terminal", "shell", shell);
    ed.press("C-grave", "");
    ed.applyWindow();
    if (!h.drainToolContains(ed, term, "$")) return screenFailed(ed, error.PromptNeverShown);
}

/// Type `line` and Return, as a person does.
fn enter(ed: *Editor, line: []const u8) void {
    ed.typeText(line);
    ed.press("Return", "");
}

fn waitFor(ed: *Editor, needle: []const u8) !void {
    if (!h.drainToolContains(ed, term, needle)) return screenFailed(ed, error.NeverShown);
}

/// Say what the screen reads, then fail with `err`.
fn screenFailed(ed: *Editor, err: anyerror) anyerror {
    if (h.toolText(ed, term)) |text| {
        defer ed.gpa.free(text);
        std.debug.print("[e2e/terminal] {t}; the screen reads:\n{s}\n", .{ err, text });
    }
    return err;
}

/// The row of the screen that reads exactly `line`.
fn rowReading(ed: *Editor, line: []const u8) ?[]const Cell {
    const g = h.gridOf(ed, term) orelse return null;
    const text = h.toolText(ed, term) orelse return null;
    defer ed.gpa.free(text);
    var it = std.mem.splitScalar(u8, text, '\n');
    var r: usize = 0;
    while (it.next()) |row| : (r += 1) if (std.mem.eql(u8, row, line)) return g.row(r);
    return null;
}

test "e2e/terminal: C-` runs the shell on a terminal in the panel, and what it prints is a screen — colours, attributes and all" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openShell(&app, test_shell);

    try t.expectEqualStrings(term, (panelEntry(ed) orelse return error.PanelNotShown).name);
    try t.expectEqualStrings(term, ed.buffers.active().name);
    // The terminal takes the keys: it captures (§10.4).
    try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());

    enter(ed, "echo hi");
    try waitFor(ed, "$ echo hi\nhi\n$");

    // SGR reaches the grid as cell styles, never as bytes: bold red, a
    // truecolor foreground, reverse video.
    enter(ed, "printf '\\033[1;31mR\\033[0m \\033[38;2;1;2;3mT\\033[0m \\033[7mI\\033[0m\\n'");
    try waitFor(ed, "\nR T I\n");
    const row = rowReading(ed, "R T I") orelse return screenFailed(ed, error.NoStyledRow);
    try t.expect(row[0].attrs.bold);
    try t.expect(Cell.rgb(row[0].fg) != null); // the palette's red, not the theme's
    try t.expectEqual(@as(u32, 0x010203), row[2].fg);
    try t.expect(!row[2].attrs.bold);
    // Reverse video swaps the THEME's colours: the grid still says which.
    try t.expectEqual(Cell.theme_bg, row[4].fg);
    try t.expectEqual(Cell.theme_fg, row[4].bg);

    // An artifact to eyeball: ide.js with the terminal in the bottom panel.
    {
        const pixels = try ed.renderComposite();
        defer gpa.free(pixels);
        const path = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/weft-app-ide-terminal.ppm", .{app.proj.prev_cwd});
        defer gpa.free(path);
        h.gfx_harness.writePpm(gpa, path, pixels, h.app_w, h.app_h) catch {};
    }

    // C-j is the SHELL's while it captures (a newline: another prompt) —
    // the panel stays.
    ed.press("C-j", "");
    ed.applyWindow();
    try t.expect(ed.viewportPane("panel") != null);

    // The grammar's break-out chord hands the keys back: C-j is the
    // editor's again, and hides the panel — and shows the same shell.
    ed.press("C-backslash", "");
    try t.expect(ed.ctx.posture() != core.input.Posture.capture);
    ed.press("C-j", "");
    ed.applyWindow();
    try t.expect(ed.viewportPane("panel") == null);
    ed.press("C-j", "");
    ed.applyWindow();
    try t.expectEqualStrings(term, (panelEntry(ed) orelse return error.PanelNotShown).name);

    // C-` takes the keys again.
    ed.press("C-grave", "");
    ed.applyWindow();
    try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());
    enter(ed, "echo back");
    try waitFor(ed, "\nback\n");

    // The problems list REPLACES the shell in the one panel.
    ed.press("C-backslash", "");
    ed.press("C-S-m", "");
    ed.applyWindow();
    try t.expectEqualStrings("*problems*", panelEntry(ed).?.name);
}

test "e2e/terminal: C-c interrupts the foreground job, C-d at an empty prompt ends the shell, and the next key starts another" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openShell(&app, test_shell);

    // `cat` waits on the terminal; what is typed is echoed by the tty, then
    // by cat.
    enter(ed, "cat");
    enter(ed, "abc");
    try waitFor(ed, "\nabc\nabc\n");
    // C-c reaches the child as the line discipline's interrupt.
    ed.press("C-c", "");
    try waitFor(ed, "^C\n$");
    enter(ed, "echo after");
    try waitFor(ed, "\nafter\n$");

    // C-d at an empty prompt is end of file: the shell leaves, and says so.
    ed.press("C-d", "");
    try waitFor(ed, "[process exited 0]");

    // The next key starts a fresh shell below; the key was the dead one's.
    ed.press("x", "x");
    try waitFor(ed, "[process exited 0]\n$");
    enter(ed, "echo again");
    try waitFor(ed, "\nagain\n$");
}

test "e2e/terminal: a full-screen program takes the screen, and gives it back when it quits" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    {
        const found = try app.proj.oracle("command -v less >/dev/null && echo yes || echo no");
        defer gpa.free(found);
        if (!std.mem.startsWith(u8, found, "yes")) return error.SkipZigTest;
        const made = try app.proj.oracle("printf 'first line\\nsecond line\\n' > pager.txt");
        gpa.free(made);
    }
    try openShell(&app, test_shell);

    enter(ed, "less pager.txt");
    try waitFor(ed, "first line\nsecond line");
    ed.press("q", "q");
    // The alternate screen is gone: the primary one is back, prompt and all.
    try waitFor(ed, "$ less pager.txt\n$");
    const text = h.toolText(ed, term) orelse return error.NoScreen;
    defer gpa.free(text);
    try t.expect(std.mem.indexOf(u8, text, "second line") == null);
}

test "e2e/terminal: the pane's size is the terminal's, and a resize reaches the child" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    // In the main pane, where a split can change its width.
    try ed.setConfig("terminal", "viewport", "none");
    try openShell(&app, test_shell);

    const g = h.gridOf(ed, term) orelse return error.NoGrid;
    var want_buf: [32]u8 = undefined;
    enter(ed, "stty size");
    try waitFor(ed, try std.fmt.bufPrint(&want_buf, "\n{d} {d}\n", .{ g.rows, g.cols }));
    const wide = g.cols;

    ed.run("window.split-right");
    ed.settle(2);
    try t.expect(g.cols < wide);
    enter(ed, "stty size");
    try waitFor(ed, try std.fmt.bufPrint(&want_buf, "\n{d} {d}\n", .{ g.rows, g.cols }));
}

test "e2e/terminal: the ide break-out chord is the only key a capturing terminal does not take" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openShell(&app, test_shell);
    // Escape, Tab and C-a — every one an editor key in ide.js — are the
    // child's: `cat -v` shows what reached it. (Not C-w: the tty itself takes
    // that one, as word erase.)
    enter(ed, "cat -v");
    ed.press("Escape", "");
    ed.press("Tab", "");
    ed.press("C-a", "");
    ed.press("Return", "");
    // Twice: the tty's echo, then cat's (a tab is a tab; ESC and C-a are
    // spelled `^[`, `^A`).
    try waitFor(ed, "\n^[      ^A\n^[      ^A\n");
    try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());
    ed.press("C-c", "");
    try waitFor(ed, "^C\n$");
}

/// The prompt the startup files `hermeticShellHome` writes set (the grid
/// drops its trailing blank, so it is matched without one).
const test_prompt = "weft-e2e>";

/// Give the shell the terminal starts here a home of its own: startup files
/// that set `test_prompt` and nothing else, found through `HOME` (bash),
/// `ZDOTDIR` (zsh) and `ENV` (sh), published as the environment of the place
/// the terminal runs in. The user's own rc files — which may take seconds or
/// print — are not read, and zsh skips the system-wide ones too.
fn hermeticShellHome(app: *IdeApp) !void {
    const gpa = app.ed.gpa;
    const out = try app.proj.oracle("mkdir -p home && " ++
        "printf \"PS1='" ++ test_prompt ++ " '\\n\" > home/.bashrc && " ++
        "printf 'setopt no_global_rcs\\n' > home/.zshenv && " ++
        "printf \"PROMPT='" ++ test_prompt ++ " '\\n\" > home/.zshrc && " ++
        "cp home/.bashrc home/.shrc");
    gpa.free(out);
    const vars = try std.fmt.allocPrint(gpa, "HOME={0s}/home\x00ZDOTDIR={0s}/home\x00ENV={0s}/home/.shrc\x00", .{app.proj.root});
    defer gpa.free(vars);
    const system = app.ed.session.system;
    _ = try system.environments.publish(system.buffers.active().place, "e2e", vars);
}

test "e2e/terminal: $SHELL (bash, zsh or sh) runs in the place's environment, answers, and shows a typed line once" {
    const gpa = t.allocator;
    // Only a shell `hermeticShellHome` can give its prompt to.
    const shell = std.fs.path.basename(std.mem.span(std.c.getenv("SHELL") orelse return error.SkipZigTest));
    for ([_][]const u8{ "bash", "zsh", "sh" }) |known| {
        if (std.mem.eql(u8, shell, known)) break;
    } else return error.SkipZigTest;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "x.txt", "x\n");
    try hermeticShellHome(&app);
    ed.press("C-grave", "");
    try waitFor(ed, test_prompt);
    // The answer goes to stderr, which is the same terminal: the line editor
    // echoes the typed line once, and the shell answers under it.
    enter(ed, "echo $((6*7)) >&2");
    try waitFor(ed, "\n42\n");
    const text = h.toolText(ed, term) orelse return error.NoScreen;
    defer gpa.free(text);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, "echo $((6*7)) >&2"));
}

/// A flood through the terminal, timed frame by frame: how long the output
/// takes to reach the screen, and what one frame (read the pty, emulate,
/// publish the changed rows, build and draw) costs meanwhile. Opt-in
/// (`WEFT_BENCH_TERMINAL=1`): it measures, it does not gate.
fn floodBench(cmd: []const u8, label: []const u8, read: bool) !void {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openShell(&app, test_shell);
    var line_buf: [256]u8 = undefined;
    // The marker is spelled apart on the typed line, so only the shell's
    // answer reads `flood-done`.
    enter(ed, try std.fmt.bufPrint(&line_buf, "{s}; echo flood-\"\"done", .{cmd}));
    // Read rather than captured: every wake also sends the rows that
    // scrolled into the scrollback, and core keeps the text in step.
    if (read) ed.press("C-backslash", "");
    var frames: std.ArrayList(u64) = .empty;
    defer frames.deinit(gpa);
    const start = core.task.nowNs();
    const deadline = start + 120 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        const f0 = core.task.nowNs();
        const pixels = try ed.renderComposite();
        gpa.free(pixels);
        try frames.append(gpa, core.task.nowNs() - f0);
        const text = h.toolText(ed, term) orelse continue;
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, "flood-done") != null) break;
    } else return error.FloodNeverEnded;
    const total = core.task.nowNs() - start;
    std.mem.sort(u64, frames.items, {}, std.sort.asc(u64));
    const n = frames.items.len;
    std.debug.print("[bench/terminal] {s}: {d} ms to the screen, {d} frames; frame p50 {d} us, p90 {d} us, max {d} us\n", .{
        label, total / std.time.ns_per_ms, n, frames.items[n / 2] / 1000, frames.items[n * 9 / 10] / 1000, frames.items[n - 1] / 1000,
    });
}

test "bench/terminal: yes and ls -R floods" {
    if (std.c.getenv("WEFT_BENCH_TERMINAL") == null) return error.SkipZigTest;
    try floodBench("yes | head -n 200000", "yes x200000", false);
    try floodBench("yes | head -n 200000", "yes x200000, read (broken out)", true);
    try floodBench("ls -R /nix/store 2>/dev/null | head -n 100000", "ls -R | head -100000", false);
    try floodBench("ls -R /nix/store 2>/dev/null | head -n 100000", "ls -R | head -100000, read (broken out)", true);
    try floodBench("true", "idle prompt", false);
}

/// The median of `rounds` forced frames of `ed` as it is now, in µs.
fn medianFrameUs(ed: *Editor, rounds: usize) !u64 {
    var frames: [64]u64 = undefined;
    const n = @min(rounds, frames.len);
    for (frames[0..n]) |*f| {
        const f0 = core.task.nowNs();
        const pixels = try ed.renderComposite();
        ed.gpa.free(pixels);
        f.* = core.task.nowNs() - f0;
    }
    std.mem.sort(u64, frames[0..n], {}, std.sort.asc(u64));
    return frames[n / 2] / 1000;
}

test "bench/terminal: a frame with a full terminal in the panel, against one with text there" {
    if (std.c.getenv("WEFT_BENCH_TERMINAL") == null) return error.SkipZigTest;
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    // The baseline: the problems list in the panel (text rows).
    try ide.openFile(ed, "x.txt", "x\n");
    ed.press("C-S-m", "");
    ed.applyWindow();
    const text_us = try medianFrameUs(ed, 32);
    // The same panel, a terminal with every row full and coloured.
    try ed.setConfig("terminal", "shell", test_shell);
    ed.press("C-grave", "");
    enter(ed, "for i in $(seq 40); do printf '\\033[3%dm%s\\033[0m\\n' $((i%8)) \"$(seq -s ' ' 60)\"; done; echo full-\"\"screen");
    try waitFor(ed, "full-screen");
    const grid_us = try medianFrameUs(ed, 32);
    std.debug.print("[bench/terminal] frame median: text panel {d} us, full terminal panel {d} us\n", .{ text_us, grid_us });
}

test "e2e/terminal: after the break-out chord, a click in the terminal (ide) or vim's `i` takes the keys back" {
    const gpa = t.allocator;
    {
        var app: IdeApp = undefined;
        try app.init(gpa);
        defer app.deinit();
        const ed = &app.ed;
        try openShell(&app, test_shell);
        ed.press("C-backslash", "");
        try t.expect(ed.ctx.posture() != core.input.Posture.capture);
        // A click in the pane body is "type here", as in any IDE's terminal.
        const pixels = try ed.renderComposite();
        gpa.free(pixels);
        const pane = ed.viewportPane("panel") orelse return error.PanelNotShown;
        const r = ed.win_layout.focusedRect(pane, ed.application.last_frame_rect);
        ed.click(.{ r.x + r.w / 2, r.y + r.h / 2 });
        try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());
        enter(ed, "echo clicked");
        try waitFor(ed, "\nclicked\n");
    }
    {
        var app: chrome.GrammarApp = undefined;
        try app.init(gpa, "config.js", null);
        defer app.deinit();
        const ed = &app.ed;
        try app.open("x.txt", "x\n");
        try ed.setConfig("terminal", "shell", test_shell);
        ed.runStr("terminal.open", "");
        ed.applyWindow();
        if (!h.drainToolContains(ed, term, "$")) return screenFailed(ed, error.PromptNeverShown);
        // Out, to normal mode in the terminal's pane — then `i` goes back in,
        // as in vim's :terminal, rather than inserting into nothing.
        ed.press("C-backslash", "");
        try t.expect(ed.ctx.posture() != core.input.Posture.capture);
        try t.expectEqualStrings(term, ed.buffers.active().name);
        ed.press("i", "i");
        try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());
        enter(ed, "echo again");
        try waitFor(ed, "\nagain\n");
    }
    {
        // Where there is nothing to resume, `i` is vim's insert as ever.
        var app: chrome.GrammarApp = undefined;
        try app.init(gpa, "config.js", null);
        defer app.deinit();
        const ed = &app.ed;
        try app.open("y.txt", "y\n");
        ed.press("i", "i");
        try t.expectEqualStrings("insert", ed.head.currentMode());
    }
}

/// Render one frame, so the chrome a click aims at is laid out.
fn frameNow(ed: *Editor) !void {
    const pixels = try ed.renderComposite();
    ed.gpa.free(pixels);
}

fn named(ed: *Editor, name: []const u8) ?*core.Buffers.Buffer {
    const id = ed.buffers.findByName(name) orelse return null;
    return ed.buffers.get(id);
}

test "e2e/terminal: two terminals in the panel are two tabs of its header — a click switches, the × closes one and the panel shows the other" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openShell(&app, test_shell);
    enter(ed, "echo first-shell");
    try waitFor(ed, "\nfirst-shell\n");
    const first_id = (named(ed, term) orelse return error.NoFirstTerminal).id;

    // "+ New Terminal" in the header starts a second one, beside the first.
    try frameNow(ed);
    ed.click(ed.pointAtTabCommand("terminal.new") orelse return error.NoNewTerminalTab);
    ed.applyWindow();
    const second_name = "*terminal:2*";
    if (!h.drainToolContains(ed, second_name, "$")) return error.SecondPromptNeverShown;
    try t.expectEqualStrings(second_name, (panelEntry(ed) orelse return error.PanelNotShown).name);
    try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());
    enter(ed, "echo second-shell");
    if (!h.drainToolContains(ed, second_name, "\nsecond-shell\n")) return error.SecondNeverAnswered;
    const second_id = (named(ed, second_name) orelse return error.NoSecondTerminal).id;
    // Each has its own screen.
    {
        const text = h.toolText(ed, term) orelse return error.NoScreen;
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "second-shell") == null);
    }

    // Both are tabs of the panel's header, and neither is an editor tab.
    try frameNow(ed);
    try t.expect(ed.pointAtTab(first_id, .body) != null);
    try t.expect(ed.pointAtTab(second_id, .body) != null);
    var strip: [16]u32 = undefined;
    var editor_tabs: usize = 0;
    for (ed.tabEntries(&strip)) |id| {
        if (id == first_id or id == second_id) editor_tabs += 1;
    }
    // (Each is listed once, by the panel's header, not twice.)
    try t.expectEqual(@as(usize, 2), editor_tabs);

    // A click on the first's tab shows it in the panel, taking the keys.
    ed.click(ed.pointAtTab(first_id, .body).?);
    ed.applyWindow();
    try t.expectEqualStrings(term, (panelEntry(ed) orelse return error.PanelNotShown).name);
    try t.expectEqualStrings(term, ed.buffers.active().name);
    try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());
    enter(ed, "echo back-in-first");
    try waitFor(ed, "\nback-in-first\n");

    // The second's × closes it: its entry goes, its tab goes, and the panel
    // goes on showing the first.
    try frameNow(ed);
    ed.click(ed.pointAtTab(second_id, .close) orelse return error.NoCloseGlyph);
    ed.applyWindow();
    ed.settle(2);
    try t.expect(named(ed, second_name) == null);
    try frameNow(ed);
    try t.expect(ed.pointAtTab(first_id, .body) != null);
    try t.expectEqualStrings(term, (panelEntry(ed) orelse return error.PanelNotShown).name);

    // `terminal.open` shows the one used last rather than starting another;
    // the next new one is `terminal.3` — a closed terminal's name is never
    // reused for a different shell.
    ed.press("C-grave", "");
    ed.applyWindow();
    try t.expectEqualStrings(term, (panelEntry(ed) orelse return error.PanelNotShown).name);
    ed.run("terminal.new");
    ed.applyWindow();
    try t.expectEqualStrings("*terminal:3*", (panelEntry(ed) orelse return error.PanelNotShown).name);
    var dbuf: [core.designation.max_len]u8 = undefined;
    try t.expectEqualStrings("weft://here/proc/terminal.3", core.designation.of(ed.buffers.active(), &dbuf).?);

    // Closing the one shown: the panel shows the other again.
    try frameNow(ed);
    ed.click(ed.pointAtTab(ed.buffers.active().id, .close) orelse return error.NoCloseGlyph);
    ed.applyWindow();
    ed.settle(2);
    try t.expectEqualStrings(term, (panelEntry(ed) orelse return error.PanelNotShown).name);
}

test "e2e/terminal: a terminal is an ordinary entry — in an editor pane it is an editor tab" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ed.setConfig("terminal", "viewport", "none");
    try openShell(&app, test_shell);
    try t.expect(ed.viewportPane("panel") == null);
    try t.expectEqualStrings(term, ed.buffers.active().name);
    try frameNow(ed);
    var strip: [16]u32 = undefined;
    try t.expect(std.mem.indexOfScalar(u32, ed.tabEntries(&strip), ed.buffers.active().id) != null);
}

// ── Terminal-normal: a terminal read as text ─────────────────────────

/// The terminal's document — its history and screen as text — once it holds
/// `needle`, driving frames (the pane tells the plugin it is read, and the
/// plugin sends its scrollback) until it does.
fn waitText(ed: *Editor, name: []const u8, needle: []const u8) ![]u8 {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.settle(1);
        const b = named(ed, name) orelse continue;
        const te = b.textEditor() orelse continue;
        const text = try te.text().toOwnedSlice(ed.gpa);
        if (std.mem.indexOf(u8, text, needle) != null) return text;
        ed.gpa.free(text);
    }
    return error.TextNeverShown;
}

/// The line of `text` the caret is on.
fn caretLine(ed: *Editor) ![]u8 {
    const te = ed.buffers.active().textEditor() orelse return error.NoText;
    const rope = te.text();
    const range = rope.lineRange(rope.offsetToPoint(te.cursorOffset()).row);
    const out = try ed.gpa.alloc(u8, range.end - range.start);
    rope.copyRange(out, range);
    return out;
}

test "e2e/terminal: out of capture a terminal is text — vim searches its scrollback, yanks a line, and `i` takes the keys back" {
    const gpa = t.allocator;
    var app: chrome.GrammarApp = undefined;
    try app.init(gpa, "config.js", null);
    defer app.deinit();
    const ed = &app.ed;
    try app.open("x.txt", "x\n");
    try ed.setConfig("terminal", "shell", test_shell);
    ed.runStr("terminal.open", "");
    ed.applyWindow();
    if (!h.drainToolContains(ed, term, "$")) return screenFailed(ed, error.PromptNeverShown);
    // Far more than the panel shows: most of it scrolls into the scrollback.
    enter(ed, "seq 1 300; echo seq-\"\"done");
    try waitFor(ed, "\nseq-done\n$");

    // Out of capture: the screen and its scrollback are the entry's text,
    // read-only, with vim's caret where the shell's cursor was.
    ed.press("C-backslash", "");
    try t.expect(ed.ctx.posture() != core.input.Posture.capture);
    try t.expectEqualStrings("normal", ed.head.currentMode());
    {
        const text = try waitText(ed, term, "\n1\n2\n3\n");
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "\n299\n300\nseq-done\n$") != null);
    }
    {
        const line = try caretLine(ed);
        defer gpa.free(line);
        try t.expectEqualStrings("$", line);
    }

    // `/142` finds it in the scrollback, far above the screen; `yy` yanks it.
    ed.press("/", "");
    ed.settle(5);
    ed.typeText("142");
    ed.settle(5);
    ed.press("Return", "");
    {
        const line = try caretLine(ed);
        defer gpa.free(line);
        try t.expectEqualStrings("142", line);
    }
    ed.typeText("yy");
    try t.expectEqualStrings("142", (ed.register.get(0) orelse return error.NothingYanked).slice());
    // And it is drawn: the pane shows the rows around the caret, from the
    // scrollback, as cells — not the live screen.
    try frameNow(ed);
    {
        const v = try ed.ensureView();
        const lines = v.frame_layout.lines;
        try t.expect(lines.len > 0);
        var saw = false;
        for (lines) |vl| {
            if (vl.src.end - vl.src.start == 3) saw = true;
        }
        try t.expect(saw);
    }
    // Visual selection over two lines, yanked — and the yank flashes.
    const flashes = ed.caps.flash.genOf(.edit);
    ed.press("V", "");
    ed.press("j", "");
    ed.press("y", "");
    try t.expectEqualStrings("142\n143", (ed.register.get(0) orelse return error.NothingYanked).slice());
    try t.expect(ed.caps.flash.genOf(.edit) != flashes);
    // The text is the program's: an edit is refused, the text unchanged.
    {
        const before = try named(ed, term).?.textEditor().?.text().toOwnedSlice(gpa);
        defer gpa.free(before);
        ed.typeText("dd");
        const after = try named(ed, term).?.textEditor().?.text().toOwnedSlice(gpa);
        defer gpa.free(after);
        try t.expectEqualStrings(before, after);
    }

    // `i` takes the keys back, as in vim's :terminal; the shell answers.
    ed.press("i", "i");
    try t.expectEqual(core.input.Posture.capture, ed.ctx.posture());
    enter(ed, "echo again");
    try waitFor(ed, "\nagain\n$");
}

test "e2e/terminal: out of capture under ide, a drag selects the terminal's cells and C-c copies them" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openShell(&app, test_shell);
    enter(ed, "echo copy-me-please");
    try waitFor(ed, "\ncopy-me-please\n$");
    ed.press("C-backslash", "");
    try t.expect(ed.ctx.posture() != core.input.Posture.capture);
    const text = try waitText(ed, term, "\ncopy-me-please\n");
    defer gpa.free(text);
    // The output line (not the typed one): drag from its `me` to its end.
    const line_at = std.mem.indexOf(u8, text, "\ncopy-me-please\n").? + 1;
    // Up the text to it (it may have scrolled into the history): the caret
    // walks the rows as it walks any text, and the pane follows it.
    for (0..8) |_| {
        try frameNow(ed);
        if (ed.pointAt(line_at) != null) break;
        ed.press("Up", "");
    }
    const from = ed.pointAt(line_at + "copy-".len) orelse return error.LineNotShown;
    const to = ed.pointAt(line_at + "copy-me-please".len) orelse return error.LineNotShown;
    ed.pointer_ms += 1000;
    ed.gestures.warp(from[0], from[1]);
    ed.pointerButton(1, true, .{});
    ed.pointerMove(.{ (from[0] + to[0]) / 2, from[1] }, .{});
    ed.pointerMove(.{ to[0] + 2, to[1] }, .{});
    ed.pointerButton(1, false, .{});
    try t.expect(ed.ctx.posture() != core.input.Posture.capture);
    ed.press("C-c", "");
    try t.expectEqualStrings("me-please", ed.head.clipboard.text());
}

// ── Shell integration (doc/terminal.md §7) ───────────────────────────

/// Whether `program` is on the PATH the tests run with.
fn have(app: *IdeApp, program: []const u8) !bool {
    var buf: [128]u8 = undefined;
    const found = try app.proj.oracle(try std.fmt.bufPrint(&buf, "command -v {s} >/dev/null && echo yes || echo no", .{program}));
    defer app.ed.gpa.free(found);
    return std.mem.startsWith(u8, found, "yes");
}

/// The directory the terminal entry's place is, or "".
fn placeDir(ed: *Editor) []const u8 {
    const b = named(ed, term) orelse return "";
    return switch (core.place.realize(b.place, ed.ctx.realizer)) {
        .path => |p| p,
        else => "",
    };
}

/// The integration injected into `shell` (a bare program, so `launch` runs
/// it): the prompt's cells are marked, `cd` moves the entry's place, the
/// prompts are landmarks the grammar's keys move between, and a command's
/// output can be selected whole.
fn integrationCase(app: *IdeApp, shell: []const u8) !void {
    const gpa = app.ed.gpa;
    const ed = &app.ed;
    try ide.openFile(ed, "x.txt", "x\n");
    try hermeticShellHome(app);
    {
        const made = try app.proj.oracle("mkdir -p sub/deeper");
        gpa.free(made);
    }
    try ed.setConfig("terminal", "shell", shell);
    ed.press("C-grave", "");
    ed.applyWindow();
    try waitFor(ed, test_prompt);

    // The prompt's cells say they are the prompt (OSC 133 A/B).
    {
        const row = rowReading(ed, test_prompt) orelse return screenFailed(ed, error.NoPromptRow);
        try t.expect(row[0].mark.prompt);
    }
    // TERM_PROGRAM says weft, for an rc file to test.
    enter(ed, "echo \"prog=$TERM_PROGRAM\"");
    try waitFor(ed, "\nprog=weft\n");

    // OSC 7: the entry's place follows the shell's directory.
    enter(ed, "cd sub/deeper");
    const want = try std.fmt.allocPrint(gpa, "{s}/sub/deeper", .{app.proj.root});
    defer gpa.free(want);
    {
        const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
        while (core.task.nowNs() < deadline and !std.mem.eql(u8, placeDir(ed), want)) ed.settle(1);
        try t.expectEqualStrings(want, placeDir(ed));
    }

    // Two commands, then out of capture: the prompts are landmarks.
    enter(ed, "echo landmark-one");
    try waitFor(ed, "\nlandmark-one\n");
    enter(ed, "echo landmark-two; echo second-line");
    try waitFor(ed, "\nsecond-line\n");
    ed.press("C-backslash", "");
    {
        const text = try waitText(ed, term, "second-line");
        gpa.free(text);
    }
    // The caret is on the last prompt (where the shell's cursor was): C-Up
    // is the one before it.
    ed.press("C-Up", "");
    {
        const line = try caretLine(ed);
        defer gpa.free(line);
        try t.expect(std.mem.indexOf(u8, line, "echo landmark-two") != null);
    }
    // The caret starts where the command line does.
    {
        const te = ed.buffers.active().textEditor().?;
        const rope = te.text();
        const range = rope.lineRange(rope.offsetToPoint(te.cursorOffset()).row);
        const at = te.cursorOffset() - range.start;
        const line = try caretLine(ed);
        defer gpa.free(line);
        try t.expectEqualStrings("echo landmark-two; echo second-line", std.mem.trim(u8, line[at..], " "));
    }
    // The command's output, selected whole.
    ed.run("grid.select-landmark-body");
    {
        const te = ed.buffers.active().textEditor().?;
        const r = te.selectedRange() orelse return error.NothingSelected;
        const out = try gpa.alloc(u8, r.end - r.start);
        defer gpa.free(out);
        te.text().copyRange(out, r);
        try t.expectEqualStrings("landmark-two\nsecond-line", out);
    }
    // From the end of that output: its own prompt, then the one before.
    ed.press("C-Up", "");
    ed.press("C-Up", "");
    {
        const line = try caretLine(ed);
        defer gpa.free(line);
        try t.expect(std.mem.indexOf(u8, line, "echo landmark-one") != null);
    }
    ed.press("C-Down", "");
    {
        const line = try caretLine(ed);
        defer gpa.free(line);
        try t.expect(std.mem.indexOf(u8, line, "echo landmark-two") != null);
    }
}

test "e2e/terminal: bash gets weft's integration injected — marked prompts, cd moves the entry's place, prompts are landmarks" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    if (!try have(&app, "bash")) return error.SkipZigTest;
    try integrationCase(&app, "bash");
}

test "e2e/terminal: zsh gets weft's integration injected through ZDOTDIR, its own startup files still read" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    // zsh is not in the nix shell itself; the host's may be on PATH.
    if (!try have(&app, "zsh")) return error.SkipZigTest;
    try integrationCase(&app, "zsh");
}

test "e2e/terminal: integration off, or a whole command line, runs the shell as it is" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ed.setConfig("terminal", "integration", "off");
    try ide.openFile(ed, "x.txt", "x\n");
    try hermeticShellHome(&app);
    try ed.setConfig("terminal", "shell", "bash");
    ed.press("C-grave", "");
    ed.applyWindow();
    try waitFor(ed, test_prompt);
    const row = rowReading(ed, test_prompt) orelse return screenFailed(ed, error.NoPromptRow);
    try t.expect(!row[0].mark.prompt);
}
