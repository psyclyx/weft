//! e2e test file — how chrome looks, and that it is the user's to switch
//! (doc/chrome.md §3).
//!
//!   • ide.js draws `widget` chrome; config.js draws `text`; both are one
//!     theme value, and `theme.set-chrome` / `theme.cycle-chrome` switch the
//!     very next frame, with no restart and no config edit;
//!   • hover is frame INPUT: moving onto a button lights it without a single
//!     dispatch, moving within it costs no frame at all, and its tooltip
//!     appears only once the pointer has rested past the delay — a deadline
//!     the loop's timer owns, never a sleep.
//!
//! Screenshots land beside the other e2e shots (`.zig-cache/tmp/weft-e2e-*`).

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");

const core = h.core;
const view_runtime = h.view_runtime;
const window_layout = h.window_layout;
const semantic_model = h.semantic_model;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;
const IdeApp = ide.IdeApp;
const Style = h.view.chrome.Style;
const Rect = h.region.Rect;
const frame_builder = h.app.frame_builder;

fn toolbarButton(ed: *Editor, label: []const u8) !Rect {
    const pane = try @import("chrome_test.zig").viewportPane(ed, "toolbar");
    const entry = ed.buffers.get(pane.pane().buffer_id) orelse return error.NoToolbarEntry;
    const ref = entry.scene_selection.view orelse return error.ToolbarNotPresented;
    const view = ed.ctx.semantic.?.views.get(ref) orelse return error.ToolbarViewGone;
    const children = switch (view.scene.content) {
        .container => |c| c.children,
        else => return error.NoButtons,
    };
    const node = for (children) |*child| switch (child.content) {
        .action => |a| if (std.mem.eql(u8, a.label, label)) break child,
        else => {},
    } else return error.NoSuchButton;
    const v = try ed.ensureView();
    for (v.pane_maps[0..v.pane_map_count]) |m| {
        if (m.pane != pane.pane().id) continue;
        for (m.hits) |hit| if (hit.node == node.id) return hit.rect;
    }
    return error.ButtonNotDrawn;
}

/// Whether two frames differ anywhere inside `r`.
fn differsIn(a: []const u8, b: []const u8, r: Rect) bool {
    const x0: usize = @intFromFloat(@max(0, r.x));
    const y0: usize = @intFromFloat(@max(0, r.y));
    const x1: usize = @min(h.app_w, @as(usize, @intFromFloat(r.x + r.w)));
    const y1: usize = @min(h.app_h, @as(usize, @intFromFloat(r.y + r.h)));
    for (y0..y1) |y| {
        const from = (y * h.app_w + x0) * 4;
        const to = (y * h.app_w + x1) * 4;
        if (!std.mem.eql(u8, a[from..to], b[from..to])) return true;
    }
    return false;
}

fn motion(ed: *Editor, at: [2]f32) !void {
    try ed.application.pointer(.{ .kind = .motion, .x = at[0], .y = at[1] });
}

