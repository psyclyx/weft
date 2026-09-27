//! e2e test file — the adaptive toolbar and the context menu under
//! config/ide.js (doc/configs.md §3.6.2-3).
//!
//! Both are presentations of ONE projection (doc/model.md §2.4), and neither
//! is a plugin that owns a viewport: the toolbar is a config viewport
//! presenting `weft://here/offers/primary` as a strip of action nodes, the
//! menu is mouse-3 presenting `offers/at-pointer` as a head-local
//! interaction. These gates were the toolbar and contextmenu plugins'; they
//! hold unchanged for the projection that replaced them — what it has to mean
//! to a person clicking:
//!
//!   • the strip is one text row along the top from the first frame, and its
//!     buttons are exactly the pinned entries plus what the editor offers,
//!     grouped and ordered by the offers' own presentation;
//!   • it ADAPTS — a Zig file, a files listing and a git status buffer in the
//!     primary pane each give their own exact set, with no toolbar code
//!     naming any of them;
//!   • a click acts on the editor and leaves the keys there; a greyed button
//!     says why when clicked; the strip redraws only when the offers move;
//!   • mouse-3 lists what is under the pointer — text and a sidebar row give
//!     different menus — runs the chosen entry, closes on Escape and on a
//!     click elsewhere, and S-F10 opens one at the caret.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");

const core = h.core;
const semantic_model = h.semantic_model;
const view_runtime = h.view_runtime;
const window_layout = h.window_layout;
const Editor = h.Editor;
const IdeApp = ide.IdeApp;
const Node = semantic_model.scene.Node;
const NodeId = semantic_model.scene.NodeId;

// ── Reading the strip ────────────────────────────────────────────────

/// The pane a declared viewport is docked in, by the name its fragment
/// declares it under (two strips share the top edge: the menubar and the
/// toolbar).
pub fn viewportPane(ed: *Editor, name: []const u8) !*window_layout.Node {
    const registry = ed.ctx.viewports orelse return error.NoViewports;
    const decl = registry.find(name) orelse return error.NoSuchViewport;
    const id = decl.pane orelse return error.ViewportNotDocked;
    return ed.win_layout.paneById(id) orelse error.ViewportNotDocked;
}

fn toolbarPane(ed: *Editor) !*window_layout.Node {
    return viewportPane(ed, "toolbar");
}

/// The toolbar's retained view, read where the host keeps it: the entry the
/// top dock shows, and the view its saved focus names.
fn toolbarView(ed: *Editor) !*const view_runtime.view.Instance {
    const pane = try toolbarPane(ed);
    const entry = ed.buffers.get(pane.pane().buffer_id) orelse return error.NoToolbarEntry;
    const ref = entry.scene_selection.view orelse return error.ToolbarNotPresented;
    return ed.ctx.semantic.?.views.get(ref) orelse error.ToolbarViewGone;
}

fn fact(node: *const Node, name: []const u8) ?[]const u8 {
    for (node.facts) |f| if (std.mem.eql(u8, f.name, name)) return f.value;
    return null;
}

/// Buttons as a person reads them: labels left to right, `|` where a
/// separator falls, a `~` on each greyed one.
fn strip(buf: []u8, view: *const view_runtime.view.Instance) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const children = switch (view.scene.content) {
        .container => |c| c.children,
        else => return "",
    };
    for (children, 0..) |*child, i| {
        if (i > 0) w.writeAll(" ") catch {};
        switch (child.content) {
            .action => |a| {
                w.writeAll(a.label) catch {};
                if (fact(child, "reason") != null) w.writeAll("~") catch {};
            },
            else => w.writeAll("|") catch {},
        }
    }
    return w.buffered();
}

fn button(view: *const view_runtime.view.Instance, label: []const u8) ?*const Node {
    const children = switch (view.scene.content) {
        .container => |c| c.children,
        else => return null,
    };
    for (children) |*child| switch (child.content) {
        .action => |a| if (std.mem.eql(u8, a.label, label)) return child,
        else => {},
    };
    return null;
}

