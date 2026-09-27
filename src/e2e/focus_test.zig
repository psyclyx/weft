//! e2e test file — focus in structural views (doc/chrome.md §5). A grammar
//! declares how it focuses a row that holds a field, and nothing else knows:
//!
//!   • ide.js (`row`): a click focuses the ROW — a highlight, no caret, the
//!     `structural` posture; printable keys jump by type-ahead; F2 or a slow
//!     second click begins an edit of the name, with a bar caret; activating
//!     it commits (the listing's own apply), Escape puts the name back; a
//!     double click opens. The status listing and the problems list — a text
//!     projection and a scene of action rows — show their focus the same way.
//!   • config.js and helix.js (`text`): a click edits the name, as it always
//!     did — a block caret, since their resting mode inserts nothing.
//!
//! The caret is read off the frame the renderer built: a rect in the theme's
//! cursor colour is a caret, and its width says bar or block.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");

const core = h.core;
const Editor = h.Editor;
const IdeApp = ide.IdeApp;

/// Build one frame inside the caret's visible blink phase — the input just
/// handled switched it on until the lifecycle's next blink deadline — so a
/// caret this frame could draw IS drawn, and "no caret" means none.
fn frame(ed: *Editor) !void {
    const deadline = ed.application.blinkDeadline().*;
    const at = if (deadline > 0) deadline - 1 else core.task.nowNs();
    const pixels = try ed.renderCompositeAt(at);
    ed.gpa.free(pixels);
}

/// The carets the last frame drew, across every pane.
fn carets(ed: *Editor, out: []h.scene.RectItem) ![]h.scene.RectItem {
    const v = try ed.ensureView();
    var n: usize = 0;
    for (ed.render.fb.built_panes.items) |pane| for (pane.items) |item| switch (item) {
        .rect => |r| if (std.meta.eql(r.color, v.theme.cursor) and n < out.len) {
            out[n] = r;
            n += 1;
        },
        else => {},
    };
    return out[0..n];
}

/// Whether the last frame washed a row as FOCUSED — the wash a scene's
/// focused row and a text projection's focused row both wear.
fn rowWashed(ed: *Editor) !bool {
    const v = try ed.ensureView();
    var wash = v.theme.background;
    for (0..3) |i| wash[i] = wash[i] * 0.8 + v.theme.selection[i] * 0.2;
    for (ed.render.fb.built_panes.items) |pane| for (pane.items) |item| switch (item) {
        .rect => |r| if (std.meta.eql(r.color, wash)) return true,
        else => {},
    };
    return false;
}

fn expectNoCaret(ed: *Editor) !void {
    try frame(ed);
    var buf: [8]h.scene.RectItem = undefined;
    try t.expectEqual(@as(usize, 0), (try carets(ed, &buf)).len);
    try t.expect(try rowWashed(ed));
}

/// The one caret drawn, which must be a bar (`bar`) or a cell-wide block.
fn expectCaret(ed: *Editor, shape: enum { bar, block }) !void {
    try frame(ed);
    var buf: [8]h.scene.RectItem = undefined;
    const drawn = try carets(ed, &buf);
    try t.expectEqual(@as(usize, 1), drawn.len);
    switch (shape) {
        .bar => try t.expectEqual(@as(f32, 2), drawn[0].w),
        .block => try t.expect(drawn[0].w > 2),
    }
}

/// The name node of the files row for `name` in the focused listing.
fn nameNode(ed: *Editor, name: []const u8) !h.semantic_model.scene.NodeId {
    const view_ref = ed.toolView() orelse return error.NoFilesView;
    const instance = ed.session.system.semantic.views.get(view_ref) orelse return error.StaleView;
    for (instance.scene.content.container.children) |row| {
        for (row.content.container.children) |node| {
            if (!std.mem.eql(u8, node.role, "files.name") or node.content != .field) continue;
            var snap = try ed.session.system.semantic.fields.get(node.content.field.ref).?.snapshot(ed.gpa);
            defer snap.deinit();
            if (std.mem.eql(u8, snap.value.bytes, name)) return node.id;
        }
    }
    return error.FilesNameNotFound;
}

