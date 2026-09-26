//! e2e test file — config/helix.js driven by key, on MANY selections
//! (doc/configs.md §2 phases 2, 3 and 6). Every test boots the real config and
//! presses keys through the keymap; what it asserts is the document and the
//! selection set core holds, never helix's private state:
//!
//!   • motions select (`w` the word ahead, `3w` three of them) and `v` extends;
//!   • `x`, `%`, `C`, `;`, `,` reshape the set, and `d c y p P R r ~ J` act on
//!     every selection as one undo unit — typing after `C` lands on both lines,
//!     and a yank of two selections pastes back one value each;
//!   • the minor modes: `gg`/`ge`/`<n>gg`, `mi`/`ma` over `textobjects`,
//!     `ms`/`md`/`mr` over `surround`, `]f` and `A-o`/`A-i` over `ts`.

const std = @import("std");
const t = std.testing;
const h = @import("harness.zig");
const lang = @import("language_support.zig");

const core = h.core;
const Editor = h.Editor;
const Project = h.Project;
const ConfigLoader = h.ConfigLoader;

/// A weft booted from the real config/helix.js in a throwaway project that is
/// the process cwd.
const HelixApp = struct {
    proj: Project = undefined,
    ed: Editor = undefined,
    loader: ConfigLoader = undefined,

    fn init(self: *HelixApp, gpa: std.mem.Allocator) !void {
        try self.proj.init(gpa);
        errdefer self.proj.deinit();
        try Editor.init(gpa, &self.ed);
        errdefer self.ed.deinit();
        self.loader = .{ .ed = &self.ed };
        errdefer self.loader.deinit();
        const config_dir = try std.fmt.allocPrint(gpa, "{s}/config", .{self.proj.prev_cwd});
        defer gpa.free(config_dir);
        try h.bootConfigNamed(&self.ed, config_dir, "helix.js", &self.loader);
        try t.expectEqual(@as(usize, 0), self.loader.missing.items.len);
        try t.expectEqual(@as(usize, 0), self.loader.failed.items.len);
        // Mirror main.zig: the grammar's own mode is where a fresh buffer rests.
        try self.ed.buffers.setDefaultMode(gpa, self.ed.head.currentMode());
    }

    fn deinit(self: *HelixApp) void {
        self.loader.deinit();
        self.ed.deinit();
        self.proj.deinit();
    }
};

fn textEd(ed: *Editor) *core.Editor {
    return ed.buffers.active().textEditor().?;
}

fn expectText(ed: *Editor, want: []const u8) !void {
    const got = try ed.textAlloc();
    defer ed.gpa.free(got);
    try t.expectEqualStrings(want, got);
}

/// Open `name` holding `body` as the focused text entry, resting in helix.
fn openFile(ed: *Editor, name: []const u8, body: []const u8) !void {
    try core.file.writeBytes(ed.gpa, name, body);
    ed.runStr("open", name);
    try t.expectEqualStrings("helix-normal", ed.mode());
}

/// Press keys the way a person types them: each character is one key.
fn keys(ed: *Editor, seq: []const u8) void {
    ed.typeText(seq);
}

/// The selection set as `{anchor, head}` pairs in document order.
fn expectSelections(ed: *Editor, want: []const [2]usize) !void {
    const te = textEd(ed);
    errdefer {
        std.debug.print("[e2e/helix] selections:", .{});
        for (0..te.selectionCount()) |i| {
            const e = te.selectionEnds(i);
            std.debug.print(" ({d},{d})", .{ e.anchor, e.head });
        }
        std.debug.print("\n", .{});
    }
    try t.expectEqual(want.len, te.selectionCount());
    for (want, 0..) |w, i| {
        const e = te.selectionEnds(i);
        try t.expectEqual(w[0], e.anchor);
        try t.expectEqual(w[1], e.head);
    }
}

