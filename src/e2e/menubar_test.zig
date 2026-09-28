//! e2e test file — the menubar and its menus (doc/chrome.md §2).
//!
//! The menubar is config: a viewport (config/menubar.js) presenting the main
//! menu, `weft://here/menu/main`, as a row of titles. What it holds is every
//! command that says where it lives; how it looks and behaves is the menu
//! widget's, which the context menu shares. What these gates hold, as a
//! person at ide.js meets it:
//!
//!   • the bar docks above the toolbar, takes no focus, and lists File, Edit,
//!     Selection, View, Go, Run, Terminal, Help;
//!   • a click drops a menu beneath its title — rows in their groups' order
//!     with rules between, each with the key that runs it IN THE EDITOR (ide's
//!     C-s, and under config.js with the fragment, vim's SPC f s), `…` on the
//!     ones that ask for more, a chevron on submenus;
//!   • a row that cannot run is greyed and its tooltip says why; a toggle's
//!     check follows its context key and flips when chosen;
//!   • the keyboard: Alt with a letter, F10, arrows across and into menus,
//!     Enter runs in the primary context without taking the keys, Escape
//!     closes one level;
//!   • the pointer: hovering another title switches menus, a submenu opens
//!     beside its row — on the other side at the window's edge — and a click
//!     anywhere else closes;
//!   • the context menu is the same widget: key hints, icons, rules.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");
const chrome = @import("chrome_test.zig");

const core = h.core;
const view_runtime = h.view_runtime;
const window_layout = h.window_layout;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const IdeApp = ide.IdeApp;
const Node = h.semantic_model.scene.Node;
const Rect = h.region.Rect;

// ── Reading the bar and its menus ───────────────────────────────────

fn fact(node: *const Node, name: []const u8) ?[]const u8 {
    for (node.facts) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

fn barPane(ed: *Editor) !*window_layout.Node {
    return chrome.viewportPane(ed, "menubar");
}

fn barView(ed: *Editor) !*const view_runtime.view.Instance {
    const pane = try barPane(ed);
    const entry = ed.buffers.get(pane.pane().buffer_id) orelse return error.NoMenubarEntry;
    const ref = entry.scene_selection.view orelse return error.MenubarNotPresented;
    return ed.ctx.semantic.?.views.get(ref) orelse error.MenubarViewGone;
}

fn titles(buf: []u8, view: *const view_runtime.view.Instance) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (view.scene.content.container.children, 0..) |*c, i| {
        if (i > 0) w.writeAll(" ") catch {};
        w.writeAll(c.content.action.label) catch {};
        if (fact(c, "lit") != null) w.writeAll("*") catch {};
    }
    return w.buffered();
}

fn title(view: *const view_runtime.view.Instance, label: []const u8) ?*const Node {
    for (view.scene.content.container.children) |*c| if (std.mem.eql(u8, c.content.action.label, label)) return c;
    return null;
}

fn rectOf(ed: *Editor, node: u64) ?Rect {
    const v = ed.ensureView() catch return null;
    for (v.pane_maps[0..v.pane_map_count]) |m| for (m.hits) |hit| {
        if (@intFromEnum(hit.node) == node) return hit.rect;
    };
    return null;
}

fn centre(r: Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

fn clickTitle(ed: *Editor, label: []const u8) !void {
    ed.applyWindow();
    const node = title(try barView(ed), label) orelse return error.NoSuchTitle;
    ed.click(centre(rectOf(ed, @intFromEnum(node.id)) orelse return error.TitleNotDrawn));
    ed.applyWindow();
}

fn dropView(ed: *Editor) ?*const view_runtime.view.Instance {
    const active = ed.head.interactions.active() orelse return null;
    return ed.ctx.semantic.?.views.get(active.descriptor.view);
}

/// The open menu's root panel.
fn menu(ed: *Editor) !*const Node {
    return &(dropView(ed) orelse return error.NoMenu).scene;
}

/// The open submenu of `panel`.
fn submenu(panel: *const Node) ?*const Node {
    for (panel.content.container.children) |*c| if (c.content == .container) return c;
    return null;
}

fn row(panel: *const Node, label: []const u8) ?*const Node {
    for (panel.content.container.children) |*c| switch (c.content) {
        .action => |a| if (std.mem.eql(u8, a.label, label)) return c,
        else => {},
    };
    return null;
}

fn expectPanel(panel: *const Node, want: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const got = chrome.panelText(&buf, panel);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("[e2e/menubar] menu: '{s}', expected '{s}'\n", .{ got, want });
        return error.TestUnexpectedMenu;
    }
}

