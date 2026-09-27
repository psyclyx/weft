//! e2e test file — config.js's visual aids, driven the way a person meets
//! them: relative line numbers in a text entry (and none in git or the file
//! browser), a flash over what every vim operation touched, and snipe's
//! labelled f/F/t/T over the visible range — alone and under an operator.
//! (doc/configs.md §1.)

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const App = h.App;
const Editor = h.Editor;
const authorFile = h.authorFile;
const drainToolContains = h.drainToolContains;
const ui_mesh = h.view.ui_mesh;

/// The gutter cells the active entry's pane shows for `line`, joined — read
/// through the SAME resolution a frame uses (`frame_builder.gutterFrame`:
/// the eligible providers for this entry's facts, and a plugin's window
/// round), not a reimplementation of it. "" when no provider answers.
fn gutterText(ed: *Editor, line: usize, out: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(ed.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const buf = ed.buffers.active();
    const text_ed = buf.textEditor();
    const fx = &ed.application.driver.ctx;
    const gf = try h.app.frame_builder.gutterFrame(a, fx, h.app.frame_builder.paneFacts(fx, buf, ed.head.focused_pane), text_ed, null, "");
    var args: ui_mesh.GutterLineArgs = .{
        .line = line,
        .row = if (text_ed) |e| e.text().lineRange(line) else .{ .start = 0, .end = 0 },
        .caret_line = gf.caret_line,
        .line_count = gf.line_count,
        .theme = &ed.render.fb.view.theme,
        .batch = gf.batch,
    };
    const segs = try ui_mesh.gutterCellsForLine(gf.bindings, a, &args);
    var n: usize = 0;
    for (segs) |s| {
        @memcpy(out[n..][0..s.text.len], s.text);
        n += s.text.len;
    }
    return out[0..n];
}

fn cursor(ed: *Editor) usize {
    return ed.buffers.active().textEditor().?.cursorOffset();
}

/// The flash set on the active entry right now.
fn flashed(ed: *Editor, out: []core.flash.Range) []core.flash.Range {
    const doc = &ed.buffers.active().textEditor().?.doc;
    return ed.caps.flash.ranges(&ed.caps.layers, doc, out);
}

test "e2e/visual-aids: config.js numbers text entries relative to the caret, and nothing else" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "numbers.txt", "one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\nten\neleven\n");
    ed.chord("g g");
    ed.press("j", "");
    ed.press("j", ""); // the caret on line 3 (index 2)

    // Twelve lines (the trailing newline opens a last, empty one): every cell
    // is padded to two digits and a blank. The caret line shows its OWN
    // number — vim's `number relativenumber` — and the rest their distance.
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings(" 3 ", try gutterText(ed, 2, &buf));
    try t.expectEqualStrings(" 2 ", try gutterText(ed, 0, &buf));
    try t.expectEqualStrings(" 1 ", try gutterText(ed, 3, &buf));
    try t.expectEqualStrings(" 8 ", try gutterText(ed, 10, &buf));

    // …and the frame DRAWS it: the text of every row starts three columns in,
    // past the gutter, and the caret's stop moved with it.
    const pixels = try ed.renderComposite();
    gpa.free(pixels);
    const view = &ed.render.fb.view;
    const lines = view.frame_layout.lines;
    try t.expect(lines.len > 3);
    try t.expectApproxEqAbs(view.origin_x + 3 * view.cell_w, lines[0].stops[0].x, 0.01);
    try t.expectApproxEqAbs(view.origin_x + 3 * view.cell_w, lines[5].stops[0].x, 0.01);
    app.proj.shot(ed, "visual-linenumbers");

    // A git status is a projection, not a file: the provider's predicate
    // (text posture, no tool) is evaluated by the host, so it is never asked
    // — even though the status rests as text (you can type into it).
    for ([_][]const u8{
        "git init -q -b main && git config user.email e2e@weft.test && git config user.name weft-e2e",
        "git add numbers.txt && git commit -q -m numbers",
    }) |cmd| gpa.free(try app.proj.oracle(cmd));
    ed.run("git-status");
    try t.expect(drainToolContains(ed, "*git*", "Branch:"));
    try t.expectEqualStrings("*git*", ed.bufferName());
    try t.expectEqualStrings("", try gutterText(ed, 0, &buf));

    // Nor is the file browser, opened from the text entry the way config.js
    // binds it.
    ed.runStr("open", "numbers.txt");
    try t.expect((try gutterText(ed, 0, &buf)).len > 0);
    ed.chord("SPC f d");
    try t.expect(std.mem.startsWith(u8, ed.bufferName(), "files:"));
    try t.expectEqualStrings("", try gutterText(ed, 0, &buf));
}