test "e2e/helix: motions select, counts repeat them, and `v` extends" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                       0    5    10   15
    try openFile(ed, "words.txt", "hello world foo bar\n");

    keys(ed, "w");
    try expectSelections(ed, &.{.{ 0, 6 }}); // "hello "
    keys(ed, "w");
    try expectSelections(ed, &.{.{ 6, 12 }}); // "world "
    keys(ed, "b");
    try expectSelections(ed, &.{.{ 12, 6 }}); // back over "world "
    keys(ed, "e");
    try expectSelections(ed, &.{.{ 6, 11 }}); // "world"
    keys(ed, ";");
    try expectSelections(ed, &.{.{ 11, 11 }});

    // A count repeats the motion; each step selects the next word.
    keys(ed, "gg3w");
    try expectSelections(ed, &.{.{ 12, 16 }}); // the third word ahead: "foo "

    // Select mode: the anchor stays, motions move only the head.
    keys(ed, "ggvww");
    try t.expectEqualStrings("helix-select", ed.mode());
    try expectSelections(ed, &.{.{ 0, 12 }});
    ed.press("Escape", "");
    try t.expectEqualStrings("helix-normal", ed.mode());
    try expectSelections(ed, &.{.{ 0, 12 }});

    // `f`/`t` take the next key as their argument.
    keys(ed, ";ggfo");
    try expectSelections(ed, &.{.{ 0, 5 }}); // through the first "o"
    keys(ed, "gg2tr");
    try expectSelections(ed, &.{.{ 0, 18 }}); // up to the second "r": "hello world foo ba"
}

test "e2e/helix: x selects lines, d deletes them, % and u" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "lines.txt", "one\ntwo\nthree\n");

    keys(ed, "x");
    try expectSelections(ed, &.{.{ 0, 4 }});
    keys(ed, "x"); // on whole lines, x takes the next one too
    try expectSelections(ed, &.{.{ 0, 8 }});
    keys(ed, "d");
    try expectText(ed, "three\n");
    try expectSelections(ed, &.{.{ 0, 0 }});
    keys(ed, "u");
    try expectText(ed, "one\ntwo\nthree\n");

    keys(ed, "%");
    try expectSelections(ed, &.{.{ 0, 14 }});
    keys(ed, "~");
    try expectText(ed, "ONE\nTWO\nTHREE\n");
    keys(ed, "u");

    // `2x` is two lines at once; `J` joins them.
    keys(ed, "gg2xJ");
    try expectText(ed, "one two\nthree\n");
}

test "e2e/helix: C copies the selection down, and typing inserts at both carets as one undo unit" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "multi.txt", "abc\nabd\nxyz\n");

    keys(ed, "C");
    try expectSelections(ed, &.{ .{ 0, 0 }, .{ 4, 4 } });
    // The new copy is the primary; `,` would keep only it.
    try t.expectEqual(@as(usize, 1), textEd(ed).primary);

    keys(ed, "i");
    try t.expectEqualStrings("helix-insert", ed.mode());
    keys(ed, "X-");
    ed.press("Escape", "");
    try expectText(ed, "X-abc\nX-abd\nxyz\n");
    keys(ed, "u");
    try expectText(ed, "abc\nabd\nxyz\n");

    // A motion moves every selection: `w` selects each line's word, `c`
    // changes both, `r` replaces every character of both.
    keys(ed, "ggCw");
    try expectSelections(ed, &.{ .{ 0, 3 }, .{ 4, 7 } });
    keys(ed, "rz");
    try expectText(ed, "zzz\nzzz\nxyz\n");
    keys(ed, "c");
    keys(ed, "ok");
    ed.press("Escape", "");
    try expectText(ed, "ok\nok\nxyz\n");

    // `,` keeps the primary alone.
    keys(ed, ",");
    try t.expectEqual(@as(usize, 1), textEd(ed).selectionCount());
}

test "e2e/helix: a yank of N selections pastes back one value each" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "yank.txt", "foo bar\nbaz qux\n");

    keys(ed, "Cw"); // "foo " and "baz "
    try expectSelections(ed, &.{ .{ 0, 4 }, .{ 8, 12 } });
    keys(ed, "y");
    // To each line's end, and place before it: line one gets its own value,
    // line two its own — not both joined.
    keys(ed, "glP");
    try expectText(ed, "foo barfoo \nbaz quxbaz \n");
    keys(ed, "u");
    try expectText(ed, "foo bar\nbaz qux\n");

    // A named register outlives a later plain yank: "foo " into `a`, "qux"
    // into the unnamed one, then `"aR` over "bar" writes "foo ".
    keys(ed, ",ggw\"ay");
    keys(ed, "ge4ley");
    keys(ed, "gg4le");
    try expectSelections(ed, &.{.{ 4, 7 }});
    keys(ed, "\"aR");
    try expectText(ed, "foo foo \nbaz qux\n");
    keys(ed, "u");
    keys(ed, "gg4leR");
    try expectText(ed, "foo qux\nbaz qux\n");
}