fn expectKeys(panel: *const Node, label: []const u8, want: ?[]const u8) !void {
    const r = row(panel, label) orelse return error.NoSuchRow;
    const got = fact(r, "keys");
    if (want) |w| {
        if (got == null or !std.mem.eql(u8, w, got.?)) {
            std.debug.print("[e2e/menubar] '{s}' keys: '{?s}', expected '{s}'\n", .{ label, got, w });
            return error.TestUnexpectedKeys;
        }
    } else if (got != null) {
        std.debug.print("[e2e/menubar] '{s}' keys: '{s}', expected none\n", .{ label, got.? });
        return error.TestUnexpectedKeys;
    }
}

fn hoverRow(ed: *Editor, panel: *const Node, label: []const u8) !void {
    const r = row(panel, label) orelse return error.NoSuchRow;
    ed.pointerMove(centre(rectOf(ed, @intFromEnum(r.id)) orelse return error.RowNotDrawn), .{});
    ed.applyWindow();
}

fn clickRow(ed: *Editor, panel: *const Node, label: []const u8) !void {
    const r = row(panel, label) orelse return error.NoSuchRow;
    ed.click(centre(rectOf(ed, @intFromEnum(r.id)) orelse return error.RowNotDrawn));
    ed.applyWindow();
}

fn litLabel(panel: *const Node) ?[]const u8 {
    for (panel.content.container.children) |*c| if (c.content == .action and fact(c, "lit") != null) return c.content.action.label;
    return null;
}

fn shot(app: anytype, name: []const u8) void {
    app.proj.shot(&app.ed, name);
}

// ── The bar ─────────────────────────────────────────────────────────

test "e2e/menubar: the menubar docks above the toolbar, takes no focus, and lists the conventional titles" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "main.zig", "const x = 1;\n");
    const editor = ed.buffers.active_id;
    ed.applyWindow();

    const bar = try barPane(ed);
    const tools = try chrome.viewportPane(ed, "toolbar");
    try t.expect(!bar.pane().attrs.takes_focus and !bar.pane().attrs.status_line and !bar.pane().attrs.cycles);
    const view = try ed.ensureView();
    var bar_rect: ?Rect = null;
    var tool_rect: ?Rect = null;
    for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == bar.pane().id) bar_rect = m.rect;
        if (m.pane == tools.pane().id) tool_rect = m.rect;
    }
    // One text row along the very top, the full width; the toolbar beneath.
    try t.expectEqual(@as(f32, 0), bar_rect.?.y);
    try t.expectApproxEqAbs(view.line_h + 2 * h.view.View.pane_margin, bar_rect.?.h, 0.5);
    try t.expectEqual(@as(f32, @floatFromInt(h.app_w)), bar_rect.?.w);
    try t.expectEqual(bar_rect.?.y + bar_rect.?.h, tool_rect.?.y);
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("File Edit Selection View Go Run Terminal Help", titles(&buf, try barView(ed)));
    try t.expectEqual(editor, ed.buffers.active_id);

    // Hiding the toolbar and showing it again puts it back beneath the bar:
    // a dock's place is its declaration's, not the latest to be shown.
    ed.runStr("viewport.toggle", "toolbar");
    ed.applyWindow();
    ed.runStr("viewport.toggle", "toolbar");
    ed.applyWindow();
    const again = try ed.ensureView();
    for (again.pane_maps[0..again.pane_map_count]) |m| {
        if (m.pane == bar.pane().id) try t.expectEqual(@as(f32, 0), m.rect.y);
        if (m.pane == (try chrome.viewportPane(ed, "toolbar")).pane().id) try t.expect(m.rect.y > 0);
    }
}

