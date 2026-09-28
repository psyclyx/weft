//! e2e test file — the status bar (doc/chrome.md §4).
//!
//! What a person reads at the bottom of the window, read back from the last
//! frame's chrome: each drawn segment's text (its compact form, or its cut,
//! when that is what fitted) and where it landed.
//!
//!   • ide.js has ONE bar along the whole bottom of the window presenting the
//!     editor's status, and no pane — the editor, the sidebar — a line of
//!     its own; a modeless grammar shows no mode chip at all;
//!   • the bar's segments are their owners': the position moves with the
//!     caret and a click on it goes to a line; git names the branch in a
//!     repository; the problems counts follow the diagnostics;
//!   • vim and helix name their modes (NORMAL/INSERT, NOR/INS) on each pane's
//!     line, which runs flush along the pane's bottom;
//!   • a narrow pane's line shrinks — compact forms, cuts, dropped segments —
//!     and is never clipped at the pane's edge;
//!   • every chrome style draws the bar.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const ide = @import("ide_test.zig");

const core = h.core;
const region = h.region;
const window_layout = h.window_layout;
const Editor = h.Editor;
const IdeApp = ide.IdeApp;

/// Build one frame now, so the chrome read back describes the present.
fn frame(ed: *Editor) !void {
    const pixels = try ed.renderComposite();
    ed.gpa.free(pixels);
}

/// One pane's status line as the last frame drew it: each segment's text,
/// its rect and its command, left to right.
const Line = struct {
    rect: region.Rect = .{},
    n: usize = 0,
    labels: [32][]const u8 = undefined,
    rects: [32]region.Rect = undefined,
    commands: [32][]const u8 = undefined,

    fn has(self: *const Line, label: []const u8) bool {
        return self.find(label) != null;
    }

    fn find(self: *const Line, label: []const u8) ?usize {
        for (self.labels[0..self.n], 0..) |l, i| if (std.mem.eql(u8, l, label)) return i;
        return null;
    }

    fn startingWith(self: *const Line, prefix: []const u8) ?[]const u8 {
        for (self.labels[0..self.n]) |l| if (std.mem.startsWith(u8, l, prefix)) return l;
        return null;
    }

    fn print(self: *const Line) void {
        std.debug.print("[e2e/status] line:", .{});
        for (self.labels[0..self.n]) |l| std.debug.print(" [{s}]", .{l});
        std.debug.print("\n", .{});
    }
};

/// The status line pane `pane` drew in the last frame (empty when it drew
/// none).
fn lineOf(ed: *Editor, pane: u32) !Line {
    const v = try ed.ensureView();
    var line: Line = .{};
    for (v.pane_maps[0..v.pane_map_count]) |m| {
        if (m.pane != pane) continue;
        line.rect = m.rect;
        for (m.chrome) |c| {
            if (c.kind != .status or line.n >= line.labels.len) continue;
            line.labels[line.n] = c.label;
            line.rects[line.n] = c.rect;
            line.commands[line.n] = c.command;
            line.n += 1;
        }
    }
    return line;
}

fn barPane(ed: *Editor) !u32 {
    return (ed.viewportPane("statusbar") orelse return error.NoStatusBar).pane().id;
}

fn primaryPane(ed: *Editor) !u32 {
    return (ed.win_layout.primaryPane() orelse return error.NoPrimaryPane).pane().id;
}

/// Frames until pane `pane`'s line has a segment starting with `prefix` —
/// a plugin's answer lands a frame after it is asked for, and git's branch
/// after a subprocess — or fail after ten seconds.
fn awaitSegment(ed: *Editor, pane: u32, prefix: []const u8) ![]const u8 {
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) {
        try frame(ed);
        const line = try lineOf(ed, pane);
        if (line.startingWith(prefix)) |l| return l;
        std.Thread.yield() catch {};
    }
    (try lineOf(ed, pane)).print();
    return error.SegmentNeverShown;
}