test "e2e/helix: gg, ge and a counted gg go to lines" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "goto.txt", "l1\nl2\nl3\nl4\n");

    keys(ed, "ge");
    try expectSelections(ed, &.{.{ 9, 9 }});
    keys(ed, "gg");
    try expectSelections(ed, &.{.{ 0, 0 }});
    keys(ed, "3gg");
    try expectSelections(ed, &.{.{ 6, 6 }});
    // `]p`/`[p` and `g.` land where they should too.
    keys(ed, "ix");
    ed.press("Escape", "");
    keys(ed, "gg");
    keys(ed, "g.");
    try expectSelections(ed, &.{.{ 7, 7 }});
}

test "e2e/helix: mi and ma over textobjects, ms md mr over surround" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                           0    5    10   15
    try openFile(ed, "pairs.txt", "call(arg) \"str\"\n");

    keys(ed, "5l");
    try expectSelections(ed, &.{.{ 5, 5 }});
    keys(ed, "mi(");
    try expectSelections(ed, &.{.{ 5, 8 }}); // arg
    keys(ed, "ma(");
    try expectSelections(ed, &.{.{ 4, 9 }}); // (arg)

    keys(ed, "gg12l");
    keys(ed, "ma\"");
    const quoted = textEd(ed).selectedRange().?;
    try t.expectEqual(@as(usize, 10), quoted.start);

    // Wrap the quoted string in parens, then swap its quotes, then drop them.
    keys(ed, ";gg10lvlllll"); // select "str" and its quotes: 10..15
    try expectSelections(ed, &.{.{ 10, 15 }});
    keys(ed, "ms(");
    ed.press("Escape", "");
    try expectText(ed, "call(arg) (\"str\")\n");
    keys(ed, "gg13l");
    keys(ed, "mr\"'");
    try expectText(ed, "call(arg) ('str')\n");
    keys(ed, "gg13l");
    keys(ed, "md'");
    try expectText(ed, "call(arg) (str)\n");
    keys(ed, "u");
    try expectText(ed, "call(arg) ('str')\n");
}

test "e2e/helix: ]f and A-o/A-i select over the tree, per selection" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                          0         10        20        30
    try openFile(ed, "main.zig", "fn a() void {}\nfn b() void {}\n");
    const syn = lang.attachedSyntax(ed) orelse return error.SyntaxDidNotAttach;
    try t.expect(lang.waitForTree(ed, syn));

    keys(ed, "]f");
    try expectSelections(ed, &.{.{ 15, 29 }}); // fn b() void {}
    keys(ed, "[f");
    try expectSelections(ed, &.{.{ 0, 14 }});

    // A caret on each name, then grow both a node at a time and walk back.
    keys(ed, ";gg3lC");
    try expectSelections(ed, &.{ .{ 3, 3 }, .{ 18, 18 } });
    ed.press("M-o", "");
    const one = [_][2]usize{ .{ 3, 4 }, .{ 18, 19 } };
    try expectSelections(ed, &one);
    ed.press("M-o", "");
    const te = textEd(ed);
    try t.expectEqual(@as(usize, 2), te.selectionCount());
    const grown = te.selectionEnds(0);
    try t.expect(grown.anchor <= 3 and grown.head >= 4 and grown.head - grown.anchor > 1);
    ed.press("M-i", "");
    try expectSelections(ed, &one);
}

// ── Phase 4: regex over the selections, and search ─────────────────────

/// Type a pattern into the open regex prompt and accept it.
fn answer(ed: *Editor, pattern: []const u8) void {
    keys(ed, pattern);
    ed.press("Return", "");
}

/// The `/` register's text: what the last search, by any grammar, set.
fn searchRegister(ed: *Editor) []const u8 {
    return (ed.register.get(core.register.Bank.search) orelse return "").slice();
}

