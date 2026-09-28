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
fn floodBench(cmd: []const u8, label: []const u8) !void {
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
    try floodBench("yes | head -n 200000", "yes x200000");
    try floodBench("ls -R /nix/store 2>/dev/null | head -n 100000", "ls -R | head -100000");
    try floodBench("true", "idle prompt");
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
