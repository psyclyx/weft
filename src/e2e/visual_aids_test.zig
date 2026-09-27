//! e2e test file — config.js's visual aids, driven the way a person meets
//! them: relative line numbers in a text entry (and none in git or the file
//! browser), a flash over what every vim operation touched, and snipe —
//! evil-snipe's s/S, z/Z/x/X and f/F/t/T with their highlights and repeats,
//! alone, under an operator and over several carets.
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
/// the eligible providers for this entry's facts, and the plugin answers the
/// pane has, which the wake that drew the last frame asked for), not a
/// reimplementation of it. "" when no provider answers.
fn gutterText(ed: *Editor, line: usize, out: []u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(ed.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const buf = ed.buffers.active();
    const text_ed = buf.textEditor();
    const fx = &ed.application.driver.ctx;
    const pane = ed.head.focused_pane;
    const gf = try h.app.frame_builder.gutterFrame(a, fx, &ed.render.fb.answers, pane, buf, h.app.frame_builder.paneFacts(fx, buf, pane), null, "");
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

/// When the focused pane's newest gutter answer was stored — unchanged
/// means nobody was asked again.
fn gutterStamp(ed: *Editor) u64 {
    var newest: u64 = 0;
    for (ed.render.fb.answers.entries.items) |e| {
        if (e.pane == ed.head.focused_pane and e.answer == .gutter) newest = @max(newest, e.stamp);
    }
    return newest;
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

    // The column follows the caret on the frame it moves. The answer is a
    // formula the renderer evaluates against the snapshot it draws, so the
    // move asks the provider nothing — no new answer, none pending — and the
    // very next frame is already renumbered from the new caret line.
    const answered = gutterStamp(ed);
    try t.expect(answered != 0);
    ed.press("j", ""); // the caret on line 4 (index 3)
    const moved = try ed.renderComposite();
    gpa.free(moved);
    try t.expectEqualStrings(" 4 ", try gutterText(ed, 3, &buf));
    try t.expectEqualStrings(" 1 ", try gutterText(ed, 2, &buf));
    try t.expectEqualStrings(" 3 ", try gutterText(ed, 0, &buf));
    try t.expectEqual(answered, gutterStamp(ed));
    for (ed.render.fb.answers.pending.items) |p| try t.expect(p.ask != .gutter);

    // A git status is a projection, not a file: the provider's predicate
    // (text posture, no tool) is evaluated by the host, so it is never asked
    // — even though the status rests as text (you can type into it).
    for ([_][]const u8{
        "git init -q -b main && git config user.email e2e@weft.test && git config user.name weft-e2e",
        "git add numbers.txt && git commit -q -m numbers",
    }) |cmd| gpa.free(try app.proj.oracle(cmd));
    ed.run("git.status");
    try t.expect(drainToolContains(ed, "*git*", "Branch:"));
    try t.expectEqualStrings("*git*", ed.bufferName());
    try t.expectEqualStrings("", try gutterText(ed, 0, &buf));

    // Nor is the file browser, opened from the text entry the way config.js
    // binds it.
    ed.runStr("file.open", "numbers.txt");
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

// ── Snipe: evil-snipe under config.js ────────────────────────────────
// config.js sets snipe the way Doom sets evil-snipe — `scope` line,
// `repeat-scope` visible, smart case — and binds s/S, z/Z/x/X under an
// operator, f/F/t/T and ;/,. Offsets are byte offsets into the text.

/// The snipe highlight layer's paint, in publish order: where each span
/// starts and the theme role it rides.
const Paint = struct {
    n: usize = 0,
    start: [16]usize = undefined,
    role: [16]u32 = undefined,

    fn of(ed: *Editor) Paint {
        var out: Paint = .{};
        const doc = &ed.buffers.active().textEditor().?.doc;
        const layer = ed.caps.layers.find(doc, "snipe") orelse return out;
        for (0..@min(layer.spanCount(), out.start.len)) |i| {
            const s = layer.resolvedSpan(i);
            out.start[out.n] = s.start;
            out.role[out.n] = s.kind;
            out.n += 1;
        }
        return out;
    }
};

// The styles-palette roles (`weft.StyleClass`) the paint uses: the match
// you landed on, and every other one.
const role_location: u32 = 4;
const role_emphasis: u32 = 5;

/// A snipe typed the way a person types it: the key, then its characters.
fn snipe(ed: *Editor, key: []const u8, chars: []const u8) void {
    ed.press(key, "");
    ed.typeText(chars);
}

test "e2e/snipe: `s` finds two characters ahead on the line, `S` behind, and the line is the limit" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    authorFile(ed, "s.txt", "ab xab yab\nab zz\n");
    ed.chord("g g");

    ed.press("s", "");
    try t.expectEqualStrings("snipe-char", ed.mode());
    try t.expectEqualStrings("2>", ed.echoText());
    ed.typeText("a");
    try t.expectEqualStrings("1>a", ed.echoText());
    ed.typeText("b");
    try t.expectEqual(@as(usize, 4), cursor(ed)); // x[a]b: the "ab" under the caret is not ahead of it
    try t.expectEqualStrings("normal", ed.mode());

    // Right after a snipe `S` would repeat it (reversed); any other key first
    // makes it a snipe of its own.
    ed.press("Escape", "");
    snipe(ed, "S", "ab");
    try t.expectEqual(@as(usize, 0), cursor(ed));

    ed.press("Escape", "");
    snipe(ed, "s", "ab");
    ed.press("s", ""); // the very next key: `s` repeats
    try t.expectEqual(@as(usize, 8), cursor(ed));

    // From y[a]b the next "ab" is on the next line, past a `line` snipe:
    // it says so and does not move. (Escape first, so `s` is a new snipe.)
    ed.press("Escape", "");
    snipe(ed, "s", "ab");
    try t.expectEqual(@as(usize, 8), cursor(ed));
    try t.expectEqualStrings("snipe: can't find ab", ed.echoText());
    try t.expectEqualStrings("normal", ed.mode());
}

test "e2e/snipe: a count lands on the Nth match; spillover and buffer scopes cross lines" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    authorFile(ed, "count.txt", "ab.ab.ab.ab\nab\n");
    ed.chord("g g");

    ed.press("3", "");
    snipe(ed, "s", "ab");
    try t.expectEqual(@as(usize, 9), cursor(ed)); // matches at 3, 6, 9

    // Nothing more on this line; a spillover scope takes the snipe on.
    try ed.setConfig("snipe", "spillover-scope", "buffer");
    ed.press("Escape", "");
    snipe(ed, "s", "ab");
    try t.expectEqual(@as(usize, 12), cursor(ed));

    // A `buffer` scope looks past the line from the start.
    try ed.setConfig("snipe", "spillover-scope", "");
    try ed.setConfig("snipe", "scope", "buffer");
    ed.chord("g g");
    ed.press("4", "");
    snipe(ed, "s", "ab");
    try t.expectEqual(@as(usize, 12), cursor(ed));
}

test "e2e/snipe: `;` and `,` repeat, the snipe's own keys repeat right after it, RET repeats at the prompt" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    authorFile(ed, "rep.txt", "ab.ab.ab.ab\n");
    ed.chord("g g");

    snipe(ed, "s", "ab");
    try t.expectEqual(@as(usize, 3), cursor(ed));
    ed.press("s", "");
    try t.expectEqual(@as(usize, 6), cursor(ed));
    ed.press("semicolon", "");
    try t.expectEqual(@as(usize, 9), cursor(ed));
    ed.press("comma", "");
    try t.expectEqual(@as(usize, 6), cursor(ed));
    // Right after a snipe `S` is evil-snipe's `,`: the other way.
    ed.press("S", "");
    try t.expectEqual(@as(usize, 3), cursor(ed));

    // Any other key in between, and `s` is a new snipe again.
    ed.press("l", "");
    ed.press("s", "");
    try t.expectEqualStrings("snipe-char", ed.mode());
    // RET with nothing typed repeats the last snipe: from 4, the next "ab".
    ed.press("Return", "");
    try t.expectEqualStrings("normal", ed.mode());
    try t.expectEqual(@as(usize, 6), cursor(ed));

    // After a BACKWARD snipe its keys keep their meaning: `s` is `;` (on
    // back), `S` is `,` (forward again) — evil-snipe's transient map.
    ed.press("Escape", "");
    snipe(ed, "S", "ab");
    try t.expectEqual(@as(usize, 3), cursor(ed));
    ed.press("s", "");
    try t.expectEqual(@as(usize, 0), cursor(ed));
    ed.press("S", "");
    try t.expectEqual(@as(usize, 3), cursor(ed));
}