fn expectStrip(ed: *Editor, want: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const got = strip(&buf, try toolbarView(ed));
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("[e2e/chrome] toolbar: '{s}', expected '{s}'\n", .{ got, want });
        return error.TestUnexpectedToolbar;
    }
}

/// Where a click on scene node `node` lands in pane `pane` of the last frame.
fn pointAtNodeIn(ed: *Editor, pane: u32, node: NodeId) ?[2]f32 {
    const v = ed.ensureView() catch return null;
    for (v.pane_maps[0..v.pane_map_count]) |m| {
        if (m.pane != pane) continue;
        for (m.hits) |hit| if (hit.node == node)
            return .{ hit.rect.x + hit.rect.w / 2, hit.rect.y + hit.rect.h / 2 };
    }
    return null;
}

fn clickButton(ed: *Editor, label: []const u8) !void {
    ed.applyWindow();
    const view = try toolbarView(ed);
    const node = button(view, label) orelse return error.NoSuchButton;
    const at = pointAtNodeIn(ed, (try toolbarPane(ed)).pane().id, node.id) orelse return error.ButtonNotDrawn;
    ed.click(at);
}

fn primaryPane(ed: *Editor) !*window_layout.Node {
    return ed.win_layout.primaryPane() orelse error.NoPrimaryPane;
}

// ── Reading the menu ─────────────────────────────────────────────────

fn menuView(ed: *Editor) ?*const view_runtime.view.Instance {
    const active = ed.head.interactions.active() orelse return null;
    return ed.ctx.semantic.?.views.get(active.descriptor.view);
}

/// The menu's rows (its root panel's `menu-item` action nodes), in order.
pub fn menuItems(out: []*const Node, view: *const view_runtime.view.Instance) []*const Node {
    var n: usize = 0;
    const rows = switch (view.scene.content) {
        .container => |c| c.children,
        else => return out[0..0],
    };
    for (rows) |*row| switch (row.content) {
        .action => if (n < out.len) {
            out[n] = row;
            n += 1;
        },
        else => {},
    };
    return out[0..n];
}

/// A menu panel as a person reads it: labels in order, `|` for a rule, a `~`
/// on each greyed row.
pub fn panelText(buf: []u8, panel: *const Node) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const rows = switch (panel.content) {
        .container => |c| c.children,
        else => return "",
    };
    var first = true;
    for (rows) |*row| {
        switch (row.content) {
            .action => |a| {
                if (!first) w.writeAll(" ") catch {};
                w.writeAll(a.label) catch {};
                if (fact(row, "reason") != null) w.writeAll("~") catch {};
            },
            .label => {
                if (!first) w.writeAll(" ") catch {};
                w.writeAll("|") catch {};
            },
            // An open submenu is its own panel.
            else => continue,
        }
        first = false;
    }
    return w.buffered();
}

fn menuText(buf: []u8, view: *const view_runtime.view.Instance) []const u8 {
    return panelText(buf, &view.scene);
}

fn expectMenu(ed: *Editor, want: []const u8) !void {
    const view = menuView(ed) orelse return error.NoMenu;
    var buf: [1024]u8 = undefined;
    const got = menuText(&buf, view);
    if (!std.mem.eql(u8, want, got)) {
        std.debug.print("[e2e/chrome] menu: '{s}', expected '{s}'\n", .{ got, want });
        return error.TestUnexpectedMenu;
    }
}

/// Walk the menu's highlight to `label` with the keyboard.
fn selectInMenu(ed: *Editor, label: []const u8) !void {
    var items_buf: [64]*const Node = undefined;
    const view = menuView(ed) orelse return error.NoMenu;
    const items = menuItems(&items_buf, view);
    var at: ?usize = null;
    var want: ?usize = null;
    for (items, 0..) |item, i| {
        if (fact(item, "lit") != null) at = i;
        if (std.mem.eql(u8, item.content.action.label, label)) want = i;
    }
    const to = want orelse return error.NoSuchMenuItem;
    // Opened by a click, nothing is lit: the first Down lights the first row.
    const from = at orelse blk: {
        ed.press("Down", "");
        break :blk 0;
    };
    if (to > from) {
        for (0..to - from) |_| ed.press("Down", "");
    } else for (0..from - to) |_| ed.press("Up", "");
}

