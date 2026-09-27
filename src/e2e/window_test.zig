//! e2e test file — drives the shared harness (harness.zig) as a user and
//! observes the surface + disk. The alias block pulls what these tests need from
//! the one harness module; unused aliases are harmless at container scope.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const session = h.session;
const region = h.region;
const window_layout = h.window_layout;
const window_cmds = h.window_cmds;
const harness = h.gfx_harness;
const app_providers = h.app.providers;
const app_session = h.app.session;
const app_collab = h.app.collab;

const Editor = h.Editor;
const Loopback = h.Loopback;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const app_w = h.app_w;
const app_h = h.app_h;

const loadVim = h.loadVim;
const loadWorkspace = h.loadWorkspace;
const loadWebIde = h.loadWebIde;
const bootConfig = h.bootConfig;
const whichKeyText = h.whichKeyText;
const whichKeyShows = h.whichKeyShows;
const authorFile = h.authorFile;
const toolText = h.toolText;
const drainToolContains = h.drainToolContains;
const drainUntilOracle = h.drainUntilOracle;
const tmpPath = h.tmpPath;
const socketPair = h.socketPair;
const napUs = h.napUs;

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
    ed.run("window.split-right");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.paneCount());

    // Move focus to the right pane and open a second buffer there — the real
    // "focused pane follows the active buffer" invariant carries it.
    ed.run("window.focus-right");
    ed.applyWindow();
    ed.runStr("buffer.create", "*bravo*");
    ed.applyWindow();
    try t.expectEqualStrings("*bravo*", ed.bufferName());
    ed.press("i", "");
    ed.typeText("BRAVO pane\nright body\n");
    ed.press("Escape", "");

    // The two panes show distinct buffers.
    const frame: region.Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(app_w), .h = @floatFromInt(app_h) };
    var slots: [window_layout.max_panes]window_layout.Slot = undefined;
    const n = ed.win_layout.collect(window_layout.headFocus(ed.win_layout, ed.head), frame, &slots);
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
    ed.run("window.split-right");
    ed.applyWindow();
    ed.run("window.split-below");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 3), ed.paneCount());

    const pixels = try ed.renderComposite();
    defer gpa.free(pixels);
    // Something was drawn somewhere in the frame (all three panes share the
    // root buffer here; the point is the tiling + composite path holds up).
    try t.expect(harness.hasContent(pixels, app_w, 0, 0, app_w, app_h));
    ed.snapshotPanes("tri-pane");
}

// ── GATE: a sidebar is a config fragment ──
//
// doc/cwa-config-decisions.md D1-D3 (and architecture §7/§9.4/§18): "a docked
// sidebar showing project files is a config fragment plus the generic tree
// presentation — expressible with zero interposing behavior, everything
// visible to explain()". The fragment (`config/sidebar.js`) declares four
// viewport ATTRIBUTES and one `present`; nothing else in this file is
// sidebar-aware, and no code anywhere names "sidebar" as a kind.
//
// What each primitive has to do for this to work: the pane tree docks a leaf
// and refuses to restructure it (D1); the layout phase routes the
// activation's open by POLICY rather than by whoever opened it (D3); and the
// primary context never moves on this viewport's focus, so nothing
// follows it (D2).

/// The current name field in the focused semantic entry.
fn focusedRowName(ed: *Editor, gpa: std.mem.Allocator) !?[]u8 {
    if (ed.head.scene_selection.path() == null) return null;
    return try ed.draftHere(gpa);
}

/// Press `j` until the row under point is `want`. Navigation is the std
/// intention `std.navigation.down` (vim binds `j` to it, with a text motion as
/// the fallback arm) — no files-specific key anywhere, which is the property
/// the listing keeps by declaring a POSTURE rather than a mode.
fn navigateToRow(ed: *Editor, gpa: std.mem.Allocator, want: []const u8) !void {
    for (0..64) |_| {
        if (try focusedRowName(ed, gpa)) |name| {
            defer gpa.free(name);
            if (std.mem.eql(u8, name, want)) return;
        }
        ed.press("j", "");
    }
    return error.RowNeverFocused;
}