test "e2e/helix: s selects matches, S splits, K and A-K keep and drop — previewed as typed" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                          0       8       16
    try openFile(ed, "re.txt", "foo bar\nbaz foo\nqux\n");

    // `s` selects every match inside the selection — already while typing.
    keys(ed, "%s");
    try t.expectEqualStrings("helix-regex", ed.mode());
    keys(ed, "fo");
    try expectSelections(ed, &.{ .{ 0, 2 }, .{ 12, 14 } });
    keys(ed, "o");
    ed.press("Return", "");
    try t.expectEqualStrings("helix-normal", ed.mode());
    try expectSelections(ed, &.{ .{ 0, 3 }, .{ 12, 15 } });

    // Escape puts back the set the prompt opened on.
    keys(ed, "%s");
    keys(ed, "qu");
    try expectSelections(ed, &.{.{ 16, 18 }});
    ed.press("Escape", "");
    try expectSelections(ed, &.{.{ 0, 20 }});

    // `S` splits on the matches: the pieces between them are selected.
    keys(ed, "S");
    answer(ed, " ");
    try expectSelections(ed, &.{ .{ 0, 3 }, .{ 4, 11 }, .{ 12, 20 } });

    // One selection per line, then keep those with a "ba", then drop the one
    // starting with "baz".
    keys(ed, "%");
    ed.press("M-s", "");
    try expectSelections(ed, &.{ .{ 0, 7 }, .{ 8, 15 }, .{ 16, 19 } });
    keys(ed, "K");
    answer(ed, "ba");
    try expectSelections(ed, &.{ .{ 0, 7 }, .{ 8, 15 } });
    ed.press("M-K", "");
    answer(ed, "^baz");
    try expectSelections(ed, &.{.{ 0, 7 }});

    // A pattern that matches nothing leaves the set alone, and says so.
    keys(ed, "s");
    answer(ed, "zzz");
    try expectSelections(ed, &.{.{ 0, 7 }});
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "nothing selected") != null);
}

test "e2e/helix: two selections on one line paste a line twice, and o opens two lines" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "two.txt", "foo bar\nzzz\n");

    // Both selections' linewise pastes land at ONE point (the next line's
    // start). The second job's empty range must stay a point there, not
    // swell over the text the first job just wrote.
    keys(ed, "xy");
    keys(ed, "xs");
    answer(ed, "[fb]");
    try expectSelections(ed, &.{ .{ 0, 1 }, .{ 4, 5 } });
    keys(ed, "p");
    try expectText(ed, "foo bar\nfoo bar\nfoo bar\nzzz\n");
    keys(ed, "u");
    try expectText(ed, "foo bar\nzzz\n");

    // `o` likewise: a line each.
    keys(ed, "ggxs");
    answer(ed, "[fb]");
    keys(ed, "o");
    keys(ed, "X");
    ed.press("Escape", "");
    try expectText(ed, "foo bar\nX\nX\nzzz\n");
}

test "e2e/helix: a counted edit is ONE undo unit — 3> and 3] space undo with one u" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "count.txt", "a\nb\n");

    keys(ed, "3>");
    const indented = try ed.textAlloc();
    defer gpa.free(indented);
    try t.expect(std.mem.startsWith(u8, indented, " ") or std.mem.startsWith(u8, indented, "\t"));
    keys(ed, "u");
    try expectText(ed, "a\nb\n");

    keys(ed, "3]");
    ed.press("space", " ");
    try expectText(ed, "a\n\n\n\nb\n");
    keys(ed, "u");
    try expectText(ed, "a\nb\n");
}

test "e2e/helix: / ? n N search with smart case, wrap around, and extend in select mode" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                            0     6    11    17   22
    try openFile(ed, "find.txt", "Alpha beta\nalpha Beta\nALPHA\n");

    // A lowercase pattern folds case; the search starts past the caret.
    keys(ed, "/");
    answer(ed, "alpha");
    try expectSelections(ed, &.{.{ 11, 16 }});
    try t.expectEqualStrings("alpha", searchRegister(ed));
    keys(ed, "n");
    try expectSelections(ed, &.{.{ 22, 27 }});
    keys(ed, "n"); // past the last one: back to the first
    try expectSelections(ed, &.{.{ 0, 5 }});
    try t.expect(std.mem.indexOf(u8, ed.echoText(), "Wrapped") != null);
    keys(ed, "N"); // and back over the start
    try expectSelections(ed, &.{.{ 22, 27 }});

    // A capital makes it case sensitive: only "Beta" matches, not "beta".
    keys(ed, "?");
    answer(ed, "Beta");
    try expectSelections(ed, &.{.{ 17, 21 }});
    keys(ed, "n");
    try expectSelections(ed, &.{.{ 17, 21 }});

    // In select mode, `n` adds the next match beside the others.
    keys(ed, "/");
    answer(ed, "alpha");
    try expectSelections(ed, &.{.{ 22, 27 }});
    keys(ed, "v");
    keys(ed, "n");
    try t.expectEqualStrings("helix-select", ed.mode());
    try expectSelections(ed, &.{ .{ 0, 5 }, .{ 22, 27 } });
    ed.press("Escape", "");
}

