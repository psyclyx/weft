//! e2e test file — the rest of ide.js's chrome (doc/configs.md §3.1.4,
//! §3.6.4): clickable tabs and status segments, the bottom panel with the
//! problems list and the terminal in it, and the breadcrumbs.
//!
//! Each is driven the way a person drives it — a click through the platform
//! gesture reducer, a key through the keymap — and each gate reads what the
//! person would see: which entry is in front, what the panel lists, what the
//! shell printed, which crumbs the status line shows.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");

const core = h.core;
const window_layout = h.window_layout;
const Editor = h.Editor;
const IdeApp = ide.IdeApp;

/// Build one frame now, so the chrome's hit regions describe the present.
fn frame(ed: *Editor) !void {
    const pixels = try ed.renderComposite();
    ed.gpa.free(pixels);
}

fn bufferId(ed: *Editor, name: []const u8) ?u32 {
    var it = ed.buffers.iterator();
    while (it.next()) |b| {
        const path = if (b.textEditor()) |te| te.backingPath() orelse b.name else b.name;
        if (std.mem.eql(u8, std.fs.path.basename(path), name)) return b.id;
    }
    return null;
}

fn activeName(ed: *Editor) []const u8 {
    const b = ed.buffers.active();
    const path = if (b.textEditor()) |te| te.backingPath() orelse b.name else b.name;
    return std.fs.path.basename(path);
}

/// The entry the bottom panel shows, or null when it is not docked.
fn panelEntry(ed: *Editor) ?*core.Buffers.Buffer {
    const node = ed.win_layout.dockedPanel(.bottom) orelse return null;
    return ed.buffers.get(node.pane().buffer_id);
}

test "e2e/panels: a tab click shows its file, a middle click and the close glyph close it, and chrome is never a tab" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ide.openFile(ed, "a.txt", "alpha\n");
    try ide.openFile(ed, "b.txt", "beta\n");
    try ide.openFile(ed, "c.txt", "gamma\n");
    const a = bufferId(ed, "a.txt").?;
    const b = bufferId(ed, "b.txt").?;
    const c = bufferId(ed, "c.txt").?;
    try frame(ed);

    // The strip lists documents only: the sidebar's listing and the
    // toolbar's strip are docked companions' entries, not tabs.
    var ids_buf: [16]u32 = undefined;
    const ids = ed.tabEntries(&ids_buf);
    const listing = ed.win_layout.dockedPanel(.left).?.pane().buffer_id;
    try t.expect(std.mem.indexOfScalar(u32, ids, listing) == null);
    for (ids) |id| try t.expect(!ed.ctx.viewports.?.holdsEntry(ed.buffers.get(id).?.designationText()));
    for ([_]u32{ a, b, c }) |want| try t.expect(std.mem.indexOfScalar(u32, ids, want) != null);

    // A click on a's tab puts a in front.
    ed.click(ed.pointAtTab(a, .body) orelse return error.NoTab);
    try t.expectEqualStrings("a.txt", activeName(ed));
    try t.expectEqual(core.pointer.Chrome.Of.tab, ed.head.pointer.hit.chrome.?.kind);

    // A middle click on b's tab closes b, and a stays in front.
    try frame(ed);
    ed.clickWith(ed.pointAtTab(b, .body) orelse return error.NoTab, 2, .{});
    try t.expect(ed.buffers.get(b) == null);
    try t.expectEqualStrings("a.txt", activeName(ed));

    // The close glyph on c's tab closes c.
    try frame(ed);
    ed.click(ed.pointAtTab(c, .close) orelse return error.NoCloseGlyph);
    try t.expect(ed.buffers.get(c) == null);
    try t.expectEqualStrings("a.txt", activeName(ed));
}