test "e2e/sidebar: a config fragment docks a files sidebar, and Return opens in the primary pane" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try core.file.writeBytes(gpa, "alpha.txt", "ALPHA CONTENT\n");
    try core.file.writeBytes(gpa, "bravo.txt", "BRAVO CONTENT\n");

    // Import the fragment through the ordinary import verb, evaluated sealed
    // like any other config. Nothing here is a test-only door.
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{app.proj.prev_cwd});
    defer gpa.free(config_dir);
    const editor_entry = ed.buffers.active_id;
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, null, &ed.config_kv, config_dir, "weft.use(\"sidebar\");");

    // The layout phase realizes declared viewports — an ordinary application
    // wake, not a harness-selectable operation.
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.paneCount());
    const panel = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    const primary = ed.win_layout.primaryPane() orelse return error.NoPrimaryPane;
    try t.expect(panel != primary);

    // The declared attributes are what the workspace enforces — read them off
    // the live pane, not off the fragment.
    try t.expect(!panel.pane().attrs.cycles);
    try t.expect(panel.pane().attrs.persistent);
    try t.expect(!panel.pane().attrs.focus_source);
    try t.expectEqual(@as(?core.viewport.Edge, .left), panel.pane().attrs.dock);

    // Presenting the subject stole neither the editor pane nor the focus.
    const browser = panel.pane().buffer_id;
    try t.expect(browser != editor_entry);
    try t.expectEqual(editor_entry, primary.pane().buffer_id);
    try t.expectEqual(editor_entry, ed.buffers.active_id);

    // Focus the sidebar deliberately (directional focus reaches it; cycling
    // never would) — the active entry follows the pane, so its rows are what
    // keys act on.
    ed.run("window.focus-left");
    ed.applyWindow();
    try t.expectEqual(browser, ed.buffers.active_id);

    // j/k navigate the tree through std intentions. Row order is the
    // directory's, not this test's business, so the walk is stated relative
    // to wherever the focus starts.
    const first_row = (try focusedRowName(ed, gpa)) orelse return error.RowNeverFocused;
    defer gpa.free(first_row);
    ed.press("j", "");
    {
        const next = (try focusedRowName(ed, gpa)) orelse return error.RowNeverFocused;
        defer gpa.free(next);
        try t.expect(!std.mem.eql(u8, next, first_row)); // j moved
    }
    ed.press("k", "");
    {
        const back = (try focusedRowName(ed, gpa)) orelse return error.RowNeverFocused;
        defer gpa.free(back);
        try t.expectEqualStrings(first_row, back); // and k moved back
    }
    try navigateToRow(ed, gpa, "alpha.txt");

    // Return activates the row. The file opens through the same `open` a
    // picker runs; WHERE it lands is the placement policy's answer, and from
    // a companion viewport that answer is the primary pane.
    ed.press("Return", "");
    ed.applyWindow();
    try t.expectEqual(@as(usize, 2), ed.paneCount());

    const opened = primary.pane().buffer_id;
    try t.expect(opened != editor_entry);
    const text = try ed.buffers.get(opened).?.textEditor().?.text().toOwnedSlice(gpa);
    defer gpa.free(text);
    try t.expectEqualStrings("ALPHA CONTENT\n", text);

    // The sidebar kept its root AND its focus discipline: same entry, still
    // focused, still on the row it was on. This is the whole gate — without a
    // placement policy the open lands in the FOCUSED pane, which is the
    // sidebar.
    try t.expectEqual(browser, panel.pane().buffer_id);
    try t.expectEqual(browser, ed.buffers.active_id);
    try t.expectEqual(panel, window_layout.headFocus(ed.win_layout, ed.head));
    {
        const still = (try focusedRowName(ed, gpa)) orelse return error.RowNeverFocused;
        defer gpa.free(still);
        try t.expectEqualStrings("alpha.txt", still);
    }

    // And the companion's own focus is not a primary-focus change: the head's
    // primary focus still names the editor pane, and that record is the only
    // thing the primary context — all a follower hears — reads focus from.
    try t.expectEqual(primary.pane().id, ed.head.primary_focus.?.pane);
    ed.run("window.focus-right");
    ed.applyWindow();
    try t.expectEqual(primary, window_layout.headFocus(ed.win_layout, ed.head));
    const pixels = try ed.renderComposite();
    defer gpa.free(pixels);
    try t.expect(!(try ed.ensureView()).semantic_active);
    app.proj.shot(ed, "files-sidebar");
}

// ── GATE: following is a consumer of two primitives, not a DSL ──
//
// doc/cwa-config-decisions.md D2, as revisited by doc/model.md §2.5: "one
// observable context, plus viewport retarget as a protocol op, plus a
// CONSUMER doing the following". `Outline` below is that consumer written out
// in full — a listener on the primary context's one event plus one call to
// the retarget op (`window_cmds.presentIn`). It is short enough to live in a
// config file, which is the point: no reactive binding grammar was needed.
//
// The bug this kills structurally is the outline retargeting to ITSELF (and
// to any other companion). There is no filter for a follower to forget: the
// primary context reads focus only from `Head.primary_focus`, which a
// companion taking focus never moves, so the event does not fire at all.

