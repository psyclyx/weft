//! e2e test file — the rest of ide.js's chrome (doc/configs.md §3.1.4,
//! §3.6.4): clickable tabs and status segments, the bottom panel with the
//! problems list in it (the terminal there has its own: terminal_test.zig), and
//! the breadcrumbs.
//!
//! Each is driven the way a person drives it — a click through the platform
//! gesture reducer, a key through the keymap — and each gate reads what the
//! person would see: which entry is in front, what the panel lists, which
//! crumbs the status line shows.

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
    const node = ed.viewportPane("panel") orelse return null;
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
    try t.expect(ed.viewportPane("panel") == null);
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
    try t.expect(ed.viewportPane("panel") == null);
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

test "e2e/panels: a panel declared `rows: 12` shows 12 body rows where panes carry no status line of their own" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ide.openFile(ed, "x.txt", "x\n");
    ed.press("C-j", "");
    ed.applyWindow();
    try frame(ed);
    // ide.js uses the one status bar (config/statusbar.js): no pane — the
    // panel neither — draws a line of its own, so none may be reserved.
    const node = ed.viewportPane("panel") orelse return error.PanelNotShown;
    const v = try ed.ensureView();
    const rect = ed.win_layout.focusedRect(node, ed.application.last_frame_rect);
    try t.expectEqual(@as(usize, 12), v.rowsIn(rect.h));
}

test "e2e/panels: the panel's header lists Problems and Terminal from their metadata, a tab click switches and lights it, and its × hides the panel" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try ide.openFile(ed, "x.txt", "x\n");

    // C-S-m opens the panel on Problems, with a header over it: one tab per
    // command `config/panel.js` named (`tabs: ["problems.open",
    // "entries:terminal", "terminal.new"]`), labeled straight from each command's own
    // presentation — the same table the palette and which-key read.
    ed.press("C-S-m", "");
    ed.applyWindow();
    try frame(ed);
    try t.expectEqualStrings("*problems*", (panelEntry(ed) orelse return error.PanelNotShown).name);
    try t.expectEqualStrings("Problems", core.presentations.of(ed.ctx, "problems.open").?.label);
    try t.expectEqualStrings("New Terminal", core.presentations.of(ed.ctx, "terminal.new").?.label);
    try t.expect(ed.pointAtTabCommand("problems.open") != null);
    try t.expect(ed.pointAtTabCommand("terminal.new") != null);
    try t.expect(ed.pointAtTabCommand("viewport.toggle panel") != null);

    // An artifact to eyeball: ide.js with the panel's header over Problems.
    app.proj.shot(ed, "ide-panel-header");

    // A click on New Terminal's tab starts a terminal in the panel, and the
    // header lists it: an entry tab (the `entries:terminal` line) beside the
    // commands; Problems' tab stays there to switch back to.
    ed.click(ed.pointAtTabCommand("terminal.new").?);
    ed.applyWindow();
    try frame(ed);
    const term_entry = panelEntry(ed) orelse return error.PanelNotShown;
    try t.expectEqualStrings("*terminal*", term_entry.name);
    try t.expect(ed.pointAtTabCommand("problems.open") != null);
    try t.expect(ed.pointAtTab(term_entry.id, .body) != null);

    // Its × (a distinct trailing tab, "viewport.toggle panel") hides the
    // whole panel — not just the entry it showed.
    ed.click(ed.pointAtTabCommand("viewport.toggle panel") orelse return error.NoCloseTab);
    ed.applyWindow();
    try t.expect(ed.viewportPane("panel") == null);
    // Focus left with the pane: the active entry is one a pane shows, so
    // keys stop going to the hidden terminal.
    try t.expect(!std.mem.eql(u8, "*terminal*", ed.ctx.buffers.active().name));

    // C-j brings it back, header included, showing what it held (terminal).
    ed.press("C-j", "");
    ed.applyWindow();
    try frame(ed);
    try t.expectEqualStrings("*terminal*", (panelEntry(ed) orelse return error.PanelNotShown).name);
    try t.expect(ed.pointAtTabCommand("problems.open") != null);
    try t.expect(ed.pointAtTabCommand("terminal.new") != null);

    // The header survives a chrome-style switch, in both directions.
    ed.runStr("theme.set-chrome", "widget");
    try frame(ed);
    try t.expect(ed.pointAtTabCommand("problems.open") != null);
    try t.expect(ed.pointAtTabCommand("terminal.new") != null);
    ed.runStr("theme.set-chrome", "text");
    try frame(ed);
    try t.expect(ed.pointAtTabCommand("problems.open") != null);
    try t.expect(ed.pointAtTabCommand("terminal.new") != null);
}

test "e2e/panels: window.close on the panel IS hiding it — it stays hidden, focus leaves with it, and showing it again brings back what it held" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.txt", "alpha\n");

    // Problems into the panel, focused there.
    ed.press("C-S-m", "");
    ed.applyWindow();
    try t.expectEqualStrings("*problems*", (panelEntry(ed) orelse return error.PanelNotShown).name);
    try t.expectEqualStrings("*problems*", ed.buffers.active().name);

    // The ordinary window close: one pane leaving the tree, like any other.
    ed.run("window.close");
    ed.applyWindow();
    try t.expect(ed.viewportPane("panel") == null);
    try t.expectEqualStrings("a.txt", activeName(ed));
    // Nothing remembers it as shown behind the tree's back: later layout
    // phases leave it closed.
    ed.applyWindow();
    try frame(ed);
    ed.applyWindow();
    try t.expect(ed.viewportPane("panel") == null);

    // A toggle decides against the tree: it is hidden, so it shows — with
    // what it held.
    ed.press("C-j", "");
    ed.applyWindow();
    try t.expectEqualStrings("*problems*", (panelEntry(ed) orelse return error.PanelNotShown).name);
}