/// A screenshot for a person to look at, in /tmp/chrome-status (best-effort).
fn shot(ed: *Editor, name: []const u8) void {
    const pixels = ed.renderComposite() catch return;
    defer ed.gpa.free(pixels);
    var threaded: std.Io.Threaded = .init(ed.gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().createDirPath(threaded.io(), "/tmp/chrome-status") catch {};
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "/tmp/chrome-status/{s}.ppm", .{name}) catch return;
    h.gfx_harness.writePpm(ed.gpa, path, pixels, h.app_w, h.app_h) catch {};
}

fn center(r: region.Rect) [2]f32 {
    return .{ r.x + r.w / 2, r.y + r.h / 2 };
}

test "e2e/status: ide.js shows one bar along the whole window's bottom — no pane or sidebar line, no mode chip" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.zig", "const a = 1;\nconst bee = 2;\n");
    ed.applyWindow();
    try frame(ed);

    const view = try ed.ensureView();
    const bar = try lineOf(ed, try barPane(ed));
    errdefer bar.print();
    // The window's full width, its last row, one row tall.
    try t.expectEqual(@as(f32, 0), bar.rect.x);
    try t.expectEqual(@as(f32, @floatFromInt(h.app_w)), bar.rect.w);
    try t.expectEqual(@as(f32, @floatFromInt(h.app_h)), bar.rect.y + bar.rect.h);
    try t.expectApproxEqAbs(view.line_h, bar.rect.h, 0.5);
    // Its segments sit on its row, inside it.
    try t.expect(bar.n > 0);
    for (bar.rects[0..bar.n]) |r| {
        try t.expect(r.x >= bar.rect.x and r.x + r.w <= bar.rect.x + bar.rect.w);
        try t.expectApproxEqAbs(bar.rect.y, r.y, 0.5);
    }
    // The editor's status: its path, its position, its language.
    try t.expect(bar.has("a.zig"));
    try t.expect(bar.has("Ln 1, Col 1"));
    try t.expect(bar.has("zig"));
    // No mode chip: ide names no mode, and no mode id reaches the screen —
    // neither the mode the head is in nor the one a listing rests in.
    for (bar.labels[0..bar.n]) |l| for ([_][]const u8{ ed.mode(), "ide", "ide-structural" }) |id| {
        try t.expect(!std.ascii.eqlIgnoreCase(l, id));
    };
    try t.expect(ed.keymap.modeDisplay(ed.mode()) == null);
    // Nothing else draws a status line: not the editor, not the sidebar.
    for (view.pane_maps[0..view.pane_map_count]) |m| {
        if (m.pane == try barPane(ed)) continue;
        for (m.chrome) |c| try t.expect(c.kind != .status);
    }
    shot(ed, "ide-bar-widget");

    // The position follows the caret.
    ide.textEd(ed).placeCursor(std.mem.indexOf(u8, "const a = 1;\nconst bee = 2;\n", "bee").?);
    try frame(ed);
    const moved = try lineOf(ed, try barPane(ed));
    errdefer moved.print();
    try t.expect(moved.has("Ln 2, Col 7"));

    // Focus in the sidebar: the bar still describes the editor, the
    // primary context, not the listing that has the keys.
    const sidebar = ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar;
    ed.click(center(topOfPane(ed, sidebar.pane().id) orelse return error.SidebarNotDrawn));
    try t.expectEqual(sidebar, window_layout.headFocus(ed.win_layout, ed.head));
    try frame(ed);
    const from_sidebar = try lineOf(ed, try barPane(ed));
    errdefer from_sidebar.print();
    try t.expect(from_sidebar.has("a.zig"));
}

/// Whether any segment reads like a buffer position (`2/6`).
fn hasBufferPos(line: *const Line) bool {
    for (line.labels[0..line.n]) |l| {
        const slash = std.mem.indexOfScalar(u8, l, '/') orelse continue;
        _ = std.fmt.parseInt(usize, l[0..slash], 10) catch continue;
        _ = std.fmt.parseInt(usize, l[slash + 1 ..], 10) catch continue;
        return true;
    }
    return false;
}