test "e2e/helix: * searches for the selection's word, A-* for its bare text" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                            0   4      11
    try openFile(ed, "star.txt", "foo foobar foo\n");

    keys(ed, "e");
    try expectSelections(ed, &.{.{ 0, 3 }});
    keys(ed, "*");
    try t.expectEqualStrings("\\bfoo\\b", searchRegister(ed));
    keys(ed, "n"); // not "foobar": the next whole word
    try expectSelections(ed, &.{.{ 11, 14 }});

    keys(ed, "gge");
    ed.press("M-asterisk", "");
    try t.expectEqualStrings("foo", searchRegister(ed));
    keys(ed, "n");
    try expectSelections(ed, &.{.{ 4, 7 }});
}

test "e2e/helix: the / register is shared — vim pastes the pattern helix searched for" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "shared.txt", "one two\n");

    keys(ed, "/");
    answer(ed, "tw.");
    try expectSelections(ed, &.{.{ 4, 7 }});
    // helix reads it back too: `"/` names the same register.
    keys(ed, "gg\"/P");
    try expectText(ed, "tw.one two\n");
    keys(ed, "u");
    try expectText(ed, "one two\n");

    // The same register, read by the other grammar: vim's `"/p`.
    try h.loadVimAlongside(ed);
    try t.expectEqualStrings("normal", ed.mode());
    ed.run("vim-goto-top");
    ed.press("quotedbl", "");
    ed.press("slash", "");
    ed.press("p", ""); // weft's vim puts a fragment at the caret
    try expectText(ed, "tw.one two\n");
}

// ── gw, &, mi/ma on the tree, flash, the caret ──────────────────────────

test "e2e/helix: gw labels the words in view, and two keys select one" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                          0     6    11    17
    try openFile(ed, "gw.txt", "alpha beta gamma\ndelta a\n");
    // A frame reports the visible range the labels cover.
    gpa.free(try ed.renderComposite());

    keys(ed, "gw");
    try t.expectEqualStrings("helix-goto-word", ed.mode());
    app.proj.shot(ed, "helix-gw-labels");
    const doc = &textEd(ed).doc;
    {
        const layer = ed.caps.layers.find(doc, "helix-goto-word") orelse return error.NoLabels;
        // Four words: a lone "a" is not one.
        try t.expectEqual(@as(usize, 4), layer.spanCount());
        const first = layer.resolvedSpan(0);
        try t.expectEqual(core.layers.Placement.overlay, first.placement);
        try t.expectEqual(@as(usize, 0), first.start);
        try t.expectEqualStrings("aa", first.message);
    }
    // The first key narrows: the survivors show what is left to type.
    keys(ed, "a");
    try t.expectEqualStrings("helix-goto-word", ed.mode());
    {
        const layer = ed.caps.layers.find(doc, "helix-goto-word") orelse return error.NoLabels;
        try t.expectEqual(@as(usize, 4), layer.spanCount());
        try t.expectEqualStrings("a", layer.resolvedSpan(0).message);
    }
    keys(ed, "c"); // alpha aa, beta ab, gamma ac
    try t.expectEqualStrings("helix-normal", ed.mode());
    try expectSelections(ed, &.{.{ 11, 16 }});
    try t.expectEqual(@as(usize, 0), (ed.caps.layers.find(doc, "helix-goto-word") orelse return).spanCount());
}

test "e2e/helix: & aligns the selections into columns" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "align.txt", "a=1\nbbb=2\n");

    keys(ed, "%s");
    answer(ed, "=");
    try expectSelections(ed, &.{ .{ 1, 2 }, .{ 7, 8 } });
    keys(ed, "&");
    try expectText(ed, "a  =1\nbbb=2\n");
    try expectSelections(ed, &.{ .{ 3, 4 }, .{ 9, 10 } });
    keys(ed, "u");
    try expectText(ed, "a=1\nbbb=2\n");
}

test "e2e/helix: mi over the tree — a comment, an argument, the closest pair" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    //                          0          12  16      24
    try openFile(ed, "obj.zig", "// hi there\nfn f(a: u8, b: u8) void {}\n");
    const syn = lang.attachedSyntax(ed) orelse return error.SyntaxDidNotAttach;
    try t.expect(lang.waitForTree(ed, syn));

    keys(ed, "gg3l");
    keys(ed, "mic");
    try expectSelections(ed, &.{.{ 0, 11 }});

    keys(ed, ";2gg12l");
    try expectSelections(ed, &.{.{ 24, 24 }});
    keys(ed, "mia");
    try expectSelections(ed, &.{.{ 24, 29 }}); // b: u8

    keys(ed, ";2gg12l");
    keys(ed, "mim");
    try expectSelections(ed, &.{.{ 17, 29 }}); // inside the parens
}

