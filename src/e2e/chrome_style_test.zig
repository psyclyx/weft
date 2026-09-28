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

test "e2e/chrome-style: frame-purity — building a frame with a tooltip and a message showing changes nothing — no plane sync, no timing, the same draw lists twice" {
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
    try t.expect(!ed.application.view_dirty);
    try t.expectEqualDeep(drawn[0], drawn[1]);
}

test "e2e/chrome-style: config.js draws text chrome, and theme.set-chrome switches the next frame live" {
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

    const text = try ed.renderComposite();
    defer gpa.free(text);
    const view = try ed.ensureView();
    try t.expectEqual(Style.text, view.chrome);
    proj.shot(&ed, "chrome-style-config-text");
    // Two documents (and whatever the config opened): a tab strip, whose
    // tabs are chrome.
    var entries: [4]u32 = undefined;
    try t.expect(ed.tabEntries(&entries).len >= 2);

    // One command, and the next frame is in the new style.
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