test "e2e/menubar: a click drops File beneath its title — rows in order, rules between groups, the editor's keys beside them" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "main.zig", "const x = 1;\n");
    ed.applyWindow();

    try clickTitle(ed, "File");
    const file = try menu(ed);
    // What a conventional File menu holds: no plumbing (remembering a
    // project, saying where its root is), no second row for one act.
    try expectPanel(file, "New File | Open File… Open… Open Recent… Browse Remote Files… | Save Save As… | Close Editor Close Without Saving | Notes | Quit");
    // The key that runs each row in the editor, as ide.js binds it.
    try expectKeys(file, "Save", "C-s");
    try expectKeys(file, "Save As…", "C-S-s");
    try expectKeys(file, "Open File…", "C-p");
    try expectKeys(file, "Close Editor", "C-w");
    try expectKeys(file, "Quit", "C-q");
    try expectKeys(file, "Close Without Saving", null);
    // Its icon, and a chevron on the row that opens a submenu.
    try t.expectEqualStrings("save", fact(row(file, "Save").?, "icon").?);
    try t.expectEqualStrings("on", fact(row(file, "Notes").?, "submenu").?);
    // Anchored below its title, lit on the bar; a click lights no row and
    // shows no underlines (the keyboard's cues).
    try t.expectEqualStrings("File", litLabel(&(try barView(ed)).scene) orelse "");
    try t.expect(litLabel(file) == null);
    try t.expect(fact(row(file, "Save").?, "mnemonic") == null);
    const file_title = rectOf(ed, @intFromEnum(title(try barView(ed), "File").?.id)).?;
    const new_row = rectOf(ed, @intFromEnum(row(file, "New File").?.id)).?;
    try t.expect(new_row.y >= file_title.y + file_title.h);
    try t.expect(new_row.x >= file_title.x and new_row.x < file_title.x + file_title.w);
    // The keys stay with the editor while it is open.
    try t.expectEqualStrings("ide", ed.mode());
    shot(&app, "menubar-file-widget");

    // The same click again closes it.
    try clickTitle(ed, "File");
    try t.expect(ed.head.interactions.active() == null);

    // The same menu in the text style: a clean cell box.
    ed.runStr("theme.set-chrome", "text");
    try clickTitle(ed, "File");
    try expectKeys(try menu(ed), "Save", "C-s");
    shot(&app, "menubar-file-ide-text");

    // Open Recent… is one picker of the files visited, most recent first;
    // choosing one opens it.
    ed.press("Escape", "");
    try ide.openFile(ed, "other.zig", "const o = 2;\n");
    ed.applyWindow();
    try clickTitle(ed, "File");
    try clickRow(ed, try menu(ed), "Open Recent…");
    try t.expect(ed.pick.active);
    ed.typeText("main");
    ed.press("Return", "");
    try t.expect(!ed.pick.active);
    try t.expect(std.mem.endsWith(u8, ed.bufferName(), "main.zig"));
}

/// config.js with the menubar fragment: the vim grammar's editor.
const VimApp = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    fn init(self: *VimApp, gpa: std.mem.Allocator) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        errdefer self.loader.deinit();
        const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{self.proj.prev_cwd});
        defer gpa.free(config_dir);
        const path = try std.fmt.allocPrint(gpa, "{s}/config.js", .{config_dir});
        defer gpa.free(path);
        const base = try core.file.readAlloc(gpa, path);
        defer gpa.free(base);
        // What a person adds to config.js to get the bar: one line.
        const src = try std.fmt.allocPrint(gpa, "{s}\nweft.use(\"menubar\");\n", .{base});
        defer gpa.free(src);
        try core.quickjs.evalConfig(&self.ed.engine, self.ed.ctx, self.loader.loader(), &self.ed.config_kv, config_dir, src);
        try self.ed.buffers.setDefaultMode(gpa, self.ed.head.currentMode());
    }

    fn deinit(self: *VimApp) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

test "e2e/menubar: under config.js with the fragment, the same File menu shows vim's keys" {
    const gpa = t.allocator;
    var app: VimApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try core.file.writeBytes(gpa, "a.txt", "one\n");
    ed.runStr("file.open", "a.txt");
    ed.applyWindow();
    try t.expectEqualStrings("normal", ed.mode());

    try clickTitle(ed, "File");
    const file = try menu(ed);
    // Keys by context: vim's normal mode opens and saves-as through its
    // leader where ide has C-p and C-S-s; C-s, the modeless floor's, saves in
    // both, and is the shortest.
    try expectKeys(file, "Save As…", "SPC f S");
    try expectKeys(file, "Open File…", "SPC SPC");
    try expectKeys(file, "Save", "C-s");
    // Text chrome, the config's style: a clean cell box.
    try t.expectEqual(h.view.chrome.Style.text, (try ed.ensureView()).chrome);
    shot(&app, "menubar-file-text");
    ed.press("Escape", "");
    ed.press("Escape", "");
    try t.expect(ed.head.interactions.active() == null);
    try t.expectEqualStrings("normal", ed.mode());
}

