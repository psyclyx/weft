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