test "e2e/status: the bar carries no one pane's detail, and a message on any line is brief" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.zig", "const a = 1;\n");
    ed.applyWindow();
    try frame(ed);

    // Where the entry stands among the open ones, and what backs it, are a
    // pane's own line's to say; the window's bar says neither.
    const bar = try lineOf(ed, try barPane(ed));
    errdefer bar.print();
    try t.expect(!hasBufferPos(&bar));
    try t.expect(!bar.has("(file)"));

    // A message shows, and then it is gone: the startup echo does not sit on
    // the bar for the rest of the session.
    ed.runStr("app.echo", "a passing remark");
    const said = core.task.nowNs();
    ed.gpa.free(try ed.renderCompositeAt(said));
    try t.expect((try lineOf(ed, try barPane(ed))).has("a passing remark"));
    ed.gpa.free(try ed.renderCompositeAt(said + 30 * std.time.ns_per_s));
    const later = try lineOf(ed, try barPane(ed));
    errdefer later.print();
    try t.expect(!later.has("a passing remark"));
    try t.expect(later.has("a.zig")); // the rest of the bar stays
}

test "e2e/status: background-notice — a background notice is brief and never replaces a plugin's own chip" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "a.zig", "const a = 1;\n");
    ed.applyWindow();
    // dap's chip, as it publishes it while a session runs.
    ed.buffers.status.set("● *debug* · running");

    // A plugin says something from a background entry — lsp refusing to
    // start, say. It shows, beside the chip, not in its place…
    core.wasm_host.noteBackground(ed.ctx, "lsp", "lsp: no server here");
    const said = core.task.nowNs();
    ed.gpa.free(try ed.renderCompositeAt(said));
    const now = try lineOf(ed, try barPane(ed));
    errdefer now.print();
    try t.expect(now.has("● *debug* · running"));
    try t.expect(now.has("lsp: no server here"));

    // …and it is brief, as a message is; the chip stays.
    ed.gpa.free(try ed.renderCompositeAt(said + 30 * std.time.ns_per_s));
    const later = try lineOf(ed, try barPane(ed));
    errdefer later.print();
    try t.expect(later.has("● *debug* · running"));
    try t.expect(!later.has("lsp: no server here"));
}

test "e2e/status: a pane's own line still says where its entry stands" {
    const gpa = t.allocator;
    var proj: h.Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader: h.ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    try h.bootConfigNamed(&ed, config_dir, "config.js", &loader);
    try ed.buffers.setDefaultMode(gpa, ed.head.currentMode());
    try core.file.writeBytes(gpa, "m.txt", "hello\n");
    ed.runStr("file.open", "m.txt");
    ed.applyWindow();
    try frame(&ed);
    const line = try lineOf(&ed, try primaryPane(&ed));
    errdefer line.print();
    try t.expect(hasBufferPos(&line));
}

/// The top rows of pane `pane` in the last frame — somewhere a click lands
/// in its body.
fn topOfPane(ed: *Editor, pane: u32) ?region.Rect {
    const v = ed.ensureView() catch return null;
    for (v.pane_maps[0..v.pane_map_count]) |m| if (m.pane == pane) {
        return .{ .x = m.rect.x, .y = m.rect.y, .w = m.rect.w, .h = @min(m.rect.h, 3 * v.line_h) };
    };
    return null;
}

test "e2e/status: a click on the position goes to a line, in the editor the bar describes" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const src = "one\ntwo\nthree\nfour\n";
    try ide.openFile(ed, "lines.txt", src);
    ed.applyWindow();
    try frame(ed);
    const editor_entry = ed.buffers.active_id;

    const bar = try lineOf(ed, try barPane(ed));
    errdefer bar.print();
    const at = bar.find("Ln 1, Col 1") orelse return error.NoPosition;
    try t.expectEqualStrings("jump.line", bar.commands[at]);
    ed.click(center(bar.rects[at]));
    try t.expect(ed.head.pick.active);
    ed.typeText("3");
    ed.press("Return", "");
    try t.expect(!ed.head.pick.active);
    try t.expectEqual(editor_entry, ed.buffers.active_id);
    try t.expectEqual(std.mem.indexOf(u8, src, "three").?, ide.textEd(ed).cursorOffset());
    try frame(ed);
    try t.expect((try lineOf(ed, try barPane(ed))).has("Ln 3, Col 1"));
}