// ── State: disabled and checked ─────────────────────────────────────

test "e2e/menubar: a row that cannot run is greyed and its tooltip says why" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.txt", "one\n");
    ed.applyWindow();

    try clickTitle(ed, "Edit");
    const edit = try menu(ed);
    try t.expectEqualStrings("there is no change to undo", fact(row(edit, "Undo").?, "reason").?);
    try expectKeys(edit, "Undo", "C-z");
    // Clicking it does nothing, and the menu stays.
    try clickRow(ed, edit, "Undo");
    try t.expect(ed.head.interactions.active() != null);

    // Resting on it: once the delay is up, the tooltip names it and why.
    try hoverRow(ed, try menu(ed), "Undo");
    const due = ed.application.hover.dueAt() orelse return error.NoTooltipPending;
    ed.gpa.free(try ed.renderCompositeAt(due));
    const tip = (try ed.ensureView()).frame_tip orelse return error.NoTooltip;
    try t.expectEqualStrings("Undo", tip.tip.label);
    try t.expectEqualStrings("there is no change to undo", tip.tip.reason);
    shot(&app, "menubar-disabled-tooltip");

    // After an edit it can run.
    ed.press("Escape", "");
    ed.press("Escape", "");
    ed.typeText("!");
    try clickTitle(ed, "Edit");
    try t.expect(fact(row(try menu(ed), "Undo").?, "reason") == null);
}

test "e2e/menubar: a toggle's check follows its context key and flips when chosen; a style is one choice of three" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.txt", "one\n");
    ed.applyWindow();

    try clickTitle(ed, "View");
    try t.expectEqualStrings("on", fact(row(try menu(ed), "Sidebar").?, "checked").?);
    try expectKeys(try menu(ed), "Sidebar", "C-b");
    try clickRow(ed, try menu(ed), "Sidebar");
    try t.expect(ed.head.interactions.active() == null);
    try t.expect(ed.win_layout.dockedPanel(.left) == null);
    try clickTitle(ed, "View");
    try t.expect(fact(row(try menu(ed), "Sidebar").?, "checked") == null);
    try clickRow(ed, try menu(ed), "Sidebar");
    try t.expect(ed.win_layout.dockedPanel(.left) != null);

    // View ▸ Appearance ▸ Chrome Style: the style drawn is the dotted one.
    try clickTitle(ed, "View");
    try hoverRow(ed, try menu(ed), "Appearance");
    const appearance = submenu(try menu(ed)) orelse return error.NoSubmenu;
    try t.expectEqualStrings("on", fact(row(appearance, "Menu Bar").?, "checked").?);
    try t.expectEqualStrings("on", fact(row(appearance, "Toolbar").?, "checked").?);
    try hoverRow(ed, appearance, "Chrome Style");
    const styles = submenu(submenu(try menu(ed)).?) orelse return error.NoSubmenu;
    try expectPanel(styles, "Text Text with Icons Widgets");
    try t.expectEqualStrings("on", fact(row(styles, "Widgets").?, "radio").?);
    try t.expectEqualStrings("on", fact(row(styles, "Widgets").?, "checked").?);
    try t.expect(fact(row(styles, "Text").?, "checked") == null);
    shot(&app, "menubar-view-appearance-widget");
    try clickRow(ed, styles, "Text");
    try t.expectEqual(h.view.chrome.Style.text, (try ed.ensureView()).chrome);
    try clickTitle(ed, "View");
    try hoverRow(ed, try menu(ed), "Appearance");
    try hoverRow(ed, submenu(try menu(ed)).?, "Chrome Style");
    const again = submenu(submenu(try menu(ed)).?).?;
    try t.expectEqualStrings("on", fact(row(again, "Text").?, "checked").?);
    try t.expect(fact(row(again, "Widgets").?, "checked") == null);
    shot(&app, "menubar-view-appearance-text");

    // The toolbar toggle, a config row with an argument.
    try clickRow(ed, submenu(try menu(ed)).?, "Toolbar");
    try t.expectError(error.ViewportNotDocked, chrome.viewportPane(ed, "toolbar"));
}

