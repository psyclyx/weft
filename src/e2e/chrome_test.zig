//! e2e test file — the adaptive toolbar and the context menu under
//! config/ide.js (doc/configs.md §3.6.2-3).
//!
//! Both are plugins over doors the action system already had: the toolbar is
//! the PRIMARY context's offers as a docked strip of action nodes, the menu
//! the offers of the context under the pointer as a head-local interaction.
//! These gates hold what that has to mean to a person clicking:
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

fn toolbarPane(ed: *Editor) !*window_layout.Node {
    return ed.win_layout.dockedPanel(.top) orelse error.NoToolbar;
}

/// The toolbar's retained view, read where the host keeps it: the entry the
/// top dock shows, and the view its saved focus names.
fn toolbarView(ed: *Editor) !*const view_runtime.view.Instance {
    const pane = try toolbarPane(ed);
    const entry = ed.buffers.get(pane.pane().buffer_id) orelse return error.NoToolbarEntry;
    const ref = entry.semantic_focus.view orelse return error.ToolbarNotPresented;
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

/// The menu's entries (each row's action node), in order.
fn menuItems(out: []*const Node, view: *const view_runtime.view.Instance) []*const Node {
    var n: usize = 0;
    const rows = switch (view.scene.content) {
        .container => |c| c.children,
        else => return out[0..0],
    };
    for (rows) |*row| switch (row.content) {
        .container => |c| if (c.children.len > 0 and n < out.len) {
            out[n] = &c.children[0];
            n += 1;
        },
        else => {},
    };
    return out[0..n];
}

fn menuText(buf: []u8, view: *const view_runtime.view.Instance) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    const rows = switch (view.scene.content) {
        .container => |c| c.children,
        else => return "",
    };
    for (rows, 0..) |*row, i| {
        if (i > 0) w.writeAll(" ") catch {};
        switch (row.content) {
            .container => |c| {
                const item = &c.children[0];
                w.writeAll(item.content.action.label) catch {};
                if (fact(item, "tone") != null) w.writeAll("~") catch {};
            },
            else => w.writeAll("|") catch {},
        }
    }
    return w.buffered();
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
        if (item.focusable) at = i;
        if (std.mem.eql(u8, item.content.action.label, label)) want = i;
    }
    const from = at orelse return error.NoHighlight;
    const to = want orelse return error.NoSuchMenuItem;
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

    // Docked at the top, as tall as one text row plus the pane margins —
    // no status line of its own — and never where the keys are.
    const pane = try toolbarPane(ed);
    try t.expect(!pane.pane().attrs.takes_focus);
    try t.expect(!pane.pane().attrs.status_line);
    const view = try ed.ensureView();
    const rect = for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == pane.pane().id) break m.rect;
    } else return error.ToolbarNotDrawn;
    try t.expectEqual(@as(f32, 0), rect.y);
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
    // and ide.js's rename keyed on the files tool.
    ed.runStr("open", ".");
    ed.applyWindow();
    try expectStrip(ed, "Save Undo~ Redo~ Palette | Rename | Edit name | Delete Paste before | New file New directory Edit permissions | Use as working target | Refresh Apply draft Revert draft");
    app.proj.shot(ed, "chrome-toolbar-files");

    // A git status buffer: git's verbs. Nothing durable to save here, so the
    // pinned Save is greyed and says so.
    ed.run("git-status");
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

    // Over the text: the editor's offers, the history words included, and
    // the source actions ide.js provides for Zig.
    rightClick(ed, ed.pointAt(3).?);
    try expectMenu(ed, "Build Test Debug | Format Rename | Undo Redo~ | Save");
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
    // included — a different menu from the same key.
    const panel = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    const view = try ed.ensureView();
    const row = for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane != panel.pane().id) continue;
        if (m.hits.len == 0) return error.SidebarRowsNotDrawn;
        break m.hits[m.hits.len - 1]; // the listing's last row: c.zig
    } else return error.SidebarNotDrawn;
    rightClick(ed, .{ row.rect.x + 2, row.rect.y + row.rect.h / 2 });
    try t.expectEqual(panel.pane().buffer_id, ed.buffers.active_id);
    try expectMenu(ed, "Up to Parent | Open | Copy Paste Cut | Rename | Insert Before Insert After | Undo~ Redo~ | Save | Edit name | Delete Paste before | New file New directory Edit permissions | Refresh Apply draft Revert draft | Use as working target");
    app.proj.shot(ed, "chrome-contextmenu-row");

    // Click Copy: the row goes to the transfer register, the menu closes.
    try t.expect(ed.ctx.semantic.?.transfer == null);
    var items_buf: [64]*const Node = undefined;
    const items = menuItems(&items_buf, menuView(ed).?);
    const copy = for (items) |item| {
        if (std.mem.eql(u8, item.content.action.label, "Copy")) break item.id;
    } else return error.NoCopy;
    const at = pointAtNodeIn(ed, panel.pane().id, copy) orelse return error.MenuItemNotDrawn;
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
    try expectMenu(ed, "Run line | Format Rename | Undo~ Redo~ | Save");
    ed.press("Escape", "");
    try t.expect(ed.head.interactions.active() == null);
    try t.expectEqualStrings("ide", ed.mode());
}