fn initRepo(app: *IdeApp) !void {
    for ([_][]const u8{
        "git init -q -b trunk",
        "git config user.email e2e@weft.test",
        "git config user.name weft-e2e",
        "printf 'one\\n' > f.txt && git add f.txt && git commit -q -m base",
    }) |cmd| app.proj.gpa.free(try app.proj.oracle(cmd));
}

test "e2e/status: the segments are their owners' — git's branch in a repository, the problems counts from diagnostics" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try initRepo(&app);
    try ide.openFile(ed, "f.txt", "one\n");
    ed.applyWindow();
    const bar = try barPane(ed);

    // git reads the branch once, off the frame; the bar shows it when it lands.
    try t.expectEqualStrings("trunk", try awaitSegment(ed, bar, "trunk"));
    const line = try lineOf(ed, bar);
    try t.expectEqualStrings("git.status", line.commands[line.find("trunk").?]);
    // It sits on the left, after the place (the project directory's name).
    try t.expect(line.rects[line.find("trunk").?].x < line.rects[line.find("Ln 1, Col 1").?].x);

    // The problems counts follow the diagnostics source's signal.
    try h.loadDiagfeed(ed);
    try ed.setConfig("problems", "source", "diagfeed.list");
    ed.runStr("diagfeed.set", "f.txt\t1\t1\terror\tbad\nf.txt\t1\t2\terror\tworse\ng.txt\t1\t1\twarning\tmeh\n");
    try t.expectEqualStrings("E 2", try awaitSegment(ed, bar, "E "));
    try t.expectEqualStrings("W 1", try awaitSegment(ed, bar, "W "));
    const counted = try lineOf(ed, bar);
    try t.expectEqualStrings("problems.open", counted.commands[counted.find("E 2").?]);
    // Fixed, the count goes.
    ed.runStr("diagfeed.set", "g.txt\t1\t1\twarning\tmeh\n");
    const deadline = core.task.nowNs() + 10 * std.time.ns_per_s;
    while (core.task.nowNs() < deadline) : (std.Thread.yield() catch {}) {
        try frame(ed);
        if ((try lineOf(ed, bar)).startingWith("E ") == null) break;
    } else return error.ErrorsNeverCleared;
    shot(ed, "ide-bar-owners");
}

test "e2e/status: vim and helix name their modes on each pane's line, which runs flush along the pane's bottom" {
    const gpa = t.allocator;
    for ([_]struct { file: []const u8, rest: []const u8, insert: []const u8 }{
        .{ .file = "config.js", .rest = "NORMAL", .insert = "INSERT" },
        .{ .file = "helix.js", .rest = "NOR", .insert = "INS" },
    }) |grammar| {
        var proj: h.Project = undefined;
        try proj.init(gpa);
        defer proj.deinit();
        var ed: Editor = undefined;
        try Editor.init(gpa, &ed);
        defer ed.deinit();
        var loader: h.ConfigLoader = .{ .ed = &ed };
        defer loader.deinit();
        const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
        defer gpa.free(config_dir);
        try h.bootConfigNamed(&ed, config_dir, grammar.file, &loader);
        try ed.buffers.setDefaultMode(gpa, ed.head.currentMode());
        try core.file.writeBytes(gpa, "m.txt", "hello\n");
        ed.runStr("file.open", "m.txt");
        ed.applyWindow();
        try frame(&ed);

        const pane = try primaryPane(&ed);
        const line = try lineOf(&ed, pane);
        errdefer line.print();
        // The chip leads the line, in the grammar's own words.
        try t.expect(line.n > 0);
        try t.expectEqualStrings(grammar.rest, line.labels[0]);
        try t.expect(line.has("m.txt"));
        try t.expect(line.has("Ln 1, Col 1"));
        // Flush: the line's segments sit on the pane's last row.
        const view = try ed.ensureView();
        try t.expectApproxEqAbs(line.rect.y + line.rect.h - view.line_h, line.rects[0].y, 0.5);
        if (std.mem.eql(u8, grammar.file, "config.js")) shot(&ed, "config-pane-text");

        ed.press("i", "i");
        try frame(&ed);
        const typing = try lineOf(&ed, pane);
        errdefer typing.print();
        try t.expectEqualStrings(grammar.insert, typing.labels[0]);
        ed.press("Escape", "");
        try frame(&ed);
        try t.expectEqualStrings(grammar.rest, (try lineOf(&ed, pane)).labels[0]);
    }
}