test "e2e/panels: the problems list shows every diagnostic by file, follows the signal, and Return jumps" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try core.file.writeBytes(gpa, "p.zig", "const a = 1;\nconst bee = 2;\nconst c = 3;\n");
    try ide.openFile(ed, "q.txt", "one\ntwo\n");
    try h.loadDiagfeed(ed);
    try ed.setConfig("problems", "source", "diagfeed.list");
    ed.runStr("diagfeed.set", "p.zig\t2\t7\terror\tbee is unused\n");

    // The panel starts hidden; C-S-m opens the list in it and focuses it.
    ed.applyWindow();
    try t.expect(ed.win_layout.dockedPanel(.bottom) == null);
    ed.press("C-S-m", "");
    ed.applyWindow();
    const shown = panelEntry(ed) orelse return error.PanelNotShown;
    try t.expectEqualStrings("*problems*", shown.name);
    try t.expectEqualStrings("*problems*", ed.buffers.active().name);
    // The editor pane kept its document.
    const primary = ed.win_layout.primaryPane().?;
    try t.expectEqualStrings("q.txt", std.fs.path.basename(ed.buffers.get(primary.pane().buffer_id).?.textEditor().?.backingPath().?));

    const view = ed.toolView() orelse return error.NoProblemsView;
    {
        const text = try ed.semanticText(view);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "p.zig") != null);
        try t.expect(std.mem.indexOf(u8, text, "2:7  error  bee is unused") != null);
    }
    // The list is a projection: THIS place's diagnostics, by designation
    // (doc/model.md §2.4) — what reopens it, and what the panel holds.
    var want_buf: [4096]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "weft://here/diagnostics/{s}", .{app.proj.root[1..]});
    try t.expectEqualStrings(want, shown.designationText());

    // The source changes and says so; the open list follows at the next
    // frame boundary, with nothing re-run by hand. A row from outside the
    // place is not this place's.
    ed.runStr("diagfeed.set", "p.zig\t1\t7\twarning\ta is shadowed\np.zig\t2\t7\terror\tbee is unused\n/elsewhere/x.zig\t1\t1\terror\tforeign\n");
    ed.applyWindow();
    {
        const text = try ed.semanticText(view);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "1:7  warning  a is shadowed") != null);
        try t.expect(std.mem.indexOf(u8, text, "foreign") == null);
    }

    // Down to the second row, Return: p.zig opens in the EDITOR pane with the
    // caret on the diagnostic, and the panel still shows the list.
    ed.press("Down", "");
    ed.press("Return", "");
    ed.applyWindow();
    const p = ed.buffers.get(bufferId(ed, "p.zig") orelse return error.NotOpened).?;
    try t.expectEqual(p.id, ed.win_layout.primaryPane().?.pane().buffer_id);
    try t.expectEqual(@as(usize, "const a = 1;\n".len + 6), p.textEditor().?.cursorOffset());
    try t.expectEqualStrings("*problems*", panelEntry(ed).?.name);
}

test "e2e/panels: two viewports on two places' diagnostics each keep their own list, and neither re-runs the other" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ide.openFile(ed, "q.txt", "one\ntwo\n");
    try h.loadDiagfeed(ed);
    try ed.setConfig("problems", "source", "diagfeed.list");
    const rows = try std.fmt.allocPrint(gpa, "{s}/p.zig\t1\t1\terror\tin the project\n{s}/other/x.zig\t1\t1\terror\tin other\n", .{ app.proj.root, app.proj.root });
    defer gpa.free(rows);
    ed.runStr("diagfeed.set", rows);

    var a_buf: [4096]u8 = undefined;
    var b_buf: [4096]u8 = undefined;
    const a = try std.fmt.bufPrint(&a_buf, "weft://here/diagnostics/{s}", .{app.proj.root[1..]});
    const b = try std.fmt.bufPrint(&b_buf, "weft://here/diagnostics/{s}/other", .{app.proj.root[1..]});
    const viewports = &ed.session.system.viewports;
    try viewports.declare(gpa, "diag-a", .{ .dock = .top, .persistent = true, .cycles = false, .focus_source = false }, .{ .rows = 6 });
    try viewports.declare(gpa, "diag-b", .{ .dock = .right, .persistent = true, .cycles = false, .focus_source = false }, .{ .rows = 30 });
    try viewports.present(gpa, "diag-a", .{ .subject = .{ .text = a } });
    try viewports.present(gpa, "diag-b", .{ .subject = .{ .text = b } });
    ed.runStr("file.open", "q.txt");
    ed.applyWindow();
    ed.applyWindow();

    const pane_a = ed.win_layout.dockedPanel(.top) orelse return error.NoPaneA;
    const pane_b = ed.win_layout.dockedPanel(.right) orelse return error.NoPaneB;
    const entry_a = ed.buffers.get(pane_a.pane().buffer_id) orelse return error.NoEntryA;
    const entry_b = ed.buffers.get(pane_b.pane().buffer_id) orelse return error.NoEntryB;
    // One entry per place: each designated by what its viewport presents.
    try t.expect(entry_a.id != entry_b.id);
    try t.expectEqualStrings(a, entry_a.designationText());
    try t.expectEqualStrings(b, entry_b.designationText());
    {
        const text = try ed.semanticText(entry_b.scene_selection.view orelse return error.NoViewB);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "in other") != null);
        try t.expect(std.mem.indexOf(u8, text, "in the project") == null);
    }
    {
        const text = try ed.semanticText(entry_a.scene_selection.view orelse return error.NoViewA);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "in the project") != null);
    }

    // The signal refreshes both, and another frame presents neither again.
    const ids = .{ entry_a.id, entry_b.id };
    ed.runStr("diagfeed.set", rows);
    ed.applyWindow();
    ed.applyWindow();
    try t.expectEqual(ids[0], pane_a.pane().buffer_id);
    try t.expectEqual(ids[1], pane_b.pane().buffer_id);
    try t.expectEqualStrings(a, ed.buffers.get(ids[0]).?.designationText());
    try t.expectEqualStrings(b, ed.buffers.get(ids[1]).?.designationText());
}