fn rightClick(ed: *Editor, at: [2]f32) void {
    ed.clickWith(at, 3, .{});
    ed.applyWindow();
}

// ── The toolbar ──────────────────────────────────────────────────────

test "e2e/chrome: the toolbar is one row along the top, the pinned entries plus the editor's offers" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "main.zig", "const x = 1;\n");
    const editor_entry = ed.buffers.active_id;
    ed.applyWindow();

    // Docked at the top — beneath the menubar — as tall as one text row plus
    // the pane margins, no status line of its own, and never where the keys
    // are.
    const pane = try toolbarPane(ed);
    try t.expect(!pane.pane().attrs.takes_focus);
    try t.expect(!pane.pane().attrs.status_line);
    const view = try ed.ensureView();
    const rect = for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == pane.pane().id) break m.rect;
    } else return error.ToolbarNotDrawn;
    try t.expectApproxEqAbs(view.line_h + 2 * h.view.View.pane_margin, rect.y, 0.5);
    try t.expectApproxEqAbs(view.line_h + 2 * h.view.View.pane_margin, rect.h, 0.5);
    try t.expectEqual(@as(f32, @floatFromInt(h.app_w)), rect.w);
    try t.expectEqual(editor_entry, ed.buffers.active_id);
    try t.expectEqual(try primaryPane(ed), window_layout.headFocus(ed.win_layout, ed.head));

    // Pinned first (Save, Undo, Redo, the palette), then what a Zig source
    // offers beyond the grammar's own words: ide.js's build/test/debug for
    // the language, then its editing actions. Nothing to undo yet, so Undo
    // and Redo are there, greyed.
    try expectStrip(ed, "Save Undo~ Redo~ Palette | Build Test Debug | Format Rename");
    const undo = button(try toolbarView(ed), "Undo").?;
    try t.expectEqualStrings("nothing-to-undo", fact(undo, "reason").?);
    try t.expectEqualStrings("muted", fact(undo, "tone").?);
    try t.expectEqualStrings("std.history.undo", fact(undo, "name").?);
    // The winner rides along — what a tooltip would say.
    try t.expectEqualStrings("config", fact(button(try toolbarView(ed), "Build").?, "provider").?);
    // Every button carries its command's icon (doc/chrome.md §1.2) for the
    // styles that draw one: an intention's from the command that answers it
    // here, a pinned command's from itself, an action's from its provider.
    for ([_][2][]const u8{ .{ "Save", "save" }, .{ "Undo", "undo" }, .{ "Palette", "command" }, .{ "Build", "build" }, .{ "Format", "format" } }) |want| {
        const b = button(try toolbarView(ed), want[0]) orelse return error.ButtonMissing;
        try t.expectEqualStrings(want[1], fact(b, "icon") orelse return error.ButtonHasNoIcon);
    }
    app.proj.shot(ed, "chrome-toolbar-zig");
}

fn initRepo(app: *IdeApp) !void {
    for ([_][]const u8{
        "git init -q -b main",
        "git config user.email e2e@weft.test",
        "git config user.name weft-e2e",
        "printf 'one\\n' > f.txt && git add f.txt && git commit -q -m base",
        "printf 'two\\n' >> f.txt",
    }) |cmd| app.proj.gpa.free(try app.proj.oracle(cmd));
}

test "e2e/chrome: the toolbar adapts to the primary context — source, a files listing, git" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try initRepo(&app);

    // A text file that is not Zig: the language-less actions only.
    try ide.openFile(ed, "notes.txt", "hello\n");
    ed.applyWindow();
    try expectStrip(ed, "Save Undo~ Redo~ Palette | Run line | Format Rename");

    // A files listing in the primary pane: the listing's own node actions,
    // and ide.js's rename keyed on the files tool. Its "Edit name" is the
    // standard `std.editing.begin` now (doc/chrome.md §5.2), which the
    // toolbar leaves to Rename. Nothing is drafted yet, so Apply draft is
    // greyed.
    ed.runStr("file.open", ".");
    ed.applyWindow();
    try expectStrip(ed, "Save Undo~ Redo~ Palette | Rename | Delete Paste before | New file New directory Edit permissions | Use as working target | Refresh Apply draft~ Revert draft");
    app.proj.shot(ed, "chrome-toolbar-files");

    // A git status buffer: git's verbs. Nothing durable to save here, so the
    // pinned Save is greyed and says so.
    ed.run("git.status");
    try t.expect(h.drainToolContains(ed, "*git*", "f.txt"));
    ed.applyWindow();
    try expectStrip(ed, "Save~ Undo~ Redo~ Palette | Stage Diff Commit Push Pull Fetch Refresh");
    app.proj.shot(ed, "chrome-toolbar-git");
}

