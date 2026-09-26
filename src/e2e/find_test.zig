//! e2e test file — the `find` plugin under config/ide.js (doc/configs.md
//! §3.4): the incremental find/replace bar, driven by the keys ide.js and the
//! bar's own mode bind, observed where a user would see it — the selection,
//! the bar's surface, the annotation layer the matches are painted on, the
//! document, and one C-z.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");

const core = h.core;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;

/// A weft booted from the real config/ide.js in a throwaway project.
const IdeApp = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    fn init(self: *IdeApp, gpa: std.mem.Allocator) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        errdefer self.loader.deinit();
        const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{self.proj.prev_cwd});
        defer gpa.free(config_dir);
        try h.bootConfigNamed(&self.ed, config_dir, "ide.js", &self.loader);
        try self.ed.buffers.setDefaultMode(gpa, self.ed.head.currentMode());
    }

    fn deinit(self: *IdeApp) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

const Span = struct { start: usize, end: usize };

fn textEd(ed: *Editor) *core.Editor {
    return ed.buffers.active().textEditor().?;
}

fn selected(ed: *Editor) ?Span {
    const r = textEd(ed).selectedRange() orelse return null;
    return .{ .start = r.start, .end = r.end };
}

fn expectText(ed: *Editor, want: []const u8) !void {
    const got = try ed.textAlloc();
    defer ed.gpa.free(got);
    try t.expectEqualStrings(want, got);
}

fn openFile(ed: *Editor, name: []const u8, body: []const u8) !void {
    try core.file.writeBytes(ed.gpa, name, body);
    ed.runStr("open", name);
    try t.expectEqualStrings("ide", ed.mode());
}

/// How many matches the bar has painted on the focused document (0 once the
/// layer is gone).
fn painted(ed: *Editor) usize {
    const layer = ed.caps.layers.find(&textEd(ed).doc, "find") orelse return 0;
    return layer.spanCount();
}

fn expectBar(ed: *Editor, needle: []const u8) !void {
    if (!h.surfaceHasText(ed, needle)) {
        std.debug.print("[e2e/find] the bar does not show '{s}'\n", .{needle});
        return error.TestUnexpectedResult;
    }
}

test "e2e/find: C-f searches as you type, F3/S-F3 wrap, options toggle, Escape clears the paint" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "a.txt", "foo bar\nfoo baz\nFoo fox\n");
    ed.press("Down", ""); // start the search past the first line

    ed.press("C-f", "");
    try t.expectEqualStrings("find", ed.mode());
    try expectBar(ed, "type to search");
    ed.typeText("fo");
    // Smart case: lowercase folds, so `Foo` counts too. The caret lands on
    // the first match at or after where the search began (line two).
    try t.expectEqual(Span{ .start = 8, .end = 10 }, selected(ed).?);
    try expectBar(ed, "2/4");
    ed.typeText("o");
    try t.expectEqual(Span{ .start = 8, .end = 11 }, selected(ed).?);
    try expectBar(ed, "2/3");
    try t.expectEqual(@as(usize, 3), painted(ed));

    // Enter / F3 forward, S-Enter / S-F3 back, wrapping at both ends.
    ed.press("Return", "\n");
    try t.expectEqual(Span{ .start = 16, .end = 19 }, selected(ed).?);
    ed.press("F3", "");
    try t.expectEqual(Span{ .start = 0, .end = 3 }, selected(ed).?);
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "wrapped") != null);
    try expectBar(ed, "1/3");
    ed.press("S-F3", "");
    try t.expectEqual(Span{ .start = 16, .end = 19 }, selected(ed).?);
    ed.press("S-Return", "");
    try t.expectEqual(Span{ .start = 8, .end = 11 }, selected(ed).?);

    // M-c: case sensitive now, so `Foo` drops out.
    ed.press("M-c", "");
    try expectBar(ed, "case:on");
    try expectBar(ed, "/2");
    ed.press("M-c", ""); // off: folds whatever the query says
    ed.press("M-c", ""); // back to smart

    // A literal query is literal: `fo.` matches nothing until M-r.
    ed.press("C-u", "");
    ed.typeText("fo.");
    try expectBar(ed, "no matches");
    try t.expectEqual(@as(usize, 0), painted(ed));
    ed.press("M-r", "");
    try expectBar(ed, "regex:on");
    try expectBar(ed, "/4"); // foo, foo, Foo, fox
    // A pattern that does not compile says why.
    ed.typeText("(");
    try expectBar(ed, "unbalanced");
    ed.press("BackSpace", "");
    // M-w: whole words only — `fo` is inside every word, never one itself.
    ed.press("M-w", "");
    try expectBar(ed, "word:on");
    ed.press("C-u", "");
    ed.typeText("fo");
    try expectBar(ed, "no matches");
    ed.typeText("\\w");
    try expectBar(ed, "/4");

    // Escape: back to the grammar, the caret stays on its match, and nothing
    // is left painted.
    const before = selected(ed).?;
    ed.press("Escape", "");
    try t.expectEqualStrings("ide", ed.mode());
    try t.expectEqual(before, selected(ed).?);
    try t.expectEqual(@as(usize, 0), painted(ed));
    try t.expect(!h.surfaceHasText(ed, "Find:"));

    // F3 keeps working with the bar closed, from the caret.
    ed.press("C-Home", "");
    ed.press("F3", "");
    try t.expectEqual(@as(usize, 0), selected(ed).?.start);
    try t.expectEqualStrings("ide", ed.mode());

    // History: with nothing selected, the next C-f offers the last query;
    // Up walks back to older ones and Down returns.
    ed.press("Right", "");
    try t.expect(selected(ed) == null);
    ed.press("C-f", "");
    try expectBar(ed, "Find: fo\\w");
    ed.typeText("baz"); // the offered query is replaced, not appended to
    try expectBar(ed, "Find: baz");
    ed.press("Up", "");
    try expectBar(ed, "Find: fo\\w");
    ed.press("Down", "");
    try expectBar(ed, "Find: baz");
    ed.press("Escape", "");

    // A one-line selection becomes the query.
    ed.press("C-Home", "");
    ed.chord("S-Right S-Right S-Right S-Right S-Right");
    ed.press("C-f", "");
    try expectBar(ed, "Find: foo b");
    ed.press("Escape", "");
}