test "e2e/visual-aids: every vim edit flashes what it touched, undo included" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "flash.txt", "alpha beta\ngamma delta\nepsilon\n");
    ed.chord("g g");

    const Step = struct { keys: []const []const u8, what: []const u8 };
    const steps = [_]Step{
        .{ .keys = &.{ "g", "U", "i", "w" }, .what = "gU over a text object" },
        .{ .keys = &.{ "g", "u", "i", "w" }, .what = "gu over a text object" },
        .{ .keys = &.{ "greater", "greater" }, .what = ">> on the line" },
        .{ .keys = &.{ "less", "less" }, .what = "<< on the line" },
        .{ .keys = &.{ "v", "l", "l", "U" }, .what = "U over a visual span" },
        .{ .keys = &.{ "y", "y", "p" }, .what = "p after yy" },
        .{ .keys = &.{"P"}, .what = "P" },
        .{ .keys = &.{ "g", "g", "J" }, .what = "J" },
        .{ .keys = &.{"asciitilde"}, .what = "~" },
        .{ .keys = &.{"r"}, .what = "r" }, // + the replacement, typed below
        .{ .keys = &.{"u"}, .what = "undo" },
        .{ .keys = &.{"C-r"}, .what = "redo" },
    };
    var out: [8]core.flash.Range = undefined;
    for (steps) |step| {
        const before = ed.caps.flash.gen;
        for (step.keys) |k| ed.press(k, "");
        if (std.mem.eql(u8, step.what, "r")) ed.typeText("Z");
        if (ed.caps.flash.gen == before) {
            std.debug.print("no flash after {s}\n", .{step.what});
            return error.NoFlash;
        }
        const set = flashed(ed, &out);
        if (set.len == 0 or set[0].end <= set[0].start) {
            std.debug.print("an empty flash after {s}\n", .{step.what});
            return error.EmptyFlash;
        }
        if (std.mem.eql(u8, step.what, "p after yy")) app.proj.shot(ed, "visual-flash");
        try t.expectEqualStrings("normal", ed.mode());
    }
    // The undo/redo flash is core's (only core saw the span) and shows
    // because config.js turned `editor/flash-undo` on: the frame that
    // followed the key treated it as live.
    try t.expectEqual(core.flash.Source.undo, ed.caps.flash.source);
    try t.expect(ed.application.flash_was_active);
}

test "e2e/visual-aids: with flash-undo off, an undo does not cut an operation's flash short" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "u.txt", "alpha\nbeta\n");
    ed.chord("g g");
    try ed.setConfig("editor", "flash-undo", "off");
    // Long enough that no fade can end inside the test, loaded or not.
    try ed.setConfig("editor", "flash-ms", "600000");
    // An operation flashes what it touched, and `u` takes it back at once.
    for ([_][]const u8{ "g", "U", "i", "w" }) |k| ed.press(k, "");
    try t.expect(ed.caps.flash.gen > 0);
    try t.expect(ed.application.flash_was_active);
    ed.press("u", "");
    const text = try ed.textAlloc();
    defer gpa.free(text);
    try t.expectEqualStrings("alpha\nbeta\n", text);
    // The operation's flash is still the one showing.
    try t.expect(ed.application.flash_was_active);
    try t.expectEqual(core.flash.Source.edit, ed.caps.flash.showing(false));
}

test "e2e/visual-aids: snipe — one hit jumps, several are labelled, and d composes across lines" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    authorFile(ed, "snipe.txt", "alpha beta\ngamma delta\nepsilon\n");
    ed.chord("g g");

    // One `g` in view after the caret: `f g` lands on it, like vim's `f`,
    // though it is on another line.
    ed.press("f", "");
    try t.expectEqualStrings("snipe-char", ed.mode());
    ed.typeText("g");
    try t.expectEqual(@as(usize, 11), cursor(ed));
    try t.expectEqualStrings("normal", ed.mode());

    // Several `a`s ahead of the caret: each gets a label drawn over its own
    // cell (nearest first, home row), and the next key picks one.
    ed.chord("g g");
    ed.press("f", "");
    ed.typeText("a");
    try t.expectEqualStrings("snipe-label", ed.mode());
    app.proj.shot(ed, "visual-snipe-labels");
    {
        const doc = &ed.buffers.active().textEditor().?.doc;
        const layer = ed.caps.layers.find(doc, "snipe") orelse return error.NoLabels;
        try t.expect(layer.spanCount() >= 3);
        const first = layer.resolvedSpan(0);
        try t.expectEqual(core.layers.Placement.overlay, first.placement);
        try t.expectEqual(@as(usize, 4), first.start); // alph[a]
        try t.expectEqualStrings("a", first.message);
    }
    ed.typeText("d"); // the third-nearest: alph[a], bet[a], g[a]mma
    try t.expectEqual(@as(usize, 12), cursor(ed));
    try t.expectEqualStrings("normal", ed.mode());
    // The labels are gone with the choice.
    try t.expectEqual(@as(usize, 0), (ed.caps.layers.find(&ed.buffers.active().textEditor().?.doc, "snipe") orelse return).spanCount());

    // `d f` + a label deletes THROUGH the chosen hit, across the line break,
    // as `d` over any other motion would — the range went to vim's pending
    // operator.
    ed.chord("g g");
    ed.press("d", "");
    ed.press("f", "");
    ed.typeText("m"); // gam[m]a — two m's on line 2
    try t.expectEqualStrings("snipe-label", ed.mode());
    ed.typeText("a"); // the nearest one
    try t.expectEqualStrings("normal", ed.mode());
    const text = try ed.textAlloc();
    defer gpa.free(text);
    try t.expectEqualStrings("ma delta\nepsilon\n", text);

    // `d t` with a single hit needs no label, and stops BEFORE it.
    ed.chord("g g");
    ed.press("d", "");
    ed.press("t", "");
    ed.typeText("p");
    const after = try ed.textAlloc();
    defer gpa.free(after);
    try t.expectEqualStrings("psilon\n", after);
}