test "e2e/chrome: clicking Undo undoes the editor and leaves it the primary context; a greyed button says why" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.txt", "one\n");
    const editor_entry = ed.buffers.active_id;
    const editor_pane = try primaryPane(ed);
    ed.press("End", "");
    ed.typeText("!");
    ed.applyWindow();
    try expectStrip(ed, "Save Undo Redo~ Palette | Run line | Format Rename");

    // The click lands on the strip and acts on the editor: the edit is
    // gone, the head never left the editor, and it is still the primary.
    try clickButton(ed, "Undo");
    try ide.expectText(ed, "one\n");
    try t.expectEqual(editor_entry, ed.buffers.active_id);
    try t.expectEqual(editor_pane, window_layout.headFocus(ed.win_layout, ed.head));
    try t.expectEqual(editor_pane.pane().id, ed.head.primary_focus.?.pane);
    try t.expectEqualStrings("ide", ed.mode());
    // The strip followed: nothing left to undo, something to redo.
    ed.applyWindow();
    try expectStrip(ed, "Save Undo~ Redo Palette | Run line | Format Rename");

    // Greyed, but not inert: a click says why nothing happened.
    try clickButton(ed, "Undo");
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "nothing-to-undo") != null);
    try ide.expectText(ed, "one\n");
    try clickButton(ed, "Redo");
    try ide.expectText(ed, "one!\n");
    // Typing still goes to the editor: the keys never moved.
    ed.typeText("?");
    try ide.expectText(ed, "one!?\n");
}

test "e2e/chrome: the toolbar redraws when the offers move, and only then" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "b.txt", "alpha\nbeta\n");
    ed.applyWindow();
    ed.applyWindow();
    const settled = (try toolbarView(ed)).descriptor.revision;

    // Quiet wakes and caret moves change nothing it shows: no redraw.
    ed.applyWindow();
    for ([_][]const u8{ "Down", "End", "Up", "C-Right", "Home" }) |k| {
        ed.press(k, "");
        ed.applyWindow();
    }
    try t.expectEqual(settled, (try toolbarView(ed)).descriptor.revision);

    // The first edit makes Undo available: one redraw, however many wakes.
    ed.typeText("x");
    ed.applyWindow();
    ed.applyWindow();
    try t.expectEqual(settled + 1, (try toolbarView(ed)).descriptor.revision);
    // More typing leaves the offers as they were: still one.
    ed.typeText("yz");
    ed.applyWindow();
    try t.expectEqual(settled + 1, (try toolbarView(ed)).descriptor.revision);
}

test "e2e/chrome: Send to REPL is on the strip exactly while a REPL is live, with no toolbar code involved" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.txt", "hello repl\n");
    const source = ed.buffers.active_id;
    ed.applyWindow();
    // ide.js gates the provider on `{context: {"repl.session": "*"}}`, and
    // nothing has published that key: not offered, so not shown.
    try expectStrip(ed, "Save Undo~ Redo~ Palette | Run line | Format Rename");

    // The repl plugin publishes `repl.session` on the place its interpreter
    // runs in. Its own buffer takes the pane; come back to the source.
    ed.runStr("repl.start", "cat");
    ed.runStr("file.open", "a.txt");
    try t.expectEqual(source, ed.buffers.active_id);
    ed.applyWindow();
    try expectStrip(ed, "Save Undo~ Redo~ Palette | Run line Send to REPL | Format Rename");
    try t.expectEqualStrings("config", fact(button(try toolbarView(ed), "Send to REPL").?, "provider").?);

    // The button acts on the editor it describes: the source's line goes to
    // the live interpreter, which echoes it into its own buffer.
    try clickButton(ed, "Send to REPL");
    try t.expect(h.drainToolContains(ed, "*repl*", "hello repl"));
    try t.expectEqual(source, ed.buffers.active_id);

    // Quitting the last REPL retracts the key, and the strip drops the button.
    ed.run("repl.quit");
    ed.applyWindow();
    try expectStrip(ed, "Save Undo~ Redo~ Palette | Run line | Format Rename");
}