fn pointAtName(ed: *Editor, name: []const u8) ![2]f32 {
    return ed.pointAtNode(try nameNode(ed, name)) orelse error.RowNotDrawn;
}

/// The name on the focused row (the name being edited, while one is).
fn expectRow(ed: *Editor, want: []const u8) !void {
    const name = try ed.draftHere(ed.gpa);
    defer ed.gpa.free(name);
    try t.expectEqualStrings(want, name);
}

/// Whether a buffer holds the project file `name`.
fn fileOpen(ed: *Editor, name: []const u8) bool {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = core.file.processDirectory(&cwd_buf) orelse return false;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ cwd, name }) catch return false;
    return ed.buffers.findByPath(path) != null;
}

/// ide.js with `m.txt`, `main.zig` and `zeta.txt` in the project, `zeta.txt`
/// open, and the keys in the docked files sidebar.
fn sidebarApp(app: *IdeApp) !void {
    try app.init(t.allocator);
    errdefer app.deinit();
    const ed = &app.ed;
    for ([_][]const u8{ "m.txt", "main.zig" }) |name| try core.file.writeBytes(ed.gpa, name, "x\n");
    try ide.openFile(ed, "zeta.txt", "zeta\n");
    ed.run("window.focus-left");
    ed.applyWindow();
    try t.expectEqualStrings("ide-structural", ed.mode());
}

test "e2e/focus: ide.js — a click focuses the sidebar ROW, typing jumps, F2 edits with a bar, and Return renames on disk" {
    var app: IdeApp = undefined;
    try sidebarApp(&app);
    defer app.deinit();
    const ed = &app.ed;

    // A click focuses the row: a highlight, no caret, and no field is being
    // edited — the posture is structural, not field.
    ed.click(try pointAtName(ed, "m.txt"));
    ed.applyWindow();
    try expectRow(ed, "m.txt");
    try t.expectEqual(core.input.Posture.structural, ed.ctx.posture());
    try t.expect(ed.head.scene_selection.field == null);
    try expectNoCaret(ed);
    app.proj.shot(ed, "focus-row-clicked");

    // Printable keys are type-ahead, not text: `m` stays on the first m-row,
    // `a` narrows the prefix to `ma` and moves to main.zig.
    ed.typeText("ma");
    try expectRow(ed, "main.zig");
    try expectNoCaret(ed);
    // A pause ends the prefix: `z` alone then jumps to zeta.txt.
    ed.head.type_ahead.at_ns = 0;
    ed.typeText("z");
    try expectRow(ed, "zeta.txt");
    ed.typeText("m");
    try expectRow(ed, "zeta.txt"); // `zm` starts nothing: the focus stays
    ed.head.type_ahead.at_ns = 0;
    ed.typeText("m");
    try expectRow(ed, "m.txt"); // …and wraps to the first m-row
    ed.typeText("m");
    try expectRow(ed, "main.zig"); // the same key again steps to the next one

    // F2 begins an edit of the name: the field posture, a BAR caret (typing
    // inserts now), the whole name selected so typing replaces it.
    ed.press("F2", "");
    try t.expect(ed.head.scene_selection.began);
    try t.expectEqual(core.input.Posture.field, ed.ctx.posture());
    try expectCaret(ed, .bar);
    ed.typeText("renamed.zig");
    try expectRow(ed, "renamed.zig");
    app.proj.shot(ed, "focus-rename");

    // Return commits: the edit ends and the listing's own apply runs, which
    // asks first; Return again confirms, and the file is renamed on disk.
    ed.press("Return", "");
    try t.expect(!ed.head.scene_selection.began);
    try t.expectEqual(core.input.Posture.structural, ed.ctx.posture());
    try t.expect(ed.head.interactions.active() != null);
    ed.press("Return", "");
    try t.expect(ed.head.interactions.active() == null);
    try t.expect(h.drainUntilOracle(&app.proj, ed, "test -f renamed.zig && test ! -e main.zig && printf ok", "ok"));
}