/// The flash set on the active entry right now.
fn flashed(ed: *Editor, out: []core.flash.Range) []core.flash.Range {
    return ed.caps.flash.ranges(&ed.caps.layers, &textEd(ed).doc, out);
}

test "e2e/helix: an operation flashes every selection, not just the primary" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "flash.txt", "one\ntwo\n");

    keys(ed, "%s");
    answer(ed, "o");
    try expectSelections(ed, &.{ .{ 0, 1 }, .{ 6, 7 } });
    const before = ed.caps.flash.gen;
    keys(ed, "y");
    try t.expect(ed.caps.flash.gen != before);
    app.proj.shot(ed, "helix-flash");
    var out: [8]core.flash.Range = undefined;
    const set = flashed(ed, &out);
    try t.expectEqual(@as(usize, 2), set.len);
    try t.expectEqual(@as(usize, 0), set[0].start);
    try t.expectEqual(@as(usize, 6), set[1].start);
}

test "e2e/helix: the caret draws on a forward selection's last character" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "caret.txt", "hello world\n");

    // helix declares where its caret draws; insert and every other grammar
    // keep core's default, the head.
    const cfg = &ed.session.cursor_cfg;
    try t.expectEqual(h.view.CaretPlace.inside, cfg.placeFor("helix-normal"));
    try t.expectEqual(h.view.CaretPlace.inside, cfg.placeFor("helix-select"));
    try t.expectEqual(h.view.CaretPlace.head, cfg.placeFor("helix-insert"));
    try t.expectEqual(h.view.CaretPlace.head, cfg.placeFor("normal"));

    keys(ed, "w"); // "hello ", head at 6
    try expectSelections(ed, &.{.{ 0, 6 }});
    app.proj.shot(ed, "helix-caret");
    const te = textEd(ed);
    try t.expectEqual(@as(usize, 5), h.view.View.caretDrawOffset(te, te.primary, .inside));
    try t.expectEqual(@as(usize, 6), h.view.View.caretDrawOffset(te, te.primary, .head));
    keys(ed, "b"); // backward: the head is the first character either way
    try t.expectEqual(@as(usize, 0), h.view.View.caretDrawOffset(te, te.primary, .inside));
}

// ── The jumplist, macros and the clipboard (core's doors) ───────────────

test "e2e/helix: SPC y and SPC p go through the system clipboard" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "clip.txt", "foo bar\n");

    keys(ed, "w");
    ed.chord("space y");
    try t.expectEqualStrings("foo ", ed.head.clipboard.text());

    // Text copied elsewhere pastes after the selection, and is selected.
    try ed.head.clipboard.set(gpa, "XY");
    ed.chord("space p");
    try expectText(ed, "foo XYbar\n");
    try expectSelections(ed, &.{.{ 4, 6 }});
    // …and replaces it with SPC R.
    try ed.head.clipboard.set(gpa, "Z");
    ed.chord("space R");
    try expectText(ed, "foo Zbar\n");
}

test "e2e/helix: C-o and C-i walk back and forth across a search" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "jump.txt", "a\nb\nfoo\n");

    keys(ed, "/");
    answer(ed, "foo");
    try expectSelections(ed, &.{.{ 4, 7 }});
    ed.press("C-o", "");
    try t.expectEqual(@as(usize, 0), textEd(ed).cursorOffset());
    ed.press("C-i", "");
    try t.expectEqual(@as(usize, 7), textEd(ed).cursorOffset());
}

test "e2e/helix: Q records a macro, Q stops, q replays it" {
    const gpa = t.allocator;
    var app: HelixApp = undefined;
    try app.init(gpa);
    defer app.deinit();
    const ed = &app.ed;
    try openFile(ed, "macro.txt", "x\nx\nx\n");

    keys(ed, "Q");
    try t.expectEqual(@as(?u8, '@'), ed.head.macros.recording);
    keys(ed, "A1");
    ed.press("Escape", "");
    keys(ed, "j");
    keys(ed, "Q");
    try t.expectEqual(@as(?u8, null), ed.head.macros.recording);
    try expectText(ed, "x1\nx\nx\n");

    keys(ed, "q");
    try expectText(ed, "x1\nx1\nx\n");
}