test "e2e/snipe: under an operator `z` is inclusive, `x` exclusive, and `t` stops before" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    authorFile(ed, "op.txt", "one ab two\n");

    const cases = [_]struct { key: []const u8, chars: []const u8, left: []const u8 }{
        .{ .key = "z", .chars = "ab", .left = " two\n" }, // through "ab"
        .{ .key = "x", .chars = "ab", .left = "ab two\n" }, // up to it
        .{ .key = "f", .chars = "w", .left = "o\n" },
        .{ .key = "t", .chars = "w", .left = "wo\n" }, // stops before the w
    };
    for (cases) |c| {
        ed.chord("g g");
        ed.press("d", "");
        snipe(ed, c.key, c.chars);
        const text = try ed.textAlloc();
        defer gpa.free(text);
        try t.expectEqualStrings(c.left, text);
        try t.expectEqualStrings("normal", ed.mode());
        ed.press("u", "");
    }
    const text = try ed.textAlloc();
    defer gpa.free(text);
    try t.expectEqualStrings("one ab two\n", text);
}

test "e2e/snipe: `f`/`t` are one-character snipes, repeated by pressing them again" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    authorFile(ed, "f.txt", "a.b.c.d.e\n");
    ed.chord("g g");

    snipe(ed, "f", ".");
    try t.expectEqual(@as(usize, 1), cursor(ed));
    ed.press("f", "");
    try t.expectEqual(@as(usize, 3), cursor(ed));
    snipe(ed, "t", "."); // just before the next dot…
    try t.expectEqual(@as(usize, 4), cursor(ed));
    ed.press("t", ""); // …and again: the adjacent dot does not hold it
    try t.expectEqual(@as(usize, 6), cursor(ed));
    snipe(ed, "F", ".");
    try t.expectEqual(@as(usize, 5), cursor(ed));
}