test "e2e/focus: ide.js — Escape cancels an edit, putting the name back; moving off an edited row commits it" {
    var app: IdeApp = undefined;
    try sidebarApp(&app);
    defer app.deinit();
    const ed = &app.ed;

    ed.click(try pointAtName(ed, "m.txt"));
    ed.applyWindow();
    ed.press("F2", "");
    ed.typeText("zzz");
    try expectRow(ed, "zzz");
    ed.press("Escape", "");
    try t.expect(!ed.head.scene_selection.began);
    try t.expectEqual(core.input.Posture.structural, ed.ctx.posture());
    try expectRow(ed, "m.txt");
    try expectNoCaret(ed);
    // Nothing is pending: the name is what it was, so there is no draft to
    // apply and nothing asks.
    try t.expect(!ed.session.system.semantic.holdsDraft(ed.toolView().?));

    // An edit the focus LEAVES is committed, not lost: the draft keeps the
    // new name, and the listing asks to apply it.
    ed.press("F2", "");
    ed.typeText("n.txt");
    ed.press("Down", "");
    try t.expect(!ed.head.scene_selection.began);
    try t.expect(ed.head.interactions.active() != null);
    ed.press("Escape", ""); // the listing's own "not now"
    try t.expect(ed.head.interactions.active() == null);
    try t.expect(ed.session.system.semantic.holdsDraft(ed.toolView().?));
}

test "e2e/focus: ide.js — a slow second click on the focused row edits its name; a double click opens it instead" {
    var app: IdeApp = undefined;
    try sidebarApp(&app);
    defer app.deinit();
    const ed = &app.ed;

    // Click, then click the same row again after the double-click interval:
    // the list-control gesture for rename.
    const m = try pointAtName(ed, "m.txt");
    ed.click(m);
    ed.applyWindow();
    try t.expect(!ed.head.scene_selection.began);
    ed.clickSlow(m);
    try t.expect(ed.head.scene_selection.began);
    try expectCaret(ed, .bar);
    ed.press("Escape", "");
    try expectRow(ed, "m.txt");

    // A slow click on a row that was NOT focused only focuses it.
    const main_zig = try pointAtName(ed, "main.zig");
    ed.clickSlow(main_zig);
    try expectRow(ed, "main.zig");
    try t.expect(!ed.head.scene_selection.began);

    // A double click opens the row, and edits nothing — even when its first
    // click was a slow one that began an edit on the way.
    try t.expect(!fileOpen(ed, "main.zig"));
    ed.clickSlow(main_zig);
    ed.clickAgain(main_zig);
    try t.expect(fileOpen(ed, "main.zig"));
    try t.expect(!ed.head.scene_selection.began);
    try t.expect(!ed.session.system.semantic.holdsDraft(ed.toolView() orelse return));
}