// ── The context menu ─────────────────────────────────────────────────

test "e2e/chrome: mouse-3 lists what is under the pointer — text or a sidebar row — and runs the choice" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "c.zig", "const y = 2;\n");
    const editor_entry = ed.buffers.active_id;
    ed.press("End", "");
    ed.typeText(" ");
    ed.applyWindow();

    // Over the text: the editor's offers, and the source actions ide.js
    // provides for Zig. Undo can run, Redo cannot, so only Undo is listed;
    // the lone words join the group before them instead of each sitting
    // between two rules.
    rightClick(ed, ed.pointAt(3).?);
    try expectMenu(ed, "Build Test Debug | Format Rename Undo Save");
    app.proj.shot(ed, "chrome-contextmenu-text");
    // Escape closes it, and the key goes no further.
    ed.press("Escape", "");
    try t.expect(ed.head.interactions.active() == null);
    try ide.expectText(ed, "const y = 2; \n");

    // Choose Undo from the keyboard: the edit is gone.
    rightClick(ed, ed.pointAt(3).?);
    try selectInMenu(ed, "Undo");
    ed.press("Return", "");
    try t.expect(ed.head.interactions.active() == null);
    try ide.expectText(ed, "const y = 2;\n");

    // Over a sidebar row: the listing's offers for THAT row, node actions
    // included — a different menu from the same key. Opened at the sidebar's
    // right edge, it floats over the editor beside it rather than being
    // squeezed into (and clipped by) the narrow pane it opened over.
    const panel = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    const view = try ed.ensureView();
    const sidebar_rect, const row = for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane != panel.pane().id) continue;
        if (m.hits.len == 0) return error.SidebarRowsNotDrawn;
        break .{ m.rect, m.hits[m.hits.len - 1] }; // the listing's last row: c.zig
    } else return error.SidebarNotDrawn;
    const sidebar_right = sidebar_rect.x + sidebar_rect.w;
    rightClick(ed, .{ sidebar_right - 4, row.rect.y + row.rect.h / 2 });
    try t.expectEqual(panel.pane().buffer_id, ed.buffers.active_id);
    // No greyed words (a menu lists what can run here), and no rule around
    // a lone item.
    try expectMenu(ed, "Up to Parent Open | Copy Paste Cut Rename | Insert Before Insert After Edit name Save | Delete Paste before | New file New directory Edit permissions | Refresh Revert draft Use as working target");
    app.proj.shot(ed, "chrome-contextmenu-row");

    // Click Copy — drawn over the editor pane, past the sidebar's edge: the
    // click is the menu's, the row goes to the transfer register, the menu
    // closes.
    try t.expect(ed.ctx.semantic.?.transfer == null);
    var items_buf: [64]*const Node = undefined;
    const items = menuItems(&items_buf, menuView(ed).?);
    const copy = for (items) |item| {
        if (std.mem.eql(u8, item.content.action.label, "Copy")) break item.id;
    } else return error.NoCopy;
    const at = pointAtNodeIn(ed, panel.pane().id, copy) orelse return error.MenuItemNotDrawn;
    try t.expect(at[0] > sidebar_right);
    ed.click(at);
    try t.expect(ed.head.interactions.active() == null);
    try t.expect(ed.ctx.semantic.?.transfer != null);

    // A click anywhere else just closes it.
    rightClick(ed, .{ row.rect.x + 2, row.rect.y + row.rect.h / 2 });
    try t.expect(ed.head.interactions.active() != null);
    ed.click(.{ 5, @as(f32, @floatFromInt(h.app_h)) - 60 });
    try t.expect(ed.head.interactions.active() == null);
    // Nothing was left behind in the editor by any of it.
    try t.expect(ed.buffers.get(editor_entry).?.textEditor().?.selectedRange() == null);
}