test "e2e/snipe: matches light up as you type, the landed one apart, and go at the next key" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    authorFile(ed, "hl.txt", "ab ab ab\n");
    ed.chord("g g");

    ed.press("s", "");
    ed.typeText("a");
    var p = Paint.of(ed);
    try t.expectEqual(@as(usize, 2), p.n); // every "a" ahead on the line
    try t.expectEqual(@as(usize, 3), p.start[0]);
    try t.expectEqual(@as(usize, 6), p.start[1]);
    try t.expectEqual(role_emphasis, p.role[0]);
    app.proj.shot(ed, "visual-snipe-incremental");

    ed.typeText("b");
    try t.expectEqual(@as(usize, 3), cursor(ed));
    p = Paint.of(ed);
    try t.expectEqual(@as(usize, 2), p.n);
    try t.expectEqual(@as(usize, 3), p.start[0]);
    try t.expectEqual(role_location, p.role[0]); // where you landed
    try t.expectEqual(@as(usize, 6), p.start[1]);
    try t.expectEqual(role_emphasis, p.role[1]);

    ed.press("l", "");
    try t.expectEqual(@as(usize, 0), Paint.of(ed).n);
}

test "e2e/snipe: aliases widen a key to a set, and smart case folds until a capital" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // weft.set("snipe", "aliases", ["[", "[[{(]"]) — two records.
    try ed.config_kv.put(gpa, "snipe", "aliases", "\x02\x01[\x05[[{(]");
    authorFile(ed, "alias.txt", "a( a{ a[\n");
    ed.chord("g g");
    snipe(ed, "s", "a[");
    try t.expectEqual(@as(usize, 3), cursor(ed)); // a{
    ed.press("semicolon", "");
    try t.expectEqual(@as(usize, 6), cursor(ed)); // a[

    authorFile(ed, "case.txt", "Ab ab AB\n");
    ed.chord("g g");
    snipe(ed, "s", "ab"); // nothing capital: any case
    try t.expectEqual(@as(usize, 3), cursor(ed));
    ed.press("semicolon", "");
    try t.expectEqual(@as(usize, 6), cursor(ed));
    ed.press("Escape", ""); // (right after a snipe, `S` would repeat it)
    snipe(ed, "S", "Ab"); // a capital: exactly this case
    try t.expectEqual(@as(usize, 0), cursor(ed));
}

test "e2e/snipe: in visual it extends the selection, and every caret snipes from its own place" {
    const gpa = t.allocator;
    var app: App = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    authorFile(ed, "multi.txt", "x ab q\ny ab q\n");
    ed.chord("g g");

    ed.press("v", "");
    snipe(ed, "s", "ab");
    try t.expectEqualStrings("visual", ed.mode());
    try t.expectEqual(@as(usize, 2), cursor(ed));
    ed.press("Escape", "");

    const text_ed = ed.buffers.active().textEditor().?;
    try text_ed.setSelections(gpa, &.{ .{ .anchor = 0, .head = 0 }, .{ .anchor = 7, .head = 7 } }, 1);
    snipe(ed, "s", "ab");
    try t.expectEqual(@as(usize, 2), text_ed.selectionCount());
    try t.expectEqual(@as(usize, 2), text_ed.selectionEnds(0).head);
    try t.expectEqual(@as(usize, 9), text_ed.selectionEnds(1).head);

    // Under an operator each caret hands its own range on.
    try text_ed.setSelections(gpa, &.{ .{ .anchor = 0, .head = 0 }, .{ .anchor = 7, .head = 7 } }, 1);
    ed.press("d", "");
    snipe(ed, "z", "ab");
    const text = try ed.textAlloc();
    defer gpa.free(text);
    try t.expectEqualStrings(" q\n q\n", text);
}
