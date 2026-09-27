//! e2e test file — opening files from a `files` listing, under each shipped
//! config (config.js, helix.js, ide.js), by key and by pointer, in the main
//! pane and in the docked sidebar.
//!
//! The regression these hold: a file row opened only when its directory was
//! one the app session itself had opened. A listing reaches every deeper
//! directory by publishing that directory's target itself — Return on a
//! directory row, or a folded-open row in the tree — and the session's
//! placement policy (`Session.openWorkspaceEntry`) had no path for those, so
//! activating any file below the listing's root refused with
//! `NoTargetHandler` and nothing opened. Every gesture here therefore opens a
//! file at the root AND below it.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const window_layout = h.window_layout;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;

/// A weft booted from one of the real configs, in a throwaway project holding
///
///   alpha.txt, sub/inner.txt, sub/deeper/deep.txt
///
/// and, like a no-file launch of the app, showing the dashboard.
const ConfigApp = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    fn init(self: *ConfigApp, gpa: std.mem.Allocator, config: []const u8) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        errdefer self.loader.deinit();
        try core.file.writeBytes(gpa, "alpha.txt", "ALPHA\n");
        try core.file.writeBytesMakingDirs(gpa, "sub", "sub/inner.txt", "INNER\n");
        try core.file.writeBytesMakingDirs(gpa, "sub/deeper", "sub/deeper/deep.txt", "DEEP\n");
        const config_dir = try self.configDir(gpa);
        defer gpa.free(config_dir);
        try h.bootConfigNamed(&self.ed, config_dir, config, &self.loader);
        // Mirror main.zig: the grammar's resting mode is where fresh buffers
        // open, and a no-file launch shows the dashboard.
        try self.ed.buffers.setDefaultMode(gpa, self.ed.head.currentMode());
        self.ed.run("dashboard");
        self.ed.applyWindow();
    }

    fn configDir(self: *ConfigApp, gpa: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/config", .{self.proj.prev_cwd});
    }

    /// Dock the sidebar fragment, as config.js and helix.js document.
    fn useSidebar(self: *ConfigApp) !void {
        const config_dir = try self.configDir(self.ed.gpa);
        defer self.ed.gpa.free(config_dir);
        try core.quickjs.evalConfig(&self.ed.engine, self.ed.ctx, null, &self.ed.config_kv, config_dir, "weft.use(\"sidebar\");");
        self.ed.applyWindow();
    }

    fn deinit(self: *ConfigApp) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

/// A grammar's keys for the next and previous row, and for the containing
/// directory — ide.js binds none (its "Up to Parent" is a menu item, which runs
/// the command).
const Keys = struct { down: []const u8, up: []const u8, step_out: ?[]const u8 };
const vim_keys: Keys = .{ .down = "j", .up = "k", .step_out = "minus" };
const ide_keys: Keys = .{ .down = "Down", .up = "Up", .step_out = null };

/// Whether the focused row of the focused listing is named `want`.
fn onRow(ed: *Editor, want: []const u8) bool {
    if (ed.head.scene_selection.field == null) return false;
    const name = ed.draftHere(ed.gpa) catch return false;
    defer ed.gpa.free(name);
    return std.mem.eql(u8, name, want);
}

/// Step through the rows until the focused one is `want`: down from where
/// the focus is, then back up.
fn goToRow(ed: *Editor, keys: Keys, want: []const u8) !void {
    for ([_][]const u8{ keys.down, keys.up }) |key| {
        for (0..16) |_| {
            if (onRow(ed, want)) return;
            ed.press(key, "");
        }
    }
    if (onRow(ed, want)) return;
    return error.RowNeverFocused;
}

/// The text the primary (editing) pane shows.
fn expectPrimaryText(ed: *Editor, want: []const u8) !void {
    ed.applyWindow();
    const primary = ed.win_layout.primaryPane() orelse return error.NoPrimaryPane;
    const entry = ed.buffers.get(primary.pane().buffer_id) orelse return error.NoEntry;
    const text_editor = entry.textEditor() orelse {
        std.debug.print("[e2e/files] the primary pane shows '{s}', not a file; echo: '{s}'\n", .{ entry.name, ed.echoText() });
        return error.PrimaryShowsNoFile;
    };
    const text = try text_editor.text().toOwnedSlice(ed.gpa);
    defer ed.gpa.free(text);
    try t.expectEqualStrings(want, text);
}

/// How the listing gets the keys back before each open: the docked sidebar
/// by directional focus, a main-pane listing by switching back to its entry
/// (an open from the main pane replaced it there).
const Listing = union(enum) {
    sidebar,
    entry: core.Buffers.Id,

    fn focus(self: Listing, ed: *Editor) void {
        switch (self) {
            .sidebar => ed.run("window-focus-left"),
            .entry => |id| ed.buffers.switchTo(ed.gpa, id, ed.head, ed.keymap) catch {},
        }
        ed.applyWindow();
    }

    /// The listing entry that is active now, found again after it navigated.
    fn here(ed: *Editor) Listing {
        return .{ .entry = ed.buffers.active_id };
    }
};