const Outline = struct {
    ed: *Editor,
    subject: []const u8,
    viewport: u32 = 0,
    /// Every delivery heard, and the ones that moved `entry` (a retarget).
    heard: usize = 0,
    retargets: usize = 0,

    fn follow(self: *Outline, viewport: u32) !void {
        self.viewport = viewport;
        try self.ed.session.system.context.subscribe(.{ .context = self, .notify = onContext });
    }

    fn onContext(raw: ?*anyopaque, keys: []const []const u8) void {
        const self: *Outline = @ptrCast(@alignCast(raw.?));
        self.heard += 1;
        for (keys) |k| {
            if (std.mem.eql(u8, k, "entry")) break;
        } else return;
        self.retargets += 1;
        window_cmds.presentIn(
            self.ed.ctx,
            self.ed.win_layout,
            self.ed.buffers,
            self.ed.gpa,
            self.ed.head,
            self.ed.keymap,
            self.viewport,
            self.subject,
        );
    }
};

test "e2e/sidebar: a companion follows primary focus and never its own" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try core.file.writeBytesMakingDirs(gpa, "sub", "sub/inner.txt", "INNER\n");
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{app.proj.prev_cwd});
    defer gpa.free(config_dir);
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, null, &ed.config_kv, config_dir, "weft.use(\"sidebar\");");
    ed.applyWindow();
    const panel = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;

    var outline: Outline = .{ .ed = ed, .subject = "sub" };
    try outline.follow(panel.pane().id);
    defer ed.session.system.context.unsubscribe(&outline);
    const root_listing = panel.pane().buffer_id;

    // Split the editor pane and open another file in the right half: ordinary
    // panes are focus sources, so the entry the primary context names moves,
    // and the companion retargets on it.
    ed.run("window.split-right");
    ed.applyWindow();
    ed.run("window.focus-right");
    ed.runStr("file.open", "sub/inner.txt");
    ed.applyWindow();
    try t.expect(outline.retargets > 0);
    const followed = outline.retargets;
    // The retarget op actually presented: the panel shows `sub`, not the root
    // listing it was materialized with, and the acting head never left the
    // pane it was in.
    try t.expect(panel.pane().buffer_id != root_listing);
    try t.expectEqual(ed.buffers.active_id, window_layout.headFocus(ed.win_layout, ed.head).pane().buffer_id);

    // Back to the left half — another ordinary pane on another entry, so
    // another retarget.
    ed.run("window.focus-left");
    ed.applyWindow();
    try t.expect(outline.retargets > followed);
    const before_companion = outline.retargets;
    const heard = outline.heard;

    // A caret move in text moves no key: nothing is delivered at all.
    ed.press("End", "");
    ed.applyWindow();
    try t.expectEqual(heard, outline.heard);

    // Now focus the COMPANION itself. That is not a primary-focus change, so
    // no key of the primary context moved and the follower is never even
    // told — it cannot chase its own subject.
    ed.run("window.focus-left");
    ed.applyWindow();
    try t.expectEqual(panel, window_layout.headFocus(ed.win_layout, ed.head));
    try t.expectEqual(before_companion, outline.retargets);
    try t.expectEqual(heard, outline.heard);
}

// A semantic entry occupies a viewport without allocating a text document.
test "e2e/files: the listing is an ordinary buffer, navigable by key" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    try core.file.writeBytes(gpa, "alpha.txt", "ALPHA\n");
    try core.file.writeBytes(gpa, "bravo.txt", "BRAVO\n");
    try core.file.writeBytesMakingDirs(gpa, "nested", "nested/inner.txt", "INNER\n");

    try ed.grantRooted("files", "fs_read", "/");
    ed.runStr("file.open", ".");
    try t.expect(std.mem.startsWith(u8, ed.bufferName(), "files:"));

    // The scene renders the provider-owned entries.
    {
        const text = try ed.semanticText(ed.toolView().?);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "alpha.txt") != null);
        try t.expect(std.mem.indexOf(u8, text, "bravo.txt") != null);
        try t.expect(std.mem.indexOf(u8, text, "nested") != null);
    }

    // Descending is by the row's KEY, never by reading the rendered line back:
    // point lands on the first focusable row, and `nested` is reachable from it
    // with ordinary cursor motion.
    const browser_id = ed.buffers.active_id;
    try t.expect(ed.buffers.active().editor == null);
    try ed.focusFilesName("nested");
    ed.press("Return", "");
    try t.expectEqual(browser_id, ed.buffers.active_id);
    {
        const text = try ed.semanticText(ed.toolView().?);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "inner.txt") != null);
        try t.expect(std.mem.startsWith(u8, ed.bufferName(), "files:"));
    }

    // And back up, through the grammar.s own `minus` → `std.hierarchy.step-out`,
    // which follows the CONTAINER relation the listing.s producer publishes.
    ed.press("minus", "");
    {
        const text = try ed.semanticText(ed.toolView().?);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "alpha.txt") != null);
    }
}