/// What each named viewport's pane shows, by viewport index — to check that
/// closing and cycling documents never touches chrome.
fn chromeEntries(ed: *Editor, out: *[8]?u32) void {
    out.* = @splat(null);
    const Visit = struct {
        fn f(o: *[8]?u32, p: *window_layout.Pane) void {
            if (p.viewport) |i| if (i < o.len) {
                o[i] = p.buffer_id;
            };
        }
    };
    ed.win_layout.eachPane(out, Visit.f);
}

test "e2e/panels: closing and cycling documents never hands a pane a viewport's chrome, and a viewport whose entry closed shows it again" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.txt", "alpha\n");
    try ide.openFile(ed, "b.txt", "beta\n");
    try frame(ed);
    var chrome: [8]?u32 = undefined;
    chromeEntries(ed, &chrome);

    // Cycling steps through documents only — the scratch, a, b — never the
    // toolbar or the file tree, and comes back round.
    const start = ed.buffers.active_id;
    for (0..3) |_| {
        ed.run("buffer.next");
        ed.applyWindow();
        try t.expect(ed.session.system.viewports.isDocument(ed.buffers.active()));
    }
    try t.expectEqual(start, ed.buffers.active_id);

    // Closing every document leaves a fresh scratch in the editor — and every
    // chrome pane exactly as it was.
    for (0..3) |_| {
        ed.run("buffer.close-force");
        ed.applyWindow();
    }
    try t.expectEqualStrings("*scratch*", ed.buffers.active().name);
    var after: [8]?u32 = undefined;
    chromeEntries(ed, &after);
    try t.expectEqualSlices(?u32, &chrome, &after);

    // C-w with the sidebar focused closes its listing — which the sidebar
    // opens again rather than showing whatever is active.
    try frame(ed);
    const sb = ed.viewportPane("sidebar") orelse return error.NoSidebar;
    const r = ed.win_layout.focusedRect(sb, ed.application.last_frame_rect);
    ed.click(.{ r.x + 20, r.y + r.h - 20 });
    ed.press("C-w", "");
    ed.applyWindow();
    const listing = ed.buffers.get(ed.viewportPane("sidebar").?.pane().buffer_id) orelse return error.SidebarLost;
    try t.expect(std.mem.startsWith(u8, listing.name, "files:"));
    chromeEntries(ed, &after);
    for (chrome, after, 0..) |was, now, i| if (i != 0) try t.expectEqual(was, now);
}

/// The dashboard item labeled `label`.
fn dashboardItem(ed: *Editor, label: []const u8) ?h.semantic_model.scene.NodeId {
    const view_ref = ed.toolView() orelse return null;
    const instance = ed.session.system.semantic.views.get(view_ref) orelse return null;
    for (instance.focus_order) |id| {
        const node = instance.node(id) orelse continue;
        if (node.content == .action and std.mem.eql(u8, node.content.action.label, label)) return id;
    }
    return null;
}

test "e2e/panels: ide.js — the dashboard's items are clicked, or Enter'd, with no key or mode of the dashboard's own" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    ed.run("dashboard.open");
    ed.applyWindow();
    try t.expectEqualStrings("*dashboard*", ed.buffers.active().name);
    try t.expect(!std.mem.eql(u8, ed.head.currentMode(), "dashboard"));

    // A click on "New buffer" runs it.
    try frame(ed);
    const new_buffer = dashboardItem(ed, "New buffer") orelse return error.NoItem;
    const here = window_layout.headFocus(ed.win_layout, ed.head).pane().id;
    ed.click(ed.pointAtNodeIn(here, new_buffer) orelse return error.ItemNotShown);
    ed.applyWindow();
    try t.expect(!std.mem.eql(u8, ed.buffers.active().name, "*dashboard*"));

    // Enter on "Open file" — ide's own activate key — opens the file picker.
    ed.run("dashboard.open");
    ed.applyWindow();
    const open_file = dashboardItem(ed, "Open file") orelse return error.NoItem;
    _ = try ed.session.system.semantic.focusView(ed.head, gpa, ed.toolView().?, open_file);
    ed.press("Return", "");
    try t.expect(ed.pick.active);
}

test "e2e/panels: only a FILE's edits are unsaved work — a scratch or a REPL closes; quit names what it would lose, and quit-force quits" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // An entry with no file behind it — a REPL's transcript, a command's
    // output — has never been saved, and that is no reason to refuse closing.
    const out = try ed.buffers.create(gpa, "*output*");
    try ed.buffers.switchTo(gpa, out, ed.head, ed.keymap);
    try ed.buffers.active().textEditor().?.doc.insert(gpa, 0, "transcript\n");
    ed.run("buffer.close-unmodified");
    try t.expect(ed.buffers.get(out) == null);

    // A file's unsaved edits refuse the close, and the quit.
    try ide.openFile(ed, "a.txt", "alpha\n");
    ed.typeText("x");
    try t.expect(try ed.buffers.active().hasUnsavedFile(gpa));
    const a = ed.buffers.active_id;
    ed.run("buffer.close-unmodified");
    try t.expect(ed.buffers.get(a) != null);
    ed.run("app.quit");
    try t.expect(!ed.session.system.quit);
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "a.txt") != null);
    ed.run("app.quit-force");
    try t.expect(ed.session.system.quit);
}