test "e2e/chrome-style: hover lights a toolbar button as frame input, dispatching nothing, and its tooltip waits for the delay" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "main.zig", "const x = 1;\n");
    ed.applyWindow();

    const resting = try ed.renderComposite();
    defer gpa.free(resting);
    try t.expectEqual(Style.widget, (try ed.ensureView()).chrome);
    app.proj.shot(ed, "chrome-style-ide-widget");

    const save = try toolbarButton(ed, "Save");
    const at: [2]f32 = .{ save.x + save.w / 2, save.y + save.h / 2 };

    // Onto the button: the frame is due, and nothing was dispatched — no
    // input edge, no gesture, only where the pointer is.
    ed.application.view_dirty = false;
    try motion(ed, at);
    try t.expect(ed.application.view_dirty);
    try t.expect(!ed.application.lifecycle.input_pending);
    try t.expectEqual(core.pointer.Kind.hover, ed.head.pointer.kind);

    // Within the same button: the same target, so no frame at all.
    ed.application.view_dirty = false;
    try motion(ed, .{ at[0] + 2, at[1] + 1 });
    try t.expect(!ed.application.view_dirty);

    // The lit frame differs from the resting one where the button is, and
    // only because of hover: the tooltip is not due yet.
    const lit = try ed.renderComposite();
    defer gpa.free(lit);
    try t.expect(differsIn(resting, lit, save));
    try t.expect(!ed.application.hover.ripe);

    // The tooltip is a deadline the loop's timer source reports; a wake
    // before it shows nothing new, the wake at it shows the tooltip below
    // the pointer.
    const due = ed.application.hover.dueAt() orelse return error.NoTooltipPending;
    const early = try ed.renderCompositeAt(due - 1);
    defer gpa.free(early);
    try t.expect(!ed.application.hover.ripe);
    const tipped = try ed.renderCompositeAt(due);
    defer gpa.free(tipped);
    try t.expect(ed.application.hover.ripe);
    try t.expect(ed.application.hover.dueAt() == null); // nothing more to wake for
    const view = try ed.ensureView();
    const below: Rect = .{ .x = at[0], .y = at[1] + view.line_h, .w = 6 * view.cell_w, .h = view.line_h };
    try t.expect(!differsIn(lit, early, below));
    try t.expect(differsIn(lit, tipped, below));
    app.proj.shot(ed, "chrome-style-ide-widget-hover-tooltip");

    // Moving off starts over: a new target, a new delay, no tooltip.
    ed.application.view_dirty = false;
    try motion(ed, .{ at[0], at[1] + 200 });
    try t.expect(ed.application.view_dirty);
    try t.expect(!ed.application.hover.ripe);
}

test "e2e/chrome-style: frame-purity — building a frame with a tooltip, a message and a flash showing changes nothing — no plane sync, no timing, the same draw lists twice" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "main.zig", "const x = 1;\n");
    ed.applyWindow();
    ed.gpa.free(try ed.renderComposite());

    // The tooltip over Save is showing, its key found when the pointer
    // settled; a message has just been said.
    const save = try toolbarButton(ed, "Save");
    try motion(ed, .{ save.x + save.w / 2, save.y + save.h / 2 });
    ed.gpa.free(try ed.renderComposite());
    const due = ed.application.hover.dueAt() orelse return error.NoTooltipPending;
    ed.gpa.free(try ed.renderCompositeAt(due));
    try t.expect(ed.application.hover.ripe);
    try t.expectEqualStrings("C-s", ed.application.hover.hint.keys());
    ed.runStr("app.echo", "a passing remark");
    // …and an operation has just flashed what it touched (vim-goggles).
    try ed.ctx.caps.flash.set(gpa, &ed.ctx.caps.layers, ed.ctx.document().?, .{ .start = 0, .end = 5 }, .edit);
    ed.gpa.free(try ed.renderCompositeAt(due + 1));

    const fb = &ed.render.fb;
    const fx = &ed.application.driver.ctx;
    const prepared = try ed.application.prepare();
    const act: h.app.frame.Active = .{
        .editor = prepared.editor,
        .abuf = prepared.buffer,
        .attach = prepared.attach,
        .frame_start = due + 2,
        .fb = .{ h.app_w, h.app_h },
        .blink_on = true,
        .menu_shown = false,
    };
    const syncs = ed.ctx.intent.?.syncs;
    const timing = ed.application.echo_timing;
    const flash = ed.application.flash_timing;
    try t.expect(flash.showing);
    ed.application.view_dirty = false;

    var drawn: [2][]h.scene.DrawItem = undefined;
    for (&drawn) |*list| {
        var input: frame_builder.FrameInput = .init(gpa);
        defer input.deinit();
        try fb.capture(fx, act, &input);
        var tops: [16]usize = undefined;
        try fb.draw(&input, tops[0..input.panes.items.len]);
        var all: std.ArrayList(h.scene.DrawItem) = .empty;
        for (fb.built_panes.items) |pane| try all.appendSlice(gpa, pane.items);
        list.* = try all.toOwnedSlice(gpa);
    }
    defer for (drawn) |list| gpa.free(list);

    // Building read the plane, the hover and the message's timing; it wrote
    // none of them, and asked for no other frame.
    try t.expectEqual(syncs, ed.ctx.intent.?.syncs);
    try t.expectEqual(timing, ed.application.echo_timing);
    try t.expectEqual(flash, ed.application.flash_timing);
    try t.expect(!ed.application.view_dirty);
    try t.expectEqualDeep(drawn[0], drawn[1]);
}