test "e2e/find: C-h replaces one and moves on; replace-all is one undo unit" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    const body = "k1=v1\nk2=v2\nk3=v3\n";
    try openFile(ed, "kv.txt", body);

    ed.press("C-h", "");
    try t.expectEqualStrings("find", ed.mode());
    try expectBar(ed, "Replace:");
    ed.press("M-r", "");
    ed.typeText("(\\w+)=(\\w+)");
    try expectBar(ed, "1/3");
    ed.press("Tab", "\t");
    ed.typeText("$2:$1");
    // Enter in the replacement field replaces the current match, flashes it,
    // and lands on the next one.
    ed.press("Return", "\n");
    try expectText(ed, "v1:k1\nk2=v2\nk3=v3\n");
    try t.expectEqual(Span{ .start = 6, .end = 11 }, selected(ed).?);
    try expectBar(ed, "1/2");
    try t.expect(ed.caps.flash.gen > 0);

    // C-M-Return replaces the rest, flashing every replacement, and one C-z
    // takes the whole pass back.
    ed.press("C-M-Return", "");
    try expectText(ed, "v1:k1\nv2:k2\nv3:k3\n");
    try t.expectEqual(@as(usize, 2), (ed.caps.layers.find(&textEd(ed).doc, "flash") orelse return error.NoFlash).spanCount());
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "replaced 2") != null);
    try expectBar(ed, "no matches");
    ed.press("Escape", "");
    ed.press("C-z", "");
    try expectText(ed, "v1:k1\nk2=v2\nk3=v3\n");
    ed.press("C-z", "");
    try expectText(ed, body);
}

test "e2e/find: M-Return turns every match into a selection" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "s.txt", "cat dog cat\ncat bird\n");

    ed.press("C-f", "");
    ed.typeText("cat");
    ed.press("F3", ""); // the second match is current
    ed.press("M-Return", "");
    try t.expectEqualStrings("ide", ed.mode());
    try t.expectEqual(@as(usize, 0), painted(ed));
    const te = textEd(ed);
    try t.expectEqual(@as(usize, 3), te.selections.items.len);
    try t.expectEqual(@as(usize, 1), te.primary);
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "3 selections") != null);
    // Typing replaces every one of them at once.
    ed.typeText("owl");
    try expectText(ed, "owl dog owl\nowl bird\n");
}

test "e2e/find: a one-megabyte buffer is searched and counted within a keystroke" {
    const gpa = t.allocator;
    var app: IdeApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;

    // ~1 MiB: 16k lines, one `needle` per 64 lines.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    var i: usize = 0;
    while (body.items.len < 1 << 20) : (i += 1) {
        const word = if (i % 64 == 63) "needle" else "straw";
        try body.print(gpa, "{d:0>6} the quick brown {s} jumps over the lazy dog\n", .{ i, word });
    }
    try openFile(ed, "big.txt", body.items);

    ed.press("C-f", "");
    var worst: u64 = 0;
    for ("needle") |c| worst = @max(worst, ed.pressTimed(&.{c}, &.{c}));
    var want_buf: [32]u8 = undefined;
    const want = try std.fmt.bufPrint(&want_buf, "1/{d}", .{i / 64});
    try expectBar(ed, want);
    // A regex with no literal lead (`\d` — every digit of every line
    // number) has nothing to prefilter on: the VM walks the whole buffer.
    ed.press("M-r", "");
    ed.press("C-u", "");
    ed.press("backslash", "\\");
    const regex_ns = ed.pressTimed("d", "d");
    try expectBar(ed, try std.fmt.bufPrint(&want_buf, "1/{d}", .{6 * i}));
    // Dispatch CPU time (`pressTimed`), measured at ~5 ms per literal
    // keystroke and ~22 ms for `\d` (98k one-byte matches) on the box this
    // was written on. The bounds are ten times that: they catch a search
    // that went back to copying the document or stepping the VM per byte,
    // not a slower machine.
    try t.expect(worst < 50 * std.time.ns_per_ms);
    try t.expect(regex_ns < 250 * std.time.ns_per_ms);
    ed.press("Escape", "");
}