/// Open alpha.txt at the listing's root, descend two levels and open
/// deep.txt, then step back out and open inner.txt — every one through the
/// config's own keys.
fn keyboardWalk(ed: *Editor, keys: Keys, listing: Listing) !void {
    listing.focus(ed);
    try goToRow(ed, keys, "alpha.txt");
    ed.press("Return", "");
    try expectPrimaryText(ed, "ALPHA\n");

    listing.focus(ed);
    try goToRow(ed, keys, "sub");
    ed.press("Return", ""); // descend
    try goToRow(ed, keys, "deeper");
    ed.press("Return", ""); // and again
    const deeper: Listing = if (listing == .sidebar) .sidebar else .here(ed);
    try goToRow(ed, keys, "deep.txt");
    ed.press("Return", "");
    try expectPrimaryText(ed, "DEEP\n");

    deeper.focus(ed);
    // Back up to sub/.
    if (keys.step_out) |key| ed.press(key, "") else ed.run("hierarchy-step-out");
    try goToRow(ed, keys, "inner.txt");
    ed.press("Return", "");
    try expectPrimaryText(ed, "INNER\n");
}

test "e2e/files: config.js — Return opens a file from the listing, at its root and below it" {
    var app: ConfigApp = undefined;
    try app.init(t.allocator, "config.js");
    defer app.deinit();
    app.ed.chord("SPC f d");
    app.ed.applyWindow();
    try keyboardWalk(&app.ed, vim_keys, .here(&app.ed));
}

test "e2e/files: helix.js — Return opens a file from the listing, at its root and below it" {
    var app: ConfigApp = undefined;
    try app.init(t.allocator, "helix.js");
    defer app.deinit();
    app.ed.run("files");
    app.ed.applyWindow();
    try keyboardWalk(&app.ed, vim_keys, .here(&app.ed));
}

test "e2e/files: ide.js — Return opens a file from a listing in the main pane, at its root and below it" {
    var app: ConfigApp = undefined;
    try app.init(t.allocator, "ide.js");
    defer app.deinit();
    // The sidebar shows `.` already; a listing in the main pane is an ordinary
    // `open` of a directory.
    app.ed.runStr("open", "sub");
    app.ed.applyWindow();
    const ed = &app.ed;
    const listing: Listing = .here(ed);
    try goToRow(ed, ide_keys, "inner.txt");
    ed.press("Return", "");
    try expectPrimaryText(ed, "INNER\n");
    listing.focus(ed);
    try goToRow(ed, ide_keys, "deeper");
    ed.press("Return", "");
    try goToRow(ed, ide_keys, "deep.txt");
    ed.press("Return", "");
    try expectPrimaryText(ed, "DEEP\n");
}

test "e2e/sidebar: ide.js's docked sidebar opens files in the primary pane, at its root and below it" {
    var app: ConfigApp = undefined;
    try app.init(t.allocator, "ide.js");
    defer app.deinit();
    const ed = &app.ed;
    const panel = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    try keyboardWalk(ed, ide_keys, .sidebar);
    // Every open landed in the editor; the sidebar kept its pane and focus.
    try t.expectEqual(panel, window_layout.headFocus(ed.win_layout, ed.head));
    try t.expectEqual(panel.pane().buffer_id, ed.buffers.active_id);
}

test "e2e/sidebar: config.js and helix.js dock the sidebar fragment, and it opens files below its root" {
    for ([_][]const u8{ "config.js", "helix.js" }) |config| {
        var app: ConfigApp = undefined;
        try app.init(t.allocator, config);
        defer app.deinit();
        try app.useSidebar();
        try keyboardWalk(&app.ed, vim_keys, .sidebar);
    }
}

test "e2e/sidebar: a file under a folded-open directory opens from the tree" {
    var app: ConfigApp = undefined;
    try app.init(t.allocator, "ide.js");
    defer app.deinit();
    const ed = &app.ed;
    Listing.focus(.sidebar, ed);
    try goToRow(ed, ide_keys, "sub");
    ed.press("Tab", ""); // unfold in place: the row's children join the tree
    try goToRow(ed, ide_keys, "inner.txt");
    ed.press("Return", "");
    try expectPrimaryText(ed, "INNER\n");
}

/// Click each drawn row of `pane` until the focused row is `want`; the point
/// clicked, for a second click there.
fn clickRow(ed: *Editor, pane: *window_layout.Node, want: []const u8) ![2]f32 {
    var index: usize = 0;
    while (true) : (index += 1) {
        ed.applyWindow();
        const view = try ed.ensureView();
        const map = for (view.pane_maps[0..view.pane_map_count]) |m| {
            if (m.pane == pane.pane().id) break m;
        } else return error.PaneNotDrawn;
        if (index >= map.hits.len) return error.RowNotDrawn;
        const hit = map.hits[index];
        const at: [2]f32 = .{ hit.rect.x + hit.rect.w / 2, hit.rect.y + hit.rect.h / 2 };
        ed.click(at);
        if (onRow(ed, want)) return at;
    }
}