test "e2e/chrome-style: config.js draws widget chrome, and theme.set-chrome switches the next frame live" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    _ = try proj.oracle("printf 'const a = 1;\\n' > alpha.zig; printf 'bravo\\n' > bravo.txt");

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    var loader: ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    try h.bootConfig(&ed, config_dir, &loader);
    ed.runStr("file.open", "alpha.zig");
    ed.runStr("file.open", "bravo.txt");

    const booted = try ed.renderComposite();
    defer gpa.free(booted);
    const view = try ed.ensureView();
    try t.expectEqual(Style.widget, view.chrome);
    proj.shot(&ed, "chrome-style-config-booted");
    // Two documents (and whatever the config opened): a tab strip, whose
    // tabs are chrome.
    var entries: [4]u32 = undefined;
    try t.expect(ed.tabEntries(&entries).len >= 2);

    // One command, and the next frame is in the new style.
    ed.runStr("theme.set-chrome", "text");
    const text = try ed.renderComposite();
    defer gpa.free(text);
    try t.expectEqual(Style.text, view.chrome);
    try t.expect(!std.mem.eql(u8, booted, text));
    proj.shot(&ed, "chrome-style-config-text");

    ed.runStr("theme.set-chrome", "text-icons");
    const icons = try ed.renderComposite();
    defer gpa.free(icons);
    try t.expectEqual(Style.text_icons, view.chrome);
    try t.expect(!std.mem.eql(u8, text, icons));
    proj.shot(&ed, "chrome-style-config-text-icons");

    ed.run("theme.cycle-chrome");
    const widget = try ed.renderComposite();
    defer gpa.free(widget);
    try t.expectEqual(Style.widget, view.chrome);
    try t.expect(!std.mem.eql(u8, icons, widget));
    proj.shot(&ed, "chrome-style-config-widget");

    // A misspelt style changes nothing; the cycle comes round to text.
    ed.runStr("theme.set-chrome", "widgets");
    gpa.free(try ed.renderComposite());
    try t.expectEqual(Style.widget, view.chrome);
    ed.run("theme.cycle-chrome");
    const again = try ed.renderComposite();
    defer gpa.free(again);
    try t.expectEqual(Style.text, view.chrome);
    // Back where it started: the tab strip is the first frame's again.
    const tab_row: Rect = .{ .x = 0, .y = 0, .w = @floatFromInt(h.app_w), .h = view.line_h + 2 * h.view.View.pane_margin };
    try t.expect(!differsIn(text, again, tab_row));
}

/// What `pane` drew in the last frame: its rect and its hits.
fn paneMap(ed: *Editor, pane: *window_layout.Node) !h.view.View.PaneMap {
    const v = try ed.ensureView();
    for (v.pane_maps[0..v.pane_map_count]) |m| if (m.pane == pane.pane().id) return m;
    return error.PaneNotDrawn;
}

/// The hit of the node labeled `label` in the active tool's view.
fn toolHit(ed: *Editor, label: []const u8) !h.view.semantic.Hit {
    const ref = ed.toolView() orelse return error.NoTool;
    const instance = ed.session.system.semantic.views.get(ref) orelse return error.ToolViewGone;
    const id = for (instance.focus_order) |id| {
        const node = instance.node(id) orelse continue;
        if (node.content == .action and std.mem.eql(u8, node.content.action.label, label)) break id;
    } else return error.NoSuchItem;
    const v = try ed.ensureView();
    for (v.pane_maps[0..v.pane_map_count]) |m| for (m.hits) |hit| {
        if (hit.node == id and hit.view.eql(ref)) return hit;
    };
    return error.ItemNotDrawn;
}