test "e2e/panels: C-` runs a line-mode shell in the panel, with its controls stripped, and C-j hides and shows it" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ide.openFile(ed, "x.txt", "x\n");
    // An interactive shell, as the default one is (`$SHELL -i`), with a
    // prompt this test can name: it prints the prompt on stderr, with no
    // newline after it, and both reach the buffer as they are read.
    try ed.setConfig("terminal", "shell", "PS1='$ ' exec bash --norc --noprofile --noediting -i");
    ed.press("C-grave", "");
    ed.applyWindow();
    try t.expectEqualStrings("*terminal*", (panelEntry(ed) orelse return error.PanelNotShown).name);
    try t.expectEqualStrings("*terminal*", ed.buffers.active().name);
    try t.expectEqualStrings("terminal", ed.mode());
    try t.expect(h.drainToolContains(ed, "*terminal*", "\n$ "));

    ed.typeText("echo hi");
    ed.press("Return", "");
    try t.expect(h.drainToolContains(ed, "*terminal*", "$ echo hi\nhi\n$ "));
    // An artifact to eyeball: ide.js with the shell in the bottom panel.
    {
        const pixels = try ed.renderComposite();
        defer gpa.free(pixels);
        const path = try std.fmt.allocPrint(gpa, "{s}/.zig-cache/tmp/weft-app-ide-panel.ppm", .{app.proj.prev_cwd});
        defer gpa.free(path);
        h.gfx_harness.writePpm(gpa, path, pixels, h.app_w, h.app_h) catch {};
    }

    // Colors a program prints never reach the buffer as bytes.
    ed.typeText("printf '\\033[31mred\\033[0m\\n'");
    ed.press("Return", "");
    try t.expect(h.drainToolContains(ed, "*terminal*", "\nred\n"));
    {
        const text = h.toolText(ed, "*terminal*") orelse return error.NoTerminal;
        defer gpa.free(text);
        try t.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
    }

    // C-j hides the panel, and shows the same shell again.
    ed.press("C-j", "");
    ed.applyWindow();
    try t.expect(ed.win_layout.dockedPanel(.bottom) == null);
    ed.press("C-j", "");
    ed.applyWindow();
    try t.expectEqualStrings("*terminal*", (panelEntry(ed) orelse return error.PanelNotShown).name);

    // The problems list REPLACES the shell in the one panel.
    ed.press("C-S-m", "");
    ed.applyWindow();
    try t.expectEqualStrings("*problems*", panelEntry(ed).?.name);
    try t.expectEqual(@as(usize, 1), countDocked(ed, .bottom));
}

fn countDocked(ed: *Editor, edge: core.viewport.Edge) usize {
    return if (ed.win_layout.dockedPanel(edge) != null) 1 else 0;
}

/// Press C-` until the terminal shows `needle`. The shell's exit is noticed
/// on the next C-` (or keystroke), and the child takes however long it takes
/// to go, so each round settles the frame and asks again.
fn pressUntilTerminalShows(ed: *Editor, needle: []const u8) bool {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        ed.press("C-grave", "");
        ed.settle(1);
        const text = h.toolText(ed, "*terminal*") orelse continue;
        defer ed.gpa.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

test "e2e/panels: a shell that exits says so, and C-` starts a fresh one" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ide.openFile(ed, "x.txt", "x\n");
    // A whole command line (it has a space): run as written — a shell with
    // no prompt, so nothing interleaves with what the test waits for.
    try ed.setConfig("terminal", "shell", "exec /bin/sh");
    ed.press("C-grave", "");
    ed.typeText("echo up");
    ed.press("Return", "");
    try t.expect(h.drainToolContains(ed, "*terminal*", "echo up\nup\n"));

    ed.typeText("exit 3");
    ed.press("Return", "");
    try t.expect(pressUntilTerminalShows(ed, "[process exited 3]"));

    // The next line goes to the NEW shell, not the dead one.
    ed.typeText("echo again");
    ed.press("Return", "");
    try t.expect(h.drainToolContains(ed, "*terminal*", "echo again\nagain\n"));
}