test "e2e/focus: ide.js — a status listing and the problems list show a focused row, never a caret" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    for ([_][]const u8{
        "git init -q -b main",
        "git config user.email e2e@weft.test",
        "git config user.name weft-e2e",
        "printf 'one\\n' > f.txt && git add f.txt && git commit -q -m base",
        "printf 'two\\n' >> f.txt",
    }) |cmd| {
        const out = try app.proj.oracle(cmd);
        gpa.free(out);
    }

    // The status listing is a TEXT projection: a click on a row puts point
    // on it, and the frame shows the row, not a caret, under `row`
    // granularity.
    try ide.openFile(ed, "q.txt", "one\n");
    ed.run("git.status");
    try t.expect(h.drainToolContains(ed, "*git*", "f.txt"));
    ed.applyWindow();
    try frame(ed);
    const at = blk: {
        const text = try ed.textAlloc();
        defer gpa.free(text);
        break :blk std.mem.indexOf(u8, text, "f.txt") orelse return error.NoFileRow;
    };
    ed.click(ed.pointAt(at) orelse return error.RowNotDrawn);
    // Its own mode takes no text: a printable key inserts nothing there.
    try t.expect(ed.head.textCommit(ed.keymap) == null);
    try expectNoCaret(ed);

    // The problems list is a scene of action rows: focused by the keyboard,
    // a highlight and no caret; a digit jumps by type-ahead to the row whose
    // label starts with it.
    try core.file.writeBytes(gpa, "p.zig", "const a = 1;\nconst bee = 2;\n");
    try h.loadDiagfeed(ed);
    try ed.setConfig("problems", "source", "diagfeed-list");
    ed.runStr("diagfeed-set", "p.zig\t1\t7\twarning\ta is shadowed\np.zig\t2\t7\terror\tbee is unused\n");
    ed.press("C-S-m", "");
    ed.applyWindow();
    try t.expectEqualStrings("*problems*", ed.buffers.active().name);
    try t.expect(ed.head.scene_selection.field == null);
    try expectNoCaret(ed);
    ed.typeText("2");
    const view = ed.session.system.semantic.views.get(ed.toolView() orelse return error.NoProblemsView).?;
    const focused = view.node(ed.head.scene_selection.head() orelse return error.NoFocus).?;
    try t.expect(std.mem.indexOf(u8, focused.content.action.label, "2:7") != null);
}

/// A weft booted from a shipped config with the sidebar docked, a file open,
/// and the keys in the sidebar.
fn configSidebar(app: *h.App, config: []const u8) !void {
    const gpa = t.allocator;
    try app.proj.init(gpa);
    errdefer app.proj.deinit();
    try Editor.init(gpa, &app.ed);
    errdefer app.ed.deinit();
    app.loader = .{ .ed = &app.ed };
    errdefer app.loader.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{app.proj.prev_cwd});
    defer gpa.free(config_dir);
    try h.bootConfigNamed(&app.ed, config_dir, config, &app.loader);
    try app.ed.buffers.setDefaultMode(gpa, app.ed.head.currentMode());
    try core.quickjs.evalConfig(&app.ed.engine, app.ed.ctx, null, &app.ed.config_kv, config_dir, "weft.use(\"sidebar\");");
    try core.file.writeBytes(gpa, "m.txt", "x\n");
    try core.file.writeBytes(gpa, "zeta.txt", "zeta\n");
    app.ed.runStr("file.open", "zeta.txt");
    app.ed.run("window.focus-left");
    app.ed.applyWindow();
}

fn expectEditsOnFocus(config: []const u8, insert_key: []const u8) !void {
    var app: h.App = undefined;
    try configSidebar(&app, config);
    defer app.deinit();
    const ed = &app.ed;
    try t.expectEqual(core.input.Granularity.text, ed.session.system.semantic.granularity);

    // A click edits the name, as it always did: the field posture, and a
    // BLOCK caret — the resting mode inserts nothing, so no bar says it does.
    ed.click(try pointAtName(ed, "m.txt"));
    ed.applyWindow();
    try t.expectEqual(core.input.Posture.field, ed.ctx.posture());
    try t.expect(!ed.head.scene_selection.began);
    try expectCaret(ed, .block);
    // The grammar's own insert key types into it — with a bar, now it does.
    ed.press(insert_key, insert_key);
    try expectCaret(ed, .bar);
    ed.typeText("q");
    try expectRow(ed, "qm.txt");
}

test "e2e/focus: config.js and helix.js keep editable listings — a click edits the name under a block caret, `i` types" {
    try expectEditsOnFocus("config.js", "i");
    try expectEditsOnFocus("helix.js", "i");
}