/// Hovering the far end of `row` — past its text — lights the whole row:
/// the frame changes at both ends of it.
fn rowLightsOnHover(ed: *Editor, row: Rect) !void {
    const gpa = t.allocator;
    const v = try ed.ensureView();
    const resting = try ed.renderComposite();
    defer gpa.free(resting);
    try motion(ed, .{ row.x + row.w - 2, row.y + row.h / 2 });
    const lit = try ed.renderComposite();
    defer gpa.free(lit);
    try t.expect(differsIn(resting, lit, .{ .x = row.x, .y = row.y, .w = v.cell_w, .h = row.h }));
    try t.expect(differsIn(resting, lit, .{ .x = row.x + row.w - v.cell_w, .y = row.y, .w = v.cell_w, .h = row.h }));
}

test "e2e/chrome-style: config.js — a listing's rows and the dashboard's items answer the pointer alike: a list's rows, not buttons; buttons have room; menubar titles abut" {
    const gpa = t.allocator;
    var proj: Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    _ = try proj.oracle("mkdir -p sub; printf 'a\\n' > alpha.txt; printf 'b\\n' > bravo.txt");

    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    var loader: ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    try h.bootConfig(&ed, config_dir, &loader);
    ed.run("dashboard.open");
    ed.applyWindow();
    gpa.free(try ed.renderComposite());
    const v = try ed.ensureView();
    try t.expectEqual(Style.widget, v.chrome);
    proj.shot(&ed, "chrome-style-lists-resting");

    // A dashboard item is a row: a click anywhere on it reaches it, and the
    // pointer anywhere on it lights all of it — no button face.
    const item = try toolHit(&ed, "New buffer");
    try t.expect(item.rect.w > 20 * v.cell_w);
    try t.expectEqual(v.line_h, item.rect.h);
    try rowLightsOnHover(&ed, item.rect);
    proj.shot(&ed, "chrome-style-lists-dashboard-hover");

    // A listing's row, the same.
    const sidebar = try @import("chrome_test.zig").viewportPane(&ed, "sidebar");
    const rows = (try paneMap(&ed, sidebar)).hits;
    try t.expect(rows.len >= 3);
    const row = rows[2].rect;
    try t.expect(row.w > 20 * v.cell_w);
    try rowLightsOnHover(&ed, row);
    proj.shot(&ed, "chrome-style-lists-sidebar-hover");

    // The chrome's text is smaller than the editor's (`theme/ui-scale`).
    try t.expect(v.ui().em < v.em);
    // A button's face, and what a click reaches, is taller than its label's
    // line; the toolbar still holds it.
    const palette = try toolbarButton(&ed, "Palette");
    const toolbar = (try paneMap(&ed, try @import("chrome_test.zig").viewportPane(&ed, "toolbar"))).rect;
    try t.expect(palette.h > v.ui().line_h + 2);
    try t.expect(palette.y >= toolbar.y and palette.y + palette.h <= toolbar.y + toolbar.h);
    // Its face lights to the edge of that taller region.
    const before = try ed.renderComposite();
    defer gpa.free(before);
    try motion(&ed, .{ palette.x + palette.w / 2, palette.y + palette.h / 2 });
    const lit = try ed.renderComposite();
    defer gpa.free(lit);
    try t.expect(differsIn(before, lit, .{ .x = palette.x + palette.w / 2, .y = palette.y, .w = 1, .h = 2 }));
    proj.shot(&ed, "chrome-style-lists-button-hover");

    // Menubar titles abut, each the bar's full height, as a desktop's do —
    // and the bar is as tall as a line of the chrome's text, and its margins.
    const titles = (try paneMap(&ed, try @import("chrome_test.zig").viewportPane(&ed, "menubar"))).hits;
    try t.expect(titles.len >= 3);
    for (titles[0 .. titles.len - 1], titles[1..]) |a, b| {
        try t.expectApproxEqAbs(a.rect.x + a.rect.w, b.rect.x, 0.5);
        try t.expectEqual(v.ui().line_h + 2 * v.barMargin(), a.rect.h);
    }
    try motion(&ed, .{ titles[1].rect.x + 2, titles[1].rect.y + 2 });
    proj.shot(&ed, "chrome-style-lists-menubar-hover");
    ed.click(.{ titles[1].rect.x + 2, titles[1].rect.y + 2 });
    proj.shot(&ed, "chrome-style-lists-menubar-open");
}