/// The prompt the startup files `hermeticShellHome` writes set. A prompt the
/// test names, rather than "a line ending in a space": startup output reaches
/// the buffer in whatever pieces the pipe was read in, and a piece ending in a
/// space (`stty: `, `… Inappropriate `) is not a prompt.
const test_prompt = "weft-e2e> ";

/// Give the shell the terminal starts here a home of its own: startup files
/// that set `test_prompt` and nothing else, found through `HOME` (bash),
/// `ZDOTDIR` (zsh) and `ENV` (sh), published as the environment of the place
/// the terminal runs in. The user's own rc files — which may take seconds,
/// print, run `stty` on a pipe or emit terminal reports — are not read, and
/// zsh skips the system-wide ones too (`no_global_rcs`: a distribution's
/// /etc/zshrc can run compinit, seconds under load) and marks no partial
/// line before the prompt (`no_prompt_sp`).
fn hermeticShellHome(app: *IdeApp) !void {
    const gpa = app.ed.gpa;
    const out = try app.proj.oracle("mkdir -p home && " ++
        "printf \"PS1='" ++ test_prompt ++ "'\\n\" > home/.bashrc && " ++
        "printf 'setopt no_global_rcs\\n' > home/.zshenv && " ++
        "printf \"unsetopt prompt_sp\\nPROMPT='" ++ test_prompt ++ "'\\n\" > home/.zshrc && " ++
        "cp home/.bashrc home/.shrc");
    gpa.free(out);
    const vars = try std.fmt.allocPrint(gpa, "HOME={0s}/home\x00ZDOTDIR={0s}/home\x00ENV={0s}/home/.shrc\x00", .{app.proj.root});
    defer gpa.free(vars);
    const system = app.ed.session.system;
    _ = try system.environments.publish(system.buffers.active().place, "e2e", vars);
}

/// Run `echo $((6*7)) >&2` in the terminal started by `shell` (null: the
/// default, `$SHELL`) and say how many times the typed line shows. The answer
/// goes to stderr — the stream a line editor echoes on — so it cannot
/// overtake an echo of the line from the other pipe. Null when that shell is
/// not installed (it exits 127 before answering).
///
/// Each phase has its own deadline and its own failure: a shell slow to
/// start cannot spend the answer's time, nor fail as though it never
/// answered.
fn typedLineShows(app: *IdeApp, shell: ?[]const u8) !?usize {
    const ed = &app.ed;
    try ide.openFile(ed, "x.txt", "x\n");
    try hermeticShellHome(app);
    if (shell) |s| try ed.setConfig("terminal", "shell", s);
    ed.press("C-grave", "");
    // Type at the prompt, as a person does: what the shell prints while it
    // starts would otherwise land in the middle of the echoed line.
    const prompted = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (true) {
        if (core.task.nowNs() >= prompted) return terminalFailed(ed, error.PromptNeverShown);
        ed.settle(1);
        const text = h.toolText(ed, "*terminal*") orelse continue;
        defer ed.gpa.free(text);
        if (std.mem.indexOf(u8, text, "[process exited 127]") != null) return null;
        if (std.mem.endsWith(u8, text, test_prompt)) break;
        // A shell that is not there reports its exit on the next C-`.
        ed.press("C-grave", "");
    }
    ed.typeText("echo $((6*7)) >&2");
    ed.press("Return", "");
    const answered = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < answered) {
        // C-` again each round: a shell that is not there reports its exit.
        ed.press("C-grave", "");
        ed.settle(1);
        const text = h.toolText(ed, "*terminal*") orelse continue;
        defer ed.gpa.free(text);
        if (std.mem.indexOf(u8, text, "[process exited 127]") != null) return null;
        if (std.mem.indexOf(u8, text, "\n42\n") == null) continue;
        const shows = std.mem.count(u8, text, "echo $((6*7)) >&2");
        if (shows != 1) std.debug.print("[e2e/panels] the terminal reads:\n{s}\n", .{text});
        return shows;
    }
    return terminalFailed(ed, error.TerminalNeverAnswered);
}

