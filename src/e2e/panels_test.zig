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
    for (ids) |id| try t.expect(!ed.ctx.viewports.?.holdsEntry(ed.buffers.get(id).?.ref()));
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
    try ed.setConfig("problems", "source", "diagfeed-list");
    ed.runStr("diagfeed-set", "p.zig\t2\t7\terror\tbee is unused\n");

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

    // The source changes and says so; the open list follows at the next
    // frame boundary, with nothing re-run by hand.
    ed.runStr("diagfeed-set", "p.zig\t1\t7\twarning\ta is shadowed\np.zig\t2\t7\terror\tbee is unused\n");
    ed.applyWindow();
    {
        const text = try ed.semanticText(view);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "1:7  warning  a is shadowed") != null);
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
    const want = try std.fmt.bufPrint(&want_buf, "breadcrumbs-jump {d}", .{fn_at});
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    const at = while (core.task.nowNs() < deadline) {
        try frame(ed);
        if (ed.pointAtStatusCommand(want)) |xy| break xy;
        std.Thread.yield() catch {};
    } else return error.NoCrumbs;
    // The outer crumb is there too, and names the struct.
    try t.expect(ed.pointAtStatusCommand("breadcrumbs-jump 0") != null);

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
    ed.runStr("buffer-create", "held");
    const held = ed.buffers.active_id;
    ed.runStr("viewport-take", "panel");
    ed.applyWindow();
    try t.expectEqualStrings("held", (panelEntry(ed) orelse return error.PanelNotShown).name);

    // Hidden, the panel remembers its entry; the entry then closes, and an
    // unrelated one is created into the freed slot.
    ed.press("C-j", "");
    ed.applyWindow();
    try t.expect(ed.win_layout.dockedPanel(.bottom) == null);
    _ = try core.command.run(ed.commands, ed.ctx, "buffer-switch", &.{.{ .integer = held }});
    ed.run("buffer-close");
    try t.expect(ed.buffers.get(held) == null);
    ed.runStr("buffer-create", "intruder");
    try t.expectEqual(held, ed.buffers.active_id);
    ed.runStr("open", "x.txt");

    // Shown again, the panel must not claim the intruder as what it held.
    ed.press("C-j", "");
    ed.applyWindow();
    const shown = panelEntry(ed) orelse return error.PanelNotShown;
    try t.expect(!std.mem.eql(u8, shown.name, "intruder"));
}