// ── The keyboard ────────────────────────────────────────────────────

test "e2e/menubar: Alt+F opens File from the keys, Enter runs in the primary context, Right moves on, Escape closes one level" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "k.txt", "one\n");
    const editor = ed.buffers.active_id;
    ed.press("End", "");
    ed.typeText("!");
    ed.applyWindow();

    // Put the keys in the sidebar: the menu still acts on the editor.
    const sidebar = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    const first_row = rectOf(ed, @intFromEnum((try sidebarRow(ed, sidebar)).node)).?;
    ed.click(centre(first_row));
    ed.applyWindow();
    try t.expectEqual(sidebar.pane().buffer_id, ed.buffers.active_id);

    ed.press("M-f", "");
    ed.applyWindow();
    const file = try menu(ed);
    try t.expectEqualStrings("File", litLabel(&(try barView(ed)).scene).?);
    try t.expectEqualStrings("New File", litLabel(file).?);
    // Opened from the keys, its letters are underlined.
    try t.expect(fact(row(file, "Save").?, "mnemonic") != null);
    shot(&app, "menubar-file-keyboard");
    // Save's letter chooses it: the EDITOR is saved, not the listing that
    // has the keys, and the keys stay in the listing.
    ed.press("s", "");
    try t.expect(ed.head.interactions.active() == null);
    const disk = try core.file.readAlloc(gpa, "k.txt");
    defer gpa.free(disk);
    try t.expectEqualStrings("one!\n", disk);
    try t.expectEqual(sidebar.pane().buffer_id, ed.buffers.active_id);
    try t.expect(ed.buffers.get(editor) != null);

    // The same by the arrows: Down to Save, Return. An edit made in the
    // editor since is written, still from the sidebar.
    const primary = ed.win_layout.primaryPane() orelse return error.NoPrimaryPane;
    ed.click(ed.pointAtIn(primary.pane().id, 1) orelse return error.EditorNotDrawn);
    ed.applyWindow();
    try t.expectEqual(editor, ed.buffers.active_id);
    ed.press("End", "");
    ed.typeText("?");
    ed.click(centre(first_row));
    ed.applyWindow();
    try t.expectEqual(sidebar.pane().buffer_id, ed.buffers.active_id);
    ed.press("M-f", "");
    for (0..20) |_| {
        if (std.mem.eql(u8, litLabel(try menu(ed)).?, "Save")) break;
        ed.press("Down", "");
    }
    try t.expectEqualStrings("Save", litLabel(try menu(ed)).?);
    ed.press("Return", "");
    try t.expect(ed.head.interactions.active() == null);
    const again = try core.file.readAlloc(gpa, "k.txt");
    defer gpa.free(again);
    try t.expectEqualStrings("one!?\n", again);
    try t.expectEqual(sidebar.pane().buffer_id, ed.buffers.active_id);

    // Arrows: Down walks the rows, Right moves on to Edit, Left back.
    ed.press("M-f", "");
    ed.press("Down", "");
    try t.expectEqualStrings("Open File…", litLabel(try menu(ed)).?);
    ed.press("Right", "");
    try t.expectEqualStrings("Edit", litLabel(&(try barView(ed)).scene).?);
    try t.expectEqualStrings("Undo", litLabel(try menu(ed)).?);
    ed.press("Left", "");
    try t.expectEqualStrings("File", litLabel(&(try barView(ed)).scene).?);
    // The wheel over a menu is the menu's (it scrolls one taller than the
    // frame): it neither closes it nor moves the lit row.
    var lit_buf: [64]u8 = undefined;
    const lit_before = try std.fmt.bufPrint(&lit_buf, "{s}", .{litLabel(try menu(ed)).?});
    ed.press("wheel-down", "");
    try t.expect(ed.head.interactions.active() != null);
    try t.expectEqualStrings("File", litLabel(&(try barView(ed)).scene).?);
    try t.expectEqualStrings(lit_before, litLabel(try menu(ed)).?);
    try t.expectEqualStrings("1", fact(try menu(ed), "scroll").?);
    // Escape closes one level: the menu, then the bar.
    ed.press("Escape", "");
    try t.expect(ed.head.interactions.active() != null);
    try t.expectEqual(@as(usize, 0), (try menu(ed)).content.container.children.len);
    try t.expectEqualStrings("File", litLabel(&(try barView(ed)).scene).?);
    ed.press("Escape", "");
    try t.expect(ed.head.interactions.active() == null);
    try t.expect(litLabel(&(try barView(ed)).scene) == null);

    // F10 — no debugger to step — lights the bar; Down drops the lit menu.
    ed.press("F10", "");
    try t.expect(ed.head.interactions.active() != null);
    try t.expectEqualStrings("File", litLabel(&(try barView(ed)).scene).?);
    ed.press("Right", "");
    ed.press("Down", "");
    try t.expectEqualStrings("Edit", litLabel(&(try barView(ed)).scene).?);
    try t.expectEqualStrings("Undo", litLabel(try menu(ed)).?);
    // Right on a submenu row opens it.
    ed.press("F10", "");
    ed.press("M-v", "");
    ed.press("End", "");
    try t.expectEqualStrings("Editor Layout", litLabel(try menu(ed)).?);
    ed.press("Right", "");
    try t.expect(submenu(try menu(ed)) != null);
    ed.press("Left", "");
    try t.expect(submenu(try menu(ed)) == null);
    ed.press("F10", "");
    try t.expect(ed.head.interactions.active() == null);
}