test "e2e/sidebar: ide.js — a double click opens a sidebar row: a file in the primary pane, a directory in place" {
    var app: ConfigApp = undefined;
    try app.init(t.allocator, "ide.js");
    defer app.deinit();
    const ed = &app.ed;
    const panel = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;

    // A single click focuses the row (clicking through to the sidebar); the
    // second click of the same gesture opens it.
    var at = try clickRow(ed, panel, "alpha.txt");
    try t.expectEqual(panel, window_layout.headFocus(ed.win_layout, ed.head));
    ed.clickAgain(at);
    try expectPrimaryText(ed, "ALPHA\n");

    // A directory row descends, and a file below the root opens too.
    at = try clickRow(ed, panel, "sub");
    ed.clickAgain(at);
    at = try clickRow(ed, panel, "inner.txt");
    ed.clickAgain(at);
    try expectPrimaryText(ed, "INNER\n");
    try t.expectEqual(panel, window_layout.headFocus(ed.win_layout, ed.head));
}

/// How many rows of the focused listing are flagged for removal.
fn rowsFlaggedDeleted(ed: *Editor) usize {
    const instance = ed.session.system.semantic.views.get(ed.toolView() orelse return 0) orelse return 0;
    var n: usize = 0;
    for (instance.scene.content.container.children) |row| for (row.facts) |fact| {
        if (std.mem.eql(u8, fact.name, "change") and std.mem.eql(u8, fact.value, "delete")) n += 1;
    };
    return n;
}

test "e2e/files: config.js — V j d over rows removes every row of the range, and nothing past it" {
    const gpa = t.allocator;
    var app: ConfigApp = undefined;
    try app.init(gpa, "config.js");
    defer app.deinit();
    const ed = &app.ed;
    try core.file.writeBytes(gpa, "beta.txt", "BETA\n");
    try core.file.writeBytes(gpa, "gamma.txt", "GAMMA\n");
    ed.run("files");
    ed.applyWindow();
    try goToRow(ed, vim_keys, "alpha.txt");

    // `V` anchors a range of rows at the focused one; `j` grows it.
    ed.press("V", "");
    ed.press("j", "");
    const range = ed.head.scene_selection.primaryRows().?;
    try t.expect(range.anchor != range.head);
    // `d` hands the view the range as one request: both rows go.
    ed.press("d", "");
    try t.expectEqual(@as(usize, 2), rowsFlaggedDeleted(ed));
    // …and the range is spent: one row again, back in the resting mode.
    try t.expect(ed.head.scene_selection.anchor == null);
    try t.expect(std.mem.indexOf(u8, ed.mode(), "visual") == null);
}

/// The primary row's place in the focused listing's focus order.
fn primaryRowIndex(ed: *Editor) !u64 {
    const set = try core.selection.read(ed.ctx, ed.gpa);
    defer ed.gpa.free(set.extents);
    return set.extents[set.primary].head;
}

test "e2e/files: config.js — `yy` over two marked rows copies both, as one transfer, and `p` lands both" {
    const gpa = t.allocator;
    var app: ConfigApp = undefined;
    try app.init(gpa, "config.js");
    defer app.deinit();
    const ed = &app.ed;
    try core.file.writeBytes(gpa, "beta.txt", "BETA\n");
    try core.file.writeBytes(gpa, "gamma.txt", "GAMMA\n");
    ed.run("files");
    ed.applyWindow();
    try goToRow(ed, vim_keys, "alpha.txt");
    const alpha = try primaryRowIndex(ed);
    try goToRow(ed, vim_keys, "gamma.txt");
    const gamma = try primaryRowIndex(ed);
    // Two rows marked, two extents — what a C-click gives a vim user too.
    try t.expect(try core.selection.write(ed.ctx, gpa, &.{
        .{ .kind = .rows, .anchor = alpha, .head = alpha },
        .{ .kind = .rows, .anchor = gamma, .head = gamma },
    }, 1));
    try t.expectEqual(@as(usize, 2), ed.head.scene_selection.extentCount());

    // `yy` is a transfer over rows: ONE copy of the set. Mapped per row,
    // each run replaced the one captured value and a paste landed one row.
    ed.press("y", "");
    ed.press("y", "");
    try t.expect(try core.selection.write(ed.ctx, gpa, &.{.{ .kind = .rows, .anchor = alpha, .head = alpha }}, 0));
    ed.press("p", "");
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("alpha.txt gamma.txt", try @import("ide_test.zig").rowsChanged(ed, "copy", &buf));
}