test "e2e/status: a narrow sidebar's line shrinks to what fits — compact, cut, dropped — and is never clipped" {
    const gpa = t.allocator;
    var proj: h.Project = undefined;
    try proj.init(gpa);
    defer proj.deinit();
    var ed: Editor = undefined;
    try Editor.init(gpa, &ed);
    defer ed.deinit();
    var loader: h.ConfigLoader = .{ .ed = &ed };
    defer loader.deinit();
    const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{proj.prev_cwd});
    defer gpa.free(config_dir);
    try h.bootConfig(&ed, config_dir, &loader);
    try ed.buffers.setDefaultMode(gpa, ed.head.currentMode());
    // config.js's documented sidebar line, uncommented.
    try core.quickjs.evalConfig(&ed.engine, ed.ctx, null, &ed.config_kv, config_dir, "weft.use(\"sidebar\");");
    try core.file.writeBytesMakingDirs(gpa, "a/deeply/nested/directory/with/a/long/name", "a/deeply/nested/directory/with/a/long/name/file.txt", "x\n");
    ed.runStr("file.open", "a/deeply/nested/directory/with/a/long/name/file.txt");
    ed.applyWindow();
    try frame(&ed);

    const sidebar = (ed.win_layout.dockedPanel(.left) orelse return error.NoSidebar).pane().id;
    const narrow = try lineOf(&ed, sidebar);
    errdefer narrow.print();
    const wide = try lineOf(&ed, try primaryPane(&ed));
    errdefer wide.print();
    // A quarter of the window: its own line, and all of it inside the pane.
    try t.expect(narrow.rect.w < wide.rect.w / 2);
    try t.expect(narrow.n > 0);
    for (narrow.rects[0..narrow.n]) |r| try t.expect(r.x >= narrow.rect.x and r.x + r.w <= narrow.rect.x + narrow.rect.w + 0.5);
    // The mode chip keeps its room.
    try t.expectEqualStrings("NORMAL", narrow.labels[0]);
    // The wide pane keeps its position whole, and its path — which yields
    // first — cut from its start, so the file's own name still shows.
    try t.expect(wide.has("Ln 1, Col 1"));
    const path = wide.startingWith("…") orelse wide.startingWith("a/deeply") orelse return error.NoPath;
    try t.expect(std.mem.endsWith(u8, path, "/name/file.txt"));
    // What the narrow line shows of its listing's name is whole or a cut
    // ending in its tail, never a word sliced at the edge.
    for (narrow.labels[0..narrow.n]) |l| try t.expect(std.unicode.utf8ValidateSlice(l));
    try t.expect(narrow.n < wide.n);
    shot(&ed, "narrow-sidebar-text");
}

test "e2e/status: every chrome style draws the bar" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try ide.openFile(ed, "s.txt", "styles\n");
    ed.applyWindow();
    for ([_][]const u8{ "text", "text-icons", "widget" }) |style| {
        ed.runStr("theme.set-chrome", style);
        try frame(ed);
        const bar = try lineOf(ed, try barPane(ed));
        errdefer bar.print();
        try t.expect(bar.has("s.txt"));
        try t.expect(bar.has("Ln 1, Col 1"));
        for (bar.rects[0..bar.n]) |r| try t.expect(r.x + r.w <= bar.rect.x + bar.rect.w);
        var name: [32]u8 = undefined;
        shot(ed, std.fmt.bufPrint(&name, "ide-bar-{s}", .{style}) catch "ide-bar");
    }
}