test "e2e/menubar: a row that asks for an argument runs in the primary context too — Save As… from the sidebar writes the editor" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.txt", "alpha\n");
    const editor = ed.buffers.active_id;
    ed.applyWindow();

    // The keys in the sidebar; File ▸ Save As… asks for the path, then
    // saves the EDITOR there, not the listing that has the keys.
    const sidebar = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    ed.click(centre(rectOf(ed, @intFromEnum((try sidebarRow(ed, sidebar)).node)).?));
    ed.applyWindow();
    try t.expectEqual(sidebar.pane().buffer_id, ed.buffers.active_id);
    ed.press("M-f", "");
    for (0..20) |_| {
        if (std.mem.eql(u8, litLabel(try menu(ed)).?, "Save As…")) break;
        ed.press("Down", "");
    }
    try t.expectEqualStrings("Save As…", litLabel(try menu(ed)).?);
    ed.press("Return", "");
    // The path through the prompt's own line (its typing is its mode's
    // commit, which a listing's type-ahead must not take — a separate gate).
    ed.runStr("menu.arg-type", "b.txt");
    ed.press("Return", "");
    ed.applyWindow();
    const disk = core.file.readAlloc(gpa, "b.txt") catch |err| {
        std.debug.print("[e2e/menubar] Save As… wrote nothing (echo: '{s}')\n", .{ed.head.echo.items});
        return err;
    };
    defer gpa.free(disk);
    try t.expectEqualStrings("alpha\n", disk);
    try t.expect(ed.buffers.get(editor) != null);
    try t.expectEqual(sidebar.pane().buffer_id, ed.buffers.active_id);
}

fn sidebarRow(ed: *Editor, sidebar: *window_layout.Node) !h.view.semantic.Hit {
    const view = try ed.ensureView();
    for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == sidebar.pane().id and m.hits.len > 0) return m.hits[0];
    }
    return error.SidebarNotDrawn;
}

// ── The pointer ─────────────────────────────────────────────────────