test "e2e/files: directory navigation retains drafts and cursors in one object entry" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try core.file.writeBytes(gpa, "alpha.txt", "alpha\n");
    try core.file.writeBytesMakingDirs(gpa, "child", "child/inner.txt", "inner\n");
    ed.runStr("file.open", ".");
    const browser = ed.buffers.active_id;
    const count = ed.buffers.count();
    const root_view = ed.toolView().?;
    try t.expect(ed.buffers.active().editor == null);
    try t.expect(ed.buffers.active().projection == null);
    try ed.focusFilesName("alpha.txt");
    ed.press("i", "");
    ed.typeText("draft-");
    ed.press("Escape", "");
    try ed.focusFilesName("child");
    const parent_cursor = ed.subjectHere().?;
    ed.press("Return", "");
    try t.expectEqual(browser, ed.buffers.active_id);
    try t.expectEqual(count, ed.buffers.count());
    const child_view = ed.toolView().?;
    try t.expect(!root_view.eql(child_view));
    try ed.focusFilesName("inner.txt");
    ed.press("i", "");
    ed.typeText("kept-");
    ed.press("Escape", "");
    ed.press("minus", "");
    try t.expectEqual(browser, ed.buffers.active_id);
    try t.expectEqual(root_view, ed.toolView().?);
    try t.expectEqual(parent_cursor, ed.subjectHere().?);
    {
        const text = try ed.semanticText(root_view);
        defer gpa.free(text);
        try t.expect(std.mem.indexOf(u8, text, "draft-alpha.txt") != null);
    }
    ed.press("Return", "");
    try t.expectEqual(child_view, ed.toolView().?);
    const draft = try ed.draftHere(gpa);
    defer gpa.free(draft);
    try t.expectEqualStrings("kept-inner.txt", draft);
    try t.expectEqual(browser, ed.buffers.active_id);
    try t.expectEqual(count, ed.buffers.count());
    // Navigation is not apply: the provider's files still have their old names.
    try t.expectEqual(core.file.Kind.file, core.file.statKind(gpa, "alpha.txt"));
    try t.expectEqual(core.file.Kind.file, core.file.statKind(gpa, "child/inner.txt"));
    app.proj.shot(ed, "files-object-navigation");
}

test "e2e/files: semantic rows scroll beyond one screen without a text document" {
    const gpa = t.allocator;
    var app: h.App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    for (0..80) |i| {
        const name = try std.fmt.allocPrint(gpa, "entry-{d:0>3}.txt", .{i});
        defer gpa.free(name);
        try core.file.writeBytes(gpa, name, "contents\n");
    }
    ed.runStr("file.open", ".");
    const view_ref = ed.toolView().?;
    const instance = ed.session.system.semantic.views.get(view_ref).?;
    try t.expectEqual(@as(usize, 80), instance.focus_order.len);
    const first = instance.focus_order[0];
    const last = instance.focus_order[79];
    _ = try ed.session.system.semantic.focusView(ed.head, gpa, view_ref, first);
    for (0..79) |_| ed.press("j", "");
    try t.expectEqual(last, ed.subjectHere().?);
    const pixels = try ed.renderComposite();
    defer gpa.free(pixels);
    const presenter = try ed.ensureView();
    try t.expect(presenter.top_row > 0);
    try t.expect(ed.buffers.active().editor == null);
    app.proj.shot(ed, "files-scrolled");
    for (0..79) |_| ed.press("k", "");
    const back = try ed.renderComposite();
    defer gpa.free(back);
    try t.expectEqual(first, ed.subjectHere().?);
    try t.expectEqual(@as(usize, 0), presenter.top_row);
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "no text in this view") == null);
}