test "e2e/chrome: S-F10 opens the menu at the caret, and Escape closes it" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "d.txt", "some text\n");
    ed.applyWindow();
    ed.press("S-F10", "");
    ed.applyWindow();
    try expectMenu(ed, "Run line Format Rename Save");
    ed.press("Escape", "");
    try t.expect(ed.head.interactions.active() == null);
    try t.expectEqualStrings("ide", ed.mode());
}

// ── Per-pane chrome ──────────────────────────────────────────────────

/// What pane `node`'s status line and gutter are asked with — the facts the
/// frame builds each pane's chrome from (`frame_builder.paneFacts`).
fn chromeFacts(ed: *Editor, node: *window_layout.Node) !core.facts.Facts {
    const entry = ed.buffers.get(node.pane().buffer_id) orelse return error.NoEntry;
    return h.app.frame_builder.paneFacts(&ed.application.driver.ctx, entry, node.pane().id);
}

/// Whether pane `node` gets a gutter this frame (ide.js's `linenumbers`).
fn hasGutter(ed: *Editor, node: *window_layout.Node) !bool {
    var arena = std.heap.ArenaAllocator.init(ed.gpa);
    defer arena.deinit();
    const entry = ed.buffers.get(node.pane().buffer_id) orelse return error.NoEntry;
    const gf = try h.app.frame_builder.gutterFrame(arena.allocator(), &ed.application.driver.ctx, &ed.render.fb.answers, node.pane().id, entry, try chromeFacts(ed, node), null, "");
    return gf.bindings.len > 0;
}

test "e2e/chrome: side by side, a text pane and a listing each show their own mode and gutter" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "e.zig", "const e = 1;\n");
    ed.applyWindow();
    const editor = try primaryPane(ed);
    const sidebar = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;

    // The editor has the keys: it says `ide`, the listing beside it says
    // where a listing rests, not the focused pane's mode.
    try t.expectEqualStrings("ide", (try chromeFacts(ed, editor)).mode);
    try t.expectEqualStrings("ide-structural", (try chromeFacts(ed, sidebar)).mode);
    // Line numbers on the text, none on the listing.
    try t.expect(try hasGutter(ed, editor));
    try t.expect(!try hasGutter(ed, sidebar));

    // Move the keys to the listing: each pane still says its own.
    const view = try ed.ensureView();
    const row = for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == sidebar.pane().id and m.hits.len > 0) break m.hits[0];
    } else return error.SidebarNotDrawn;
    ed.click(.{ row.rect.x + 2, row.rect.y + row.rect.h / 2 });
    ed.applyWindow();
    try t.expectEqual(sidebar.pane().buffer_id, ed.buffers.active_id);
    try t.expectEqualStrings("ide-structural", (try chromeFacts(ed, sidebar)).mode);
    try t.expectEqualStrings("ide", (try chromeFacts(ed, editor)).mode);
    try t.expect(try hasGutter(ed, editor));
    try t.expect(!try hasGutter(ed, sidebar));
    app.proj.shot(ed, "chrome-per-pane-mode");
}

test "e2e/chrome: a double click on a toolbar button runs it once" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.txt", "one\n");
    // Two undo units: a motion between the edits seals the first.
    ed.press("End", "");
    ed.typeText("!");
    ed.press("Home", "");
    ed.press("End", "");
    ed.typeText("?");
    try ide.expectText(ed, "one!?\n");

    // The second click of a double click is the same gesture, not a second
    // press of the button: one undo, not two.
    ed.applyWindow();
    const view = try toolbarView(ed);
    const node = button(view, "Undo") orelse return error.NoSuchButton;
    const at = pointAtNodeIn(ed, (try toolbarPane(ed)).pane().id, node.id) orelse return error.ButtonNotDrawn;
    ed.click(at);
    ed.clickAgain(at);
    try ide.expectText(ed, "one!\n");
}