test "e2e/menubar: hovering another title switches menus, a submenu opens beside its row and flips at the edge, a click elsewhere closes" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "p.zig", "const p = 1;\n");
    ed.applyWindow();

    try clickTitle(ed, "File");
    const edit_title = title(try barView(ed), "Edit").?;
    ed.pointerMove(centre(rectOf(ed, @intFromEnum(edit_title.id)).?), .{});
    ed.applyWindow();
    try t.expectEqualStrings("Edit", litLabel(&(try barView(ed)).scene).?);
    try t.expect(row(try menu(ed), "Undo") != null);

    // View ▸ Appearance: room on the right, so beside the row, level with it.
    const view_title = title(try barView(ed), "View").?;
    ed.pointerMove(centre(rectOf(ed, @intFromEnum(view_title.id)).?), .{});
    ed.applyWindow();
    try hoverRow(ed, try menu(ed), "Appearance");
    const parent_row = rectOf(ed, @intFromEnum(row(try menu(ed), "Appearance").?.id)).?;
    const sub_row = rectOf(ed, @intFromEnum(row(submenu(try menu(ed)).?, "Menu Bar").?.id)).?;
    try t.expect(sub_row.x >= parent_row.x + parent_row.w);
    try t.expectApproxEqAbs(parent_row.y, sub_row.y, 1);
    shot(&app, "menubar-view-submenu");

    // Run ▸ Agents: the Run menu sits far enough right that its submenu
    // would overflow the window, so it opens on the left.
    const run_title = title(try barView(ed), "Run").?;
    ed.pointerMove(centre(rectOf(ed, @intFromEnum(run_title.id)).?), .{});
    ed.applyWindow();
    try hoverRow(ed, try menu(ed), "Agents");
    const agents_row = rectOf(ed, @intFromEnum(row(try menu(ed), "Agents").?.id)).?;
    const agents = submenu(try menu(ed)) orelse return error.NoSubmenu;
    const first = agents.content.container.children[0];
    const flipped = rectOf(ed, @intFromEnum(first.id)).?;
    try t.expect(flipped.x + flipped.w <= agents_row.x);
    try t.expect(flipped.x >= 0);
    shot(&app, "menubar-run-flipped");

    // A click on the text closes the menu and does nothing else there.
    const before = ide.textEd(ed).cursorOffset();
    ed.click(.{ @as(f32, @floatFromInt(h.app_w)) - 20, @as(f32, @floatFromInt(h.app_h)) - 80 });
    try t.expect(ed.head.interactions.active() == null);
    try t.expectEqual(before, ide.textEd(ed).cursorOffset());
}

// ── The context menu is the same widget ─────────────────────────────

test "e2e/menubar: the context menu is the menu widget — keys, icons, rules, the keyboard's cues" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "c.zig", "const y = 2;\n");
    ed.press("End", "");
    ed.typeText(" ");
    ed.applyWindow();

    ed.clickWith(ed.pointAt(3).?, 3, .{});
    ed.applyWindow();
    const ctx_menu = try menu(ed);
    try t.expect(std.mem.eql(u8, "menu", h.view.menu.leaf(ctx_menu.role)));
    try expectPanel(ctx_menu, "Cut Copy Paste | Build Test Debug | Format Rename Undo Save");
    try expectKeys(ctx_menu, "Cut", "C-x");
    try expectKeys(ctx_menu, "Undo", "C-z");
    try expectKeys(ctx_menu, "Save", "C-s");
    try expectKeys(ctx_menu, "Rename", "F2");
    try t.expectEqualStrings("save", fact(row(ctx_menu, "Save").?, "icon").?);
    try t.expect(litLabel(ctx_menu) == null);
    shot(&app, "menubar-context-widget");
    // Hover lights a row; the keyboard carries on from it.
    try hoverRow(ed, ctx_menu, "Format");
    try t.expectEqualStrings("Format", litLabel(try menu(ed)).?);
    ed.press("Down", "");
    try t.expectEqualStrings("Rename", litLabel(try menu(ed)).?);
    ed.press("Escape", "");
    try t.expect(ed.head.interactions.active() == null);

    // S-F10 at the caret: lit on its first row, underlined, and a letter
    // runs its row — `u`, Undo, takes the space back.
    ed.press("S-F10", "");
    ed.applyWindow();
    try t.expectEqualStrings("Cut", litLabel(try menu(ed)).?);
    try t.expect(fact(row(try menu(ed), "Undo").?, "mnemonic") != null);
    ed.press("u", "");
    try t.expect(ed.head.interactions.active() == null);
    try ide.expectText(ed, "const y = 2;\n");

    // Text chrome: the same menu in a clean cell box.
    ed.runStr("theme.set-chrome", "text");
    ed.clickWith(ed.pointAt(3).?, 3, .{});
    ed.applyWindow();
    shot(&app, "menubar-context-text");
    ed.press("Escape", "");
}