/// Say what the terminal reads, then fail with `err`.
fn terminalFailed(ed: *Editor, err: anyerror) anyerror {
    if (h.toolText(ed, "*terminal*")) |text| {
        defer ed.gpa.free(text);
        std.debug.print("[e2e/panels] {t}; the terminal reads:\n{s}\n", .{ err, text });
    }
    return err;
}

test "e2e/panels: the default shell does not echo a typed line a second time" {
    const gpa = t.allocator;
    // Only a shell `hermeticShellHome` can give its prompt to.
    const shell = std.fs.path.basename(std.mem.span(std.c.getenv("SHELL") orelse return error.SkipZigTest));
    for ([_][]const u8{ "bash", "zsh", "sh" }) |known| {
        if (std.mem.eql(u8, shell, known)) break;
    } else return error.SkipZigTest;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    // `$SHELL` interactive, as ide.js runs it: the plugin echoes the line,
    // so the shell's own line editor must not echo it again.
    const shows = (try typedLineShows(&app, null)) orelse return error.SkipZigTest;
    try t.expectEqual(@as(usize, 1), shows);
}

test "e2e/panels: bash and zsh started by name edit no line of their own" {
    const gpa = t.allocator;
    for ([_][]const u8{ "bash", "zsh" }) |shell| {
        var app: IdeApp = undefined;
        try app.init(gpa);
        defer app.deinit();
        const shows = (try typedLineShows(&app, shell)) orelse continue; // not installed
        errdefer std.debug.print("[e2e/panels] {s} showed the typed line {d} times\n", .{ shell, shows });
        try t.expectEqual(@as(usize, 1), shows);
    }
}

test "e2e/panels: the breadcrumbs name the symbols around the caret, and a click on one jumps there" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    const src =
        \\const Point = struct {
        \\    fn norm(self: Point) u32 {
        \\        return 0;
        \\    }
        \\};
        \\
    ;
    try ide.openFile(ed, "b.zig", src);
    const fn_at = std.mem.indexOf(u8, src, "fn norm").?;
    ide.textEd(ed).placeCursor(std.mem.indexOf(u8, src, "return").?);

    // The grammar parses off the frame thread; frames until the crumbs show.
    var want_buf: [64]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "breadcrumbs.jump {d}", .{fn_at});
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    const at = while (core.task.nowNs() < deadline) {
        try frame(ed);
        if (ed.pointAtStatusCommand(want)) |xy| break xy;
        std.Thread.yield() catch {};
    } else return error.NoCrumbs;
    // The outer crumb is there too, and names the struct.
    try t.expect(ed.pointAtStatusCommand("breadcrumbs.jump 0") != null);

    // Clicking the inner crumb runs its command: the caret goes to `fn`.
    ed.click(at);
    try t.expectEqual(core.pointer.Chrome.Of.status, ed.head.pointer.hit.chrome.?.kind);
    try t.expectEqual(fn_at, ide.textEd(ed).cursorOffset());
}

test "e2e/panels: a panel whose entry closed does not capture the next entry to reuse its slot" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ide.openFile(ed, "x.txt", "x\n");
    ed.runStr("buffer.create", "held");
    const held = ed.buffers.active_id;
    ed.runStr("viewport.take", "panel");
    ed.applyWindow();
    try t.expectEqualStrings("held", (panelEntry(ed) orelse return error.PanelNotShown).name);

    // Hidden, the panel remembers its entry; the entry then closes, and an
    // unrelated one is created into the freed slot.
    ed.press("C-j", "");
    ed.applyWindow();
    try t.expect(ed.win_layout.dockedPanel(.bottom) == null);
    _ = try core.command.run(ed.commands, ed.ctx, "buffer.switch", &.{.{ .integer = held }});
    ed.run("buffer.close-unmodified");
    try t.expect(ed.buffers.get(held) == null);
    ed.runStr("buffer.create", "intruder");
    try t.expectEqual(held, ed.buffers.active_id);
    ed.runStr("file.open", "x.txt");

    // Shown again, the panel must not claim the intruder as what it held.
    ed.press("C-j", "");
    ed.applyWindow();
    const shown = panelEntry(ed) orelse return error.PanelNotShown;
    try t.expect(!std.mem.eql(u8, shown.name, "intruder"));
}
